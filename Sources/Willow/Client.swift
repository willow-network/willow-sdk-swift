import Foundation

// MARK: - Client Configuration

/// Configuration options for the Willow client.
public struct ClientConfig {
    public let baseURL: URL
    /// Optional indexer node URL. When set, GraphQL and SQL queries are routed here.
    public let indexerURL: URL?
    public let timeout: TimeInterval
    public let retryConfig: RetryConfig
    /// Never read: `data.get` and `data.query` always verify, and
    /// `getUnverified` and `queryUnverified` never do, whatever this says.
    @available(*, deprecated, message: "Never read: data.get and data.query always verify; getUnverified and queryUnverified never do.")
    public var autoVerify: Bool {
        return storedAutoVerify
    }
    private let storedAutoVerify: Bool
    /// Managed-tier API key (`wk_…`). When set, the SDK sends
    /// `X-API-Key: <apiKey>` on every request via the URLSession's
    /// `httpAdditionalHeaders`. Mint a key at
    /// https://dashboard.willow.tech/account. Required for queries and
    /// writes against managed `api.willow.tech` / `indexer.willow.tech`.
    public let apiKey: String?
    /// The CometBFT RPC (typically port 26657) of a consensus node you run or
    /// trust. Verified reads (`data.get`, `data.query`) compare a proof's
    /// root with the app hash this node's headers carry, and trust it as a
    /// client trusts its own node: the SDK doesn't verify validator
    /// signatures. Without it, verified reads work only against an API on
    /// this machine (whose node's RPC is taken to be at port 26657) or with a
    /// light client you set (`WillowClient.setLightClient`); otherwise they
    /// throw before sending anything. Never point it at the API: a header
    /// the API serves can't vouch for a proof the API serves.
    public let consensusRpcURL: URL?
    /// The chain the default light client follows. Nil (the default) takes
    /// the chain the consensus RPC reports (`/status` `node_info.network`);
    /// set, a consensus RPC serving another chain is refused.
    public let chainId: String?

    public init(
        baseURL: URL,
        indexerURL: URL? = nil,
        timeout: TimeInterval = 30,
        retryConfig: RetryConfig = .default,
        autoVerify: Bool = true,
        apiKey: String? = nil,
        consensusRpcURL: URL? = nil,
        chainId: String? = nil
    ) {
        self.baseURL = baseURL
        self.indexerURL = indexerURL
        self.timeout = timeout
        self.retryConfig = retryConfig
        self.storedAutoVerify = autoVerify
        self.apiKey = apiKey
        self.consensusRpcURL = consensusRpcURL
        self.chainId = chainId
    }
}

// MARK: - Willow Client

/// Main client for interacting with the Willow network.
public class WillowClient {
    private let config: ClientConfig
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var currentIdentity: Identity?
    private let nonces: NonceAllocator
    private var lightClient: LightClient?
    private var lightClientInitTask: Task<LightClient, Error>?
    /// The session the default light client reads the consensus RPC
    /// through, when given (tests); else its own.
    private let rpcSession: URLSession?
    /// The session for storage node requests (`files`): no API key goes to a
    /// storage node, and each request times out as the client's do.
    internal let storageSession: URLSession

    /// Data operations.
    public private(set) lazy var data: DataOperations = DataOperations(client: self)

    /// Registration operations.
    public private(set) lazy var registration: RegistrationOperations = RegistrationOperations(client: self)

    /// Token operations.
    public private(set) lazy var token: TokenOperations = TokenOperations(client: self)

    /// Validator operations.
    public private(set) lazy var validators: ValidatorOperations = ValidatorOperations(client: self)

    /// Indexing operations.
    public private(set) lazy var indexing: IndexingOperations = IndexingOperations(client: self)

    /// File storage operations.
    public private(set) lazy var files: FileOperations = FileOperations(client: self)

    /// Computed fields registry for SDK-layer derived field computation.
    public let computedFieldRegistry = ComputedFieldRegistry()

