import XCTest
@testable import Willow

/// The GroveDB verifier against BLAKE3's official test vectors, Merk's hash
/// rules, and real proofs from grovedb 3.1.0 (Fixtures/grovedb, the proofs the
/// TypeScript SDK's verifier is tested on, minted by a Rust generator over the
/// canonical grovedb).
final class GroveDBProofTests: XCTestCase {

    // MARK: - BLAKE3

    /// BLAKE3's official test vectors (test_vectors/test_vectors.json in the
    /// BLAKE3 repository), default hash mode, first 32 bytes of output. Each
    /// input is `length` bytes of the repeating sequence 0, 1, ..., 250.
    static let blake3Vectors: [(Int, String)] = [
        (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
        (1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"),
        (2, "7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63"),
        (3, "e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f"),
        (4, "f30f5ab28fe047904037f77b6da4fea1e27241c5d132638d8bedce9d40494f32"),
        (5, "b40b44dfd97e7a84a996a91af8b85188c66c126940ba7aad2e7ae6b385402aa2"),
        (6, "06c4e8ffb6872fad96f9aaca5eee1553eb62aed0ad7198cef42e87f6a616c844"),
        (7, "3f8770f387faad08faa9d8414e9f449ac68e6ff0417f673f602a646a891419fe"),
        (8, "2351207d04fc16ade43ccab08600939c7c1fa70a5c0aaca76063d04c3228eaeb"),
        (63, "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b"),
        (64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98"),
        (65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee"),
        (127, "d81293fda863f008c09e92fc382a81f5a0b4a1251cba1634016a0f86a6bd640d"),
        (128, "f17e570564b26578c33bb7f44643f539624b05df1a76c81f30acd548c44b45ef"),
        (129, "683aaae9f3c5ba37eaaf072aed0f9e30bac0865137bae68b1fde4ca2aebdcb12"),
        (1023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11"),
        (1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"),
        (1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"),
        (2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"),
        (2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030"),
        (3072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"),
        (3073, "7124b49501012f81cc7f11ca069ec9226cecb8a2c850cfe644e327d22d3e1cd3"),
        (4096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969"),
        (4097, "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995"),
        (5120, "9cadc15fed8b5d854562b26a9536d9707cadeda9b143978f319ab34230535833"),
        (5121, "628bd2cb2004694adaab7bbd778a25df25c47b9d4155a55f8fbd79f2fe154cff"),
        (6144, "3e2e5b74e048f3add6d21faab3f83aa44d3b2278afb83b80b3c35164ebeca205"),
        (6145, "f1323a8631446cc50536a9f705ee5cb619424d46887f3c376c695b70e0f0507f"),
        (7168, "61da957ec2499a95d6b8023e2b0e604ec7f6b50e80a9678b89d2628e99ada77a"),
        (7169, "a003fc7a51754a9b3c7fae0367ab3d782dccf28855a03d435f8cfe74605e7817"),
        (8192, "aae792484c8efe4f19e2ca7d371d8c467ffb10748d8a5a1ae579948f718a2a63"),
        (8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b"),
        (16384, "f875d6646de28985646f34ee13be9a576fd515f76b5b0a26bb324735041ddde4"),
        (31744, "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47"),
        (102400, "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085"),
    ]

    func testBLAKE3IsTheOfficialTestVectors() {
        for (length, expected) in Self.blake3Vectors {
            let input = (0..<length).map { UInt8($0 % 251) }
            XCTAssertEqual(Data(BLAKE3.hash(input)).hexString, expected, "length \(length)")
        }
    }

    // MARK: - Merk's hash rules

    /// Expected values computed with the BLAKE3 reference implementation's
    /// Python bindings, following grovedb-merk's tree hashing.
    func testMerkHashRules() throws {
        let a = computeHash([UInt8]([1]))
        let b = computeHash([UInt8]([2]))
        let c = computeHash([UInt8]([3]))
        XCTAssertEqual(a.hexString, "48fc721fbbc172e0925fa27af1671de225ba927134802998b10a1568a188652b")
        XCTAssertEqual(b.hexString, "ab13bedf42e84bae0f7c62c7dd6a8ada571e8829bed6ea558217f0361b5e25d0")
        XCTAssertEqual(c.hexString, "e1e0e81d6ea39b0cf8b86ffd440921011f57400cbc3f76a8a171906a9b8d7505")

        // value_hash = BLAKE3(varint(len) || value)
        XCTAssertEqual(valueHash(Data([1, 2, 3])).hexString, "0c2f2a068e9d8a97c02d0b4e01569a3caf87007f73f85c44f907d4038cabc4f3")
        XCTAssertEqual(valueHash(Data()).hexString, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213")
        // A length of 300 takes a two-byte varint.
        XCTAssertEqual(merkVarint(300), [0xAC, 0x02])
        let long = Data((0..<300).map { UInt8($0 % 251) })
        XCTAssertEqual(valueHash(long).hexString, "aac73da780e40153f01a3b321cdf90078cfac2a70f65fd7e11f9cbf7b58dbdbd")

        // kv_hash = BLAKE3(varint(len) || key || value_hash(value))
        let key = Data("key".utf8)
        let value = Data("value".utf8)
        XCTAssertEqual(kvHash(key: key, value: value).hexString, "bc6abb815cb11f53ef6438f69a86a3e42d5ed04f28109e59c7699090c808ef96")
        XCTAssertEqual(kvDigestToKvHash(key: key, valueHash: valueHash(value)), kvHash(key: key, value: value))

        // node_hash = BLAKE3(kv || left || right); combine_hash = BLAKE3(a || b)
        XCTAssertEqual(computeNodeHash(kvHash: a, leftHash: b, rightHash: c).hexString, "186bc39283bb5e684fadde68251512e4741c370fe011dcece8a26da8831937e7")
        XCTAssertEqual(computeNodeHash(kvHash: a, leftHash: nullHash, rightHash: nullHash).hexString, "d7a11a5aeac8439120e343021bc7c8913cb17d2f333d6babd070979d9b1738c5")
        XCTAssertEqual(combineHash(a, b).hexString, "2643fa74cd323c0d80963207ac617d364087e2075e1aa60ba1c9ef461cd28a7e")
    }

    // MARK: - Real proofs

    struct SingleKey: Decodable {
        let path: [String]
        let key: String
        let value_hex: String
        let proof_hex: String
        let expected_root_hex: String
    }

    struct RangeFull: Decodable {
        let path: [String]
        let expected_keys: [String]
        let expected_values_hex: [String]
        let proof_hex: String
        let expected_root_hex: String
    }

    struct PartialProof: Decodable {
        let proofHex: String
        let stateRootHex: String
        let key: String
        let path: String
    }

    struct Envelope: Decodable {
        let root: String
        let path: [String]
        let key: String?
        let proof: String
        let proof_renamed_layer: String?
        let proof_dropped_layer: String?
        let proof_opts_flipped: String?
    }

    static func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "grovedb"), name)
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    static func hex(_ string: String) throws -> Data {
        return try XCTUnwrap(Data(hexString: string), string)
    }

    static func path(_ segments: [String]) -> [[UInt8]] {
        return segments.map { Array($0.utf8) }
    }

    func testRealSingleKeyProofsVerifyToTheirRoots() throws {
        for name in ["single_key_apps_data_key2", "nested_single_key_user_bob"] {
            let f = try Self.fixture(name, as: SingleKey.self)
            let result = try GroveDBVerifier.verifyProofAgainstRoot(
                proofBytes: Self.hex(f.proof_hex), expectedRootHash: f.expected_root_hex, expectedPath: Self.path(f.path)
            )
            XCTAssertEqual(result.rootHash, f.expected_root_hex, name)
            XCTAssertEqual(result.results.count, 1, name)
            let proved = try XCTUnwrap(result.results.first)
            XCTAssertEqual(proved.path, Self.path(f.path), name)
            XCTAssertEqual(proved.key, Data(f.key.utf8), name)
            XCTAssertEqual(DataOperations.groveItemBytes(proved.value), try Self.hex(f.value_hex), name)
        }
    }

    func testARealProofProvesTheValueADataReadServes() throws {
        let f = try Self.fixture("nested_single_key_user_bob", as: SingleKey.self)
        let result = try GroveDBVerifier.verifyProof(proofBytes: Self.hex(f.proof_hex), expectedPath: DataOperations.dataPath("my-sub"))
        let proven = try DataOperations.requireProven(subgroveId: "my-sub", key: "user:bob", value: ["balance": AnyCodable(250)], in: result)
        XCTAssertEqual(proven["balance"]?.value as? Int, 250)
        XCTAssertThrowsError(try DataOperations.requireProven(subgroveId: "my-sub", key: "user:bob", value: ["balance": AnyCodable(251)], in: result))
    }

    func testARealRangeProofVerifiesToItsRoot() throws {
        let f = try Self.fixture("range_full_apps_data", as: RangeFull.self)
        let result = try GroveDBVerifier.verifyProofAgainstRoot(
            proofBytes: Self.hex(f.proof_hex), expectedRootHash: f.expected_root_hex, expectedPath: Self.path(f.path)
        )
        XCTAssertEqual(result.results.map { String(decoding: $0.key, as: UTF8.self) }, f.expected_keys)
        XCTAssertEqual(result.results.map { DataOperations.groveItemBytes($0.value)?.hexString }, f.expected_values_hex.map { Optional($0) })
    }

    /// A single key among 300: the partial tree the proof rebuilds is
    /// unbalanced (collapsed siblings), which a valid proof may be.
    func testARealProofIntoALargeTreeVerifies() throws {
        let f = try Self.fixture("partial-proof-live", as: PartialProof.self)
        let segments = f.path.split(separator: "/").map(String.init)
        let result = try GroveDBVerifier.verifyProofAgainstRoot(
            proofBytes: Self.hex(f.proofHex), expectedRootHash: f.stateRootHex, expectedPath: Self.path(segments)
        )
        XCTAssertTrue(result.results.contains { $0.key == Data(f.key.utf8) })
    }

    func testRealIndexedProofsVerifyAtTheirPath() throws {
        let fixtures = try Self.fixture("envelope-real-proofs", as: [String: Envelope].self)
        for (name, count) in [("single-key", 1), ("range-all", 5), ("absent-key", 0), ("range-limit-2", 2)] {
            let f = try XCTUnwrap(fixtures[name], name)
            let result = try GroveDBVerifier.verifyProofAgainstRoot(
                proofBytes: Self.hex(f.proof), expectedRootHash: f.root, expectedPath: Self.path(f.path)
            )
            XCTAssertEqual(result.results.count, count, name)
        }
        let single = try XCTUnwrap(fixtures["single-key"])
        let result = try GroveDBVerifier.verifyProof(proofBytes: Self.hex(single.proof), expectedPath: Self.path(single.path))
        XCTAssertEqual(result.results.first?.key, Data(try XCTUnwrap(single.key).utf8))
    }

    @available(*, deprecated)
    func testARenamedOrDroppedLayerIsRefused() throws {
        let fixtures = try Self.fixture("envelope-real-proofs", as: [String: Envelope].self)
        for name in ["single-key", "range-all", "absent-key"] {
            let f = try XCTUnwrap(fixtures[name], name)
            for tampered in [f.proof_renamed_layer, f.proof_dropped_layer] {
                XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: Self.hex(XCTUnwrap(tampered)), expectedPath: Self.path(f.path))) { error in
                    XCTAssertTrue("\(error)".contains("does not descend"), "\(name): \(error)")
                }
            }
            XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: Self.hex(XCTUnwrap(f.proof_opts_flipped)))) { error in
                XCTAssertTrue("\(error)".contains("prove_options"), "\(name): \(error)")
            }
        }
        // Without the path, a lower layer whose key its layer doesn't prove
        // is refused too.
        let single = try XCTUnwrap(fixtures["single-key"])
        XCTAssertThrowsError(try GroveDBVerifier.verifyProofAgainstRoot(
            proofBytes: Self.hex(XCTUnwrap(single.proof_renamed_layer)), expectedRootHash: single.root
        )) { error in
            XCTAssertTrue("\(error)".contains("prove as an element"), "\(error)")
        }
        // A shorter or longer path is refused.
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: Self.hex(single.proof), expectedPath: Array(Self.path(single.path).prefix(3))))
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: Self.hex(single.proof), expectedPath: Self.path(single.path + ["x"])))
    }

    /// grovedb proves a tree element the query doesn't descend into as a
    /// node with no lower layer: its value hash combines its bytes with the
    /// subtree's root, so its bytes alone don't hash to it. The dropped-layer
    /// proof is byte for byte grovedb's proof of the key `Supply` itself at
    /// `subgroves/aave-v3-lending/indexed`, and verifies at that path.
    @available(*, deprecated)
    func testATreeElementWithNoLowerLayerVerifies() throws {
        let fixtures = try Self.fixture("envelope-real-proofs", as: [String: Envelope].self)
        for name in ["single-key", "range-all", "absent-key"] {
            let f = try XCTUnwrap(fixtures[name], name)
            let dropped = try Self.hex(XCTUnwrap(f.proof_dropped_layer))
            let parent = Array(Self.path(f.path).dropLast())
            let result = try GroveDBVerifier.verifyProofAgainstRoot(proofBytes: dropped, expectedRootHash: f.root, expectedPath: parent)
            XCTAssertEqual(result.results.count, 1, name)
            let tree = try XCTUnwrap(result.results.first, name)
            XCTAssertEqual(tree.path, parent, name)
            XCTAssertEqual(tree.key, Data("Supply".utf8), name)
            XCTAssertTrue(groveTreeRootKey(tree.value).isTree, name)
            // Only its key is bound, so the proof doesn't show the tree whole.
            XCTAssertFalse(tree.isValueBound, name)
            XCTAssertFalse(result.coversWholeTree, name)
            XCTAssertEqual(try GroveDBVerifier.verifyProof(proofBytes: dropped).rootHash, f.root, name)
        }
        // An item's bytes must still hash to its value hash: the same proof
        // with the tree element's variant byte changed to an item's is refused.
        let single = try XCTUnwrap(fixtures["single-key"])
        let element = "0201" + "44"
        let asItem = "0001" + "44"
        let tampered = try XCTUnwrap(single.proof_dropped_layer).replacingOccurrences(of: element, with: asItem)
        XCTAssertNotEqual(tampered, single.proof_dropped_layer)
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: Self.hex(tampered))) { error in
            XCTAssertTrue("\(error)".contains("does not hash to its committed value hash"), "\(error)")
        }
    }

    @available(*, deprecated)
    func testAChangedValueDoesNotVerify() throws {
        let f = try Self.fixture("single_key_apps_data_key2", as: SingleKey.self)
        // "value-for-key2" -> "value-for-key3" inside the proof.
        let tampered = f.proof_hex.replacingOccurrences(of: f.value_hex, with: String(f.value_hex.dropLast()) + "3")
        XCTAssertNotEqual(tampered, f.proof_hex)
        XCTAssertThrowsError(try GroveDBVerifier.verifyProofAgainstRoot(
            proofBytes: Self.hex(tampered), expectedRootHash: f.expected_root_hex, expectedPath: Self.path(f.path)
        ))
        // As do trailing bytes and a truncated proof.
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: Self.hex(f.proof_hex + "00")))
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: Self.hex(String(f.proof_hex.dropLast(4)))))
    }

    /// A forged proof for `subgroves/my-sub/data/user:bob` against the real
    /// root of `nested_single_key_user_bob`: it pushes that root as a `Hash`
    /// node and attaches the forged path to it as a child. A `Hash` node
    /// stands for a pruned subtree whose hash already covers its children, so
    /// it can't be a parent, and the proof is refused.
    func testAHashNodeCantBeAParent() throws {
        let f = try Self.fixture("nested_single_key_user_bob", as: SingleKey.self)
        let forged = "005401b3919503bca50efc2b8ae6fc643d4c57a2c527e04b0bfa102b9079c3084a0269040973756267726f76657300050201017800908ee3ea4f90b0786f56fdb9e4ee07aca782ade89e30fc861aab53d85076968011010973756267726f7665732f04066d792d73756200050201017800c0443d5e00404774059bfea49101762310601b326a01442b418c493fbd5a9ed201066d792d7375622d04046461746100050201017800624d3ac133927b2263aa2c62ffd1e63a4069944eef70edaf6a0bdd2276653a9b010464617461240308757365723a626f62001800157b2262616c616e6365223a3939393939393939397d000001"
        XCTAssertThrowsError(try GroveDBVerifier.verifyProofAgainstRoot(
            proofBytes: Self.hex(forged), expectedRootHash: f.expected_root_hex, expectedPath: DataOperations.dataPath("my-sub")
        ))
        // Push Hash, Push KV, Child: the KV can't hang under the Hash node.
        let ops: [UInt8] = [0x01] + [UInt8](repeating: 0xAB, count: 32) + [0x03, 1, 1, 0, 0, 0x11]
        XCTAssertThrowsError(try executeMerkProof(Data(ops)))
    }

    func testOutOfOrderKeysAreRefused() {
        // Push KV(2), Push KV(1), Parent: keys must ascend.
        let ops: [UInt8] = [0x03, 1, 2, 0, 0, 0x03, 1, 1, 0, 0, 0x10]
        XCTAssertThrowsError(try executeMerkProof(Data(ops))) { error in
            XCTAssertTrue("\(error)".contains("ordering"))
        }
        let ordered: [UInt8] = [0x03, 1, 1, 0, 0, 0x03, 1, 2, 0, 0, 0x10]
        XCTAssertNoThrow(try executeMerkProof(Data(ordered)))
    }

    func testTreeElementsAreRecognized() {
        // Element::Tree(Some(root_key), None) and Element::Item(bytes, None).
        XCTAssertEqual(groveTreeRootKey(Data([0x02, 0x01, 0x02, 0xAA, 0xBB, 0x00])).rootKey, [0xAA, 0xBB])
        XCTAssertTrue(groveTreeRootKey(Data([0x02, 0x00, 0x00])).isTree)
        XCTAssertFalse(groveTreeRootKey(Data([0x00, 0x01, 0x41, 0x00])).isTree)
    }
}
