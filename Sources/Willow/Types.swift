import Foundation

// MARK: - Signature Algorithms

/// Cryptographic algorithm used for signatures.
public enum SignatureAlgorithm: String, Codable {
    case ed25519 = "Ed25519"
    case secp256k1 = "secp256k1"

    /// Returns the DID key type string for this algorithm.
    public var keyType: String {
        switch self {
        case .ed25519:
            return "Ed25519VerificationKey2018"
        case .secp256k1:
            return "EcdsaSecp256k1VerificationKey2019"
        }
    }

    /// Multicodec prefix bytes prepended to the public key before hashing when
    /// deriving a self-certifying `did:willow` identifier.
    ///
    /// - Ed25519:   `0xED 0x01`
    /// - secp256k1: `0xE7 0x01`
    public var multicodecPrefix: [UInt8] {
        switch self {
        case .ed25519:
            return [0xED, 0x01]
        case .secp256k1:
            return [0xE7, 0x01]
        }
    }
}

// MARK: - DID Types

/// A public key in a DID document.
public struct PublicKey: Codable, Equatable {
    public let id: String
    public let type: String
    public let publicKeyHex: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case publicKeyHex = "public_key_hex"
    }

    public init(id: String, type: String, publicKeyHex: String?) {
        self.id = id
        self.type = type
        self.publicKeyHex = publicKeyHex
    }
}

/// A DID (Decentralized Identifier) document.
public struct DidDocument: Codable, Equatable {
    public let id: String
    public let publicKeys: [PublicKey]
    public let created: Int64
    public let updated: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case publicKeys = "public_keys"
        case created
        case updated
    }

    public init(id: String, publicKeys: [PublicKey], created: Int64, updated: Int64) {
        self.id = id
        self.publicKeys = publicKeys
        self.created = created
        self.updated = updated
    }
}

/// Information about a DID including its balance.
public struct DidInfo: Codable {
    public let did: String
    public let document: DidDocument?
    public let balance: UInt64
    public let nonce: UInt64
    public let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case did
        case document
        case balance
        case nonce
        case createdAt = "created_at"
    }
}

// MARK: - Schema Types

/// A field in a schema.
public struct SchemaField: Codable, Equatable {
    public let name: String
    public let type: String
    public let required: Bool
    public let indexed: Bool

    public init(name: String, type: String, required: Bool = false, indexed: Bool = false) {
        self.name = name
        self.type = type
        self.required = required
        self.indexed = indexed
    }
}

/// Type of index.
public enum IndexType: String, Codable {
    case hash = "hash"
    case range = "range"
    case fulltext = "fulltext"
    case inverted = "inverted"
}

/// An index definition on a schema.
public struct IndexDefinition: Codable, Equatable {
    public let name: String
    public let fields: [String]
    public let type: IndexType
    public let unique: Bool

    public init(name: String, fields: [String], type: IndexType, unique: Bool = false) {
        self.name = name
        self.fields = fields
        self.type = type
        self.unique = unique
    }
}

/// Schema definition for a subgrove.
public struct SchemaDefinition: Codable, Equatable {
    public let name: String
    public let description: String?
    public let fields: [SchemaField]
    public let indexes: [IndexDefinition]

    public init(name: String, description: String? = nil, fields: [SchemaField] = [], indexes: [IndexDefinition] = []) {
        self.name = name
        self.description = description
        self.fields = fields
        self.indexes = indexes
    }
}

// MARK: - Subgrove Types

/// Request to register a new subgrove.
public struct RegisterSubgroveRequest: Codable {
    public var subgroveId: String
    public var name: String
    public var description: String?
    public var schema: SchemaDefinition
    public var ownerDid: String
    public var writers: [String]
    public var readers: [String]
    public var rewardRate: UInt64
    public var retentionWindow: RetentionWindow?

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case name
        case description
        case schema
        case ownerDid = "owner_did"
        case writers
        case readers
        case rewardRate = "reward_rate"
        case retentionWindow = "retention_window"
    }

    public init(subgroveId: String, name: String, description: String? = nil, schema: SchemaDefinition = SchemaDefinition(name: ""), ownerDid: String = "", writers: [String] = [], readers: [String] = [], rewardRate: UInt64 = 0, retentionWindow: RetentionWindow? = nil) {
        self.subgroveId = subgroveId
        self.name = name
        self.description = description
        self.schema = schema
        self.ownerDid = ownerDid
        self.writers = writers
        self.readers = readers
        self.rewardRate = rewardRate
        self.retentionWindow = retentionWindow
    }
}

