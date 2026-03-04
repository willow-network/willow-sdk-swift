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
        chainId: String = "willow-chain",
        requestTimeoutSecs: TimeInterval = 30,
        maxRetries: Int = 3,
        retryDelaySecs: TimeInterval = 1.0
    ) {
        self.consensusRpcUrl = consensusRpcUrl
        self.apiUrl = apiUrl
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

    public init(
        success: Bool,
        txHash: String? = nil,
        height: Int64? = nil,
        errorCode: Int? = nil,
        errorMessage: String? = nil,
        rawLog: String? = nil
    ) {
        self.success = success
        self.txHash = txHash
        self.height = height
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.rawLog = rawLog
    }
}

// MARK: - Transaction Types

/// DID registration transaction.
public struct RegisterDidTx: Codable {
    public var didDocument: [String: AnyCodable]
    public var signature: String
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case didDocument = "did_document"
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(didDocument: [String: AnyCodable], signature: String = "", publicKeyId: String, nonce: Int) {
        self.didDocument = didDocument
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }
}

/// App registration transaction.
public struct RegisterAppTx: Codable {
    public var appId: String
    public var name: String
    public var description: String
    public var appType: String
    public var ownerDid: String
    public var admins: [String]
    public var initialFunding: Int?
    public var signature: String
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case appId = "app_id"
        case name
        case description
        case appType = "app_type"
        case ownerDid = "owner_did"
        case admins
        case initialFunding = "initial_funding"
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(
        appId: String,
        name: String,
        description: String,
        appType: String,
        ownerDid: String,
        admins: [String] = [],
        initialFunding: Int? = nil,
        signature: String = "",
        publicKeyId: String,
        nonce: Int
    ) {
        self.appId = appId
        self.name = name
        self.description = description
        self.appType = appType
        self.ownerDid = ownerDid
        self.admins = admins
        self.initialFunding = initialFunding
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }
}

/// DataStorage mode configuration for a subgrove.
public struct SubgroveDataStorage: Codable {
    public var name: String
    public var writers: [String]
    public var freeReaders: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case writers
        case freeReaders = "free_readers"
    }

    public init(name: String = "", writers: [String] = [], freeReaders: [String] = []) {
        self.name = name
        self.writers = writers
        self.freeReaders = freeReaders
    }
}

/// BlockchainIndexing mode configuration for a subgrove.
public struct SubgroveBlockchainIndexing: Codable {
    public init() {}
}

/// SubgroveMode: DataStorage or BlockchainIndexing.
public enum SubgroveMode: Codable {
    case dataStorage(SubgroveDataStorage)
    case blockchainIndexing(SubgroveBlockchainIndexing)

    enum CodingKeys: String, CodingKey {
        case dataStorage = "DataStorage"
        case blockchainIndexing = "BlockchainIndexing"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ds = try container.decodeIfPresent(SubgroveDataStorage.self, forKey: .dataStorage) {
            self = .dataStorage(ds)
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
        case .blockchainIndexing(let bi):
            try container.encode(bi, forKey: .blockchainIndexing)
        }
    }
}

