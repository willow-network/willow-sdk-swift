import XCTest
@testable import Willow

/// The envelope-descent guard (checkEnvelope). The gap: grovedb finds the next
/// layer by the envelope's lowerLayers map key, which is not hash-bound, so a
/// renamed or dropped subtree on the query path yields the same root with an
/// empty result set — "K = V" verifies as "K is absent". These build the
/// decoded envelope directly (the byte decoder's format is a separate issue —
/// see the PR note), so they exercise the guard on its own.
final class GroveDBEnvelopeTests: XCTestCase {
    let path: [[UInt8]] = [Array("subgroves".utf8), Array("aave-v3-lending".utf8),
                           Array("indexed".utf8), Array("Supply".utf8)]

    func hexKey(_ k: [UInt8]) -> String { k.map { String(format: "%02x", $0) }.joined() }

    func honest(_ p: [[UInt8]]? = nil, opts: Bool = true) -> GroveDBProof {
        let segs = p ?? path
        var layer = LayerProof(merkProof: Data(), lowerLayers: [:])
        for seg in segs.reversed() {
            layer = LayerProof(merkProof: Data(), lowerLayers: [hexKey(seg): layer])
        }
        var o = ProveOptions(); o.decreaseLimitOnEmptySubQueryResult = opts
        return GroveDBProof(version: 0, proof: GroveDBProofV0(rootLayer: layer, proveOptions: o))
    }

    func testHonestEnvelopeDescends() throws {
        try GroveDBVerifier.checkEnvelope(honest(), expectedPath: path)
    }

    func testRenamedLowerLayerRejected() throws {
        let p = honest()
        let root = p.proof!.rootLayer!
        let sub = root.lowerLayers.values.first!
        root.lowerLayers = [hexKey(Array("forged".utf8)): sub]
        XCTAssertThrowsError(try GroveDBVerifier.checkEnvelope(p, expectedPath: path)) { e in
            XCTAssertTrue("\(e)".contains("does not descend"))
        }
    }

    func testDroppedLowerLayerRejected() throws {
        let p = honest()
        var layer = p.proof!.rootLayer!
        for seg in path.dropLast() { layer = layer.lowerLayers[hexKey(seg)]! }
        layer.lowerLayers = [:]
        XCTAssertThrowsError(try GroveDBVerifier.checkEnvelope(p, expectedPath: path))
    }

    func testExtraLowerLayersRejected() throws {
        // Descends to 'indexed'; asked to stop at 'aave-v3-lending'.
        XCTAssertThrowsError(try GroveDBVerifier.checkEnvelope(honest(Array(path[0..<3])), expectedPath: Array(path[0..<2]))) { e in
            XCTAssertTrue("\(e)".contains("unexpected lower layers"))
        }
    }

    func testNonDefaultProveOptionsRejected() throws {
        XCTAssertThrowsError(try GroveDBVerifier.checkEnvelope(honest(opts: false), expectedPath: path)) { e in
            XCTAssertTrue("\(e)".contains("prove_options"))
        }
    }
}
