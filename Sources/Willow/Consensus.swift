import Foundation

// MARK: - Consensus Types

/// Transaction status enumeration.
public enum TransactionStatus: String, Codable {
    case pending = "pending"
    case success = "success"
    case failed = "failed"
    case notFound = "not_found"
}

/// Configuration for consensus client.
public struct ConsensusConfig {
    /// CometBFT RPC URL (e.g., "http://localhost:26657").
    public let consensusRpcUrl: String

    /// Optional REST API URL for account queries.
    public let apiUrl: String?

    /// Optional indexer node base URL (e.g., "http://localhost:3051"), used by
    /// `verifyBlockCompleteness` to fetch the served matched-log preimage.
    public let indexerUrl: String?

    /// Chain ID.
    public let chainId: String

    /// Request timeout in seconds.
    public let requestTimeoutSecs: TimeInterval

    /// Maximum retry attempts.
    public let maxRetries: Int

    /// Delay between retries in seconds.
    public let retryDelaySecs: TimeInterval

    public init(
        consensusRpcUrl: String,
        apiUrl: String? = nil,
        indexerUrl: String? = nil,
        chainId: String = "willow-chain",
        requestTimeoutSecs: TimeInterval = 30,
        maxRetries: Int = 3,
        retryDelaySecs: TimeInterval = 1.0
    ) {
        self.consensusRpcUrl = consensusRpcUrl
        self.apiUrl = apiUrl
        self.indexerUrl = indexerUrl
        self.chainId = chainId
        self.requestTimeoutSecs = requestTimeoutSecs
        self.maxRetries = maxRetries
        self.retryDelaySecs = retryDelaySecs
    }
}

/// Result of transaction broadcast.
public struct BroadcastResult {
    public let success: Bool
    public let txHash: String?
    public let height: Int64?
    public let errorCode: Int?
    public let errorMessage: String?
    public let rawLog: String?
    /// The signed transaction as it was sent (its DID, nonce, and body), on
    /// the result of a write the SDK signed under a nonce it chose. Pass it
    /// to `resubmit(_:)` to send the identical transaction again under the
    /// same nonce.
    public let submission: SignedSubmission?

    public init(
        success: Bool,
        txHash: String? = nil,
        height: Int64? = nil,
        errorCode: Int? = nil,
        errorMessage: String? = nil,
        rawLog: String? = nil,
        submission: SignedSubmission? = nil
    ) {
        self.success = success
        self.txHash = txHash
        self.height = height
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.rawLog = rawLog
        self.submission = submission
    }

    /// This result, carrying `submission`.
    internal func with(_ submission: SignedSubmission) -> BroadcastResult {
        return BroadcastResult(
            success: success, txHash: txHash, height: height, errorCode: errorCode, errorMessage: errorMessage,
            rawLog: rawLog, submission: submission)
    }
}

/// A signed transaction as the SDK sent it to `POST /tx/submit`: the DID
/// whose nonce it carries, the nonce, and the exact body sent.
///
/// A write whose outcome is unknown (its submission failed in transit, or
/// the API answered a 5xx or a 408) may have reached the node and may still
/// land. Retry it only by sending this same transaction again under the same
/// nonce (`WillowClient.resubmit(_:)` or `ConsensusClient.resubmit(_:)`):
/// whichever copy lands first spends the nonce and the other is refused, so
/// the write runs at most once. Signing the write again under a fresh nonce
/// could run it twice.
public struct SignedSubmission: Equatable {
    /// The DID whose nonce the transaction carries.
    public let did: String
    /// The transaction's nonce.
    public let nonce: Int
    /// The `/tx/submit` body sent: the signed transaction as JSON.
    public let body: Data
    /// The reservation that took the nonce, so a resubmission renews its
    /// own lease and not another write's.
    internal let token: UInt64
}

// MARK: - Transaction Types

/// DID registration transaction.
public struct RegisterDidTx: Codable {
    public var didDocument: [String: AnyCodable]
    public var signature: [UInt8]
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case didDocument = "did_document"
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(didDocument: [String: AnyCodable], signature: [UInt8] = [], publicKeyId: String, nonce: Int) {
        self.didDocument = didDocument
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }
}

/// Paid-read pricing for a subgrove: the chain's `ReadPricing`.
public struct ReadPricing: Codable, Equatable {
    /// Whether readers outside the free-reader list pay per query.
    public var enabled: Bool
    /// The price of one query, in the token's smallest unit.
    public var pricePerQuery: U128
    /// The owner's share of read revenue in basis points (10000 = 100%).
    public var ownerRevenueShareBps: UInt32

    enum CodingKeys: String, CodingKey {
        case enabled
        case pricePerQuery = "price_per_query"
        case ownerRevenueShareBps = "owner_revenue_share_bps"
    }

    public init(enabled: Bool, pricePerQuery: U128, ownerRevenueShareBps: UInt32) {
        self.enabled = enabled
        self.pricePerQuery = pricePerQuery
        self.ownerRevenueShareBps = ownerRevenueShareBps
    }
}

/// DataStorage mode configuration for a subgrove.
public struct SubgroveDataStorage: Codable {
    public var name: String
    public var writers: [String]
    public var freeReaders: [String]
    /// Paid-read pricing; `nil` for none.
    public var readPricing: ReadPricing?

    enum CodingKeys: String, CodingKey {
        case name
        case writers
        case freeReaders = "free_readers"
        case readPricing = "read_pricing"
    }

    public init(name: String = "", writers: [String] = [], freeReaders: [String] = [], readPricing: ReadPricing? = nil) {
        self.name = name
        self.writers = writers
        self.freeReaders = freeReaders
        self.readPricing = readPricing
    }
}

/// FileStorage mode configuration for a subgrove: files whose manifests go
/// through consensus and whose chunks live on storage nodes.
public struct SubgroveFileStorage: Codable {
    public var name: String
    /// The largest file accepted, in bytes.
    public var maxFileSize: UInt64
    /// How many storage nodes must hold each file.
    public var replicationFactor: UInt8
    public var writers: [String]
    public var freeReaders: [String]
    /// Paid-download pricing; `nil` for none.
    public var readPricing: ReadPricing?
    /// How long files are kept, in seconds (0 = permanently).
    public var retentionPeriod: UInt64