/// The document schema a subgrove registers, as the node reads it: field
/// names mapped to types ("string", "number", "boolean", "array", "object",
/// or "bytes"), indexes, and required fields. The node refuses a DataStorage
/// or FileStorage registration whose schema declares indexes.
public struct SubgroveSchema: Codable, Equatable {
    public struct Index: Codable, Equatable {
        public let name: String
        public let fields: [String]
        public let unique: Bool

        public init(name: String, fields: [String], unique: Bool = false) {
            self.name = name
            self.fields = fields
            self.unique = unique
        }
    }

    public let version: UInt32
    public let fields: [String: String]
    public let indexes: [Index]
    public let requiredFields: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case fields
        case indexes
        case requiredFields = "required_fields"
    }

    public init(version: UInt32 = 1, fields: [String: String] = [:], indexes: [Index] = [], requiredFields: [String] = []) {
        self.version = version
        self.fields = fields
        self.indexes = indexes
        self.requiredFields = requiredFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(UInt32.self, forKey: .version) ?? 1
        fields = try container.decodeIfPresent([String: String].self, forKey: .fields) ?? [:]
        indexes = try container.decodeIfPresent([Index].self, forKey: .indexes) ?? []
        requiredFields = try container.decodeIfPresent([String].self, forKey: .requiredFields) ?? []
    }

    /// `definition` in the node's form. A field's type maps to the node's
    /// ("int", "float", and "number" to number; "bool" to boolean; "array" and
    /// "array:<item>" to array); a required field is listed in
    /// `requiredFields`. The node keeps no per-field index flag and no index
    /// type, so `SchemaField.indexed` and `IndexDefinition.type` are not
    /// carried. Throws a validation error for a type the node has no match for.
    public init(_ definition: SchemaDefinition) throws {
        var fields: [String: String] = [:]
        for field in definition.fields {
            let type = field.type.lowercased()
            switch type {
            case "string", "number", "object", "bytes", "boolean":
                fields[field.name] = type
            case "int", "integer", "float", "double":
                fields[field.name] = "number"
            case "bool":
                fields[field.name] = "boolean"
            case _ where type == "array" || type.hasPrefix("array:"):
                fields[field.name] = "array"
            default:
                throw ValidationError("Schema field \(field.name) has type \(field.type), which the node has no match for")
            }
        }
        self.init(
            version: 1,
            fields: fields,
            indexes: definition.indexes.map { Index(name: $0.name, fields: $0.fields, unique: $0.unique) },
            requiredFields: definition.fields.filter { $0.required }.map { $0.name }
        )
    }

    /// The schema as the JSON text a registration carries, keys sorted.
    public func jsonText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// A registered subgrove as `GET /subgroves` lists it.
