import Foundation

// A GroveDB proof verifier, verify-only: it decodes a grovedb `GroveDBProof`,
// replays each layer's Merk proof with Merk's hash rules (BLAKE3; see
// GroveDBTypes.swift), binds each lower layer to its parent through the tree
// element's combined value hash, and returns the root hash and the proven
// values. A proof checks out only if the root it hashes to is the trusted root.

// MARK: - Merk Operation Codes

private let opPushHash: UInt8 = 0x01
private let opPushKVHash: UInt8 = 0x02
private let opPushKV: UInt8 = 0x03
private let opPushKVValueHash: UInt8 = 0x04
private let opPushKVDigest: UInt8 = 0x05
private let opPushKVRefValueHash: UInt8 = 0x06
private let opPushKVValueHashFeatureType: UInt8 = 0x07
private let opPushInvertedHash: UInt8 = 0x08
private let opPushInvertedKVHash: UInt8 = 0x09
private let opPushInvertedKV: UInt8 = 0x0a
private let opPushInvertedKVValueHash: UInt8 = 0x0b
private let opPushInvertedKVDigest: UInt8 = 0x0c
private let opPushInvertedKVRefValueHash: UInt8 = 0x0d
private let opPushInvertedKVValueHashFeatureType: UInt8 = 0x0e
private let opParent: UInt8 = 0x10
private let opChild: UInt8 = 0x11
private let opParentInverted: UInt8 = 0x12
private let opChildInverted: UInt8 = 0x13

// MARK: - Tree

/// A node in the Merk AVL tree, as a proof rebuilds it.
public class Tree {
    public var node: MerkNode
    public var left: Tree?
    public var right: Tree?
    public var childHeights: (left: Int, right: Int) = (0, 0)

    public init(node: MerkNode) {
        self.node = node
    }

    /// Returns the height of this tree.
    public var height: Int {
        return max(childHeights.left, childHeights.right) + 1
    }

    /// The node's hash: a `Hash` node's stored hash, else
    /// `computeNodeHash(kvHash, left, right)` with Merk's key-value hash for
    /// the node's kind.
    public func hash() -> CryptoHash {
        let kv: CryptoHash
        switch node.type {
        case .hash:
            return node.hash
        case .kvHash:
            kv = node.kvHashVal
        case .kv:
            kv = kvHash(key: node.key ?? Data(), value: node.value ?? Data())
        case .kvValueHash, .kvValueHashFeatureType, .kvDigest:
            kv = kvDigestToKvHash(key: node.key ?? Data(), valueHash: node.valueHash)
        case .kvRefValueHash:
            // A reference commits to its own value hash combined with the
            // referenced value's.
            let combined = combineHash(node.valueHash, valueHash(node.value ?? Data()))
            kv = kvDigestToKvHash(key: node.key ?? Data(), valueHash: combined)
        }
        return computeNodeHash(kvHash: kv, leftHash: left?.hash() ?? nullHash, rightHash: right?.hash() ?? nullHash)
    }

    /// Converts this tree to a hash-only tree.
    public func intoHash() -> Tree {
        let newTree = Tree(node: MerkNode.hashNode(hash()))
        newTree.childHeights = childHeights
        return newTree
    }

    /// Attaches a child tree with its height.
    public func attachWithHeight(isLeft: Bool, child: Tree, height: Int) {
        if isLeft {
            left = child
            childHeights.left = height
        } else {
            right = child
            childHeights.right = height
        }
    }
}

// MARK: - Merk Decoder

/// Decodes Merk proof operations from bytes: a one-byte op code, then for a
/// push the node (a key with a one-byte length, a value with a big-endian
/// two-byte length, 32-byte hashes, and for a feature-type node its tree
/// feature).
public class MerkDecoder {
    private let data: [UInt8]
    private var offset: Int = 0

    public init(_ data: Data) {
        self.data = [UInt8](data)
    }

    /// Returns true if there are more operations to decode.
    public var hasMore: Bool {
        return offset < data.count
    }

