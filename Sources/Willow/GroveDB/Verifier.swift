import Foundation

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

/// A node in the Merk AVL tree.
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

    /// Computes the hash of this tree node.
    public func hash() -> CryptoHash {
        // Get KV hash based on node type
        var kvHashVal: CryptoHash

        switch node.type {
        case .hash:
            return node.hash
        case .kvHash:
            kvHashVal = node.kvHashVal
        case .kv:
            if let key = node.key, let value = node.value {
                kvHashVal = kvHash(key: key, value: value)
            } else {
                kvHashVal = nullHash
            }
        case .kvValueHash, .kvRefValueHash, .kvValueHashFeatureType:
            if let key = node.key {
                var combined = [UInt8]()
                combined.append(contentsOf: key)
                combined.append(contentsOf: node.valueHash.bytes)
                kvHashVal = computeHash(combined)
            } else {
                kvHashVal = nullHash
            }
        case .kvDigest:
            if let key = node.key {
                var combined = [UInt8]()
                combined.append(contentsOf: key)
                combined.append(contentsOf: node.valueHash.bytes)
                kvHashVal = computeHash(combined)
            } else {
                kvHashVal = nullHash
            }
        }

        // Get child hashes
        let leftHash = left?.hash() ?? nullHash
        let rightHash = right?.hash() ?? nullHash

        return computeNodeHash(kvHash: kvHashVal, leftHash: leftHash, rightHash: rightHash)
    }

    /// Converts this tree to a hash-only tree.
    public func intoHash() -> Tree {
        let h = hash()
        let newTree = Tree(node: MerkNode.hashNode(h))
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

/// Decodes Merk proof operations from bytes.
public class MerkDecoder {
    private let data: Data
    private var offset: Int = 0

    public init(_ data: Data) {
        self.data = data
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
        // Push variants
        case opPushHash:
            let node = try decodeHash()
            return MerkOp(type: .push, node: node)
        case opPushKVHash:
            let node = try decodeKVHash()
            return MerkOp(type: .push, node: node)
        case opPushKV:
            let node = try decodeKV()
            return MerkOp(type: .push, node: node)
        case opPushKVValueHash:
            let node = try decodeKVValueHash()
            return MerkOp(type: .push, node: node)
        case opPushKVDigest:
            let node = try decodeKVDigest()
            return MerkOp(type: .push, node: node)
        case opPushKVRefValueHash:
            let node = try decodeKVRefValueHash()
            return MerkOp(type: .push, node: node)

        // Push inverted variants
        case opPushInvertedHash:
            let node = try decodeHash()
            return MerkOp(type: .pushInverted, node: node)
        case opPushInvertedKVHash:
            let node = try decodeKVHash()
            return MerkOp(type: .pushInverted, node: node)
        case opPushInvertedKV:
            let node = try decodeKV()
            return MerkOp(type: .pushInverted, node: node)
        case opPushInvertedKVValueHash:
            let node = try decodeKVValueHash()
            return MerkOp(type: .pushInverted, node: node)
        case opPushInvertedKVDigest:
            let node = try decodeKVDigest()
            return MerkOp(type: .pushInverted, node: node)
        case opPushInvertedKVRefValueHash:
            let node = try decodeKVRefValueHash()
            return MerkOp(type: .pushInverted, node: node)

        // Tree operations
        case opParent:
            return MerkOp(type: .parent)
        case opChild:
            return MerkOp(type: .child)
        case opParentInverted:
            return MerkOp(type: .parentInverted)
        case opChildInverted:
            return MerkOp(type: .childInverted)

        default:
            throw VerificationError("Unknown op code: 0x\(String(format: "%02x", opCode))")
        }
    }

    private func decodeHash() throws -> MerkNode {
        let hashData = try readBytes(hashLength)
        return MerkNode.hashNode(CryptoHash(data: hashData))
    }

    private func decodeKVHash() throws -> MerkNode {
        let hashData = try readBytes(hashLength)
        return MerkNode.kvHashNode(CryptoHash(data: hashData))
    }

    private func decodeKV() throws -> MerkNode {
        guard offset < data.count else {
            throw VerificationError("Unexpected end of data reading key length")
        }
        let keyLen = Int(data[offset])
        offset += 1

        let key = try readBytes(keyLen)
        let valueLen = try readU16()
        let value = try readBytes(Int(valueLen))

        return MerkNode.kvNode(key: key, value: value)
    }

    private func decodeKVValueHash() throws -> MerkNode {
        guard offset < data.count else {
            throw VerificationError("Unexpected end of data reading key length")
        }
        let keyLen = Int(data[offset])
        offset += 1

        let key = try readBytes(keyLen)
        let valueLen = try readU16()
        let value = try readBytes(Int(valueLen))
        let valueHashData = try readBytes(hashLength)

        return MerkNode(type: .kvValueHash, key: key, value: value, valueHash: CryptoHash(data: valueHashData))
    }

    private func decodeKVDigest() throws -> MerkNode {
        guard offset < data.count else {
            throw VerificationError("Unexpected end of data reading key length")
        }
        let keyLen = Int(data[offset])
        offset += 1

        let key = try readBytes(keyLen)
        let valueHashData = try readBytes(hashLength)

        return MerkNode(type: .kvDigest, key: key, valueHash: CryptoHash(data: valueHashData))
    }

    private func decodeKVRefValueHash() throws -> MerkNode {
        guard offset < data.count else {
            throw VerificationError("Unexpected end of data reading key length")
        }
        let keyLen = Int(data[offset])
        offset += 1

        let key = try readBytes(keyLen)
        let valueLen = try readU16()
        let value = try readBytes(Int(valueLen))
        let valueHashData = try readBytes(hashLength)

        return MerkNode(type: .kvRefValueHash, key: key, value: value, valueHash: CryptoHash(data: valueHashData))
    }

    private func readU16() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw VerificationError("Unexpected end of data reading u16")
        }
        // Big-endian u16
        let value = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2
        return value
    }

    private func readBytes(_ n: Int) throws -> Data {
        guard offset + n <= data.count else {
            throw VerificationError("Unexpected end of data reading \(n) bytes")
        }
        let result = data.subdata(in: offset..<(offset + n))
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

/// Executes a Merk proof and returns the result.
public func executeMerkProof(_ proofBytes: Data) throws -> MerkExecutionResult {
    let decoder = MerkDecoder(proofBytes)
    var stack: [Tree] = []
    var resultSet: [ProvedKeyValue] = []

    while decoder.hasMore {
        guard let op = try decoder.next() else { break }

        switch op.type {
        case .push, .pushInverted:
            // Collect key-value pairs
            if let node = op.node {
                switch node.type {
                case .kv:
                    if let key = node.key, let value = node.value {
                        resultSet.append(ProvedKeyValue(
                            key: key,
                            value: value,
                            proofHash: valueHash(value)
                        ))
                    }
                case .kvValueHash, .kvRefValueHash, .kvValueHashFeatureType:
                    if let key = node.key {
                        resultSet.append(ProvedKeyValue(
                            key: key,
                            value: node.value,
                            proofHash: node.valueHash
                        ))
                    }
                case .kvDigest:
                    if let key = node.key {
                        resultSet.append(ProvedKeyValue(
                            key: key,
                            value: nil,
                            proofHash: node.valueHash
                        ))
                    }
                default:
                    break
                }
            }
            stack.append(Tree(node: op.node ?? MerkNode(type: .hash)))

        case .parent:
            // Pop parent and child, attach child as LEFT of parent
            guard stack.count >= 2 else {
                throw VerificationError("Stack underflow on Parent")
            }
            let parent = stack.removeLast()
            let child = stack.removeLast()

            let childHeight = child.height
            let childHash = child.intoHash()
            parent.attachWithHeight(isLeft: true, child: childHash, height: childHeight)
            stack.append(parent)

        case .child:
            // Pop child and parent, attach child as RIGHT of parent
            guard stack.count >= 2 else {
                throw VerificationError("Stack underflow on Child")
            }
            let child = stack.removeLast()
            let parent = stack.removeLast()

            let childHeight = child.height
            let childHash = child.intoHash()
            parent.attachWithHeight(isLeft: false, child: childHash, height: childHeight)
            stack.append(parent)

        case .parentInverted:
            // Pop parent and child, attach child as RIGHT of parent
            guard stack.count >= 2 else {
                throw VerificationError("Stack underflow on ParentInverted")
            }
            let parent = stack.removeLast()
            let child = stack.removeLast()

            let childHeight = child.height
            let childHash = child.intoHash()
            parent.attachWithHeight(isLeft: false, child: childHash, height: childHeight)
            stack.append(parent)

        case .childInverted:
            // Pop child and parent, attach child as LEFT of parent
            guard stack.count >= 2 else {
                throw VerificationError("Stack underflow on ChildInverted")
            }
            let child = stack.removeLast()
            let parent = stack.removeLast()

            let childHeight = child.height
            let childHash = child.intoHash()
            parent.attachWithHeight(isLeft: true, child: childHash, height: childHeight)
            stack.append(parent)
        }
    }

    guard stack.count == 1 else {
        throw VerificationError("Expected proof to result in exactly one stack item, got \(stack.count)")
    }

    let tree = stack[0]

    // Verify AVL tree property
    let heightDiff = abs(tree.childHeights.left - tree.childHeights.right)
    if heightDiff > 1 {
        throw VerificationError("Expected proof to result in a valid AVL tree")
    }

    return MerkExecutionResult(rootHash: tree.hash(), resultSet: resultSet)
}

// MARK: - GroveDB Verifier

/// Verifier for GroveDB proofs.
public class GroveDBVerifier {
    private var trustedRootHash: String?

    public init() {}

    /// Sets the trusted root hash.
    public func setTrustedRoot(_ rootHash: String) throws {
        guard rootHash.count == hashLength * 2 else {
            throw VerificationError("Invalid root hash length")
        }
        // Validate hex format
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

    /// Decodes a GroveDB proof from bytes.
    public static func decodeGroveDBProof(_ proofBytes: Data) throws -> GroveDBProof {
        guard proofBytes.count >= 4 else {
            throw VerificationError("Proof too short")
        }

        // Version is first 4 bytes (little-endian u32)
        let version = UInt32(proofBytes[0]) |
                      UInt32(proofBytes[1]) << 8 |
                      UInt32(proofBytes[2]) << 16 |
                      UInt32(proofBytes[3]) << 24

        guard version == 0 else {
            throw VerificationError("Unsupported proof version: \(version)")
        }

        let (rootLayer, remaining) = try decodeLayerProof(proofBytes.subdata(in: 4..<proofBytes.count))

        var proveOptions = ProveOptions()
        if remaining.count >= 1 {
            proveOptions.decreaseLimitOnEmptySubQueryResult = remaining[0] != 0
        }

        return GroveDBProof(
            version: Int(version),
            proof: GroveDBProofV0(rootLayer: rootLayer, proveOptions: proveOptions)
        )
    }

    private static func decodeLayerProof(_ data: Data) throws -> (LayerProof, Data) {
        guard data.count >= 4 else {
            throw VerificationError("Layer proof too short")
        }

        // Merk proof length (little-endian u32)
        let merkProofLen = Int(UInt32(data[0]) |
                               UInt32(data[1]) << 8 |
                               UInt32(data[2]) << 16 |
                               UInt32(data[3]) << 24)
        var offset = 4

        guard data.count >= offset + merkProofLen else {
            throw VerificationError("Incomplete merk proof data")
        }

        let merkProof = data.subdata(in: offset..<(offset + merkProofLen))
        offset += merkProofLen

        var lowerLayers: [String: LayerProof] = [:]

        // Check if there are lower layers
        if data.count >= offset + 4 {
            let lowerLayersCount = Int(UInt32(data[offset]) |
                                       UInt32(data[offset + 1]) << 8 |
                                       UInt32(data[offset + 2]) << 16 |
                                       UInt32(data[offset + 3]) << 24)
            offset += 4

            for _ in 0..<lowerLayersCount {
                guard data.count >= offset + 4 else { break }

                // Key length
                let keyLen = Int(UInt32(data[offset]) |
                                 UInt32(data[offset + 1]) << 8 |
                                 UInt32(data[offset + 2]) << 16 |
                                 UInt32(data[offset + 3]) << 24)
                offset += 4

                guard data.count >= offset + keyLen else { break }

                // Key
                let key = data.subdata(in: offset..<(offset + keyLen))
                offset += keyLen

                // Nested layer proof
                let (nestedProof, remaining) = try decodeLayerProof(data.subdata(in: offset..<data.count))
                offset = data.count - remaining.count

                let keyHex = key.map { String(format: "%02x", $0) }.joined()
                lowerLayers[keyHex] = nestedProof
            }
        }

        let layerProof = LayerProof(merkProof: merkProof, lowerLayers: lowerLayers)
        return (layerProof, data.subdata(in: offset..<data.count))
    }

    /// Verifies a GroveDB proof and returns the verification result.
    public static func verifyProof(proofBytes: Data) throws -> GroveDBVerificationResult {
        let proof = try decodeGroveDBProof(proofBytes)

        var results: [GroveDBQueryResult] = []
        let rootHash = try verifyLayerProof(proof.proof?.rootLayer, currentPath: [], results: &results)

        return GroveDBVerificationResult(rootHash: rootHash.hexString, results: results)
    }

    private static func verifyLayerProof(_ layer: LayerProof?, currentPath: [[UInt8]], results: inout [GroveDBQueryResult]) throws -> CryptoHash {
        guard let layer = layer else {
            throw VerificationError("Missing layer proof")
        }

        // Execute the Merk proof
        let merkResult = try executeMerkProof(layer.merkProof)

        // Process each proven value
        for proved in merkResult.resultSet {
            let keyHex = proved.key.map { String(format: "%02x", $0) }.joined()
            let lowerLayer = layer.lowerLayers[keyHex]

            if let lowerLayer = lowerLayer, let value = proved.value {
                // This is a subtree - verify the lower layer
                var newPath = currentPath
                newPath.append([UInt8](proved.key))
                let lowerHash = try verifyLayerProof(lowerLayer, currentPath: newPath, results: &results)

                // Verify the combined hash
                let elementValueHash = valueHash(value)
                let combinedHash = combineHash(elementValueHash, lowerHash)

                if combinedHash != proved.proofHash {
                    throw VerificationError("Lower layer hash mismatch at key \(keyHex): expected \(proved.proofHash.hexString), got \(combinedHash.hexString)")
                }
            } else if let value = proved.value {
                // Leaf value - add to results
                results.append(GroveDBQueryResult(
                    path: currentPath,
                    key: proved.key,
                    value: value
                ))
            }
        }

        return merkResult.rootHash
    }

    /// Verifies a proof against an expected root hash.
    public static func verifyProofAgainstRoot(proofBytes: Data, expectedRootHash: String) throws -> GroveDBVerificationResult {
        let result = try verifyProof(proofBytes: proofBytes)

        if result.rootHash != expectedRootHash {
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
