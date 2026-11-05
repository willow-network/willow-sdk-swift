import XCTest
@testable import Willow

/// Large-value merk ops (0x20...0x23, 0x28...0x2b). grovedb 3.1.0 writes a
/// proof value's length as a u16, so a value of 64 KiB or more could not be
/// proven; the Willow GroveDB fork writes such values with large-value ops
/// (u32 length). The fixtures are real proofs from the fork's prover: a
/// 70,000-byte item (its merk op is 0x20) and a 65,530-byte item whose
/// 65,535-byte merk value is the largest a 3.1.0 op (0x03) carries.
final class GroveDBLargeValueTests: XCTestCase {
    struct LargeValue: Decodable {
        let path: [String]
        let key: String
        let value_len: Int
        let element_len: Int
        let item_opcode: Int
        let proof_hex: String
        let expected_root_hex: String
    }

    static func fixture(_ name: String) throws -> LargeValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "grovedb"), name)
        return try JSONDecoder().decode(LargeValue.self, from: Data(contentsOf: url))
    }

    static func katValue(_ n: Int) -> Data {
        return Data((0..<n).map { UInt8(($0 * 7 + 3) % 256) })
    }

    static func decodeAll(_ bytes: [UInt8]) throws -> [MerkOp] {
        let decoder = MerkDecoder(Data(bytes))
        var ops: [MerkOp] = []
        while let op = try decoder.next() { ops.append(op) }
        return ops
    }

    static func largeKV(_ op: UInt8, declared: UInt32, carried: Int, tail: [UInt8] = []) -> [UInt8] {
        var b: [UInt8] = [op, 1, 0x6b]
        b += [UInt8(declared >> 24 & 0xff), UInt8(declared >> 16 & 0xff), UInt8(declared >> 8 & 0xff), UInt8(declared & 0xff)]
        b += [UInt8](repeating: 9, count: carried)
        return b + tail
    }

    func testRealLargeAndSmallValueProofsVerifyToTheirRoots() throws {
        for (name, opcode) in [("large_value_item", 0x20), ("small_value_item", 0x03)] {
            let f = try Self.fixture(name)
            XCTAssertEqual(f.item_opcode, opcode, name)
            let proofBytes = try XCTUnwrap(Data(hexString: f.proof_hex))
            let needle = [UInt8(opcode), UInt8(f.key.utf8.count)] + Array(f.key.utf8)
            let all = [UInt8](proofBytes)
            XCTAssertTrue((0...(all.count - needle.count)).contains { Array(all[$0..<($0 + needle.count)]) == needle }, name)

            let path = f.path.map { Array($0.utf8) }
            let result = try GroveDBVerifier.verifyProofAgainstRoot(
                proofBytes: proofBytes, expectedRootHash: f.expected_root_hex, expectedPath: path
            )
            XCTAssertEqual(result.rootHash, f.expected_root_hex, name)
            let proved = try XCTUnwrap(result.results.first { $0.key == Data(f.key.utf8) }, name)
            XCTAssertEqual(proved.value.count, f.element_len, name)
            XCTAssertEqual(proved.nodeType, .kv, name)
            XCTAssertTrue(proved.isValueBound, name)
            XCTAssertEqual(DataOperations.groveItemBytes(proved.value), Self.katValue(f.value_len), name)
        }
    }

    func testEveryLargeValueOpDecodesAsTheOpItMirrors() throws {
        let hash = [UInt8](repeating: 5, count: 32)
        let cases: [(UInt8, MerkOpType, MerkNodeType, [UInt8])] = [
            (0x20, .push, .kv, []),
            (0x21, .push, .kvValueHash, hash),
            (0x22, .push, .kvRefValueHash, hash),
            (0x23, .push, .kvValueHashFeatureType, hash + [0]),
            (0x28, .pushInverted, .kv, []),
            (0x29, .pushInverted, .kvValueHash, hash),
            (0x2a, .pushInverted, .kvRefValueHash, hash),
            (0x2b, .pushInverted, .kvValueHashFeatureType, hash + [0]),
        ]
        for (op, type, node, tail) in cases {
            let ops = try Self.decodeAll(Self.largeKV(op, declared: 65536, carried: 65536, tail: tail))
            XCTAssertEqual(ops.count, 1)
            XCTAssertEqual(ops[0].type, type)
            XCTAssertEqual(ops[0].node?.type, node)
            XCTAssertEqual(ops[0].node?.value?.count, 65536)
        }
    }

    func testLargeValueOpRefusals() throws {
        XCTAssertThrowsError(try Self.decodeAll(Self.largeKV(0x20, declared: 100, carried: 100)))
        XCTAssertThrowsError(try Self.decodeAll(Self.largeKV(0x20, declared: 65535, carried: 65535)))
        XCTAssertThrowsError(try Self.decodeAll(Self.largeKV(0x20, declared: 64 * 1024 * 1024 + 1, carried: 0)))
        XCTAssertThrowsError(try Self.decodeAll(Self.largeKV(0x20, declared: 0xffff_ffff, carried: 0)))
        XCTAssertThrowsError(try Self.decodeAll(Self.largeKV(0x20, declared: 70000, carried: 69999)))
        XCTAssertThrowsError(try Self.decodeAll([0x21, 1, 0x6b, 0, 1]))
        for op: UInt8 in [0x24, 0x25, 0x26, 0x27, 0x2c, 0x2d, 0x2e, 0x2f] {
            XCTAssertThrowsError(try Self.decodeAll(Self.largeKV(op, declared: 65536, carried: 65536)))
        }
        XCTAssertEqual(try Self.decodeAll(Self.largeKV(0x20, declared: 65536, carried: 65536)).count, 1)
    }
}
