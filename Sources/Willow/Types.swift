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

// MARK: - Authentication Types

/// A challenge for DID authentication.
public struct AuthenticationChallenge: Codable {
    public let challenge: String
    public let nonce: String
    public let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case challenge
        case nonce
        case expiresAt = "expires_at"
    }
}

/// Response to an authentication challenge.
public struct AuthenticationResponse: Codable {
    public let did: String
    public let challenge: String
    public let nonce: String
    public let signature: String
    public let publicKeyId: String

    enum CodingKeys: String, CodingKey {
        case did
        case challenge
        case nonce
        case signature
        case publicKeyId = "public_key_id"
    }
}

/// An authenticated session.
public struct Session: Codable {
    public let did: String
    public let token: String?
    public let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case did
        case token
        case expiresAt = "expires_at"
    }

    /// Checks if the session has expired.
    public var isExpired: Bool {
        return Date().timeIntervalSince1970 > Double(expiresAt)
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

// MARK: - App Types

/// Type of application.
public enum AppType: String, Codable {
    case standard = "standard"
    case indexer = "indexer"
}

/// Request to register a new app.
public struct RegisterAppRequest: Codable {
    public var appId: String
    public var name: String
    public var description: String?
    public var appType: AppType
    public var ownerDid: String
    public var admins: [String]

    enum CodingKeys: String, CodingKey {
        case appId = "app_id"
        case name
        case description
        case appType = "app_type"
        case ownerDid = "owner_did"
        case admins
    }

    public init(appId: String, name: String, description: String? = nil, appType: AppType = .standard, ownerDid: String = "", admins: [String] = []) {
        self.appId = appId
        self.name = name
        self.description = description
        self.appType = appType
        self.ownerDid = ownerDid
        self.admins = admins
    }
}

/// A registered application.
public struct AppRegistration: Codable {
    public let appId: String
    public let name: String
    public let description: String?
    public let appType: AppType
    public let ownerDid: String
    public let admins: [String]?
    public let balance: UInt64
    public let createdAt: Int64
    public let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case appId = "app_id"
        case name
        case description
        case appType = "app_type"
        case ownerDid = "owner_did"
        case admins
        case balance
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Subgrove Types

/// Request to register a new subgrove.
public struct RegisterSubgroveRequest: Codable {
    public var subgroveId: String
    public var appId: String
    public var name: String
    public var description: String?
    public var schema: SchemaDefinition
    public var ownerDid: String
    public var writers: [String]
    public var readers: [String]
    public var rewardRate: UInt64

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case appId = "app_id"
        case name
        case description
        case schema
        case ownerDid = "owner_did"
        case writers
        case readers
        case rewardRate = "reward_rate"
    }

    public init(subgroveId: String, appId: String, name: String, description: String? = nil, schema: SchemaDefinition = SchemaDefinition(name: ""), ownerDid: String = "", writers: [String] = [], readers: [String] = [], rewardRate: UInt64 = 0) {
        self.subgroveId = subgroveId
        self.appId = appId
        self.name = name
        self.description = description
        self.schema = schema
        self.ownerDid = ownerDid
        self.writers = writers
        self.readers = readers
        self.rewardRate = rewardRate
    }
}

/// A registered subgrove.
public struct SubgroveRegistration: Codable {
    public let subgroveId: String
    public let appId: String
    public let name: String
    public let description: String?
    public let schema: SchemaDefinition
    public let ownerDid: String
    public let writers: [String]?
    public let readers: [String]?
    public let rewardRate: UInt64?
    public let itemCount: UInt64
    public let storageUsed: UInt64
    public let createdAt: Int64
    public let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case appId = "app_id"
        case name
        case description
        case schema
        case ownerDid = "owner_did"
        case writers
        case readers
        case rewardRate = "reward_rate"
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
    public let totalSupply: UInt64
    public let circulatingSupply: UInt64

    enum CodingKeys: String, CodingKey {
        case name
        case symbol
        case decimals
        case totalSupply = "total_supply"
        case circulatingSupply = "circulating_supply"
    }
}

/// Balance information for a DID or app.
public struct BalanceInfo: Codable {
    public let id: String
    public let balance: UInt64
    public let available: UInt64
    public let locked: UInt64
}

/// Fee schedule for storage operations.
public struct FeeSchedule: Codable {
    public let storageFeePerByte: UInt64
    public let queryFeeBase: UInt64
    public let queryFeePerResult: UInt64
    public let transactionFeeBase: UInt64

    enum CodingKeys: String, CodingKey {
        case storageFeePerByte = "storage_fee_per_byte"
        case queryFeeBase = "query_fee_base"
        case queryFeePerResult = "query_fee_per_result"
        case transactionFeeBase = "transaction_fee_base"
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

// MARK: - Subgraph Types

/// Information about a subgraph (indexed blockchain data).
public struct SubgraphInfo: Codable {
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
    public let subgraphs: [String]
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
    public let appId: String
    public let subgroveId: String?
    public let actions: [String]
    public let grantedBy: String
    public let grantedAt: Int64
    public let expiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case did
        case appId = "app_id"
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
