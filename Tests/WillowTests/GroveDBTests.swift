import XCTest
@testable import Willow

final class GroveDBTests: XCTestCase {

    // MARK: - CryptoHash Tests

    func testCryptoHashCreation() {
        let hash = CryptoHash()
        XCTAssertEqual(hash.bytes.count, hashLength)
        XCTAssertTrue(hash.isZero, "Default hash should be zero")
    }

    func testCryptoHashFromBytes() {
        var bytes = [UInt8](repeating: 0, count: hashLength)
        bytes[0] = 1
        bytes[31] = 255

        let hash = CryptoHash(bytes: bytes)
        XCTAssertEqual(hash.bytes[0], 1)
        XCTAssertEqual(hash.bytes[31], 255)
        XCTAssertFalse(hash.isZero, "Hash with non-zero bytes should not be zero")
    }

    func testCryptoHashFromData() {
        let data = Data([1, 2, 3, 4, 5] + [UInt8](repeating: 0, count: 27))
        let hash = CryptoHash(data: data)

        XCTAssertEqual(hash.bytes[0], 1)
        XCTAssertEqual(hash.bytes[4], 5)
    }

    func testCryptoHashHexString() {
        var bytes = [UInt8](repeating: 0, count: hashLength)
        bytes[0] = 0xAB
        bytes[1] = 0xCD

        let hash = CryptoHash(bytes: bytes)
        let hex = hash.hexString

        XCTAssertEqual(hex.count, 64, "Hex string should be 64 characters")
        XCTAssertTrue(hex.hasPrefix("abcd"), "Hex should start with 'abcd'")
    }

    func testCryptoHashFromHex() throws {
        let hexString = String(repeating: "ab", count: 32)
        let hash = try CryptoHash.fromHex(hexString)

        for byte in hash.bytes {
            XCTAssertEqual(byte, 0xAB)
        }
    }

    func testCryptoHashFromHexInvalidLength() {
        XCTAssertThrowsError(try CryptoHash.fromHex("abcd")) { error in
            XCTAssertTrue(error is WillowError, "Should throw WillowError")
        }
    }

    func testCryptoHashEquality() {
        let hash1 = CryptoHash(bytes: [UInt8](repeating: 1, count: hashLength))
        let hash2 = CryptoHash(bytes: [UInt8](repeating: 1, count: hashLength))
        let hash3 = CryptoHash(bytes: [UInt8](repeating: 2, count: hashLength))

        XCTAssertEqual(hash1, hash2)
        XCTAssertNotEqual(hash1, hash3)
    }

    // MARK: - Hash Function Tests

    func testComputeHash() {
        let data = Data("test".utf8)
        let hash = computeHash(data)

        XCTAssertFalse(hash.isZero, "Hash should not be zero")
        XCTAssertEqual(hash.bytes.count, hashLength)

        // Same input should produce same hash
        let hash2 = computeHash(data)
        XCTAssertEqual(hash, hash2)
    }

    func testComputeHashBytes() {
        let bytes: [UInt8] = [1, 2, 3, 4, 5]
        let hash = computeHash(bytes)

        XCTAssertFalse(hash.isZero)
        XCTAssertEqual(hash.bytes.count, hashLength)
    }

    func testValueHash() {
        let value = Data("value".utf8)
        let hash = valueHash(value)

        XCTAssertEqual(hash, computeHash(value))
    }

    func testKVHash() {
        let key = Data("key".utf8)
        let value = Data("value".utf8)
        let hash = kvHash(key: key, value: value)

        // Should be different from just hashing key or value
        let keyHash = computeHash(key)
        let valueHashVal = computeHash(value)

        XCTAssertNotEqual(hash, keyHash)
        XCTAssertNotEqual(hash, valueHashVal)
    }

    func testComputeNodeHash() {
        let kv = CryptoHash(bytes: [UInt8](repeating: 1, count: hashLength))
        let left = CryptoHash(bytes: [UInt8](repeating: 2, count: hashLength))
        let right = CryptoHash(bytes: [UInt8](repeating: 3, count: hashLength))

        let nodeHash = computeNodeHash(kvHash: kv, leftHash: left, rightHash: right)

        XCTAssertFalse(nodeHash.isZero)

        // Should be consistent
        let nodeHash2 = computeNodeHash(kvHash: kv, leftHash: left, rightHash: right)
        XCTAssertEqual(nodeHash, nodeHash2)
    }

