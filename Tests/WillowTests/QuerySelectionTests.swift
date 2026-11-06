import XCTest
@testable import Willow

/// The node's `/query` selection, as `data.query` reproduces it: every filter
/// an exact match (numbers by exact decimal value), a stable sort in a total
/// order by kind, and what the node refuses, refused before sending.
final class QuerySelectionTests: XCTestCase {

    // MARK: - What the node refuses

    static let longField = "a" + String(repeating: "\u{e9}", count: 128) // 257 bytes

    /// Requests the node's query route refuses (400), by what they hold.
    static let refusedByTheNode: [(String, QueryRequest)] = [
        ("33 filters", QueryRequest(filters: (0..<33).map { QueryFilter(field: "f\($0)", operator: "eq", value: $0) })),
        ("$and", QueryBuilder().equals("$and", [1]).build()),
        ("$or", QueryBuilder().equals("$or", [1]).build()),
        ("$not", QueryBuilder().equals("$not", 1).build()),
        ("$nor", QueryBuilder().equals("$nor", [1]).build()),
        ("a filter field of 257 bytes", QueryBuilder().equals(longField, 1).build()),
        ("a filter value of 4,097 bytes", QueryBuilder().equals("s", String(repeating: "a", count: 4095)).build()),
        ("a filter value of 4,098 bytes once escaped", QueryBuilder().equals("s", String(repeating: "\"", count: 2048)).build()),
        ("a filter value of 4,100 bytes of control characters", QueryBuilder().equals("s", String(repeating: "\u{01}", count: 683)).build()),
        ("an array filter value of 4,097 bytes", QueryBuilder().equals("a", Array(repeating: 1, count: 2046) + [111]).build()),
        ("a sort field of 257 bytes", QueryBuilder().sortAsc(longField).build()),
    ]

    func testWhatTheNodeRefusesIsRefusedBeforeSending() throws {
        for (name, request) in Self.refusedByTheNode {
            XCTAssertThrowsError(try request.validateForNode(), name) { error in
                XCTAssertEqual((error as? WillowError)?.type, .validation, "\(name): \(error)")
            }
            XCTAssertThrowsError(try request.nodeBody(), name)
        }
        // Two filters on one field: the node would keep only the last. Field
        // names equal as Swift strings are one key to `encode(to:)`.
        XCTAssertThrowsError(try QueryBuilder().equals("a", 1).equals("a", 2).build().validateForNode())
        XCTAssertThrowsError(try QueryBuilder().equals("\u{e9}", 1).equals("e\u{301}", 1).build().validateForNode())
    }

