import XCTest
@testable import Willow

/// Where a verified read's header comes from: only a consensus RPC the caller
/// configures (or a local node's), never the API whose proof it checks.
final class TrustModelTests: XCTestCase {

    static let bob = "user:bob"

    /// A server for the API at `api.test` serving `value` and the proof
    /// `tree` at `height`, and for CometBFT's RPC routes from `chain`: on
    /// `rpc.test`, or, when `rpcOnAPI` is set, on the API itself, as a
    /// hostile API would serve them.
    static func server(
        tree: Locked<(ProofBuilder.Built, String, Int64)>, chain: Locked<StubChain>, rpcOnAPI: Bool = false
    ) -> StubServer {
        return StubServer { request in
            let (proof, value, height) = tree.value
            if request.url.host == "rpc.test" {
                return chain.value.answer(request)
            }
            switch request.path {
            case "/data/sg/\(bob)":
                return (200, #"{"success":true,"data":\#(value)}"#)
            case "/proof/sg/\(bob)":
                return (200, #"{"success":true,"data":{"proof":"\#(proof.proof.hexString)","height":\#(height)}}"#)
            case "/query/sg":
                return (200, #"{"success":true,"data":{"documents":[],"total":0,"offset":0,"limit":100,"proof":"\#(proof.proof.hexString)","height":\#(height)}}"#)
            default:
                return rpcOnAPI ? chain.value.answer(request) : (404, "")
            }
        }
    }

    /// A hostile API forges a value, a proof that hashes to a forged root,
    /// and a CometBFT header carrying that root. A header taken from the API
    /// can't vouch for its proof: without a consensus RPC, a verified read
    /// throws before sending anything.
    func testWithoutAConsensusRPCAVerifiedReadSendsNothing() async throws {
        let value = #"{"balance":1000000}"#
        let forged = VerifiedReadsTests.dataTree([(Self.bob, value)])
        let chain = StubChain(headers: [42: (forged.hash.hexString, Date().addingTimeInterval(-5))])
        let stub = Self.server(tree: Locked((forged, value, 41)), chain: Locked(chain), rpcOnAPI: true)
        let client = try stub.client(baseURL: "https://api.test")

        do {
            let response = try await client.data.get(subgroveId: "sg", key: Self.bob)
            XCTFail("a value the API forged, checked against a header the API served, was returned as verified: \(response.data)")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .config, error.message)
            XCTAssertTrue(error.message.contains("consensusRpcURL"), error.message)
        }
        do {
            let response = try await client.data.query(subgroveId: "sg", query: QueryRequest())
            XCTFail("a query answered from a forged proof was returned as verified: \(response.results.count)")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .config, error.message)
        }
        XCTAssertEqual(stub.requests.map { $0.target }, [], "nothing is sent")
        XCTAssertFalse(client.hasLightClient())
    }

    /// With a consensus RPC configured, the headers come from it alone: the
    /// API is asked only for the value and its proof.
    func testVerifiedReadsTakeHeadersOnlyFromTheConsensusRPC() async throws {
        let value = #"{"balance":250}"#
        let tree = VerifiedReadsTests.dataTree([(Self.bob, value)])
        let chain = StubChain(headers: [42: (tree.hash.hexString, Date().addingTimeInterval(-5))])
        // The API also answers CometBFT's routes, with another root.
        let other = StubChain(headers: [42: (String(repeating: "ab", count: 32), Date().addingTimeInterval(-5))])
        let stub = StubServer { request in
            if request.url.host == "rpc.test" {
                return chain.answer(request)
            }
            switch request.path {
            case "/data/sg/\(Self.bob)":
                return (200, #"{"success":true,"data":\#(value)}"#)
            case "/proof/sg/\(Self.bob)":
                return (200, #"{"success":true,"data":{"proof":"\#(tree.proof.hexString)","height":41}}"#)
            default:
                return other.answer(request)
            }
        }
        let client = try stub.client(baseURL: "https://api.test", consensusRpcURL: "https://rpc.test/")

        let response = try await client.data.get(subgroveId: "sg", key: Self.bob)
        XCTAssertEqual(response.data["balance"]?.value as? Int, 250)
        XCTAssertEqual(response.proof?.header.height, 42)
        XCTAssertEqual(
            stub.requests.filter { $0.url.host == "api.test" }.map { $0.target }, ["/data/sg/user:bob", "/proof/sg/user:bob"])
        XCTAssertEqual(Set(stub.requests.filter { $0.url.host == "rpc.test" }.map { $0.path }), ["/status", "/commit", "/validators"])
    }

    /// Only an API on this machine at port 3031 has its node's RPC derived
    /// (port 26657); any other API needs `consensusRpcURL`.
    func testOnlyALocalAPIsRPCIsDerived() throws {
        func rpc(_ api: String) -> String? {
            return WillowClient.localConsensusRPC(forAPI: URL(string: api)!)?.absoluteString
        }
        XCTAssertEqual(rpc("http://localhost:3031"), "http://localhost:26657")
        XCTAssertEqual(rpc("http://127.0.0.1:3031/"), "http://127.0.0.1:26657")
        XCTAssertEqual(rpc("http://[::1]:3031"), "http://[::1]:26657")
        XCTAssertNil(rpc("https://api.willow.tech"))
        XCTAssertNil(rpc("http://api.example.com:3031"))
        XCTAssertNil(rpc("http://localhost:8080"))
        XCTAssertNil(rpc("http://10.0.0.5:3031"))
        XCTAssertNil(rpc("http://localhost.example.com:3031"))

        XCTAssertNil(try WillowClient(baseURL: "https://api.example.com").consensusRPC())
        XCTAssertNil(try WillowClient(baseURL: "https://api.example.com:3031").consensusRPC())
        XCTAssertEqual(try WillowClient(baseURL: "http://localhost:3031").consensusRPC(), "http://localhost:26657")
        XCTAssertEqual(
            try WillowClient(baseURL: "https://api.example.com", consensusRpcURL: "https://rpc.example.com/").consensusRPC(),
            "https://rpc.example.com")
        XCTAssertThrowsError(try WillowClient(baseURL: "https://api.example.com", consensusRpcURL: "not a url"))
    }
}
