import XCTest
@testable import Willow

final class CompletenessTests: XCTestCase {

    // Cross-language correctness gate. These hashes are produced by the
    // canonical Rust `canonical_event_set_hash`; any byte-layout or endianness
    // drift in `canonicalEventSetHash` flips them.

    func testVectorAEmptySet() {
        let hash = canonicalEventSetHash(blockNumber: 0, matchedLogs: [])
        XCTAssertEqual(
            hash.hexString,
            "52089e4c924fbab0475d310d7f74bf8cae542d006a45d3c5d94adacda6937da5"
        )
    }

    func testVectorBTwoLogs() {
        let logs = Self.vectorBLogs
        let hash = canonicalEventSetHash(blockNumber: 7, matchedLogs: logs)
        XCTAssertEqual(
            hash.hexString,
            "e1544ae919458663e8fce14bdcd06df6a777410c068302c0584dff1587524dfd"
        )
    }

    func testVerifyServedEventsAcceptsExactMatch() {
        let commitment = Data(hexString:
            "e1544ae919458663e8fce14bdcd06df6a777410c068302c0584dff1587524dfd")!
        XCTAssertTrue(verifyServedEvents(
            commitment: commitment,
            blockNumber: 7,
            matchedLogs: Self.vectorBLogs
        ))
    }

    func testVerifyServedEventsRejectsTampering() {
        let commitment = Data(hexString:
            "e1544ae919458663e8fce14bdcd06df6a777410c068302c0584dff1587524dfd")!

        // Wrong block number.
        XCTAssertFalse(verifyServedEvents(
            commitment: commitment, blockNumber: 8, matchedLogs: Self.vectorBLogs))

        // Dropped log.
        XCTAssertFalse(verifyServedEvents(
            commitment: commitment, blockNumber: 7,
            matchedLogs: [Self.vectorBLogs[0]]))

        // Added log.
        var extended = Self.vectorBLogs
        extended.append(CompletenessLog(
            address: Data(repeating: 0x44, count: 20), topics: [], data: Data()))
        XCTAssertFalse(verifyServedEvents(
            commitment: commitment, blockNumber: 7, matchedLogs: extended))

        // Flipped one data byte.
        var flipped = Self.vectorBLogs
        flipped[0] = CompletenessLog(
            address: flipped[0].address,
            topics: flipped[0].topics,
            data: Data([0x01, 0x02, 0x03, 0x05]))
        XCTAssertFalse(verifyServedEvents(
            commitment: commitment, blockNumber: 7, matchedLogs: flipped))
    }

    // MARK: - Endpoint preimage parsing

    // Gates the JSON -> CompletenessLog mapping against the authoritative
    // vector: parsing the indexer's matched-logs body must reproduce the exact
    // CompletenessLog set whose hash is `vectorB`. If field extraction, hex
    // decoding, or 0x-prefix handling drifts, verification flips to false.
    func testParseMatchedLogsMatchesAuthoritativeVector() throws {
        let logs = try parseMatchedLogs(Data(Self.matchedLogsBody.utf8))
        XCTAssertEqual(logs, Self.vectorBLogs)

        let commitment = Data(hexString:
            "e1544ae919458663e8fce14bdcd06df6a777410c068302c0584dff1587524dfd")!
        XCTAssertTrue(verifyServedEvents(commitment: commitment, blockNumber: 7, matchedLogs: logs))
    }

    func testParseEventsCommitmentDecodesAnchor() throws {
        let body = """
        { "subgrove_id": "sg", "block_number": 7,
          "events_commitment": "e1544ae919458663e8fce14bdcd06df6a777410c068302c0584dff1587524dfd" }
        """
        let commitment = try parseEventsCommitment(Data(body.utf8))
        XCTAssertEqual(commitment.count, 32)
        XCTAssertEqual(
            commitment.hexString,
            "e1544ae919458663e8fce14bdcd06df6a777410c068302c0584dff1587524dfd"
        )
    }

    // MARK: - End-to-end wrapper (mocked transport)

    // Full verifyBlockCompleteness path with both endpoints stubbed: the ABCI
    // store query returns the events_commitment anchor (base64 over the RPC
    // envelope) and the indexer GET returns the matched-logs body. Asserts the
    // wrapper composes fetch -> fetch -> verify into `true`.
    func testVerifyBlockCompletenessEndToEndMocked() async throws {
        let anchorJSON = """
        { "subgrove_id": "sg", "block_number": 7,
          "events_commitment": "e1544ae919458663e8fce14bdcd06df6a777410c068302c0584dff1587524dfd" }
        """
        let anchorValueB64 = Data(anchorJSON.utf8).base64EncodedString()

        StubURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            if url.contains(":26657") {
                // CometBFT abci_query JSON-RPC envelope.
                let rpc = """
                { "jsonrpc": "2.0", "id": 1, "result":
                  { "response": { "code": 0, "value": "\(anchorValueB64)" } } }
                """
                return (200, Data(rpc.utf8))
            }
            // Indexer matched-logs GET.
            XCTAssertTrue(url.contains("/completeness/sg/7/matched-logs"))
            return (200, Data(Self.matchedLogsBody.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let config = ConsensusConfig(
            consensusRpcUrl: "http://localhost:26657",
            indexerUrl: "http://localhost:3051"
        )
        let client = ConsensusClient(config, session: session)

        let verified = try await client.verifyBlockCompleteness(subgroveId: "sg", blockNumber: 7)
        XCTAssertTrue(verified)
    }

    // The exact authoritative matched-logs response body (willow PR #676).
    private static let matchedLogsBody = """
    {
      "subgrove_id": "sg", "block_number": 7, "count": 2,
      "matched_logs": [
        { "block_number": 7, "block_hash": "0x0000000000000000000000000000000000000000000000000000000000000000",
          "transaction_hash": "0x0000000000000000000000000000000000000000000000000000000000000000",
          "transaction_index": 0, "log_index": "0x0",
          "address": "0x4242424242424242424242424242424242424242",
          "topics": ["0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                     "0x1111111111111111111111111111111111111111111111111111111111111111"],
          "data": "0x01020304", "removed": false },
        { "block_number": 7, "block_hash": "0x0000000000000000000000000000000000000000000000000000000000000000",
          "transaction_hash": "0x0000000000000000000000000000000000000000000000000000000000000000",
          "transaction_index": 0, "log_index": "0x1",
          "address": "0x4343434343434343434343434343434343434343",
          "topics": ["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
          "data": "0x", "removed": false } ]
    }
    """

    private static let vectorBLogs: [CompletenessLog] = [
        CompletenessLog(
            address: Data(repeating: 0x42, count: 20),
            topics: [Data(repeating: 0xdd, count: 32), Data(repeating: 0x11, count: 32)],
            data: Data([0x01, 0x02, 0x03, 0x04])
        ),
        CompletenessLog(
            address: Data(repeating: 0x43, count: 20),
            topics: [Data(repeating: 0xaa, count: 32)],
            data: Data()
        ),
    ]
}

// MARK: - Stub transport

/// Minimal `URLProtocol` stub: routes every request through a closure that
/// returns `(statusCode, body)`. Used to drive `verifyBlockCompleteness`
/// without a live validator or indexer.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