    enum CodingKeys: String, CodingKey {
        case name
        case maxFileSize = "max_file_size"
        case replicationFactor = "replication_factor"
        case writers
        case freeReaders = "free_readers"
        case readPricing = "read_pricing"
        case retentionPeriod = "retention_period"
    }

    public init(
        name: String,
        maxFileSize: UInt64,
        replicationFactor: UInt8,
        writers: [String] = [],
        freeReaders: [String] = [],
        readPricing: ReadPricing? = nil,
        retentionPeriod: UInt64 = 0
    ) {
        self.name = name
        self.maxFileSize = maxFileSize
        self.replicationFactor = replicationFactor
        self.writers = writers
        self.freeReaders = freeReaders
        self.readPricing = readPricing
        self.retentionPeriod = retentionPeriod
    }
}

/// BlockchainIndexing mode configuration for a subgrove.
///
/// The node's BlockchainIndexing registration also needs a manifest, an
/// execution mode, and an indexer config, which this type doesn't carry, so
/// the SDK refuses to sign a registration in this mode.
public struct SubgroveBlockchainIndexing: Codable {
    /// How long real-time indexed data is retained on consensus nodes.
    public var retentionWindow: RetentionWindow?

    enum CodingKeys: String, CodingKey {
        case retentionWindow = "retention_window"
    }

    public init(retentionWindow: RetentionWindow? = nil) {
        self.retentionWindow = retentionWindow
    }
}

/// SubgroveMode: DataStorage, FileStorage, or BlockchainIndexing.
public enum SubgroveMode: Codable {
    case dataStorage(SubgroveDataStorage)
    case fileStorage(SubgroveFileStorage)
    case blockchainIndexing(SubgroveBlockchainIndexing)

    enum CodingKeys: String, CodingKey {
        case dataStorage = "DataStorage"
        case fileStorage = "FileStorage"
        case blockchainIndexing = "BlockchainIndexing"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ds = try container.decodeIfPresent(SubgroveDataStorage.self, forKey: .dataStorage) {
            self = .dataStorage(ds)
        } else if let fs = try container.decodeIfPresent(SubgroveFileStorage.self, forKey: .fileStorage) {
            self = .fileStorage(fs)
        } else if let bi = try container.decodeIfPresent(SubgroveBlockchainIndexing.self, forKey: .blockchainIndexing) {
            self = .blockchainIndexing(bi)
        } else {
            self = .dataStorage(SubgroveDataStorage())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dataStorage(let ds):
            try container.encode(ds, forKey: .dataStorage)
        case .fileStorage(let fs):
            try container.encode(fs, forKey: .fileStorage)
        case .blockchainIndexing(let bi):
            try container.encode(bi, forKey: .blockchainIndexing)
        }
    }

    /// The mode's name, empty for BlockchainIndexing.
    internal var name: String {
        switch self {
        case .dataStorage(let mode): return mode.name
        case .fileStorage(let mode): return mode.name
        case .blockchainIndexing: return ""
        }
    }
}

/// Subgrove registration transaction: the chain's `RegisterSubgroveTx`.
///
/// It is signed over `registerSubgroveMessage`, whose `Config` line is the
/// SHA-256 of the transaction's bincode with an empty signature, so it binds
/// every field. The SDK sends every field explicitly (`template_config` and
/// the checkpoint TEE requirement as none, `cryptographic_completeness` as
/// false) and hashes exactly what it sends. A BlockchainIndexing mode is
/// refused: this type can't carry everything that mode needs.
public struct RegisterSubgroveTx {
    public var subgroveId: String
    /// Human-readable name.
    public var name: String
    public var description: String
    /// The schema as JSON text, e.g. `{"version":1,"fields":{},"indexes":[],"required_fields":[]}`.
    public var schema: String
    public var ownerDid: String
    /// DIDs with admin rights.
    public var admins: [String]
    /// Tokens (smallest unit) moved from the owner to fund the subgrove at registration.
    public var initialFunding: U128?
    public var mode: SubgroveMode
    /// Set for a private subgrove.
    public var privacy: PrivacyConfig?
    /// The owner's own key grant, for a private subgrove.
    public var initialOwnerKeyGrant: EncryptedKeyGrant?
    /// Blocks held in the chain-tip buffer before submissions fire.
    public var confirmationDepth: UInt32
    public var signature: [UInt8]
    public var publicKeyId: String
    public var nonce: Int

    public init(
        subgroveId: String,
        name: String = "",
        description: String = "",
        schema: String,
        ownerDid: String,
        admins: [String] = [],
        initialFunding: U128? = nil,
        mode: SubgroveMode = .dataStorage(SubgroveDataStorage()),
        privacy: PrivacyConfig? = nil,
        initialOwnerKeyGrant: EncryptedKeyGrant? = nil,
        confirmationDepth: UInt32 = 0,
        signature: [UInt8] = [],
        publicKeyId: String,
        nonce: Int
    ) {
        self.subgroveId = subgroveId
        self.name = name
        self.description = description
        self.schema = schema
        self.ownerDid = ownerDid
        self.admins = admins
        self.initialFunding = initialFunding
        self.mode = mode
        self.privacy = privacy
        self.initialOwnerKeyGrant = initialOwnerKeyGrant
        self.confirmationDepth = confirmationDepth
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }
}

/// Token transfer transaction.
public struct TransferTx: Codable {
    public var fromDid: String
    public var toDid: String
    public var amount: Int64
    public var memo: String?
    public var signature: [UInt8]
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case fromDid = "from_did"
        case toDid = "to_did"
        case amount
        case memo
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(
        fromDid: String,
        toDid: String,
        amount: Int64,
        memo: String? = nil,
        signature: [UInt8] = [],
        publicKeyId: String,
        nonce: Int
    ) {
        self.fromDid = fromDid
        self.toDid = toDid
        self.amount = amount
        self.memo = memo
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }
}

