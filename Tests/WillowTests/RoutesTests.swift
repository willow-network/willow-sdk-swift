import XCTest
@testable import Willow

/// Each client method reads the route the API server serves and decodes its
/// `{ success, data, error }` envelope.
final class RoutesTests: XCTestCase {

    func testGetUnverifiedReadsTheDataRoute() async throws {
        let stub = StubServer { request in
            XCTAssertEqual("\(request.method) \(request.target)", "GET /data/sg/k")
            return (200, #"{"success":true,"data":{"title":"hello","n":2},"error":null}"#)
        }
        let client = try stub.client(baseURL: "http://api.test")

        let response = try await client.data.getUnverified(subgroveId: "sg", key: "k")
        XCTAssertEqual(response.key, "k")
        XCTAssertEqual(response.data["title"]?.value as? String, "hello")
        XCTAssertEqual(response.data["n"]?.value as? Int, 2)
        XCTAssertNil(response.proof)
    }

    func testMissingDataIsNotFound() async throws {
        // The API answers a missing key with HTTP 200 and success: false.
        let stub = StubServer { _ in (200, #"{"success":false,"data":null,"error":"Data not found"}"#) }
        let client = try stub.client(baseURL: "http://api.test")

        do {
            _ = try await client.data.getUnverified(subgroveId: "sg", key: "k")
            XCTFail("expected not found")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .notFound)
        }
    }

    func testVerifiedGetReadsTheProofAndRefusesOneThatDoesNotVerify() async throws {
        let identity = try RequestSigningTests.vectorIdentity(.ed25519)
        let stub = StubServer { request in
            switch request.path {
            case "/data/sg/k":
                return (200, #"{"success":true,"data":{"a":1}}"#)
            case "/proof/sg/k":
                return (200, #"{"success":true,"data":{"proof":"00000000ff","path":[],"key":"6b","height":7}}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(identity)

        do {
            _ = try await client.data.get(subgroveId: "sg", key: "k")
            XCTFail("an unverifiable proof must not return the value")
        } catch {}
        XCTAssertEqual(stub.requests.map { "\($0.method) \($0.target)" }, ["GET /data/sg/k", "GET /proof/sg/k"])
        for request in stub.requests {
            try request.assertNonceSigned(by: identity)
        }
    }

    func testVerifiedGetRefusesAMissingProof() async throws {
        let stub = StubServer { request in
            if request.path == "/data/sg/k" {
                return (200, #"{"success":true,"data":{"a":1}}"#)
            }
            return (500, #"{"success":false,"data":null,"error":"Error generating proof"}"#)
        }
        let client = try stub.client(baseURL: "http://api.test")

        do {
            _ = try await client.data.get(subgroveId: "sg", key: "k")
            XCTFail("a value without a proof must not be returned as verified")
        } catch {}
    }

    func testProvenValueMustBeTheValueServed() throws {
        let json = Data(#"{"a":1,"b":"x"}"#.utf8)
        // Element::Item(bytes, None): variant 0, varint length, bytes, no flags.
        let item = Data([0x00, UInt8(json.count)]) + json + Data([0x00])
        let result = GroveDBVerificationResult(rootHash: "00", results: [
            GroveDBQueryResult(path: DataOperations.dataPath("sg"), key: Data("k".utf8), value: item),
        ])
        let served: [String: AnyCodable] = ["b": AnyCodable("x"), "a": AnyCodable(1)]

        XCTAssertNoThrow(try DataOperations.requireProven(key: "k", value: served, in: result))
        XCTAssertThrowsError(try DataOperations.requireProven(key: "k", value: ["a": AnyCodable(2)], in: result))
        XCTAssertThrowsError(try DataOperations.requireProven(key: "other", value: served, in: result))

        let notItem = GroveDBVerificationResult(rootHash: "00", results: [
            GroveDBQueryResult(path: DataOperations.dataPath("sg"), key: Data("k".utf8), value: Data([0x02]) + item.dropFirst()),
        ])
        XCTAssertThrowsError(try DataOperations.requireProven(key: "k", value: served, in: notItem))
    }

    func testGroveItemBytesReadsLongLengths() {
        let payload = Data(repeating: 0x41, count: 300)
        // 251 marks a two-byte big-endian length.
        let element = Data([0x00, 251, 0x01, 0x2c]) + payload + Data([0x00])
        XCTAssertEqual(DataOperations.groveItemBytes(element), payload)
        XCTAssertNil(DataOperations.groveItemBytes(Data([0x00, 251, 0x01])))
        XCTAssertNil(DataOperations.groveItemBytes(Data([0x00, 5, 1, 2])))
    }

    func testQueryUnverifiedReadsTheQueryRoute() async throws {
        let stub = StubServer { request in
            XCTAssertEqual("\(request.method) \(request.target)", "POST /query/sg")
            return (200, #"""
            {"success":true,"data":{"documents":[{"a":1},{"a":2}],"total":5,"offset":0,"limit":2,
             "verification":{"is_verified":false}},"error":null}
            """#)
        }
        let client = try stub.client(baseURL: "http://api.test")

        let response = try await client.data.queryUnverified(subgroveId: "sg", query: QueryRequest(limit: 2))
        XCTAssertEqual(response.results.map { $0.data["a"]?.value as? Int }, [1, 2])
        XCTAssertEqual(response.totalCount, 5)
        XCTAssertTrue(response.hasMore)
        XCTAssertNil(response.proof)
    }

    func testVerifiedQueryAsksForAndRequiresAProof() async throws {
        let stub = StubServer { request in
            let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            XCTAssertEqual(body?["include_proof"] as? Bool, true)
            return (200, #"{"success":true,"data":{"documents":[],"total":0,"offset":0,"limit":100}}"#)
        }
        let client = try stub.client(baseURL: "http://api.test")

        do {
            _ = try await client.data.query(subgroveId: "sg", query: QueryRequest())
            XCTFail("a query answered without a proof must not pass as verified")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .proof)
        }
    }

    func testQueryProofIsReadAsHex() throws {
        let json = Data(#"{"documents":[],"total":0,"offset":0,"limit":100,"proof":"0a0b","height":9}"#.utf8)
        let response = try JSONDecoder().decode(QueryResponse.self, from: json)
        XCTAssertEqual(response.proof, Data([0x0a, 0x0b]))
    }

    func testGetRootHashReadsStateRootHash() async throws {
        let stub = StubServer { request in
            XCTAssertEqual(request.target, "/state/root-hash")
            return (200, #"{"success":true,"data":{"root_hash":"f264e0","note":"n"},"error":null}"#)
        }
        let client = try stub.client(baseURL: "http://api.test")

        let rootHash = try await client.getRootHash()
        XCTAssertEqual(rootHash, "f264e0")
    }

    func testGetPermissionsReadsTheDIDPermissionsRoute() async throws {
        let stub = StubServer { request in
            XCTAssertEqual(request.target, "/did/did:willow:a/permissions")
            return (200, #"""
            {"success":true,"data":[{"did":"did:willow:a","subgrove_id":"sg","role":"reader",
             "granted_by":"did:willow:o","granted_at":1000}],"error":null}
            """#)
        }
        let client = try stub.client(baseURL: "http://api.test")

        let permissions = try await client.registration.getPermissions(did: "did:willow:a")
        XCTAssertEqual(permissions.count, 1)
        XCTAssertEqual(permissions[0].subgroveId, "sg")
        XCTAssertEqual(permissions[0].role, "reader")
        XCTAssertEqual(permissions[0].grantedBy, "did:willow:o")
        XCTAssertEqual(permissions[0].actions, [])
    }

    func testGetFeeScheduleReadsFeesScheduleOnce() async throws {
        let stub = StubServer { request in
            XCTAssertEqual(request.target, "/fees/schedule")
            // The amounts are u128 JSON integers; 1e20 is past UInt64.
            return (200, #"""
            {"success":true,"data":{"did_registration":1000000000000000000,
             "subgrove_registration":100000000000000000000,"base_tx_cost":24000000000000000,
             "cost_per_byte":86400000000000,"query_fee":4000000000000000,"transfer_fee_percentage":10,
             "max_tx_size_bytes":67108864,"max_data_payload_bytes":524288},"error":null}
            """#)
        }
        let client = try stub.client(baseURL: "http://api.test")

        let schedule = try await client.token.getFeeSchedule()
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(schedule.didRegistration, "1000000000000000000")
        XCTAssertEqual(schedule.subgroveRegistration, "100000000000000000000")
        XCTAssertEqual(schedule.baseTxCost, "24000000000000000")
        XCTAssertEqual(schedule.costPerByte, "86400000000000")
        XCTAssertEqual(schedule.maxDataPayloadBytes, 524288)
    }

    func testFileTransactionsGoToTxSubmit() async throws {
        var code = 0
        let stub = StubServer { request in
            XCTAssertEqual("\(request.method) \(request.target)", "POST /tx/submit")
            return (200, #"{"success":true,"data":{"tx_hash":"AB","code":\#(code),"log":"bad nonce"},"error":null}"#)
        }
        let client = try stub.client(baseURL: "http://api.test")
        let signing = FileSigningOptions(
            ownerDid: "did:willow:a", privateKey: Data(), publicKeyId: "did:willow:a#key-1",
            signFunction: { _, _ in Data([1, 2, 3]) }, nonce: 4
        )

        try await client.files.delete(subgroveId: "sg", fileKey: "f", signing: signing)
        try await client.files.unregisterStorageNode(nodeDid: "did:willow:n", signing: signing)

        let delete = try XCTUnwrap(try JSONSerialization.jsonObject(with: stub.requests[0].body) as? [String: Any])
        // The variant name keeps its case: a snake_case key is not a Transaction.
        let deleteBody = try XCTUnwrap(delete["DeleteFileManifest"] as? [String: Any])
        XCTAssertEqual(deleteBody["signature"] as? [Int], [1, 2, 3])
        XCTAssertEqual(deleteBody["nonce"] as? Int, 4)
        let unregister = try XCTUnwrap(try JSONSerialization.jsonObject(with: stub.requests[1].body) as? [String: Any])
        XCTAssertNotNil(unregister["UnregisterStorageNode"])

        // CheckTx refusals come back as HTTP 200 with a nonzero code.
        let before = stub.requests.count
        code = 5
        do {
            try await client.files.delete(subgroveId: "sg", fileKey: "f", signing: signing)
            XCTFail("a refused transaction must throw")
        } catch let error as TransactionError {
            XCTAssertEqual(error.errorCode, 5)
            XCTAssertEqual(error.txHash, "AB")
        }
        XCTAssertEqual(stub.requests.count, before + 1)
    }

    func testTransactionsAreSentOnce() async throws {
        let stub = StubServer { _ in (502, #"{"success":false,"data":null,"error":"Failed to reach CometBFT RPC"}"#) }
        let client = try stub.client(baseURL: "http://api.test")

        do {
            try await client.files.delete(subgroveId: "sg", fileKey: "f")
            XCTFail("a 502 must throw")
        } catch let error as HTTPError {
            XCTAssertEqual(error.statusCode, 502)
        }
        // The transaction may have reached the mempool; a resend would be a replay.
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testFileManifestCarriesHashesAsBytes() async throws {
        let stub = StubServer { _ in (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""}}"#) }
        let client = try stub.client(baseURL: "http://api.test")

        // The manifest is submitted first; the chunk upload to a closed port then fails.
        do {
            _ = try await client.files.upload(
                subgroveId: "sg", fileKey: "f", filename: "a.txt", data: Data("hello".utf8),
                storageNodeEndpoint: "http://127.0.0.1:1"
            )
        } catch {}

        let submitted = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(submitted.target, "/tx/submit")
        let tx = try XCTUnwrap(try JSONSerialization.jsonObject(with: submitted.body) as? [String: Any])
        let manifest = try XCTUnwrap(tx["StoreFileManifest"] as? [String: Any])
        // [u8; 32] fields are JSON arrays of numbers.
        let contentHash = try XCTUnwrap(manifest["content_hash"] as? [Int])
        XCTAssertEqual(Data(contentHash.map { UInt8($0) }).hexString,
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual((manifest["chunk_merkle_root"] as? [Int])?.count, 32)
    }

    func testConsensusFileManifestCarriesHashesAsBytes() async throws {
        let stub = StubServer { request in
            if request.path.hasSuffix("/nonce") {
                return (200, #"{"success":true,"data":{"nonce":0}}"#)
            }
            return (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""}}"#)
        }
        let consensus = ConsensusClient(
            ConsensusConfig(consensusRpcUrl: "http://rpc.test", apiUrl: "http://api.test"),
            session: stub.session
        )
        let hash = String(repeating: "ab", count: 32)

        let result = try await consensus.storeFileManifest(
            subgroveId: "sg", fileKey: "f", filename: "a.txt", contentType: "text/plain", totalSize: 5,
            contentHash: hash.uppercased(), chunkCount: 1, chunkSize: 5, chunkMerkleRoot: hash,
            ownerDid: "did:willow:a", privateKey: Data(), publicKeyId: "did:willow:a#key-1",
            signFunction: { message, _ in
                XCTAssertEqual(String(decoding: message, as: UTF8.self), "store_file:sg:f:\(hash):5")
                return Data([9])
            }
        )
        XCTAssertTrue(result.success)

        let submitted = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(submitted.target, "/tx/submit")
        let tx = try XCTUnwrap(try JSONSerialization.jsonObject(with: submitted.body) as? [String: Any])
        let manifest = try XCTUnwrap(tx["StoreFileManifest"] as? [String: Any])
        XCTAssertEqual(manifest["content_hash"] as? [Int], Array(repeating: 0xab, count: 32))
        XCTAssertEqual(manifest["chunk_merkle_root"] as? [Int], Array(repeating: 0xab, count: 32))
    }
}
