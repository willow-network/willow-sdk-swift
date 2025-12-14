import Foundation

// MARK: - Trust Threshold

/// Trust threshold for validator verification.
public struct TrustThreshold {
    public let numerator: Int
    public let denominator: Int

    public init(numerator: Int = 2, denominator: Int = 3) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Validates that voting power meets the threshold.
    public func validate(votingPower: Int64, totalPower: Int64) -> Bool {
        // votingPower / totalPower >= numerator / denominator
        // votingPower * denominator >= numerator * totalPower
        return votingPower * Int64(denominator) >= Int64(numerator) * totalPower
    }
}

// MARK: - Light Client Configuration

/// Configuration for the light client.
public struct LightClientConfig {
    public let chainId: String
    public let validatorEndpoints: [String]
    public let trustThreshold: TrustThreshold
    public let trustingPeriod: TimeInterval
    public let maxClockDrift: TimeInterval
    public let minValidatorsForConsensus: Int
    public let autoSync: Bool
    public let syncInterval: TimeInterval
    public let rpcTimeout: TimeInterval
    public let maxRetries: Int

    public init(
        chainId: String,
        validatorEndpoints: [String],
        trustThreshold: TrustThreshold = TrustThreshold(),
        trustingPeriod: TimeInterval = 24 * 60 * 60, // 24 hours
        maxClockDrift: TimeInterval = 10, // 10 seconds
        minValidatorsForConsensus: Int = 1,
        autoSync: Bool = true,
        syncInterval: TimeInterval = 5 * 60, // 5 minutes
        rpcTimeout: TimeInterval = 10,
        maxRetries: Int = 3
    ) {
        self.chainId = chainId
        self.validatorEndpoints = validatorEndpoints
        self.trustThreshold = trustThreshold
        self.trustingPeriod = trustingPeriod
        self.maxClockDrift = maxClockDrift
        self.minValidatorsForConsensus = minValidatorsForConsensus
        self.autoSync = autoSync
        self.syncInterval = syncInterval
        self.rpcTimeout = rpcTimeout
        self.maxRetries = maxRetries
    }

    public static var `default`: LightClientConfig {
        return LightClientConfig(chainId: "willow-1", validatorEndpoints: [])
    }
}

// MARK: - Validator

/// A validator in the network.
public struct LightClientValidator: Codable, Equatable {
    public let address: String
    public let publicKey: String
    public let votingPower: Int64

    enum CodingKeys: String, CodingKey {
        case address
        case publicKey = "pub_key"
        case votingPower = "voting_power"
    }

    public init(address: String, publicKey: String, votingPower: Int64) {
        self.address = address
        self.publicKey = publicKey
        self.votingPower = votingPower
    }
}

// MARK: - Validator Set

/// A set of validators.
public struct ValidatorSet: Codable {
    public let validators: [LightClientValidator]
    public let totalVotingPower: Int64?

    enum CodingKeys: String, CodingKey {
        case validators
        case totalVotingPower = "total_voting_power"
    }

    public init(validators: [LightClientValidator], totalVotingPower: Int64? = nil) {
        self.validators = validators
        self.totalVotingPower = totalVotingPower
    }

    /// Gets the total voting power, calculating if not stored.
    public func getTotalVotingPower() -> Int64 {
        if let total = totalVotingPower, total > 0 {
            return total
        }
        return validators.reduce(0) { $0 + $1.votingPower }
    }
}

// MARK: - Block ID

/// A block identifier.
public struct BlockID: Codable, Equatable {
    public let hash: String
    public let partSetHeader: PartSetHeader?

    enum CodingKeys: String, CodingKey {
        case hash
        case partSetHeader = "parts"
    }

    public init(hash: String, partSetHeader: PartSetHeader? = nil) {
        self.hash = hash
        self.partSetHeader = partSetHeader
    }
}

/// Part set header.
public struct PartSetHeader: Codable, Equatable {
    public let total: Int
    public let hash: String
}

// MARK: - Header

/// A block header.
public struct Header: Codable {
    public let chainId: String
    public let height: Int64
    public let time: Date
    public let lastBlockId: BlockID?
    public let lastCommitHash: String?
    public let dataHash: String?
    public let validatorsHash: String?
    public let nextValidatorsHash: String?
    public let consensusHash: String?
    public let appHash: String
    public let lastResultsHash: String?
    public let evidenceHash: String?
    public let proposerAddress: String?

    enum CodingKeys: String, CodingKey {
        case chainId = "chain_id"
        case height
        case time
        case lastBlockId = "last_block_id"
        case lastCommitHash = "last_commit_hash"
        case dataHash = "data_hash"
        case validatorsHash = "validators_hash"
        case nextValidatorsHash = "next_validators_hash"
        case consensusHash = "consensus_hash"
        case appHash = "app_hash"
        case lastResultsHash = "last_results_hash"
        case evidenceHash = "evidence_hash"
        case proposerAddress = "proposer_address"
    }

