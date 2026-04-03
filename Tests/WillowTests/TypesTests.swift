import XCTest
@testable import Willow

final class TypesTests: XCTestCase {

    // MARK: - Schema Tests

    func testSchemaFieldCreation() {
        let field = SchemaField(name: "email", type: "string", required: true, indexed: true)

        XCTAssertEqual(field.name, "email")
        XCTAssertEqual(field.type, "string")
        XCTAssertTrue(field.required)
        XCTAssertTrue(field.indexed)
    }

    func testSchemaFieldDefaults() {
        let field = SchemaField(name: "optional", type: "int")

        XCTAssertFalse(field.required)
        XCTAssertFalse(field.indexed)
    }

    func testIndexDefinition() {
        let index = IndexDefinition(
            name: "email_idx",
            fields: ["email"],
            type: .hash,
            unique: true
        )

        XCTAssertEqual(index.name, "email_idx")
        XCTAssertEqual(index.fields, ["email"])
        XCTAssertEqual(index.type, .hash)
        XCTAssertTrue(index.unique)
    }

    func testIndexTypeValues() {
        XCTAssertEqual(IndexType.hash.rawValue, "hash")
        XCTAssertEqual(IndexType.range.rawValue, "range")
        XCTAssertEqual(IndexType.fulltext.rawValue, "fulltext")
        XCTAssertEqual(IndexType.inverted.rawValue, "inverted")
    }

    func testSchemaDefinition() {
        let schema = SchemaDefinition(
            name: "users",
            description: "User data schema",
            fields: [
                SchemaField(name: "name", type: "string", required: true),
                SchemaField(name: "age", type: "int")
            ],
            indexes: [
                IndexDefinition(name: "name_idx", fields: ["name"], type: .hash)
            ]
        )

        XCTAssertEqual(schema.name, "users")
        XCTAssertEqual(schema.description, "User data schema")
        XCTAssertEqual(schema.fields.count, 2)
        XCTAssertEqual(schema.indexes.count, 1)
    }

    // MARK: - Validator Tests

    func testValidatorStatus() {
        XCTAssertEqual(ValidatorStatus.active.rawValue, "active")
        XCTAssertEqual(ValidatorStatus.inactive.rawValue, "inactive")
        XCTAssertEqual(ValidatorStatus.jailed.rawValue, "jailed")
    }

    // MARK: - Query Tests

    func testQueryFilter() {
        let filter = QueryFilter(field: "age", operator: "gte", value: 18)

        XCTAssertEqual(filter.field, "age")
        XCTAssertEqual(filter.operator, "gte")
        // Value is wrapped in AnyCodable
    }

    func testQuerySort() {
        let sort = QuerySort(field: "created_at", ascending: false)

        XCTAssertEqual(sort.field, "created_at")
        XCTAssertFalse(sort.ascending)
    }

    func testQueryRequest() {
        let request = QueryRequest(
            filters: [
                QueryFilter(field: "status", operator: "eq", value: "active")
            ],
            sort: QuerySort(field: "name", ascending: true),
            limit: 10,
            offset: 0,
            includeProof: true
        )

        XCTAssertEqual(request.filters.count, 1)
        XCTAssertEqual(request.limit, 10)
        XCTAssertEqual(request.offset, 0)
        XCTAssertTrue(request.includeProof)
    }

    // MARK: - GraphQL Tests

    func testGraphQLRequest() {
        let request = GraphQLRequest(
            query: "{ users { id name } }",
            variables: ["limit": AnyCodable(10)],
            operationName: "GetUsers",
            includeProof: true
        )

        XCTAssertEqual(request.query, "{ users { id name } }")
        XCTAssertNotNil(request.variables)
        XCTAssertEqual(request.operationName, "GetUsers")
        XCTAssertTrue(request.includeProof)
    }

    // MARK: - Session Tests

    func testSessionExpiry() {
        let futureSession = Session(
            did: "did:willow:Ed25519:abc",
            token: "token123",
            expiresAt: Int64(Date().timeIntervalSince1970) + 3600 // 1 hour from now
        )
        XCTAssertFalse(futureSession.isExpired)

        let expiredSession = Session(
            did: "did:willow:Ed25519:abc",
            token: "token123",
            expiresAt: Int64(Date().timeIntervalSince1970) - 3600 // 1 hour ago
        )
        XCTAssertTrue(expiredSession.isExpired)
    }

    // MARK: - RetryConfig Tests

    func testRetryConfigDefault() {
        let config = RetryConfig.default

        XCTAssertEqual(config.maxRetries, 3)
        XCTAssertEqual(config.initialBackoff, 0.1)
        XCTAssertEqual(config.maxBackoff, 5.0)
        XCTAssertEqual(config.backoffFactor, 2.0)
    }

    func testRetryConfigCustom() {
        let config = RetryConfig(
            maxRetries: 5,
            initialBackoff: 0.5,
            maxBackoff: 10.0,
            backoffFactor: 3.0
        )

        XCTAssertEqual(config.maxRetries, 5)
        XCTAssertEqual(config.initialBackoff, 0.5)
        XCTAssertEqual(config.maxBackoff, 10.0)
        XCTAssertEqual(config.backoffFactor, 3.0)
    }

    // MARK: - AnyCodable Tests

    func testAnyCodableInt() {
        let any = AnyCodable(42)
        XCTAssertEqual(any.value as? Int, 42)
    }

    func testAnyCodableString() {
        let any = AnyCodable("hello")
        XCTAssertEqual(any.value as? String, "hello")
    }

    func testAnyCodableBool() {
        let any = AnyCodable(true)
        XCTAssertEqual(any.value as? Bool, true)
    }

    func testAnyCodableDouble() {
        let any = AnyCodable(3.14)
        XCTAssertEqual(any.value as? Double, 3.14)
    }

    func testAnyCodableArray() {
        let any = AnyCodable([1, 2, 3])
        XCTAssertNotNil(any.value as? [Any])
    }

    func testAnyCodableDict() {
        let any = AnyCodable(["key": "value"])
        XCTAssertNotNil(any.value as? [String: Any])
    }

    func testAnyCodableEncoding() throws {
        let original = ["value": AnyCodable(42)]
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let json = String(data: data, encoding: .utf8)

        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("42"))
    }

    func testAnyCodableDecoding() throws {
        let json = #"{"value": 42}"#
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let result = try decoder.decode([String: AnyCodable].self, from: data)

        XCTAssertEqual(result["value"]?.value as? Int, 42)
    }
}
