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

    /// Whether `votingPower` is at least `numerator / denominator` of
    /// `totalPower`, compared exactly (the products are 128-bit, so no power
    /// overflows). False for a negative power or numerator, a total that
    /// isn't positive, or a denominator that isn't positive.
    public func validate(votingPower: Int64, totalPower: Int64) -> Bool {
        guard numerator >= 0, denominator > 0, votingPower >= 0, totalPower > 0 else {
            return false
        }
        // votingPower * denominator >= numerator * totalPower
        let signed = votingPower.multipliedFullWidth(by: Int64(denominator))
        let needed = totalPower.multipliedFullWidth(by: Int64(numerator))
        return (signed.high, signed.low) >= (needed.high, needed.low)
    }
}

// MARK: - Light Client Configuration

/// Configuration for the light client.
public struct LightClientConfig {
    public let chainId: String
    public let validatorEndpoints: [String]
    public let trustThreshold: TrustThreshold
    /// How long a trusted header can be used to accept others, and a header
    /// to match a proof's root, counted from the header's block time (from
    /// when it was trusted, for a header given without its block time).
    public let trustingPeriod: TimeInterval
    /// How far ahead of this clock a header's time may be. A header may be
    /// any age: the header after a proof's block may be read long after it
    /// was made.
    public let maxClockDrift: TimeInterval
    /// How many of a header's validators must have a commit signature
    /// present (the signatures aren't verified) for the header to be
    /// accepted. Default 1: a chain of one validator has one.
    public let minValidatorsForConsensus: Int
    /// How many of `validatorEndpoints` must answer `/status` for
    /// `LightClient.latestChainHeight()`, which every verified read asks, to
    /// report the chain's latest height (at least 1). Default 1, so one
    /// trusted RPC serves verified reads; raise it to require that several
    /// endpoints agree.
    public let minEndpointsForLatestHeight: Int
    public let autoSync: Bool
    public let syncInterval: TimeInterval
    public let rpcTimeout: TimeInterval
    public let maxRetries: Int
    /// How long `LightClient.verifiedAppHash(atHeight:)` and
    /// `LightClient.verifyAppHash(_:forStateAfter:)` wait for a header the
    /// chain hasn't produced yet.
    public let headerWaitTimeout: TimeInterval
    /// How many blocks a verified read's proof may be from the chain's latest
    /// height (`LightClient.latestChainHeight()`): the API chooses the state
    /// it proves, so a proof of a state further behind (or a height further
    /// ahead) is refused with `ProofHeightOutOfRangeError`. See
    /// `LightClient.verifyAppHash(_:forStateAfter:)`. Default 20.
    public let maxProofLagBlocks: Int64

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
        maxRetries: Int = 3,
        headerWaitTimeout: TimeInterval = 30,
        maxProofLagBlocks: Int64 = 20,
        minEndpointsForLatestHeight: Int = 1
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
        self.headerWaitTimeout = headerWaitTimeout
        self.maxProofLagBlocks = maxProofLagBlocks
        self.minEndpointsForLatestHeight = minEndpointsForLatestHeight
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

    /// The total voting power: `totalVotingPower` when it is positive, else
    /// the sum of the validators' powers, or `Int64.max` when that sum can't
    /// be taken (see `checkedTotalVotingPower()`). It never traps.
    public func getTotalVotingPower() -> Int64 {
        if let total = totalVotingPower, total > 0 {
            return total
        }
        return (try? checkedTotalVotingPower()) ?? Int64.max
    }

    /// CometBFT's bound on a validator set's total voting power
    /// (`MaxTotalVotingPower`, `Int64.max / 8`).
    internal static let maxTotalVotingPower: Int64 = Int64.max / 8

