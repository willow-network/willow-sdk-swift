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
    /// Reads the value from `GET /data/{subgroveId}/{key}` and its proof
    /// from `GET /proof/{subgroveId}/{key}`. The proof must prove, in the
    /// subgrove's data tree (`subgroves/{subgroveId}/data`), the key with the
    /// value served, and its root must equal (as hex, case-insensitively) the
    /// app hash of the header after the block the proof's state is from: the
    /// proof is served with that block's height H, and a header at H+1
    /// carries the state after block H. The light client supplies that
    /// header (`LightClient.verifiedAppHash(atHeight:)`), waiting for it if
    /// the chain hasn't produced it yet. The proof is checked with Merk's
    /// hash rules (BLAKE3) and grovedb's proof encoding. It returns the value
    /// the proof proves; any failure throws, and the value is never returned
    /// unverified.
    ///
    /// The app hash is only as trustworthy as the light client's header: see
    /// `LightClient`, whose header check does not verify commit signatures.
    ///
    /// A key the API reports missing throws `NotFoundError` (type
    /// `.notFound`). That answer comes without a proof, so it does not prove
    /// the key absent. Use `getUnverified` to read without a proof.
    public func get(subgroveId: String, key: String) async throws -> DataResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        // The light client starts from a header before the proof is read, so
        // the header after the proof's block is at or after it.
        let lc = try await client.getOrCreateLightClient()

        let value = try await fetchValue(subgroveId: subgroveId, key: key, client: client)

        let proofResponse: ApiResponse<ServedProof> = try await client.get(path: "/proof/\(pathSegment(subgroveId))/\(pathSegment(key))")
        let served = try client.unwrap(proofResponse, "proof")
        let cleanHex = served.proof.hasPrefix("0x") ? String(served.proof.dropFirst(2)) : served.proof
        guard let proofBytes = Data(hexString: cleanHex), !proofBytes.isEmpty else {
            throw ProofError("The API returned no proof for \(subgroveId)/\(key)")
        }
        guard let height = served.height, height > 0 else {
            throw ProofError("The API returned the proof for \(subgroveId)/\(key) without the height of its state")
        }

        let result = try GroveDBVerifier.verifyProof(proofBytes: proofBytes, expectedPath: DataOperations.dataPath(subgroveId))
        let proven = try DataOperations.requireProven(subgroveId: subgroveId, key: key, value: value, in: result)
        try await DataOperations.requireRoot(result.rootHash, stateAfter: height, lightClient: lc)

        return DataResponse(
            key: key,
            data: proven,
            proof: DataProof(proof: proofBytes, rootHash: result.rootHash, height: height, verifiedAt: Int64(Date().timeIntervalSince1970))
        )
    }

    /// Requires that `rootHash` is the app hash of the header at `height + 1`,
    /// which carries the state after block `height`; hex is compared
    /// case-insensitively.
    internal static func requireRoot(_ rootHash: String, stateAfter height: Int64, lightClient: LightClient) async throws {
        guard height < Int64.max else {
            throw ProofError("The proof's height \(height) has no next header")
        }
        let appHash = try await lightClient.verifiedAppHash(atHeight: height + 1)
        guard rootHash.lowercased() == appHash.lowercased() else {
            throw ProofError("The proof's root \(rootHash) is not the app hash \(appHash) of the header at height \(height + 1)")
        }
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

    /// Queries a DataStorage subgrove and verifies the answer against a
    /// GroveDB proof of its whole data tree. Applies computed fields if
    /// registered for the subgrove.
    ///
    /// Asks `POST /query/{subgroveId}` for a proof. The node proves every
    /// element of `subgroves/{subgroveId}/data`; the proof must prove that
    /// tree at that path and hide no node of it (or prove it empty), every
    /// element must be an item, and its root must equal the app hash of the
    /// header after the block the proof's state is from, as in `get`. The
    /// SDK then answers the query itself over those items, as the node does:
    /// the items that parse as JSON, in key order; the filter (one equality
    /// on a field, numbers compared by value); the sort (numbers by value,
    /// strings by their UTF-8 bytes, anything else as equal, ties kept in key
    /// order); then the offset and limit (default 100). The documents the
    /// API serves are not used: every result is a proven item, with its key,
    /// and `totalCount` counts the proven items that pass the filter. Any
    /// failure throws.
    ///
    /// The app hash is only as trustworthy as the light client's header: see
    /// `LightClient`. A request the node can't run (see `QueryRequest`) is
    /// refused with a validation error before anything is sent.
    public func query(subgroveId: String, query: QueryRequest) async throws -> QueryResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try query.validateForNode()
        let lc = try await client.getOrCreateLightClient()

        var queryWithProof = query
        queryWithProof.includeProof = true
        let envelope: ApiResponse<QueryResponse> = try await client.postVerbatim(path: "/query/\(pathSegment(subgroveId))", body: queryWithProof)
        let served = try client.unwrap(envelope, "query result")

        guard let proof = served.proof, !proof.isEmpty else {
            throw ProofError("The API returned no proof for the query on \(subgroveId)")
        }
        guard let height = served.height, height > 0 else {
            throw ProofError("The API returned the proof for the query on \(subgroveId) without the height of its state")
        }

        let answer = try DataOperations.answer(query, proof: proof, path: DataOperations.dataPath(subgroveId))
        try await DataOperations.requireRoot(answer.rootHash, stateAfter: height, lightClient: lc)

        var response = QueryResponse(
            results: answer.results,
            totalCount: answer.total,
            hasMore: (query.offset ?? 0) + answer.results.count < answer.total,
            proof: proof,
            height: height
        )
        if let fields = client.computedFieldRegistry.get(datasetId: subgroveId) {
            response = applyComputedFieldsToResponse(response: response, fields: fields)
        }
        return response
    }

    /// Verifies `proof` as a proof of the whole tree at `path` holding only
    /// items, and answers `query` over those items as the node's query route
    /// does (see `query(subgroveId:query:)`).
    internal static func answer(_ query: QueryRequest, proof: Data, path: [[UInt8]]) throws -> (rootHash: String, results: [QueryResult], total: Int) {
        try query.validateForNode()
        let (rootHash, tree) = try GroveDBVerifier.verifyTree(proof, at: path)
        guard tree.complete else {
            throw ProofError("The proof doesn't show the whole data tree (it hides nodes), so the query's answer can't be checked")
        }

        // The node reads the tree in key order and skips items that aren't JSON.
        var documents: [(key: String, value: Any)] = []
        for entry in tree.entries.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            guard entry.nodeType == .kv, let bytes = groveItemBytes(entry.value) else {
                throw ProofError("The data tree holds an element that isn't an item, at key \(entry.key.hexString)")
            }
            if let json = try? JSONDecoder().decode(AnyCodable.self, from: bytes) {
                documents.append((String(decoding: entry.key, as: UTF8.self), json.value))
            }
        }

        if let filter = query.filters.first {
            documents = documents.filter { document in
                guard let field = fieldValue(document.value, filter.field) else { return false }
                return jsonEqual(field, filter.value.value)
            }
        }
        if let sort = query.sort {
            // A stable sort: ties keep key order.
            let keys: [Any?] = documents.map { fieldValue($0.value, sort.field) }
            let order: [Int] = Array(documents.indices).sorted { (i: Int, j: Int) -> Bool in
                var compared: Int = compareForSort(keys[i], keys[j])
                if !sort.ascending {
                    compared = -compared
                }
                if compared != 0 {
                    return compared < 0
                }
                return i < j
            }
            documents = order.map { documents[$0] }
        }

        let total = documents.count
        let page = documents.dropFirst(query.offset ?? 0).prefix(query.limit ?? 100)
        let results = try page.map { document -> QueryResult in
            guard let object = document.value as? [String: Any] else {
                throw SerializationError("The document at key \(document.key) is not a JSON object")
            }
            return QueryResult(key: document.key, data: object.mapValues { AnyCodable($0) })
        }
        return (rootHash.hexString, results, total)
    }

    /// The value at a dotted field path, through JSON objects only.
    internal static func fieldValue(_ document: Any, _ path: String) -> Any? {
        var current = document
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard let object = current as? [String: Any], let next = object[String(part)] else { return nil }
            current = next
        }
        return current
    }

    /// JSON equality: null, booleans, numbers (by value), strings (by their
    /// UTF-8 bytes), arrays, and objects. A boolean is not a number.
    internal static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNull, is NSNull):
            return true
        case let (x as [Any], y as [Any]):
            guard x.count == y.count else { return false }
            for i in x.indices where !jsonEqual(x[i], y[i]) {
                return false
            }
            return true
        case let (x as [String: Any], y as [String: Any]):
            guard x.count == y.count else { return false }
            for (key, value) in x {
                guard let other = y[key], jsonEqual(value, other) else { return false }
            }
            return true
        case let (x as String, y as String):
            return Array(x.utf8) == Array(y.utf8)
        default:
            if let x = jsonBool(a), let y = jsonBool(b) { return x == y }
            if let x = jsonNumber(a), let y = jsonNumber(b) { return x == y }
            return false
        }
    }

    /// -1, 0, or 1, as the node sorts: numbers by value, strings by their
    /// UTF-8 bytes, anything else (a missing field, mixed kinds) as equal.
    internal static func compareForSort(_ a: Any?, _ b: Any?) -> Int {
        if let a = a, let b = b, let x = jsonNumber(a), let y = jsonNumber(b) {
            return x < y ? -1 : (x > y ? 1 : 0)
        }
        if let x = a as? String, let y = b as? String {
            let (u, v) = (Array(x.utf8), Array(y.utf8))
            return u == v ? 0 : (u.lexicographicallyPrecedes(v) ? -1 : 1)
        }
        return 0
    }

    private static func jsonBool(_ value: Any) -> Bool? {
        if type(of: value) == Bool.self {
            return value as? Bool
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return nil
    }

    private static func jsonNumber(_ value: Any) -> Double? {
        if jsonBool(value) != nil { return nil }
        switch value {
        case let int as Int: return Double(int)
        case let double as Double: return double
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }

    /// Queries data without proof verification (`POST /query/{subgroveId}`):
    /// the documents and total are the node's, unchecked. Applies computed
    /// fields if registered for the subgrove. A request the node can't run
    /// (see `QueryRequest`) is refused with a validation error before
    /// anything is sent.
    public func queryUnverified(subgroveId: String, query: QueryRequest) async throws -> QueryResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        try query.validateForNode()
        let envelope: ApiResponse<QueryResponse> = try await client.postVerbatim(path: "/query/\(pathSegment(subgroveId))", body: query)
        var response = try client.unwrap(envelope, "query result")

        // Apply computed fields if registered
        if let fields = client.computedFieldRegistry.get(datasetId: subgroveId) {
            response = applyComputedFieldsToResponse(response: response, fields: fields)
        }

        return response
    }

    // MARK: - Store Operations

    /// Stores an item as a `StoreData` transaction, signed by the client's
    /// identity and submitted to `POST /tx/submit` (the API serves no data
    /// write route: writes go through consensus).
    ///
    /// `data` is serialized once, with sorted keys; the transaction carries
    /// that JSON text's UTF-8 bytes under the identity's next nonce, signed
    /// over `storeDataMessage`. A subgrove ID, key, or DID holding a line
    /// break is refused with a validation error before anything is signed.
    ///
    /// The nonce is the lowest one above the account's base that the client
    /// hasn't seen used and that no other write in flight from this process
    /// holds, so writes sent before earlier ones land take distinct nonces. A
    /// write refused at CheckTx gives its nonce back, unless the refusal says
    /// the nonce is held by a pending transaction, already used, or spent. A
    /// write refused in its block after its signature and nonce verify spends
    /// its nonce, so calling again signs under another. One whose submission
    /// failed in transit (a network error or a 5xx) may still land, so its
    /// nonce stays held for 120 s: read the key to see whether it landed
    /// before storing it again. Read it too after a refusal that says the
    /// nonce is already used: an earlier attempt may have landed under that
    /// nonce, and storing again under a fresh one would write twice.
    @discardableResult
    public func store(subgroveId: String, key: String, data: [String: Any]) async throws -> BroadcastResult {
        guard let client = client else { throw NetworkError("Client deallocated") }
        let identity = try client.transactionIdentity()
        let text = try storeDataText(data)
        // Refuse a line break before spending a request on the nonce.
        _ = try storeDataMessage(subgroveId: subgroveId, key: key, ownerDid: identity.did, data: Data(text.utf8), nonce: 0)
        return try await client.submitUnderNextNonce(did: identity.did) { nonce in
            let tx = try signedStoreData(
                subgroveId: subgroveId, key: key, data: text, ownerDid: identity.did,
                publicKeyId: identity.publicKeyId, nonce: nonce, sign: identity.sign
            )
            return try encodeTransaction(txType: "StoreData", transaction: tx)
        }
    }

    /// Stores multiple items in batch.
    ///
    /// The node has no batch write and the API no batch route, so this throws
    /// a validation error and sends nothing. Store each item with
    /// `store(subgroveId:key:data:)`, one transaction each.
    @available(*, deprecated, message: "The node has no batch write; store each item with store(subgroveId:key:data:).")
    public func batchStore(subgroveId: String, items: [StoreRequest]) async throws {
        throw ValidationError(
            "The node has no batch write: store each item with store(subgroveId:key:data:), one StoreData transaction each"
        )
    }

    // MARK: - Update Operations

    /// Updates an item.
    ///
    /// An update is an UpdateData consensus transaction, which this SDK
    /// doesn't build, and the API serves no update route, so this throws a
    /// validation error and sends nothing.
    @available(*, deprecated, message: "An update is an UpdateData transaction, which this SDK doesn't build.")
    public func update(subgroveId: String, key: String, data: [String: Any]) async throws {
        throw ValidationError(
            "Updating data is an UpdateData consensus transaction, which this SDK doesn't build; the API serves no update route"
        )
    }

    // MARK: - Delete Operations

    /// Deletes an item.
    ///
    /// A delete is a DeleteData consensus transaction, which this SDK doesn't
    /// build, and the API serves no delete route, so this throws a validation
    /// error and sends nothing.
    @available(*, deprecated, message: "A delete is a DeleteData transaction, which this SDK doesn't build.")
    public func delete(subgroveId: String, key: String) async throws {
        throw ValidationError(
            "Deleting data is a DeleteData consensus transaction, which this SDK doesn't build; the API serves no delete route"
        )
    }

    // MARK: - Historical Query Operations

    /// Gets checkpoint state root information
    /// (`GET /checkpoints/{subgroveId}/{checkpointId}/state-root`).
    public func getCheckpointStateRoot(subgroveId: String, checkpointId: String) async throws -> CheckpointInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/checkpoints/\(pathSegment(subgroveId))/\(pathSegment(checkpointId))/state-root"
        return try await client.getData(path: path, "checkpoint")
    }

    /// Queries historical indexed data from a checkpoint.
    /// Routes through consensus to available indexer nodes that serve historical data.
    public func queryHistorical(subgroveId: String, checkpointId: String, request: HistoricalQueryRequest) async throws -> HistoricalQueryResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/historical/query/\(pathSegment(subgroveId))/\(pathSegment(checkpointId))"
        return try await client.post(path: path, body: request)
    }

    /// Queries historical data with proof verification: not supported.
    ///
    /// A checkpoint's `state_root` is not a GroveDB root a proof can hash to,
    /// and nothing ties the response's `data` to its proof, so the SDK can't
    /// verify a historical answer. This throws a validation error and sends
    /// nothing. `queryHistorical` returns the answer unverified.
    @available(*, deprecated, message: "A historical answer can't be verified; use queryHistorical, which returns it unverified.")
    public func queryHistoricalVerified(subgroveId: String, checkpointId: String, request: HistoricalQueryRequest) async throws -> HistoricalQueryResponse {
        throw ValidationError(
            "A historical query's answer can't be verified: a checkpoint's state root is not a GroveDB root and its data isn't bound to the proof; queryHistorical returns it unverified"
        )
    }
}

