import Foundation

// MARK: - Light Client

/// A light client that follows Willow's CometBFT headers and supplies the app
/// hash a GroveDB proof's root is compared with.
///
/// It starts from a header you pin (`init(_:trustedHeader:validatorSet:)` or
/// `init(_:trustedState:)`) or, with no pin, from the first header an
/// endpoint serves. A later header is accepted if `verify(block:trustedState:)`
/// passes. That check does not verify the commit's signatures, nor that the
/// validator set the endpoint serves is the one the header commits to, so a
/// header it accepts is only as trustworthy as the endpoints it reads.
public class LightClient {
    private let config: LightClientConfig
    /// The session RPC requests go through (replaceable for tests).
    internal var session: URLSession
    private let decoder: JSONDecoder

    private var trustedState: TrustedState?
    private var syncTask: Task<Void, Never>?
    private var isRunning = false

    /// App hashes of the headers this client has accepted, by height (the
    /// most recent `maxRememberedHeaders`).
    private var acceptedAppHashes: [Int64: String] = [:]
    private static let maxRememberedHeaders = 256

    private var latestKnownHeight: Int64 = 0
    private var lastSyncAttempt: Date?
    private var lastSyncError: String?

    /// Creates a new light client.
    public init(_ config: LightClientConfig) throws {
        guard !config.validatorEndpoints.isEmpty else {
            throw LightClientError("At least one validator endpoint is required")
        }

        self.config = config

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.rpcTimeout
        self.session = URLSession(configuration: sessionConfig)

        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Creates a new light client with a trusted header for production use.
    /// This is the recommended way to initialize a light client in production.
    public init(_ config: LightClientConfig, trustedHeader: TrustedHeader, validatorSet: ValidatorSet) throws {
        guard !config.validatorEndpoints.isEmpty else {
            throw LightClientError("At least one validator endpoint is required")
        }

        // Validate the trusted header hasn't expired
        let age = Date().timeIntervalSince(trustedHeader.trustedAt)
        if age > config.trustingPeriod {
            throw LightClientError("Trusted header has expired (age: \(Int(age))s, max: \(Int(config.trustingPeriod))s)")
        }

        self.config = config

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.rpcTimeout
        self.session = URLSession(configuration: sessionConfig)

        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder.dateDecodingStrategy = .iso8601

        // Initialize with trusted state
        self.trustedState = TrustedState(header: trustedHeader, validatorSet: validatorSet)
        self.latestKnownHeight = trustedHeader.height
        remember(height: trustedHeader.height, appHash: trustedHeader.appHash)
    }

    /// Creates a new light client with a complete trusted state for production use.
    public init(_ config: LightClientConfig, trustedState: TrustedState) throws {
        guard !config.validatorEndpoints.isEmpty else {
            throw LightClientError("At least one validator endpoint is required")
        }

        // Validate the trusted state hasn't expired
        let age = Date().timeIntervalSince(trustedState.header.trustedAt)
        if age > config.trustingPeriod {
            throw LightClientError("Trusted state has expired (age: \(Int(age))s, max: \(Int(config.trustingPeriod))s)")
        }

        self.config = config

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.rpcTimeout
        self.session = URLSession(configuration: sessionConfig)

        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder.dateDecodingStrategy = .iso8601

        // Initialize with trusted state
        self.trustedState = trustedState
        self.latestKnownHeight = trustedState.header.height
        remember(height: trustedState.header.height, appHash: trustedState.header.appHash)
    }

    // MARK: - Lifecycle

    /// Starts the light client.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        if config.autoSync {
            startAutoSync()
        }
    }

    /// Stops the light client.
    public func stop() {
        isRunning = false
        syncTask?.cancel()
        syncTask = nil
    }

    private func startAutoSync() {
        syncTask = Task { [weak self] in
            while let self = self, self.isRunning {
                do {
                    try await self.sync()
                } catch {
                    self.lastSyncError = error.localizedDescription
                }

                try? await Task.sleep(nanoseconds: UInt64(self.config.syncInterval * 1_000_000_000))
            }
        }
    }

    // MARK: - Synchronization

    /// Synchronizes with the network.
    public func sync() async throws {
        lastSyncAttempt = Date()
        lastSyncError = nil

        // Get latest block from any endpoint
        let lightBlock = try await fetchLatestLightBlock()
        latestKnownHeight = lightBlock.header.height

        // If no trusted state, initialize with this block
        if trustedState == nil {
            try await initializeTrustedState(from: lightBlock)
            return
        }

        // Verify and update to the new block
        try await verifyAndUpdate(to: lightBlock)
    }

    /// Synchronizes to a specific height.
    public func syncTo(height: Int64) async throws {
        let lightBlock = try await fetchLightBlock(at: height)
        try await verifyAndUpdate(to: lightBlock)
    }

    private func initializeTrustedState(from block: LightBlock) async throws {
        // WARNING: This method trusts the first block received from the network.
        // For production use, initialize the light client with a known trusted header
        // using init(_:trustedHeader:validatorSet:) or init(_:trustedState:).

        let trustedHeader = TrustedHeader(
            height: block.header.height,
            appHash: block.header.appHash,
            trustedAt: Date(),
            headerTime: block.header.time,
            nextValidatorsHash: block.header.nextValidatorsHash,
            lastBlockId: block.header.lastBlockId
        )

        trustedState = TrustedState(
            header: trustedHeader,
            validatorSet: block.validatorSet
        )
        remember(height: trustedHeader.height, appHash: trustedHeader.appHash)
    }

    private func remember(height: Int64, appHash: String) {
        acceptedAppHashes[height] = appHash
        if acceptedAppHashes.count > Self.maxRememberedHeaders, let oldest = acceptedAppHashes.keys.min() {
            acceptedAppHashes.removeValue(forKey: oldest)
        }
    }

    private func verifyAndUpdate(to block: LightBlock) async throws {
        guard let currentState = trustedState else {
            throw LightClientError("No trusted state")
        }

        // Verify the block
        let result = try verify(block: block, trustedState: currentState)

        guard result.verified else {
            throw LightClientError("Verification failed: \(result.error ?? "unknown error")")
        }

        // Update trusted state
        let newHeader = TrustedHeader(
            height: block.header.height,
            appHash: block.header.appHash,
            trustedAt: Date(),
            headerTime: block.header.time,
            nextValidatorsHash: block.header.nextValidatorsHash,
            lastBlockId: block.header.lastBlockId
        )

        trustedState = TrustedState(
            header: newHeader,
            validatorSet: block.validatorSet
        )
        remember(height: newHeader.height, appHash: newHeader.appHash)
    }

    // MARK: - Verification

    /// Checks a light block against trusted state: the chain ID, that height
    /// and time move forward, the trusting period, clock drift, for the next
    /// height that its validators hash is the trusted header's next
    /// validators hash, and that commit signatures are present from
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

        // Check trusting period
        let headerAge = Date().timeIntervalSince(trustedState.header.trustedAt)
        guard headerAge < config.trustingPeriod else {
            return LightClientVerificationResult(
                verified: false,
                height: block.header.height,
                appHash: block.header.appHash,
                error: "Trusted state expired"
            )
        }

        // Check clock drift
        let timeDiff = abs(block.header.time.timeIntervalSince(Date()))
        guard timeDiff < config.maxClockDrift else {
            return LightClientVerificationResult(
                verified: false,
                height: block.header.height,
                appHash: block.header.appHash,
                error: "Clock drift too large: \(timeDiff)s > \(config.maxClockDrift)s"
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

    /// The app hash of the trusted header, syncing first if there is none or
    /// it has outlived the trusting period. A header at height H carries the
    /// app hash from after block H-1; to check a proof of the state after a
    /// given block, use `verifiedAppHash(atHeight:)` with the next height.
    public func getVerifiedRootHash() async throws -> String {
        // Ensure we have trusted state
        if trustedState == nil {
            try await sync()
        }

        guard let state = trustedState else {
            throw LightClientError("No trusted state available")
        }

        // Check if trusted state is still valid
        let age = Date().timeIntervalSince(state.header.trustedAt)
        if age > config.trustingPeriod {
            try await sync()
            guard let newState = trustedState else {
                throw LightClientError("Failed to sync trusted state")
            }
            return newState.header.appHash
        }

        return state.header.appHash
    }

    /// The app hash of the header at `height`, accepted the way `sync`
    /// accepts a header (see `verify(block:trustedState:)`). A header at
    /// height H carries the app hash from after block H-1, so a proof of the
    /// state after block H is checked against the header at H+1.
    ///
    /// The trusted header, or one this client accepted before, is answered
    /// from memory. A later header is fetched, waiting up to the config's
    /// `headerWaitTimeout` for the chain to produce it, checked against the
    /// trusted state, and becomes the trusted state. An earlier header can't
    /// be checked (the client moves forward only), so it throws.
    public func verifiedAppHash(atHeight height: Int64) async throws -> String {
        if trustedState == nil {
            try await sync()
        }
        guard let state = trustedState else {
            throw LightClientError("No trusted state available")
        }
        guard Date().timeIntervalSince(state.header.trustedAt) <= config.trustingPeriod else {
            throw LightClientError("The trusted header at height \(state.header.height) has outlived the trusting period")
        }
        if let appHash = acceptedAppHashes[height] {
            return appHash
        }
        guard height > state.header.height else {
            throw LightClientError(
                "The header at height \(height) is below the trusted header at height \(state.header.height); the light client checks headers only forward")
        }

        let deadline = Date().addingTimeInterval(config.headerWaitTimeout)
        while true {
            do {
                let block = try await fetchLightBlock(at: height)
                guard block.header.height == height else {
                    throw LightClientError("Asked for the header at height \(height), got one at height \(block.header.height)")
                }
                try await verifyAndUpdate(to: block)
                return block.header.appHash
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
        guard let state = trustedState else {
            throw LightClientError("No trusted state to export")
        }
        return state
    }

    /// Imports a trusted state.
    public func importTrustedState(_ state: TrustedState) throws {
        // Validate the state
        let age = Date().timeIntervalSince(state.header.trustedAt)
        if age > config.trustingPeriod {
            throw LightClientError("Imported state has expired")
        }

        trustedState = state
    }

    /// Gets the current sync status.
    public func getSyncStatus() -> SyncStatus {
        return SyncStatus(
            latestTrustedHeight: trustedState?.header.height ?? 0,
            latestTrustedTime: trustedState?.header.trustedAt ?? Date.distantPast,
            latestKnownHeight: latestKnownHeight,
            isSynced: trustedState != nil && lastSyncError == nil,
            lastSyncAttempt: lastSyncAttempt,
            lastSyncError: lastSyncError
        )
    }

    // MARK: - RPC Calls

    private func fetchLatestLightBlock() async throws -> LightBlock {
        return try await fetchLightBlock(at: nil)
    }

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
        // Fetch commit
        let commit = try await fetchCommit(from: endpoint, height: height)

        // Fetch validators
        let validators = try await fetchValidators(from: endpoint, height: height)

        // Create light block
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

        struct CommitResponse: Codable {
            let result: CommitResult
        }

        struct CommitResult: Codable {
            let signedHeader: SignedHeader

            enum CodingKeys: String, CodingKey {
                case signedHeader = "signed_header"
            }
        }

        struct SignedHeader: Codable {
            let header: Header
            let commit: Commit
        }

        let response = try decoder.decode(CommitResponse.self, from: data)
        return (response.result.signedHeader.header, response.result.signedHeader.commit)
    }

    private func fetchValidators(from endpoint: String, height: Int64?) async throws -> ValidatorSet {
        var urlString = "\(endpoint)/validators"
        if let h = height {
            urlString += "?height=\(h)"
        }

        guard let url = URL(string: urlString) else {
            throw LightClientError("Invalid endpoint URL: \(endpoint)")
        }

        let (data, _) = try await session.data(from: url)
        try Self.throwRPCError(data)

        struct ValidatorsResponse: Codable {
            let result: ValidatorsResult
        }

        struct ValidatorsResult: Codable {
            let validators: [ValidatorData]
        }

        struct ValidatorData: Codable {
            let address: String
            let pubKey: PubKey
            let votingPower: String

            enum CodingKeys: String, CodingKey {
                case address
                case pubKey = "pub_key"
                case votingPower = "voting_power"
            }
        }

        struct PubKey: Codable {
            let type: String
            let value: String
        }

        let response = try decoder.decode(ValidatorsResponse.self, from: data)

        let validators = response.result.validators.map { v in
            LightClientValidator(
                address: v.address,
                publicKey: v.pubKey.value,
                votingPower: Int64(v.votingPower) ?? 0
            )
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
