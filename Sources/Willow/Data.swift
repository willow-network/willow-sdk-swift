import Foundation

// MARK: - Data Operations

/// Provides methods for data storage and retrieval with proof verification.
public class DataOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    // MARK: - Get Operations

    /// Gets an item with automatic proof verification.
    public func get(appId: String, subgroveId: String, key: String) async throws -> DataResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/apps/\(appId)/subgroves/\(subgroveId)/data/\(key)?include_proof=true"
        let response: DataResponse = try await client.get(path: path)

        // Verify proof if available
        if let proofData = response.proof?.proof {
            try await verifyProof(proofData, client: client)
        }

        return response
    }

    /// Gets an item without proof verification (faster but less secure).
    public func getUnverified(appId: String, subgroveId: String, key: String) async throws -> DataResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/apps/\(appId)/subgroves/\(subgroveId)/data/\(key)"
        return try await client.get(path: path)
    }

    // MARK: - Query Operations

    /// Queries data with automatic proof verification.
    public func query(appId: String, subgroveId: String, query: QueryRequest) async throws -> QueryResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        var queryWithProof = query
        queryWithProof.includeProof = true

        let path = "/apps/\(appId)/subgroves/\(subgroveId)/query"
        let response: QueryResponse = try await client.post(path: path, body: queryWithProof)

        // Verify proof if available
        if let proofData = response.proof {
            try await verifyProof(proofData, client: client)
        }

        return response
    }

    /// Queries data without proof verification.
    public func queryUnverified(appId: String, subgroveId: String, query: QueryRequest) async throws -> QueryResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/apps/\(appId)/subgroves/\(subgroveId)/query"
        return try await client.post(path: path, body: query)
    }

    // MARK: - Store Operations

    /// Stores an item.
    public func store(appId: String, subgroveId: String, key: String, data: [String: Any]) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let request = StoreRequest(key: key, data: data)
        let path = "/apps/\(appId)/subgroves/\(subgroveId)/data"
        let _: EmptyStoreResponse = try await client.post(path: path, body: request)
    }

    /// Stores multiple items in batch.
    public func batchStore(appId: String, subgroveId: String, items: [StoreRequest]) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/apps/\(appId)/subgroves/\(subgroveId)/data/batch"
        let batchRequest = BatchStoreRequest(items: items)
        let _: EmptyStoreResponse = try await client.post(path: path, body: batchRequest)
    }

    // MARK: - Update Operations

    /// Updates an item.
    public func update(appId: String, subgroveId: String, key: String, data: [String: Any]) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/apps/\(appId)/subgroves/\(subgroveId)/data/\(key)"
        let body = data.mapValues { AnyCodable($0) }
        let _: EmptyStoreResponse = try await client.put(path: path, body: body)
    }

    // MARK: - Delete Operations

    /// Deletes an item.
    public func delete(appId: String, subgroveId: String, key: String) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/apps/\(appId)/subgroves/\(subgroveId)/data/\(key)"
        try await client.delete(path: path)
    }

    // MARK: - Historical Query Operations

    /// Gets checkpoint state root information.
    public func getCheckpointStateRoot(subgroveId: String, checkpointId: String) async throws -> CheckpointInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/checkpoints/\(subgroveId)/\(checkpointId)/state-root"
        return try await client.get(path: path)
    }

    /// Queries historical indexed data from a checkpoint.
    /// Routes through consensus to available indexer nodes that serve historical data.
    public func queryHistorical(subgroveId: String, checkpointId: String, request: HistoricalQueryRequest) async throws -> HistoricalQueryResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/historical/query/\(subgroveId)/\(checkpointId)"
        return try await client.post(path: path, body: request)
    }

    /// Queries historical data with automatic proof verification.
    /// Forces proof inclusion and verifies the proof against the checkpoint's state root.
    public func queryHistoricalVerified(subgroveId: String, checkpointId: String, request: HistoricalQueryRequest) async throws -> HistoricalQueryResponse {
        // Force proof inclusion
        var requestWithProof = request
        requestWithProof.includeProof = true

        let response = try await queryHistorical(subgroveId: subgroveId, checkpointId: checkpointId, request: requestWithProof)

        // Verify the proof against checkpoint state root
        guard let proofHex = response.proof, !proofHex.isEmpty else {
            throw ProofError("Historical query did not return proof data despite include_proof=true")
        }

        // Decode hex proof
        let cleanHex = proofHex.hasPrefix("0x") ? String(proofHex.dropFirst(2)) : proofHex
        guard let proofBytes = Data(hexString: cleanHex) else {
            throw ProofError("Failed to decode historical proof hex")
        }

        // Verify proof and get computed root hash
        let result = try GroveDBVerifier.verifyProof(proofBytes: proofBytes)

        // Normalize and compare root hashes
        let computedRoot = result.rootHash.lowercased().replacingOccurrences(of: "0x", with: "")
        let expectedRoot = response.stateRoot.lowercased().replacingOccurrences(of: "0x", with: "")

        if computedRoot != expectedRoot {
            throw ProofError("Historical proof verification failed: computed root \(result.rootHash) does not match checkpoint state root \(response.stateRoot)")
        }

        return response
    }

    // MARK: - Proof Verification

    private func verifyProof(_ proofData: Data, client: WillowClient) async throws {
        // Always use light client for trustless verification.
        // This auto-initializes the light client on first use (trust-on-first-use).
        //
        // TODO: When mainnet/testnet launches, the light client should be initialized
        // with hardcoded checkpoint headers instead of trust-on-first-use for true
        // trustless verification from the start.
        let lc = try await client.getOrCreateLightClient()
        let expectedRootHash = try await lc.getVerifiedRootHash()

        // Verify the proof
        let result = try GroveDBVerifier.verifyProofAgainstRoot(proofBytes: proofData, expectedRootHash: expectedRootHash)
        if result.rootHash != expectedRootHash {
            throw ProofError("Root hash mismatch: expected \(expectedRootHash), got \(result.rootHash)")
        }
    }
}