    /// Creates a new Willow client.
    /// - Parameters:
    ///   - baseURL: Base URL of the Willow validator API.
    ///   - indexerURL: Optional indexer node URL for routing GraphQL/SQL queries.
    ///   - timeout: Request timeout in seconds.
    ///   - autoVerify: Ignored: `data.get` and `data.query` always verify,
    ///     and `getUnverified` and `queryUnverified` never do.
    ///   - apiKey: Managed-tier API key (see `ClientConfig.apiKey`).
    ///   - consensusRpcURL: The CometBFT RPC of a consensus node you run or
    ///     trust, which verified reads take their headers from (see
    ///     `ClientConfig.consensusRpcURL`).
    ///   - chainId: The chain verified reads follow; nil takes the one the
    ///     consensus RPC reports (see `ClientConfig.chainId`).
    public convenience init(
        baseURL: String, indexerURL: String? = nil, timeout: TimeInterval = 30, autoVerify: Bool = true, apiKey: String? = nil,
        consensusRpcURL: String? = nil, chainId: String? = nil
    ) throws {
        guard let url = URL(string: baseURL) else {
            throw ConfigError("Invalid base URL: \(baseURL)")
        }

        let parsedIndexerURL: URL?
        if let indexerStr = indexerURL {
            guard let iURL = URL(string: indexerStr) else {
                throw ConfigError("Invalid indexer URL: \(indexerStr)")
            }
            parsedIndexerURL = iURL
        } else {
            parsedIndexerURL = nil
        }

        let parsedRpcURL: URL?
        if let rpc = consensusRpcURL {
            guard let rpcURL = URL(string: rpc), rpcURL.scheme != nil, rpcURL.host != nil else {
                throw ConfigError("Invalid consensus RPC URL: \(rpc)")
            }
            parsedRpcURL = rpcURL
        } else {
            parsedRpcURL = nil
        }

        let config = ClientConfig(
            baseURL: url, indexerURL: parsedIndexerURL, timeout: timeout, autoVerify: autoVerify, apiKey: apiKey,
            consensusRpcURL: parsedRpcURL, chainId: chainId
        )

        self.init(config: config, session: WillowClient.makeSession(timeout: timeout, apiKey: apiKey), nonces: .shared)
    }

    /// A session whose requests wait at most `timeout` for data and
    /// `timeout * 2` in all, sending `X-API-Key: apiKey` when given.
    internal static func makeSession(timeout: TimeInterval, apiKey: String? = nil) -> URLSession {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout * 2
        if let apiKey = apiKey {
            sessionConfig.httpAdditionalHeaders = ["X-API-Key": apiKey]
        }
        return URLSession(configuration: sessionConfig)
    }

    /// Testing seam: supply the configuration, a `URLSession` (e.g. backed by
    /// a stub `URLProtocol`), the nonce allocator (a fresh one unless given;
    /// the public initializers use the process's shared one), and the
    /// sessions the default light client reads the consensus RPC through and
    /// `files` reach storage nodes through.
    internal init(
        config: ClientConfig, session: URLSession, nonces: NonceAllocator = NonceAllocator(), rpcSession: URLSession? = nil,
        storageSession: URLSession? = nil
    ) {
        self.config = config
        self.session = session
        self.nonces = nonces
        self.rpcSession = rpcSession
        self.storageSession = storageSession ?? WillowClient.makeSession(timeout: config.timeout)

        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase

        // No key conversion: every type this client decodes spells its
        // snake_case keys in its CodingKeys, and `.convertFromSnakeCase` would
        // rewrite "root_hash" to "rootHash" before matching, so none would.
        self.decoder = JSONDecoder()
    }

    /// Creates a client whose verified reads compare proofs with `lightClient`.
    public convenience init(baseURL: String, lightClient: LightClient, timeout: TimeInterval = 30) throws {
        try self.init(baseURL: baseURL, timeout: timeout, autoVerify: true)
        self.lightClient = lightClient
    }

    // MARK: - Light Client

    /// Returns whether a light client is configured.
    public func hasLightClient() -> Bool {
        return lightClient != nil
    }

    /// Sets the light client verified reads compare proofs with.
    public func setLightClient(_ lightClient: LightClient) {
        self.lightClient = lightClient
    }

    /// Gets the light client.
    public func getLightClient() -> LightClient? {
        return lightClient
    }