public struct SubgroveRegistration: Codable {
    public let subgroveId: String
    public let name: String
    public let description: String
    public let admins: [String]
    public let schema: SubgroveSchema
    public let ownerDid: String
    public let writers: [String]
    public let freeReaders: [String]
    public let readPricing: ReadPricing?
    public let privacy: PrivacyConfig?
    public let retentionWindow: RetentionWindow?
    public let confirmationDepth: UInt32
    public let createdAt: UInt64
    public let updatedAt: UInt64
    /// "DataStorage" or "BlockchainIndexing".
    public let mode: String?
    public let chain: String?
    public let indexerCount: Int?

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case name
        case description
        case admins
        case schema
        case ownerDid = "owner_did"
        case writers
        case freeReaders = "free_readers"
        case readPricing = "read_pricing"
        case privacy
        case retentionWindow = "retention_window"
        case confirmationDepth = "confirmation_depth"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case mode
        case chain
        case indexerCount = "indexer_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subgroveId = try container.decode(String.self, forKey: .subgroveId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        admins = try container.decodeIfPresent([String].self, forKey: .admins) ?? []
        schema = try container.decode(SubgroveSchema.self, forKey: .schema)
        ownerDid = try container.decode(String.self, forKey: .ownerDid)
        writers = try container.decodeIfPresent([String].self, forKey: .writers) ?? []
        freeReaders = try container.decodeIfPresent([String].self, forKey: .freeReaders) ?? []
        readPricing = try container.decodeIfPresent(ReadPricing.self, forKey: .readPricing)
        privacy = try container.decodeIfPresent(PrivacyConfig.self, forKey: .privacy)
        retentionWindow = try container.decodeIfPresent(RetentionWindow.self, forKey: .retentionWindow)
        confirmationDepth = try container.decodeIfPresent(UInt32.self, forKey: .confirmationDepth) ?? 0
        createdAt = try container.decode(UInt64.self, forKey: .createdAt)
        updatedAt = try container.decode(UInt64.self, forKey: .updatedAt)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        chain = try container.decodeIfPresent(String.self, forKey: .chain)
        indexerCount = try container.decodeIfPresent(Int.self, forKey: .indexerCount)
    }
}

// MARK: - Token Types

/// Information about the WILL token (`GET /token/info`). Supplies are in the
/// token's smallest unit, as decimal digits (they exceed `UInt64`).
public struct TokenInfo: Codable {
    public let name: String
    public let symbol: String
    public let decimals: UInt8
    public let genesisSupply: String
    public let mintedSupply: String
    public let maxSupply: String
    public let circulatingSupply: String

    enum CodingKeys: String, CodingKey {
        case name
        case symbol
        case decimals
        case genesisSupply = "genesis_supply"
        case mintedSupply = "minted_supply"
        case maxSupply = "max_supply"
        case circulatingSupply = "circulating_supply"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)
        decimals = try container.decode(UInt8.self, forKey: .decimals)
        genesisSupply = try container.decodeAmount(forKey: .genesisSupply)
        mintedSupply = try container.decodeAmount(forKey: .mintedSupply)
        maxSupply = try container.decodeAmount(forKey: .maxSupply)
        circulatingSupply = try container.decodeAmount(forKey: .circulatingSupply)
    }
}

/// A DID's balance (`GET /token/balance/{did}`), in the token's smallest
/// unit, as decimal digits. An account the chain doesn't know reads as zeros.
public struct BalanceInfo: Codable {
    public let did: String
    public let available: String
    public let staked: String
    public let locked: String

    enum CodingKeys: String, CodingKey {
        case did
        case available
        case staked
        case locked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        did = try container.decode(String.self, forKey: .did)
        available = try container.decodeAmount(forKey: .available)
        staked = try container.decodeAmount(forKey: .staked)
        locked = try container.decodeAmount(forKey: .locked)
    }
}

/// Fee schedule for operations.
public struct FeeSchedule: Codable {
    public let didRegistration: String
    public let subgroveRegistration: String
    public let baseTxCost: String
    public let costPerByte: String
    public let queryFee: String
    public let transferFeePercentage: UInt32
    public let maxTxSizeBytes: UInt64
    public let maxDataPayloadBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case didRegistration = "did_registration"
        case subgroveRegistration = "subgrove_registration"
        case baseTxCost = "base_tx_cost"
        case costPerByte = "cost_per_byte"
        case queryFee = "query_fee"
        case transferFeePercentage = "transfer_fee_percentage"
        case maxTxSizeBytes = "max_tx_size_bytes"
        case maxDataPayloadBytes = "max_data_payload_bytes"
    }

    /// The API serves the amounts as JSON integers (u128, beyond `UInt64` for
    /// some), so each is read as a string or an integer and kept as its digits.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        didRegistration = try container.decodeAmount(forKey: .didRegistration)
        subgroveRegistration = try container.decodeAmount(forKey: .subgroveRegistration)
        baseTxCost = try container.decodeAmount(forKey: .baseTxCost)
        costPerByte = try container.decodeAmount(forKey: .costPerByte)
        queryFee = try container.decodeAmount(forKey: .queryFee)
        transferFeePercentage = try container.decode(UInt32.self, forKey: .transferFeePercentage)
        maxTxSizeBytes = try container.decode(UInt64.self, forKey: .maxTxSizeBytes)
        maxDataPayloadBytes = try container.decode(UInt64.self, forKey: .maxDataPayloadBytes)
    }
}