    func testWhatTheNodeTakesAtItsLimitsIsSent() throws {
        let accepted: [(String, QueryRequest)] = [
            ("32 filters", QueryRequest(filters: (0..<32).map { QueryFilter(field: "f\($0)", operator: "eq", value: $0) })),
            ("a filter field of 256 bytes", QueryBuilder().equals(String(repeating: "\u{e9}", count: 128), 1).build()),
            ("a filter value of 4,096 bytes", QueryBuilder().equals("s", String(repeating: "a", count: 4094)).build()),
            ("a filter value of 4,096 bytes once escaped", QueryBuilder().equals("s", String(repeating: "\"", count: 2047)).build()),
            ("an array filter value of 4,096 bytes", QueryBuilder().equals("a", Array(repeating: 1, count: 2046) + [11]).build()),
            ("a sort field of 256 bytes", QueryBuilder().sortDesc(String(repeating: "a", count: 256)).build()),
            ("$comment, an ordinary field", QueryBuilder().equals("$comment", "x").build()),
        ]
        for (name, request) in accepted {
            XCTAssertNoThrow(try request.validateForNode(), name)
            XCTAssertNoThrow(try NodeQueryPlan(body: request.nodeBody()), name)
        }
        let two = try NodeQueryPlan(body: QueryBuilder().equals("a", 1).equals("b", "x").build().nodeBody())
        XCTAssertEqual(two.filters.map { String(decoding: $0.field, as: UTF8.self) }.sorted(), ["a", "b"])
        XCTAssertThrowsError(try NodeQueryPlan(body: Data(#"{"filters":{"a":{"$gt":1}}}"#.utf8)))
    }

    func testAFilterValueIsMeasuredAsTheNodeWritesItBack() throws {
        func length(_ text: String) throws -> Int {
            return try NodeJSON.parse(Data(text.utf8)).serializedLength
        }
        XCTAssertEqual(try length("[1.50,-0,1E5,null,true,false]"), "[1.50,0,1e+5,null,true,false]".utf8.count)
        // `/` and non-ASCII are written as they are; `"`, `\`, and control characters escaped.
        XCTAssertEqual(try length(#""\/é😀""#), 2 + 1 + 2 + 4)
        XCTAssertEqual(try length(#""\"\\\b\t\n\f\r\u0001\u007f""#), 2 + 2 * 7 + 6 + 1)
        XCTAssertEqual(try length(#"[{"a":1,"a":2},{}]"#), #"[{"a":2},{}]"#.utf8.count)
    }

    // MARK: - Every filter applies

    func testEveryFilterMustMatch() throws {
        let root = VerifiedReadsTests.dataTree([
            ("a", #"{"s":"active","n":1}"#), ("b", #"{"s":"active","n":2}"#),
            ("c", #"{"s":"inactive","n":1}"#), ("d", #"{"s":"active","n":1.0}"#), ("e", #"{"n":1}"#),
        ])
        let path = DataOperations.dataPath("sg")
        let answer = try DataOperations.answer(QueryBuilder().equals("s", "active").equals("n", 1).build(), proof: root.proof, path: path)
        XCTAssertEqual(answer.results.map { $0.key }, ["a", "d"])
        XCTAssertEqual(answer.total, 2)
    }

    // MARK: - Cross-checked with the node's query engine

    /// Items of a data tree, in key order: k22 is not an object, and k23 is
    /// not JSON (the node skips it).
    static let table: [(String, String)] = [
        ("k00", #"{"v":2}"#),
        ("k01", #"{"v":"b"}"#),
        ("k02", #"{}"#),
        ("k03", #"{"v":null}"#),
        ("k04", #"{"v":true}"#),
        ("k05", #"{"v":false}"#),
        ("k06", #"{"v":[1]}"#),
        ("k07", #"{"v":{"a":1}}"#),
        ("k08", #"{"v":1.0}"#),
        ("k09", #"{"v":-1e400}"#),
        ("k10", #"{"v":"a"}"#),
        ("k11", #"{"v":"😀"}"#),
        ("k12", #"{"v":"￿"}"#),
        ("k13", #"{"v":1}"#),
        ("k14", #"{"v":1e400}"#),
        ("k15", #"{"v":[]}"#),
        ("k16", #"{"v":-0}"#),
        ("k17", #"{"v":0.0}"#),
        ("k18", #"{"v":10e-1}"#),
        ("k19", #"{"v":"A"}"#),
        ("k20", #"{"v":{}}"#),
        ("k21", #"{"v":null}"#),
        ("k22", #"5"#),
        ("k23", #"{"v":"#),
        ("k24", #"{"v":[1.0,{"a":1E0}],"m":{"k":"x"}}"#),
        ("k25", #"{"v":[1,{"a":1}],"m":{"k":"y"}}"#),
        ("k26", #"{"v":"b","m":{"k":"x"}}"#),
        ("k27", #"{"v.w":1,"m":["x"]}"#),
    ]

    /// The keys the node selects for the request `body`, in its order.
    func selected(_ body: String) throws -> [String] {
        var documents: [(key: Data, value: NodeJSON)] = []
        for (key, text) in Self.table {
            guard let value = try? NodeJSON.parse(Data(text.utf8)) else { continue }
            documents.append((Data(key.utf8), value))
        }
        let plan = try NodeQueryPlan(body: Data(body.utf8))
        return DataOperations.select(plan, from: documents).map { String(decoding: $0.key, as: UTF8.self) }
    }

    func where_(_ filters: String) throws -> [String] {
        return try selected(#"{"filters":"# + filters + "}")
    }

    // The expected orders and match sets below are the node's, read from its
    // query engine (willow-indexing `query_engine.rs`: `sort_documents` with
    // `SortKey::total_cmp`, `apply_filters` with `json_values_equal`,
    // `numbers_equal`, and `exact_decimal`, and `get_field_value`): a stable
    // sort by kind (missing < null < false < true < numbers < strings <
    // arrays < objects), numbers by their f64 (none first), strings by code
    // point; every filter an exact match, numbers by exact decimal value.

    func testTheSortIsTheNodesTotalOrder() throws {
        XCTAssertEqual(try selected(#"{"sort":{"field":"v","order":"asc"}}"#), [
            "k02", "k22", "k27", // missing (k22 is not an object; k27's key is "v.w")
            "k03", "k21", // null
            "k05", // false
            "k04", // true
            "k09", "k14", // numbers with no finite f64
            "k16", "k17", // 0
            "k08", "k13", "k18", // 1
            "k00", // 2
            "k19", "k10", "k01", "k26", "k12", "k11", // "A" < "a" < "b" = "b" < U+FFFF < U+1F600
            "k06", "k15", "k24", "k25", // arrays tie
            "k07", "k20", // objects tie
        ])
        XCTAssertEqual(try selected(#"{"sort":{"field":"v","order":"desc"}}"#), [
            "k07", "k20",
            "k06", "k15", "k24", "k25",
            "k11", "k12", "k01", "k26", "k10", "k19",
            "k00",
            "k08", "k13", "k18",
            "k16", "k17",
            "k09", "k14",
            "k04",
            "k05",
            "k03", "k21",
            "k02", "k22", "k27",
        ])
        // A dotted sort field reaches into objects only.
        XCTAssertEqual(Array(try selected(#"{"sort":{"field":"m.k","order":"desc"}}"#).prefix(3)), ["k25", "k24", "k26"])
    }

    func testFiltersMatchAsTheNodesDo() throws {
        XCTAssertEqual(try where_(#"{"v":1}"#), ["k08", "k13", "k18"])
        XCTAssertEqual(try where_(#"{"v":1.000e0}"#), ["k08", "k13", "k18"])
        XCTAssertEqual(try where_(#"{"v":0}"#), ["k16", "k17"])
        XCTAssertEqual(try where_(#"{"v":-0.0}"#), ["k16", "k17"])
        XCTAssertEqual(try where_(#"{"v":1e400}"#), ["k14"])
        XCTAssertEqual(try where_(#"{"v":-1E+400}"#), ["k09"])
        XCTAssertEqual(try where_(#"{"v":null}"#), ["k03", "k21"])
        XCTAssertEqual(try where_(#"{"v":false}"#), ["k05"])
        XCTAssertEqual(try where_(#"{"v":"b"}"#), ["k01", "k26"])
        XCTAssertEqual(try where_(#"{"v":[]}"#), ["k15"])
        XCTAssertEqual(try where_(#"{"v":[1e0]}"#), ["k06"])
        XCTAssertEqual(try where_(#"{"v":[1,{"a":1.0}]}"#), ["k24", "k25"])
        XCTAssertEqual(try where_(#"{"v":[1,{"a":1,"b":2}]}"#), [])
        XCTAssertEqual(try where_(#"{"v":"b","m.k":"x"}"#), ["k26"])
        XCTAssertEqual(try where_(#"{"m.k":"x"}"#), ["k24", "k26"])
        XCTAssertEqual(try where_(#"{"v.w":1}"#), [])
        XCTAssertEqual(try where_(#"{"m.0":"x"}"#), [])
        XCTAssertEqual(try where_(#"{"v":1,"m.k":"x"}"#), [])
    }

    func testNumbersCompareAsTheNodesExactDecimalReadsThem() {
        let max = "170141183460469231731687303715884105727" // i128::MAX
        let maxPlus1 = "170141183460469231731687303715884105728"
        let maxPlus2 = "170141183460469231731687303715884105729"
        let maxMinus1 = "170141183460469231731687303715884105726"
        let cases: [(String, String, Bool)] = [
            ("1", "1.0", true),
            ("1", "1e+0", true),
            ("100", "1e+2", true),
            ("1.5", "15e-1", true),
            ("0", "-0.0", true),
            ("0", "0e+5", true),
            ("-1", "1", false),
            ("12345678901234567890", "12345678901234567891", false),
            ("9007199254740993", "9007199254740992", false),
            ("1e+\(max)", "10e+\(maxMinus1)", true),
            ("10e+\(max)", "1e+\(maxPlus1)", false), // + a trailing zero passes i128::MAX
            ("1e+\(maxPlus1)", "1.0e+\(maxPlus1)", false), // past i128: texts differ
            ("1e+\(maxPlus1)", "1e+\(maxPlus1)", true),
            ("1e-\(maxPlus1)", "0.1e-\(max)", true), // i128::MIN
            ("1.0e-\(maxPlus1)", "1e-\(maxPlus2)", false), // - a fraction digit passes i128::MIN
            ("0e+\(maxPlus1)", "0", false),
            ("0e+\(max)", "0", true),
            ("1e+18446744073709551616", "10e+18446744073709551615", true), // past u64, within i128
            ("1e+" + String(repeating: "0", count: 60) + "5", "1e+5", true),
        ]
        for (a, b, equal) in cases {
            XCTAssertEqual(NodeJSON.numbersEqual(a, b), equal, "\(a) \(b)")
            XCTAssertEqual(NodeJSON.numbersEqual(b, a), equal, "\(b) \(a)")
        }
        XCTAssertEqual(NodeJSON.exactDecimal("-0.0"), NodeJSON.exactDecimal("0"))
        XCTAssertEqual(NodeJSON.exactDecimal("-12.3400e+2"), NodeJSON.exactDecimal("-1234"))
        XCTAssertNotEqual(NodeJSON.exactDecimal("-1234"), NodeJSON.exactDecimal("1234"))
        XCTAssertNil(I128(Array(maxPlus1.utf8)))
        XCTAssertNotNil(I128(Array("-\(maxPlus1)".utf8)))
        XCTAssertNil(I128(Array("-\(maxPlus2)".utf8)))
        XCTAssertNil(I128(Array(max.utf8))?.adding(1))
        XCTAssertNil(I128(Array("-\(maxPlus1)".utf8))?.adding(-1))
        XCTAssertEqual(I128(Array("18446744073709551616".utf8))?.adding(-1), I128(Array("18446744073709551615".utf8)))
    }
}