/// Data storage transaction: the chain's `StoreData`.
///
/// `data` is JSON text. The transaction carries its UTF-8 bytes (`dataBytes`),
/// encoded as the JSON array of numbers the chain's `Vec<u8>` reads, and the
/// signed message (`storeDataMessage`) binds their SHA-256.
public struct DataStoreTx: Codable {
    public var subgroveId: String
    public var key: String
    public var data: String
    public var ownerDid: String
    public var signature: [UInt8]
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case key
        case data
        case ownerDid = "owner_did"
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(
        subgroveId: String,
        key: String,
        data: String,
        ownerDid: String,
        signature: [UInt8] = [],
        publicKeyId: String,
        nonce: Int
    ) {
        self.subgroveId = subgroveId
        self.key = key
        self.data = data
        self.ownerDid = ownerDid
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }

    /// The bytes the transaction's `data` field carries: `data` as UTF-8.
    public var dataBytes: Data {
        return Data(data.utf8)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subgroveId = try container.decode(String.self, forKey: .subgroveId)
        key = try container.decode(String.self, forKey: .key)
        if let bytes = try? container.decode([UInt8].self, forKey: .data) {
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "data is not UTF-8")
            }
            data = text
        } else {
            data = try container.decode(String.self, forKey: .data)
        }
        ownerDid = try container.decode(String.self, forKey: .ownerDid)
        signature = try container.decode([UInt8].self, forKey: .signature)
        publicKeyId = try container.decode(String.self, forKey: .publicKeyId)
        nonce = try container.decode(Int.self, forKey: .nonce)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subgroveId, forKey: .subgroveId)
        try container.encode(key, forKey: .key)
        try container.encode([UInt8](dataBytes), forKey: .data)
        try container.encode(ownerDid, forKey: .ownerDid)
        try container.encode(signature, forKey: .signature)
        try container.encode(publicKeyId, forKey: .publicKeyId)
        try container.encode(nonce, forKey: .nonce)
    }
}

/// Deregister (delete) a subgrove transaction.
/// Remaining funding balance is refunded to the owner.
public struct DeregisterSubgroveTx: Codable {
    public var subgroveId: String
    public var ownerDid: String
    public var signature: [UInt8]
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case ownerDid = "owner_did"
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(
        subgroveId: String,
        ownerDid: String,
        signature: [UInt8] = [],
        publicKeyId: String,
        nonce: Int
    ) {
        self.subgroveId = subgroveId
        self.ownerDid = ownerDid
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }
}

// MARK: - Consensus Client

/// CometBFT consensus client for direct transaction broadcasting.
///
/// Enables full-featured blockchain interactions without relying on data nodes.
public class ConsensusClient {
    private let config: ConsensusConfig
    private let session: URLSession
    private let nonces: NonceAllocator

    public init(_ config: ConsensusConfig) {
        self.config = config
        self.session = ConsensusClient.makeSession(config)
        self.nonces = .shared
    }

    /// A session whose requests wait at most `requestTimeoutSecs` for data
    /// and twice that in all.
    internal static func makeSession(_ config: ConsensusConfig) -> URLSession {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.requestTimeoutSecs
        sessionConfig.timeoutIntervalForResource = config.requestTimeoutSecs * 2
        return URLSession(configuration: sessionConfig)
    }

    /// Testing seam: supply a `URLSession` (e.g. backed by a stub `URLProtocol`)
    /// so the RPC + indexer fetches can be exercised without a live node, and
    /// the nonce allocator (a fresh one unless given; the public initializer
    /// uses the process's shared one).
    internal init(_ config: ConsensusConfig, session: URLSession, nonces: NonceAllocator = NonceAllocator()) {
        self.config = config
        self.session = session
        self.nonces = nonces
    }

    // MARK: - High-Level Transaction Methods

    /// Register a DID on the blockchain.
    ///
    /// Willow DIDs are self-certifying: the id is `did:willow:z...` derived from
    /// the public key (see `deriveWillowDID`), so it cannot be chosen and does
    /// not yet hold a balance. The registration fee is paid from the DID's own
    /// balance, so a two-step bootstrap is required:
    ///
    ///   1. Pre-fund: some already-registered account calls `transfer(...)` to
    ///      send at least the registration fee to the derived DID id.
    ///   2. Register: the holder calls `registerDid(...)`, which spends the fee
    ///      from that balance.
    ///
    /// Calling `registerDid` before the derived id is funded fails on-chain with
    /// insufficient funds.
    public func registerDid(
        didDocument: [String: Any],
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        let did = (didDocument["id"] as? String) ?? ""

        // Convert to AnyCodable for encoding
        let codableDocument = didDocument.mapValues { AnyCodable($0) }
        let signMessage = createSignMessage(txType: "RegisterDid", didDocument: didDocument)

        return try await submitUnderNextNonce(did: did) { nonce in
            var tx = RegisterDidTx(
                didDocument: codableDocument,
                publicKeyId: publicKeyId,
                nonce: nonce
            )
            tx.signature = Array(try signFunction(Data(signMessage.utf8), privateKey))
            return try encodeTransaction(txType: "RegisterDid", transaction: tx)
        }
    }

    /// Register a subgrove (dataset) on the blockchain as a `RegisterSubgrove`
    /// transaction.
    ///
    /// The transaction is `registration` under a nonce of the owner's that no
    /// other write in flight holds (its `nonce` and `signature` are replaced).
    /// `signFunction` signs `registerSubgroveMessage` over the subgrove ID,
    /// the owner DID, the SHA-256 of the transaction's bincode with an empty
    /// signature, and the nonce; the SDK sends exactly the fields it hashed.
    /// Refused with a validation error before anything is signed: a
    /// BlockchainIndexing mode, a subgrove ID or owner DID holding a line
    /// break, and a DataStorage or FileStorage registration the node refuses
    /// (see `registerSubgroveMessage`): a subgrove ID out of the node's form;
    /// an admin, writer, or free reader that isn't a Willow DID; a schema the
    /// node can't read or that declares indexes; or a private subgrove's
    /// initial key grant that isn't key epoch 0 to the owner.
    public func registerSubgrove(
        _ registration: RegisterSubgroveTx,
        privateKey: Data,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        var tx = registration
        tx.signature = []
        tx.nonce = 0
        // Refuse what can't be signed before spending a request on the nonce.
        _ = try registerSubgroveMessage(tx)
        let unsigned = tx
        return try await submitUnderNextNonce(did: tx.ownerDid) { nonce in
            var tx = unsigned
            tx.nonce = nonce
            return try signedRegisterSubgroveBody(tx) { try signFunction($0, privateKey) }
        }
    }

