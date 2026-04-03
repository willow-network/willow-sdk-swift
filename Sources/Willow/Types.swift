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

/// A registered subgrove.
public struct SubgroveRegistration: Codable {
    public let subgroveId: String
    public let name: String
    public let description: String?
    public let schema: SchemaDefinition
    public let ownerDid: String
    public let writers: [String]?
    public let readers: [String]?
    public let rewardRate: UInt64?
    public let retentionWindow: RetentionWindow?
    public let itemCount: UInt64
    public let storageUsed: UInt64
    public let createdAt: Int64
    public let updatedAt: Int64

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
        case itemCount = "item_count"
        case storageUsed = "storage_used"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Token Types

/// Information about the WILL token.
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
}

/// Balance information for a DID.
public struct BalanceInfo: Codable {
    public let id: String
    public let balance: UInt64
    public let available: UInt64
    public let locked: UInt64
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
}

// MARK: - Validator Types

/// Status of a validator.
public enum ValidatorStatus: String, Codable {
    case active = "active"
    case inactive = "inactive"
    case jailed = "jailed"
}

/// Information about a validator.
public struct ValidatorInfo: Codable {
    public let address: String
    public let publicKey: String
    public let votingPower: Int64
    public let status: ValidatorStatus
    public let commission: Double
    public let moniker: String?
    public let website: String?
    public let details: String?

    enum CodingKeys: String, CodingKey {
        case address
        case publicKey = "public_key"
        case votingPower = "voting_power"
        case status
        case commission
        case moniker
        case website
        case details
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
    public let key: String
    public let data: [String: AnyCodable]
}

/// Response to a query.
public struct QueryResponse: Codable {
    public let results: [QueryResult]
    public let totalCount: Int
    public let hasMore: Bool
    public let proof: Data?

    enum CodingKeys: String, CodingKey {
        case results
        case totalCount = "total_count"
        case hasMore = "has_more"
        case proof
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
    public let indexerDid: String
    public let submittedAt: UInt64
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
        indexerDid = try container.decode(String.self, forKey: .indexerDid)
        submittedAt = try container.decode(UInt64.self, forKey: .submittedAt)
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
        try container.encode(indexerDid, forKey: .indexerDid)
        try container.encode(submittedAt, forKey: .submittedAt)
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

    public init(query: String, includeProof: Bool? = nil) {
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try? container.decode(UInt64.self, forKey: .blocks) {
            self = .blocks(n)
            return
        }
        if let n = try? container.decode(UInt64.self, forKey: .seconds) {
            self = .seconds(n)
            return
        }
        if container.contains(.indefinite) {
            self = .indefinite
            return
        }
        if container.contains(.verifyOnly) {
            self = .verifyOnly
            return
        }

        // Try single-value string for simple variant
        let singleContainer = try decoder.singleValueContainer()
        let value = try singleContainer.decode(String.self)
        switch value {
        case "Indefinite":
            self = .indefinite
        case "VerifyOnly":
            self = .verifyOnly
        default:
            throw DecodingError.dataCorruptedError(
                in: singleContainer,
                debugDescription: "Unknown RetentionWindow value: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .blocks(let n):
            try container.encode(n, forKey: .blocks)
        case .seconds(let n):
            try container.encode(n, forKey: .seconds)
        case .indefinite:
            try container.encode("Indefinite", forKey: .indefinite)
        case .verifyOnly:
            try container.encode("VerifyOnly", forKey: .verifyOnly)
        }
    }
}

// MARK: - Subgrove Types

/// Information about a subgrove (indexed blockchain data).
public struct SubgroveInfo: Codable {
    public let id: String
    public let name: String
    public let description: String?
    public let network: String
    public let startBlock: UInt64
    public let currentBlock: UInt64
    public let status: String
    public let createdAt: Int64
    public let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case network
        case startBlock = "start_block"
        case currentBlock = "current_block"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Information about an indexer node.
public struct IndexerInfo: Codable {
    public let id: String
    public let address: String
    public let stake: UInt64
    public let subgroves: [String]
    public let status: String
    public let performance: Double
}

// MARK: - Health Types

/// Health status of a node.
public struct HealthStatus: Codable {
    public let healthy: Bool
    public let version: String
    public let nodeId: String
    public let network: String
    public let blockHeight: Int64
    public let syncStatus: String

    enum CodingKeys: String, CodingKey {
        case healthy
        case version
        case nodeId = "node_id"
        case network
        case blockHeight = "block_height"
        case syncStatus = "sync_status"
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

/// A permission entry.
public struct Permission: Codable {
    public let did: String
    public let subgroveId: String?
    public let actions: [String]
    public let grantedBy: String
    public let grantedAt: Int64
    public let expiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case did
        case subgroveId = "subgrove_id"
        case actions
        case grantedBy = "granted_by"
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
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
