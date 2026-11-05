import Foundation
import CryptoKit

// MARK: - Signed Messages

// The messages transactions are signed over: StoreData, StoreFileManifest,
// and DeleteFileManifest (data and file writes); RegisterSubgrove,
// GrantSubgroveKey, RotateSubgroveKey, and UnregisterStorageNode
// (registrations, key grants, and storage-node removals); and
// RevokeSubgroveKey, whose older form already binds every field.
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
// message after the nonce is chosen. A transaction that lands in a block and
// is refused there after its signature and nonce verify still spends its
// nonce; to retry it, sign again under a fresh nonce. One that never landed
// spends nothing: retry it under that attempt's own nonce, so that at most one
// of the two can run. A write refused as "already used" may be one whose
// earlier attempt landed: read what it wrote before signing it again under a
// fresh nonce, or it can run twice.
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

// MARK: - Registrations, Key Grants, and Storage Nodes

/// The bincode (bincode 1.x's default encoding) of `tx` with an empty
/// signature, as the node decodes the JSON the SDK sends for it: the bytes a
/// RegisterSubgrove message's `Config` line hashes.
///
/// Throws a validation error for a mode the SDK can't build
/// (BlockchainIndexing) or a negative nonce.
public func registerSubgroveUnsignedBincode(_ tx: RegisterSubgroveTx) throws -> Data {
    var unsigned = tx
    unsigned.signature = []
    return try registerSubgroveUnsignedBincode(json: unsigned.wireJSON())
}

/// The message a RegisterSubgrove transaction is signed over:
///
/// ```
/// RegisterSubgrove
/// Subgrove: <subgroveId>
/// Owner: <ownerDid>
/// Config: <hex SHA-256 of registerSubgroveUnsignedBincode(tx)>
/// Nonce: <nonce>
/// ```
///
/// `Config` binds every field of the transaction but its signature. Throws a
/// validation error when the subgrove ID or owner DID holds a line break, for
/// a mode the SDK can't build (BlockchainIndexing), a negative nonce, or a
/// DataStorage or FileStorage registration the node refuses: a subgrove ID
/// that isn't 1 to 64 ASCII letters, digits, `-`, or `_` starting with a
/// letter or digit; an admin, writer, or free reader that isn't a Willow DID;
/// a schema the node can't read as its schema definition, or one that
/// declares indexes; or a private DataStorage subgrove whose initial key
/// grant isn't key epoch 0 to the owner.
public func registerSubgroveMessage(_ tx: RegisterSubgroveTx) throws -> String {
    try tx.checkStorageRules()
    var unsigned = tx
    unsigned.signature = []
    return try registerSubgroveMessage(json: unsigned.wireJSON())
}

/// The RegisterSubgrove message for the transaction JSON `tx` (the object
/// inside `{"RegisterSubgrove": ...}`), as the node rebuilds it.
internal func registerSubgroveMessage(json tx: WireJSON) throws -> String {
    let fields = try WireJSONObject(tx, "RegisterSubgrove")
    let subgroveId = try fields.required("subgrove_id").string("subgrove_id")
    let ownerDid = try fields.required("owner_did").string("owner_did")
    let nonce = try fields.required("nonce").unsigned("nonce", as: UInt64.self)
    let config = Data(SHA256.hash(data: try registerSubgroveUnsignedBincode(json: tx))).hexString
    return [
        "RegisterSubgrove",
        try signedTextField("Subgrove", subgroveId),
        try signedTextField("Owner", ownerDid),
        "Config: \(config)",
        "Nonce: \(nonce)",
    ].joined(separator: "\n")
}

/// The message a GrantSubgroveKey transaction is signed over:
///
/// ```
/// GrantSubgroveKey
/// Subgrove: <subgroveId>
/// Sender: <senderDid>
/// Grantee: <grant.granteeDid>
/// GranteeKey: <grant.granteePublicKeyId>
/// KeyEpoch: <grant.keyEpoch>
/// EphemeralKey: <hex grant.ephemeralPublicKey>
/// EncryptedKey: <hex grant.encryptedKey>
/// GrantedBy: <grant.grantedBy>
/// GrantedAt: <grant.grantedAt>
/// Nonce: <nonce>
/// ```
///
/// Throws a validation error when a text field holds a line break or the
/// grantee isn't a Willow DID (`did:willow:` then one or more ASCII letters,
/// digits, `-`, or `_`, at most 128 bytes), which the node refuses.
public func grantSubgroveKeyMessage(
    subgroveId: String,
    senderDid: String,
    grant: EncryptedKeyGrant,
    nonce: UInt64
) throws -> String {
    return ([
        "GrantSubgroveKey",
        try signedTextField("Subgrove", subgroveId),
        try signedTextField("Sender", senderDid),
    ] + (try grantLines(grant)) + [
        "Nonce: \(nonce)",
    ]).joined(separator: "\n")
}

