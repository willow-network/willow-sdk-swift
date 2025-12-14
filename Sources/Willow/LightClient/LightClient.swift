import Foundation

// MARK: - Light Client

/// Light client for trustless verification of Willow data.
public class LightClient {
    private let config: LightClientConfig
    private let session: URLSession
    private let decoder: JSONDecoder

    private var trustedState: TrustedState?
    private var syncTask: Task<Void, Never>?
    private var isRunning = false

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
    }

    // MARK: - Verification

    /// Verifies a light block against trusted state.
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

    /// Gets the verified root hash (app_hash).
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
}
