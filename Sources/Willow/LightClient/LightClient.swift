import Foundation

// MARK: - Light Client

/// A light client that follows Willow's CometBFT headers and supplies the app
/// hash a GroveDB proof's root is compared with.
///
/// It starts from a header you pin (`init(_:trustedHeader:validatorSet:)` or
/// `init(_:trustedState:)`) or, with no pin, from the first header an
/// endpoint serves. Another header is accepted if `verify(block:trustedState:)`
/// passes against the highest header already accepted below it, and if it is
/// earlier than the next accepted header above it. That check does not
/// verify the commit's signatures, nor that the validator set the endpoint
/// serves is the one the header commits to, so a header it accepts is only as
/// trustworthy as the endpoints it reads.
///
/// It reads CometBFT's RPC answers (`/commit` and `/validators`). It is safe
/// to use from several tasks at once.
public final class LightClient: @unchecked Sendable {
    private let config: LightClientConfig
    private let decoder: JSONDecoder

    /// Guards every `var` below.
    private let lock = NSLock()
    private var _session: URLSession
    /// The highest header accepted.
    private var trustedState: TrustedState?
    /// The headers accepted, by height (the most recent `maxRememberedHeaders`).
    private var accepted: [Int64: TrustedState] = [:]
    private static let maxRememberedHeaders = 256

    private var syncTask: Task<Void, Never>?
    private var isRunning = false
    private var latestKnownHeight: Int64 = 0
    private var lastSyncAttempt: Date?
    private var lastSyncError: String?

    /// The session RPC requests go through (replaceable for tests).
    internal var session: URLSession {
        get { return locked { _session } }
        set { locked { _session = newValue } }
    }

    /// Creates a new light client.
    public init(_ config: LightClientConfig) throws {
        guard !config.validatorEndpoints.isEmpty else {
            throw LightClientError("At least one validator endpoint is required")
        }
        self.config = config
        self._session = LightClient.makeSession(config)
        self.decoder = LightClient.makeDecoder()
    }

    /// Creates a new light client with a trusted header for production use.
    /// This is the recommended way to initialize a light client in production.
    public convenience init(_ config: LightClientConfig, trustedHeader: TrustedHeader, validatorSet: ValidatorSet) throws {
        try self.init(config, trustedState: TrustedState(header: trustedHeader, validatorSet: validatorSet))
    }

    /// Creates a new light client with a complete trusted state for production use.
    public init(_ config: LightClientConfig, trustedState: TrustedState) throws {
        guard !config.validatorEndpoints.isEmpty else {
            throw LightClientError("At least one validator endpoint is required")
        }

        // Validate the trusted state hasn't expired
        let age = Date().timeIntervalSince(trustedState.header.trustingPeriodStart)
        if age > config.trustingPeriod {
            throw LightClientError("Trusted header has expired (age: \(Int(age))s, max: \(Int(config.trustingPeriod))s)")
        }

        self.config = config
        self._session = LightClient.makeSession(config)
        self.decoder = LightClient.makeDecoder()
        self.latestKnownHeight = trustedState.header.height
        rememberLocked(trustedState)
    }

    private static func makeSession(_ config: LightClientConfig) -> URLSession {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.rpcTimeout
        return URLSession(configuration: sessionConfig)
    }

