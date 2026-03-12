import Foundation
import CryptoKit
import Security

// MARK: - Constants

private let defaultChunkSize = 262_144 // 256 KB

// MARK: - File Manifest

/// File manifest metadata stored on-chain.
public struct FileManifest: Codable {
    public let fileKey: String
    public let filename: String
    public let contentType: String
    public let totalSize: UInt64
    public let contentHash: String
    public let chunkCount: UInt32
    public let chunkSize: UInt32
    public let chunkMerkleRoot: String
    public let ownerDid: String
    public let createdAt: UInt64
    public let updatedAt: UInt64
    public let encrypted: Bool
    public let storageNodes: [String]

    enum CodingKeys: String, CodingKey {
        case fileKey = "file_key"
        case filename
        case contentType = "content_type"
        case totalSize = "total_size"
        case contentHash = "content_hash"
        case chunkCount = "chunk_count"
        case chunkSize = "chunk_size"
        case chunkMerkleRoot = "chunk_merkle_root"
        case ownerDid = "owner_did"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case encrypted
        case storageNodes = "storage_nodes"
    }
}

/// Response for listing files.
struct FileListResponse: Codable {
    let files: [FileManifest]
}

// MARK: - Signing Options

/// Options for signing file storage transactions.
public struct FileSigningOptions {
    public let ownerDid: String
    public let privateKey: Data
    public let publicKeyId: String
    public let signFunction: (Data, Data) throws -> Data
    public let nonce: Int

    public init(ownerDid: String, privateKey: Data, publicKeyId: String, signFunction: @escaping (Data, Data) throws -> Data, nonce: Int) {
        self.ownerDid = ownerDid
        self.privateKey = privateKey
        self.publicKeyId = publicKeyId
        self.signFunction = signFunction
        self.nonce = nonce
    }
}

// MARK: - File Operations

