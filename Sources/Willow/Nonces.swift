import Foundation

// MARK: - Chain Nonce State

/// An account's nonce state as the chain reports it: its base (every nonce at
/// or below it is used) and the nonces above the base it shows used.
internal struct ChainNonces: Equatable {
    let base: UInt64
    let used: Set<UInt64>

    /// Refuses a base too close to the top of the range for a window of
    /// nonces above it to fit in an `Int`.
    init(base: UInt64, used: Set<UInt64> = []) throws {
        try Self.checkRange(base)
        self.base = base
        self.used = used
    }

    /// From the value of the ABCI query `/store/account_nonce_state/{did}`:
    /// 11 bytes, the base as a big-endian u64, then 3 bytes in which bit
    /// `i % 8` of byte `i / 8` marks `base + 1 + i` used. Empty is an account
    /// with no transactions; 8 bytes is the base alone.
    init(nonceState value: Data) throws {
        let bytes = [UInt8](value)
        guard bytes.isEmpty || bytes.count == 8 || bytes.count == 11 else {
            throw ValidationError("An account nonce state is 11 bytes, not \(bytes.count)")
        }
        let base = bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        try Self.checkRange(base)
        var used: Set<UInt64> = []
        if bytes.count == 11 {
            for i in 0..<Int(NonceAllocator.window) {
                let bit = UInt8(1) << UInt8(i % 8)
                if bytes[8 + i / 8] & bit != 0 {
                    used.insert(base + 1 + UInt64(i))
                }
            }
        }
        try self.init(base: base, used: used)
    }

    private static func checkRange(_ base: UInt64) throws {
        guard base <= UInt64(Int.max) - NonceAllocator.window else {
            throw ValidationError("The account nonce \(base) is out of range")
        }
    }
}

// MARK: - Submission Outcomes

/// How a submission ended, for the nonce it was signed under.
internal enum NonceOutcome: Equatable {
    /// Accepted at CheckTx: held until the chain shows it used, or for a lease.
    case accepted
    /// Never sent, or refused with its nonce neither held nor used: free again.
    case givenBack
    /// Refused because another pending transaction holds the nonce: held for a lease.
    case held
    /// Refused because the chain has used or spent the nonce.
    case used
    /// Unknown (a network error or a 5xx): it may be pending, so the nonce stays held for its lease.
    case unknown

    /// The outcome of a CheckTx refusal whose log is `log`: the nonce is
    /// given back unless the refusal says it is held by a pending
    /// transaction, already used, or spent.
    static func refusal(_ log: String) -> NonceOutcome {
        if log.contains("held by a pending transaction") {
            return .held
        }
        if log.contains("already used") || log.contains("<= base nonce")
            || (log.contains("(nonce ") && log.contains(" spent)")) {
            return .used
        }
        return .givenBack
    }

    /// The outcome of a `POST /tx/submit` answered with HTTP `status`: a 2xx
    /// carries CheckTx's answer, a 4xx (other than 408) is the API refusing the
    /// body before CheckTx, and anything else leaves the transaction's fate
    /// unknown.
    static func submission(status: Int, result: BroadcastResult) -> NonceOutcome {
        switch status {
        case 200..<300:
            return result.success ? .accepted : refusal(result.errorMessage ?? result.rawLog ?? "")
        case 400..<500 where status != 408:
            return .givenBack
        default:
            return .unknown
        }
    }

    /// The outcome of a submission that threw `error`: a `TransactionError`
    /// is CheckTx's refusal, an `HTTPError` with a 4xx (other than 408) the
    /// API's, and anything else unknown.
    static func submission(error: Error) -> NonceOutcome {
        switch error {
        case let refused as TransactionError:
            return refusal(refused.message)
        case let http as HTTPError where (400..<500).contains(http.statusCode) && http.statusCode != 408:
            return .givenBack
        default:
            return .unknown
        }
    }
}

// MARK: - Nonce Allocator

/// One account on one network: a DID and the API its transactions go through.
internal struct NonceAccount: Hashable {
    let did: String
    let network: String

    /// `did`'s account at the API `api`, its URL compared without case in the
    /// scheme and host, a default port, or a trailing slash.
    init(did: String, api: String) {
        self.did = did
        guard var components = URLComponents(string: api) else {
            network = api
            return
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "http" && components.port == 80) || (components.scheme == "https" && components.port == 443) {
            components.port = nil
        }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        network = components.string ?? api
    }
}