// MARK: - Helper Types

private struct EmptyStoreResponse: Codable {}

private struct BatchStoreRequest: Codable {
    let items: [StoreRequest]
}

// MARK: - Query Builder

/// Builder for constructing query requests.
public class QueryBuilder {
    private var filters: [QueryFilter] = []
    private var search: QuerySearch?
    private var sort: QuerySort?
    private var limit_: Int?
    private var offset_: Int?
    private var includeProof: Bool = false

    public init() {}

    /// Adds an equals filter.
    @discardableResult
    public func equals(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "eq", value: value))
        return self
    }

    /// Adds a not equals filter.
    @discardableResult
    public func notEquals(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "ne", value: value))
        return self
    }

    /// Adds a greater than filter.
    @discardableResult
    public func greaterThan(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "gt", value: value))
        return self
    }

    /// Adds a greater than or equal filter.
    @discardableResult
    public func greaterThanOrEqual(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "gte", value: value))
        return self
    }

    /// Adds a less than filter.
    @discardableResult
    public func lessThan(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "lt", value: value))
        return self
    }

    /// Adds a less than or equal filter.
    @discardableResult
    public func lessThanOrEqual(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "lte", value: value))
        return self
    }

    /// Adds a contains filter.
    @discardableResult
    public func contains(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "contains", value: value))
        return self
    }

    /// Adds a full-text search.
    @discardableResult
    public func search(fields: [String], query: String) -> QueryBuilder {
        self.search = QuerySearch(fields: fields, query: query)
        return self
    }

    /// Sets ascending sort.
    @discardableResult
    public func sortAsc(_ field: String) -> QueryBuilder {
        self.sort = QuerySort(field: field, ascending: true)
        return self
    }

    /// Sets descending sort.
    @discardableResult
    public func sortDesc(_ field: String) -> QueryBuilder {
        self.sort = QuerySort(field: field, ascending: false)
        return self
    }

    /// Sets the limit.
    @discardableResult
    public func limit(_ limit: Int) -> QueryBuilder {
        self.limit_ = limit
        return self
    }

    /// Sets the offset.
    @discardableResult
    public func offset(_ offset: Int) -> QueryBuilder {
        self.offset_ = offset
        return self
    }

    /// Includes proof in response.
    @discardableResult
    public func withProof() -> QueryBuilder {
        self.includeProof = true
        return self
    }

    /// Builds the query request.
    public func build() -> QueryRequest {
        return QueryRequest(
            filters: filters,
            search: search,
            sort: sort,
            limit: limit_,
            offset: offset_,
            includeProof: includeProof
        )
    }
}