    func testCombineHash() {
        let a = CryptoHash(bytes: [UInt8](repeating: 1, count: hashLength))
        let b = CryptoHash(bytes: [UInt8](repeating: 2, count: hashLength))

        let combined = combineHash(a, b)

        XCTAssertFalse(combined.isZero)
        XCTAssertNotEqual(combined, a)
        XCTAssertNotEqual(combined, b)

        // Order matters
        let reversed = combineHash(b, a)
        XCTAssertNotEqual(combined, reversed)
    }

    // MARK: - MerkNode Tests

    func testMerkNodeCreation() {
        let node = MerkNode(type: .hash, hash: nullHash)

        XCTAssertEqual(node.type, .hash)
        XCTAssertTrue(node.hash.isZero)
    }

    func testMerkNodeHashNode() {
        let hash = computeHash(Data("test".utf8))
        let node = MerkNode.hashNode(hash)

        XCTAssertEqual(node.type, .hash)
        XCTAssertEqual(node.hash, hash)
    }

    func testMerkNodeKVHashNode() {
        let hash = computeHash(Data("kv".utf8))
        let node = MerkNode.kvHashNode(hash)

        XCTAssertEqual(node.type, .kvHash)
        XCTAssertEqual(node.kvHashVal, hash)
    }

    func testMerkNodeKVNode() {
        let key = Data("key".utf8)
        let value = Data("value".utf8)
        let node = MerkNode.kvNode(key: key, value: value)

        XCTAssertEqual(node.type, .kv)
        XCTAssertEqual(node.key, key)
        XCTAssertEqual(node.value, value)
    }

    // MARK: - Element Tests

    func testElementIsTree() {
        let item = Element(type: .item)
        XCTAssertFalse(item.isTree)

        let tree = Element(type: .tree)
        XCTAssertTrue(tree.isTree)

        let sumTree = Element(type: .sumTree)
        XCTAssertTrue(sumTree.isTree)
    }

    func testElementHasRootKey() {
        let treeNoKey = Element(type: .tree, rootKey: nil)
        XCTAssertFalse(treeNoKey.hasRootKey)

        let treeEmptyKey = Element(type: .tree, rootKey: Data())
        XCTAssertFalse(treeEmptyKey.hasRootKey)

        let treeWithKey = Element(type: .tree, rootKey: Data([1, 2, 3]))
        XCTAssertTrue(treeWithKey.hasRootKey)

        let itemWithKey = Element(type: .item, rootKey: Data([1, 2, 3]))
        XCTAssertFalse(itemWithKey.hasRootKey) // Items don't have root keys
    }

    // MARK: - LayerProof Tests

    func testLayerProofCreation() {
        let layer = LayerProof()

        XCTAssertTrue(layer.merkProof.isEmpty)
        XCTAssertTrue(layer.lowerLayers.isEmpty)
    }

    func testLayerProofWithData() {
        let layer = LayerProof(merkProof: Data([1, 2, 3]))
        layer.lowerLayers["sub1"] = LayerProof(merkProof: Data([4, 5, 6]))

        XCTAssertEqual(layer.merkProof.count, 3)
        XCTAssertEqual(layer.lowerLayers.count, 1)
        XCTAssertNotNil(layer.lowerLayers["sub1"])
    }

    // MARK: - GroveDBProof Tests

    func testGroveDBProofCreation() {
        let proof = GroveDBProof()

        XCTAssertEqual(proof.version, 0)
        XCTAssertNil(proof.proof)
    }

    // MARK: - Query Result Tests

    func testGroveDBQueryResult() {
        let path: [[UInt8]] = [[1, 2], [3, 4]]
        let key = Data([5, 6])
        let value = Data([7, 8])

        let result = GroveDBQueryResult(path: path, key: key, value: value)

        XCTAssertEqual(result.path.count, 2)
        XCTAssertEqual(result.key, key)
        XCTAssertEqual(result.value, value)
    }

    // MARK: - Verification Result Tests

    func testGroveDBVerificationResult() {
        let result = GroveDBVerificationResult(
            rootHash: "abc123",
            results: []
        )

        XCTAssertEqual(result.rootHash, "abc123")
        XCTAssertTrue(result.results.isEmpty)
    }

    // MARK: - NullHash Tests

    func testNullHash() {
        XCTAssertTrue(nullHash.isZero)
        XCTAssertEqual(nullHash.bytes.count, hashLength)
    }
}