extension KeyedDecodingContainer {
    /// A token amount the API serves as a JSON integer (a u128, beyond
    /// `UInt64` for some) or a decimal string, kept as its digits.
    func decodeAmount(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        if let integer = try? decode(UInt64.self, forKey: key) {
            return String(integer)
        }
        let decimal = try decode(Decimal.self, forKey: key)
        guard decimal.isFinite, decimal >= 0, decimal == decimal.wholePart() else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not a whole amount")
        }
        return NSDecimalNumber(decimal: decimal).stringValue
    }
}

private extension Decimal {
    func wholePart() -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }
}

// MARK: - Validator Types

/// Status of a validator.
public enum ValidatorStatus: String, Codable {
    case active = "active"
    case inactive = "inactive"
    case jailed = "jailed"
}

/// A validator as `GET /validators` and `GET /validators/{did}` serve it.
/// Stakes are in the token's smallest unit, as decimal digits.
public struct ValidatorInfo: Codable {
    public let did: String
    public let totalStake: String
    public let selfStake: String
    public let active: Bool
    public let jailed: Bool
    /// When a jailed validator's jail ends (Unix seconds).
    public let jailEndTime: UInt64?
    public let consensusPubkey: String?

    enum CodingKeys: String, CodingKey {
        case did
        case totalStake = "total_stake"
        case selfStake = "self_stake"
        case active
        case jailed
        case jailEndTime = "jail_end_time"
        case consensusPubkey = "consensus_pubkey"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        did = try container.decode(String.self, forKey: .did)
        totalStake = try container.decodeAmount(forKey: .totalStake)
        selfStake = try container.decodeAmount(forKey: .selfStake)
        active = try container.decode(Bool.self, forKey: .active)
        jailed = try container.decode(Bool.self, forKey: .jailed)
        jailEndTime = try container.decodeIfPresent(UInt64.self, forKey: .jailEndTime)
        consensusPubkey = try container.decodeIfPresent(String.self, forKey: .consensusPubkey)
    }

    /// Jailed, active, or inactive.
    public var status: ValidatorStatus {
        if jailed { return .jailed }
        return active ? .active : .inactive
    }
}

// MARK: - Query Types

/// A filter condition for queries.
public struct QueryFilter: Codable {
    public let field: String
    public let `operator`: String
    public let value: AnyCodable

    public init(field: String, operator: String, value: Any) {
        self.field = field
        self.operator = `operator`
        self.value = AnyCodable(value)
    }
}

/// Sorting options for queries.
public struct QuerySort: Codable {
    public let field: String
    public let ascending: Bool

    public init(field: String, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }
}

/// Full-text search options.
public struct QuerySearch: Codable {
    public let fields: [String]
    public let query: String

    public init(fields: [String], query: String) {
        self.fields = fields
        self.query = query
    }
}

/// A query request.
public struct QueryRequest: Codable {
    public var filters: [QueryFilter]
    public var search: QuerySearch?
    public var sort: QuerySort?
    public var limit: Int?
    public var offset: Int?
    public var includeProof: Bool

    enum CodingKeys: String, CodingKey {
        case filters
        case search
        case sort
        case limit
        case offset
        case includeProof = "include_proof"
    }

    public init(filters: [QueryFilter] = [], search: QuerySearch? = nil, sort: QuerySort? = nil, limit: Int? = nil, offset: Int? = nil, includeProof: Bool = false) {
        self.filters = filters
        self.search = search
        self.sort = sort
        self.limit = limit
        self.offset = offset
        self.includeProof = includeProof
    }
}