    /// Decodes the next operation.
    public func next() throws -> MerkOp? {
        guard hasMore else { return nil }

        let opCode = data[offset]
        offset += 1

        switch opCode {
        case opPushHash: return MerkOp(type: .push, node: try decodeHash())
        case opPushKVHash: return MerkOp(type: .push, node: try decodeKVHash())
        case opPushKV: return MerkOp(type: .push, node: try decodeKV())
        case opPushKVValueHash: return MerkOp(type: .push, node: try decodeKVValueHash(.kvValueHash))
        case opPushKVDigest: return MerkOp(type: .push, node: try decodeKVDigest())
        case opPushKVRefValueHash: return MerkOp(type: .push, node: try decodeKVValueHash(.kvRefValueHash))
        case opPushKVValueHashFeatureType: return MerkOp(type: .push, node: try decodeKVValueHashFeatureType())
        case opPushInvertedHash: return MerkOp(type: .pushInverted, node: try decodeHash())
        case opPushInvertedKVHash: return MerkOp(type: .pushInverted, node: try decodeKVHash())
        case opPushInvertedKV: return MerkOp(type: .pushInverted, node: try decodeKV())
        case opPushInvertedKVValueHash: return MerkOp(type: .pushInverted, node: try decodeKVValueHash(.kvValueHash))
        case opPushInvertedKVDigest: return MerkOp(type: .pushInverted, node: try decodeKVDigest())
        case opPushInvertedKVRefValueHash: return MerkOp(type: .pushInverted, node: try decodeKVValueHash(.kvRefValueHash))
        case opPushInvertedKVValueHashFeatureType: return MerkOp(type: .pushInverted, node: try decodeKVValueHashFeatureType())
        case opParent: return MerkOp(type: .parent)
        case opChild: return MerkOp(type: .child)
        case opParentInverted: return MerkOp(type: .parentInverted)
        case opChildInverted: return MerkOp(type: .childInverted)
        default:
            throw VerificationError("Unknown op code: 0x\(String(format: "%02x", opCode))")
        }
    }

    private func decodeHash() throws -> MerkNode {
        return MerkNode.hashNode(CryptoHash(data: try readBytes(hashLength)))
    }

    private func decodeKVHash() throws -> MerkNode {
        return MerkNode.kvHashNode(CryptoHash(data: try readBytes(hashLength)))
    }

    private func decodeKV() throws -> MerkNode {
        let key = try readBytes(Int(try readU8()))
        let value = try readBytes(Int(try readU16()))
        return MerkNode.kvNode(key: key, value: value)
    }

    private func decodeKVValueHash(_ type: MerkNodeType) throws -> MerkNode {
        let key = try readBytes(Int(try readU8()))
        let value = try readBytes(Int(try readU16()))
        let hash = CryptoHash(data: try readBytes(hashLength))
        return MerkNode(type: type, key: key, value: value, valueHash: hash)
    }

    private func decodeKVDigest() throws -> MerkNode {
        let key = try readBytes(Int(try readU8()))
        let hash = CryptoHash(data: try readBytes(hashLength))
        return MerkNode(type: .kvDigest, key: key, valueHash: hash)
    }

    /// A KVValueHash node followed by its tree feature, which the node's hash
    /// does not include: basic (0), summed (1, a zigzag varint), big summed
    /// (2, 16 bytes), counted (3, a varint), or counted and summed (4, both).
    private func decodeKVValueHashFeatureType() throws -> MerkNode {
        let node = try decodeKVValueHash(.kvValueHashFeatureType)
        switch try readU8() {
        case 0:
            break
        case 1, 3:
            _ = try readLEB128()
        case 2:
            _ = try readBytes(16)
        case 4:
            _ = try readLEB128()
            _ = try readLEB128()
        case let feature:
            throw VerificationError("Unknown tree feature type: \(feature)")
        }
        return node
    }

    private func readU8() throws -> UInt8 {
        guard offset < data.count else {
            throw VerificationError("Unexpected end of data reading a byte")
        }
        offset += 1
        return data[offset - 1]
    }

    private func readU16() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw VerificationError("Unexpected end of data reading u16")
        }
        let value = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2
        return value
    }

    private func readLEB128() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readU8()
            guard shift < 64 else { throw VerificationError("Varint too long") }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    private func readBytes(_ n: Int) throws -> Data {
        guard offset + n <= data.count else {
            throw VerificationError("Unexpected end of data reading \(n) bytes")
        }
        let result = Data(data[offset..<(offset + n)])
        offset += n
        return result
    }
}

// MARK: - Merk Execution Result

/// Result of executing a Merk proof.
public struct MerkExecutionResult {
    public let rootHash: CryptoHash
    public let resultSet: [ProvedKeyValue]
}

// MARK: - Execute Merk Proof

