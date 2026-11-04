import XCTest
@testable import Willow

/// What `data.get` and `data.query` verify, and what the SDK no longer
/// presents as verified: proofs confined to the path asked for, a query
/// answered from a proof of the whole data tree, roots compared with the
/// header after the proof's block, and the reads that can't be verified.
final class VerifiedReadsTests: XCTestCase {

    // MARK: - Fixtures

    typealias Envelope = GroveDBProofTests.Envelope
    typealias SingleKey = GroveDBProofTests.SingleKey

    static func realProofs() throws -> [String: Envelope] {
        return try GroveDBProofTests.fixture("envelope-real-proofs", as: [String: Envelope].self)
    }

    static func hex(_ string: String) throws -> Data {
        return try GroveDBProofTests.hex(string)
    }

    static func path(_ segments: [String]) -> [[UInt8]] {
        return GroveDBProofTests.path(segments)
    }

    /// A light client pinned at `height` with `appHash`, reading RPC through
    /// the stub server.
    static func pinnedLightClient(height: Int64, appHash: String, stub: StubServer, wait: TimeInterval = 0.4) throws -> LightClient {
        let config = LightClientConfig(
            chainId: "willow-chain", validatorEndpoints: ["http://rpc.test"], autoSync: false, headerWaitTimeout: wait)
        let state = TrustedState(
            header: TrustedHeader(height: height, appHash: appHash, trustedAt: Date()),
            validatorSet: ValidatorSet(validators: []))
        let lc = try LightClient(config, trustedState: state)
        lc.session = stub.session
        return lc
    }

    // MARK: - The verifier is confined to the path

    /// grovedb's encoding of a proof that is a single `Hash` node: version 0,
    /// a 33-byte Merk proof (`Push(Hash(root))`), no lower layers, default
    /// prove options.
    static func loneHashProof(_ rootHex: String) throws -> Data {
        return try hex("0021" + "01" + rootHex + "00" + "01")
    }

    @available(*, deprecated)
    func testALoneHashProofProvesNothing() throws {
        let f = try XCTUnwrap(Self.realProofs()["single-key"])
        let lone = try Self.loneHashProof(f.root)

        for path in [Self.path(f.path), DataOperations.dataPath("aave-v3-lending"), [Array("subgroves".utf8)]] {
            XCTAssertThrowsError(try GroveDBVerifier.verifyProofAgainstRoot(proofBytes: lone, expectedRootHash: f.root, expectedPath: path)) { error in
                XCTAssertTrue("\(error)".contains("does not descend"), "\(error)")
            }
        }
        XCTAssertThrowsError(try DataOperations.answer(QueryRequest(), proof: lone, path: DataOperations.dataPath("aave-v3-lending")))
        // Without a path it hashes to the real root and proves no value:
        // why the path-less entry points are deprecated.
        let pathless = try GroveDBVerifier.verifyProofAgainstRoot(proofBytes: lone, expectedRootHash: f.root.uppercased())
        XCTAssertTrue(pathless.results.isEmpty)
    }

    @available(*, deprecated)
    func testATwoSubgroveProofAskedForOnePathReturnsOnlyThatPath() throws {
        let a = ProofBuilder.layer(items: [("k1", ProofBuilder.item("v1")), ("k2", ProofBuilder.item("v2"))])
        let b = ProofBuilder.layer(items: [("k9", ProofBuilder.item("v9"))])
        let root = ProofBuilder.layer(trees: [("subgroves", ProofBuilder.layer(trees: [("a", a), ("b", b)]))])
        let proof = root.proof

        let result = try GroveDBVerifier.verifyProofAgainstRoot(
            proofBytes: proof, expectedRootHash: root.hash.hexString, expectedPath: Self.path(["subgroves", "a"]))
        XCTAssertEqual(result.results.map { String(decoding: $0.key, as: UTF8.self) }, ["k1", "k2"])
        XCTAssertTrue(result.results.allSatisfy { $0.path == Self.path(["subgroves", "a"]) })
        XCTAssertTrue(result.coversWholeTree)
        XCTAssertEqual(DataOperations.groveItemBytes(result.results[0].value), Data("v1".utf8))

        // b's layer is off the path asked for, so the proof isn't one of a alone.
        let otherSide = try GroveDBVerifier.verifyProof(proofBytes: proof, expectedPath: Self.path(["subgroves", "b"]))
        XCTAssertEqual(otherSide.results.map { String(decoding: $0.key, as: UTF8.self) }, ["k9"])

        // The path-less walk returns both subgroves' values, each at its path.
        let pathless = try GroveDBVerifier.verifyProof(proofBytes: proof)
        XCTAssertEqual(Set(pathless.results.map { $0.path }), [Self.path(["subgroves", "a"]), Self.path(["subgroves", "b"])])
    }