/// The message a RotateSubgroveKey transaction is signed over:
///
/// ```
/// RotateSubgroveKey
/// Subgrove: <subgroveId>
/// Sender: <senderDid>
/// NewEpoch: <newEpoch>
/// Grants: <newGrants.count>
/// <each grant's seven lines, Grantee through GrantedAt, in order>
/// Nonce: <nonce>
/// ```
///
/// Throws a validation error when a text field holds a line break or a
/// grantee isn't a Willow DID, which the node refuses.
public func rotateSubgroveKeyMessage(
    subgroveId: String,
    senderDid: String,
    newEpoch: UInt32,
    newGrants: [EncryptedKeyGrant],
    nonce: UInt64
) throws -> String {
    var lines = [
        "RotateSubgroveKey",
        try signedTextField("Subgrove", subgroveId),
        try signedTextField("Sender", senderDid),
        "NewEpoch: \(newEpoch)",
        "Grants: \(newGrants.count)",
    ]
    for grant in newGrants {
        lines += try grantLines(grant)
    }
    lines.append("Nonce: \(nonce)")
    return lines.joined(separator: "\n")
}

/// The message a RevokeSubgroveKey transaction is signed over, which already
/// binds every field: `RevokeSubgroveKey:<subgroveId>:<revokeeDid>:<senderDid>:<nonce>`.
///
/// Throws a validation error when the subgrove ID holds a `:` or the revokee
/// or sender isn't a Willow DID: the node refuses those, so the message
/// splits one way.
public func revokeSubgroveKeyMessage(subgroveId: String, revokeeDid: String, senderDid: String, nonce: UInt64) throws -> String {
    if subgroveId.utf8.contains(UInt8(ascii: ":")) {
        throw ValidationError("A revoked subgrove's ID can't hold ':': \(subgroveId)")
    }
    try checkWillowDID(revokeeDid, "The revokee")
    try checkWillowDID(senderDid, "The sender")
    return "RevokeSubgroveKey:\(subgroveId):\(revokeeDid):\(senderDid):\(nonce)"
}

/// The message an UnregisterStorageNode transaction is signed over:
///
/// ```
/// UnregisterStorageNode
/// Node: <nodeDid>
/// Nonce: <nonce>
/// ```
///
/// Throws a validation error when the node DID holds a line break.
public func unregisterStorageNodeMessage(nodeDid: String, nonce: UInt64) throws -> String {
    return [
        "UnregisterStorageNode",
        try signedTextField("Node", nodeDid),
        "Nonce: \(nonce)",
    ].joined(separator: "\n")
}

/// One key grant's lines: `Grantee`, `GranteeKey`, `KeyEpoch`, `EphemeralKey`
/// and `EncryptedKey` (lowercase hex of the exact bytes), `GrantedBy`, `GrantedAt`.
/// The grantee must be a Willow DID, so that a revoke can name it.
private func grantLines(_ grant: EncryptedKeyGrant) throws -> [String] {
    let grantee = try signedTextField("Grantee", grant.granteeDid)
    try checkWillowDID(grant.granteeDid, "A grantee")
    return [
        grantee,
        try signedTextField("GranteeKey", grant.granteePublicKeyId),
        "KeyEpoch: \(grant.keyEpoch)",
        "EphemeralKey: \(Data(grant.ephemeralPublicKey).hexString)",
        "EncryptedKey: \(Data(grant.encryptedKey).hexString)",
        try signedTextField("GrantedBy", grant.grantedBy),
        "GrantedAt: \(grant.grantedAt)",
    ]
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

/// Whether `byte` is an ASCII letter or digit.
internal func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"):
        return true
    default:
        return false
    }
}