    /// The sum of the validators' voting powers. Throws a light client error
    /// for a set CometBFT refuses: a negative power, two validators with one
    /// address (compared without case), or a total above
    /// `maxTotalVotingPower`.
    internal func checkedTotalVotingPower() throws -> Int64 {
        var total: Int64 = 0
        var addresses = Set<String>()
        for validator in validators {
            guard validator.votingPower >= 0 else {
                throw LightClientError("The validator \(validator.address) has negative voting power \(validator.votingPower)")
            }
            guard addresses.insert(validator.address.uppercased()).inserted else {
                throw LightClientError("The validator set lists \(validator.address) twice")
            }
            let (sum, overflow) = total.addingReportingOverflow(validator.votingPower)
            guard !overflow, sum <= Self.maxTotalVotingPower else {
                throw LightClientError("The validator set's total voting power exceeds \(Self.maxTotalVotingPower)")
            }
            total = sum
        }
        return total
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

    /// Reads a header as CometBFT's RPC writes one: the height as a decimal
    /// string (a number is read too) and the time as RFC 3339 text with up
    /// to nine fractional digits.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chainId = try container.decode(String.self, forKey: .chainId)
        height = try container.decodeCometInt64(forKey: .height)
        time = try container.decodeCometTime(forKey: .time)
        lastBlockId = try container.decodeIfPresent(BlockID.self, forKey: .lastBlockId)
        lastCommitHash = try container.decodeIfPresent(String.self, forKey: .lastCommitHash)
        dataHash = try container.decodeIfPresent(String.self, forKey: .dataHash)
        validatorsHash = try container.decodeIfPresent(String.self, forKey: .validatorsHash)
        nextValidatorsHash = try container.decodeIfPresent(String.self, forKey: .nextValidatorsHash)
        consensusHash = try container.decodeIfPresent(String.self, forKey: .consensusHash)
        appHash = try container.decode(String.self, forKey: .appHash)
        lastResultsHash = try container.decodeIfPresent(String.self, forKey: .lastResultsHash)
        evidenceHash = try container.decodeIfPresent(String.self, forKey: .evidenceHash)
        proposerAddress = try container.decodeIfPresent(String.self, forKey: .proposerAddress)
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

    /// Reads a signature as CometBFT's RPC writes one. An absent signature's
    /// timestamp (CometBFT writes the zero time) reads as nil if it isn't
    /// RFC 3339 text.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockIdFlag = try container.decode(Int.self, forKey: .blockIdFlag)
        validatorAddress = try container.decodeIfPresent(String.self, forKey: .validatorAddress)
        if let text = try? container.decodeIfPresent(String.self, forKey: .timestamp) {
            timestamp = RFC3339.date(from: text)
        } else {
            timestamp = nil
        }
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
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

    /// Reads a commit as CometBFT's RPC writes one: the height as a decimal
    /// string (a number is read too).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        height = try container.decodeCometInt64(forKey: .height)
        round = try container.decode(Int.self, forKey: .round)
        blockId = try container.decodeIfPresent(BlockID.self, forKey: .blockId)
        signatures = try container.decodeIfPresent([CommitSig].self, forKey: .signatures)
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
    /// When this process (or the one that exported it) trusted the header.
    public let trustedAt: Date
    /// The header's block time. The trusting period runs from it; without
    /// it, from `trustedAt`.
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

    /// Where the trusting period runs from: the header's block time, or when
    /// it was trusted if that isn't known.
    internal var trustingPeriodStart: Date {
        return headerTime ?? trustedAt
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

// MARK: - Verified Header

/// The header whose app hash a verified read's proof root matched.
///
/// A header at height `height` carries the chain's state after block
/// `height - 1`. A verified read proves its value as of that state, not as
/// of now: the value held after block `height - 1`, and may have changed
/// since. `LightClient.verifyAppHash(_:forStateAfter:)` matches a root to the
/// newest header it knows that carries it, no more than
/// `LightClientConfig.maxProofLagBlocks` blocks behind the chain's latest
/// height.
public struct VerifiedHeader: Codable, Equatable {
    /// The header's height. It carries the state after block `height - 1`.
    public let height: Int64
    /// The header's block time, when known (a header pinned without its
    /// block time has none).
    public let time: Date?
    /// The header's app hash, the root the proof hashes to.
    public let appHash: String

    enum CodingKeys: String, CodingKey {
        case height
        case time
        case appHash = "app_hash"
    }

    public init(height: Int64, time: Date?, appHash: String) {
        self.height = height
        self.time = time
        self.appHash = appHash
    }

    init(_ header: TrustedHeader) {
        self.init(height: header.height, time: header.headerTime, appHash: header.appHash)
    }
}

// MARK: - Verification Result

/// Result of `LightClient.verify(block:trustedState:)`.
public struct LightClientVerificationResult {
    /// Whether the block passed the light client's consistency checks. It
    /// doesn't mean the commit's signatures verify: they aren't checked.
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

// MARK: - CometBFT JSON

extension KeyedDecodingContainer {
    /// An int64, which CometBFT's JSON writes as a decimal string.
    func decodeCometInt64(forKey key: Key) throws -> Int64 {
        if let text = try? decode(String.self, forKey: key) {
            guard let value = Int64(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not an int64: \(text)")
            }
            return value
        }
        return try decode(Int64.self, forKey: key)
    }

    /// A time, which CometBFT's JSON writes as RFC 3339 text; anything else
    /// is read with the decoder's date strategy.
    func decodeCometTime(forKey key: Key) throws -> Date {
        if let text = try? decode(String.self, forKey: key) {
            guard let date = RFC3339.date(from: text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not an RFC 3339 time: \(text)")
            }
            return date
        }
        return try decode(Date.self, forKey: key)
    }
}

/// RFC 3339 times as CometBFT writes them: `YYYY-MM-DDTHH:MM:SS`, an optional
/// fraction of any length, and `Z` or a `+HH:MM` / `-HH:MM` offset.
internal enum RFC3339 {
    static func date(from text: String) -> Date? {
        let b = Array(text.utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= b.count else { return nil }
            var value = 0
            for i in range {
                guard (0x30...0x39).contains(b[i]) else { return nil }
                value = value * 10 + Int(b[i] - 0x30)
            }
            return value
        }
        guard b.count >= 20, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              b[10] == UInt8(ascii: "T") || b[10] == UInt8(ascii: "t"),
              b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second <= 60 else {
            return nil
        }
        var i = 19
        var fraction = 0.0
        if b[i] == UInt8(ascii: ".") {
            i += 1
            let start = i
            while i < b.count, (0x30...0x39).contains(b[i]) {
                i += 1
            }
            guard i > start, let value = Double("0." + String(decoding: b[start..<i], as: UTF8.self)) else { return nil }
            fraction = value
        }
        guard i < b.count else { return nil }
        var offset = 0
        switch b[i] {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            i += 1
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            guard i + 6 <= b.count, b[i + 3] == UInt8(ascii: ":"),
                  let hours = number((i + 1)..<(i + 3)), let minutes = number((i + 4)..<(i + 6)) else {
                return nil
            }
            offset = (hours * 3600 + minutes * 60) * (b[i] == UInt8(ascii: "-") ? -1 : 1)
            i += 6
        default:
            return nil
        }
        guard i == b.count else { return nil }

        // Days from 1970-01-01 to the civil date (proleptic Gregorian).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds) + fraction)
    }
}
