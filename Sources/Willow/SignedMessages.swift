import Foundation
import CryptoKit

// MARK: - Signed Messages for Data and File Writes

// The messages StoreData, StoreFileManifest, and DeleteFileManifest
// transactions are signed over.
//
// Each message is a set of lines joined by "\n" (the byte 0x0A), with no
// trailing newline, as UTF-8: the kind first, then one `Label: value` line per
// field, the nonce last. It binds the transaction's nonce and every field the
// transaction writes. Text fields go in verbatim, with no escaping or
// normalization. Variable-length bytes appear as the lowercase hex SHA-256 of
// the exact bytes the transaction carries; fixed-length hashes appear as their
// lowercase hex. Numbers are unsigned decimal.
//
// A text field holding a line break (the byte 0x0A) is refused with a
// validation error: the node refuses such a transaction, and the lines must
// read back one way only.
//
// The nonce in the message is the nonce in the transaction, so build the
// message after the nonce is chosen. A write that lands in a block and is
// refused there after its signature and nonce verify still spends its nonce;
// to retry, sign again under the next free nonce.
//
// Ed25519 signs the message's UTF-8 bytes; secp256k1 signs their Keccak-256
// (see `KeyPair.sign`).

/// Encryption metadata a file manifest carries for a file in a private
/// subgrove: the key epoch from the subgrove's key grants and the 24-byte
/// XChaCha20-Poly1305 nonce.
public struct FileEncryption: Equatable {
    public let keyEpoch: UInt64
    public let nonce: Data

    public init(keyEpoch: UInt64, nonce: Data) {
        self.keyEpoch = keyEpoch
        self.nonce = nonce
    }
}

/// The message a StoreData transaction is signed over.
///
/// `data` is the exact bytes the transaction's `data` field carries (the JSON
/// text's UTF-8 bytes); the message binds their SHA-256:
///
/// ```
/// StoreData
/// Subgrove: <subgroveId>
/// Key: <key>
/// Owner: <ownerDid>
/// DataHash: <hex SHA-256 of data>
/// Nonce: <nonce>
/// ```
///
/// Throws a validation error when `subgroveId`, `key`, or `ownerDid` holds a
/// line break.
public func storeDataMessage(
    subgroveId: String,
    key: String,
    ownerDid: String,
    data: Data,
    nonce: UInt64
) throws -> String {
    return [
        "StoreData",
        try signedTextField("Subgrove", subgroveId),
        try signedTextField("Key", key),
        try signedTextField("Owner", ownerDid),
        "DataHash: \(Data(SHA256.hash(data: data)).hexString)",
        "Nonce: \(nonce)",
    ].joined(separator: "\n")
}

/// The message a StoreFileManifest transaction is signed over.
///
/// `contentHash` and `chunkMerkleRoot` are the 32 bytes the transaction
/// carries. `encryption` is `nil` when the transaction carries no
/// `encryption`:
///
/// ```
/// StoreFileManifest
/// Subgrove: <subgroveId>
/// Key: <fileKey>
/// Owner: <ownerDid>
/// Filename: <filename>
/// ContentType: <contentType>
/// TotalSize: <totalSize>
/// ContentHash: <hex contentHash>
/// ChunkCount: <chunkCount>
/// ChunkSize: <chunkSize>
/// ChunkMerkleRoot: <hex chunkMerkleRoot>
/// Encryption: none | <keyEpoch>:<hex nonce>
/// Nonce: <nonce>
/// ```
///
/// Throws a validation error when a text field holds a line break, or a hash
/// or the encryption nonce has the wrong length.
public func storeFileManifestMessage(
    subgroveId: String,
    fileKey: String,
    ownerDid: String,
    filename: String,
    contentType: String,
    totalSize: UInt64,
    contentHash: Data,
    chunkCount: UInt32,
    chunkSize: UInt32,
    chunkMerkleRoot: Data,
    encryption: FileEncryption? = nil,
    nonce: UInt64
) throws -> String {
    let encryptionValue: String
    if let encryption = encryption {
        encryptionValue = "\(encryption.keyEpoch):\(try fixedLengthHex("Encryption nonce", encryption.nonce, count: 24))"
    } else {
        encryptionValue = "none"
    }
    return [
        "StoreFileManifest",
        try signedTextField("Subgrove", subgroveId),
        try signedTextField("Key", fileKey),
        try signedTextField("Owner", ownerDid),
        try signedTextField("Filename", filename),
        try signedTextField("ContentType", contentType),
        "TotalSize: \(totalSize)",
        "ContentHash: \(try fixedLengthHex("ContentHash", contentHash, count: 32))",
        "ChunkCount: \(chunkCount)",
        "ChunkSize: \(chunkSize)",
        "ChunkMerkleRoot: \(try fixedLengthHex("ChunkMerkleRoot", chunkMerkleRoot, count: 32))",
        "Encryption: \(encryptionValue)",
        "Nonce: \(nonce)",
    ].joined(separator: "\n")
}

/// The message a DeleteFileManifest transaction is signed over:
///
/// ```
/// DeleteFileManifest
/// Subgrove: <subgroveId>
/// Key: <fileKey>
/// Owner: <ownerDid>
/// Nonce: <nonce>
/// ```
///
/// Throws a validation error when a text field holds a line break.
public func deleteFileManifestMessage(
    subgroveId: String,
    fileKey: String,
    ownerDid: String,
    nonce: UInt64
) throws -> String {
    return [
        "DeleteFileManifest",
        try signedTextField("Subgrove", subgroveId),
        try signedTextField("Key", fileKey),
        try signedTextField("Owner", ownerDid),
        "Nonce: \(nonce)",
    ].joined(separator: "\n")
}

// MARK: - Helpers

/// `Label: value`, refusing a value that holds the byte 0x0A. The check is on
/// the UTF-8 bytes: Swift reads "\r\n" as one Character, so
/// `String.contains("\n")` misses it.
private func signedTextField(_ label: String, _ value: String) throws -> String {
    if value.utf8.contains(0x0A) {
        throw ValidationError("\(label) holds a line break, which a signed field can't")
    }
    return "\(label): \(value)"
}

private func fixedLengthHex(_ label: String, _ bytes: Data, count: Int) throws -> String {
    guard bytes.count == count else {
        throw ValidationError("\(label) must be \(count) bytes, got \(bytes.count)")
    }
    return bytes.hexString
}

/// `value` as the unsigned integer type a transaction field has on the wire.
internal func unsignedField<T: FixedWidthInteger & UnsignedInteger>(_ label: String, _ value: Int, as type: T.Type) throws -> T {
    guard let unsigned = T(exactly: value) else {
        throw ValidationError("\(label) must be an integer from 0 to \(T.max)")
    }
    return unsigned
}
