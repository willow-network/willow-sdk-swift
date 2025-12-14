import Foundation
import CryptoKit

// MARK: - Constants

/// Length of a hash in bytes.
public let hashLength = 32

/// A null hash (all zeros).
public let nullHash = CryptoHash()

// MARK: - CryptoHash

/// A 32-byte cryptographic hash.
public struct CryptoHash: Equatable, Hashable {
    public var bytes: [UInt8]

    public init() {
        self.bytes = [UInt8](repeating: 0, count: hashLength)
    }

    public init(bytes: [UInt8]) {
        if bytes.count >= hashLength {
            self.bytes = Array(bytes.prefix(hashLength))
        } else {
            self.bytes = bytes + [UInt8](repeating: 0, count: hashLength - bytes.count)
        }
    }

    public init(data: Data) {
        self.init(bytes: [UInt8](data))
    }

    /// Returns the hex string representation.
    public var hexString: String {
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Checks if the hash is all zeros.
    public var isZero: Bool {
        return bytes.allSatisfy { $0 == 0 }
    }

    /// Creates a hash from a hex string.
    public static func fromHex(_ hex: String) throws -> CryptoHash {
        guard hex.count == hashLength * 2 else {
            throw ProofError("Invalid hash length: expected \(hashLength * 2) hex chars, got \(hex.count)")
        }

        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw ProofError("Invalid hex character in hash")
            }
            bytes.append(byte)
            index = nextIndex
        }

        return CryptoHash(bytes: bytes)
    }
}

// MARK: - Hash Functions

/// Computes SHA256 hash of data.
public func computeHash(_ data: Data) -> CryptoHash {
    let hash = SHA256.hash(data: data)
    return CryptoHash(bytes: Array(hash))
}

/// Computes SHA256 hash of bytes.
public func computeHash(_ bytes: [UInt8]) -> CryptoHash {
    return computeHash(Data(bytes))
}

/// Computes the value hash.
public func valueHash(_ value: Data) -> CryptoHash {
    return computeHash(value)
}

/// Computes the key-value hash.
public func kvHash(key: Data, value: Data) -> CryptoHash {
    var combined = [UInt8]()
    combined.append(contentsOf: key)
    combined.append(contentsOf: value)
    return computeHash(combined)
}

/// Computes the node hash from kv hash and child hashes.
public func computeNodeHash(kvHash: CryptoHash, leftHash: CryptoHash, rightHash: CryptoHash) -> CryptoHash {
    var combined = [UInt8]()
    combined.append(contentsOf: kvHash.bytes)
    combined.append(contentsOf: leftHash.bytes)
    combined.append(contentsOf: rightHash.bytes)
    return computeHash(combined)
}

/// Combines two hashes.
public func combineHash(_ a: CryptoHash, _ b: CryptoHash) -> CryptoHash {
    var combined = [UInt8]()
    combined.append(contentsOf: a.bytes)
    combined.append(contentsOf: b.bytes)
    return computeHash(combined)
}

// MARK: - Merk Node Types

/// Type of Merk node.
public enum MerkNodeType: Int {
    case hash = 0
    case kvHash = 1
    case kv = 2
    case kvValueHash = 3
    case kvDigest = 4
    case kvRefValueHash = 5
    case kvValueHashFeatureType = 6
}

/// Type of Merk operation.
public enum MerkOpType: Int {
    case push = 0
    case pushInverted = 1
    case parent = 2
    case child = 3
    case parentInverted = 4
    case childInverted = 5
}

// MARK: - Merk Node

/// A node in a Merk tree.
public struct MerkNode {
    public let type: MerkNodeType
    public var hash: CryptoHash
    public var kvHashVal: CryptoHash
    public var key: Data?
    public var value: Data?
    public var valueHash: CryptoHash

    public init(type: MerkNodeType, hash: CryptoHash = CryptoHash(), kvHashVal: CryptoHash = CryptoHash(), key: Data? = nil, value: Data? = nil, valueHash: CryptoHash = CryptoHash()) {
        self.type = type
        self.hash = hash
        self.kvHashVal = kvHashVal
        self.key = key
        self.value = value
        self.valueHash = valueHash
    }

