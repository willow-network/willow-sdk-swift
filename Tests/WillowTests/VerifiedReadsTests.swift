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

    /// A KV node for an item, a KVDigest node hiding it, and a KVValueHash
    /// node carrying bytes that read as a tree with the item's value hash all
    /// hash alike: a value-hash node's hash covers the value hash, not the
    /// bytes it carries.
    func testATreeShapedValueWithoutItsLowerLayerIsNotBound() throws {
        let key: [UInt8] = Array("k".utf8)
        let item = ProofBuilder.item(#"{"n":1}"#)
        let fakeTree = ProofBuilder.tree(rootKey: Array("zz".utf8))
        let itemHash = Willow.valueHash(Data(item))
        func proof(_ ops: [UInt8]) -> ProofBuilder.Built {
            let kv = kvDigestToKvHash(key: Data(key), valueHash: itemHash)
            let data = ProofBuilder.Built(
                merk: ops, hash: computeNodeHash(kvHash: kv, leftHash: nullHash, rightHash: nullHash), rootKey: key, lower: [])
            return ProofBuilder.layer(trees: [("subgroves", ProofBuilder.layer(trees: [("sg", ProofBuilder.layer(trees: [("data", data)]))]))])
        }
        let honest = proof([0x03, UInt8(key.count)] + key + [0, UInt8(item.count)] + item)
        let hidden = proof([0x05, UInt8(key.count)] + key + itemHash.bytes)
        let spoofed = proof([0x04, UInt8(key.count)] + key + [0, UInt8(fakeTree.count)] + fakeTree + itemHash.bytes)
        XCTAssertEqual(spoofed.hash, honest.hash)
        XCTAssertEqual(hidden.hash, honest.hash)
        let path = DataOperations.dataPath("sg")

        let real = try GroveDBVerifier.verifyProof(proofBytes: honest.proof, expectedPath: path)
        XCTAssertTrue(real.coversWholeTree)
        XCTAssertEqual(real.results.map { $0.isValueBound }, [true])
        XCTAssertFalse(try GroveDBVerifier.verifyProof(proofBytes: hidden.proof, expectedPath: path).coversWholeTree)

        // Rewriting the hidden node as a tree element verifies to the same
        // root, but its bytes aren't bound and the tree isn't shown whole.
        let forged = try GroveDBVerifier.verifyProof(proofBytes: spoofed.proof, expectedPath: path)
        XCTAssertEqual(forged.rootHash, real.rootHash)
        XCTAssertFalse(forged.coversWholeTree)
        XCTAssertEqual(forged.results.map { $0.isValueBound }, [false])
        XCTAssertEqual(forged.results.first?.value, Data(fakeTree))
        let pathless = try GroveDBVerifier.verifyProof(proofBytes: spoofed.proof)
        XCTAssertEqual(pathless.results.map { $0.isValueBound }, [false])

        // Neither verified read takes it.
        XCTAssertThrowsError(try DataOperations.answer(QueryRequest(), proof: spoofed.proof, path: path))
        let served: [String: AnyCodable] = ["n": AnyCodable(1)]
        XCTAssertNoThrow(try DataOperations.requireProven(subgroveId: "sg", key: "k", value: served, in: real))
        XCTAssertThrowsError(try DataOperations.requireProven(subgroveId: "sg", key: "k", value: served, in: forged))
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

    // MARK: - JSON as the node reads it

    static func node(_ text: String) throws -> NodeJSON {
        return try NodeJSON.parse(Data(text.utf8))
    }

    func testNumbersCompareByTheTextTheNodeKeeps() throws {
        XCTAssertNotEqual(try Self.node("1"), try Self.node("1.0"))
        XCTAssertNotEqual(try Self.node("9007199254740993"), try Self.node("9007199254740992"))
        XCTAssertNotEqual(try Self.node("100"), try Self.node("1e2"))
        XCTAssertNotEqual(try Self.node("1e-5"), try Self.node("1e-05"))
        XCTAssertNotEqual(try Self.node("true"), try Self.node("1"))
        // An integer that fits u64 or i64 is its digits, so -0 is 0; an
        // exponent is written e with a sign.
        XCTAssertEqual(try Self.node("-0"), .number("0"))
        XCTAssertEqual(try Self.node("-0.0"), .number("-0.0"))
        XCTAssertEqual(try Self.node("1E5"), .number("1e+5"))
        XCTAssertEqual(try Self.node("1e5"), try Self.node("1E+5"))
        XCTAssertEqual(try Self.node("18446744073709551615"), .number("18446744073709551615"))
        XCTAssertEqual(try Self.node("18446744073709551616"), .number("18446744073709551616"))
        XCTAssertEqual(try Self.node("-9223372036854775809"), .number("-9223372036854775809"))
        XCTAssertEqual(try Self.node("1e400"), .number("1e+400"))

        // Strings by their bytes: a precomposed é isn't e + U+0301.
        XCTAssertNotEqual(try Self.node(#""é""#), try Self.node(#""é""#))
        XCTAssertEqual(try Self.node(#""é""#), .string([0xC3, 0xA9]))
        XCTAssertEqual(try Self.node(#""😀""#), .string(Array("\u{1F600}".utf8)))
        // Objects in any order; a repeated key keeps its last value.
        XCTAssertEqual(try Self.node(#"{"a":1,"b":[2]}"#), try Self.node(#"{"b":[2],"a":1}"#))
        XCTAssertEqual(try Self.node(#"{"a":1,"a":2}"#), try Self.node(#"{"a":2}"#))
        XCTAssertNotEqual(try Self.node(#"{"a":1}"#), try Self.node(#"{"a":1,"b":2}"#))
    }

    func testFieldPathsMatchKeysByTheirBytes() throws {
        let document = try Self.node(#"{"a":{"b":2},"l":[1,2],"é":3,"x.y":4}"#)
        XCTAssertEqual(document.value(atPath: Array("a.b".utf8)), .number("2"))
        XCTAssertNil(document.value(atPath: Array("l.0".utf8)), "an array has no members")
        XCTAssertEqual(document.value(atPath: Array("\u{e9}".utf8)), .number("3"))
        XCTAssertNil(document.value(atPath: Array("e\u{301}".utf8)), "a canonical equivalent is other bytes")
        XCTAssertNil(document.value(atPath: Array("x.y".utf8)), "a dot always splits the path")
    }

    func testTheNodesJSONReaderIsStrict() throws {
        for refused in [
            "", "nul", "01", "1.", "-", "1e", "[1,]", #"{"a":1,}"#, "[1] x", #"{"a" 1}"#, "'a'",
            #""\ud800""#, #""\udc00""#, #""\ud800A""#, #""\x""#, "\"a\u{1}\"", "\u{feff}{}",
        ] {
            XCTAssertThrowsError(try Self.node(refused), refused) { error in
                guard case NodeJSON.ReadError.notJSON = error else { return XCTFail("\(refused): \(error)") }
            }
        }
        // Bytes that aren't UTF-8 in a string: an overlong encoding and a lone continuation byte.
        for bytes: [UInt8] in [[0x22, 0xC0, 0x80, 0x22], [0x22, 0x80, 0x22], [0x22, 0xED, 0xA0, 0x80, 0x22]] {
            XCTAssertThrowsError(try NodeJSON.parse(bytes))
        }
        // serde_json reads at most 127 levels of nesting.
        XCTAssertNoThrow(try Self.node(String(repeating: "[", count: 127) + String(repeating: "]", count: 127)))
        XCTAssertThrowsError(try Self.node(String(repeating: "[", count: 128) + String(repeating: "]", count: 128)))
        XCTAssertNoThrow(try Self.node(" \t\r\n{\"a\" : [ true , false , null ] } \n"))

        // An object whose first key is one of serde_json's private tokens
        // isn't read as an object; the SDK doesn't guess how.
        XCTAssertThrowsError(try Self.node(#"{"$serde_json::private::Number":"1"}"#)) { error in
            guard case NodeJSON.ReadError.unsupported = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try Self.node(#"{"a":1,"$serde_json::private::Number":"1"}"#))
    }

    func testSortOrderFollowsTheNode() throws {
        typealias Key = DataOperations.SortKey
        func key(_ text: String?) throws -> Key {
            return Key(try text.map { try Self.node($0) })
        }
        XCTAssertEqual(Key.compare(try key("2"), try key("10")), -1)
        XCTAssertEqual(Key.compare(try key("2.0"), try key("2")), 0)
        XCTAssertEqual(Key.compare(try key(#""b""#), try key(#""a""#)), 1)
        XCTAssertEqual(Key.compare(try key(#""Z""#), try key(#""a""#)), -1)
        XCTAssertEqual(Key.compare(try key(#""é""#), try key(#""f""#)), 1, "by UTF-8 bytes, not by Unicode collation")
        XCTAssertEqual(Key.compare(try key("1"), try key(#""a""#)), 0)
        XCTAssertEqual(Key.compare(try key(nil), try key("1")), 0)
        XCTAssertEqual(Key.compare(try key("true"), try key("false")), 0)
        // A number outside f64's range has no value, and sorts first.
        XCTAssertEqual(Key.compare(try key("1e400"), try key("-5")), -1)
        XCTAssertEqual(Key.compare(try key("1e400"), try key("-1e400")), 0)

        // The comparator is one order only when the keys are all numbers,
        // all strings, or all equal.
        let consistent: [[String?]] = [
            ["1", "3", "2"], [#""a""#, #""c""#], [nil, nil, "true"], ["1", "1.0", #""a""#, nil], ["1", #""a""#], [],
        ]
        for keys in consistent {
            XCTAssertTrue(Key.orderIsConsistent(try keys.map(key)), "\(keys)")
        }
        let inconsistent: [[String?]] = [["1", "2", #""a""#], ["1", "2", nil], [#""a""#, #""b""#, "1"], [#""a""#, #""b""#, "null"]]
        for keys in inconsistent {
            XCTAssertFalse(Key.orderIsConsistent(try keys.map(key)), "\(keys)")
        }
    }

    /// A data tree of `items` at `subgroves/sg/data`.
    static func dataTree(_ items: [(String, String)]) -> ProofBuilder.Built {
        let data = ProofBuilder.layer(items: items.map { ($0.0, ProofBuilder.item($0.1)) })
        return ProofBuilder.layer(trees: [("subgroves", ProofBuilder.layer(trees: [("sg", ProofBuilder.layer(trees: [("data", data)]))]))])
    }

    func testAQueryFiltersByTheNumberTextTheNodeCompares() throws {
        let root = Self.dataTree([
            ("a", #"{"n":1}"#), ("b", #"{"n":1.0}"#), ("c", #"{"n":9007199254740993}"#),
            ("d", #"{"n":9007199254740992}"#), ("e", #"{"n":1E2}"#), ("f", #"{"n":-0}"#),
        ])
        let path = DataOperations.dataPath("sg")
        func keys(_ request: QueryRequest) throws -> [String] {
            return try DataOperations.answer(request, proof: root.proof, path: path).results.map { $0.key }
        }
        XCTAssertEqual(try keys(QueryBuilder().equals("n", 1).build()), ["a"])
        XCTAssertEqual(try keys(QueryBuilder().equals("n", 9007199254740993).build()), ["c"])
        XCTAssertEqual(try keys(QueryBuilder().equals("n", 9007199254740992).build()), ["d"])
        XCTAssertEqual(try keys(QueryBuilder().equals("n", 0).build()), ["f"])
        XCTAssertEqual(try keys(QueryBuilder().equals("n", 100).build()), [], "1E2 is kept as 1e+2, not 100")
        XCTAssertEqual(try keys(QueryBuilder().equals("n", NSNumber(value: 1)).build()), ["a"], "an NSNumber 1 is a number, not true")

        // A Double goes out as the encoder writes it, and is compared as that text.
        let request = QueryBuilder().equals("n", 1.0).build()
        let sent = try XCTUnwrap(String(data: WillowClient.verbatimBody(request), encoding: .utf8))
        XCTAssertEqual(try keys(request), sent.contains(#""n":1}"#) ? ["a"] : ["b"], sent)
        let one = try DataOperations.answer(QueryBuilder().equals("n", 1).build(), proof: root.proof, path: path)
        XCTAssertEqual(one.results.first?.data["n"]?.value as? Int, 1)
        XCTAssertEqual(one.total, 1)
    }

    func testAQueryFiltersOnFieldBytes() throws {
        let root = Self.dataTree([("a", #"{"é":1}"#), ("b", #"{"é":1}"#)])
        let path = DataOperations.dataPath("sg")
        let precomposed = try DataOperations.answer(QueryBuilder().equals("\u{e9}", 1).build(), proof: root.proof, path: path)
        XCTAssertEqual(precomposed.results.map { $0.key }, ["a"])
        let decomposed = try DataOperations.answer(QueryBuilder().equals("e\u{301}", 1).build(), proof: root.proof, path: path)
        XCTAssertEqual(decomposed.results.map { $0.key }, ["b"])
    }

    func testAQueryWithANumberOutsideDoublesRange() throws {
        let root = Self.dataTree([("a", #"{"n":1}"#), ("b", #"{"n":1e400}"#), ("c", #"{"n":2}"#)])
        let path = DataOperations.dataPath("sg")
        // The node reads the item (it keeps the number's text) and filters it out.
        let filtered = try DataOperations.answer(QueryBuilder().equals("n", 2).build(), proof: root.proof, path: path)
        XCTAssertEqual(filtered.results.map { $0.key }, ["c"])
        // It sorts first, as the node's f64 comparison has no value for it.
        let sorted = try DataOperations.answer(QueryBuilder().sortAsc("n").limit(2).offset(1).build(), proof: root.proof, path: path)
        XCTAssertEqual(sorted.results.map { $0.key }, ["a", "c"])
        XCTAssertEqual(sorted.total, 3)
        // Returned, it can't be a Double, so the query isn't verified.
        XCTAssertThrowsError(try DataOperations.answer(QueryRequest(), proof: root.proof, path: path)) { error in
            XCTAssertEqual((error as? WillowError)?.type, .proof)
            XCTAssertTrue((error as? WillowError)?.message.contains("can't be verified") ?? false, "\(error)")
        }
    }

    func testASortTheNodeDoesntOrderIsNotVerified() throws {
        let root = Self.dataTree([("a", #"{"r":2,"t":"x"}"#), ("b", #"{"r":"z","t":"y"}"#), ("c", #"{"r":1,"t":"x"}"#), ("d", #"{"t":"x"}"#)])
        let path = DataOperations.dataPath("sg")
        for request in [QueryBuilder().sortAsc("r").build(), QueryBuilder().equals("t", "x").sortDesc("r").build()] {
            XCTAssertThrowsError(try DataOperations.answer(request, proof: root.proof, path: path)) { error in
                XCTAssertEqual((error as? WillowError)?.type, .proof)
                XCTAssertTrue((error as? WillowError)?.message.contains("can't be verified") ?? false, "\(error)")
            }
        }
        // Over the items that match, the sort field is all numbers.
        let numbers = Self.dataTree([("a", #"{"r":2,"t":"x"}"#), ("b", #"{"r":"z","t":"y"}"#), ("c", #"{"r":1,"t":"x"}"#)])
        let answer = try DataOperations.answer(QueryBuilder().equals("t", "x").sortAsc("r").build(), proof: numbers.proof, path: path)
        XCTAssertEqual(answer.results.map { $0.key }, ["c", "a"])
        // A field no item has leaves key order.
        let missing = try DataOperations.answer(QueryBuilder().sortDesc("nope").build(), proof: root.proof, path: path)
        XCTAssertEqual(missing.results.map { $0.key }, ["a", "b", "c", "d"])
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
            // The documents served are not the proven ones, and one isn't
            // even an object; the SDK doesn't read them.
            return (200, #"{"success":true,"data":{"documents":[{"title":"forged","n":1e400},7],"total":1,"offset":0,"limit":100,"proof":"\#(tree.proof.hexString)","height":41}}"#)
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

    /// A stub API serving `bob`'s value and its proof, with `height`.
    static func bobServer(height: Int64, rpc: @escaping (ReceivedRequest) -> (Int, String) = { _ in (404, "") }) throws -> StubServer {
        let f = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: SingleKey.self)
        return StubServer { request in
            if request.url.host == "rpc.test" {
                return rpc(request)
            }
            switch request.path {
            case "/data/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"balance":250}}"#)
            case "/proof/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"proof":"\#(f.proof_hex)","height":\#(height)}}"#)
            default:
                return (404, "")
            }
        }
    }

    func testAVerifiedGetTakesALaterAcceptedHeaderCarryingTheRoot() async throws {
        let f = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: SingleKey.self)
        let stub = try Self.bobServer(height: 41)
        let client = try stub.client(baseURL: "http://api.test")
        // No block with transactions since block 41: the header at 50 still
        // carries the state after it.
        client.setLightClient(try Self.pinnedLightClient(height: 50, appHash: f.expected_root_hex, stub: stub))

        let response = try await client.data.get(subgroveId: "my-sub", key: "user:bob")
        XCTAssertEqual(response.data["balance"]?.value as? Int, 250)
        XCTAssertFalse(stub.requests.contains { $0.url.host == "rpc.test" })
    }

    func testAVerifiedGetRefusesAStateOlderThanEveryAcceptedHeader() async throws {
        let stub = try Self.bobServer(height: 41)
        let client = try stub.client(baseURL: "http://api.test")
        // The header at 50 carries another state, and the header at 42 is
        // below every header the light client has accepted.
        client.setLightClient(try Self.pinnedLightClient(height: 50, appHash: String(repeating: "ab", count: 32), stub: stub))

        do {
            _ = try await client.data.get(subgroveId: "my-sub", key: "user:bob")
            XCTFail("a proof older than the trusted header, of a state since changed, can't be checked")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .lightClient)
            XCTAssertTrue(error.message.contains("below every header"), error.message)
        }
        XCTAssertFalse(stub.requests.contains { $0.url.host == "rpc.test" })
    }

    func testAVerifiedGetFetchesAndAcceptsTheNextHeader() async throws {
        let f = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: SingleKey.self)
        // The header at 42 is an hour old: no transaction since block 41.
        let chain = StubChain(chainId: "willow-chain", headers: [42: (f.expected_root_hex.uppercased(), Date().addingTimeInterval(-3600))])
        let stub = try Self.bobServer(height: 41, rpc: chain.answer)
        let client = try stub.client(baseURL: "http://api.test")
        let lc = try Self.pinnedLightClient(height: 41, appHash: "00", stub: stub)
        client.setLightClient(lc)

        let response = try await client.data.get(subgroveId: "my-sub", key: "user:bob")
        XCTAssertEqual(response.data["balance"]?.value as? Int, 250)
        XCTAssertEqual(lc.getSyncStatus().latestTrustedHeight, 42)
        let rpc = stub.requests.filter { $0.url.host == "rpc.test" }.map { $0.target }
        XCTAssertEqual(rpc, ["/commit?height=42", "/validators?height=42&page=1&per_page=100"])

        // A later read of the same state takes the header from memory.
        _ = try await client.data.get(subgroveId: "my-sub", key: "user:bob")
        XCTAssertEqual(stub.requests.filter { $0.url.host == "rpc.test" }.count, 2)
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