/// Provides file storage operations.
public class FileOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    /// Upload a file to a FileStorage subgrove.
    public func upload(
        appId: String,
        subgroveId: String,
        fileKey: String,
        filename: String,
        data: Data,
        storageNodeEndpoint: String,
        signing: FileSigningOptions? = nil
    ) async throws -> FileManifest {
        let chunkSize = defaultChunkSize
        let chunks = chunkData(data, chunkSize: chunkSize)
        let chunkCount = chunks.count

        let contentHash = SHA256.hash(data: data)
        let contentHashHex = contentHash.map { String(format: "%02x", $0) }.joined()

        let chunkHashes = chunks.map { Data(SHA256.hash(data: $0)) }
        let merkleRoot = computeMerkleRoot(chunkHashes)
        let merkleRootHex = merkleRoot.map { String(format: "%02x", $0) }.joined()

        // Build signature fields
        let ownerDid: String
        let signatureBytes: [Int]
        let publicKeyId: String
        let nonce: Int

        if let signing = signing {
            ownerDid = signing.ownerDid
            publicKeyId = signing.publicKeyId
            nonce = signing.nonce

            let signMessage = "store_file:\(appId):\(subgroveId):\(fileKey):\(contentHashHex):\(data.count)"
            let signatureData = try signing.signFunction(Data(signMessage.utf8), signing.privateKey)
            signatureBytes = Array(signatureData).map { Int($0) }
        } else {
            ownerDid = ""
            signatureBytes = []
            publicKeyId = ""
            nonce = 0
        }

        // Submit StoreFileManifestTx to consensus
        guard let client = client else { throw NetworkError("Client deallocated") }
        let manifestTx = StoreFileManifestTx(
            StoreFileManifest: StoreFileManifestTxBody(
                app_id: appId,
                subgrove_id: subgroveId,
                file_key: fileKey,
                filename: filename,
                content_type: guessContentType(filename),
                total_size: data.count,
                content_hash: contentHashHex,
                chunk_count: chunkCount,
                chunk_size: chunkSize,
                chunk_merkle_root: merkleRootHex,
                owner_did: ownerDid,
                signature: signatureBytes,
                public_key_id: publicKeyId,
                nonce: nonce
            )
        )
        let _: BroadcastResponse = try await client.post(path: "/broadcast_tx", body: manifestTx)

        // Upload chunks to storage node
        for (i, chunk) in chunks.enumerated() {
            let url = URL(string: "\(storageNodeEndpoint)/upload/\(appId)/\(subgroveId)/\(fileKey)?chunk_index=\(i)&chunk_count=\(chunkCount)&content_hash=\(contentHashHex)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = chunk

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NetworkError("Failed to upload chunk \(i)")
            }
        }

        return FileManifest(
            fileKey: fileKey,
            filename: filename,
            contentType: guessContentType(filename),
            totalSize: UInt64(data.count),
            contentHash: contentHashHex,
            chunkCount: UInt32(chunkCount),
            chunkSize: UInt32(chunkSize),
            chunkMerkleRoot: merkleRootHex,
            ownerDid: ownerDid,
            createdAt: 0,
            updatedAt: 0,
            encrypted: false,
            storageNodes: [storageNodeEndpoint]
        )
    }

    /// Download a file from a FileStorage subgrove.
    public func download(
        appId: String,
        subgroveId: String,
        fileKey: String,
        storageNodeEndpoint: String
    ) async throws -> Data {
        let manifest = try await metadata(appId: appId, subgroveId: subgroveId, fileKey: fileKey)

        var fileData = Data()
        var chunkHashes: [Data] = []
        for i in 0..<manifest.chunkCount {
            let url = URL(string: "\(storageNodeEndpoint)/chunk/\(appId)/\(subgroveId)/\(fileKey)/\(i)?content_hash=\(manifest.contentHash)")!
            let (chunkData, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NetworkError("Failed to download chunk \(i)")
            }
            chunkHashes.append(Data(SHA256.hash(data: chunkData)))
            fileData.append(chunkData)
        }

        // Verify chunk Merkle root
        let computedMerkleRoot = computeMerkleRoot(chunkHashes)
        let computedMerkleRootHex = computedMerkleRoot.map { String(format: "%02x", $0) }.joined()
        guard computedMerkleRootHex == manifest.chunkMerkleRoot else {
            throw ValidationError("Chunk Merkle root mismatch")
        }

        // Verify content hash
        let computedHash = SHA256.hash(data: fileData)
        let computedHashHex = computedHash.map { String(format: "%02x", $0) }.joined()
        guard computedHashHex == manifest.contentHash else {
            throw ValidationError("Content hash mismatch")
        }

        return fileData
    }

    /// Get file manifest metadata.
    public func metadata(appId: String, subgroveId: String, fileKey: String) async throws -> FileManifest {
        guard let client = client else { throw NetworkError("Client deallocated") }
        let path = "/files/\(appId)/\(subgroveId)/\(fileKey)"
        return try await client.get(path: path)
    }

    /// List all files in a subgrove.
    public func list(appId: String, subgroveId: String) async throws -> [FileManifest] {
        guard let client = client else { throw NetworkError("Client deallocated") }
        let path = "/files/\(appId)/\(subgroveId)"
        let response: FileListResponse = try await client.get(path: path)
        return response.files
    }

    /// Delete a file (submits DeleteFileManifestTx to consensus).
    public func delete(appId: String, subgroveId: String, fileKey: String, signing: FileSigningOptions? = nil) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let ownerDid: String
        let signatureBytes: [Int]
        let publicKeyId: String
        let nonce: Int

        if let signing = signing {
            ownerDid = signing.ownerDid
            publicKeyId = signing.publicKeyId
            nonce = signing.nonce

            let signMessage = "delete_file:\(appId):\(subgroveId):\(fileKey)"
            let signatureData = try signing.signFunction(Data(signMessage.utf8), signing.privateKey)
            signatureBytes = Array(signatureData).map { Int($0) }
        } else {
            ownerDid = ""
            signatureBytes = []
            publicKeyId = ""
            nonce = 0
        }

        let deleteTx = DeleteFileManifestTx(
            DeleteFileManifest: DeleteFileManifestTxBody(
                app_id: appId,
                subgrove_id: subgroveId,
                file_key: fileKey,
                owner_did: ownerDid,
                signature: signatureBytes,
                public_key_id: publicKeyId,
                nonce: nonce
            )
        )
        let _: BroadcastResponse = try await client.post(path: "/broadcast_tx", body: deleteTx)
    }

    /// Unregister a storage node (submits UnregisterStorageNode to consensus).
    public func unregisterStorageNode(nodeDid: String, signing: FileSigningOptions) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let signMessage = "unregister_storage_node:\(nodeDid)"
        let signatureData = try signing.signFunction(Data(signMessage.utf8), signing.privateKey)
        let signatureBytes = Array(signatureData).map { Int($0) }

        let tx = UnregisterStorageNodeTx(
            UnregisterStorageNode: UnregisterStorageNodeTxBody(
                node_did: nodeDid,
                signature: signatureBytes,
                public_key_id: signing.publicKeyId,
                nonce: signing.nonce
            )
        )
        let _: BroadcastResponse = try await client.post(path: "/broadcast_tx", body: tx)
    }
}

// MARK: - Transaction Types

