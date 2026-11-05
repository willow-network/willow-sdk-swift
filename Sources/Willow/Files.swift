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

    public init(
        fileKey: String, filename: String, contentType: String, totalSize: UInt64, contentHash: String,
        chunkCount: UInt32, chunkSize: UInt32, chunkMerkleRoot: String, ownerDid: String, createdAt: UInt64,
        updatedAt: UInt64, encrypted: Bool, storageNodes: [String]
    ) {
        self.fileKey = fileKey
        self.filename = filename
        self.contentType = contentType
        self.totalSize = totalSize
        self.contentHash = contentHash
        self.chunkCount = chunkCount
        self.chunkSize = chunkSize
        self.chunkMerkleRoot = chunkMerkleRoot
        self.ownerDid = ownerDid
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.encrypted = encrypted
        self.storageNodes = storageNodes
    }

    /// `GET /files/{subgroveId}` lists manifests without `storage_nodes`,
    /// which reads as empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileKey = try container.decode(String.self, forKey: .fileKey)
        filename = try container.decode(String.self, forKey: .filename)
        contentType = try container.decode(String.self, forKey: .contentType)
        totalSize = try container.decode(UInt64.self, forKey: .totalSize)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        chunkCount = try container.decode(UInt32.self, forKey: .chunkCount)
        chunkSize = try container.decode(UInt32.self, forKey: .chunkSize)
        chunkMerkleRoot = try container.decode(String.self, forKey: .chunkMerkleRoot)
        ownerDid = try container.decode(String.self, forKey: .ownerDid)
        createdAt = try container.decode(UInt64.self, forKey: .createdAt)
        updatedAt = try container.decode(UInt64.self, forKey: .updatedAt)
        encrypted = try container.decode(Bool.self, forKey: .encrypted)
        storageNodes = try container.decodeIfPresent([String].self, forKey: .storageNodes) ?? []
    }
}

/// Response for listing files.
struct FileListResponse: Codable {
    let files: [FileManifest]
}

// MARK: - Signing Options

