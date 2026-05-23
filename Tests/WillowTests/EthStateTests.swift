import XCTest
@testable import Willow

final class EthStateTests: XCTestCase {

    func testMptRejectsShortRoot() {
        XCTAssertThrowsError(try verifyMptProof(
            root: Data(repeating: 0, count: 16),
            keyHash: Data(repeating: 0, count: 32),
            expectedValue: Data([0x80]),
            proofNodes: [Data([0xc0])]
        )) { error in
            XCTAssertTrue("\(error)".contains("root must be 32 bytes"))
        }
    }

    func testMptRejectsEmptyProof() {
        XCTAssertThrowsError(try verifyMptProof(
            root: Data(repeating: 0, count: 32),
            keyHash: Data(repeating: 0, count: 32),
            expectedValue: Data(),
            proofNodes: []
        )) { error in
            XCTAssertTrue("\(error)".contains("proof is empty"))
        }
    }

    func testMptVerifiesSingleLeafTrie() throws {
        let keyHash = keccak256(Data("hello".utf8))
        // Compact-encoded leaf path: 0x20 prefix (leaf, even nibbles) + key.
        var encodedPath = Data([0x20])
        encodedPath.append(keyHash)
        let value = Data([0xab, 0xcd, 0xef])
        let leafNode = rlpEncodeList([
            rlpEncodeBytes(encodedPath),
            rlpEncodeBytes(value),
        ])
        let root = keccak256(leafNode)
        try verifyMptProof(
            root: root,
            keyHash: keyHash,
            expectedValue: value,
            proofNodes: [leafNode]
        )
    }

    func testRlpRoundTrips() throws {
        let raw: [Data] = [
            Data([0x01]),
            Data([0xab, 0xcd]),
            Data(repeating: 0x77, count: 60),
        ]
        let encoded = raw.map { rlpEncodeBytes($0) }
        let list = rlpEncodeList(encoded)
        let decoded = try rlpDecodeList(list)
        XCTAssertEqual(decoded.count, raw.count)
        for (i, want) in raw.enumerated() {
            XCTAssertEqual(decoded[i], want, "item \(i) mismatch")
        }
    }
}