private struct StoreFileManifestTxBody: Encodable {
    let app_id: String
    let subgrove_id: String
    let file_key: String
    let filename: String
    let content_type: String
    let total_size: Int
    let content_hash: String
    let chunk_count: Int
    let chunk_size: Int
    let chunk_merkle_root: String
    let owner_did: String
    let signature: [Int]
    let public_key_id: String
    let nonce: Int
}

private struct StoreFileManifestTx: Encodable {
    let StoreFileManifest: StoreFileManifestTxBody
}

private struct DeleteFileManifestTxBody: Encodable {
    let app_id: String
    let subgrove_id: String
    let file_key: String
    let owner_did: String
    let signature: [Int]
    let public_key_id: String
    let nonce: Int
}

private struct DeleteFileManifestTx: Encodable {
    let DeleteFileManifest: DeleteFileManifestTxBody
}

private struct UnregisterStorageNodeTxBody: Encodable {
    let node_did: String
    let signature: [Int]
    let public_key_id: String
    let nonce: Int
}

private struct UnregisterStorageNodeTx: Encodable {
    let UnregisterStorageNode: UnregisterStorageNodeTxBody
}

private struct BroadcastResponse: Decodable {}

// MARK: - Helpers

private func chunkData(_ data: Data, chunkSize: Int) -> [Data] {
    var chunks: [Data] = []
    var offset = 0
    while offset < data.count {
        let end = min(offset + chunkSize, data.count)
        chunks.append(data[offset..<end])
        offset = end
    }
    return chunks
}

private func computeMerkleRoot(_ hashes: [Data]) -> Data {
    if hashes.isEmpty { return Data(repeating: 0, count: 32) }
    // No early return for single-leaf: pad to [leaf, leaf] and hash.
    // This prevents availability proof forgery for single-chunk files.

    var current = hashes
    if current.count == 1 {
        current.append(current[0])
    }
    while current.count > 1 {
        if current.count % 2 != 0 {
            current.append(current.last!)
        }
        var next: [Data] = []
        for i in stride(from: 0, to: current.count, by: 2) {
            var combined = current[i]
            combined.append(current[i + 1])
            next.append(Data(SHA256.hash(data: combined)))
        }
        current = next
    }
    return current[0]
}

// MARK: - Encryption

/// Encrypt file data using XChaCha20-Poly1305.
///
/// Uses XChaCha20-Poly1305 with a 24-byte nonce to match the Rust SDK and
/// consensus layer. Files encrypted with this function are interoperable
/// across all Willow SDKs.
///
/// - Parameters:
///   - data: Plaintext file data
///   - key: 32-byte symmetric key from the subgrove key grant system
/// - Returns: Tuple of (ciphertext with auth tag, 24-byte nonce)
///
/// Note: Swift CryptoKit provides ChaChaPoly (IETF ChaCha20-Poly1305, 12-byte nonce)
/// but not XChaCha20-Poly1305. This implementation derives a subkey using HChaCha20
/// and then uses ChaChaPoly with the derived key and last 12 bytes of the nonce,
/// matching the XChaCha20 construction (RFC draft-irtf-cfrg-xchacha).
public func encryptFile(data: Data, key: Data) throws -> (ciphertext: Data, nonce: Data) {
    guard key.count == 32 else {
        throw ValidationError("Key must be 32 bytes")
    }

    // Generate 24-byte nonce
    var nonceBytes = Data(count: 24)
    nonceBytes.withUnsafeMutableBytes { ptr in
        _ = SecRandomCopyBytes(kSecRandomDefault, 24, ptr.baseAddress!)
    }

    let ciphertext = try xchacha20Poly1305Encrypt(data: data, key: key, nonce: nonceBytes)
    return (ciphertext, nonceBytes)
}

/// Decrypt file data using XChaCha20-Poly1305.
///
/// - Parameters:
///   - ciphertext: Encrypted data (includes 16-byte auth tag)
///   - key: 32-byte symmetric key
///   - nonce: 24-byte nonce used during encryption
/// - Returns: Decrypted plaintext
public func decryptFile(ciphertext: Data, key: Data, nonce: Data) throws -> Data {
    guard key.count == 32 else {
        throw ValidationError("Key must be 32 bytes")
    }
    guard nonce.count == 24 else {
        throw ValidationError("Nonce must be 24 bytes")
    }

    return try xchacha20Poly1305Decrypt(ciphertext: ciphertext, key: key, nonce: nonce)
}