/// Whether `byte` is an ASCII letter or digit, `-`, or `_`.
internal func isIdentifierByte(_ byte: UInt8) -> Bool {
    return isASCIILetterOrDigit(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
}

/// Refuses `did` unless it is a Willow DID as the node reads one:
/// `did:willow:` then one or more ASCII letters, digits, `-`, or `_`, at most
/// 128 bytes in all. `who` names it in the error.
internal func checkWillowDID(_ did: String, _ who: String) throws {
    let prefix = Array("did:willow:".utf8)
    let bytes = Array(did.utf8)
    guard bytes.starts(with: prefix), bytes.count > prefix.count, bytes.count <= 128,
          bytes[prefix.count...].allSatisfy(isIdentifierByte)
    else {
        throw ValidationError(
            "\(who) must be a Willow DID (did:willow: then 1 or more ASCII letters, digits, '-', or '_', at most 128 bytes): \(did)"
        )
    }
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

// MARK: - RegisterDid

/// The message a RegisterDid transaction is signed over: the node's compact
/// JSON of the DID document (`serde_json::to_vec` of its `DidDocument`), as
/// `didDocumentBody` writes it. The node signs no other text: its fields in
/// its order (`id`, `public_keys`, `authentication`, `service`, `created`,
/// `updated`, `proof`; a key's `id`, `type`, `controller`,
/// `public_key_base58`, `public_key_hex`; a service's `id`, `type`,
/// `service_endpoint`; a proof's `type`, `created`, `verification_method`,
/// `proof_purpose`, `jws`), an absent option as `null`, no whitespace, and
/// strings escaped as serde_json escapes them (`"` and `\`, and the control
/// characters below 0x20; not `/` or any other text).
///
/// - Throws: A validation error for a document the node can't read (see
///   `didDocumentBody`).
public func registerDidMessage(_ didDocument: [String: Any]) throws -> String {
    return String(decoding: try didDocumentBody(didDocument).serialized, as: UTF8.self)
}

/// A DID document as the node decodes it, in its field order, from a
/// document in its JSON form: `id`; `public_keys`, each with `id`, `type`
/// (or `key_type`), `controller`, and optionally `public_key_base58` and
/// `public_key_hex`; `authentication`, the key IDs that sign for the DID;
/// `service`, each with `id`, `type` (or `service_type`), and
/// `service_endpoint` (or `endpoint`), empty when absent; `created` and
/// `updated`, integers from 0 to 2^64 - 1; and optionally `proof`, with
/// `type` (or `proof_type`), `created`, `verification_method`,
/// `proof_purpose`, and `jws`. Fields the node doesn't read are dropped:
/// send this document, so the node serializes back exactly what was signed.
///
/// Refuses, with a validation error, a document missing a field the node
/// requires or holding one of the wrong type (a number that isn't an
/// unsigned integer, such as `1.5` or `-1`, or a value that isn't JSON).
internal func didDocumentBody(_ didDocument: [String: Any]) throws -> WireJSON {
    let d = try WireJSONObject(try WireJSON.foundation(didDocument), "didDocument")

    /// The string at `key` (or, when absent, at `alias`), required.
    func text(_ object: WireJSONObject, _ key: String, or alias: String? = nil) throws -> WireJSON {
        let value = try object.optional(key) ?? alias.flatMap { object.optional($0) } ?? object.required(key)
        return .string(try value.string(object.label(key)))
    }
    /// The string at `key`, or null when absent or null.
    func optionalText(_ object: WireJSONObject, _ key: String) throws -> WireJSON {
        return try object.optionalValue(key) { .string(try $0.string(object.label(key))) } ?? .null
    }
    func u64(_ object: WireJSONObject, _ key: String) throws -> WireJSON {
        return .unsigned(try object.required(key).unsigned(object.label(key), as: UInt64.self))
    }
    /// The array at `key` (empty when absent or null, if `optional`), each
    /// element read with `read`.
    func list(_ key: String, optional: Bool = false, _ read: (WireJSONObject) throws -> WireJSON) throws -> WireJSON {
        let value = optional ? (d.optionalValue(key) { $0 } ?? .array([])) : try d.required(key)
        return .array(try value.array(d.label(key)).enumerated().map { index, element in
            try read(try WireJSONObject(element, "\(d.label(key))[\(index)]"))
        })
    }

    let publicKeys = try list("public_keys") { k in
        .object([
            .init("id", try text(k, "id")),
            .init("type", try text(k, "type", or: "key_type")),
            .init("controller", try text(k, "controller")),
            .init("public_key_base58", try optionalText(k, "public_key_base58")),
            .init("public_key_hex", try optionalText(k, "public_key_hex")),
        ])
    }
    let services = try list("service", optional: true) { s in
        .object([
            .init("id", try text(s, "id")),
            .init("type", try text(s, "type", or: "service_type")),
            .init("service_endpoint", try text(s, "service_endpoint", or: "endpoint")),
        ])
    }
    let proof = try d.optionalValue("proof") { value -> WireJSON in
        let p = try WireJSONObject(value, d.label("proof"))
        return .object([
            .init("type", try text(p, "type", or: "proof_type")),
            .init("created", try u64(p, "created")),
            .init("verification_method", try text(p, "verification_method")),
            .init("proof_purpose", try text(p, "proof_purpose")),
            .init("jws", try text(p, "jws")),
        ])
    } ?? .null
    return .object([
        .init("id", try text(d, "id")),
        .init("public_keys", publicKeys),
        .init("authentication", .strings(try d.required("authentication").strings(d.label("authentication")))),
        .init("service", services),
        .init("created", try u64(d, "created")),
        .init("updated", try u64(d, "updated")),
        .init("proof", proof),
    ])
}
