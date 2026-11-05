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

/// A nonce handed out by `NonceAllocator.reserve`: the account, the nonce,
/// and a token that tells this lease from a later one on the same nonce.
internal struct NonceReservation: Equatable {
    let account: NonceAccount
    let nonce: UInt64
    fileprivate let token: UInt64
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
/// s pass (the node holds a pending transaction's nonce for 3 blocks or 120
/// s, whichever ends first, so 120 s is the longest it can be held); a
/// refusal that says it is used or spent marks it used. With all 24 held, a
/// write fails rather than sign a nonce above the window.
///
/// Each lease carries the token of the reservation that took it. A
/// reservation that outlives its lease may find the nonce handed to a later
/// write: `confirm` tells it so before it is sent, and `settle` changes only
/// a lease whose token is its own.
///
/// Every client in the process shares `shared`, so writes to one API from
/// `WillowClient` and `ConsensusClient` take distinct nonces.
internal final class NonceAllocator {
    /// How many nonces above the base the node accepts.
    static let window: UInt64 = 24
    /// How long a handed-out nonce that hasn't landed stays held, in seconds.
    static let lease: TimeInterval = 120
    /// How many times a write takes a new nonce after losing its lease while
    /// it was built before it gives up.
    static let attempts = 3

    /// The process's allocator.
    static let shared = NonceAllocator()

    private struct Lease {
        /// When it began or was last renewed.
        var since: TimeInterval
        /// The reservation holding it.
        let token: UInt64
    }

    private struct Account {
        /// The highest base the chain has reported.
        var base: UInt64 = 0
        /// Nonces above the base seen used: in the chain's bitmap, or named by a refusal.
        var used: Set<UInt64> = []
        /// Each nonce handed out that hasn't been seen used, and its lease.
        var leases: [UInt64: Lease] = [:]

        /// Whether `nonce` is above the base, unused, and leased to no one.
        func isFree(_ nonce: UInt64) -> Bool {
            return nonce > base && !used.contains(nonce) && leases[nonce] == nil
        }
    }

    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var accounts: [NonceAccount: Account] = [:]
    private var lastToken: UInt64 = 0

    /// `now` is a monotonic clock in seconds.
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// The lowest nonce above `chain.base` that isn't used and isn't held,
    /// now held. A base lower than one reported before (a slower answer) hands
    /// out none of the nonces that one showed used. Throws when every nonce in
    /// the window is held or used.
    func reserve(_ account: NonceAccount, chain: ChainNonces) throws -> NonceReservation {
        lock.lock()
        defer { lock.unlock() }
        let at = now()
        var state = accounts[account] ?? Account()
        state.base = max(state.base, chain.base)
        state.used.formUnion(chain.used)
        let base = state.base
        let used = state.used.filter { $0 > base }
        state.used = used
        state.leases = state.leases.filter { nonce, lease in
            nonce > base && !used.contains(nonce) && at - lease.since < Self.lease
        }
        defer { accounts[account] = state }
        guard let free = (base + 1...base + Self.window).first(where: { state.isFree($0) }) else {
            throw WillowError(
                type: .transaction,
                message: "The nonce window is full: every nonce the node accepts for \(account.did) "
                    + "(\(base + 1) to \(base + Self.window)) is in flight or used. Wait for earlier writes to land."
            )
        }
        lastToken += 1
        state.leases[free] = Lease(since: at, token: lastToken)
        return NonceReservation(account: account, nonce: free, token: lastToken)
    }

    /// Whether `reservation` still holds its nonce, just before the
    /// transaction signed under it is sent; if so its lease is renewed from
    /// now. A lease that lapsed with no other write taking the nonce is taken
    /// again. False when another write holds the nonce or the chain shows it
    /// used: the transaction must be signed again under another.
    func confirm(_ reservation: NonceReservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var state = accounts[reservation.account] else { return false }
        let nonce = reservation.nonce
        let holder = state.leases[nonce]?.token ?? reservation.token
        guard holder == reservation.token, nonce > state.base, !state.used.contains(nonce) else {
            return false
        }
        state.leases[nonce] = Lease(since: now(), token: reservation.token)
        accounts[reservation.account] = state
        return true
    }

    /// Records how the submission signed under `reservation` ended. A lease
    /// that another reservation now holds is left as it is.
    func settle(_ reservation: NonceReservation, _ outcome: NonceOutcome) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = accounts[reservation.account] else { return }
        let nonce = reservation.nonce
        let owned = state.leases[nonce]?.token == reservation.token
        switch outcome {
        case .accepted, .unknown, .held:
            // It may be pending: held for a lease from when it reached the
            // node, as the node's hold runs.
            if owned || state.isFree(nonce) {
                state.leases[nonce] = Lease(since: now(), token: reservation.token)
            }
        case .givenBack:
            if owned {
                state.leases[nonce] = nil
            }
        case .used:
            if owned {
                state.leases[nonce] = nil
            }
            if nonce > state.base {
                state.used.insert(nonce)
            }
        }
        accounts[reservation.account] = state
    }