/// XChaCha20-Poly1305 encrypt using HChaCha20 subkey derivation + ChaChaPoly.
private func xchacha20Poly1305Encrypt(data: Data, key: Data, nonce: Data) throws -> Data {
    let subkey = hchacha20(key: key, input: Data(nonce[0..<16]))
    var subNonce = Data(repeating: 0, count: 12)
    subNonce[4..<12] = nonce[16..<24]
    let sealedBox = try ChaChaPoly.seal(data, using: SymmetricKey(data: subkey), nonce: ChaChaPoly.Nonce(data: subNonce))
    return sealedBox.ciphertext + sealedBox.tag
}

/// XChaCha20-Poly1305 decrypt using HChaCha20 subkey derivation + ChaChaPoly.
private func xchacha20Poly1305Decrypt(ciphertext: Data, key: Data, nonce: Data) throws -> Data {
    let subkey = hchacha20(key: key, input: Data(nonce[0..<16]))
    var subNonce = Data(repeating: 0, count: 12)
    subNonce[4..<12] = nonce[16..<24]
    let tag = ciphertext.suffix(16)
    let encrypted = ciphertext.dropLast(16)
    let sealedBox = try ChaChaPoly.SealedBox(
        nonce: ChaChaPoly.Nonce(data: subNonce),
        ciphertext: encrypted,
        tag: tag
    )
    return try ChaChaPoly.open(sealedBox, using: SymmetricKey(data: subkey))
}

/// HChaCha20: derive a 256-bit subkey from a 256-bit key and 128-bit input.
/// This is the core of the XChaCha20 construction.
private func hchacha20(key: Data, input: Data) -> Data {
    // ChaCha quarter round
    func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[a] = state[a] &+ state[b]; state[d] ^= state[a]; state[d] = (state[d] << 16) | (state[d] >> 16)
        state[c] = state[c] &+ state[d]; state[b] ^= state[c]; state[b] = (state[b] << 12) | (state[b] >> 20)
        state[a] = state[a] &+ state[b]; state[d] ^= state[a]; state[d] = (state[d] << 8) | (state[d] >> 24)
        state[c] = state[c] &+ state[d]; state[b] ^= state[c]; state[b] = (state[b] << 7) | (state[b] >> 25)
    }

    func loadLE32(_ data: Data, _ offset: Int) -> UInt32 {
        return UInt32(data[offset]) | (UInt32(data[offset+1]) << 8) |
               (UInt32(data[offset+2]) << 16) | (UInt32(data[offset+3]) << 24)
    }

    // Initialize state: "expand 32-byte k" constants + key + input
    var state: [UInt32] = [
        0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,  // sigma
        loadLE32(key, 0), loadLE32(key, 4), loadLE32(key, 8), loadLE32(key, 12),
        loadLE32(key, 16), loadLE32(key, 20), loadLE32(key, 24), loadLE32(key, 28),
        loadLE32(input, 0), loadLE32(input, 4), loadLE32(input, 8), loadLE32(input, 12),
    ]

    // 20 rounds (10 double rounds)
    for _ in 0..<10 {
        quarterRound(&state, 0, 4, 8, 12)
        quarterRound(&state, 1, 5, 9, 13)
        quarterRound(&state, 2, 6, 10, 14)
        quarterRound(&state, 3, 7, 11, 15)
        quarterRound(&state, 0, 5, 10, 15)
        quarterRound(&state, 1, 6, 11, 12)
        quarterRound(&state, 2, 7, 8, 13)
        quarterRound(&state, 3, 4, 9, 14)
    }

    // Output: first 4 and last 4 words
    var result = Data(count: 32)
    for i in 0..<4 {
        let v = state[i]
        result[i*4] = UInt8(v & 0xff); result[i*4+1] = UInt8((v >> 8) & 0xff)
        result[i*4+2] = UInt8((v >> 16) & 0xff); result[i*4+3] = UInt8((v >> 24) & 0xff)
    }
    for i in 0..<4 {
        let v = state[12 + i]
        result[16 + i*4] = UInt8(v & 0xff); result[16 + i*4+1] = UInt8((v >> 8) & 0xff)
        result[16 + i*4+2] = UInt8((v >> 16) & 0xff); result[16 + i*4+3] = UInt8((v >> 24) & 0xff)
    }
    return result
}

private let contentTypes: [String: String] = [
    "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "gif": "image/gif", "pdf": "application/pdf", "json": "application/json",
    "txt": "text/plain", "html": "text/html", "css": "text/css",
    "js": "application/javascript", "wasm": "application/wasm",
    "zip": "application/zip", "mp4": "video/mp4", "mp3": "audio/mpeg",
]

private func guessContentType(_ filename: String) -> String {
    let ext = (filename as NSString).pathExtension.lowercased()
    return contentTypes[ext] ?? "application/octet-stream"
}