    /// CometBFT's RPC JSON. Its keys are snake_case, as the types spell
    /// them; `Header`, `Commit`, and `CommitSig` read its 64-bit integers
    /// (decimal strings) and RFC 3339 times themselves.
    private static func makeDecoder() -> JSONDecoder {
        return JSONDecoder()
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Lifecycle

    /// Starts the light client.
    public func start() {
        let startSync: Bool = locked {
            guard !isRunning else { return false }
            isRunning = true
            return config.autoSync
        }
        if startSync {
            startAutoSync()
        }
    }

    /// Stops the light client.
    public func stop() {
        let task: Task<Void, Never>? = locked {
            isRunning = false
            defer { syncTask = nil }
            return syncTask
        }
        task?.cancel()
    }

    private var running: Bool {
        return locked { isRunning }
    }

    private func startAutoSync() {
        let task = Task { [weak self] in
            while let self = self, self.running {
                do {
                    try await self.sync()
                } catch {
                    self.locked { self.lastSyncError = error.localizedDescription }
                }

                try? await Task.sleep(nanoseconds: UInt64(self.config.syncInterval * 1_000_000_000))
            }
        }
        locked { syncTask = task }
    }

    // MARK: - Synchronization

    /// Synchronizes with the network: fetches the latest header and accepts
    /// it (with no trusted header yet, trusts it). A latest header this
    /// client has already accepted is not an error.
    public func sync() async throws {
        locked {
            lastSyncAttempt = Date()
            lastSyncError = nil
        }

        let lightBlock = try await fetchLightBlock(at: nil)
        try locked {
            latestKnownHeight = max(latestKnownHeight, lightBlock.header.height)
            if trustedState == nil {
                // WARNING: this trusts the first header received from the
                // network. For production use, initialize the light client
                // with a known trusted header using
                // init(_:trustedHeader:validatorSet:) or init(_:trustedState:).
                rememberLocked(LightClient.trustedState(of: lightBlock))
            } else {
                try acceptLocked(lightBlock)
            }
        }
    }

    /// Synchronizes to a specific height: fetches the header there and
    /// accepts it.
    public func syncTo(height: Int64) async throws {
        let lightBlock = try await fetchLightBlock(at: height)
        try locked { try acceptLocked(lightBlock) }
    }

    private static func trustedState(of block: LightBlock) -> TrustedState {
        return TrustedState(
            header: TrustedHeader(
                height: block.header.height,
                appHash: block.header.appHash,
                trustedAt: Date(),
                headerTime: block.header.time,
                nextValidatorsHash: block.header.nextValidatorsHash,
                lastBlockId: block.header.lastBlockId
            ),
            validatorSet: block.validatorSet
        )
    }

    /// Records an accepted header (call with the lock held). The highest
    /// becomes the trusted state.
    private func rememberLocked(_ state: TrustedState) {
        accepted[state.header.height] = state
        if trustedState.map({ state.header.height > $0.header.height }) ?? true {
            trustedState = state
        }
        while accepted.count > Self.maxRememberedHeaders, let oldest = accepted.keys.min() {
            accepted.removeValue(forKey: oldest)
        }
    }

    /// Accepts a header (call with the lock held). One already accepted at
    /// its height is accepted again if it carries the same app hash and
    /// refused if it doesn't. Otherwise it must pass
    /// `verify(block:trustedState:)` against the highest header accepted
    /// below it, and be earlier than the lowest accepted above it; a header
    /// below every accepted one can't be checked.
    private func acceptLocked(_ block: LightBlock) throws {
        let height = block.header.height
        if let known = accepted[height] {
            guard known.header.appHash.lowercased() == block.header.appHash.lowercased() else {
                throw LightClientError(
                    "The header served at height \(height) carries app hash \(block.header.appHash), not \(known.header.appHash), the app hash of the header this client accepted at that height")
            }
            return
        }
        guard let anchor = accepted.filter({ $0.key < height }).max(by: { $0.key < $1.key })?.value else {
            let lowest = accepted.keys.min().map { "\($0)" } ?? "none"
            throw LightClientError(
                "The header at height \(height) is below every header this light client has accepted (the lowest is at height \(lowest)); it checks a header only against an earlier one")
        }
        let result = try verify(block: block, trustedState: anchor)
        guard result.verified else {
            throw LightClientError("Verification failed: \(result.error ?? "unknown error")")
        }
        if let next = accepted.filter({ $0.key > height }).min(by: { $0.key < $1.key })?.value,
           let nextTime = next.header.headerTime, block.header.time >= nextTime {
            throw LightClientError(
                "The header at height \(height) is not earlier than the accepted header at height \(next.header.height)")
        }
        rememberLocked(LightClient.trustedState(of: block))
    }

    // MARK: - Verification

    /// Checks a light block against trusted state: the chain ID, that height
    /// and time move forward, that the trusted header is within the trusting
    /// period (from its block time, or from when it was trusted if its block
    /// time isn't known), that the header's time is
    /// less than `maxClockDrift` ahead of this clock (a header may be any age:
    /// the header after a proof's block may be read long after it was made),
    /// for the next height that its validators hash is the trusted header's
    /// next validators hash, and that commit signatures are present from
    /// validators holding the trust threshold of the served set's voting
    /// power. The signatures are counted by validator address, not verified,
    /// and the served validator set is not checked against the header.
    public func verify(block: LightBlock, trustedState: TrustedState) throws -> LightClientVerificationResult {
        // Check chain ID
        guard block.header.chainId == config.chainId else {
            return LightClientVerificationResult(
                verified: false,
                height: block.header.height,
                appHash: block.header.appHash,
                error: "Chain ID mismatch: expected \(config.chainId), got \(block.header.chainId)"
            )
        }

        // Check height is increasing
        guard block.header.height > trustedState.header.height else {
            return LightClientVerificationResult(
                verified: false,
                height: block.header.height,
                appHash: block.header.appHash,
                error: "Height not increasing: trusted=\(trustedState.header.height), untrusted=\(block.header.height)"
            )
        }

        // Check time is progressing forward
        if let trustedTime = trustedState.header.headerTime {
            guard block.header.time > trustedTime else {
                return LightClientVerificationResult(
                    verified: false,
                    height: block.header.height,
                    appHash: block.header.appHash,
                    error: "Time did not progress forward"
                )
            }
        }

        // Check the trusting period, from the trusted header's block time
        let headerAge = Date().timeIntervalSince(trustedState.header.trustingPeriodStart)
        guard headerAge < config.trustingPeriod else {
            return LightClientVerificationResult(
                verified: false,
                height: block.header.height,
                appHash: block.header.appHash,
                error: "Trusted state expired"
            )
        }

        // Check clock drift: refuse a header from the future.
        let ahead = block.header.time.timeIntervalSince(Date())
        guard ahead < config.maxClockDrift else {
            return LightClientVerificationResult(
                verified: false,
                height: block.header.height,
                appHash: block.header.appHash,
                error: "Clock drift too large: the header's time is \(ahead)s ahead of this clock, max \(config.maxClockDrift)s"
            )
        }

        // For adjacent blocks, verify validators_hash matches next_validators_hash
        if block.header.height == trustedState.header.height + 1 {
            if let expectedValidatorsHash = trustedState.header.nextValidatorsHash,
               let actualValidatorsHash = block.header.validatorsHash {
                guard expectedValidatorsHash == actualValidatorsHash else {
                    return LightClientVerificationResult(
                        verified: false,
                        height: block.header.height,
                        appHash: block.header.appHash,
                        error: "Validator set transition hash mismatch"
                    )
                }
            }
        }

        // Verify signatures
        let totalPower = block.validatorSet.getTotalVotingPower()
        var signedPower: Int64 = 0
        var signatureCount = 0

        if let signatures = block.commit.signatures {
            for sig in signatures {
                if sig.isCommit {
                    // Find validator by address
                    if let validatorAddress = sig.validatorAddress,
                       let validator = block.validatorSet.validators.first(where: { $0.address == validatorAddress }) {
                        signedPower += validator.votingPower
                        signatureCount += 1
                    }
                }
            }
        }

        // Check minimum validators
        guard signatureCount >= config.minValidatorsForConsensus else {
            return LightClientVerificationResult(
                verified: false,
                height: block.header.height,
                appHash: block.header.appHash,
                votingPower: signedPower,
                totalPower: totalPower,
                signatureCount: signatureCount,
                error: "Not enough validators signed"
            )
        }

        // Check trust threshold
        guard config.trustThreshold.validate(votingPower: signedPower, totalPower: totalPower) else {
            return LightClientVerificationResult(
                verified: false,
                height: block.header.height,
                appHash: block.header.appHash,
                votingPower: signedPower,
                totalPower: totalPower,
                signatureCount: signatureCount,
                error: "Trust threshold not met"
            )
        }

        return LightClientVerificationResult(
            verified: true,
            height: block.header.height,
            appHash: block.header.appHash,
            votingPower: signedPower,
            totalPower: totalPower,
            signatureCount: signatureCount
        )
    }

    // MARK: - Root Hash

    /// The trusted header's state, syncing first if there is none. Verified
    /// reads call it before fetching a proof, so that the first header this
    /// client takes is no later than the proof's state.
    internal func currentTrustedState() async throws -> TrustedState {
        if let state = locked({ trustedState }) {
            return state
        }
        try await sync()
        guard let state = locked({ trustedState }) else {
            throw LightClientError("No trusted state available")
        }
        return state
    }

    /// The app hash of the trusted header, syncing first if there is none or
    /// it has outlived the trusting period. A header at height H carries the
    /// app hash from after block H-1; to check a proof of the state after a
    /// given block, use `verifyAppHash(_:forStateAfter:)`.
    public func getVerifiedRootHash() async throws -> String {
        let state = try await currentTrustedState()

        // Check if trusted state is still valid
        let age = Date().timeIntervalSince(state.header.trustingPeriodStart)
        if age > config.trustingPeriod {
            try await sync()
            guard let newState = locked({ trustedState }) else {
                throw LightClientError("Failed to sync trusted state")
            }
            return newState.header.appHash
        }

        return state.header.appHash
    }

    /// The app hash of the header at `height`, accepted as `sync` accepts a
    /// header. A header at height H carries the app hash from after block
    /// H-1.
    ///
    /// A header this client has accepted is answered from memory. Any other
    /// is fetched, waiting up to the config's `headerWaitTimeout` for the
    /// chain to produce it, and checked against the highest header accepted
    /// below it (see `verify(block:trustedState:)`). A header below every
    /// one this client has accepted can't be checked, so it throws.
    public func verifiedAppHash(atHeight height: Int64) async throws -> String {
        let state = try await currentTrustedState()
        guard Date().timeIntervalSince(state.header.trustingPeriodStart) <= config.trustingPeriod else {
            throw LightClientError("The trusted header at height \(state.header.height) has outlived the trusting period")
        }
        let (known, lowest): (TrustedState?, Int64?) = locked { (accepted[height], accepted.keys.min()) }
        if let known = known {
            return known.header.appHash
        }
        if let lowest = lowest, height < lowest {
            throw LightClientError(
                "The header at height \(height) is below every header this light client has accepted (the lowest is at height \(lowest)); it checks a header only against an earlier one")
        }

        let block = try await fetchHeader(at: height)
        try locked {
            latestKnownHeight = max(latestKnownHeight, height)
            try acceptLocked(block)
        }
        return block.header.appHash
    }

    /// Requires that the chain's app hash after block `height` is `appHash`
    /// (hex, compared case-insensitively), and returns the height of the
    /// header that carries it.
    ///
    /// A header at height H+1 carries the app hash from after block H. The
    /// node leaves its state, and so its app hash, unchanged in a block
    /// without transactions, and every block with transactions changes it
    /// (the block's height is written into the state). So the app hash from
    /// after block H, where H is a block with transactions, is in every
    /// header from H+1 up to and including the header of the next block with
    /// transactions, and in no other. This takes:
    ///
    /// - a header this client has accepted, at H+1 or above and within the
    ///   trusting period (from its block time), that carries `appHash`;
    /// - otherwise the header at H+1, from `verifiedAppHash(atHeight:)`
    ///   (fetched and checked if this client hasn't accepted it), which must
    ///   carry `appHash`: a proof error if it doesn't.
    ///
    /// A header at H+1 below every header this client has accepted can't be
    /// checked, so a state older than all of them that has since changed
    /// throws.
    public func verifyAppHash(_ appHash: String, forStateAfter height: Int64) async throws -> Int64 {
        guard height >= 0, height < Int64.max else {
            throw LightClientError("No header carries the state after block \(height)")
        }
        let next = height + 1
        _ = try await currentTrustedState()
        let wanted = appHash.lowercased()
        let now = Date()
        let carrying: Int64? = locked {
            accepted.values
                .filter {
                    $0.header.height >= next && $0.header.appHash.lowercased() == wanted
                        && now.timeIntervalSince($0.header.trustingPeriodStart) <= config.trustingPeriod
                }
                .map { $0.header.height }
                .min()
        }
        if let carrying = carrying {
            return carrying
        }
        let actual = try await verifiedAppHash(atHeight: next)
        guard actual.lowercased() == wanted else {
            throw ProofError("The root \(appHash) is not the app hash \(actual) of the header at height \(next), which carries the state after block \(height)")
        }
        return next
    }

    /// The header at `height`, waiting up to `headerWaitTimeout` for the
    /// chain to produce it.
    private func fetchHeader(at height: Int64) async throws -> LightBlock {
        let deadline = Date().addingTimeInterval(config.headerWaitTimeout)
        while true {
            do {
                let block = try await fetchLightBlock(at: height)
                guard block.header.height == height else {
                    throw LightClientError("Asked for the header at height \(height), got one at height \(block.header.height)")
                }
                return block
            } catch let error as HeaderNotYetAvailable {
                guard Date() < deadline else {
                    throw LightClientError("The header at height \(height) did not appear within \(Int(config.headerWaitTimeout)) s: \(error.detail)")
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    // MARK: - State Management

    /// Exports the current trusted state for persistence.
    public func exportTrustedState() throws -> TrustedState {
        guard let state = locked({ trustedState }) else {
            throw LightClientError("No trusted state to export")
        }
        return state
    }

    /// Imports a trusted state. It replaces every header accepted so far:
    /// the imported header becomes the only one this client has accepted.
    public func importTrustedState(_ state: TrustedState) throws {
        // Validate the state
        let age = Date().timeIntervalSince(state.header.trustingPeriodStart)
        if age > config.trustingPeriod {
            throw LightClientError("Imported state has expired")
        }

        locked {
            accepted = [:]
            trustedState = nil
            rememberLocked(state)
            latestKnownHeight = max(latestKnownHeight, state.header.height)
        }
    }

    /// Gets the current sync status.
    public func getSyncStatus() -> SyncStatus {
        return locked {
            SyncStatus(
                latestTrustedHeight: trustedState?.header.height ?? 0,
                latestTrustedTime: trustedState?.header.trustedAt ?? Date.distantPast,
                latestKnownHeight: latestKnownHeight,
                isSynced: trustedState != nil && lastSyncError == nil,
                lastSyncAttempt: lastSyncAttempt,
                lastSyncError: lastSyncError
            )
        }
    }

    // MARK: - RPC Calls

    private func fetchLightBlock(at height: Int64?) async throws -> LightBlock {
        var lastError: Error?

        for endpoint in config.validatorEndpoints {
            do {
                return try await fetchLightBlockFrom(endpoint: endpoint, height: height)
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? LightClientError("Failed to fetch light block from any endpoint")
    }

    private func fetchLightBlockFrom(endpoint: String, height: Int64?) async throws -> LightBlock {
        let commit = try await fetchCommit(from: endpoint, height: height)
        // The validators of the header's own height, which signed its commit.
        let validators = try await fetchValidators(from: endpoint, height: commit.header.height)
        return LightBlock(
            header: commit.header,
            validatorSet: validators,
            commit: commit.commit
        )
    }

    private func fetchCommit(from endpoint: String, height: Int64?) async throws -> (header: Header, commit: Commit) {
        var urlString = "\(endpoint)/commit"
        if let h = height {
            urlString += "?height=\(h)"
        }

        guard let url = URL(string: urlString) else {
            throw LightClientError("Invalid endpoint URL: \(endpoint)")
        }

        let (data, _) = try await session.data(from: url)
        try Self.throwRPCError(data)

        struct CommitResponse: Decodable {
            let result: CommitResult
        }

        struct CommitResult: Decodable {
            let signedHeader: SignedHeader

            enum CodingKeys: String, CodingKey {
                case signedHeader = "signed_header"
            }
        }

        struct SignedHeader: Decodable {
            let header: Header
            let commit: Commit
        }

        let response = try decoder.decode(CommitResponse.self, from: data)
        return (response.result.signedHeader.header, response.result.signedHeader.commit)
    }

    /// The validator set at `height`, every page of it.
    private func fetchValidators(from endpoint: String, height: Int64) async throws -> ValidatorSet {
        struct ValidatorsResponse: Decodable {
            let result: ValidatorsResult
        }

        struct ValidatorsResult: Decodable {
            let validators: [ValidatorData]
            let total: String?
        }

        struct ValidatorData: Decodable {
            let address: String
            let pubKey: PubKey
            let votingPower: String

            enum CodingKeys: String, CodingKey {
                case address
                case pubKey = "pub_key"
                case votingPower = "voting_power"
            }
        }

        struct PubKey: Decodable {
            let type: String
            let value: String
        }

        let perPage = 100
        var validators: [LightClientValidator] = []
        for page in 1...100 {
            let urlString = "\(endpoint)/validators?height=\(height)&page=\(page)&per_page=\(perPage)"
            guard let url = URL(string: urlString) else {
                throw LightClientError("Invalid endpoint URL: \(endpoint)")
            }

            let (data, _) = try await session.data(from: url)
            try Self.throwRPCError(data)
            let result = try decoder.decode(ValidatorsResponse.self, from: data).result

            for v in result.validators {
                guard let power = Int64(v.votingPower) else {
                    throw LightClientError("The validator \(v.address) has voting power \(v.votingPower), not an integer")
                }
                validators.append(LightClientValidator(address: v.address, publicKey: v.pubKey.value, votingPower: power))
            }
            let total = result.total.flatMap { Int($0) } ?? validators.count
            if validators.count >= total || result.validators.isEmpty {
                break
            }
        }

        return ValidatorSet(validators: validators)
    }

    /// Throws the JSON-RPC error an endpoint answered with, if any: a height
    /// the chain hasn't reached as `HeaderNotYetAvailable`, anything else as
    /// a light client error.
    internal static func throwRPCError(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rpcError = object["error"] as? [String: Any] else {
            return
        }
        let detail = (rpcError["data"] as? String) ?? (rpcError["message"] as? String) ?? "unknown error"
        if detail.contains("current blockchain height") {
            throw HeaderNotYetAvailable(detail: detail)
        }
        throw LightClientError("The RPC endpoint answered with an error: \(detail)")
    }
}

/// An endpoint's answer for a height the chain hasn't reached yet.
internal struct HeaderNotYetAvailable: Error {
    let detail: String
}
