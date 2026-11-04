import Foundation

// MARK: - Registration Operations

/// Provides methods for subgrove registration.
public class RegistrationOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    // MARK: - Subgrove Operations

    /// Registers a new DataStorage subgrove as a `RegisterSubgrove`
    /// transaction, signed by the client's identity (the owner) and submitted
    /// to `POST /tx/submit` (the API serves no registration route).
    ///
    /// The subgrove's name, description, writers, and readers (as free
    /// readers) come from `request`, and its schema is `request.schema` in the
    /// node's form (`SubgroveSchema(_:)`). The transaction goes out under the
    /// identity's next free nonce, signed over `registerSubgroveMessage`.
    /// Refused with a validation error before anything is signed: an owner DID
    /// other than the identity's, a reward rate or retention window (they
    /// belong to BlockchainIndexing, which this SDK can't register), a schema
    /// type the node has no match for, an owner holding a line break, and
    /// what the node refuses: a schema with indexes, a subgrove ID that isn't
    /// 1 to 64 ASCII letters, digits, `-`, or `_` starting with a letter or
    /// digit, or a writer or reader that isn't a Willow DID.
    @discardableResult
    public func registerSubgrove(_ request: RegisterSubgroveRequest) async throws -> BroadcastResult {
        guard let client = client else { throw NetworkError("Client deallocated") }
        let identity = try client.transactionIdentity()
        guard request.ownerDid.isEmpty || request.ownerDid == identity.did else {
            throw ValidationError("The owner \(request.ownerDid) is not the identity \(identity.did) that signs the registration")
        }
        guard request.rewardRate == 0, request.retentionWindow == nil else {
            throw ValidationError(
                "A reward rate and retention window belong to a BlockchainIndexing registration, which this SDK can't build"
            )
        }
        var tx = RegisterSubgroveTx(
            subgroveId: request.subgroveId,
            name: request.name,
            description: request.description ?? "",
            schema: try SubgroveSchema(request.schema).jsonText(),
            ownerDid: identity.did,
            mode: .dataStorage(SubgroveDataStorage(name: request.name, writers: request.writers, freeReaders: request.readers)),
            publicKeyId: identity.publicKeyId,
            nonce: 0
        )
        // Refuse what can't be signed before spending a request on the nonce.
        _ = try registerSubgroveMessage(tx)
        return try await client.submitUnderNextNonce(did: identity.did) { nonce in
            tx.nonce = nonce
            return try signedRegisterSubgroveBody(tx, sign: identity.sign)
        }
    }

    /// Retrieves information about a subgrove (`GET /subgroves/{id}`).
    public func getSubgrove(subgroveId: String) async throws -> SubgroveInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.getData(path: "/subgroves/\(pathSegment(subgroveId))", "subgrove")
    }

    /// Lists the subgroves `GET /subgroves` serves: the public ones, and with
    /// an identity set, those it can access.
    public func listSubgroves() async throws -> [SubgroveRegistration] {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.getData(path: "/subgroves", "subgroves")
    }

    /// Updates an existing subgrove.
    ///
    /// The API serves no subgrove update route, and this SDK builds no
    /// transaction for one, so this throws a validation error and sends
    /// nothing.
    @available(*, deprecated, message: "The API serves no subgrove update route.")
    public func updateSubgrove(subgroveId: String, updates: [String: Any]) async throws -> SubgroveRegistration {
        throw ValidationError("The API serves no subgrove update route, and this SDK builds no transaction for one")
    }

    /// Deletes a subgrove as a `DeregisterSubgrove` transaction, signed by
    /// the client's identity (the owner) under its next free nonce and
    /// submitted to `POST /tx/submit`. The subgrove's remaining funding is
    /// refunded to the owner.
    @discardableResult
    public func deleteSubgrove(subgroveId: String) async throws -> BroadcastResult {
        guard let client = client else { throw NetworkError("Client deallocated") }
        let identity = try client.transactionIdentity()
        return try await client.submitUnderNextNonce(did: identity.did) { nonce in
            var tx = DeregisterSubgroveTx(
                subgroveId: subgroveId,
                ownerDid: identity.did,
                publicKeyId: identity.publicKeyId,
                nonce: nonce
            )
            let message = deregisterSubgroveMessage(subgroveId: tx.subgroveId, ownerDid: tx.ownerDid, nonce: tx.nonce)
            tx.signature = Array(try identity.sign(Data(message.utf8)))
            return try encodeTransaction(txType: "DeregisterSubgrove", transaction: tx)
        }
    }

    // MARK: - Permission Operations

    /// Retrieves the subgrove permissions granted to a DID
    /// (`GET /did/{did}/permissions`).
    public func getPermissions(did: String) async throws -> [Permission] {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let response: ApiResponse<[Permission]> = try await client.get(path: "/did/\(pathSegment(did))/permissions")
        return try client.unwrap(response, "permissions")
    }

    /// Grants a permission to a DID.
    ///
    /// The API serves no permission route, and this SDK builds no transaction
    /// that grants one, so this throws a validation error and sends nothing.
    @available(*, deprecated, message: "The API serves no permission route.")
    public func grantPermission(_ permission: Permission) async throws {
        throw ValidationError("The API serves no permission route, and this SDK builds no transaction that grants one")
    }

    /// Revokes a permission from a DID.
    ///
    /// The API serves no permission route, and this SDK builds no transaction
    /// that revokes one, so this throws a validation error and sends nothing.
    @available(*, deprecated, message: "The API serves no permission route.")
    public func revokePermission(did: String, subgroveId: String) async throws {
        throw ValidationError("The API serves no permission route, and this SDK builds no transaction that revokes one")
    }
}