// MARK: - Helper Types

/// What `GET /proof/{subgroveId}/{key}` serves: the hex GroveDB proof and the
/// height of the block whose state it proves (the header at `height + 1`
/// carries that state's app hash).
private struct ServedProof: Codable {
    let proof: String
    let height: Int64?
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

    /// Adds an equals filter. The node's query route runs one filter, so a
    /// query with more than one is refused.
    @discardableResult
    public func equals(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "eq", value: value))
        return self
    }

    /// Adds a not equals filter. The node's query route doesn't run it.
    @available(*, deprecated, message: "The node's query route runs only an equality filter; data.query and data.queryUnverified refuse a query with this one.")
    @discardableResult
    public func notEquals(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "ne", value: value))
        return self
    }

    /// Adds a greater than filter. The node's query route doesn't run it.
    @available(*, deprecated, message: "The node's query route runs only an equality filter; data.query and data.queryUnverified refuse a query with this one.")
    @discardableResult
    public func greaterThan(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "gt", value: value))
        return self
    }

    /// Adds a greater than or equal filter. The node's query route doesn't run it.
    @available(*, deprecated, message: "The node's query route runs only an equality filter; data.query and data.queryUnverified refuse a query with this one.")
    @discardableResult
    public func greaterThanOrEqual(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "gte", value: value))
        return self
    }

    /// Adds a less than filter. The node's query route doesn't run it.
    @available(*, deprecated, message: "The node's query route runs only an equality filter; data.query and data.queryUnverified refuse a query with this one.")
    @discardableResult
    public func lessThan(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "lt", value: value))
        return self
    }

    /// Adds a less than or equal filter. The node's query route doesn't run it.
    @available(*, deprecated, message: "The node's query route runs only an equality filter; data.query and data.queryUnverified refuse a query with this one.")
    @discardableResult
    public func lessThanOrEqual(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "lte", value: value))
        return self
    }

    /// Adds a contains filter. The node's query route doesn't run it.
    @available(*, deprecated, message: "The node's query route runs only an equality filter; data.query and data.queryUnverified refuse a query with this one.")
    @discardableResult
    public func contains(_ field: String, _ value: Any) -> QueryBuilder {
        filters.append(QueryFilter(field: field, operator: "contains", value: value))
        return self
    }

    /// Adds a full-text search. The node's query route has none.
    @available(*, deprecated, message: "The node's query route has no full-text search; data.query and data.queryUnverified refuse a query with one.")
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
