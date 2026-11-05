import XCTest
@testable import Willow

/// A proof's envelope holds at most 1,024 layers, and a proof of one key at
/// most 1 MiB, so a hostile proof can't make verifying it take quadratic time.
final class ProofLimitsTests: XCTestCase {

    /// grovedb's bincode varint: a byte up to 250, else a marker and the
    /// value big-endian.
    static func varint(_ n: Int) -> [UInt8] {
        switch n {
        case 0...250: return [UInt8(n)]
        case 251..<(1 << 16): return [251, UInt8(n >> 8), UInt8(n & 0xff)]
        default: return [252] + (0..<4).reversed().map { UInt8((n >> ($0 * 8)) & 0xff) }
        }
    }

    static func vector(_ bytes: [UInt8]) -> [UInt8] {
        return varint(bytes.count) + bytes
    }

    /// A proof whose root layer proves `decoys` tree elements and then
    /// `subgroves`, each with a lower layer that hashes, with the element, to
    /// the value hash the root layer commits: every lower layer but the
    /// path's is off the path. Checking each against the root layer's nodes
    /// by a scan made verifying it quadratic in `decoys`.
    static func decoyProof(_ decoys: Int) -> Data {
        let treeElement: [UInt8] = [0x02, 0x01, 0x01, 0x41, 0x00] // Tree(Some([0x41]), None)
        let lowerRoot = [UInt8](repeating: 0x11, count: 32)
        let lowerMerk: [UInt8] = [0x01] + lowerRoot // Push(Hash)
        let committed = combineHash(valueHash(Data(treeElement)), CryptoHash(bytes: lowerRoot)).bytes
        var keys = (0..<decoys).map { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
        keys.append(Array("subgroves".utf8))
        var merk: [UInt8] = []
        for (i, key) in keys.enumerated() {
            // Push(KVValueHash(key, element, value hash)), then Parent.
            merk += [0x04, UInt8(key.count)] + key + [0x00, UInt8(treeElement.count)] + treeElement + committed
            if i > 0 {
                merk.append(0x10)
            }
        }
        var proof = varint(0) + vector(merk) + varint(keys.count)
        for key in keys {
            proof += vector(key) + vector(lowerMerk) + varint(0)
        }
        proof.append(0x01)
        return Data(proof)
    }

    /// 20,000 off-path layers (a 1.6 MB proof) are refused as the envelope is
    /// read, before any is hashed; the same proof with a few decoys is read
    /// and fails only where its path ends.
    func testAProofOfThousandsOfLayersIsRefusedBeforeHashing() throws {
        let path = DataOperations.dataPath("sg")
        let started = Date()
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: Self.decoyProof(20_000), expectedPath: path)) { error in
            XCTAssertTrue((error as? VerificationError)?.message.contains("more than 1024 layers") == true, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertThrowsError(try GroveDBVerifier.verifyProof(proofBytes: Self.decoyProof(3), expectedPath: path)) { error in
            XCTAssertTrue((error as? VerificationError)?.message.contains("path segment 1") == true, "\(error)")
        }
    }

    /// A proof of one key over 1 MiB is refused before it is verified.
    func testAVerifiedGetRefusesAProofOfOneKeyOverOneMiB() async throws {
        let f = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: GroveDBProofTests.SingleKey.self)
        let padded = f.proof_hex + String(repeating: "00", count: (1 << 20) + 1 - f.proof_hex.count / 2)
        let stub = StubServer { request in
            switch request.path {
            case "/data/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"balance":250}}"#)
            case "/proof/my-sub/user:bob":
                return (200, #"{"success":true,"data":{"proof":"\#(padded)","height":41}}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setLightClient(try VerifiedReadsTests.pinnedLightClient(height: 42, appHash: f.expected_root_hex, stub: stub))
        do {
            _ = try await client.data.get(subgroveId: "my-sub", key: "user:bob")
            XCTFail("verified a proof of one key over 1 MiB")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .proof)
            XCTAssertTrue(error.message.contains("over the 1 MiB"), error.message)
        }
    }
}