    /// Gets or creates the light client verified reads compare proofs with.
    ///
    /// With none set, it creates one that reads headers from the consensus
    /// RPC: `consensusRpcURL`, or, for an API on this machine (`localhost`,
    /// `127.0.0.1`, or `::1` at port 3031), that node's RPC at port 26657.
    /// It trusts that node, as a client trusts its own node: it takes the
    /// first header the node serves as served, and checks later ones only as
    /// `LightClient.verify(block:trustedState:)` does, without verifying
    /// validator signatures. It follows the chain `ClientConfig.chainId`
    /// names, or, without one, the chain the RPC reports (its `/status`
    /// `node_info.network`, else its latest header's chain ID). With no RPC,
    /// it throws a config error before sending anything: a header the API
    /// serves can't vouch for a proof the API serves.
    public func getOrCreateLightClient() async throws -> LightClient {
        // Return existing light client if available
        if let existing = lightClient {
            return existing
        }

        // If initialization is already in progress, wait for it
        if let task = lightClientInitTask {
            return try await task.value
        }

        guard let rpc = consensusRPC() else {
            throw ConfigError(
                "Verified reads have no trusted header source: set consensusRpcURL to the CometBFT RPC of a consensus node "
                    + "you run or trust (or set a light client with setLightClient). The SDK doesn't take headers from the API "
                    + "(\(config.baseURL.absoluteString)): a header the API serves can't vouch for a proof the API serves.")
        }

        // Start initialization
        let session = self.rpcSession
        let configuredChainId = config.chainId
        let task = Task<LightClient, Error> {
            let rpcSession = session ?? LightClient.makeSession(rpcTimeout: LightClientConfig.default.rpcTimeout)
            let chainId: String
            if let configured = configuredChainId {
                chainId = configured
            } else {
                chainId = try await LightClient.chainId(at: rpc, session: rpcSession)
            }
            let lightClientConfig = LightClientConfig(
                chainId: chainId,
                validatorEndpoints: [rpc],
                trustThreshold: TrustThreshold(numerator: 2, denominator: 3),
                trustingPeriod: 86400, // 24 hours
                maxClockDrift: 30,     // 30 seconds
                autoSync: false
            )

            let lc = try LightClient(lightClientConfig)
            lc.session = rpcSession

            // Take the consensus node's latest header as served.
            try await lc.sync()

            return lc
        }

        lightClientInitTask = task
        let lc = try await task.value
        self.lightClient = lc
        lightClientInitTask = nil
        return lc
    }

