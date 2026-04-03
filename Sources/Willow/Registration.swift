import Foundation

// MARK: - Registration Operations

/// Provides methods for subgrove registration.
public class RegistrationOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    // MARK: - Subgrove Operations

    /// Registers a new subgrove.
    public func registerSubgrove(_ request: RegisterSubgroveRequest) async throws -> SubgroveRegistration {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        return try await client.post(path: "/subgroves", body: request)
    }

    /// Retrieves information about a subgrove.
    public func getSubgrove(subgroveId: String) async throws -> SubgroveRegistration {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/subgroves/\(subgroveId)"
        return try await client.get(path: path)
    }

    /// Lists all subgroves.
    public func listSubgroves() async throws -> [SubgroveRegistration] {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/subgroves")
    }

    /// Updates an existing subgrove.
    public func updateSubgrove(subgroveId: String, updates: [String: Any]) async throws -> SubgroveRegistration {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/subgroves/\(subgroveId)"
        let body = updates.mapValues { AnyCodable($0) }
        return try await client.put(path: path, body: body)
    }

    /// Deletes a subgrove.
    public func deleteSubgrove(subgroveId: String) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/subgroves/\(subgroveId)"
        try await client.delete(path: path)
    }

    // MARK: - Permission Operations

    /// Retrieves permissions for a DID.
    public func getPermissions(did: String) async throws -> [Permission] {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/permissions/\(did)")
    }

    /// Grants a permission to a DID.
    public func grantPermission(_ permission: Permission) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let _: EmptyResponse = try await client.post(path: "/permissions", body: permission)
    }

    /// Revokes a permission from a DID.
    public func revokePermission(did: String, subgroveId: String) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/permissions/\(did)/\(subgroveId)"
        try await client.delete(path: path)
    }
}

private struct EmptyResponse: Codable {}

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
