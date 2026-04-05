import Foundation

// MARK: - Indexing Operations

/// Provides methods for blockchain indexing and GraphQL queries.
public class IndexingOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    // MARK: - GraphQL Queries

    /// Executes a GraphQL query against a subgrove.
    /// When an indexer URL is configured, the query is routed there.
    public func query(subgroveId: String, request: GraphQLRequest) async throws -> GraphQLResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        // Enable proof by default if light client is available
        var requestWithProof = request
        if client.hasLightClient() {
            requestWithProof.includeProof = true
        }

        let base = client.indexerBaseURL()
        let path = "/graphql/\(subgroveId)"
        let response: GraphQLResponse = try await client.postToBase(base: base, path: path, body: requestWithProof)

        // Verify proof if available
        if client.hasLightClient(), let proofData = response.proof {
            try await verifyProof(proofData, client: client)
        }

        return response
    }

    /// Executes a GraphQL query without proof verification (faster).
    public func queryUnverified(subgroveId: String, request: GraphQLRequest) async throws -> GraphQLResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        var requestNoProof = request
        requestNoProof.includeProof = false

        let path = "/graphql/\(subgroveId)"
        return try await client.post(path: path, body: requestNoProof)
    }

    /// Convenience method for executing GraphQL queries.
    public func execute(subgroveId: String, query: String, variables: [String: Any]? = nil) async throws -> GraphQLResponse {
        let request = GraphQLRequest(
            query: query,
            variables: variables?.mapValues { AnyCodable($0) }
        )
        return try await self.query(subgroveId: subgroveId, request: request)
    }

    /// Execute a SQL query against a subgrove.
    /// When an indexer URL is configured, the query is routed there.
    public func sqlQuery(
        subgroveId: String,
        query: String,
        includeProof: Bool = true
    ) async throws -> SqlResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let request = SqlRequest(query: query, includeProof: includeProof)
        let base = client.indexerBaseURL()
        let path = "/sql/\(subgroveId)"
        let response: SqlResponse = try await client.postToBase(base: base, path: path, body: request)
        return response
    }

    /// Executes a query and decodes the result into the provided type.
    public func executeWithResult<T: Decodable>(subgroveId: String, query: String, variables: [String: Any]? = nil, resultType: T.Type) async throws -> T {
        let response = try await execute(subgroveId: subgroveId, query: query, variables: variables)

        if let errors = response.errors, !errors.isEmpty {
            throw GraphQLQueryError("GraphQL error: \(errors[0].message)")
        }

        guard let data = response.data else {
            throw GraphQLQueryError("No data in response")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Subgrove Operations

    /// Lists all available subgroves.
    public func listSubgroves() async throws -> [SubgroveInfo] {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/subgroves")
    }

    /// Retrieves information about a specific subgrove.
    public func getSubgrove(subgroveId: String) async throws -> SubgroveInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/subgroves/\(subgroveId)")
    }

    // MARK: - Indexer Operations

    /// Lists all indexers.
    public func listIndexers() async throws -> [IndexerInfo] {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/indexers")
    }

    /// Retrieves information about a specific indexer.
    public func getIndexer(indexerId: String) async throws -> IndexerInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/indexers/\(indexerId)")
    }

    /// Retrieves the status of an indexer for a subgrove.
    public func getIndexerStatus(indexerId: String, subgroveId: String) async throws -> IndexerInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/indexers/\(indexerId)/status/\(subgroveId)"
        return try await client.get(path: path)
    }

    // MARK: - Proof Verification

    private func verifyProof(_ proofData: Data, client: WillowClient) async throws {
        guard let lc = client.getLightClient() else {
            throw LightClientConfigError("Light client not initialized")
        }

        // Get the trusted root hash
        let expectedRootHash = try await lc.getVerifiedRootHash()

        // Verify the GroveDB proof
        let result = try GroveDBVerifier.verifyProofAgainstRoot(proofBytes: proofData, expectedRootHash: expectedRootHash)
        if result.rootHash != expectedRootHash {
            throw ProofError("Root hash mismatch: expected \(expectedRootHash), got \(result.rootHash)")
        }
    }
}

// MARK: - GraphQL Query Builder

/// Builder for constructing GraphQL queries.
public class GraphQLQueryBuilder {
    private var request: GraphQLRequest

    public init(query: String) {
        self.request = GraphQLRequest(query: query)
    }

    /// Adds a variable to the query.
    @discardableResult
    public func variable(_ name: String, value: Any) -> GraphQLQueryBuilder {
        if request.variables == nil {
            request.variables = [:]
        }
        request.variables?[name] = AnyCodable(value)
        return self
    }

    /// Sets multiple variables.
    @discardableResult
    public func variables(_ vars: [String: Any]) -> GraphQLQueryBuilder {
        if request.variables == nil {
            request.variables = [:]
        }
        for (key, value) in vars {
            request.variables?[key] = AnyCodable(value)
        }
        return self
    }

    /// Sets the operation name.
    @discardableResult
    public func operationName(_ name: String) -> GraphQLQueryBuilder {
        request.operationName = name
        return self
    }

    /// Enables proof inclusion.
    @discardableResult
    public func includeProof() -> GraphQLQueryBuilder {
        request.includeProof = true
        return self
    }

    /// Builds the GraphQLRequest.
    public func build() -> GraphQLRequest {
        return request
    }
}

// MARK: - Convenience Extensions

extension IndexingOperations {
    /// Queries with a builder pattern.
    public func query(subgroveId: String, _ configure: (GraphQLQueryBuilder) -> Void) async throws -> GraphQLResponse {
        let builder = GraphQLQueryBuilder(query: "")
        configure(builder)
        return try await query(subgroveId: subgroveId, request: builder.build())
    }
}