/// A single result from a query.
public struct QueryResult: Codable {
    /// The document's key. `POST /query` returns documents without their keys,
    /// so this is empty for its results.
    public let key: String
    public let data: [String: AnyCodable]
}

/// Response to a query: the `data` of `POST /query/{subgroveId}`, which is
/// `{ documents, total, offset, limit, proof?, height? }`.
public struct QueryResponse {
    public let results: [QueryResult]
    public let totalCount: Int
    public let hasMore: Bool
    /// The GroveDB proof, when one was asked for (served as hex).
    public let proof: Data?
}

extension QueryResponse: Codable {
    enum CodingKeys: String, CodingKey {
        case documents
        case total
        case offset
        case proof
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let documents = try container.decodeIfPresent([AnyCodable].self, forKey: .documents) ?? []
        results = try documents.map { document in
            guard let object = document.value as? [String: Any] else {
                throw DecodingError.dataCorruptedError(
                    forKey: .documents, in: container, debugDescription: "A query document is not a JSON object")
            }
            return QueryResult(key: "", data: object.mapValues { AnyCodable($0) })
        }
        totalCount = try container.decodeIfPresent(Int.self, forKey: .total) ?? results.count
        let offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        hasMore = offset + results.count < totalCount
        if let hex = try container.decodeIfPresent(String.self, forKey: .proof) {
            let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
            guard let bytes = Data(hexString: clean) else {
                throw DecodingError.dataCorruptedError(forKey: .proof, in: container, debugDescription: "The proof is not hex")
            }
            proof = bytes
        } else {
            proof = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(results.map { AnyCodable($0.data.mapValues { $0.value }) }, forKey: .documents)
        try container.encode(totalCount, forKey: .total)
        try container.encodeIfPresent(proof?.hexString, forKey: .proof)
    }
}

// MARK: - Historical Query Types

/// A request for historical checkpoint data.
public struct HistoricalQueryRequest: Codable {
    public var path: [[UInt8]]
    public var key: [UInt8]?
    public var queryType: String?
    public var includeProof: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case key
        case queryType = "query_type"
        case includeProof = "include_proof"
    }

    public init(path: [[UInt8]], key: [UInt8]? = nil, queryType: String? = nil, includeProof: Bool = false) {
        self.path = path
        self.key = key
        self.queryType = queryType
        self.includeProof = includeProof
    }
}

/// Response from a historical query.
public struct HistoricalQueryResponse: Codable {
    public let success: Bool
    public let providerDid: String?
    public let providerEndpoint: String?
    public let stateRoot: String
    public let blockRange: (UInt64, UInt64)
    public let data: AnyCodable
    public let proof: String?
    public let canReindex: Bool?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case success
        case providerDid = "provider_did"
        case providerEndpoint = "provider_endpoint"
        case stateRoot = "state_root"
        case blockRange = "block_range"
        case data
        case proof
        case canReindex = "can_reindex"
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        providerDid = try container.decodeIfPresent(String.self, forKey: .providerDid)
        providerEndpoint = try container.decodeIfPresent(String.self, forKey: .providerEndpoint)
        stateRoot = try container.decode(String.self, forKey: .stateRoot)
        data = try container.decode(AnyCodable.self, forKey: .data)
        proof = try container.decodeIfPresent(String.self, forKey: .proof)
        canReindex = try container.decodeIfPresent(Bool.self, forKey: .canReindex)
        error = try container.decodeIfPresent(String.self, forKey: .error)

        // Decode block_range as array of two UInt64
        let blockRangeArray = try container.decode([UInt64].self, forKey: .blockRange)
        guard blockRangeArray.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .blockRange, in: container, debugDescription: "Expected array of 2 elements for block_range")
        }
        blockRange = (blockRangeArray[0], blockRangeArray[1])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(success, forKey: .success)
        try container.encodeIfPresent(providerDid, forKey: .providerDid)
        try container.encodeIfPresent(providerEndpoint, forKey: .providerEndpoint)
        try container.encode(stateRoot, forKey: .stateRoot)
        try container.encode([blockRange.0, blockRange.1], forKey: .blockRange)
        try container.encode(data, forKey: .data)
        try container.encodeIfPresent(proof, forKey: .proof)
        try container.encodeIfPresent(canReindex, forKey: .canReindex)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// Information about a checkpoint.
