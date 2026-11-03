import Foundation

// MARK: - Data Operations

/// Provides methods for data storage and retrieval with proof verification.
public class DataOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    // MARK: - Get Operations

    /// Gets an item and verifies it against a GroveDB proof.
    ///
    /// Reads the value from `GET /data/{subgroveId}/{key}` and its proof from
    /// `GET /proof/{subgroveId}/{key}`, then requires that the proof descends to
    /// the subgrove's data tree, proves `key` there with the value served, and
    /// hashes to the light client's verified root. It returns the value the
    /// proof proves. Any failure throws; the value is never returned
    /// unverified.
    ///
    /// The proof verifier cannot verify a proof from the chain yet, so this
    /// throws for every live read: it decodes proof integers as fixed-width
    /// where grovedb writes bincode varints, it hashes Merk nodes with SHA-256
    /// where grovedb-merk uses BLAKE3 over length-prefixed fields, it does not
    /// check a `KVValueHash` node's value against its value hash, and the root
    /// is compared with the light client's latest trusted header rather than
    /// the header at the proof's height. Use `getUnverified` to read without a
    /// proof.
    public func get(subgroveId: String, key: String) async throws -> DataResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let value = try await fetchValue(subgroveId: subgroveId, key: key, client: client)

        let proofResponse: ApiResponse<ServedProof> = try await client.get(path: "/proof/\(pathSegment(subgroveId))/\(pathSegment(key))")
        let served = try client.unwrap(proofResponse, "proof")
        let cleanHex = served.proof.hasPrefix("0x") ? String(served.proof.dropFirst(2)) : served.proof
        guard let proofBytes = Data(hexString: cleanHex), !proofBytes.isEmpty else {
            throw ProofError("The API returned no proof for \(subgroveId)/\(key)")
        }

        let result = try GroveDBVerifier.verifyProof(proofBytes: proofBytes, expectedPath: DataOperations.dataPath(subgroveId))
        let proven = try DataOperations.requireProven(subgroveId: subgroveId, key: key, value: value, in: result)

        let lc = try await client.getOrCreateLightClient()
        let expectedRootHash = try await lc.getVerifiedRootHash()
        guard result.rootHash.lowercased() == expectedRootHash.lowercased() else {
            throw ProofError("Root hash mismatch: expected \(expectedRootHash), got \(result.rootHash)")
        }

        return DataResponse(
            key: key,
            data: proven,
            proof: DataProof(proof: proofBytes, rootHash: result.rootHash, height: served.height ?? 0, verifiedAt: Int64(Date().timeIntervalSince1970))
        )
    }

    /// Gets an item without proof verification (faster but less secure), from
    /// `GET /data/{subgroveId}/{key}`.
    public func getUnverified(subgroveId: String, key: String) async throws -> DataResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let value = try await fetchValue(subgroveId: subgroveId, key: key, client: client)
        return DataResponse(key: key, data: value, proof: nil)
    }

    /// The value `GET /data/{subgroveId}/{key}` serves: the stored JSON object
    /// (or `{"hex": ...}` for bytes that are not JSON).
    private func fetchValue(subgroveId: String, key: String, client: WillowClient) async throws -> [String: AnyCodable] {
        let response: ApiResponse<AnyCodable> = try await client.get(path: "/data/\(pathSegment(subgroveId))/\(pathSegment(key))")
        let value = try client.unwrap(response, "Data")
        guard let object = value.value as? [String: Any] else {
            throw SerializationError("The value at \(subgroveId)/\(key) is not a JSON object")
        }
        return object.mapValues { AnyCodable($0) }
    }

    /// The GroveDB path of a subgrove's data tree: `subgroves / {id} / data`.
    internal static func dataPath(_ subgroveId: String) -> [[UInt8]] {
        return [Array("subgroves".utf8), Array(subgroveId.utf8), Array("data".utf8)]
    }

    /// Requires that `result` proves `key` in the subgrove's data tree with an
    /// item whose bytes are the JSON of `value` (compared as JSON, since the API
    /// re-serializes it), and returns the proven value.
    internal static func requireProven(subgroveId: String, key: String, value: [String: AnyCodable], in result: GroveDBVerificationResult) throws -> [String: AnyCodable] {
        let path = dataPath(subgroveId)
        guard let proved = result.results.first(where: { $0.path == path && $0.key == Data(key.utf8) }) else {
            throw ProofError("The proof does not prove key \(key) in \(subgroveId)'s data")
        }
        guard let itemBytes = groveItemBytes(proved.value) else {
            throw ProofError("The proven element for \(key) is not an item")
        }
        let served = NSDictionary(dictionary: value.mapValues { $0.value })
        let proven: Any
        if let json = try? JSONSerialization.jsonObject(with: itemBytes, options: [.fragmentsAllowed]) {
            proven = json
        } else {
            proven = ["hex": itemBytes.hexString]
        }
        guard let provenObject = proven as? [String: Any], served.isEqual(to: provenObject) else {
            throw ProofError("The value served for \(key) is not the value the proof proves")
        }
        return provenObject.mapValues { AnyCodable($0) }
    }

    /// The bytes of a serialized GroveDB `Element::Item(bytes, flags)`: variant
    /// 0, then the bytes with a bincode varint length (big-endian beyond one
    /// byte). `nil` for any other element.
    internal static func groveItemBytes(_ element: Data) -> Data? {
        let bytes = [UInt8](element)
        guard bytes.count >= 2, bytes[0] == 0 else { return nil }
        var index = 1
        let length: UInt64
        switch bytes[index] {
        case 0..<251:
            length = UInt64(bytes[index])
            index += 1
        case 251, 252, 253:
            let width = bytes[index] == 251 ? 2 : (bytes[index] == 252 ? 4 : 8)
            guard bytes.count >= index + 1 + width else { return nil }
            length = bytes[(index + 1)..<(index + 1 + width)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            index += 1 + width
        default:
            return nil
        }
        guard length <= UInt64(bytes.count - index) else { return nil }
        return Data(bytes[index..<(index + Int(length))])
    }

    // MARK: - Query Operations

    /// Queries data with automatic proof verification.
    /// Applies computed fields if registered for the subgrove.
    ///
    /// Asks `POST /query/{subgroveId}` for a proof and requires it to hash to
    /// the light client's verified root; a response without one throws. The
    /// documents are not checked against the proof's contents. As with `get`,
    /// the proof verifier cannot verify a proof from the chain yet, so this
    /// throws for every live query.
    public func query(subgroveId: String, query: QueryRequest) async throws -> QueryResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        var queryWithProof = query
        queryWithProof.includeProof = true

        let envelope: ApiResponse<QueryResponse> = try await client.post(path: "/query/\(pathSegment(subgroveId))", body: queryWithProof)
        var response = try client.unwrap(envelope, "query result")

        guard let proofData = response.proof, !proofData.isEmpty else {
            throw ProofError("The API returned no proof for the query on \(subgroveId)")
        }
        try await verifyProof(proofData, client: client)

        // Apply computed fields if registered
        if let fields = client.computedFieldRegistry.get(datasetId: subgroveId) {
            response = applyComputedFieldsToResponse(response: response, fields: fields)
        }

        return response
    }

    /// Queries data without proof verification (`POST /query/{subgroveId}`).
    /// Applies computed fields if registered for the subgrove.
    public func queryUnverified(subgroveId: String, query: QueryRequest) async throws -> QueryResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let envelope: ApiResponse<QueryResponse> = try await client.post(path: "/query/\(pathSegment(subgroveId))", body: query)
        var response = try client.unwrap(envelope, "query result")

        // Apply computed fields if registered
        if let fields = client.computedFieldRegistry.get(datasetId: subgroveId) {
            response = applyComputedFieldsToResponse(response: response, fields: fields)
        }

        return response
    }

    // MARK: - Store Operations

    /// Stores an item.
    public func store(subgroveId: String, key: String, data: [String: Any]) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let request = StoreRequest(key: key, data: data)
        let path = "/subgroves/\(pathSegment(subgroveId))/data"
        let _: EmptyStoreResponse = try await client.post(path: path, body: request)
    }

    /// Stores multiple items in batch.
    public func batchStore(subgroveId: String, items: [StoreRequest]) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/subgroves/\(pathSegment(subgroveId))/data/batch"
        let batchRequest = BatchStoreRequest(items: items)
        let _: EmptyStoreResponse = try await client.post(path: path, body: batchRequest)
    }

    // MARK: - Update Operations

    /// Updates an item.
    public func update(subgroveId: String, key: String, data: [String: Any]) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/subgroves/\(pathSegment(subgroveId))/data/\(pathSegment(key))"
        let body = data.mapValues { AnyCodable($0) }
        let _: EmptyStoreResponse = try await client.put(path: path, body: body)
    }

    // MARK: - Delete Operations

    /// Deletes an item.
    public func delete(subgroveId: String, key: String) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/subgroves/\(pathSegment(subgroveId))/data/\(pathSegment(key))"
        try await client.delete(path: path)
    }

    // MARK: - Historical Query Operations

    /// Gets checkpoint state root information.
    public func getCheckpointStateRoot(subgroveId: String, checkpointId: String) async throws -> CheckpointInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/checkpoints/\(pathSegment(subgroveId))/\(pathSegment(checkpointId))/state-root"
        return try await client.get(path: path)
    }

    /// Queries historical indexed data from a checkpoint.
    /// Routes through consensus to available indexer nodes that serve historical data.
    public func queryHistorical(subgroveId: String, checkpointId: String, request: HistoricalQueryRequest) async throws -> HistoricalQueryResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/historical/query/\(pathSegment(subgroveId))/\(pathSegment(checkpointId))"
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
        // Always verify through the light client; auto-initialized via
        // trust-on-first-use on first call. Pin a known-good checkpoint
        // header in production deployments.
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

/// What `GET /proof/{subgroveId}/{key}` serves: the hex GroveDB proof and the
/// block height it was generated at.
private struct ServedProof: Codable {
    let proof: String
    let height: Int64?
}

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