    /// Creates a hash node.
    public static func hashNode(_ hash: CryptoHash) -> MerkNode {
        return MerkNode(type: .hash, hash: hash)
    }

    /// Creates a KV hash node.
    public static func kvHashNode(_ kvHash: CryptoHash) -> MerkNode {
        return MerkNode(type: .kvHash, kvHashVal: kvHash)
    }

    /// Creates a KV node.
    public static func kvNode(key: Data, value: Data) -> MerkNode {
        return MerkNode(type: .kv, key: key, value: value)
    }
}

// MARK: - Merk Operation

/// An operation in a Merk proof.
public struct MerkOp {
    public let type: MerkOpType
    public let node: MerkNode?

    public init(type: MerkOpType, node: MerkNode? = nil) {
        self.type = type
        self.node = node
    }
}

// MARK: - Element Types

/// Type of element in GroveDB.
public enum ElementType: Int {
    case item = 0
    case reference = 1
    case tree = 2
    case sumTree = 3
    case sumItem = 4
    case bigSumTree = 5
    case countTree = 6
    case countSumTree = 7
}

/// An element in GroveDB.
public struct Element {
    public let type: ElementType
    public var value: Data?
    public var rootKey: Data?

    public init(type: ElementType, value: Data? = nil, rootKey: Data? = nil) {
        self.type = type
        self.value = value
        self.rootKey = rootKey
    }

    /// Returns true if this element is a tree type.
    public var isTree: Bool {
        switch type {
        case .tree, .sumTree, .bigSumTree, .countTree, .countSumTree:
            return true
        default:
            return false
        }
    }

    /// Returns true if this tree element has a root key.
    public var hasRootKey: Bool {
        return isTree && rootKey != nil && !rootKey!.isEmpty
    }
}

// MARK: - Proof Types

/// A proved key-value pair.
public struct ProvedKeyValue {
    public let key: Data
    public let value: Data?
    public let proofHash: CryptoHash

    public init(key: Data, value: Data?, proofHash: CryptoHash) {
        self.key = key
        self.value = value
        self.proofHash = proofHash
    }
}

/// A layer proof in GroveDB.
public class LayerProof {
    public var merkProof: Data
    public var lowerLayers: [String: LayerProof]

    public init(merkProof: Data = Data(), lowerLayers: [String: LayerProof] = [:]) {
        self.merkProof = merkProof
        self.lowerLayers = lowerLayers
    }
}

/// Prove options.
public struct ProveOptions {
    public var decreaseLimitOnEmptySubQueryResult: Bool

    public init(decreaseLimitOnEmptySubQueryResult: Bool = false) {
        self.decreaseLimitOnEmptySubQueryResult = decreaseLimitOnEmptySubQueryResult
    }
}

/// GroveDB proof version 0.
public class GroveDBProofV0 {
    public var rootLayer: LayerProof?
    public var proveOptions: ProveOptions

    public init(rootLayer: LayerProof? = nil, proveOptions: ProveOptions = ProveOptions()) {
        self.rootLayer = rootLayer
        self.proveOptions = proveOptions
    }
}

/// A GroveDB proof.
public class GroveDBProof {
    public var version: Int
    public var proof: GroveDBProofV0?

    public init(version: Int = 0, proof: GroveDBProofV0? = nil) {
        self.version = version
        self.proof = proof
    }
}

// MARK: - Query Result

/// Result of a query.
public struct GroveDBQueryResult {
    public let path: [[UInt8]]
    public let key: Data
    public let value: Data

    public init(path: [[UInt8]], key: Data, value: Data) {
        self.path = path
        self.key = key
        self.value = value
    }
}

// MARK: - Verification Result

/// Result of proof verification.
public struct GroveDBVerificationResult {
    public let rootHash: String
    public let results: [GroveDBQueryResult]

    public init(rootHash: String, results: [GroveDBQueryResult]) {
        self.rootHash = rootHash
        self.results = results
    }
}

// MARK: - Verification Error

/// Error during proof verification.
public struct VerificationError: Error, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        return message
    }
}
