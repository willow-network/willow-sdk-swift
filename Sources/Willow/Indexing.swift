import Foundation

// MARK: - Indexing Operations

/// Provides methods for blockchain indexing and GraphQL queries.
public class IndexingOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    // MARK: - GraphQL Queries

    /// Executes a GraphQL query against a subgrove
    /// (`POST /graphql/{subgroveId}`), routed to the indexer URL when one is
    /// configured.
    ///
    /// The answer is not verified. The proof the node can attach
    /// (`includeProof`) lists value hashes and a state root, which don't
    /// bind the GraphQL `data`, so the SDK returns it as `proof` (JSON bytes)
    /// without checking it, light client or not. Variables are sent with
    /// their names as written.
    public func query(subgroveId: String, request: GraphQLRequest) async throws -> GraphQLResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/graphql/\(pathSegment(subgroveId))"
        return try await client.postVerbatim(base: client.indexerBaseURL(), path: path, body: request)
    }

    /// Executes a GraphQL query against the API without asking for a proof
    /// (`include_proof: false`). Like `query`, the answer is not verified.
    public func queryUnverified(subgroveId: String, request: GraphQLRequest) async throws -> GraphQLResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        var requestNoProof = request
        requestNoProof.includeProof = false

        let path = "/graphql/\(pathSegment(subgroveId))"
        return try await client.postVerbatim(path: path, body: requestNoProof)
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
        includeProof: Bool = false
    ) async throws -> SqlResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let request = SqlRequest(query: query, includeProof: includeProof)
        let base = client.indexerBaseURL()
        let path = "/sql/\(pathSegment(subgroveId))"
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

    /// Lists the blockchain-indexing subgroves (`GET /subgroves/indexed`).
    public func listSubgroves() async throws -> [SubgroveInfo] {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.getData(path: "/subgroves/indexed", "subgroves")
    }

    /// Retrieves information about a specific subgrove (`GET /subgroves/{id}`).
    public func getSubgrove(subgroveId: String) async throws -> SubgroveInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.getData(path: "/subgroves/\(pathSegment(subgroveId))", "subgrove")
    }

    // MARK: - Indexer Operations

    /// Lists all indexers (`GET /indexers`).
    public func listIndexers() async throws -> [IndexerInfo] {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.getData(path: "/indexers", "indexers")
    }

    /// Retrieves information about a specific indexer (`GET /indexers/{did}`).
    public func getIndexer(indexerId: String) async throws -> IndexerInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.getData(path: "/indexers/\(pathSegment(indexerId))", "indexer")
    }

    /// Retrieves the status of an indexer for a subgrove.
    ///
    /// The API serves no per-subgrove indexer status, so this throws a
    /// validation error and sends nothing; `getIndexer(indexerId:)` lists the
    /// subgroves an indexer serves.
    @available(*, deprecated, message: "The API serves no per-subgrove indexer status; use getIndexer(indexerId:).")
    public func getIndexerStatus(indexerId: String, subgroveId: String) async throws -> IndexerInfo {
        throw ValidationError("The API serves no per-subgrove indexer status; getIndexer(indexerId:) lists the subgroves an indexer serves")
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

    /// Asks the node to attach its proof object, which the SDK returns
    /// unverified (see `IndexingOperations.query`).
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
