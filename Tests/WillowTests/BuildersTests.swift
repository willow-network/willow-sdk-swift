import XCTest
@testable import Willow

final class BuildersTests: XCTestCase {

    // MARK: - AppBuilder Tests

    func testAppBuilderBasic() {
        let request = AppBuilder(appId: "my-app", name: "My App")
            .build()

        XCTAssertEqual(request.appId, "my-app")
        XCTAssertEqual(request.name, "My App")
        XCTAssertEqual(request.appType, .standard)
    }

    func testAppBuilderWithDescription() {
        let request = AppBuilder(appId: "my-app", name: "My App")
            .description("A test application")
            .build()

        XCTAssertEqual(request.description, "A test application")
    }

    func testAppBuilderWithType() {
        let request = AppBuilder(appId: "indexer-app", name: "Indexer App")
            .type(.indexer)
            .build()

        XCTAssertEqual(request.appType, .indexer)
    }

    func testAppBuilderWithOwner() {
        let request = AppBuilder(appId: "my-app", name: "My App")
            .owner("did:willow:Ed25519:owner123")
            .build()

        XCTAssertEqual(request.ownerDid, "did:willow:Ed25519:owner123")
    }

    func testAppBuilderWithAdmins() {
        let request = AppBuilder(appId: "my-app", name: "My App")
            .admins(["did:admin1", "did:admin2"])
            .build()

        XCTAssertEqual(request.admins.count, 2)
    }

    func testAppBuilderAddAdmin() {
        let request = AppBuilder(appId: "my-app", name: "My App")
            .addAdmin("did:admin1")
            .addAdmin("did:admin2")
            .build()

        XCTAssertEqual(request.admins.count, 2)
        XCTAssertTrue(request.admins.contains("did:admin1"))
        XCTAssertTrue(request.admins.contains("did:admin2"))
    }

    func testAppBuilderChaining() {
        let request = AppBuilder(appId: "full-app", name: "Full App")
            .description("Full featured app")
            .type(.standard)
            .owner("did:owner")
            .admins(["did:admin1"])
            .addAdmin("did:admin2")
            .build()

        XCTAssertEqual(request.appId, "full-app")
        XCTAssertEqual(request.description, "Full featured app")
        XCTAssertEqual(request.appType, .standard)
        XCTAssertEqual(request.ownerDid, "did:owner")
        XCTAssertEqual(request.admins.count, 2)
    }

    // MARK: - SubgroveBuilder Tests

    func testSubgroveBuilderBasic() {
        let request = SubgroveBuilder(subgroveId: "users", appId: "my-app", name: "Users")
            .build()

        XCTAssertEqual(request.subgroveId, "users")
        XCTAssertEqual(request.appId, "my-app")
        XCTAssertEqual(request.name, "Users")
    }

    func testSubgroveBuilderWithSchema() {
        let schema = SchemaDefinition(name: "user_schema")
        let request = SubgroveBuilder(subgroveId: "users", appId: "my-app", name: "Users")
            .schema(schema)
            .build()

        XCTAssertEqual(request.schema.name, "user_schema")
    }

    func testSubgroveBuilderWithOwner() {
        let request = SubgroveBuilder(subgroveId: "users", appId: "my-app", name: "Users")
            .owner("did:owner")
            .build()

        XCTAssertEqual(request.ownerDid, "did:owner")
    }

    func testSubgroveBuilderWithWriters() {
        let request = SubgroveBuilder(subgroveId: "users", appId: "my-app", name: "Users")
            .writers(["did:writer1", "did:writer2"])
            .build()

        XCTAssertEqual(request.writers.count, 2)
    }

    func testSubgroveBuilderAddWriter() {
        let request = SubgroveBuilder(subgroveId: "users", appId: "my-app", name: "Users")
            .addWriter("did:writer1")
            .addWriter("did:writer2")
            .build()

        XCTAssertEqual(request.writers.count, 2)
    }

    func testSubgroveBuilderWithReaders() {
        let request = SubgroveBuilder(subgroveId: "users", appId: "my-app", name: "Users")
            .readers(["did:reader1"])
            .addReader("did:reader2")
            .build()

        XCTAssertEqual(request.readers.count, 2)
    }

    func testSubgroveBuilderWithRewardRate() {
        let request = SubgroveBuilder(subgroveId: "users", appId: "my-app", name: "Users")
            .rewardRate(1000)
            .build()

        XCTAssertEqual(request.rewardRate, 1000)
    }

    // MARK: - SchemaBuilder Tests

    func testSchemaBuilderBasic() {
        let schema = SchemaBuilder(name: "users")
            .build()

        XCTAssertEqual(schema.name, "users")
        XCTAssertTrue(schema.fields.isEmpty)
        XCTAssertTrue(schema.indexes.isEmpty)
    }

    func testSchemaBuilderWithDescription() {
        let schema = SchemaBuilder(name: "users")
            .description("User data schema")
            .build()

        XCTAssertEqual(schema.description, "User data schema")
    }