    public init(chainId: String, height: Int64, time: Date, appHash: String) {
        self.chainId = chainId
        self.height = height
        self.time = time
        self.lastBlockId = nil
        self.lastCommitHash = nil
        self.dataHash = nil
        self.validatorsHash = nil
        self.nextValidatorsHash = nil
        self.consensusHash = nil
        self.appHash = appHash
        self.lastResultsHash = nil
        self.evidenceHash = nil
        self.proposerAddress = nil
    }
}

// MARK: - Commit Signature

/// A commit signature.
public struct CommitSig: Codable {
    public let blockIdFlag: Int
    public let validatorAddress: String?
    public let timestamp: Date?
    public let signature: String?

    enum CodingKeys: String, CodingKey {
        case blockIdFlag = "block_id_flag"
        case validatorAddress = "validator_address"
        case timestamp
        case signature
    }

    /// Returns true if this is an absent signature.
    public var isAbsent: Bool {
        return blockIdFlag == 1
    }

    /// Returns true if this is a commit signature.
    public var isCommit: Bool {
        return blockIdFlag == 2
    }
}

// MARK: - Commit

/// A block commit.
public struct Commit: Codable {
    public let height: Int64
    public let round: Int
    public let blockId: BlockID?
    public let signatures: [CommitSig]?

    enum CodingKeys: String, CodingKey {
        case height
        case round
        case blockId = "block_id"
        case signatures
    }

    public init(height: Int64, round: Int, blockId: BlockID? = nil, signatures: [CommitSig]? = nil) {
        self.height = height
        self.round = round
        self.blockId = blockId
        self.signatures = signatures
    }
}

// MARK: - Light Block

/// A light block containing header, validators, and commit.
public struct LightBlock: Codable {
    public let header: Header
    public let validatorSet: ValidatorSet
    public let commit: Commit

    enum CodingKeys: String, CodingKey {
        case header
        case validatorSet = "validator_set"
        case commit
    }
}

// MARK: - Trusted Header

/// A trusted header with verification timestamp.
public struct TrustedHeader: Codable {
    public let height: Int64
    public let appHash: String
    public let trustedAt: Date
    public let headerTime: Date?
    public let nextValidatorsHash: String?
    public let lastBlockId: BlockID?

    enum CodingKeys: String, CodingKey {
        case height
        case appHash = "app_hash"
        case trustedAt = "trusted_at"
        case headerTime = "header_time"
        case nextValidatorsHash = "next_validators_hash"
        case lastBlockId = "last_block_id"
    }

    public init(height: Int64, appHash: String, trustedAt: Date = Date(), headerTime: Date? = nil, nextValidatorsHash: String? = nil, lastBlockId: BlockID? = nil) {
        self.height = height
        self.appHash = appHash
        self.trustedAt = trustedAt
        self.headerTime = headerTime
        self.nextValidatorsHash = nextValidatorsHash
        self.lastBlockId = lastBlockId
    }
}

// MARK: - Trusted State

/// Complete trusted state for persistence.
public struct TrustedState: Codable {
    public let header: TrustedHeader
    public let validatorSet: ValidatorSet

    public init(header: TrustedHeader, validatorSet: ValidatorSet) {
        self.header = header
        self.validatorSet = validatorSet
    }
}

// MARK: - Verification Result

/// Result of header verification.
public struct LightClientVerificationResult {
    public let verified: Bool
    public let height: Int64
    public let appHash: String
    public let votingPower: Int64
    public let totalPower: Int64
    public let signatureCount: Int
    public let error: String?

    public init(verified: Bool, height: Int64, appHash: String, votingPower: Int64 = 0, totalPower: Int64 = 0, signatureCount: Int = 0, error: String? = nil) {
        self.verified = verified
        self.height = height
        self.appHash = appHash
        self.votingPower = votingPower
        self.totalPower = totalPower
        self.signatureCount = signatureCount
        self.error = error
    }
}

// MARK: - Sync Status

/// Current synchronization status.
public struct SyncStatus {
    public let latestTrustedHeight: Int64
    public let latestTrustedTime: Date
    public let latestKnownHeight: Int64
    public let isSynced: Bool
    public let lastSyncAttempt: Date?
    public let lastSyncError: String?

    public init(latestTrustedHeight: Int64 = 0, latestTrustedTime: Date = Date(), latestKnownHeight: Int64 = 0, isSynced: Bool = false, lastSyncAttempt: Date? = nil, lastSyncError: String? = nil) {
        self.latestTrustedHeight = latestTrustedHeight
        self.latestTrustedTime = latestTrustedTime
        self.latestKnownHeight = latestKnownHeight
        self.isSynced = isSynced
        self.lastSyncAttempt = lastSyncAttempt
        self.lastSyncError = lastSyncError
    }
}

// MARK: - Proof Verification Result

/// Result of proof verification.
public struct ProofVerificationResult {
    public let verified: Bool
    public let rootHash: String
    public let expectedHash: String
    public let height: Int64
    public let error: String?

    public init(verified: Bool, rootHash: String, expectedHash: String, height: Int64 = 0, error: String? = nil) {
        self.verified = verified
        self.rootHash = rootHash
        self.expectedHash = expectedHash
        self.height = height
        self.error = error
    }
}
