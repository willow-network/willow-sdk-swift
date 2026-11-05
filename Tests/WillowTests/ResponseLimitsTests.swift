import XCTest
@testable import Willow

/// Every answer is read under a cap for its route, and refused, not retried,
/// once it passes it.
final class ResponseLimitsTests: XCTestCase {

    /// 4 MiB of JSON whitespace, which pads an answer past the small cap
    /// without changing what it decodes to.
    static let padding = String(repeating: " ", count: 4 << 20)

    /// An answer of a fixed shape past 4 MiB is refused before it is
    /// decoded, and not retried; a list the node doesn't page may be larger.
    func testAnAnswerPastItsRoutesCapIsRefusedAndNotRetried() async throws {
        let stub = StubServer { request in
            switch request.path {
            case "/state/root-hash":
                return (200, #"{"success":true,"data":{"root_hash":"ab"},"error":null}"# + Self.padding)
            case "/subgroves":
                return (200, #"{"success":true,"data":[],"error":null}"# + Self.padding + Self.padding)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        do {
            let root = try await client.getRootHash()
            XCTFail("read an answer past 4 MiB: \(root)")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .responseTooLarge, error.message)
            XCTAssertTrue(error.message.contains("4 MiB"), error.message)
        }
        XCTAssertEqual(stub.requests.filter { $0.path == "/state/root-hash" }.count, 1)

        let subgroves = try await client.registration.listSubgroves()
        XCTAssertTrue(subgroves.isEmpty)
    }

    /// The consensus client's RPC answers are capped too, and one past its
    /// cap isn't retried.
    func testAConsensusRPCAnswerPastItsCapIsRefusedAndNotRetried() async throws {
        let stub = StubServer { _ in
            (200, #"{"jsonrpc":"2.0","id":1,"result":{"node_info":{"network":"c"}}}"# + Self.padding)
        }
        let consensus = ConsensusClient(
            ConsensusConfig(consensusRpcUrl: "http://rpc.test", apiUrl: "http://api.test"), session: stub.session)
        do {
            let status = try await consensus.getStatus()
            XCTFail("read an answer past 4 MiB: \(status)")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .responseTooLarge, error.message)
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    /// `levels` arrays nested around `0`.
    static func nested(_ levels: Int) -> String {
        return String(repeating: "[", count: levels) + "0" + String(repeating: "]", count: levels)
    }

    /// An answer nested 500 levels deep overflowed a task's stack as
    /// `AnyCodable` decoded it (before any proof was read, for a verified
    /// get), crashing the process. It is refused before it is decoded; an
    /// answer nested to the limit still reads on a task's stack, and brackets
    /// inside strings don't count.
    func testDeeplyNestedAnswersAreRefusedBeforeDecoding() async throws {
        let deep = Self.nested(500)
        let stub = StubServer { request in
            switch request.path {
            case "/data/sg/deep":
                return (200, #"{"success":true,"data":{"a":"# + deep + "}}")
            case "/data/sg/strings":
                let brackets = String(repeating: "[{", count: 300)
                return (200, #"{"success":true,"data":{"a":"\"\#(brackets)","b":"\#(brackets)\\"}}"#)
            case "/query/deep", "/query/sg":
                // The documents' array and object, and the envelope's two
                // objects, hold the value 4 levels down: 156 reaches the limit.
                let levels = request.path == "/query/deep" ? 500 : HTTPBody.maxJSONDepth - 4
                return (200, #"{"success":true,"data":{"documents":[{"a":"# + Self.nested(levels) + #"}],"total":1},"error":null}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        let outcome: (refused: [String], read: [Int]) = try await Task.detached {
            var refused: [String] = []
            do {
                _ = try await client.data.getUnverified(subgroveId: "sg", key: "deep")
                refused.append("read")
            } catch let error as WillowError {
                refused.append(error.type.rawValue)
            }
            do {
                _ = try await client.data.queryUnverified(subgroveId: "deep", query: QueryRequest())
                refused.append("read")
            } catch let error as WillowError {
                refused.append(error.type.rawValue)
            }
            let strings = try await client.data.getUnverified(subgroveId: "sg", key: "strings")
            let page = try await client.data.queryUnverified(subgroveId: "sg", query: QueryRequest())
            var depth = 0
            var current: Any? = page.results.first?.data["a"]?.value
            while let array = current as? [Any] {
                depth += 1
                current = array.first
            }
            return (refused, [strings.data.count, depth])
        }.value
        XCTAssertEqual(outcome.refused, ["response_too_large", "response_too_large"])
        XCTAssertEqual(outcome.read, [2, HTTPBody.maxJSONDepth - 4])
    }

    /// The scan counts brackets outside strings only, and an escaped quote
    /// doesn't end a string.
    func testTheNestingScanSkipsStrings() throws {
        let limit = HTTPBody.maxJSONDepth
        XCTAssertNoThrow(try HTTPBody.checkNesting(Array(Self.nested(limit).utf8)))
        XCTAssertThrowsError(try HTTPBody.checkNesting(Array(Self.nested(limit + 1).utf8)))
        let quoted = #"["\"\#(String(repeating: "[", count: limit + 1))", "\\"]"#
        XCTAssertNoThrow(try HTTPBody.checkNesting(Array(quoted.utf8)))
        let afterEscapedBackslash = #"["\\", "# + Self.nested(limit) + "]"
        XCTAssertThrowsError(try HTTPBody.checkNesting(Array(afterEscapedBackslash.utf8)))
    }
}