/// Hands out transaction nonces so that no two writes in flight from one
/// account share one.
///
/// The node accepts a nonce in `base + 1 … base + 24` that it hasn't used, and
/// its base advances only over used nonces with no gap. So a nonce handed out
/// and never used must be handed out again, or it blocks the window. Each
/// write takes the lowest nonce in the window that the chain doesn't show
/// used and that no write in flight holds. A nonce is held from when it is
/// handed out until the chain shows it used, a refusal gives it back, or 120
/// s (the node's admission hold) pass; a refusal that says it is used or
/// spent marks it used. With all 24 held, a write fails rather than sign a
/// nonce above the window.
///
/// Every client in the process shares `shared`, so writes to one API from
/// `WillowClient` and `ConsensusClient` take distinct nonces.
internal final class NonceAllocator {
    /// How many nonces above the base the node accepts.
    static let window: UInt64 = 24
    /// How long a handed-out nonce that hasn't landed stays held, in seconds.
    static let lease: TimeInterval = 120

    /// The process's allocator.
    static let shared = NonceAllocator()

    private struct Account {
        /// The highest base the chain has reported.
        var base: UInt64 = 0
        /// Nonces above the base seen used: in the chain's bitmap, or named by a refusal.
        var used: Set<UInt64> = []
        /// Each nonce handed out that hasn't been seen used, and when its lease began.
        var leases: [UInt64: TimeInterval] = [:]
    }

    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var accounts: [NonceAccount: Account] = [:]

    /// `now` is a monotonic clock in seconds.
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// The lowest nonce above `chain.base` that isn't used and isn't held,
    /// now held. A base lower than one reported before (a slower answer) hands
    /// out none of the nonces that one showed used. Throws when every nonce in
    /// the window is held or used.
    func reserve(_ account: NonceAccount, chain: ChainNonces) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let at = now()
        var state = accounts[account] ?? Account()
        state.base = max(state.base, chain.base)
        state.used.formUnion(chain.used)
        let base = state.base
        let used = state.used.filter { $0 > base }
        state.used = used
        state.leases = state.leases.filter { nonce, since in
            nonce > base && !used.contains(nonce) && at - since < Self.lease
        }
        defer { accounts[account] = state }
        let leases = state.leases
        guard let free = (base + 1...base + Self.window).first(where: { !used.contains($0) && leases[$0] == nil }) else {
            throw WillowError(
                type: .transaction,
                message: "The nonce window is full: every nonce the node accepts for \(account.did) "
                    + "(\(base + 1) to \(base + Self.window)) is in flight or used. Wait for earlier writes to land."
            )
        }
        state.leases[free] = at
        return free
    }

    /// Records how the submission signed under `nonce` ended.
    func settle(_ account: NonceAccount, nonce: UInt64, _ outcome: NonceOutcome) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = accounts[account] else { return }
        switch outcome {
        case .accepted, .unknown:
            // Its lease runs from when it reached the node, as the node's hold does.
            if state.leases[nonce] != nil {
                state.leases[nonce] = now()
            }
        case .held:
            if nonce > state.base {
                state.leases[nonce] = now()
            }
        case .givenBack:
            state.leases[nonce] = nil
        case .used:
            state.leases[nonce] = nil
            if nonce > state.base {
                state.used.insert(nonce)
            }
        }
        accounts[account] = state
    }

    /// Hands out a nonce for `account` against `chain`, builds the
    /// transaction under it with `build`, and submits it with `submit`, which
    /// returns the outcome for the nonce with the result. A transaction that
    /// can't be built gives its nonce back.
    func submit<T>(
        _ account: NonceAccount,
        chain: ChainNonces,
        build: (Int) throws -> Data,
        submit: (Data) async throws -> (T, NonceOutcome)
    ) async throws -> T {
        let nonce = try reserve(account, chain: chain)
        let body: Data
        do {
            body = try build(Int(nonce))
        } catch {
            settle(account, nonce: nonce, .givenBack)
            throw error
        }
        let result: T
        let outcome: NonceOutcome
        do {
            (result, outcome) = try await submit(body)
        } catch {
            settle(account, nonce: nonce, NonceOutcome.submission(error: error))
            throw error
        }
        settle(account, nonce: nonce, outcome)
        return result
    }
}
