import Foundation

// MARK: - Client Configuration

/// Configuration options for the Willow client.
public struct ClientConfig {
    public let baseURL: URL
    /// Optional indexer node URL. When set, GraphQL and SQL queries are routed here.
    public let indexerURL: URL?
    public let timeout: TimeInterval
    public let retryConfig: RetryConfig
    public let autoVerify: Bool
    /// Managed-tier API key (`wk_…`). When set, the SDK sends
    /// `X-API-Key: <apiKey>` on every request via the URLSession's
    /// `httpAdditionalHeaders`. Mint a key at
    /// https://dashboard.willow.tech/account. Required for queries and
    /// writes against managed `api.willow.tech` / `indexer.willow.tech`.
    public let apiKey: String?

    public init(
        baseURL: URL,
        indexerURL: URL? = nil,
        timeout: TimeInterval = 30,
        retryConfig: RetryConfig = .default,
        autoVerify: Bool = true,
        apiKey: String? = nil
    ) {
        self.baseURL = baseURL
        self.indexerURL = indexerURL
        self.timeout = timeout
        self.retryConfig = retryConfig
        self.autoVerify = autoVerify
        self.apiKey = apiKey
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
    private var lightClient: LightClient?
    private var lightClientInitTask: Task<LightClient, Error>?

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
    ///   - autoVerify: Whether to automatically verify proofs.
    public convenience init(baseURL: String, indexerURL: String? = nil, timeout: TimeInterval = 30, autoVerify: Bool = true, apiKey: String? = nil) throws {
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

        let config = ClientConfig(baseURL: url, indexerURL: parsedIndexerURL, timeout: timeout, autoVerify: autoVerify, apiKey: apiKey)

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout * 2
        if let apiKey = apiKey {
            sessionConfig.httpAdditionalHeaders = ["X-API-Key": apiKey]
        }
        self.init(config: config, session: URLSession(configuration: sessionConfig))
    }

    /// Testing seam: supply the configuration and a `URLSession` (e.g. backed
    /// by a stub `URLProtocol`).
    internal init(config: ClientConfig, session: URLSession) {
        self.config = config
        self.session = session

        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase

        // No key conversion: every type this client decodes spells its
        // snake_case keys in its CodingKeys, and `.convertFromSnakeCase` would
        // rewrite "root_hash" to "rootHash" before matching, so none would.
        self.decoder = JSONDecoder()
    }

    /// Creates a client with a light client for trustless verification.
    public convenience init(baseURL: String, lightClient: LightClient, timeout: TimeInterval = 30) throws {
        try self.init(baseURL: baseURL, timeout: timeout, autoVerify: true)
        self.lightClient = lightClient
    }

    // MARK: - Light Client

    /// Returns whether a light client is configured.
    public func hasLightClient() -> Bool {
        return lightClient != nil
    }

    /// Sets the light client for trustless verification.
    public func setLightClient(_ lightClient: LightClient) {
        self.lightClient = lightClient
    }

    /// Gets the light client.
    public func getLightClient() -> LightClient? {
        return lightClient
    }

    /// Gets or creates the light client for trustless verification.
    ///
    /// Trust-on-first-use bootstrap: the first verified header is trusted,
    /// and every subsequent header chains from it cryptographically. Pin a
    /// known-good checkpoint header in production deployments.
    public func getOrCreateLightClient() async throws -> LightClient {
        // Return existing light client if available
        if let existing = lightClient {
            return existing
        }

        // If initialization is already in progress, wait for it
        if let task = lightClientInitTask {
            return try await task.value
        }

        // Start initialization
        let task = Task<LightClient, Error> {
            let lightClientConfig = LightClientConfig(
                chainId: "willow-chain",
                validatorEndpoints: [config.baseURL.absoluteString.replacingOccurrences(of: ":3031", with: ":26657")],
                trustThreshold: TrustThreshold(numerator: 2, denominator: 3),
                trustingPeriod: 86400, // 24 hours
                maxClockDrift: 30,     // 30 seconds
                autoSync: false
            )

            let lc = try LightClient(lightClientConfig)

            // Sync to get initial trusted state (trust-on-first-use)
            try await lc.sync()

            return lc
        }

        lightClientInitTask = task
        let lc = try await task.value
        self.lightClient = lc
        lightClientInitTask = nil
        return lc
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
    public func registerDID(_ document: DidDocument) async throws -> DidInfo {
        return try await post(path: "/did/register", body: document)
    }

    // MARK: - Root Hash

    /// Gets the node's current GroveDB root hash (`GET /state/root-hash`).
    ///
    /// This is the serving node's own state root, unverified; for a root checked
    /// against validator signatures use `getVerifiedRootHash()`.
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

    /// Gets the verified root hash from the light client.
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
    /// transaction; that is thrown as a `TransactionError`. It is sent once: a
    /// 5xx can follow a transaction that reached the mempool, and resending it
    /// would be refused as a replay. A data or file write refused in its block
    /// after its signature and nonce verify still spends its nonce, so a retry
    /// is signed again under the next free nonce.
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

    /// Unwraps the API's `{ success, data, error }` envelope.
    internal func unwrap<T: Codable>(_ response: ApiResponse<T>, _ what: String) throws -> T {
        if response.success, let data = response.data {
            return data
        }
        if let error = response.error, error.lowercased().contains("not found") {
            throw NotFoundError(what)
        }
        throw NetworkError(response.error ?? "The API returned no \(what)")
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
    /// them) name one of the API's reads of subgrove data:
    /// `GET /data/:sg/:key`, `GET /proof/:sg/:key`, `POST /query/:sg`,
    /// `POST /sql/:sg`, and `POST /graphql/:sg`.
    internal static func isSubgroveReadRoute(method: String, target: String) -> Bool {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard path.hasPrefix("/") else { return false }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0.isEmpty }) else { return false }
        switch (method, segments.count) {
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
                    let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw HTTPError(statusCode: httpResponse.statusCode, message: message)
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