    /// The consensus RPC verified reads take headers from, without a trailing
    /// slash: `consensusRpcURL`, else the local node's for a local API; nil
    /// when there is neither.
    internal func consensusRPC() -> String? {
        guard let url = config.consensusRpcURL ?? WillowClient.localConsensusRPC(forAPI: config.baseURL) else {
            return nil
        }
        var text = url.absoluteString
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    /// For an API on this machine (host `localhost`, `127.0.0.1`, or `::1`,
    /// port 3031, the API's default), its node's CometBFT RPC: the same
    /// scheme and host at port 26657. Nil for any other API URL: the SDK
    /// doesn't guess where a remote API's consensus node is.
    internal static func localConsensusRPC(forAPI api: URL) -> URL? {
        guard var components = URLComponents(url: api, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              components.port == 3031
        else {
            return nil
        }
        components.port = 26657
        components.percentEncodedPath = ""
        components.percentEncodedQuery = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    // MARK: - Identity Management

    /// Returns the current identity.
    public func getIdentity() -> Identity? {
        return currentIdentity
    }

    /// Sets the identity for request signing.
    public func setIdentity(_ identity: Identity) {
        self.currentIdentity = identity
    }

    /// Checks if an identity is set.
    public func hasIdentity() -> Bool {
        return currentIdentity != nil
    }

    /// Clears the current identity.
    public func clearIdentity() {
        currentIdentity = nil
    }

    /// Throws if no identity is set.
    public func requireAuth() throws {
        guard hasIdentity() else {
            throw AuthenticationError("Identity not set. Call setIdentity() first.")
        }
    }

    /// Registers a DID.
    ///
    /// The API has no DID registration route: a DID is registered on chain by
    /// a RegisterDid transaction, which this client doesn't build. This
    /// throws a validation error and sends nothing.
    @available(*, deprecated, message: "The API serves no DID registration route; a DID is registered by a RegisterDid transaction.")
    public func registerDID(_ document: DidDocument) async throws -> DidInfo {
        throw ValidationError(
            "The API has no DID registration route: a DID is registered by a RegisterDid transaction "
                + "submitted to POST /tx/submit, which this client doesn't build"
        )
    }

    // MARK: - Transactions

    /// The identity that signs this client's transactions.
    internal func transactionIdentity() throws -> Identity {
        guard let identity = currentIdentity else {
            throw AuthenticationError("Identity not set. Call setIdentity() first.")
        }
        return identity
    }

    /// `did`'s nonce state as `GET /account/{did}/nonce` reports it: the base
    /// alone (the API serves no bitmap of the nonces used above it).
    internal func accountNonces(did: String) async throws -> ChainNonces {
        struct AccountNonce: Codable {
            let nonce: UInt64
        }
        let response: ApiResponse<AccountNonce> = try await get(path: "/account/\(pathSegment(did))/nonce")
        return try ChainNonces(base: try unwrap(response, "account nonce").nonce)
    }

    /// Signs and submits the transaction `build` makes under a nonce for
    /// `did` that no other write in flight holds (see `NonceAllocator`): the
    /// lowest one above the account's base that isn't held or seen used.
    ///
    /// A transaction the API refuses (CheckTx, or a 4xx before it) gives its
    /// nonce back, unless the refusal says the nonce is held by a pending
    /// transaction, already used, or spent. A submission whose fate is unknown
    /// (a network error, a 5xx, or a 408) may still land, so its nonce stays
    /// held for 120 s (the node holds a pending transaction's nonce for 3
    /// blocks or 120 s, whichever ends first), and it is thrown as a
    /// `TransactionSubmitError` carrying the signed transaction, to
    /// `resubmit(_:)`. The result, and a CheckTx refusal (`TransactionError`),
    /// carry it too.
    internal func submitUnderNextNonce(did: String, _ build: (Int) throws -> Data) async throws -> BroadcastResult {
        let account = NonceAccount(did: did, api: config.baseURL.absoluteString)
        let (result, submission) = try await nonces.signAndSend(account, chain: try await accountNonces(did: did), build: build) { body in
            (try await self.submitTransaction(body), .accepted)
        }
        return result.with(submission)
    }

    /// Sends a write again under its own nonce: `submission` is the signed
    /// transaction a `TransactionSubmitError`, a `TransactionError`, or a
    /// `BroadcastResult` carries. Its body is sent unchanged, so whichever
    /// copy lands first spends the nonce and the other is refused: the write
    /// runs at most once. This is how to retry a write whose outcome is
    /// unknown (`TransactionSubmitError`); calling the write again would sign
    /// it under a fresh nonce, and both could run.
    ///
    /// The nonce is held while it is in flight, as for a new write. When the
    /// node already holds the identical transaction ("tx already exists in
    /// cache"), that counts as accepted: a successful result with no
    /// transaction hash. Throws as the write does: `TransactionSubmitError`
    /// when the outcome is again unknown (resubmit it again),
    /// `TransactionError` when CheckTx refuses it (a refusal saying the nonce
    /// is already used means some transaction under it landed, perhaps this
    /// write's earlier copy: read what it wrote). Throws a transaction error
    /// and sends nothing when this client has seen the nonce used, or has
    /// handed it to another write after this one's 120 s hold lapsed.
    public func resubmit(_ submission: SignedSubmission) async throws -> BroadcastResult {
        let account = NonceAccount(did: submission.did, api: config.baseURL.absoluteString)
        let result = try await nonces.resubmit(submission, on: account) { body -> (BroadcastResult, NonceOutcome) in
            do {
                return (try await self.submitTransaction(body), .accepted)
            } catch let error as HTTPError where error.message.contains("tx already exists in cache") {
                // The node's mempool holds these exact bytes: it is pending.
                return (BroadcastResult(success: true, rawLog: error.message), .accepted)
            }
        }
        return result.with(submission)
    }

    // MARK: - Root Hash

    /// Gets the node's current GroveDB root hash (`GET /state/root-hash`).
    ///
    /// This is the serving node's own state root, unverified; for the light
    /// client's trusted app hash use `getVerifiedRootHash()`.
    public func getRootHash() async throws -> String {
        struct RootHash: Codable {
            let rootHash: String

            enum CodingKeys: String, CodingKey {
                case rootHash = "root_hash"
            }
        }
        let response: ApiResponse<RootHash> = try await get(path: "/state/root-hash")
        return try unwrap(response, "root hash").rootHash
    }

    /// The app hash of the light client's trusted header (see
    /// `LightClient.getVerifiedRootHash()`).
    public func getVerifiedRootHash() async throws -> String {
        guard let lc = lightClient else {
            throw LightClientError("No light client configured")
        }
        return try await lc.getVerifiedRootHash()
    }

    // MARK: - Health

    /// Gets the health status of the node.
    public func getHealth() async throws -> HealthStatus {
        return try await get(path: "/health")
    }

    /// Returns the indexer URL if configured, otherwise the base URL.
    internal func indexerBaseURL() -> URL {
        return config.indexerURL ?? config.baseURL
    }

    // MARK: - HTTP Methods

    // `path` is percent-encoded: build it from literal segments and
    // `pathSegment(_:)` for each value, so a `/`, `?`, `#`, or `%` in a value
    // stays inside its segment. A query goes in `query`, not in `path`.

    internal func get<T: Decodable>(path: String, query: [(String, String)] = []) async throws -> T {
        return try await send(method: "GET", base: config.baseURL, path: path, query: query, body: nil)
    }

    internal func post<T: Decodable, B: Encodable>(path: String, body: B) async throws -> T {
        return try await send(method: "POST", base: config.baseURL, path: path, body: try encoder.encode(body))
    }

    /// Posts to an explicit base URL (used for indexer routing).
    internal func postToBase<T: Decodable, B: Encodable>(base: URL, path: String, body: B) async throws -> T {
        return try await send(method: "POST", base: base, path: path, body: try encoder.encode(body))
    }

    /// Posts `body` encoded without key conversion, so keys the caller
    /// chose (a filter's field, a GraphQL variable) go out as written. The
    /// body's own CodingKeys spell the wire names.
    internal func postVerbatim<T: Decodable, B: Encodable>(base: URL? = nil, path: String, body: B) async throws -> T {
        return try await send(method: "POST", base: base ?? config.baseURL, path: path, body: try WillowClient.verbatimBody(body))
    }

    /// The body `postVerbatim` sends for `body`: JSON with sorted keys and no
    /// key conversion.
    internal static func verbatimBody<B: Encodable>(_ body: B) throws -> Data {
        let verbatim = JSONEncoder()
        verbatim.outputFormatting = [.sortedKeys]
        return try verbatim.encode(body)
    }

    /// Posts bytes already written as the body.
    internal func postData<T: Decodable>(path: String, body: Data) async throws -> T {
        return try await send(method: "POST", base: config.baseURL, path: path, body: body)
    }

    internal func put<T: Decodable, B: Encodable>(path: String, body: B) async throws -> T {
        return try await send(method: "PUT", base: config.baseURL, path: path, body: try encoder.encode(body))
    }

    internal func delete(path: String) async throws {
        let _: EmptyResponse = try await send(method: "DELETE", base: config.baseURL, path: path, body: nil)
    }

    /// Submits a transaction already encoded as JSON (`{"<Variant>": {...}}`)
    /// to the API's `POST /tx/submit`, which hands it to CheckTx.
    ///
    /// The API answers HTTP 200 with a nonzero `code` when CheckTx refuses the
    /// transaction; that is thrown as a `TransactionError`. It is sent once,
    /// with no automatic retry: a 5xx can follow a transaction that reached
    /// the mempool. Such a write is retried with `resubmit(_:)`, under the
    /// same nonce. A write refused in its block after its signature and nonce
    /// verify spends its nonce, so a retry of that one is signed again under a
    /// nonce not yet used.
    @discardableResult
    internal func submitTransaction(_ body: Data) async throws -> BroadcastResult {
        let (data, status) = try await sendRaw(method: "POST", base: config.baseURL, path: "/tx/submit", body: body, retry: false)
        let result = try parseTxSubmitResponse(data: data, statusCode: status)
        guard result.success else {
            throw TransactionError(
                message: result.errorMessage ?? result.rawLog ?? "transaction refused",
                txHash: result.txHash,
                errorCode: result.errorCode ?? 0
            )
        }
        return result
    }

    /// Unwraps the API's `{ success, data, error }` envelope: its `data`, or
    /// its `error` thrown (a not-found error as `NotFoundError`).
    internal func unwrap<T: Codable>(_ response: ApiResponse<T>, _ what: String) throws -> T {
        if response.success, let data = response.data {
            return data
        }
        if let error = response.error, error.lowercased().contains("not found") {
            throw WillowError(type: .notFound, message: "\(what): \(error)")
        }
        throw NetworkError(response.error ?? "The API returned no \(what)")
    }

    /// GETs `path` and unwraps the envelope the API answers with.
    internal func getData<T: Codable>(path: String, query: [(String, String)] = [], _ what: String) async throws -> T {
        let response: ApiResponse<T> = try await get(path: path, query: query)
        return try unwrap(response, what)
    }

    private func send<T: Decodable>(method: String, base: URL, path: String, query: [(String, String)] = [], body: Data?) async throws -> T {
        let (data, _) = try await sendRaw(method: method, base: base, path: path, query: query, body: body)
        // Handle empty response
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try decoder.decode(T.self, from: data)
    }

    /// Sends a request, retrying network errors, 5xx, and 429 with backoff
    /// unless `retry` is false, and returns the body and status of a 2xx answer.
    /// Each attempt is built and signed anew, so a nonce-signed attempt carries
    /// its own nonce.
    private func sendRaw(method: String, base: URL, path: String, query: [(String, String)] = [], body: Data?, retry: Bool = true) async throws -> (Data, Int) {
        let url = try WillowClient.requestURL(base: base, path: path, query: query)
        let toAPI = isAPI(base)
        return try await execute(maxRetries: retry ? config.retryConfig.maxRetries : 0) {
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let body = body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            try self.addAuthHeaders(&request, toAPI: toAPI, path: path, body: body ?? Data())
            return request
        }
    }

    /// The URL for the percent-encoded `path` under `base`, with `query`
    /// percent-encoded as its query string. The path is appended to the base
    /// URL's path as given, so the target the client signs is the one sent.
    internal static func requestURL(base: URL, path: String, query: [(String, String)] = []) throws -> URL {
        guard isPercentEncodedPath(path), path.hasPrefix("/"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else {
            throw ConfigError("Invalid request path: \(path)")
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.percentEncodedPath = basePath + path
        components.percentEncodedQuery = query.isEmpty ? nil : try query.map { name, value in
            guard let name = name.addingPercentEncoding(withAllowedCharacters: queryComponentAllowed),
                  let value = value.addingPercentEncoding(withAllowedCharacters: queryComponentAllowed)
            else {
                throw ConfigError("Invalid query item: \(name)")
            }
            return "\(name)=\(value)"
        }.joined(separator: "&")
        components.fragment = nil
        guard let url = components.url else {
            throw ConfigError("Invalid request URL: \(base.absoluteString) \(path)")
        }
        return url
    }

    /// Characters a query name or value keeps unencoded: those allowed in a
    /// query, less the `&`, `=`, `+`, and `?` that would change its meaning.
    private static let queryComponentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        return allowed
    }()

    /// Whether `path` uses only characters allowed in a URL path, with each
    /// `%` starting a two-digit escape.
    private static func isPercentEncodedPath(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%" {
                guard index + 2 < scalars.count,
                      scalars[index + 1].properties.isASCIIHexDigit,
                      scalars[index + 2].properties.isASCIIHexDigit
                else {
                    return false
                }
                index += 3
                continue
            }
            guard CharacterSet.urlPathAllowed.contains(scalar) else {
                return false
            }
            index += 1
        }
        return true
    }

    /// The path and query the API receives for `url`: the request line's
    /// target, less any path the API base URL carries (a proxy mounted under a
    /// path strips it before the API sees the request).
    internal func apiTarget(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? ""
        if target.isEmpty {
            target = "/"
        }
        if let query = components?.percentEncodedQuery {
            target += "?" + query
        }
        var basePath = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        if !basePath.isEmpty, target.hasPrefix(basePath + "/") {
            target = String(target.dropFirst(basePath.count))
        }
        return target
    }

    /// Whether `base` is the API (rather than an indexer).
    private func isAPI(_ base: URL) -> Bool {
        return base == config.baseURL
    }

    /// Whether `method` and `target` (a path and query as the API receives
    /// them) name one of the API's reads that act on the caller's DID:
    /// `GET /data/:sg/:key`, `GET /proof/:sg/:key`, `POST /query/:sg`,
    /// `POST /sql/:sg`, and `POST /graphql/:sg` (read rights), and the key
    /// grant reads `GET /key-grants/:sg`, `GET /key-grants/:sg/:did`, and
    /// `GET /proof/key-grant/:sg/:did`, which the API answers only for a
    /// nonce-signed caller.
    internal static func isSubgroveReadRoute(method: String, target: String) -> Bool {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard path.hasPrefix("/") else { return false }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0.isEmpty }) else { return false }
        if method == "GET", segments[0] == "key-grants" {
            return segments.count == 2 || segments.count == 3
        }
        switch (method, segments.count) {
        case ("GET", 4):
            return segments[0] == "proof" && segments[1] == "key-grant"
        case ("GET", 3):
            return segments[0] == "data" || segments[0] == "proof"
        case ("POST", 2):
            return ["query", "sql", "graphql"].contains(String(segments[0]))
        default:
            return false
        }
    }