public struct CheckpointInfo: Codable {
    public let checkpointId: String
    public let subgroveId: String
    public let stateRoot: String
    public let blockRange: (UInt64, UInt64)
    public let indexerDid: String?
    public let submittedAt: UInt64?
    public let isTrusted: Bool

    enum CodingKeys: String, CodingKey {
        case checkpointId = "checkpoint_id"
        case subgroveId = "subgrove_id"
        case stateRoot = "state_root"
        case blockRange = "block_range"
        case indexerDid = "indexer_did"
        case submittedAt = "submitted_at"
        case isTrusted = "is_trusted"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checkpointId = try container.decode(String.self, forKey: .checkpointId)
        subgroveId = try container.decode(String.self, forKey: .subgroveId)
        stateRoot = try container.decode(String.self, forKey: .stateRoot)
        indexerDid = try container.decodeIfPresent(String.self, forKey: .indexerDid)
        submittedAt = try container.decodeIfPresent(UInt64.self, forKey: .submittedAt)
        isTrusted = try container.decode(Bool.self, forKey: .isTrusted)

        // Decode block_range as array of two UInt64
        let blockRangeArray = try container.decode([UInt64].self, forKey: .blockRange)
        guard blockRangeArray.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .blockRange, in: container, debugDescription: "Expected array of 2 elements for block_range")
        }
        blockRange = (blockRangeArray[0], blockRangeArray[1])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(checkpointId, forKey: .checkpointId)
        try container.encode(subgroveId, forKey: .subgroveId)
        try container.encode(stateRoot, forKey: .stateRoot)
        try container.encode([blockRange.0, blockRange.1], forKey: .blockRange)
        try container.encodeIfPresent(indexerDid, forKey: .indexerDid)
        try container.encodeIfPresent(submittedAt, forKey: .submittedAt)
        try container.encode(isTrusted, forKey: .isTrusted)
    }
}

// MARK: - GraphQL Types

/// A GraphQL query request.
public struct GraphQLRequest: Codable {
    public var query: String
    public var variables: [String: AnyCodable]?
    public var operationName: String?
    public var includeProof: Bool

    enum CodingKeys: String, CodingKey {
        case query
        case variables
        case operationName = "operation_name"
        case includeProof = "include_proof"
    }

    public init(query: String, variables: [String: AnyCodable]? = nil, operationName: String? = nil, includeProof: Bool = false) {
        self.query = query
        self.variables = variables
        self.operationName = operationName
        self.includeProof = includeProof
    }
}

/// A GraphQL error.
public struct GraphQLError: Codable {
    public let message: String
    public let locations: [GraphQLLocation]?
    public let path: [AnyCodable]?
    public let extensions: [String: AnyCodable]?
}

/// A location in a GraphQL query.
public struct GraphQLLocation: Codable {
    public let line: Int
    public let column: Int
}

/// A GraphQL query response.
public struct GraphQLResponse: Codable {
    public let data: Data?
    public let errors: [GraphQLError]?
    public let proof: Data?
}

// MARK: - SQL Query Types

/// A cryptographic proof returned with a query result.
public struct QueryProof: Codable {
    public let rootHash: String
    public let proofBytes: Data
    public let height: Int64

    enum CodingKeys: String, CodingKey {
        case rootHash = "root_hash"
        case proofBytes = "proof_bytes"
        case height
    }
}

/// Request body for SQL queries.
public struct SqlRequest: Codable {
    public let query: String
    public let includeProof: Bool?

    enum CodingKeys: String, CodingKey {
        case query
        case includeProof = "include_proof"
    }

    public init(query: String, includeProof: Bool? = false) {
        self.query = query
        self.includeProof = includeProof
    }
}

