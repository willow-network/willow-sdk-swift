import Foundation

// MARK: - Light Client

/// Follows Willow's CometBFT headers from the consensus RPC endpoints you
/// configure, and supplies the app hash a GroveDB proof's root is compared
/// with.
///
/// It trusts those endpoints, as a client trusts its own node: it doesn't
/// verify validator signatures, so a header it holds is only as trustworthy
/// as the nodes it reads. Point it at a consensus node you run or trust,
/// never at the API whose proofs it checks.
///
/// It starts from a header you pin (`init(_:trustedHeader:validatorSet:)` or
/// `init(_:trustedState:)`) or, with no pin, from the latest header an
/// endpoint serves, taken as served. Another header is accepted if
/// `verify(block:trustedState:)`'s consistency checks pass against the
/// highest header already accepted below it, and if it is earlier than the
/// next accepted header above it. Those checks don't verify the commit's
/// signatures, nor that the validator set an endpoint serves is the one the
/// header commits to.
///
/// It reads CometBFT's RPC answers (`/commit`, `/validators`, and
/// `/status`). It is safe to use from several tasks at once.
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
        guard config.maxProofLagBlocks >= 0 else {
            throw LightClientConfigError("maxProofLagBlocks must not be negative, not \(config.maxProofLagBlocks)")
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
        guard config.maxProofLagBlocks >= 0 else {
            throw LightClientConfigError("maxProofLagBlocks must not be negative, not \(config.maxProofLagBlocks)")
        }

        // Validate the trusted state hasn't expired
        let age = Date().timeIntervalSince(trustedState.header.trustingPeriodStart)
        if age > config.trustingPeriod {
            throw LightClientError("Trusted header has expired (age: \(LightClient.seconds(age)) s, max: \(LightClient.seconds(config.trustingPeriod)) s)")
        }

        self.config = config
        self._session = LightClient.makeSession(config)
        self.decoder = LightClient.makeDecoder()
        self.latestKnownHeight = trustedState.header.height
        rememberLocked(trustedState)
    }

    private static func makeSession(_ config: LightClientConfig) -> URLSession {
        return makeSession(rpcTimeout: config.rpcTimeout)
    }

    /// A session for RPC requests that time out after `rpcTimeout`.
    internal static func makeSession(rpcTimeout: TimeInterval) -> URLSession {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = rpcTimeout
        return URLSession(configuration: sessionConfig)
    }

    /// CometBFT's RPC JSON. Its keys are snake_case, as the types spell
    /// them; `Header`, `Commit`, and `CommitSig` read its 64-bit integers
    /// (decimal strings) and RFC 3339 times themselves.
    private static func makeDecoder() -> JSONDecoder {
        return JSONDecoder()
    }

    /// `interval` in whole seconds, as text (any `Double`, without trapping).
    internal static func seconds(_ interval: TimeInterval) -> String {
        return String(format: "%.0f", interval)
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
                // The first header is taken as the endpoint serves it: the
                // light client trusts the endpoints it reads. It must be of
                // the configured chain.
                guard lightBlock.header.chainId == config.chainId else {
                    throw LightClientError(
                        "The RPC endpoint serves the chain \(lightBlock.header.chainId), not \(config.chainId), the chain this light client is configured for")
                }
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
    @discardableResult
    private func acceptLocked(_ block: LightBlock) throws -> TrustedState {
        let height = block.header.height
        if let known = accepted[height] {
            guard known.header.appHash.lowercased() == block.header.appHash.lowercased() else {
                throw LightClientError(
                    "The header served at height \(height) carries app hash \(block.header.appHash), not \(known.header.appHash), the app hash of the header this client accepted at that height")
            }
            return known
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
        let state = LightClient.trustedState(of: block)
        rememberLocked(state)
        return state
    }

    // MARK: - Verification

    /// Checks that a light block an endpoint serves is consistent with a
    /// trusted header: the chain ID, that height and time move forward, that
    /// the trusted header is within the trusting period (from its block time,
    /// or from when it was trusted if its block time isn't known), that the
    /// header's time is less than `maxClockDrift` ahead of this clock (a
    /// header may be any age: the header after a proof's block may be read
    /// long after it was made), for the next height that its validators hash
    /// is the trusted header's next validators hash, and that the commit
    /// names validators holding the trust threshold of the served set's
    /// voting power. The signatures are counted by validator address (each
    /// validator once), not verified, and the served validator set is not
    /// checked against the header, so a result that passes says the endpoint
    /// served a consistent block, not that the chain's validators signed it.
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
        if trustedState.header.height < Int64.max, block.header.height == trustedState.header.height + 1 {
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

        // Count the voting power of the validators whose commit signatures
        // are present. The signatures are not verified. A set CometBFT
        // refuses (a negative power, a repeated address, a total above its
        // bound) is refused, so no sum overflows, and each validator counts
        // once however many signatures name it.
        let totalPower: Int64
        do {
            totalPower = try block.validatorSet.checkedTotalVotingPower()
        } catch {
            return LightClientVerificationResult(
                verified: false,
                height: block.header.height,
                appHash: block.header.appHash,
                error: (error as? WillowError)?.message ?? "\(error)"
            )
        }
        var signedPower: Int64 = 0
        var signatureCount = 0
        var counted = Set<String>()
        for sig in block.commit.signatures ?? [] where sig.isCommit {
            guard let address = sig.validatorAddress, counted.insert(address.uppercased()).inserted,
                  let validator = block.validatorSet.validators.first(where: { $0.address == address }) else {
                continue
            }
            let (sum, overflow) = signedPower.addingReportingOverflow(validator.votingPower)
            guard !overflow else {
                return LightClientVerificationResult(
                    verified: false, height: block.header.height, appHash: block.header.appHash,
                    error: "The signed voting power overflows")
            }
            signedPower = sum
            signatureCount += 1
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
        return try await acceptedHeader(atHeight: height).appHash
    }

    /// The header at `height`, as `verifiedAppHash(atHeight:)` accepts it.
    internal func acceptedHeader(atHeight height: Int64) async throws -> TrustedHeader {
        let state = try await currentTrustedState()
        guard Date().timeIntervalSince(state.header.trustingPeriodStart) <= config.trustingPeriod else {
            throw LightClientError("The trusted header at height \(state.header.height) has outlived the trusting period")
        }
        let (known, lowest): (TrustedState?, Int64?) = locked { (accepted[height], accepted.keys.min()) }
        if let known = known {
            return known.header
        }
        if let lowest = lowest, height < lowest {
            throw LightClientError(
                "The header at height \(height) is below every header this light client has accepted (the lowest is at height \(lowest)); it checks a header only against an earlier one")
        }

        let block = try await fetchHeader(at: height)
        return try locked {
            latestKnownHeight = max(latestKnownHeight, height)
            return try acceptLocked(block).header
        }
    }

    /// Requires that the chain's app hash after block `height` is `appHash`
    /// (hex, compared case-insensitively), in a header no more than
    /// `maxProofLagBlocks` blocks behind the chain's latest height, and
    /// returns that header. Verified reads call it with a proof's root and
    /// the height the API serves with the proof.
    ///
    /// A header at height H+1 carries the app hash from after block H. The
    /// node leaves its state, and so its app hash, unchanged in a block
    /// without transactions, and every block with transactions changes it
    /// (the block's height is written into the state); the API serves as a
    /// proof's height the last block with transactions. So the app hash from
    /// after block H, where H is a block with transactions, is in every
    /// header from H+1 up to and including the header of the next block with
    /// transactions, and in no other. A header G that carries it shows the
    /// state was the chain's after block G-1.
    ///
    /// The API chooses the state it proves, so the state must be recent: the
    /// latest height L is `latestChainHeight()`, and a header G is recent when
    /// L - (G - 1) is at most `maxProofLagBlocks`. This returns:
    ///
    /// - the newest header this client has accepted, at H+1 or above and
    ///   within the trusting period (from its block time), that carries
    ///   `appHash`, if it is recent;
    /// - otherwise, if L - H is at most `maxProofLagBlocks`, the header at
    ///   H+1, from `verifiedAppHash(atHeight:)` (fetched and checked if this
    ///   client hasn't accepted it, waiting for one the chain hasn't produced
    ///   yet), which must carry `appHash`: a proof error if it doesn't;
    /// - otherwise, after `sync()` takes the latest header, the newest
    ///   accepted header that carries `appHash`, if it is recent (the state
    ///   is old, but no block with transactions has come since).
    ///
    /// Anything else throws `ProofHeightOutOfRangeError`: a state older than
    /// that, or a height H more than `maxProofLagBlocks` above L. A header at
    /// H+1 below every header this client has accepted can't be checked, so
    /// a recent state older than all of them that has since changed throws a
    /// light client error.
    public func verifyAppHash(_ appHash: String, forStateAfter height: Int64) async throws -> VerifiedHeader {
        guard height >= 0, height < Int64.max else {
            throw LightClientError("No header carries the state after block \(height)")
        }
        let next = height + 1
        _ = try await currentTrustedState()
        let maxLag = config.maxProofLagBlocks
        var latest = try await latestChainHeight()
        if height > latest, height - latest > maxLag {
            throw ProofHeightOutOfRangeError(
                "The proof is of the state after block \(height), \(height - latest) blocks ahead of the chain's latest height \(latest); at most \(maxLag) is accepted (maxProofLagBlocks)")
        }
        let wanted = appHash.lowercased()
        // The newest accepted header at `next` or above carrying the root, if
        // the state it shows (after the block before it) is recent.
        func recentCarrying() -> TrustedHeader? {
            let now = Date()
            let newest: TrustedHeader? = locked {
                accepted.values
                    .map { $0.header }
                    .filter {
                        $0.height >= next && $0.appHash.lowercased() == wanted
                            && now.timeIntervalSince($0.trustingPeriodStart) <= config.trustingPeriod
                    }
                    .max { $0.height < $1.height }
            }
            guard let header = newest, latest - (header.height - 1) <= maxLag else { return nil }
            return header
        }

        if let header = recentCarrying() {
            return VerifiedHeader(header)
        }
        if latest - height <= maxLag {
            let header = try await acceptedHeader(atHeight: next)
            guard header.appHash.lowercased() == wanted else {
                throw ProofError("The root \(appHash) is not the app hash \(header.appHash) of the header at height \(next), which carries the state after block \(height)")
            }
            return VerifiedHeader(header)
        }
        // The state is older than that. It is still the chain's state if no
        // block with transactions has come since: then the latest header
        // carries it.
        try await sync()
        let synced: Int64 = locked { trustedState?.header.height ?? 0 }
        latest = max(latest, synced)
        if let header = recentCarrying() {
            return VerifiedHeader(header)
        }
        throw ProofHeightOutOfRangeError(
            "The proof is of the state after block \(height), \(latest - height) blocks behind the chain's latest height \(latest), and no header this light client has accepted within \(maxLag) blocks of that height carries its root; at most \(maxLag) is accepted (maxProofLagBlocks)")
    }

    /// The chain's latest height as the configured endpoints report it
    /// (CometBFT's `/status`): the highest height that a majority of the
    /// endpoints that answer, and at least `minValidatorsForConsensus` of
    /// them, have reached (the lower median of their heights), or the highest
    /// header this client has accepted if that is higher. An endpoint
    /// reporting a height far above or below the others' moves it only with
    /// a majority. It trusts the endpoints as the light client's headers do.
    /// Verified reads refuse a proof of a state far behind it (see
    /// `verifyAppHash(_:forStateAfter:)`).
    ///
    /// Throws a light client error when fewer than
    /// `minValidatorsForConsensus` endpoints (and at least one) answer.
    public func latestChainHeight() async throws -> Int64 {
        let endpoints = config.validatorEndpoints
        let answers: [Int64] = await withTaskGroup(of: Int64?.self) { group in
            for endpoint in endpoints {
                group.addTask { try? await self.fetchLatestHeight(from: endpoint) }
            }
            var heights: [Int64] = []
            for await height in group {
                if let height = height, height > 0 {
                    heights.append(height)
                }
            }
            return heights
        }
        let heights = answers.sorted(by: >)
        let needed = max(1, config.minValidatorsForConsensus)
        guard heights.count >= needed else {
            throw LightClientError(
                "Only \(heights.count) of \(endpoints.count) endpoints reported the chain's latest height; \(needed) are needed")
        }
        // Highest first: the k-th has been reached by k endpoints.
        let majority = heights.count / 2 + 1
        let reached = heights[max(needed, majority) - 1]
        return locked {
            let latest = max(reached, trustedState?.header.height ?? 0)
            latestKnownHeight = max(latestKnownHeight, latest)
            return latest
        }
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
                    throw LightClientError("The header at height \(height) did not appear within \(LightClient.seconds(config.headerWaitTimeout)) s: \(error.detail)")
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
        // A CometBFT height is at least 1.
        guard commit.header.height >= 1 else {
            throw LightClientError("The RPC endpoint served a header at height \(commit.header.height)")
        }
        // The validators of the header's own height, which signed its commit.
        let validators = try await fetchValidators(from: endpoint, height: commit.header.height)
        return LightBlock(
            header: commit.header,
            validatorSet: validators,
            commit: commit.commit
        )
    }

    /// The chain ID of the CometBFT RPC at `endpoint`: the network its
    /// `/status` reports (`node_info.network`), or, if it reports none, the
    /// chain ID of its latest header (`/commit`).
    internal static func chainId(at endpoint: String, session: URLSession) async throws -> String {
        struct StatusResponse: Decodable {
            struct Result: Decodable {
                struct NodeInfo: Decodable {
                    let network: String?
                }
                let node_info: NodeInfo?
            }
            let result: Result?
        }
        struct CommitResponse: Decodable {
            struct Result: Decodable {
                struct SignedHeader: Decodable {
                    struct ChainHeader: Decodable {
                        let chain_id: String
                    }
                    let header: ChainHeader
                }
                let signed_header: SignedHeader
            }
            let result: Result
        }
        guard let status = URL(string: "\(endpoint)/status"), let commit = URL(string: "\(endpoint)/commit") else {
            throw LightClientError("Invalid endpoint URL: \(endpoint)")
        }
        let (statusData, _) = try await session.data(from: status)
        try throwRPCError(statusData)
        if let network = (try? JSONDecoder().decode(StatusResponse.self, from: statusData))?.result?.node_info?.network,
           !network.isEmpty {
            return network
        }
        let (commitData, _) = try await session.data(from: commit)
        try throwRPCError(commitData)
        let chainId = try JSONDecoder().decode(CommitResponse.self, from: commitData).result.signed_header.header.chain_id
        guard !chainId.isEmpty else {
            throw LightClientError("The RPC endpoint \(endpoint) reports no chain ID")
        }
        return chainId
    }

    /// The latest height an endpoint's CometBFT `/status` reports.
    private func fetchLatestHeight(from endpoint: String) async throws -> Int64 {
        guard let url = URL(string: "\(endpoint)/status") else {
            throw LightClientError("Invalid endpoint URL: \(endpoint)")
        }
        let (data, _) = try await session.data(from: url)
        try Self.throwRPCError(data)

        struct StatusResponse: Decodable {
            let result: StatusResult
        }

        struct StatusResult: Decodable {
            let syncInfo: SyncInfo

            enum CodingKeys: String, CodingKey {
                case syncInfo = "sync_info"
            }
        }

        struct SyncInfo: Decodable {
            let latestBlockHeight: Int64

            enum CodingKeys: String, CodingKey {
                case latestBlockHeight = "latest_block_height"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                latestBlockHeight = try container.decodeCometInt64(forKey: .latestBlockHeight)
            }
        }

        return try decoder.decode(StatusResponse.self, from: data).result.syncInfo.latestBlockHeight
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
                guard let power = Int64(v.votingPower), power >= 0 else {
                    throw LightClientError("The validator \(v.address) has voting power \(v.votingPower), not an integer from 0 to \(Int64.max)")
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