/// Subgrove registration transaction.
public struct RegisterSubgroveTx: Codable {
    public var subgroveId: String
    public var appId: String
    public var schema: String
    public var ownerDid: String
    public var mode: SubgroveMode?
    public var signature: String
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case appId = "app_id"
        case schema
        case ownerDid = "owner_did"
        case mode
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(
        subgroveId: String,
        appId: String,
        schema: String,
        ownerDid: String,
        mode: SubgroveMode? = nil,
        signature: String = "",
        publicKeyId: String,
        nonce: Int
    ) {
        self.subgroveId = subgroveId
        self.appId = appId
        self.schema = schema
        self.ownerDid = ownerDid
        self.mode = mode
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
    public var signature: String
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
        signature: String = "",
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

/// Data storage transaction.
public struct DataStoreTx: Codable {
    public var appId: String
    public var subgroveId: String
    public var key: String
    public var data: String
    public var ownerDid: String
    public var signature: String
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case appId = "app_id"
        case subgroveId = "subgrove_id"
        case key
        case data
        case ownerDid = "owner_did"
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(
        appId: String,
        subgroveId: String,
        key: String,
        data: String,
        ownerDid: String,
        signature: String = "",
        publicKeyId: String,
        nonce: Int
    ) {
        self.appId = appId
        self.subgroveId = subgroveId
        self.key = key
        self.data = data
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
    private var nonceCache: [String: Int] = [:]

    public init(_ config: ConsensusConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.requestTimeoutSecs
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - High-Level Transaction Methods

    /// Register a DID on the blockchain.
    public func registerDid(
        didDocument: [String: Any],
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        let did = (didDocument["id"] as? String) ?? ""
        let nonce = try await getNextNonce(did: did)

        // Convert to AnyCodable for encoding
        let codableDocument = didDocument.mapValues { AnyCodable($0) }

        var tx = RegisterDidTx(
            didDocument: codableDocument,
            publicKeyId: publicKeyId,
            nonce: nonce
        )

        // Create sign message and sign
        let signMessage = createSignMessage(txType: "RegisterDid", didDocument: didDocument)
        let signatureData = try signFunction(Data(signMessage.utf8), privateKey)
        tx.signature = signatureData.map { String(format: "%02x", $0) }.joined()

        return try await broadcastTransaction(txType: "RegisterDid", transaction: tx)
    }

    /// Register an application on the blockchain.
    public func registerApp(
        appId: String,
        name: String,
        description: String,
        appType: String,
        ownerDid: String,
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data,
        admins: [String] = []
    ) async throws -> BroadcastResult {
        let nonce = try await getNextNonce(did: ownerDid)

        var tx = RegisterAppTx(
            appId: appId,
            name: name,
            description: description,
            appType: appType,
            ownerDid: ownerDid,
            admins: admins,
            publicKeyId: publicKeyId,
            nonce: nonce
        )

        let signMessage = createSignMessageForApp(tx: tx)
        let signatureData = try signFunction(Data(signMessage.utf8), privateKey)
        tx.signature = signatureData.map { String(format: "%02x", $0) }.joined()

        return try await broadcastTransaction(txType: "RegisterApp", transaction: tx)
    }

    /// Register a subgrove (dataset) on the blockchain.
    public func registerSubgrove(
        subgroveId: String,
        appId: String,
        schema: String,
        ownerDid: String,
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data,
        mode: SubgroveMode? = nil
    ) async throws -> BroadcastResult {
        let nonce = try await getNextNonce(did: ownerDid)

        var tx = RegisterSubgroveTx(
            subgroveId: subgroveId,
            appId: appId,
            schema: schema,
            ownerDid: ownerDid,
            mode: mode,
            publicKeyId: publicKeyId,
            nonce: nonce
        )

        let signMessage = createSignMessageForSubgrove(tx: tx)
        let signatureData = try signFunction(Data(signMessage.utf8), privateKey)
        tx.signature = signatureData.map { String(format: "%02x", $0) }.joined()

        return try await broadcastTransaction(txType: "RegisterSubgrove", transaction: tx)
    }

    /// Transfer tokens between DIDs.
    public func transfer(
        fromDid: String,
        toDid: String,
        amount: Int64,
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data,
        memo: String? = nil
    ) async throws -> BroadcastResult {
        let nonce = try await getNextNonce(did: fromDid)

        var tx = TransferTx(
            fromDid: fromDid,
            toDid: toDid,
            amount: amount,
            memo: memo,
            publicKeyId: publicKeyId,
            nonce: nonce
        )

        let signMessage = createSignMessageForTransfer(tx: tx)
        let signatureData = try signFunction(Data(signMessage.utf8), privateKey)
        tx.signature = signatureData.map { String(format: "%02x", $0) }.joined()

        return try await broadcastTransaction(txType: "Transfer", transaction: tx)
    }

    /// Store data on the blockchain.
    public func storeData(
        appId: String,
        subgroveId: String,
        key: String,
        data: Any,
        ownerDid: String,
        privateKey: Data,
        publicKeyId: String,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        let nonce = try await getNextNonce(did: ownerDid)

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let dataString = String(data: jsonData, encoding: .utf8) ?? "{}"

        var tx = DataStoreTx(
            appId: appId,
            subgroveId: subgroveId,
            key: key,
            data: dataString,
            ownerDid: ownerDid,
            publicKeyId: publicKeyId,
            nonce: nonce
        )

        let signMessage = createSignMessageForDataStore(tx: tx)
        let signatureData = try signFunction(Data(signMessage.utf8), privateKey)
        tx.signature = signatureData.map { String(format: "%02x", $0) }.joined()

        return try await broadcastTransaction(txType: "DataStore", transaction: tx)
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

    // MARK: - Private Methods

    internal func broadcastPrivacyTransaction<T: Encodable>(txType: String, transaction: T) async throws -> BroadcastResult {
        return try await broadcastTransaction(txType: txType, transaction: transaction)
    }

    internal func getNextNonce(did: String) async throws -> Int {
        return try await _getNextNonce(did: did)
    }

    private func broadcastTransaction<T: Encodable>(txType: String, transaction: T) async throws -> BroadcastResult {
        let wrapper = [txType: transaction]
        let txData = try JSONEncoder().encode(wrapper)
        let txBase64 = txData.base64EncodedString()

        let result = try await rpcRequest(method: "broadcast_tx_sync", params: ["tx": txBase64])

        let code = result["code"] as? Int ?? 0
        let hash = result["hash"] as? String
        let log = result["log"] as? String

        return BroadcastResult(
            success: code == 0,
            txHash: hash,
            errorCode: code != 0 ? code : nil,
            errorMessage: code != 0 ? log : nil,
            rawLog: log
        )
    }

    private func queryTransaction(txHash: String) async throws -> [String: Any]? {
        do {
            return try await rpcRequest(method: "tx", params: ["hash": txHash, "prove": false])
        } catch {
            return nil
        }
    }

    private func rpcRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ]

        var lastError: Error?

        for attempt in 0...config.maxRetries {
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
                if attempt < config.maxRetries {
                    try await Task.sleep(nanoseconds: UInt64(config.retryDelaySecs * Double(attempt + 1) * 1_000_000_000))
                }
            }
        }

        throw lastError ?? ConsensusClientError("Request failed after \(config.maxRetries + 1) attempts")
    }

    private func _getNextNonce(did: String) async throws -> Int {
        do {
            let currentNonce = try await getAccountNonce(did: did)
            let nextNonce = currentNonce + 1
            nonceCache[did] = nextNonce
            return nextNonce
        } catch {
            let currentNonce = nonceCache[did] ?? 0
            let nextNonce = currentNonce + 1
            nonceCache[did] = nextNonce
            return nextNonce
        }
    }

    private func getAccountNonce(did: String) async throws -> Int {
        guard let apiUrl = config.apiUrl else {
            return nonceCache[did] ?? 0
        }

        guard let url = URL(string: "\(apiUrl)/account/\(did.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? did)/nonce") else {
            throw ConsensusClientError("Invalid API URL")
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ConsensusClientError("Failed to fetch nonce")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = json["success"] as? Bool, success,
              let dataObj = json["data"] as? [String: Any],
              let nonce = dataObj["nonce"] as? Int else {
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

    private func createSignMessageForApp(tx: RegisterAppTx) -> String {
        var msg = """
        RegisterApp
        App ID: \(tx.appId)
        Name: \(tx.name)
        Description: \(tx.description)
        Type: \(tx.appType)
        Owner: \(tx.ownerDid)
        Admins: \(tx.admins.joined(separator: ","))
        Nonce: \(tx.nonce)
        """
        if let funding = tx.initialFunding, funding > 0 {
            msg += "\nFunding: \(funding)"
        }
        return msg
    }

    private func createSignMessageForSubgrove(tx: RegisterSubgroveTx) -> String {
        if let mode = tx.mode {
            switch mode {
            case .blockchainIndexing(let bi):
                return """
                RegisterSubgrove
                Subgrove ID: \(tx.subgroveId)
                App ID: \(tx.appId)
                Mode: BlockchainIndexing
                Schema: \(tx.schema)
                Owner: \(tx.ownerDid)
                Nonce: \(tx.nonce)
                """
            case .dataStorage(let ds):
                return """
                RegisterSubgrove
                Subgrove ID: \(tx.subgroveId)
                App ID: \(tx.appId)
                Name: \(ds.name)
                Schema: \(tx.schema)
                Owner: \(tx.ownerDid)
                Writers: \(ds.writers.joined(separator: ","))
                Readers: \(ds.freeReaders.joined(separator: ","))
                Nonce: \(tx.nonce)
                """
            }
        }
        // Default: DataStorage with empty values
        return """
        RegisterSubgrove
        Subgrove ID: \(tx.subgroveId)
        App ID: \(tx.appId)
        Name: \
        Schema: \(tx.schema)
        Owner: \(tx.ownerDid)
        Writers: \
        Readers: \
        Nonce: \(tx.nonce)
        """
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

    private func createSignMessageForDataStore(tx: DataStoreTx) -> String {
        return """
        DataStore
        App ID: \(tx.appId)
        Subgrove ID: \(tx.subgroveId)
        Key: \(tx.key)
        Data: \(tx.data)
        Owner: \(tx.ownerDid)
        Nonce: \(tx.nonce)
        """
    }
}

// MARK: - Error

/// Consensus client error.
public func ConsensusClientError(_ message: String) -> WillowError {
    return WillowError(type: .network, message: message)
}