/// Response from a SQL query.
public struct SqlResponse: Codable {
    public let columns: [String]
    public let rows: [[AnyCodable]]
    public let total: UInt64?
    public let warnings: [String]?
    public let proof: QueryProof?
}

// MARK: - Retention Window

/// How long real-time indexed data is retained on consensus nodes.
public enum RetentionWindow: Codable, Equatable {
    /// Retain for N consensus blocks.
    case blocks(UInt64)
    /// Retain for N seconds.
    case seconds(UInt64)
    /// Never prune (default).
    case indefinite
    /// Verify and discard: consensus verifies but does not store raw data.
    case verifyOnly

    enum CodingKeys: String, CodingKey {
        case blocks = "Blocks"
        case seconds = "Seconds"
        case indefinite = "Indefinite"
        case verifyOnly = "VerifyOnly"
    }

    /// Reads serde's form: a unit variant as its name (`"Indefinite"`), a
    /// variant with a count as `{"Blocks": n}`.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
            switch value {
            case "Indefinite":
                self = .indefinite
            case "VerifyOnly":
                self = .verifyOnly
            default:
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Unknown RetentionWindow value: \(value)"
                )
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try container.decodeIfPresent(UInt64.self, forKey: .blocks) {
            self = .blocks(n)
        } else if let n = try container.decodeIfPresent(UInt64.self, forKey: .seconds) {
            self = .seconds(n)
        } else if container.contains(.indefinite) {
            self = .indefinite
        } else if container.contains(.verifyOnly) {
            self = .verifyOnly
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "Unknown RetentionWindow value"
            ))
        }
    }

    /// Writes serde's form: a unit variant as its name, a count as `{"Blocks": n}`.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .blocks(let n):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(n, forKey: .blocks)
        case .seconds(let n):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(n, forKey: .seconds)
        case .indefinite:
            var container = encoder.singleValueContainer()
            try container.encode("Indefinite")
        case .verifyOnly:
            var container = encoder.singleValueContainer()
            try container.encode("VerifyOnly")
        }
    }
}

// MARK: - Subgrove Types

/// A subgrove as `GET /subgroves/{id}` and `GET /subgroves/indexed` serve
/// it. A storage subgrove reads with zero blocks and no indexers.
public struct SubgroveInfo: Codable {
    public let subgroveId: String
    public let name: String
    public let ownerDid: String
    public let status: String
    /// The latest indexed source-chain block, 0 before any.
    public let latestBlock: UInt64
    /// The Willow height the subgrove was registered at.
    public let deploymentBlock: UInt64
    public let indexers: [String]
    /// The chain an indexing subgrove indexes.
    public let chain: String?

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case name
        case ownerDid = "owner_did"
        case status
        case latestBlock = "latest_block"
        case deploymentBlock = "deployment_block"
        case indexers
        case chain
    }
}

/// Information about an indexer node. Matches the validator's
/// `GET /indexers` response shape.
public struct IndexerInfo: Codable {
    public let indexerDid: String
    public let subgroves: [String]
    /// The indexer's stake in the token's smallest unit, as decimal digits.
    public let stakeAmount: String
    /// Monitoring / health endpoint (historically also used for queries).
    public let endpoint: String
    /// Preferred endpoint for client query traffic (GraphQL/SQL).
    /// When `nil`, callers should fall back to `endpoint`.
    /// See ``effectiveQueryEndpoint()``.
    public let queryEndpoint: String?
    public let status: String
    public let performanceScore: Double
    public let lastUpdate: UInt64

    public init(
        indexerDid: String,
        subgroves: [String],
        stakeAmount: String,
        endpoint: String,
        queryEndpoint: String? = nil,
        status: String,
        performanceScore: Double,
        lastUpdate: UInt64
    ) {
        self.indexerDid = indexerDid
        self.subgroves = subgroves
        self.stakeAmount = stakeAmount
        self.endpoint = endpoint
        self.queryEndpoint = queryEndpoint
        self.status = status
        self.performanceScore = performanceScore
        self.lastUpdate = lastUpdate
    }