/// Executes a Merk proof and returns the root hash it rebuilds and the
/// key-values it carries, in order.
///
/// Keys must ascend across pushes (descend across inverted pushes), each child
/// is attached once to a node that isn't a `Hash` node, and the ops must leave
/// exactly one tree. The rebuilt tree
/// is a partial one (collapsed siblings are single hash nodes), so it is not
/// checked for AVL balance: as in grovedb, integrity rests on the hashes.
public func executeMerkProof(_ proofBytes: Data) throws -> MerkExecutionResult {
    let decoder = MerkDecoder(proofBytes)
    var stack: [Tree] = []
    var resultSet: [ProvedKeyValue] = []
    var lastKey: Data?
    var lastInverted = false

    func pop() throws -> Tree {
        guard let tree = stack.popLast() else {
            throw VerificationError("Stack underflow")
        }
        return tree
    }

    func attach(parentFirst: Bool, left: Bool) throws {
        let first = try pop()
        let second = try pop()
        let parent = parentFirst ? first : second
        let child = parentFirst ? second : first
        // A Hash node stands for a pruned subtree: its hash already covers its
        // children and ignores any attached, so it can't be a parent.
        if parent.node.type == .hash {
            throw VerificationError("A hash node can't have children")
        }
        if (left && parent.left != nil) || (!left && parent.right != nil) {
            throw VerificationError(left ? "Left child already attached" : "Right child already attached")
        }
        parent.attachWithHeight(isLeft: left, child: child.intoHash(), height: child.height)
        stack.append(parent)
    }

    while decoder.hasMore {
        guard let op = try decoder.next() else { break }

        switch op.type {
        case .push, .pushInverted:
            let node = op.node ?? MerkNode(type: .hash)
            let inverted = op.type == .pushInverted
            if let key = node.key, node.type != .hash, node.type != .kvHash {
                if let last = lastKey, lastInverted == inverted {
                    // Ascending across pushes, descending across inverted pushes.
                    let outOfOrder = inverted
                        ? !key.lexicographicallyPrecedes(last)
                        : (key.lexicographicallyPrecedes(last) || key == last)
                    if outOfOrder {
                        throw VerificationError(inverted ? "Incorrect key ordering inverted" : "Incorrect key ordering")
                    }
                }
                lastKey = key
                lastInverted = inverted

                switch node.type {
                case .kv:
                    resultSet.append(ProvedKeyValue(key: key, value: node.value, proofHash: valueHash(node.value ?? Data()), nodeType: .kv))
                case .kvDigest:
                    resultSet.append(ProvedKeyValue(key: key, value: nil, proofHash: node.valueHash, nodeType: .kvDigest))
                default:
                    resultSet.append(ProvedKeyValue(key: key, value: node.value, proofHash: node.valueHash, nodeType: node.type))
                }
            }
            stack.append(Tree(node: node))
        case .parent:
            try attach(parentFirst: true, left: true)
        case .child:
            try attach(parentFirst: false, left: false)
        case .parentInverted:
            try attach(parentFirst: true, left: false)
        case .childInverted:
            try attach(parentFirst: false, left: true)
        }
    }

    guard stack.count == 1 else {
        throw VerificationError("Expected proof to result in exactly one stack item, got \(stack.count)")
    }
    return MerkExecutionResult(rootHash: stack[0].hash(), resultSet: resultSet)
}

// MARK: - Proof Envelope

/// Reads the bincode 2 encoding grovedb writes a `GroveDBProof` in:
/// big-endian varint integers (a byte up to 250 is the value; 251, 252, and
/// 253 are followed by a 2-, 4-, or 8-byte value), length-prefixed byte
/// vectors, and one-byte bools.
private struct ProofReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var atEnd: Bool { return offset == bytes.count }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw VerificationError("Proof truncated") }
        offset += 1
        return bytes[offset - 1]
    }

    mutating func bool() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        case let tag: throw VerificationError("Invalid bool tag \(tag)")
        }
    }

    mutating func varint() throws -> UInt64 {
        let tag = try u8()
        let width: Int
        switch tag {
        case 0...250: return UInt64(tag)
        case 251: width = 2
        case 252: width = 4
        case 253: width = 8
        default: throw VerificationError("Unsupported varint tag \(tag)")
        }
        guard offset + width <= bytes.count else { throw VerificationError("Proof truncated (varint)") }
        let value = bytes[offset..<(offset + width)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        offset += width
        return value
    }

    mutating func byteVector() throws -> [UInt8] {
        let count = try varint()
        guard count <= UInt64(bytes.count - offset) else { throw VerificationError("Proof truncated (byte vector)") }
        let out = Array(bytes[offset..<(offset + Int(count))])
        offset += Int(count)
        return out
    }
}