// MARK: - Subgrove Builder

/// Builder for constructing subgrove registrations.
public class SubgroveBuilder {
    private var request: RegisterSubgroveRequest

    public init(subgroveId: String, name: String) {
        self.request = RegisterSubgroveRequest(subgroveId: subgroveId, name: name)
    }

    /// Sets the subgrove description.
    @discardableResult
    public func description(_ desc: String) -> SubgroveBuilder {
        request.description = desc
        return self
    }

    /// Sets the schema definition.
    @discardableResult
    public func schema(_ schema: SchemaDefinition) -> SubgroveBuilder {
        request.schema = schema
        return self
    }

    /// Sets the owner DID.
    @discardableResult
    public func owner(_ did: String) -> SubgroveBuilder {
        request.ownerDid = did
        return self
    }

    /// Sets the writer DIDs.
    @discardableResult
    public func writers(_ dids: [String]) -> SubgroveBuilder {
        request.writers = dids
        return self
    }

    /// Adds a writer DID.
    @discardableResult
    public func addWriter(_ did: String) -> SubgroveBuilder {
        request.writers.append(did)
        return self
    }

    /// Sets the reader DIDs.
    @discardableResult
    public func readers(_ dids: [String]) -> SubgroveBuilder {
        request.readers = dids
        return self
    }

    /// Adds a reader DID.
    @discardableResult
    public func addReader(_ did: String) -> SubgroveBuilder {
        request.readers.append(did)
        return self
    }

    /// Sets the reward rate for indexers.
    @discardableResult
    public func rewardRate(_ rate: UInt64) -> SubgroveBuilder {
        request.rewardRate = rate
        return self
    }

    /// Sets the retention window for indexed data.
    @discardableResult
    public func retentionWindow(_ window: RetentionWindow) -> SubgroveBuilder {
        request.retentionWindow = window
        return self
    }

    /// Builds the RegisterSubgroveRequest.
    public func build() -> RegisterSubgroveRequest {
        return request
    }
}

// MARK: - Schema Builder

/// Builder for constructing schema definitions.
public class SchemaBuilder {
    private var schema: SchemaDefinition

    public init(name: String) {
        self.schema = SchemaDefinition(name: name)
    }

    /// Sets the schema description.
    @discardableResult
    public func description(_ desc: String) -> SchemaBuilder {
        self.schema = SchemaDefinition(
            name: schema.name,
            description: desc,
            fields: schema.fields,
            indexes: schema.indexes
        )
        return self
    }

    /// Adds a field to the schema.
    @discardableResult
    public func field(_ name: String, type: String, required: Bool = false, indexed: Bool = false) -> SchemaBuilder {
        var fields = schema.fields
        fields.append(SchemaField(name: name, type: type, required: required, indexed: indexed))
        self.schema = SchemaDefinition(
            name: schema.name,
            description: schema.description,
            fields: fields,
            indexes: schema.indexes
        )
        return self
    }

    /// Adds a string field.
    @discardableResult
    public func stringField(_ name: String, required: Bool = false) -> SchemaBuilder {
        return field(name, type: "string", required: required)
    }

    /// Adds an integer field.
    @discardableResult
    public func intField(_ name: String, required: Bool = false) -> SchemaBuilder {
        return field(name, type: "int", required: required)
    }

    /// Adds a float field.
    @discardableResult
    public func floatField(_ name: String, required: Bool = false) -> SchemaBuilder {
        return field(name, type: "float", required: required)
    }

    /// Adds a boolean field.
    @discardableResult
    public func boolField(_ name: String, required: Bool = false) -> SchemaBuilder {
        return field(name, type: "bool", required: required)
    }

    /// Adds an array field with item type.
    @discardableResult
    public func arrayField(_ name: String, itemType: String, required: Bool = false) -> SchemaBuilder {
        return field(name, type: "array:\(itemType)", required: required)
    }

    /// Adds an object field.
    @discardableResult
    public func objectField(_ name: String, required: Bool = false) -> SchemaBuilder {
        return field(name, type: "object", required: required)
    }

    /// Adds an index to the schema.
    @discardableResult
    public func index(_ name: String, fields: [String], type: IndexType, unique: Bool = false) -> SchemaBuilder {
        var indexes = schema.indexes
        indexes.append(IndexDefinition(name: name, fields: fields, type: type, unique: unique))
        self.schema = SchemaDefinition(
            name: schema.name,
            description: schema.description,
            fields: schema.fields,
            indexes: indexes
        )
        return self
    }

    /// Adds a hash index.
    @discardableResult
    public func hashIndex(_ name: String, fields: [String]) -> SchemaBuilder {
        return index(name, fields: fields, type: .hash)
    }

    /// Adds a range index.
    @discardableResult
    public func rangeIndex(_ name: String, fields: [String]) -> SchemaBuilder {
        return index(name, fields: fields, type: .range)
    }

    /// Adds a full-text index.
    @discardableResult
    public func fullTextIndex(_ name: String, fields: [String]) -> SchemaBuilder {
        return index(name, fields: fields, type: .fulltext)
    }

    /// Adds a unique index.
    @discardableResult
    public func uniqueIndex(_ name: String, fields: [String]) -> SchemaBuilder {
        return index(name, fields: fields, type: .hash, unique: true)
    }

    /// Builds the SchemaDefinition.
    public func build() -> SchemaDefinition {
        return schema
    }
}