    /// Signs the request when an identity is set.
    ///
    /// A read of subgrove data sent to the API (see `isSubgroveReadRoute`) is
    /// signed with a one-time nonce over its method, its path and query as
    /// sent, and its body (`body` must be the exact bytes it sends); only that
    /// form carries the DID's read rights. Every other request is
    /// signed in the older `{METHOD}:{PATH}:{TIMESTAMP}` form, which the API
    /// accepts with 300 s of clock skew either way and from its first second
    /// up. Requests to an indexer keep the older form too: indexers verify
    /// neither.
    private func addAuthHeaders(_ request: inout URLRequest, toAPI: Bool, path: String, body: Data) throws {
        guard let identity = currentIdentity, let method = request.httpMethod, let url = request.url else {
            return
        }
        let headers: [String: String]
        let target = apiTarget(url)
        if toAPI && WillowClient.isSubgroveReadRoute(method: method, target: target) {
            headers = try signRequestWithNonce(method: method, pathAndQuery: target, body: body, identity: identity)
        } else if toAPI {
            headers = try signRequest(method: method, path: target, identity: identity)
        } else {
            headers = try signRequest(method: method, path: path, identity: identity)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func execute(maxRetries: Int, _ makeRequest: () throws -> URLRequest) async throws -> (Data, Int) {
        var lastError: Error?
        var backoff = config.retryConfig.initialBackoff

        for attempt in 0...maxRetries {
            do {
                let request = try makeRequest()
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError("Invalid response type")
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    throw HTTPError(statusCode: httpResponse.statusCode, message: WillowClient.errorMessage(data))
                }

                return (data, httpResponse.statusCode)
            } catch let error as HTTPError where shouldRetry(statusCode: error.statusCode) && attempt < maxRetries {
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * config.retryConfig.backoffFactor, config.retryConfig.maxBackoff)
            } catch let error as URLError where attempt < maxRetries {
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * config.retryConfig.backoffFactor, config.retryConfig.maxBackoff)
            } catch {
                throw error
            }
        }