    func testSchemaBuilderAddField() {
        let schema = SchemaBuilder(name: "users")
            .field("email", type: "string", required: true, indexed: true)
            .build()

        XCTAssertEqual(schema.fields.count, 1)
        XCTAssertEqual(schema.fields[0].name, "email")
        XCTAssertEqual(schema.fields[0].type, "string")
        XCTAssertTrue(schema.fields[0].required)
        XCTAssertTrue(schema.fields[0].indexed)
    }

    func testSchemaBuilderStringField() {
        let schema = SchemaBuilder(name: "test")
            .stringField("name", required: true)
            .build()

        XCTAssertEqual(schema.fields[0].type, "string")
        XCTAssertTrue(schema.fields[0].required)
    }

    func testSchemaBuilderIntField() {
        let schema = SchemaBuilder(name: "test")
            .intField("age", required: false)
            .build()

        XCTAssertEqual(schema.fields[0].type, "int")
        XCTAssertFalse(schema.fields[0].required)
    }

    func testSchemaBuilderFloatField() {
        let schema = SchemaBuilder(name: "test")
            .floatField("score", required: true)
            .build()

        XCTAssertEqual(schema.fields[0].type, "float")
    }

    func testSchemaBuilderBoolField() {
        let schema = SchemaBuilder(name: "test")
            .boolField("active", required: false)
            .build()

        XCTAssertEqual(schema.fields[0].type, "bool")
    }

    func testSchemaBuilderArrayField() {
        let schema = SchemaBuilder(name: "test")
            .arrayField("tags", itemType: "string", required: false)
            .build()

        XCTAssertEqual(schema.fields[0].type, "array:string")
    }

    func testSchemaBuilderObjectField() {
        let schema = SchemaBuilder(name: "test")
            .objectField("metadata", required: false)
            .build()

        XCTAssertEqual(schema.fields[0].type, "object")
    }

    func testSchemaBuilderAddIndex() {
        let schema = SchemaBuilder(name: "users")
            .index("email_idx", fields: ["email"], type: .hash, unique: true)
            .build()

        XCTAssertEqual(schema.indexes.count, 1)
        XCTAssertEqual(schema.indexes[0].name, "email_idx")
        XCTAssertEqual(schema.indexes[0].fields, ["email"])
        XCTAssertEqual(schema.indexes[0].type, .hash)
        XCTAssertTrue(schema.indexes[0].unique)
    }

    func testSchemaBuilderHashIndex() {
        let schema = SchemaBuilder(name: "test")
            .hashIndex("email_idx", fields: ["email"])
            .build()

        XCTAssertEqual(schema.indexes[0].type, .hash)
        XCTAssertFalse(schema.indexes[0].unique)
    }

    func testSchemaBuilderRangeIndex() {
        let schema = SchemaBuilder(name: "test")
            .rangeIndex("created_idx", fields: ["created_at"])
            .build()

        XCTAssertEqual(schema.indexes[0].type, .range)
    }

    func testSchemaBuilderFullTextIndex() {
        let schema = SchemaBuilder(name: "test")
            .fullTextIndex("content_idx", fields: ["title", "body"])
            .build()

        XCTAssertEqual(schema.indexes[0].type, .fulltext)
        XCTAssertEqual(schema.indexes[0].fields, ["title", "body"])
    }

    func testSchemaBuilderUniqueIndex() {
        let schema = SchemaBuilder(name: "test")
            .uniqueIndex("email_unique", fields: ["email"])
            .build()

        XCTAssertEqual(schema.indexes[0].type, .hash)
        XCTAssertTrue(schema.indexes[0].unique)
    }

    func testSchemaBuilderComplex() {
        let schema = SchemaBuilder(name: "users")
            .description("User profiles")
            .stringField("name", required: true)
            .stringField("email", required: true)
            .intField("age", required: false)
            .boolField("verified", required: false)
            .arrayField("roles", itemType: "string", required: false)
            .uniqueIndex("email_idx", fields: ["email"])
            .rangeIndex("age_idx", fields: ["age"])
            .fullTextIndex("name_search", fields: ["name"])
            .build()

        XCTAssertEqual(schema.name, "users")
        XCTAssertEqual(schema.description, "User profiles")
        XCTAssertEqual(schema.fields.count, 5)
        XCTAssertEqual(schema.indexes.count, 3)
    }

    // MARK: - QueryBuilder Tests

    func testQueryBuilderBasic() {
        let query = QueryBuilder()
            .build()

        XCTAssertTrue(query.filters.isEmpty)
        XCTAssertNil(query.sort)
        XCTAssertNil(query.limit)
        XCTAssertNil(query.offset)
        XCTAssertFalse(query.includeProof)
    }

    func testQueryBuilderEquals() {
        let query = QueryBuilder()
            .equals("status", "active")
            .build()

        XCTAssertEqual(query.filters.count, 1)
        XCTAssertEqual(query.filters[0].field, "status")
        XCTAssertEqual(query.filters[0].operator, "eq")
    }

    func testQueryBuilderNotEquals() {
        let query = QueryBuilder()
            .notEquals("status", "deleted")
            .build()

        XCTAssertEqual(query.filters[0].operator, "ne")
    }