    enum CodingKeys: String, CodingKey {
        case indexerDid = "indexer_did"
        case subgroves
        case stakeAmount = "stake_amount"
        case endpoint
        case queryEndpoint = "query_endpoint"
        case status
        case performanceScore = "performance_score"
        case lastUpdate = "last_update"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        indexerDid = try container.decode(String.self, forKey: .indexerDid)
        subgroves = try container.decode([String].self, forKey: .subgroves)
        stakeAmount = try container.decodeAmount(forKey: .stakeAmount)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        queryEndpoint = try container.decodeIfPresent(String.self, forKey: .queryEndpoint)
        status = try container.decode(String.self, forKey: .status)
        performanceScore = try container.decode(Double.self, forKey: .performanceScore)
        lastUpdate = try container.decode(UInt64.self, forKey: .lastUpdate)
    }

    /// URL clients should POST GraphQL/SQL queries to. Prefers `queryEndpoint`
    /// when non-nil; falls back to `endpoint` otherwise.
    public func effectiveQueryEndpoint() -> String {
        return queryEndpoint ?? endpoint
    }
}

// MARK: - Health Types

/// A node's health as `GET /health` serves it.
public struct HealthStatus: Codable {
    /// "healthy", "degraded", or "unhealthy".
    public let status: String
    /// RFC 3339.
    public let timestamp: String
    public let version: String
    /// Each check's result, as the node reports it.
    public let checks: [String: AnyCodable]?

    public var healthy: Bool {
        return status == "healthy"
    }
}

// MARK: - Data Types

/// A proof for data retrieval.
public struct DataProof: Codable {
    public let proof: Data
    public let rootHash: String
    public let height: Int64
    public let verifiedAt: Int64

    enum CodingKeys: String, CodingKey {
        case proof
        case rootHash = "root_hash"
        case height
        case verifiedAt = "verified_at"
    }
}

/// Response from a data retrieval operation.
public struct DataResponse: Codable {
    public let key: String
    public let data: [String: AnyCodable]
    public let proof: DataProof?
}

/// A request to store data.
public struct StoreRequest: Codable {
    public let key: String?
    public let data: [String: AnyCodable]

    public init(key: String? = nil, data: [String: Any]) {
        self.key = key
        self.data = data.mapValues { AnyCodable($0) }
    }
}

// MARK: - Permission Types

/// A permission entry, as `GET /did/{did}/permissions` lists them.
public struct Permission: Codable {
    public let did: String
    public let subgroveId: String?
    /// The subgrove role granted (for example "reader" or "writer").
    public let role: String?
    public let actions: [String]
    public let grantedBy: String
    public let grantedAt: Int64
    public let expiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case did
        case subgroveId = "subgrove_id"
        case role
        case actions
        case grantedBy = "granted_by"
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        did = try container.decode(String.self, forKey: .did)
        subgroveId = try container.decodeIfPresent(String.self, forKey: .subgroveId)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        actions = try container.decodeIfPresent([String].self, forKey: .actions) ?? []
        grantedBy = try container.decode(String.self, forKey: .grantedBy)
        grantedAt = try container.decode(Int64.self, forKey: .grantedAt)
        expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt)
    }
}

// MARK: - API Response

/// Generic API response wrapper.
public struct ApiResponse<T: Codable>: Codable {
    public let success: Bool
    public let data: T?
    public let error: String?
}

// MARK: - Retry Configuration

/// Configuration for retry behavior.
public struct RetryConfig {
    public let maxRetries: Int
    public let initialBackoff: TimeInterval
    public let maxBackoff: TimeInterval
    public let backoffFactor: Double

    public init(maxRetries: Int = 3, initialBackoff: TimeInterval = 0.1, maxBackoff: TimeInterval = 5.0, backoffFactor: Double = 2.0) {
        self.maxRetries = maxRetries
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.backoffFactor = backoffFactor
    }

    public static let `default` = RetryConfig()
}

// MARK: - AnyCodable Helper

/// A type-erased Codable value.
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot encode AnyCodable"))
        }
    }
}