/// Whether a serialized grovedb element is a tree (Tree, SumTree, BigSumTree,
/// CountTree, or CountSumTree) and its root key.
internal func groveTreeRootKey(_ element: Data) -> (isTree: Bool, rootKey: [UInt8]?) {
    var reader = ProofReader(element)
    guard let variant = try? reader.varint(), [2, 4, 5, 6, 7].contains(variant) else {
        return (false, nil)
    }
    guard let tag = try? reader.u8() else { return (false, nil) }
    if tag == 0 { return (true, nil) }
    guard tag == 1, let key = try? reader.byteVector() else { return (false, nil) }
    return (true, key)
}

// MARK: - GroveDB Verifier

/// Verifier for GroveDB proofs.
public class GroveDBVerifier {
    private var trustedRootHash: String?

    /// Lower layers nest at most this deep; a real path is a few segments.
    private static let maxLayerDepth = 64

    public init() {}

    /// Sets the trusted root hash.
    public func setTrustedRoot(_ rootHash: String) throws {
        guard rootHash.count == hashLength * 2 else {
            throw VerificationError("Invalid root hash length")
        }
        _ = try CryptoHash.fromHex(rootHash)
        trustedRootHash = rootHash
    }

    /// Verifies a proof against the trusted root.
    public func verify(proofBytes: Data) throws -> GroveDBVerificationResult {
        guard let expectedRootHash = trustedRootHash else {
            throw VerificationError("No trusted root hash set")
        }
        return try GroveDBVerifier.verifyProofAgainstRoot(proofBytes: proofBytes, expectedRootHash: expectedRootHash)
    }

    /// Decodes a GroveDB proof (only the V0 variant exists), refusing
    /// trailing bytes.
    public static func decodeGroveDBProof(_ proofBytes: Data) throws -> GroveDBProof {
        var reader = ProofReader(proofBytes)
        let version = try reader.varint()
        guard version == 0 else {
            throw VerificationError("Unsupported proof version: \(version)")
        }
        let rootLayer = try decodeLayerProof(&reader, depth: 0)
        let options = ProveOptions(decreaseLimitOnEmptySubQueryResult: try reader.bool())
        guard reader.atEnd else {
            throw VerificationError("Proof has \(reader.bytes.count - reader.offset) trailing bytes")
        }
        return GroveDBProof(version: 0, proof: GroveDBProofV0(rootLayer: rootLayer, proveOptions: options))
    }

    private static func decodeLayerProof(_ reader: inout ProofReader, depth: Int) throws -> LayerProof {
        guard depth <= maxLayerDepth else {
            throw VerificationError("Layer proof nesting too deep")
        }
        let merkProof = try reader.byteVector()
        let count = try reader.varint()
        var lowerLayers: [String: LayerProof] = [:]
        for _ in 0..<count {
            let key = try reader.byteVector()
            let keyHex = Data(key).hexString
            let nested = try decodeLayerProof(&reader, depth: depth + 1)
            guard lowerLayers.updateValue(nested, forKey: keyHex) == nil else {
                throw VerificationError("Proof repeats the lower layer \(keyHex)")
            }
        }
        return LayerProof(merkProof: Data(merkProof), lowerLayers: lowerLayers)
    }

    /// The check grovedb's own verifier does not make. The verifier finds the
    /// next layer by the envelope's `lowerLayers` map KEY, which is not
    /// hash-bound: a prover who renames or drops the entry for a subtree on the
    /// query path gets the same root hash with that subtree's results silently
    /// gone, so a proof of "K = V" verifies as "K is absent". Requiring a layer
    /// for every path segment closes it (once a layer is present its root is
    /// hash-bound to the parent). `proveOptions` is prover-chosen bytes that
    /// steer limit accounting, so it is pinned to the default the chain uses.
    public static func checkEnvelope(_ proof: GroveDBProof, expectedPath: [[UInt8]]) throws {
        guard proof.version == 0, let v0 = proof.proof, var layer = v0.rootLayer else {
            throw VerificationError("envelope: missing root layer")
        }
        guard v0.proveOptions.decreaseLimitOnEmptySubQueryResult else {
            throw VerificationError("envelope: non-default prove_options")
        }
        for (i, seg) in expectedPath.enumerated() {
            guard let next = layer.lowerLayers[Data(seg).hexString] else {
                throw VerificationError(
                    "envelope: no lower layer for path segment \(i); the proof does not descend to the query path")
            }
            layer = next
        }
        if !layer.lowerLayers.isEmpty {
            throw VerificationError("envelope: unexpected lower layers below the query path")
        }
    }