    func testQueryBuilderGreaterThan() {
        let query = QueryBuilder()
            .greaterThan("age", 18)
            .build()

        XCTAssertEqual(query.filters[0].operator, "gt")
    }

    func testQueryBuilderGreaterThanOrEqual() {
        let query = QueryBuilder()
            .greaterThanOrEqual("score", 100)
            .build()

        XCTAssertEqual(query.filters[0].operator, "gte")
    }

    func testQueryBuilderLessThan() {
        let query = QueryBuilder()
            .lessThan("count", 10)
            .build()

        XCTAssertEqual(query.filters[0].operator, "lt")
    }

    func testQueryBuilderLessThanOrEqual() {
        let query = QueryBuilder()
            .lessThanOrEqual("price", 99.99)
            .build()

        XCTAssertEqual(query.filters[0].operator, "lte")
    }

    func testQueryBuilderContains() {
        let query = QueryBuilder()
            .contains("tags", "swift")
            .build()

        XCTAssertEqual(query.filters[0].operator, "contains")
    }

    func testQueryBuilderSearch() {
        let query = QueryBuilder()
            .search(fields: ["title", "content"], query: "hello world")
            .build()

        XCTAssertNotNil(query.search)
        XCTAssertEqual(query.search?.fields, ["title", "content"])
        XCTAssertEqual(query.search?.query, "hello world")
    }

    func testQueryBuilderSortAsc() {
        let query = QueryBuilder()
            .sortAsc("name")
            .build()

        XCTAssertNotNil(query.sort)
        XCTAssertEqual(query.sort?.field, "name")
        XCTAssertTrue(query.sort?.ascending ?? false)
    }

    func testQueryBuilderSortDesc() {
        let query = QueryBuilder()
            .sortDesc("created_at")
            .build()

        XCTAssertEqual(query.sort?.field, "created_at")
        XCTAssertFalse(query.sort?.ascending ?? true)
    }

    func testQueryBuilderLimit() {
        let query = QueryBuilder()
            .limit(10)
            .build()

        XCTAssertEqual(query.limit, 10)
    }

    func testQueryBuilderOffset() {
        let query = QueryBuilder()
            .offset(20)
            .build()

        XCTAssertEqual(query.offset, 20)
    }

    func testQueryBuilderWithProof() {
        let query = QueryBuilder()
            .withProof()
            .build()

        XCTAssertTrue(query.includeProof)
    }

    func testQueryBuilderComplex() {
        let query = QueryBuilder()
            .equals("status", "active")
            .greaterThan("score", 80)
            .lessThanOrEqual("attempts", 3)
            .search(fields: ["name"], query: "john")
            .sortDesc("created_at")
            .limit(10)
            .offset(0)
            .withProof()
            .build()

        XCTAssertEqual(query.filters.count, 3)
        XCTAssertNotNil(query.search)
        XCTAssertNotNil(query.sort)
        XCTAssertEqual(query.limit, 10)
        XCTAssertEqual(query.offset, 0)
        XCTAssertTrue(query.includeProof)
    }

    // MARK: - GraphQLQueryBuilder Tests

    func testGraphQLQueryBuilderBasic() {
        let request = GraphQLQueryBuilder(query: "{ users { id name } }")
            .build()

        XCTAssertEqual(request.query, "{ users { id name } }")
        XCTAssertNil(request.variables)
        XCTAssertNil(request.operationName)
        XCTAssertFalse(request.includeProof)
    }

    func testGraphQLQueryBuilderWithVariable() {
        let request = GraphQLQueryBuilder(query: "query($id: ID!) { user(id: $id) { name } }")
            .variable("id", value: "123")
            .build()

        XCTAssertNotNil(request.variables)
        XCTAssertEqual(request.variables?.count, 1)
    }

    func testGraphQLQueryBuilderWithVariables() {
        let request = GraphQLQueryBuilder(query: "query { users }")
            .variables(["limit": 10, "offset": 0])
            .build()

        XCTAssertEqual(request.variables?.count, 2)
    }

    func testGraphQLQueryBuilderWithOperationName() {
        let request = GraphQLQueryBuilder(query: "query GetUser { user { id } }")
            .operationName("GetUser")
            .build()

        XCTAssertEqual(request.operationName, "GetUser")
    }

    func testGraphQLQueryBuilderWithProof() {
        let request = GraphQLQueryBuilder(query: "{ users { id } }")
            .includeProof()
            .build()

        XCTAssertTrue(request.includeProof)
    }

    func testGraphQLQueryBuilderChaining() {
        let request = GraphQLQueryBuilder(query: "query GetUsers($limit: Int!) { users(limit: $limit) { id name } }")
            .variable("limit", value: 10)
            .operationName("GetUsers")
            .includeProof()
            .build()

        XCTAssertEqual(request.query.contains("GetUsers"), true)
        XCTAssertEqual(request.operationName, "GetUsers")
        XCTAssertTrue(request.includeProof)
    }
}