    /// Register a subgrove (dataset) on the blockchain: `registerSubgrove(_:)`
    /// with the subgrove's name taken from the mode's (DataStorage when `mode`
    /// is nil) and every other field at its default.
    public func registerSubgrove(
        subgroveId: String,
        schema: String,
        ownerDid: String,
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data,
        mode: SubgroveMode? = nil
    ) async throws -> BroadcastResult {
        let mode = mode ?? .dataStorage(SubgroveDataStorage())
        let registration = RegisterSubgroveTx(
            subgroveId: subgroveId,
            name: mode.name,
            schema: schema,
            ownerDid: ownerDid,
            mode: mode,
            publicKeyId: publicKeyId,
            nonce: 0
        )
        return try await registerSubgrove(registration, privateKey: privateKey, signFunction: signFunction)
    }

    /// Transfer tokens between DIDs, under the lowest nonce of `fromDid`
    /// above its base that the chain doesn't show used and no other write in
    /// flight from this process holds.
    ///
    /// A transfer whose outcome is unknown (its submission failed in transit,
    /// or the API answered a 5xx or a 408) throws a `TransactionSubmitError`.
    /// It may have reached the node and may still land: retry it only with
    /// `resubmit(error.submission)`, which sends the same signed transfer
    /// under the same nonce, so it runs at most once. Calling `transfer`
    /// again would sign a second transfer under a fresh nonce, and both could
    /// run. A transfer CheckTx refuses is returned with `success` false and
    /// `submission` set.
    public func transfer(
        fromDid: String,
        toDid: String,
        amount: Int64,
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data,
        memo: String? = nil
    ) async throws -> BroadcastResult {
        return try await submitUnderNextNonce(did: fromDid) { nonce in
            var tx = TransferTx(
                fromDid: fromDid,
                toDid: toDid,
                amount: amount,
                memo: memo,
                publicKeyId: publicKeyId,
                nonce: nonce
            )
            let signMessage = createSignMessageForTransfer(tx: tx)
            tx.signature = Array(try signFunction(Data(signMessage.utf8), privateKey))
            return try encodeTransaction(txType: "Transfer", transaction: tx)
        }
    }

    /// Store data on the blockchain as a `StoreData` transaction.
    ///
    /// `data` (a JSON object) is serialized once, with sorted keys and each
    /// `Double` in its shortest form, the text the node keeps and a verified
    /// read returns as that same `Double`; the transaction carries that JSON
    /// text's UTF-8 bytes. `signFunction` signs
    /// `storeDataMessage` over the subgrove ID, key, owner DID, the SHA-256 of
    /// those bytes, and the transaction's nonce. Anything but a JSON object
    /// (the node refuses it in the block, spending the nonce), or a subgrove
    /// ID, key, or owner DID holding a line break, is refused with a
    /// validation error before anything is signed.
    ///
    /// The nonce is the lowest one above the account's base that the chain
    /// doesn't show used and no other write in flight from this process holds.
    /// A write refused in its block after its signature and nonce verify still
    /// spends its nonce; calling again signs anew under another. A write whose
    /// outcome is unknown (a network error, a 5xx, or a 408) throws a
    /// `TransactionSubmitError`: it may still land, so retry it only with
    /// `resubmit(_:)`, which sends the same transaction under the same nonce.
    /// Calling `storeData` again would sign it under a fresh nonce, and both
    /// could run.
    public func storeData(
        subgroveId: String,
        key: String,
        data: Any,
        ownerDid: String,
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        let dataString = try storeDataText(data)
        return try await submitUnderNextNonce(did: ownerDid) { nonce in
            let tx = try signedStoreData(
                subgroveId: subgroveId, key: key, data: dataString, ownerDid: ownerDid,
                publicKeyId: publicKeyId, nonce: nonce
            ) { try signFunction($0, privateKey) }
            return try encodeTransaction(txType: "StoreData", transaction: tx)
        }
    }

    /// Deregister (delete) a subgrove. Remaining funding is refunded to the owner.
    public func deregisterSubgrove(
        subgroveId: String,
        ownerDid: String,
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        return try await submitUnderNextNonce(did: ownerDid) { nonce in
            let signMessage = deregisterSubgroveMessage(subgroveId: subgroveId, ownerDid: ownerDid, nonce: nonce)
            var tx = DeregisterSubgroveTx(
                subgroveId: subgroveId,
                ownerDid: ownerDid,
                publicKeyId: publicKeyId,
                nonce: nonce
            )
            tx.signature = Array(try signFunction(Data(signMessage.utf8), privateKey))
            return try encodeTransaction(txType: "DeregisterSubgrove", transaction: tx)
        }
    }

    // MARK: - Transaction Status

    /// Get the status of a transaction.
    public func getTransactionStatus(txHash: String) async throws -> TransactionStatus {
        do {
            let result = try await queryTransaction(txHash: txHash)
            if result == nil {
                return .notFound
            }
            let code = (result?["tx_result"] as? [String: Any])?["code"] as? Int ?? 0
            return code == 0 ? .success : .failed
        } catch {
            return .notFound
        }
    }

