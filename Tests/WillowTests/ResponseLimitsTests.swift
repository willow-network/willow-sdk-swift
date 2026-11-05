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
}