    /// Hands out a nonce for `account` against `chain`, builds the
    /// transaction under it with `build`, and submits it with `submit`, which
    /// returns the outcome for the nonce with the result. A transaction that
    /// can't be built gives its nonce back. One whose lease another write took
    /// while it was built (building took over 120 s) is built again under a
    /// new nonce, up to `attempts` times. Errors are thrown as `send` throws
    /// them.
    func submit<T>(
        _ account: NonceAccount,
        chain: ChainNonces,
        build: (Int) throws -> Data,
        submit: (Data) async throws -> (T, NonceOutcome)
    ) async throws -> T {
        return try await signAndSend(account, chain: chain, build: build, submit: submit).result
    }

    /// `submit`, returning the transaction sent with the result.
    func signAndSend<T>(
        _ account: NonceAccount,
        chain: ChainNonces,
        build: (Int) throws -> Data,
        submit: (Data) async throws -> (T, NonceOutcome)
    ) async throws -> (result: T, submission: SignedSubmission) {
        var attempt = 0
        var reservation: NonceReservation
        var body: Data
        repeat {
            if attempt == Self.attempts {
                throw WillowError(
                    type: .transaction,
                    message: "Building the transaction took longer than the \(Int(Self.lease)) s a nonce is held, "
                        + "\(Self.attempts) times: each time another write took its nonce"
                )
            }
            attempt += 1
            reservation = try reserve(account, chain: chain)
            do {
                body = try build(Int(reservation.nonce))
            } catch {
                settle(reservation, .givenBack)
                throw error
            }
        } while !confirm(reservation)
        let submission = SignedSubmission(did: account.did, nonce: Int(reservation.nonce), body: body, token: reservation.token)
        return (try await send(reservation, submission, submit), submission)
    }

    /// Sends `submission` again under its own nonce, holding the nonce while
    /// it is in flight as for a new write, and settles it as `send` does.
    /// Nothing is sent, and a transaction error is thrown, when the chain
    /// shows the nonce used (some transaction under it landed: the write's
    /// earlier copy, or another one its DID signed) or when another write
    /// from this process now holds it (the write's 120 s hold lapsed and the
    /// nonce was handed out again).
    func resubmit<T>(
        _ submission: SignedSubmission,
        on account: NonceAccount,
        submit: (Data) async throws -> (T, NonceOutcome)
    ) async throws -> T {
        guard account.did == submission.did, submission.nonce > 0 else {
            throw ValidationError("The submission is not one of \(account.did)'s transactions")
        }
        let reservation = NonceReservation(account: account, nonce: UInt64(submission.nonce), token: submission.token)
        lock.lock()
        var state = accounts[account] ?? Account()
        let nonce = reservation.nonce
        let at = now()
        let other = state.leases[nonce].map { $0.token != submission.token && at - $0.since < Self.lease } ?? false
        let used = nonce <= state.base || state.used.contains(nonce)
        if !other && !used {
            state.leases[nonce] = Lease(since: at, token: submission.token)
            accounts[account] = state
        }
        lock.unlock()
        if used {
            throw WillowError(
                type: .transaction,
                message: "Nonce \(nonce) of \(account.did) is used: a transaction under it has landed (this write's earlier copy, "
                    + "or another one signed by the same DID). Read what the write wrote to learn whether it took effect")
        }
        if other {
            throw WillowError(
                type: .transaction,
                message: "Nonce \(nonce) of \(account.did) was handed to another write after this one's hold lapsed, "
                    + "so it isn't resubmitted. Read what the write wrote to learn whether it took effect")
        }
        return try await send(reservation, submission, submit)
    }

    /// Submits `submission`'s body and settles its nonce with the outcome.
    /// A CheckTx refusal is thrown as a `TransactionError` carrying the
    /// submission; a failure whose outcome is unknown (a network error, a
    /// 5xx, a 408) as a `TransactionSubmitError` carrying it; anything else
    /// as thrown.
    private func send<T>(
        _ reservation: NonceReservation,
        _ submission: SignedSubmission,
        _ submit: (Data) async throws -> (T, NonceOutcome)
    ) async throws -> T {
        let result: T
        let outcome: NonceOutcome
        do {
            (result, outcome) = try await submit(submission.body)
        } catch {
            let outcome = NonceOutcome.submission(error: error)
            settle(reservation, outcome)
            if let refused = error as? TransactionError {
                throw TransactionError(
                    message: refused.message, txHash: refused.txHash, errorCode: refused.errorCode, submission: submission)
            }
            if outcome == .unknown {
                throw TransactionSubmitError(submission: submission, cause: error)
            }
            throw error
        }
        settle(reservation, outcome)
        return result
    }
}