/// Options for signing file storage transactions with a key the client's
/// identity doesn't hold.
///
/// `nonce` is the transaction's nonce, and the signed message binds it. A
/// write signed with these options doesn't take its nonce from the client's
/// nonce allocator: pick one no other write of `ownerDid` holds. A write
/// refused in its block after its signature and nonce verify still spends
/// its nonce, so a retry of that one needs new options with the next free
/// nonce, which signs anew. A write whose outcome is unknown is retried
/// under the same nonce. With no options, `upload` and `delete` sign with
/// the client's identity under a nonce from its allocator, as `data.store`
/// does.
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
    ///
    /// The manifest is a StoreFileManifest transaction. With `signing`,
    /// `signFunction` signs `storeFileManifestMessage` over every field of the
    /// manifest sent and `signing.nonce`. Without it, the client's identity
    /// signs under the lowest free nonce from its nonce allocator, as for
    /// `data.store` (a write whose outcome is unknown throws a
    /// `TransactionSubmitError` to `resubmit`); with no identity either, it
    /// throws an authentication error and sends nothing (the node refuses an
    /// unsigned manifest). A text field holding a line break is refused with
    /// a validation error before anything is signed.
    ///
    /// The storage node takes a chunk only once the manifest is on chain, so
    /// each chunk is posted again every `pollInterval` seconds until it is
    /// taken or `landingTimeout` seconds pass. A manifest whose outcome is
    /// unknown doesn't stop that: if the chunks are taken, the manifest landed
    /// and `upload` returns. If they aren't, it throws what the submission
    /// failed with. `resubmit` that (or, with `signing`, send it again under
    /// the same nonce), then call `upload` again to get the chunks up; once the
    /// first manifest is on chain, the second is refused in its block, which
    /// spends its nonce and changes nothing.
    public func upload(
        subgroveId: String,
        fileKey: String,
        filename: String,
        data: Data,
        storageNodeEndpoint: String,
        signing: FileSigningOptions? = nil,
        landingTimeout: TimeInterval = 60,
        pollInterval: TimeInterval = 1
    ) async throws -> FileManifest {
        guard let client = client else { throw NetworkError("Client deallocated") }
        let chunkSize = defaultChunkSize
        let chunks = chunkData(data, chunkSize: chunkSize)
        let chunkCount = chunks.count
        let contentType = guessContentType(filename)

        let contentHash = Data(SHA256.hash(data: data))
        let contentHashHex = contentHash.hexString

        let chunkHashes = chunks.map { Data(SHA256.hash(data: $0)) }
        let merkleRoot = computeMerkleRoot(chunkHashes)
        let merkleRootHex = merkleRoot.hexString
        let chunkURLs = try (0..<chunkCount).map { i in
            try FileOperations.storageURL(
                storageNodeEndpoint, ["upload", subgroveId, fileKey],
                query: "chunk_index=\(i)&chunk_count=\(chunkCount)&content_hash=\(contentHashHex)")
        }

        // The manifest, signed under `nonce` by `owner` with `sign`.
        func manifest(owner: String, publicKeyId: String, nonce: Int, sign: (Data) throws -> Data) throws -> Data {
            let signMessage = try storeFileManifestMessage(
                subgroveId: subgroveId,
                fileKey: fileKey,
                ownerDid: owner,
                filename: filename,
                contentType: contentType,
                totalSize: unsignedField("totalSize", data.count, as: UInt64.self),
                contentHash: contentHash,
                chunkCount: unsignedField("chunkCount", chunkCount, as: UInt32.self),
                chunkSize: unsignedField("chunkSize", chunkSize, as: UInt32.self),
                chunkMerkleRoot: merkleRoot,
                nonce: unsignedField("nonce", nonce, as: UInt64.self)
            )
            let manifestTx = StoreFileManifestConsensusBody(
                subgrove_id: subgroveId,
                file_key: fileKey,
                filename: filename,
                content_type: contentType,
                total_size: data.count,
                content_hash: contentHash.map { Int($0) },
                chunk_count: chunkCount,
                chunk_size: chunkSize,
                chunk_merkle_root: merkleRoot.map { Int($0) },
                owner_did: owner,
                signature: Array(try sign(Data(signMessage.utf8))).map { Int($0) },
                public_key_id: publicKeyId,
                nonce: nonce
            )
            return try encodeTransaction(txType: "StoreFileManifest", transaction: manifestTx)
        }

        // Submit StoreFileManifestTx to consensus through the API's /tx/submit.
        // A submission whose outcome is unknown doesn't stop the upload: if the
        // manifest landed, the chunks go up; if they don't, it is thrown.
        var unknownOutcome: Error?
        let ownerDid: String
        if let signing = signing {
            ownerDid = signing.ownerDid
            let body = try manifest(owner: signing.ownerDid, publicKeyId: signing.publicKeyId, nonce: signing.nonce) {
                try signing.signFunction($0, signing.privateKey)
            }
            do {
                try await client.submitTransaction(body)
            } catch let refused as TransactionError {
                throw refused
            } catch {
                unknownOutcome = error
            }
        } else {
            let identity = try client.transactionIdentity()
            ownerDid = identity.did
            // Refuse what can't be signed before spending a request on the nonce.
            _ = try manifest(owner: identity.did, publicKeyId: identity.publicKeyId, nonce: 1) { _ in Data() }
            do {
                _ = try await client.submitUnderNextNonce(did: identity.did) { nonce in
                    try manifest(owner: identity.did, publicKeyId: identity.publicKeyId, nonce: nonce, sign: identity.sign)
                }
            } catch let unknown as TransactionSubmitError {
                unknownOutcome = unknown
            }
        }

        // Upload chunks to the storage node, which takes one only once the
        // manifest is on chain: it answers 403 until then, and 503 while it
        // can't read the chain.
        let deadline = Date().addingTimeInterval(landingTimeout)
        for (i, chunk) in chunks.enumerated() {
            var request = URLRequest(url: chunkURLs[i])
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = chunk

            while true {
                var status: Int?
                do {
                    let (_, response) = try await HTTPBody.read(client.storageSession, request, limit: ResponseLimit.small, json: false)
                    status = (response as? HTTPURLResponse)?.statusCode
                } catch is URLError {
                    status = nil
                }
                if let status = status, (200...299).contains(status) { break }
                guard status == nil || status == 403 || status == 503, Date() < deadline else {
                    if let unknownOutcome = unknownOutcome { throw unknownOutcome }
                    throw NetworkError("Failed to upload chunk \(i)")
                }
                try await Task.sleep(nanoseconds: UInt64(max(0, pollInterval) * 1_000_000_000))
            }
        }

        return FileManifest(
            fileKey: fileKey,
            filename: filename,
            contentType: contentType,
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
    ///
    /// The manifest comes from the API (`GET /files/{subgroveId}/{fileKey}`),
    /// unverified. One the chain would refuse (see `checkManifest`) is refused
    /// with a validation error before any chunk is fetched. The chunks come
    /// from `storageNodeEndpoint`, each read as it arrives and refused with a
    /// validation error once it passes the manifest's chunk size or the bytes
    /// the file has left (or with `ResponseTooLargeError` past 2 MiB, the
    /// most a storage node stores in a chunk). The file must be exactly the
    /// manifest's size, with its chunk Merkle root and content hash.
    public func download(
        subgroveId: String,
        fileKey: String,
        storageNodeEndpoint: String
    ) async throws -> Data {
        guard let client = client else { throw NetworkError("Client deallocated") }
        let manifest = try await metadata(subgroveId: subgroveId, fileKey: fileKey)
        try FileOperations.checkManifest(manifest)
        let urls = try (0..<manifest.chunkCount).map { i in
            try FileOperations.storageURL(
                storageNodeEndpoint, ["chunk", subgroveId, fileKey, String(i)], query: "content_hash=\(manifest.contentHash)")
        }

        var fileData = Data()
        var chunkHashes: [Data] = []
        for (i, url) in urls.enumerated() {
            // The most this chunk holds: the manifest's chunk size, or what
            // the file has left (both at most 1 GiB, as checked above).
            let expected = Int(min(UInt64(manifest.chunkSize), manifest.totalSize - UInt64(fileData.count)))
            let limit = min(ResponseLimit.chunk, expected)
            let chunkData: Data
            let response: URLResponse
            do {
                (chunkData, response) = try await HTTPBody.read(client.storageSession, from: url, limit: limit, json: false)
            } catch let error as WillowError where error.type == .responseTooLarge && limit == expected {
                throw ValidationError(
                    "The storage node served more than chunk \(i) holds: the manifest's \(manifest.chunkSize)-byte chunks of \(manifest.totalSize) bytes")
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NetworkError("Failed to download chunk \(i)")
            }
            chunkHashes.append(Data(SHA256.hash(data: chunkData)))
            fileData.append(chunkData)
        }
        guard UInt64(fileData.count) == manifest.totalSize else {
            throw ValidationError("The storage node served \(fileData.count) bytes, not the manifest's \(manifest.totalSize)")
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

    /// The node's largest file, in bytes (1 GiB).
    internal static let maxFileSize: UInt64 = 1_073_741_824
    /// The node's most chunks: 1 GiB in chunks of 4,096 bytes, the smallest
    /// chunk it now takes in a file of more than one.
    internal static let maxChunkCount: UInt32 = 262_144

    /// Refuses a manifest the chain would refuse: no data, more than 1 GiB or
    /// 262,144 chunks, a zero chunk size, a chunk count that doesn't match the
    /// total and chunk sizes (`(count - 1) * size < total <= count * size`),
    /// or a content hash or chunk Merkle root that isn't 32 nonzero bytes of
    /// hex. Chunks under 4,096 bytes in a file of more than one are taken:
    /// the chain refuses them only from a later height, so a manifest stored
    /// before it may have them.
    internal static func checkManifest(_ manifest: FileManifest) throws {
        let total = manifest.totalSize
        let count = UInt64(manifest.chunkCount)
        let size = UInt64(manifest.chunkSize)
        guard total > 0, total <= maxFileSize else {
            throw ValidationError("The manifest's total size \(total) is not 1 to \(maxFileSize) bytes")
        }
        guard count > 0, manifest.chunkCount <= maxChunkCount, size > 0 else {
            throw ValidationError("The manifest's \(count) chunks of \(size) bytes are not 1 to \(maxChunkCount) chunks of at least 1 byte")
        }
        guard (count - 1) * size < total, total <= count * size else {
            throw ValidationError("The manifest's \(count) chunks of \(size) bytes don't hold its \(total) bytes")
        }
        for (name, hex) in [("content hash", manifest.contentHash), ("chunk Merkle root", manifest.chunkMerkleRoot)] {
            guard hex.utf8.count == 64, let bytes = Data(hexString: hex), bytes.count == 32, bytes.contains(where: { $0 != 0 }) else {
                throw ValidationError("The manifest's \(name) is not 32 nonzero bytes of hex")
            }
        }
    }

    /// The storage node URL `endpoint` / each of `segments`, percent-encoded
    /// as one path segment, with `query` (already encoded).
    internal static func storageURL(_ endpoint: String, _ segments: [String], query: String) throws -> URL {
        var base = endpoint
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let path = segments.map { pathSegment($0) }.joined(separator: "/")
        guard let url = URL(string: "\(base)/\(path)?\(query)"), url.scheme != nil, url.host != nil else {
            throw ValidationError("Invalid storage node URL: \(endpoint)")
        }
        return url
    }

    /// Get file manifest metadata.
    public func metadata(subgroveId: String, fileKey: String) async throws -> FileManifest {
        guard let client = client else { throw NetworkError("Client deallocated") }
        let path = "/files/\(pathSegment(subgroveId))/\(pathSegment(fileKey))"
        return try await client.get(path: path)
    }

    /// List all files in a subgrove.
    public func list(subgroveId: String) async throws -> [FileManifest] {
        guard let client = client else { throw NetworkError("Client deallocated") }
        let path = "/files/\(pathSegment(subgroveId))"
        let response: FileListResponse = try await client.get(path: path)
        return response.files
    }

    /// Delete a file (submits DeleteFileManifestTx to consensus).
    ///
    /// With `signing`, `signFunction` signs `deleteFileManifestMessage` over
    /// the subgrove ID, file key, owner DID, and `signing.nonce`. Without it,
    /// the client's identity signs under the lowest free nonce from its nonce
    /// allocator, as for `data.store`; with no identity either, it throws an
    /// authentication error and sends nothing. A text field holding a line
    /// break is refused with a validation error before anything is signed.
    public func delete(subgroveId: String, fileKey: String, signing: FileSigningOptions? = nil) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }

        func deletion(owner: String, publicKeyId: String, nonce: Int, sign: (Data) throws -> Data) throws -> Data {
            let signMessage = try deleteFileManifestMessage(
                subgroveId: subgroveId,
                fileKey: fileKey,
                ownerDid: owner,
                nonce: unsignedField("nonce", nonce, as: UInt64.self)
            )
            let deleteTx = DeleteFileManifestConsensusBody(
                subgrove_id: subgroveId,
                file_key: fileKey,
                owner_did: owner,
                signature: Array(try sign(Data(signMessage.utf8))).map { Int($0) },
                public_key_id: publicKeyId,
                nonce: nonce
            )
            return try encodeTransaction(txType: "DeleteFileManifest", transaction: deleteTx)
        }

        if let signing = signing {
            let body = try deletion(owner: signing.ownerDid, publicKeyId: signing.publicKeyId, nonce: signing.nonce) {
                try signing.signFunction($0, signing.privateKey)
            }
            try await client.submitTransaction(body)
            return
        }
        let identity = try client.transactionIdentity()
        _ = try deletion(owner: identity.did, publicKeyId: identity.publicKeyId, nonce: 1) { _ in Data() }
        _ = try await client.submitUnderNextNonce(did: identity.did) { nonce in
            try deletion(owner: identity.did, publicKeyId: identity.publicKeyId, nonce: nonce, sign: identity.sign)
        }
    }

    /// Unregister a storage node (submits UnregisterStorageNode to consensus).
    ///
    /// `signFunction` signs `unregisterStorageNodeMessage` over the node DID
    /// and `signing.nonce`, a nonce of the node's DID that the caller picks
    /// (the node's key isn't the client's identity, so the client's nonce
    /// allocator doesn't hand it out). A node DID holding a line break, or a
    /// negative nonce, is refused with a validation error before anything is
    /// signed.
    public func unregisterStorageNode(nodeDid: String, signing: FileSigningOptions) async throws {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let signMessage = try unregisterStorageNodeMessage(
            nodeDid: nodeDid,
            nonce: unsignedField("nonce", signing.nonce, as: UInt64.self)
        )
        let signatureData = try signing.signFunction(Data(signMessage.utf8), signing.privateKey)
        let signatureBytes = Array(signatureData).map { Int($0) }

        let tx = UnregisterStorageNodeConsensusBody(
            node_did: nodeDid,
            signature: signatureBytes,
            public_key_id: signing.publicKeyId,
            nonce: signing.nonce
        )
        try await client.submitTransaction(encodeTransaction(txType: "UnregisterStorageNode", transaction: tx))
    }
}

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
