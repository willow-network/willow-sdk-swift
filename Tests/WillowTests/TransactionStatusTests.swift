import XCTest
@testable import Willow

/// `getTransactionStatus` and `waitForTransaction` ask CometBFT's `tx` for
/// the hash in the form its JSON-RPC reads: base64.
final class TransactionStatusTests: XCTestCase {

    static let hashHex = String(repeating: "AB", count: 31) + "CD"

    /// The API's hex hash was sent as is, which CometBFT reads as base64 (or
    /// refuses), so every poll found nothing and a landed transaction read
    /// as pending until the timeout.
    func testWaitingFindsATransactionByItsHash() async throws {
        let base64 = try XCTUnwrap(Data(hexString: Self.hashHex)).base64EncodedString()
        let stub = StubServer { request in
            guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  body["method"] as? String == "tx",
                  let params = body["params"] as? [String: Any], params["hash"] as? String == base64 else {
                return (200, #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"Internal error","data":"tx not found"}}"#)
            }
            XCTAssertEqual(params["prove"] as? Bool, false)
            return (200, #"{"jsonrpc":"2.0","id":1,"result":{"hash":"\#(Self.hashHex)","height":"7","tx_result":{"code":0}}}"#)
        }
        let consensus = ConsensusClient(
            ConsensusConfig(consensusRpcUrl: "http://rpc.test", maxRetries: 0, retryDelaySecs: 0), session: stub.session)
        let status = try await consensus.waitForTransaction(txHash: Self.hashHex, timeoutSecs: 1, pollInterval: 0.05)
        XCTAssertEqual(status, .success)
        let lowered = try await consensus.getTransactionStatus(txHash: "0x" + Self.hashHex.lowercased())
        XCTAssertEqual(lowered, .success)

        do {
            _ = try await consensus.getTransactionStatus(txHash: "not a hash")
            XCTFail("a hash that isn't hex was sent")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
    }
}