    /// Verify a proof and require it descends to `expectedPath` (see
    /// `checkEnvelope`). With the path known, an empty result set at that path
    /// is a proven absence rather than a possible omission.
    public static func verifyProof(proofBytes: Data, expectedPath: [[UInt8]]) throws -> GroveDBVerificationResult {
        let proof = try decodeGroveDBProof(proofBytes)
        try checkEnvelope(proof, expectedPath: expectedPath)
        var results: [GroveDBQueryResult] = []
        let rootHash = try verifyLayerProof(proof.proof?.rootLayer, currentPath: [], results: &results)
        return GroveDBVerificationResult(rootHash: rootHash.hexString, results: results)
    }

    /// `verifyProofAgainstRoot` plus the path descent check.
    public static func verifyProofAgainstRoot(proofBytes: Data, expectedRootHash: String, expectedPath: [[UInt8]]) throws -> GroveDBVerificationResult {
        let result = try verifyProof(proofBytes: proofBytes, expectedPath: expectedPath)
        if result.rootHash != expectedRootHash.lowercased() {
            throw VerificationError("Root hash mismatch: expected \(expectedRootHash), got \(result.rootHash)")
        }
        return result
    }

    /// Verifies a GroveDB proof and returns the root hash it hashes to and the
    /// values it proves. Use `verifyProof(proofBytes:expectedPath:)` whenever
    /// the query path is known.
    public static func verifyProof(proofBytes: Data) throws -> GroveDBVerificationResult {
        let proof = try decodeGroveDBProof(proofBytes)
        guard proof.proof?.proveOptions.decreaseLimitOnEmptySubQueryResult ?? false else {
            throw VerificationError("envelope: non-default prove_options")
        }
        var results: [GroveDBQueryResult] = []
        let rootHash = try verifyLayerProof(proof.proof?.rootLayer, currentPath: [], results: &results)
        return GroveDBVerificationResult(rootHash: rootHash.hexString, results: results)
    }

    /// Replays one layer, recursing into each lower layer the proof carries
    /// for a proven tree element: the element's value hash must be
    /// `combineHash(valueHash(element), lower layer's root)`. A leaf whose node
    /// carries a value hash must carry the value that hashes to it.
    private static func verifyLayerProof(_ layer: LayerProof?, currentPath: [[UInt8]], results: inout [GroveDBQueryResult]) throws -> CryptoHash {
        guard let layer = layer else {
            throw VerificationError("Missing layer proof")
        }
        let merkResult = try executeMerkProof(layer.merkProof)

        for proved in merkResult.resultSet {
            let keyHex = proved.key.hexString
            let path = currentPath + [[UInt8](proved.key)]

            if let lowerLayer = layer.lowerLayers[keyHex], let value = proved.value {
                let (isTree, rootKey) = groveTreeRootKey(value)
                guard isTree, let root = rootKey, !root.isEmpty else {
                    throw VerificationError("Proof has a lower layer for a non-tree element at key \(keyHex)")
                }
                let lowerHash = try verifyLayerProof(lowerLayer, currentPath: path, results: &results)
                let combinedHash = combineHash(valueHash(value), lowerHash)
                if combinedHash != proved.proofHash {
                    throw VerificationError("Lower layer hash mismatch at key \(keyHex): expected \(proved.proofHash.hexString), got \(combinedHash.hexString)")
                }
            } else if let value = proved.value {
                if proved.nodeType == .kvValueHash || proved.nodeType == .kvValueHashFeatureType {
                    let computed = valueHash(value)
                    if computed != proved.proofHash {
                        throw VerificationError("The value at key \(keyHex) does not hash to its committed value hash: expected \(proved.proofHash.hexString), got \(computed.hexString)")
                    }
                }
                results.append(GroveDBQueryResult(path: currentPath, key: proved.key, value: value))
            }
        }

        return merkResult.rootHash
    }

    /// Verifies a proof against an expected root hash.
    public static func verifyProofAgainstRoot(proofBytes: Data, expectedRootHash: String) throws -> GroveDBVerificationResult {
        let result = try verifyProof(proofBytes: proofBytes)
        if result.rootHash != expectedRootHash.lowercased() {
            throw VerificationError("Root hash mismatch: expected \(expectedRootHash), got \(result.rootHash)")
        }
        return result
    }

    /// Quickly verifies a proof and returns just the root hash.
    public static func quickVerify(proofBytes: Data) throws -> CryptoHash {
        let result = try verifyProof(proofBytes: proofBytes)
        return try CryptoHash.fromHex(result.rootHash)
    }
}