    /// Wait for a transaction to be confirmed.
    public func waitForTransaction(
        txHash: String,
        timeoutSecs: TimeInterval = 60,
        pollInterval: TimeInterval = 2.0
    ) async throws -> TransactionStatus {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeoutSecs {
            let status = try await getTransactionStatus(txHash: txHash)

            if status == .success || status == .failed {
                return status
            }

            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        return .pending
    }

    // MARK: - Chain Info

    /// Get the blockchain chain ID.
    public func getChainId() async throws -> String {
        do {
            let result = try await rpcRequest(method: "status", params: [:])
            if let nodeInfo = result["node_info"] as? [String: Any],
               let network = nodeInfo["network"] as? String {
                return network
            }
            return config.chainId
        } catch {
            return config.chainId
        }
    }

    /// Get the latest blockchain height.
    public func getLatestHeight() async throws -> Int64? {
        do {
            let result = try await rpcRequest(method: "status", params: [:])
            if let syncInfo = result["sync_info"] as? [String: Any],
               let heightStr = syncInfo["latest_block_height"] as? String,
               let height = Int64(heightStr) {
                return height
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Get node status.
    public func getStatus() async throws -> [String: Any] {
        return try await rpcRequest(method: "status", params: [:])
    }

    /// Get the latest block.
    public func getLatestBlock() async throws -> [String: Any] {
        return try await rpcRequest(method: "block", params: [:])
    }

    /// Get a block by height.
    public func getBlock(height: Int64) async throws -> [String: Any] {
        return try await rpcRequest(method: "block", params: ["height": String(height)])
    }

    /// Get validators at a given height.
    public func getValidators(height: Int64? = nil) async throws -> [String: Any] {
        var params: [String: String] = [:]
        if let h = height {
            params["height"] = String(h)
        }
        return try await rpcRequest(method: "validators", params: params)
    }

    /// Get commit at a given height.
    public func getCommit(height: Int64? = nil) async throws -> [String: Any] {
        var params: [String: String] = [:]
        if let h = height {
            params["height"] = String(h)
        }
        return try await rpcRequest(method: "commit", params: params)
    }

    // MARK: - Crypto-Completeness Verification

    /// Verifies, client-side, that the indexer served the complete, untampered
    /// filter-matched event set for `(subgroveId, blockNumber)`.
    ///
    /// End-to-end check of willow PR #676: fetch the on-chain anchor (the
    /// `events_commitment`) via the validator's ABCI store query, fetch the
    /// indexer's matched-log preimage, re-hash it locally, and compare. Returns
    /// `true` only on an exact match — no trust in the indexer required.
    ///
    /// Throws when either half is unavailable: a missing anchor (no commitment
    /// for that block) or a non-200 from the indexer (block not finalized / logs
    /// not retained) is surfaced as an error, not a silent `false`.
    public func verifyBlockCompleteness(
        subgroveId: String,
        blockNumber: UInt64
    ) async throws -> Bool {
        let commitment = try await fetchEventsCommitment(subgroveId: subgroveId, blockNumber: blockNumber)
        let logs = try await fetchMatchedLogs(subgroveId: subgroveId, blockNumber: blockNumber)
        return verifyServedEvents(commitment: commitment, blockNumber: blockNumber, matchedLogs: logs)
    }

    /// Fetches the on-chain `events_commitment` anchor via the ABCI store query.
    ///
    /// Queries `/store/events_commitment/{subgroveId}/{blockNumber}`; a non-zero
    /// ABCI code (no commitment for that block) throws.
    internal func fetchEventsCommitment(subgroveId: String, blockNumber: UInt64) async throws -> Data {
        let path = "/store/events_commitment/\(subgroveId)/\(blockNumber)"
        let value = try await abciQuery(path: path)
        return try parseEventsCommitment(value)
    }

    /// CometBFT `abci_query` over JSON-RPC, returning the decoded `value` bytes.
    ///
    /// The RPC envelope base64-encodes `response.value`; this decodes it. A
    /// non-zero `response.code` (the query failed, e.g. key absent) throws.
    internal func abciQuery(path: String) async throws -> Data {
        let value = try await abciQueryValue(path: path)
        // An OK response with no value means the key is absent.
        guard !value.isEmpty else {
            throw ConsensusClientError("abci_query: no value for \(path)")
        }
        return value
    }

    /// The `value` bytes `abci_query` answers for `path`, empty when it
    /// answers none, in at most `maxRetries + 1` attempts (the config's
    /// retries unless given).
    private func abciQueryValue(path: String, maxRetries: Int? = nil) async throws -> Data {
        let result = try await rpcRequest(method: "abci_query", params: ["path": path, "data": ""], maxRetries: maxRetries)

        guard let response = result["response"] as? [String: Any] else {
            throw ConsensusClientError("abci_query: missing response")
        }

        // CometBFT serializes `code` as an integer; absent means 0 (OK).
        let code = (response["code"] as? Int) ?? 0
        if code != 0 {
            let info = (response["log"] as? String) ?? (response["info"] as? String) ?? "code \(code)"
            throw ConsensusClientError("abci_query failed for \(path): \(info)")
        }

        guard let base64 = response["value"] as? String, !base64.isEmpty else {
            return Data()
        }
        guard let value = Data(base64Encoded: base64) else {
            throw ConsensusClientError("abci_query: no value for \(path)")
        }
        return value
    }

    /// Fetches the indexer's served matched-log set for one block.
    ///
    /// GETs `{indexerUrl}/completeness/{subgroveId}/{blockNumber}/matched-logs`;
    /// a non-200 (block not finalized / logs not retained) throws.
    internal func fetchMatchedLogs(subgroveId: String, blockNumber: UInt64) async throws -> [CompletenessLog] {
        guard let indexerUrl = config.indexerUrl, !indexerUrl.isEmpty else {
            throw ConsensusClientError("indexerUrl is required for verifyBlockCompleteness")
        }
        let trimmed = indexerUrl.hasSuffix("/") ? String(indexerUrl.dropLast()) : indexerUrl
        guard let url = URL(string: "\(trimmed)/completeness/\(subgroveId)/\(blockNumber)/matched-logs") else {
            throw ConsensusClientError("Invalid indexer URL for matched-logs")
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConsensusClientError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw ConsensusClientError("matched-logs unavailable: \(message)")
        }
        return try parseMatchedLogs(data)
    }

    // MARK: - Private Methods

    /// Signs and submits the transaction `build` makes under a nonce for
    /// `did` that no other write in flight holds (see `NonceAllocator`): the
    /// lowest one above the account's base that the chain doesn't show used
    /// and no write holds.
    ///
    /// A transaction the API refuses (CheckTx, or a 4xx before it) gives its
    /// nonce back, unless the refusal says the nonce is held by a pending
    /// transaction, already used, or spent. A submission whose fate is unknown
    /// (a network error or a 5xx) may still land, so its nonce stays held for
    /// 120 s (the node holds a pending transaction's nonce for 3 blocks or
    /// 120 s, whichever ends first), and it is thrown as a
    /// `TransactionSubmitError` carrying the signed transaction, to
    /// `resubmit(_:)`. A body the API refuses in plain text (a 4xx) never
    /// reached CheckTx, so its nonce is given back. The result carries the
    /// signed transaction.
    internal func submitUnderNextNonce(did: String, _ build: (Int) throws -> Data) async throws -> BroadcastResult {
        let submitURL = try txSubmitURL()
        let account = NonceAccount(did: did, api: config.apiUrl ?? "")
        let (result, submission) = try await nonces.signAndSend(account, chain: try await accountNonces(did: did), build: build) { body in
            try await self.broadcast(body, to: submitURL)
        }
        return result.with(submission)
    }

    /// Sends a write again under its own nonce: `submission` is the signed
    /// transaction a `TransactionSubmitError` or a `BroadcastResult` carries.
    /// Its body is sent unchanged, so whichever copy lands first spends the
    /// nonce and the other is refused: the write runs at most once. This is
    /// how to retry a write whose outcome is unknown
    /// (`TransactionSubmitError`); calling the write again would sign it
    /// under a fresh nonce, and both could run.
    ///
    /// The nonce is held while it is in flight, as for a new write. When the
    /// node already holds the identical transaction ("tx already exists in
    /// cache"), that counts as accepted: a successful result with no
    /// transaction hash. A CheckTx refusal is returned as for a write (one
    /// saying the nonce is already used means some transaction under it
    /// landed, perhaps this write's earlier copy: read what it wrote), and an
    /// unknown outcome is thrown again as a `TransactionSubmitError`. Throws a
    /// transaction error and sends nothing when this process has seen the
    /// nonce used, or has handed it to another write after this one's 120 s
    /// hold lapsed.
    public func resubmit(_ submission: SignedSubmission) async throws -> BroadcastResult {
        let submitURL = try txSubmitURL()
        let account = NonceAccount(did: submission.did, api: config.apiUrl ?? "")
        let result = try await nonces.resubmit(submission, on: account) { body in
            try await self.broadcast(body, to: submitURL, resubmission: true)
        }
        return result.with(submission)
    }

    /// Posts a `/tx/submit` body and reads the outcome for its nonce. An
    /// answer that leaves the transaction's fate unknown (a 5xx or a 408,
    /// even in JSON) is thrown as an `HTTPError`, so the write throws a
    /// `TransactionSubmitError`. For a resubmission, the node already holding
    /// the identical transaction counts as accepted.
    private func broadcast(_ body: Data, to url: URL, resubmission: Bool = false) async throws -> (BroadcastResult, NonceOutcome) {
        let (result, status) = try await broadcastBody(body, to: url)
        let message = result.errorMessage ?? result.rawLog ?? "HTTP \(status)"
        if resubmission, !result.success, message.contains("tx already exists in cache") {
            return (BroadcastResult(success: true, rawLog: message), .accepted)
        }
        let outcome = NonceOutcome.submission(status: status, result: result)
        if outcome == .unknown {
            throw HTTPError(statusCode: status, message: message)
        }
        return (result, outcome)
    }

    /// `did`'s nonce state: the base and the nonces used above it from the
    /// ABCI query `/store/account_nonce_state/{did}`, or, when the RPC can't
    /// answer that, the base alone from the API's `GET /account/{did}/nonce`.
    internal func accountNonces(did: String) async throws -> ChainNonces {
        do {
            return try ChainNonces(nonceState: try await abciQueryValue(path: "/store/account_nonce_state/\(did)", maxRetries: 0))
        } catch {
            guard config.apiUrl != nil else { throw error }
            return try ChainNonces(base: try await getAccountNonce(did: did))
        }
    }

    /// The API's `POST /tx/submit` URL.
    private func txSubmitURL() throws -> URL {
        guard let apiUrl = config.apiUrl, !apiUrl.isEmpty else {
            throw ConsensusClientError("apiUrl is required for transaction submission")
        }

        let trimmed = apiUrl.hasSuffix("/") ? String(apiUrl.dropLast()) : apiUrl
        guard let url = URL(string: "\(trimmed)/tx/submit") else {
            throw ConsensusClientError("Invalid API URL for /tx/submit")
        }
        return url
    }

    /// Submits a `/tx/submit` body already encoded as JSON through the API
    /// server, which bincode-encodes it (the chain's on-the-wire format) and
    /// forwards it to CometBFT. Returns the answer and its HTTP status; a
    /// non-2xx answer in plain text is thrown as an `HTTPError`.
    private func broadcastBody(_ body: Data, to url: URL) async throws -> (BroadcastResult, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConsensusClientError("Invalid response")
        }

        return (try parseTxSubmitResponse(data: data, statusCode: httpResponse.statusCode), httpResponse.statusCode)
    }

    private func queryTransaction(txHash: String) async throws -> [String: Any]? {
        do {
            return try await rpcRequest(method: "tx", params: ["hash": txHash, "prove": false])
        } catch {
            return nil
        }
    }

    private func rpcRequest(method: String, params: [String: Any], maxRetries: Int? = nil) async throws -> [String: Any] {
        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ]

        var lastError: Error?
        let maxRetries = max(0, maxRetries ?? config.maxRetries)

        for attempt in 0...maxRetries {
            do {
                guard let url = URL(string: config.consensusRpcUrl) else {
                    throw ConsensusClientError("Invalid RPC URL")
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: rpcBody)

                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ConsensusClientError("Invalid response")
                }

                if httpResponse.statusCode != 200 {
                    throw ConsensusClientError("HTTP \(httpResponse.statusCode)")
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ConsensusClientError("Invalid JSON response")
                }

                if let error = json["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Unknown error"
                    throw ConsensusClientError("RPC error: \(message)")
                }

                return json["result"] as? [String: Any] ?? [:]

            } catch {
                lastError = error
                if attempt < maxRetries {
                    try await Task.sleep(nanoseconds: UInt64(config.retryDelaySecs * Double(attempt + 1) * 1_000_000_000))
                }
            }
        }

        throw lastError ?? ConsensusClientError("Request failed after \(maxRetries + 1) attempts")
    }

    /// The account's base nonce from the API's `GET /account/{did}/nonce`.
    private func getAccountNonce(did: String) async throws -> UInt64 {
        struct AccountNonce: Codable {
            let nonce: UInt64
        }
        guard let apiUrl = config.apiUrl else {
            throw ConsensusClientError("apiUrl is required to read an account's nonce")
        }
        let trimmed = apiUrl.hasSuffix("/") ? String(apiUrl.dropLast()) : apiUrl
        guard let url = URL(string: "\(trimmed)/account/\(pathSegment(did))/nonce") else {
            throw ConsensusClientError("Invalid API URL")
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ConsensusClientError("Failed to fetch nonce")
        }

        guard let answer = try? JSONDecoder().decode(ApiResponse<AccountNonce>.self, from: data),
              answer.success, let nonce = answer.data?.nonce else {
            throw ConsensusClientError("Failed to parse nonce response")
        }

        return nonce
    }

    // MARK: - Sign Message Creation

    private func createSignMessage(txType: String, didDocument: [String: Any]) -> String {
        if let jsonData = try? JSONSerialization.data(withJSONObject: didDocument, options: .sortedKeys),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return "{}"
    }

    private func createSignMessageForTransfer(tx: TransferTx) -> String {
        return """
        Transfer
        From: \(tx.fromDid)
        To: \(tx.toDid)
        Amount: \(tx.amount)
        Memo: \(tx.memo ?? "")
        Nonce: \(tx.nonce)
        """
    }

    // MARK: - File Manifest Transaction Methods

    /// Store a file manifest on the blockchain.
    ///
    /// `contentHash` and `chunkMerkleRoot` are 32 bytes of hex. `signFunction`
    /// signs `storeFileManifestMessage` over every field of the manifest sent
    /// and its nonce. A text field holding a line break is refused with a
    /// validation error before anything is signed.
    ///
    /// The nonce is the lowest one above the account's base that the chain
    /// doesn't show used and no other write in flight from this process holds.
    /// A write refused in its block after its signature and nonce verify still
    /// spends its nonce; calling again signs anew under another.
    public func storeFileManifest(
        subgroveId: String,
        fileKey: String,
        filename: String,
        contentType: String,
        totalSize: Int,
        contentHash: String,
        chunkCount: Int,
        chunkSize: Int,
        chunkMerkleRoot: String,
        ownerDid: String,
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        let contentHashBytes = try hashBytes(fromHex: contentHash, field: "contentHash")
        let chunkMerkleRootBytes = try hashBytes(fromHex: chunkMerkleRoot, field: "chunkMerkleRoot")
        let totalSizeValue = try unsignedField("totalSize", totalSize, as: UInt64.self)
        let chunkCountValue = try unsignedField("chunkCount", chunkCount, as: UInt32.self)
        let chunkSizeValue = try unsignedField("chunkSize", chunkSize, as: UInt32.self)

        return try await submitUnderNextNonce(did: ownerDid) { nonce in
            let signMessage = try storeFileManifestMessage(
                subgroveId: subgroveId,
                fileKey: fileKey,
                ownerDid: ownerDid,
                filename: filename,
                contentType: contentType,
                totalSize: totalSizeValue,
                contentHash: contentHashBytes,
                chunkCount: chunkCountValue,
                chunkSize: chunkSizeValue,
                chunkMerkleRoot: chunkMerkleRootBytes,
                nonce: unsignedField("nonce", nonce, as: UInt64.self)
            )
            let signatureBytes = Array(try signFunction(Data(signMessage.utf8), privateKey)).map { Int($0) }

            let tx = StoreFileManifestConsensusBody(
                subgrove_id: subgroveId,
                file_key: fileKey,
                filename: filename,
                content_type: contentType,
                total_size: totalSize,
                content_hash: contentHashBytes.map { Int($0) },
                chunk_count: chunkCount,
                chunk_size: chunkSize,
                chunk_merkle_root: chunkMerkleRootBytes.map { Int($0) },
                owner_did: ownerDid,
                signature: signatureBytes,
                public_key_id: publicKeyId,
                nonce: nonce
            )
            return try encodeTransaction(txType: "StoreFileManifest", transaction: tx)
        }
    }

    /// Delete a file manifest from the blockchain.
    ///
    /// `signFunction` signs `deleteFileManifestMessage` over the subgrove ID,
    /// file key, owner DID, and the transaction's nonce. A text field holding a
    /// line break is refused with a validation error before anything is signed.
    ///
    /// The nonce is the lowest one above the account's base that the chain
    /// doesn't show used and no other write in flight from this process holds.
    /// A write refused in its block after its signature and nonce verify still
    /// spends its nonce; calling again signs anew under another.
    public func deleteFileManifest(
        subgroveId: String,
        fileKey: String,
        ownerDid: String,
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        return try await submitUnderNextNonce(did: ownerDid) { nonce in
            let signMessage = try deleteFileManifestMessage(
                subgroveId: subgroveId,
                fileKey: fileKey,
                ownerDid: ownerDid,
                nonce: unsignedField("nonce", nonce, as: UInt64.self)
            )
            let signatureBytes = Array(try signFunction(Data(signMessage.utf8), privateKey)).map { Int($0) }

            let tx = DeleteFileManifestConsensusBody(
                subgrove_id: subgroveId,
                file_key: fileKey,
                owner_did: ownerDid,
                signature: signatureBytes,
                public_key_id: publicKeyId,
                nonce: nonce
            )
            return try encodeTransaction(txType: "DeleteFileManifest", transaction: tx)
        }
    }
}

// MARK: - Transaction Submission Helpers

/// The JSON body `POST /tx/submit` takes for a transaction:
/// `{"<Variant>": {...}}`, the server's `Transaction` enum as serde writes it.
/// Encoded with no key conversion, so the variant name keeps its case.
internal func encodeTransaction<T: Encodable>(txType: String, transaction: T) throws -> Data {
    return try JSONEncoder().encode([txType: transaction])
}

/// The message a DeregisterSubgrove transaction is signed over:
/// `DeregisterSubgrove:<subgroveId>:<ownerDid>:<nonce>`.
internal func deregisterSubgroveMessage(subgroveId: String, ownerDid: String, nonce: Int) -> String {
    return "DeregisterSubgrove:\(subgroveId):\(ownerDid):\(nonce)"
}

/// `data` as the JSON text a StoreData transaction carries: serialized once,
/// with sorted keys, each number written as `WireJSON.foundation` writes it
/// (a `Double` in its shortest form), which is the text the node stores and
/// a verified read returns as that same value. Refuses anything but a JSON
/// object.
internal func storeDataText(_ data: Any) throws -> String {
    guard data is [String: Any] else {
        throw ValidationError("data must be a JSON object")
    }
    return String(decoding: try WireJSON.foundation(data).serialized, as: UTF8.self)
}

/// A StoreData transaction under `nonce`, signed with `sign` over
/// `storeDataMessage` built from its own fields.
internal func signedStoreData(
    subgroveId: String,
    key: String,
    data: String,
    ownerDid: String,
    publicKeyId: String,
    nonce: Int,
    sign: (Data) throws -> Data
) throws -> DataStoreTx {
    var tx = DataStoreTx(
        subgroveId: subgroveId,
        key: key,
        data: data,
        ownerDid: ownerDid,
        publicKeyId: publicKeyId,
        nonce: nonce
    )
    let message = try storeDataMessage(
        subgroveId: tx.subgroveId,
        key: tx.key,
        ownerDid: tx.ownerDid,
        data: tx.dataBytes,
        nonce: unsignedField("nonce", tx.nonce, as: UInt64.self)
    )
    tx.signature = Array(try sign(Data(message.utf8)))
    return tx
}

/// The `/tx/submit` body of `tx` signed with `sign`: the signature is over
/// `registerSubgroveMessage(tx)`, which hashes the very JSON sent (signature
/// aside), so the node decodes the fields that were signed. A data or file
/// registration the node refuses is refused before signing.
internal func signedRegisterSubgroveBody(_ tx: RegisterSubgroveTx, sign: (Data) throws -> Data) throws -> Data {
    try tx.checkStorageRules()
    var unsigned = tx
    unsigned.signature = []
    let message = try registerSubgroveMessage(json: unsigned.wireJSON())
    var signed = unsigned
    signed.signature = Array(try sign(Data(message.utf8)))
    return try signed.submitBody()
}

/// Reads a `POST /tx/submit` answer: `{ success, data: { tx_hash, code, log }, error }`.
/// CheckTx refuses a transaction with HTTP 200 and a nonzero `code`, which is
/// reported as `success: false`.
///
/// A non-2xx answer whose body isn't a JSON object (the API refuses a body it
/// can't read, with a 400, 415, or 422, in plain text) is thrown as an
/// `HTTPError` carrying the status and the body's text, so the status decides
/// what becomes of the nonce.
internal func parseTxSubmitResponse(data: Data, statusCode: Int) throws -> BroadcastResult {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        guard (200...299).contains(statusCode) else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HTTPError(statusCode: statusCode, message: text.isEmpty ? "HTTP \(statusCode)" : text)
        }
        throw ConsensusClientError("Invalid JSON in /tx/submit response")
    }

    let success = json["success"] as? Bool ?? false
    guard success, let result = json["data"] as? [String: Any] else {
        let errMsg = (json["error"] as? String) ?? "HTTP \(statusCode)"
        return BroadcastResult(
            success: false, txHash: nil, errorCode: nil, errorMessage: errMsg, rawLog: errMsg
        )
    }

    let code = result["code"] as? Int ?? 0
    let hash = result["tx_hash"] as? String
    let log = result["log"] as? String

    return BroadcastResult(
        success: code == 0,
        txHash: hash,
        errorCode: code != 0 ? code : nil,
        errorMessage: code != 0 ? log : nil,
        rawLog: log
    )
}