    func testALowerLayerOffThePathMustStillHashToItsElement() throws {
        let a = ProofBuilder.layer(items: [("k", ProofBuilder.item("v"))])
        let b = ProofBuilder.layer(items: [("k", ProofBuilder.item("w"))])
        let subgroves = ProofBuilder.layer(trees: [("a", a), ("b", b)])
        // The same `subgroves` layer, with b's lower layer swapped for one
        // its element doesn't commit to.
        let swapped = ProofBuilder.Built(
            merk: subgroves.merk, hash: subgroves.hash, rootKey: subgroves.rootKey,
            lower: [(Array("a".utf8), a), (Array("b".utf8), ProofBuilder.layer(items: [("k", ProofBuilder.item("x"))]))])
        let path = Self.path(["subgroves", "a"])

        let honest = ProofBuilder.layer(trees: [("subgroves", subgroves)])
        XCTAssertEqual(try GroveDBVerifier.verifyProofAgainstRoot(proofBytes: honest.proof, expectedRootHash: honest.hash.hexString, expectedPath: path).results.count, 1)
        let tampered = ProofBuilder.layer(trees: [("subgroves", swapped)])
        XCTAssertEqual(tampered.hash, honest.hash)
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: tampered.proof, expectedPath: path)) { error in
            XCTAssertTrue("\(error)".contains("Lower layer hash mismatch at key"), "\(error)")
        }
    }

    @available(*, deprecated)
    func testAFakeLowerLayersChainIsRefused() throws {
        let f = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: SingleKey.self)
        let real = try Self.hex(f.proof_hex)
        let decoded = try GroveDBVerifier.decodeGroveDBProof(real)
        let root = try XCTUnwrap(decoded.proof?.rootLayer)

        // A lower layer for a key the root layer doesn't prove.
        root.lowerLayers[Data("zzz".utf8).hexString] = LayerProof(merkProof: Data([0x03, 1, 0x61, 0, 2, 0, 0]))
        let stray = ProofBuilder.encode(decoded)
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: stray, expectedPath: DataOperations.dataPath("my-sub")))
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: stray)) { error in
            XCTAssertTrue("\(error)".contains("prove as an element"), "\(error)")
        }

        // The real chain of layers under a root layer that is only the
        // root's `Hash` node: no layer proves the path's keys.
        let realChain = try XCTUnwrap(GroveDBVerifier.decodeGroveDBProof(real).proof?.rootLayer?.lowerLayers)
        let rootHash = [UInt8](try Self.hex(f.expected_root_hex))
        let fake = GroveDBProof(version: 0, proof: GroveDBProofV0(
            rootLayer: LayerProof(merkProof: Data([UInt8(0x01)] + rootHash), lowerLayers: realChain),
            proveOptions: ProveOptions(decreaseLimitOnEmptySubQueryResult: true)))
        let fakeBytes = ProofBuilder.encode(fake)
        XCTAssertThrowsError(try GroveDBVerifier.verifyProofAgainstRoot(
            proofBytes: fakeBytes, expectedRootHash: f.expected_root_hex, expectedPath: DataOperations.dataPath("my-sub"))) { error in
            XCTAssertTrue("\(error)".contains("not proven as an element"), "\(error)")
        }
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: fakeBytes))
    }

    func testCoversWholeTreeOnlyWhenTheLayerHidesNothing() throws {
        let fixtures = try Self.realProofs()
        for (name, whole) in [("range-all", true), ("range-limit-2", false), ("single-key", false), ("absent-key", false)] {
            let f = try XCTUnwrap(fixtures[name])
            let result = try GroveDBVerifier.verifyProofAgainstRoot(proofBytes: Self.hex(f.proof), expectedRootHash: f.root, expectedPath: Self.path(f.path))
            XCTAssertEqual(result.coversWholeTree, whole, name)
        }
        let range = try GroveDBProofTests.fixture("range_full_apps_data", as: GroveDBProofTests.RangeFull.self)
        XCTAssertTrue(try GroveDBVerifier.verifyProof(proofBytes: Self.hex(range.proof_hex), expectedPath: Self.path(range.path)).coversWholeTree)
        let bob = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: SingleKey.self)
        XCTAssertFalse(try GroveDBVerifier.verifyProof(proofBytes: Self.hex(bob.proof_hex), expectedPath: Self.path(bob.path)).coversWholeTree)
    }

    func testAnEmptyTreeAtThePathIsProvenEmpty() throws {
        let root = ProofBuilder.layer(trees: [("subgroves", ProofBuilder.layer(trees: [
            ("notes", ProofBuilder.layer(trees: [("data", .empty)])),
        ]))])
        let result = try GroveDBVerifier.verifyProof(proofBytes: root.proof, expectedPath: DataOperations.dataPath("notes"))
        XCTAssertEqual(result.rootHash, root.hash.hexString)
        XCTAssertTrue(result.results.isEmpty)
        XCTAssertTrue(result.coversWholeTree)

        // An element that says "empty" while its value hash commits to a subtree.
        let forged = ProofBuilder.layer(trees: [("subgroves", ProofBuilder.layer(trees: [
            ("notes", ProofBuilder.layer(nodes: [ProofBuilder.Node(
                key: Array("data".utf8), element: ProofBuilder.tree(rootKey: nil), subtreeRoot: CryptoHash(bytes: [UInt8](repeating: 7, count: 32)))])),
        ]))])
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: forged.proof, expectedPath: DataOperations.dataPath("notes"))) { error in
            XCTAssertTrue("\(error)".contains("not proven empty"), "\(error)")
        }
    }

    // MARK: - A query is answered from the proven data tree

    static let rangeAllKeys = [
        "0x00000000000000000000000000000000000000000000000000000000000a11ce-0",
        "0x000000000000000000000000000000000000000000000000000000000014239c-1",
        "0x00000000000000000000000000000000000000000000000000000000001e356a-2",
        "0x0000000000000000000000000000000000000000000000000000000000284738-3",
        "0x0000000000000000000000000000000000000000000000000000000000325906-4",
    ]

    func testARealWholeTreeProofAnswersTheQuery() throws {
        let f = try XCTUnwrap(Self.realProofs()["range-all"])
        let proof = try Self.hex(f.proof)
        let path = Self.path(f.path)

        let all = try DataOperations.answer(QueryRequest(), proof: proof, path: path)
        XCTAssertEqual(all.rootHash, f.root)
        XCTAssertEqual(all.total, 5)
        XCTAssertEqual(all.results.map { $0.key }, Self.rangeAllKeys)
        XCTAssertEqual(all.results.map { $0.data["blockNumber"]?.value as? Int }, [23000000, 23000001, 23000002, 23000003, 23000004])
        XCTAssertEqual(all.results.map { $0.data["id"]?.value as? String }, Self.rangeAllKeys)

        let byUser = try DataOperations.answer(
            QueryBuilder().equals("user", "0x000000000000000000000000000000000000bef1").build(), proof: proof, path: path)
        XCTAssertEqual(byUser.results.map { $0.key }, [Self.rangeAllKeys[2]])
        XCTAssertEqual(byUser.total, 1)

        let byNumber = try DataOperations.answer(QueryBuilder().equals("blockNumber", 23000003).build(), proof: proof, path: path)
        XCTAssertEqual(byNumber.results.map { $0.key }, [Self.rangeAllKeys[3]])
        XCTAssertEqual(try DataOperations.answer(QueryBuilder().equals("blockNumber", "23000003").build(), proof: proof, path: path).total, 0)
        XCTAssertEqual(try DataOperations.answer(QueryBuilder().equals("missing", 1).build(), proof: proof, path: path).total, 0)

        let page = try DataOperations.answer(QueryBuilder().sortDesc("blockNumber").offset(1).limit(2).build(), proof: proof, path: path)
        XCTAssertEqual(page.results.map { $0.key }, [Self.rangeAllKeys[3], Self.rangeAllKeys[2]])
        XCTAssertEqual(page.total, 5)
        let byAmount = try DataOperations.answer(QueryBuilder().sortDesc("amount").limit(1).build(), proof: proof, path: path)
        XCTAssertEqual(byAmount.results.map { $0.key }, [Self.rangeAllKeys[4]])
        XCTAssertEqual(try DataOperations.answer(QueryRequest(limit: 0), proof: proof, path: path).results.count, 0)

        // The same proof asked for another path.
        XCTAssertThrowsError(try DataOperations.answer(QueryRequest(), proof: proof, path: DataOperations.dataPath("aave-v3-lending")))
    }

    func testAProofThatHidesPartOfTheTreeCantAnswerAQuery() throws {
        let fixtures = try Self.realProofs()
        for name in ["range-limit-2", "single-key", "absent-key"] {
            let f = try XCTUnwrap(fixtures[name])
            XCTAssertThrowsError(try DataOperations.answer(QueryRequest(), proof: Self.hex(f.proof), path: Self.path(f.path)), name) { error in
                XCTAssertEqual((error as? WillowError)?.type, .proof, name)
            }
        }
        let bob = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: SingleKey.self)
        XCTAssertThrowsError(try DataOperations.answer(QueryRequest(), proof: Self.hex(bob.proof_hex), path: DataOperations.dataPath("my-sub")))
    }

    func testADataTreeHoldingSomethingButItemsIsRefused() throws {
        let data = ProofBuilder.layer(items: [("a", ProofBuilder.item(#"{"n":1}"#))], trees: [("b", .empty)])
        let root = ProofBuilder.layer(trees: [("subgroves", ProofBuilder.layer(trees: [("sg", ProofBuilder.layer(trees: [("data", data)]))]))])
        XCTAssertThrowsError(try DataOperations.answer(QueryRequest(), proof: root.proof, path: DataOperations.dataPath("sg"))) { error in
            XCTAssertTrue("\(error)".contains("an item, at key"), "\(error)")
        }
    }

    func testItemsThatArentJSONAreSkippedAndNonObjectsRefused() throws {
        let data = ProofBuilder.layer(items: [
            ("a", ProofBuilder.item(#"{"n":1}"#)), ("b", ProofBuilder.item("not json")), ("c", ProofBuilder.item("[1,2]")),
        ])
        let root = ProofBuilder.layer(trees: [("subgroves", ProofBuilder.layer(trees: [("sg", ProofBuilder.layer(trees: [("data", data)]))]))])
        let path = DataOperations.dataPath("sg")
        // The node skips "b" and serves "c", which isn't an object.
        XCTAssertThrowsError(try DataOperations.answer(QueryRequest(), proof: root.proof, path: path))
        let filtered = try DataOperations.answer(QueryBuilder().equals("n", 1).build(), proof: root.proof, path: path)
        XCTAssertEqual(filtered.results.map { $0.key }, ["a"])
        XCTAssertEqual(try DataOperations.answer(QueryRequest(limit: 1), proof: root.proof, path: path).total, 2)
    }

    func testJSONEqualityAndSortOrderFollowTheNode() {
        XCTAssertTrue(DataOperations.jsonEqual(1, 1.0))
        XCTAssertFalse(DataOperations.jsonEqual(true, 1))
        XCTAssertFalse(DataOperations.jsonEqual(NSNumber(value: true), 1))
        XCTAssertTrue(DataOperations.jsonEqual(NSNumber(value: true), true))
        XCTAssertTrue(DataOperations.jsonEqual(NSNull(), NSNull()))
        XCTAssertTrue(DataOperations.jsonEqual([1, "a"] as [Any], [1, "a"] as [Any]))
        XCTAssertTrue(DataOperations.jsonEqual(["a": [1]] as [String: Any], ["a": [1]] as [String: Any]))
        XCTAssertFalse(DataOperations.jsonEqual(["a": 1] as [String: Any], ["a": 1, "b": 2] as [String: Any]))
        // Strings compare by their bytes: a precomposed é isn't e + U+0301.
        XCTAssertFalse(DataOperations.jsonEqual("\u{e9}", "e\u{301}"))

        XCTAssertEqual(DataOperations.fieldValue(["a": ["b": 2]] as [String: Any], "a.b") as? Int, 2)
        XCTAssertNil(DataOperations.fieldValue(["a": [1, 2]] as [String: Any], "a.0"))

        XCTAssertEqual(DataOperations.compareForSort(2, 10), -1)
        XCTAssertEqual(DataOperations.compareForSort("b", "a"), 1)
        XCTAssertEqual(DataOperations.compareForSort("Z", "a"), -1)
        XCTAssertEqual(DataOperations.compareForSort("\u{e9}", "f"), 1, "by UTF-8 bytes, not by Unicode collation")
        XCTAssertEqual(DataOperations.compareForSort(1, "a"), 0)
        XCTAssertEqual(DataOperations.compareForSort(nil, 1), 0)
        XCTAssertEqual(DataOperations.compareForSort(true, false), 0)
    }

    // MARK: - Requests the node can and can't run

    func testAQueryIsSentInTheNodesForm() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let request = QueryBuilder().equals("createdAt", "x").sortDesc("updatedAt").limit(5).offset(2).build()
        XCTAssertEqual(
            String(decoding: try encoder.encode(request), as: UTF8.self),
            #"{"filters":{"createdAt":"x"},"include_proof":false,"limit":5,"offset":2,"sort":{"field":"updatedAt","order":"desc"}}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(QueryRequest()), as: UTF8.self), #"{"include_proof":false}"#)

        let decoded = try JSONDecoder().decode(QueryRequest.self, from: encoder.encode(request))
        XCTAssertEqual(decoded.filters.map { $0.field }, ["createdAt"])
        XCTAssertEqual(decoded.sort?.ascending, false)
        XCTAssertEqual(decoded.limit, 5)
    }

    @available(*, deprecated)
    func testAQueryTheNodeCantRunIsRefusedBeforeSending() async throws {
        let stub = StubServer { _ in (500, "") }
        let client = try stub.client(baseURL: "http://api.test")
        client.setLightClient(try Self.pinnedLightClient(height: 2, appHash: "00", stub: stub))

        let refused: [QueryRequest] = [
            QueryBuilder().equals("a", 1).equals("b", 2).build(),
            QueryBuilder().greaterThan("a", 1).build(),
            QueryBuilder().search(fields: ["a"], query: "x").build(),
            QueryBuilder().equals("a", ["nested": 1]).build(),
            QueryRequest(limit: -1),
        ]
        for request in refused {
            for verified in [true, false] {
                do {
                    if verified {
                        _ = try await client.data.query(subgroveId: "sg", query: request)
                    } else {
                        _ = try await client.data.queryUnverified(subgroveId: "sg", query: request)
                    }
                    XCTFail("refused: \(request)")
                } catch let error as WillowError {
                    XCTAssertEqual(error.type, .validation)
                }
            }
            XCTAssertThrowsError(try JSONEncoder().encode(request))
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: - Verified reads through the client

    /// A whole-tree proof of `subgroves/notes/data`, as the node serves it
    /// for a query.
    static func notesTree() -> ProofBuilder.Built {
        let data = ProofBuilder.layer(items: [
            ("n1", ProofBuilder.item(#"{"title":"b","rank":2,"tag":"x"}"#)),
            ("n2", ProofBuilder.item(#"{"title":"a","rank":3,"tag":"y"}"#)),
            ("n3", ProofBuilder.item(#"{"title":"c","rank":1,"tag":"x"}"#)),
        ])
        let notes = ProofBuilder.layer(items: [("meta", ProofBuilder.item("{}"))], trees: [("data", data)])
        return ProofBuilder.layer(trees: [("subgroves", ProofBuilder.layer(items: [("aaa", ProofBuilder.item("0"))], trees: [("notes", notes)]))])
    }

    func testAVerifiedQueryReturnsTheProvenAnswerAndChecksTheNextHeader() async throws {
        let tree = Self.notesTree()
        var served = 0
        let stub = StubServer { request in
            guard request.url.host == "api.test", request.path == "/query/notes" else { return (404, "") }
            served += 1
            // The documents served are not the proven ones; the SDK doesn't use them.
            return (200, #"{"success":true,"data":{"documents":[{"title":"forged"}],"total":1,"offset":0,"limit":100,"proof":"\#(tree.proof.hexString)","height":41}}"#)
        }
        let client = try stub.client(baseURL: "http://api.test")
        // The header after block 41 carries the state the proof is from; its
        // app hash is served in upper case.
        client.setLightClient(try Self.pinnedLightClient(height: 42, appHash: tree.hash.hexString.uppercased(), stub: stub))

        let response = try await client.data.query(subgroveId: "notes", query: QueryBuilder().equals("tag", "x").sortAsc("rank").build())
        XCTAssertEqual(response.results.map { $0.key }, ["n3", "n1"])
        XCTAssertEqual(response.results.map { $0.data["title"]?.value as? String }, ["c", "b"])
        XCTAssertEqual(response.totalCount, 2)
        XCTAssertFalse(response.hasMore)
        XCTAssertEqual(response.height, 41)
        XCTAssertEqual(response.proof, tree.proof)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: stub.requests[0].body) as? [String: Any])
        XCTAssertEqual(body["include_proof"] as? Bool, true)
        XCTAssertEqual(body["filters"] as? [String: String], ["tag": "x"])
        XCTAssertEqual(body["sort"] as? [String: String], ["field": "rank", "order": "asc"])
        XCTAssertEqual(served, 1)
    }

    func testAVerifiedQueryRefusesTheProofsOwnHeightsHeader() async throws {
        let tree = Self.notesTree()
        let stub = StubServer { request in
            if request.url.host == "rpc.test" {
                // Not an answer the light client accepts.
                return (200, #"{"jsonrpc":"2.0","id":-1,"result":{}}"#)
            }
            return (200, #"{"success":true,"data":{"documents":[],"total":0,"offset":0,"limit":100,"proof":"\#(tree.proof.hexString)","height":41}}"#)
        }
        let client = try stub.client(baseURL: "http://api.test")
        // Pinned at the proof's own height: its app hash is the state before
        // block 41, so the SDK asks for header 42 instead.
        client.setLightClient(try Self.pinnedLightClient(height: 41, appHash: tree.hash.hexString, stub: stub))

        do {
            _ = try await client.data.query(subgroveId: "notes", query: QueryRequest())
            XCTFail("the header at the proof's own height must not be used")
        } catch {}
        XCTAssertEqual(stub.requests.filter { $0.url.host == "rpc.test" }.first?.target, "/commit?height=42")
    }

    func testAVerifiedQueryWithoutAHeightOrProofThrows() async throws {
        let tree = Self.notesTree()
        for data in [
            #"{"documents":[],"total":0,"offset":0,"limit":100,"proof":"\#(tree.proof.hexString)"}"#,
            #"{"documents":[],"total":0,"offset":0,"limit":100,"height":3}"#,
        ] {
            let stub = StubServer { _ in (200, #"{"success":true,"data":\#(data)}"#) }
            let client = try stub.client(baseURL: "http://api.test")
            client.setLightClient(try Self.pinnedLightClient(height: 4, appHash: tree.hash.hexString, stub: stub))
            do {
                _ = try await client.data.query(subgroveId: "notes", query: QueryRequest())
                XCTFail("must not pass as verified")
            } catch let error as WillowError {
                XCTAssertEqual(error.type, .proof)
            }
        }
    }

    func testAVerifiedGetChecksTheHeaderAfterTheProofsBlock() async throws {
        let f = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: SingleKey.self)
        let stub = StubServer { request in
            switch request.path {
            case "/data/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"balance":250}}"#)
            case "/proof/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"proof":"\#(f.proof_hex)","height":41}}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setLightClient(try Self.pinnedLightClient(height: 42, appHash: f.expected_root_hex.uppercased(), stub: stub))

        let response = try await client.data.get(subgroveId: "my-sub", key: "user:bob")
        XCTAssertEqual(response.data["balance"]?.value as? Int, 250)
        XCTAssertEqual(response.proof?.height, 41)
        XCTAssertEqual(response.proof?.rootHash, f.expected_root_hex)
        XCTAssertTrue(stub.requests.allSatisfy { $0.url.host == "api.test" })
    }

    func testAVerifiedGetRefusesAHeaderBelowTheTrustedOne() async throws {
        let f = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: SingleKey.self)
        let stub = StubServer { request in
            switch request.path {
            case "/data/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"balance":250}}"#)
            case "/proof/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"proof":"\#(f.proof_hex)","height":41}}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setLightClient(try Self.pinnedLightClient(height: 50, appHash: f.expected_root_hex, stub: stub))

        do {
            _ = try await client.data.get(subgroveId: "my-sub", key: "user:bob")
            XCTFail("a proof older than the trusted header can't be checked")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .lightClient)
            XCTAssertTrue(error.message.contains("below the trusted header"), error.message)
        }
        XCTAssertFalse(stub.requests.contains { $0.url.host == "rpc.test" })
    }

    func testAVerifiedGetWaitsForTheNextHeaderThenGivesUp() async throws {
        let f = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: SingleKey.self)
        let stub = StubServer { request in
            if request.url.host == "rpc.test" {
                return (500, #"{"jsonrpc":"2.0","id":-1,"error":{"code":-32603,"message":"Internal error","data":"height 42 must be less than or equal to the current blockchain height 41"}}"#)
            }
            switch request.path {
            case "/data/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"balance":250}}"#)
            case "/proof/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"proof":"\#(f.proof_hex)","height":41}}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setLightClient(try Self.pinnedLightClient(height: 41, appHash: f.expected_root_hex, stub: stub, wait: 0.6))

        do {
            _ = try await client.data.get(subgroveId: "my-sub", key: "user:bob")
            XCTFail("no header after the proof's block, no verified value")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .lightClient)
            XCTAssertTrue(error.message.contains("did not appear"), error.message)
        }
        let polls = stub.requests.filter { $0.target == "/commit?height=42" }
        XCTAssertGreaterThan(polls.count, 1, "it waits for the header")
    }

    func testAVerifiedGetRefusesAProofWithoutAHeight() async throws {
        let f = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: SingleKey.self)
        let stub = StubServer { request in
            switch request.path {
            case "/data/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"balance":250}}"#)
            case "/proof/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"proof":"\#(f.proof_hex)"}}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setLightClient(try Self.pinnedLightClient(height: 42, appHash: f.expected_root_hex, stub: stub))
        do {
            _ = try await client.data.get(subgroveId: "my-sub", key: "user:bob")
            XCTFail("a proof without its height can't be matched to a header")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .proof)
        }
    }

    // MARK: - Reads the SDK can't verify

    @available(*, deprecated)
    func testAHistoricalQueryIsNotPresentedAsVerified() async throws {
        let stub = StubServer { _ in (200, "{}") }
        let client = try stub.client(baseURL: "http://api.test")
        do {
            _ = try await client.data.queryHistoricalVerified(
                subgroveId: "sg", checkpointId: "cp", request: HistoricalQueryRequest(path: [Array("a".utf8)]))
            XCTFail("a historical answer can't be verified")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testAGraphQLAnswerIsReturnedUnverifiedInTheNodesShape() async throws {
        let stub = StubServer { request in
            guard request.path == "/graphql/sg" else { return (404, "") }
            return (200, #"""
            {"data":{"deposits":[{"id":"d1","amount":"5"}]},"errors":null,
             "proof":{"merkle_proofs":[{"key":"d1","value_hash":[1,2],"siblings":[],"path":"indexed/Deposit"}],
                      "state_root":[9,9],"block_height":7,"ethereum_anchor":null}}
            """#)
        }
        let client = try stub.client(baseURL: "http://api.test")
        // A light client that would refuse anything: the answer isn't checked.
        client.setLightClient(try Self.pinnedLightClient(height: 1, appHash: "00", stub: stub))

        let request = GraphQLQueryBuilder(query: "query Q($ownerId: String) { deposits { id } }")
            .variable("ownerId", value: "x")
            .build()
        let response = try await client.indexing.query(subgroveId: "sg", request: request)

        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response.data)) as? [String: Any])
        XCTAssertEqual(((data["deposits"] as? [[String: Any]])?.first?["id"]) as? String, "d1")
        let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response.proof)) as? [String: Any])
        XCTAssertEqual(proof["block_height"] as? Int, 7)

        XCTAssertEqual(stub.requests.map { $0.target }, ["/graphql/sg"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: stub.requests[0].body) as? [String: Any])
        XCTAssertEqual(body["include_proof"] as? Bool, false, "a light client no longer turns proofs on")
        XCTAssertEqual(body["variables"] as? [String: String], ["ownerId": "x"], "variable names go out as written")

        struct Deposits: Decodable { struct Deposit: Decodable { let id: String }; let deposits: [Deposit] }
        let typed = try await client.indexing.executeWithResult(subgroveId: "sg", query: "{ deposits { id } }", resultType: Deposits.self)
        XCTAssertEqual(typed.deposits.map { $0.id }, ["d1"])
    }
}

// MARK: - Proof builder

/// Builds GroveDB proofs that hash as grovedb's do (Merk's rules, grovedb's
/// encoding), for shapes no fixture covers. Each layer shows every node of a
/// balanced tree; each tree element carries its lower layer.
enum ProofBuilder {
    /// grovedb's bincode varint: one byte up to 250, else 251 and a
    /// big-endian u16.
    static func varint(_ n: Int) -> [UInt8] {
        precondition(n <= 0xFFFF)
        if n <= 250 {
            return [UInt8(n)]
        }
        let high = UInt8(n >> 8)
        let low = UInt8(n & 0xFF)
        return [251, high, low]
    }

    /// `Element::Item(bytes, None)`.
    static func item(_ text: String) -> [UInt8] {
        let bytes: [UInt8] = Array(text.utf8)
        var out: [UInt8] = [0x00]
        out += varint(bytes.count)
        out += bytes
        out.append(0x00)
        return out
    }

    /// `Element::Tree(root_key, None)`.
    static func tree(rootKey: [UInt8]?) -> [UInt8] {
        guard let key = rootKey else { return [0x02, 0x00, 0x00] }
        var out: [UInt8] = [0x02, 0x01]
        out += varint(key.count)
        out += key
        out.append(0x00)
        return out
    }

    struct Node {
        let key: [UInt8]
        let element: [UInt8]
        /// A tree element's subtree root (the null hash when empty); nil for
        /// an item, pushed as a KV node.
        let subtreeRoot: CryptoHash?

        var valueHash: CryptoHash {
            let own = Willow.valueHash(Data(element))
            return subtreeRoot.map { combineHash(own, $0) } ?? own
        }
    }

    /// A layer: its Merk proof, root hash, root key, and lower layers.
    struct Built {
        let merk: [UInt8]
        let hash: CryptoHash
        let rootKey: [UInt8]?
        let lower: [([UInt8], Built)]

        static let empty = Built(merk: [], hash: nullHash, rootKey: nil, lower: [])

        /// The whole proof with this layer at its root.
        var proof: Data {
            var out: [UInt8] = [0x00]
            out += ProofBuilder.encodeLayer(self)
            out.append(0x01)
            return Data(out)
        }
    }

    static func layer(items: [(String, [UInt8])] = [], trees: [(String, Built)] = []) -> Built {
        var nodes = items.map { Node(key: Array($0.0.utf8), element: $0.1, subtreeRoot: nil) }
        nodes += trees.map { Node(key: Array($0.0.utf8), element: tree(rootKey: $0.1.rootKey), subtreeRoot: $0.1.hash) }
        let lower = trees.filter { $0.1.rootKey != nil }.map { (Array($0.0.utf8), $0.1) }
        return layer(nodes: nodes, lower: lower)
    }

    static func layer(nodes: [Node], lower: [([UInt8], Built)] = []) -> Built {
        func build(_ slice: ArraySlice<Node>) -> (ops: [UInt8], hash: CryptoHash, key: [UInt8])? {
            guard !slice.isEmpty else { return nil }
            let mid = slice.startIndex + slice.count / 2
            let node = slice[mid]
            let left = build(slice[slice.startIndex..<mid])
            let right = build(slice[(mid + 1)..<slice.endIndex])
            var ops: [UInt8] = left?.ops ?? []
            // KV for an item; KVValueHash, with its value hash, for a tree.
            ops.append(node.subtreeRoot == nil ? 0x03 : 0x04)
            ops.append(UInt8(node.key.count))
            ops += node.key
            ops.append(UInt8(node.element.count >> 8))
            ops.append(UInt8(node.element.count & 0xFF))
            ops += node.element
            if node.subtreeRoot != nil {
                ops += node.valueHash.bytes
            }
            if left != nil { ops.append(0x10) }
            if let right = right {
                ops += right.ops
                ops.append(0x11)
            }
            let kv = kvDigestToKvHash(key: Data(node.key), valueHash: node.valueHash)
            return (ops, computeNodeHash(kvHash: kv, leftHash: left?.hash ?? nullHash, rightHash: right?.hash ?? nullHash), node.key)
        }
        guard let built = build(nodes.sorted { $0.key.lexicographicallyPrecedes($1.key) }[...]) else {
            return .empty
        }
        return Built(merk: built.ops, hash: built.hash, rootKey: built.key, lower: lower)
    }

    static func encodeLayer(_ built: Built) -> [UInt8] {
        var out: [UInt8] = varint(built.merk.count)
        out += built.merk
        out += varint(built.lower.count)
        for (key, layer) in built.lower {
            out += varint(key.count)
            out += key
            out += encodeLayer(layer)
        }
        return out
    }

    /// Re-encodes a decoded proof, lower layers in key order.
    static func encode(_ proof: GroveDBProof) -> Data {
        func layer(_ l: LayerProof) -> [UInt8] {
            var out: [UInt8] = varint(l.merkProof.count)
            out += [UInt8](l.merkProof)
            out += varint(l.lowerLayers.count)
            for keyHex in l.lowerLayers.keys.sorted() {
                let key: [UInt8] = [UInt8](Data(hexString: keyHex)!)
                out += varint(key.count)
                out += key
                out += layer(l.lowerLayers[keyHex]!)
            }
            return out
        }
        let v0 = proof.proof!
        var out: [UInt8] = [0x00]
        out += layer(v0.rootLayer!)
        out.append(v0.proveOptions.decreaseLimitOnEmptySubQueryResult ? 1 : 0)
        return Data(out)
    }
}