        throw lastError ?? NetworkError("Request failed after retries")
    }

    /// The message of a refused request: the envelope's (or a bare body's)
    /// `error` when the API sent one, else the body as text.
    internal static func errorMessage(_ body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = json["error"] as? String, !error.isEmpty {
            return error
        }
        return String(data: body, encoding: .utf8) ?? "Unknown error"
    }

    private func shouldRetry(statusCode: Int) -> Bool {
        return statusCode >= 500 || statusCode == 429
    }

    // MARK: - Computed Fields

    /// Registers computed fields for a specific dataset (subgrove).
    ///
    /// Computed fields are SDK-layer derived values calculated from proven data.
    /// For example, price ratios computed from proven reserve amounts.
    ///
    /// - Parameters:
    ///   - datasetId: The dataset (subgrove) ID
    ///   - fields: The computed field definitions
    public func registerComputedFields(datasetId: String, fields: ComputedFieldSet) {
        computedFieldRegistry.register(datasetId: datasetId, fields: fields)
    }

    /// Closes the client and releases resources.
    public func close() {
        session.invalidateAndCancel()
        storageSession.invalidateAndCancel()
        lightClient?.stop()
    }
}

// MARK: - Path Segments

/// `raw` percent-encoded as one URL path segment: everything outside the
/// characters a path allows is encoded, and so are `/` and a segment of only
/// dots, so the value cannot split or climb the path.
internal func pathSegment(_ raw: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    if encoded == "." || encoded == ".." {
        return String(repeating: "%2E", count: encoded.count)
    }
    return encoded
}

// MARK: - Empty Response

private struct EmptyResponse: Codable {}