/// A 32-byte hash given as hex, as bytes. The server's `[u8; 32]` fields take
/// them in JSON as an array of numbers.
internal func hashBytes(fromHex hex: String, field: String) throws -> Data {
    let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    guard let bytes = Data(hexString: clean), bytes.count == 32 else {
        throw ValidationError("\(field) must be 32 bytes of hex")
    }
    return bytes
}

// MARK: - File Manifest Consensus Transaction Types

// Field for field the server's `StoreFileManifestTx` with no `encryption`:
// `content_hash` and `chunk_merkle_root` are `[u8; 32]`, which JSON carries as
// arrays of numbers.
internal struct StoreFileManifestConsensusBody: Encodable {
    let subgrove_id: String
    let file_key: String
    let filename: String
    let content_type: String
    let total_size: Int
    let content_hash: [Int]
    let chunk_count: Int
    let chunk_size: Int
    let chunk_merkle_root: [Int]
    let owner_did: String
    let signature: [Int]
    let public_key_id: String
    let nonce: Int
}

internal struct DeleteFileManifestConsensusBody: Encodable {
    let subgrove_id: String
    let file_key: String
    let owner_did: String
    let signature: [Int]
    let public_key_id: String
    let nonce: Int
}

internal struct UnregisterStorageNodeConsensusBody: Encodable {
    let node_did: String
    let signature: [Int]
    let public_key_id: String
    let nonce: Int
}

// MARK: - Error

/// Consensus client error.
public func ConsensusClientError(_ message: String) -> WillowError {
    return WillowError(type: .network, message: message)
}
