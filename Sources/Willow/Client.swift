import Foundation

// MARK: - Client Configuration

/// Configuration options for the Willow client.
public struct ClientConfig {
    public let baseURL: URL
    public let timeout: TimeInterval
    public let retryConfig: RetryConfig
    public let autoVerify: Bool

    public init(
        baseURL: URL,
        timeout: TimeInterval = 30,
        retryConfig: RetryConfig = .default,
        autoVerify: Bool = true
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.retryConfig = retryConfig
        self.autoVerify = autoVerify
    }
}

// MARK: - Willow Client

/// Main client for interacting with the Willow network.
public class WillowClient {
    private let config: ClientConfig
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var currentSession: Session?
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

    /// Creates a new Willow client.
    public init(baseURL: String, timeout: TimeInterval = 30, autoVerify: Bool = true) throws {
        guard let url = URL(string: baseURL) else {
            throw ConfigError("Invalid base URL: \(baseURL)")
        }

        self.config = ClientConfig(baseURL: url, timeout: timeout, autoVerify: autoVerify)

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout * 2
        self.session = URLSession(configuration: sessionConfig)

        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase

        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
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
    /// This method auto-initializes a light client using trust-on-first-use:
    /// the first block received from the node is trusted, and all subsequent
    /// blocks are verified against it.
    ///
    /// - Important: TODO: When mainnet/testnet launches, replace trust-on-first-use
    ///   with hardcoded checkpoint headers for true trustless initialization.
    ///   Trust-on-first-use is secure for subsequent operations but trusts the
    ///   initial block from the connected node.
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
            // Auto-initialize light client
            // TODO: When mainnet/testnet launches, use hardcoded checkpoint headers
            // instead of trust-on-first-use for true trustless initialization from genesis.
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

    // MARK: - Authentication

    /// Returns the current session.
    public func getSession() -> Session? {
        return currentSession
    }

    /// Returns the current identity.
    public func getIdentity() -> Identity? {
        return currentIdentity
    }

    /// Checks if the client is authenticated.
    public var isAuthenticated: Bool {
        guard let session = currentSession else { return false }
        return !session.isExpired
    }

    /// Throws if not authenticated.
    public func requireAuth() throws {
        guard isAuthenticated else {
            throw WillowErrors.notAuthenticated
        }
    }

    /// Registers a DID.
    public func registerDID(_ document: DidDocument) async throws -> DidInfo {
        return try await post(path: "/did/register", body: document)
    }

    /// Authenticates with an identity.
    public func authenticate(_ identity: Identity) async throws -> Session {
        // Step 1: Get challenge
        let challengeRequest = ["did": identity.did]
        let challenge: AuthenticationChallenge = try await post(path: "/auth/challenge", body: challengeRequest)

        // Step 2: Sign challenge
        let signature = try signAuthenticationChallenge(
            challenge: challenge,
            did: identity.did,
            keyPair: identity.keyPair
        )

        // Step 3: Submit response
        let response = AuthenticationResponse(
            did: identity.did,
            challenge: challenge.challenge,
            nonce: challenge.nonce,
            signature: signature,
            publicKeyId: identity.publicKeyId
        )

        let session: Session = try await post(path: "/auth/authenticate", body: response)

        self.currentSession = session
        self.currentIdentity = identity
        return session
    }

    /// Logs out and clears the session.
    public func logout() {
        currentSession = nil
        currentIdentity = nil
    }

    // MARK: - Root Hash

    /// Gets the current root hash from the node.
    public func getRootHash() async throws -> String {
        struct RootHashResponse: Codable {
            let rootHash: String

            enum CodingKeys: String, CodingKey {
                case rootHash = "root_hash"
            }
        }
        let response: RootHashResponse = try await get(path: "/state/root")
        return response.rootHash
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

    // MARK: - HTTP Methods

    internal func get<T: Decodable>(path: String) async throws -> T {
        let url = config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuthHeaders(&request)
        return try await execute(request)
    }

    internal func post<T: Decodable, B: Encodable>(path: String, body: B) async throws -> T {
        let url = config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        addAuthHeaders(&request)
        return try await execute(request)
    }

    internal func put<T: Decodable, B: Encodable>(path: String, body: B) async throws -> T {
        let url = config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        addAuthHeaders(&request)
        return try await execute(request)
    }

    internal func delete(path: String) async throws {
        let url = config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        addAuthHeaders(&request)
        let _: EmptyResponse = try await execute(request)
    }

    private func addAuthHeaders(_ request: inout URLRequest) {
        if let session = currentSession, let token = session.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        var lastError: Error?
        var backoff = config.retryConfig.initialBackoff

        for attempt in 0...config.retryConfig.maxRetries {
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError("Invalid response type")
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw HTTPError(statusCode: httpResponse.statusCode, message: message)
                }

                // Handle empty response
                if T.self == EmptyResponse.self {
                    return EmptyResponse() as! T
                }

                return try decoder.decode(T.self, from: data)
            } catch let error as HTTPError where shouldRetry(statusCode: error.statusCode) && attempt < config.retryConfig.maxRetries {
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * config.retryConfig.backoffFactor, config.retryConfig.maxBackoff)
            } catch let error as URLError where attempt < config.retryConfig.maxRetries {
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

    /// Closes the client and releases resources.
    public func close() {
        session.invalidateAndCancel()
        lightClient?.stop()
    }
}

// MARK: - Empty Response

private struct EmptyResponse: Codable {}
