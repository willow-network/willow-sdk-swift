import Foundation
import CryptoKit
import CryptoSwift
import P256K

// MARK: - Key Pair

/// A cryptographic key pair.
public struct KeyPair {
    public let algorithm: SignatureAlgorithm
    public let publicKey: Data
    public let privateKey: Data

    public init(algorithm: SignatureAlgorithm, publicKey: Data, privateKey: Data) {
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.privateKey = privateKey
    }

    /// Returns the public key as a hex string.
    public var publicKeyHex: String {
        return publicKey.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the private key as a hex string.
    public var privateKeyHex: String {
        return privateKey.map { String(format: "%02x", $0) }.joined()
    }

    /// Signs a message with this key pair.
    public func sign(_ message: Data) throws -> Data {
        switch algorithm {
        case .ed25519:
            return try signEd25519(message: message, privateKey: privateKey)
        case .secp256k1:
            return try signSecp256k1(message: message, privateKey: privateKey)
        }
    }
}

// MARK: - Identity

/// A complete identity with key pair and DID document.
public struct Identity {
    public let keyPair: KeyPair
    public let didDocument: DidDocument

    /// Returns the DID string.
    public var did: String {
        return didDocument.id
    }

    /// Returns the public key ID.
    public var publicKeyId: String {
        return didDocument.publicKeys.first?.id ?? ""
    }

    /// Signs a message with this identity.
    public func sign(_ message: Data) throws -> Data {
        return try keyPair.sign(message)
    }
}

// MARK: - Key Generation

/// Generates a new key pair for the given algorithm.
public func generateKeyPair(algorithm: SignatureAlgorithm) throws -> KeyPair {
    switch algorithm {
    case .ed25519:
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        return KeyPair(
            algorithm: algorithm,
            publicKey: publicKey.rawRepresentation,
            privateKey: privateKey.rawRepresentation
        )

    case .secp256k1:
        let privateKey = try P256K.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        return KeyPair(
            algorithm: algorithm,
            publicKey: publicKey.dataRepresentation,
            privateKey: privateKey.dataRepresentation
        )
    }
}

/// Creates a key pair from an existing private key.
public func keyPairFromPrivateKey(algorithm: SignatureAlgorithm, privateKeyHex: String) throws -> KeyPair {
    guard let privateKeyData = Data(hexString: privateKeyHex) else {
        throw CryptoError("Invalid private key hex")
    }

    switch algorithm {
    case .ed25519:
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let publicKey = privateKey.publicKey
        return KeyPair(
            algorithm: algorithm,
            publicKey: publicKey.rawRepresentation,
            privateKey: privateKey.rawRepresentation
        )

    case .secp256k1:
        let privateKey = try P256K.Signing.PrivateKey(dataRepresentation: [UInt8](privateKeyData))
        let publicKey = privateKey.publicKey
        return KeyPair(
            algorithm: algorithm,
            publicKey: publicKey.dataRepresentation,
            privateKey: privateKey.dataRepresentation
        )
    }
}

// MARK: - Identity Creation

/// Creates a new identity with a fresh key pair.
public func newIdentity(algorithm: SignatureAlgorithm) throws -> Identity {
    let keyPair = try generateKeyPair(algorithm: algorithm)
    let didDocument = createDidDocument(keyPair: keyPair)
    return Identity(keyPair: keyPair, didDocument: didDocument)
}

/// Creates an identity from an existing private key.
public func identityFromPrivateKey(algorithm: SignatureAlgorithm, privateKeyHex: String) throws -> Identity {
    let keyPair = try keyPairFromPrivateKey(algorithm: algorithm, privateKeyHex: privateKeyHex)
    let didDocument = createDidDocument(keyPair: keyPair)
    return Identity(keyPair: keyPair, didDocument: didDocument)
}

// MARK: - DID Generation

/// Derives a self-certifying `did:willow` identifier from a raw public key.
///
/// The Willow chain requires every DID id to be exactly:
///
///     did = "did:willow:z" + base58btc( SHA3-256( multicodec_prefix || public_key ) )
///
/// where `SHA3-256` is FIPS-202 SHA3-256 (NOT Keccak-256), `multicodec_prefix`
/// is `0xED 0x01` for Ed25519 and `0xE7 0x01` for secp256k1, the leading `z`
/// is the multibase base58btc marker, and `base58btc` uses the Bitcoin
/// alphabet with each leading `0x00` byte encoded as a leading `1`.
///
/// For secp256k1 the 33-byte compressed public key is hashed; an uncompressed
/// (65-byte, `0x04`-prefixed) key is normalized to compressed form first.
///
/// The id is bound to the key material, so it cannot be chosen freely — see
/// the two-step pre-fund → register bootstrap documented on
/// `ConsensusClient.registerDid`.
public func deriveWillowDID(algorithm: SignatureAlgorithm, publicKey: Data) -> String {
    let keyBytes: [UInt8]
    switch algorithm {
    case .ed25519:
        keyBytes = [UInt8](publicKey)
    case .secp256k1:
        keyBytes = compressedSecp256k1PublicKey([UInt8](publicKey))
    }

    let payload = algorithm.multicodecPrefix + keyBytes
    // FIPS-202 SHA3-256 (32-byte digest) — deliberately not Keccak-256.
    let digest = Digest.sha3(payload, variant: .sha256)
    return "did:willow:z" + base58btcEncode(digest)
}

/// Generates a self-certifying DID string from a key pair.
public func generateDID(keyPair: KeyPair) -> String {
    return deriveWillowDID(algorithm: keyPair.algorithm, publicKey: keyPair.publicKey)
}

/// Creates a DID document from a key pair.
public func createDidDocument(keyPair: KeyPair) -> DidDocument {
    let did = generateDID(keyPair: keyPair)
    let now = Int64(Date().timeIntervalSince1970)

    let publicKey = PublicKey(
        id: "\(did)#key-1",
        type: keyPair.algorithm.keyType,
        publicKeyHex: keyPair.publicKeyHex
    )

    return DidDocument(
        id: did,
        publicKeys: [publicKey],
        created: now,
        updated: now
    )
}

// MARK: - DID Derivation Helpers

/// Normalizes a secp256k1 public key to 33-byte compressed form.
///
/// Accepts a key that is already compressed (33 bytes, `0x02`/`0x03` prefix)
/// or uncompressed (65 bytes, `0x04` prefix). Any other input is returned
/// unchanged as a best effort; keys produced by this SDK are always compressed.
private func compressedSecp256k1PublicKey(_ bytes: [UInt8]) -> [UInt8] {
    if bytes.count == 33, bytes[0] == 0x02 || bytes[0] == 0x03 {
        return bytes
    }
    if bytes.count == 65, bytes[0] == 0x04 {
        let x = Array(bytes[1...32])
        let yIsOdd = (bytes[64] & 1) == 1
        return [yIsOdd ? 0x03 : 0x02] + x
    }
    return bytes
}

/// Bitcoin/base58btc alphabet.
private let base58Alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

/// Encodes bytes using the Bitcoin base58btc alphabet, emitting one leading
/// `1` for each leading `0x00` byte (multibase base58btc convention).
private func base58btcEncode(_ input: [UInt8]) -> String {
    // Count leading zero bytes.
    var zeros = 0
    while zeros < input.count && input[zeros] == 0 {
        zeros += 1
    }

    // Allocate enough space for the big-endian base58 digits.
    // ceil(log(256) / log(58)) ~= 138/100.
    let size = (input.count - zeros) * 138 / 100 + 1
    var b58 = [UInt8](repeating: 0, count: size)

    var length = 0
    for i in zeros..<input.count {
        var carry = Int(input[i])
        var j = 0
        var k = size - 1
        // Apply b58 = b58 * 256 + input[i].
        while (carry != 0 || j < length) && k >= 0 {
            carry += 256 * Int(b58[k])
            b58[k] = UInt8(carry % 58)
            carry /= 58
            j += 1
            k -= 1
        }
        length = j
    }

    // Skip leading zeros produced in the base58 buffer.
    var it = size - length
    while it < size && b58[it] == 0 {
        it += 1
    }

    var result = String(repeating: "1", count: zeros)
    while it < size {
        result.append(base58Alphabet[Int(b58[it])])
        it += 1
    }
    return result
}

// MARK: - Signing

/// Signs a message using Ed25519.
private func signEd25519(message: Data, privateKey: Data) throws -> Data {
    let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
    let signature = try signingKey.signature(for: message)
    return signature
}

/// Signs a message using secp256k1.
///
/// Willow verifies secp256k1 signatures over the Keccak-256 (Ethereum's hash,
/// not FIPS-202 SHA3-256) of the message, so the digest is signed directly
/// rather than through `signature(for: Data)`, which hashes with SHA-256. The
/// result is the 64-byte compact `r || s`, lower-S (libsecp256k1 signs lower-S
/// only), with an RFC 6979 nonce.
private func signSecp256k1(message: Data, privateKey: Data) throws -> Data {
    let signingKey = try P256K.Signing.PrivateKey(dataRepresentation: [UInt8](privateKey))
    let signature = try signingKey.signature(for: HashDigest([UInt8](keccak256(message))))
    return try signature.compactRepresentation
}

// MARK: - Verification

/// Verifies a signature.
public func verify(algorithm: SignatureAlgorithm, publicKey: Data, message: Data, signature: Data) throws -> Bool {
    switch algorithm {
    case .ed25519:
        return try verifyEd25519(publicKey: publicKey, message: message, signature: signature)
    case .secp256k1:
        return try verifySecp256k1(publicKey: publicKey, message: message, signature: signature)
    }
}

/// Verifies an Ed25519 signature.
private func verifyEd25519(publicKey: Data, message: Data, signature: Data) throws -> Bool {
    let verifyingKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    return verifyingKey.isValidSignature(signature, for: message)
}

/// Verifies a secp256k1 signature the way the Willow server does: ECDSA over the
/// Keccak-256 of the message, the signature as 64-byte compact `r || s` or DER,
/// lower-S only. The public key is 33 bytes compressed or 65 bytes uncompressed;
/// a 64-byte uncompressed key without its `0x04` tag is also accepted here.
private func verifySecp256k1(publicKey: Data, message: Data, signature: Data) throws -> Bool {
    let keyBytes = [UInt8](publicKey)
    let verifyingKey: P256K.Signing.PublicKey
    switch keyBytes.count {
    case 33:
        verifyingKey = try P256K.Signing.PublicKey(dataRepresentation: keyBytes, format: .compressed)
    case 65:
        verifyingKey = try P256K.Signing.PublicKey(dataRepresentation: keyBytes, format: .uncompressed)
    case 64:
        verifyingKey = try P256K.Signing.PublicKey(dataRepresentation: [0x04] + keyBytes, format: .uncompressed)
    default:
        throw CryptoError("Invalid secp256k1 public key length: \(keyBytes.count)")
    }

    let ecdsaSignature: P256K.Signing.ECDSASignature
    do {
        if signature.count == 64 {
            ecdsaSignature = try P256K.Signing.ECDSASignature(compactRepresentation: [UInt8](signature))
        } else {
            ecdsaSignature = try P256K.Signing.ECDSASignature(derRepresentation: [UInt8](signature))
        }
    } catch {
        return false
    }
    // libsecp256k1 refuses a higher-S signature, as the server does.
    return verifyingKey.isValidSignature(ecdsaSignature, for: HashDigest([UInt8](keccak256(message))))
}

// MARK: - Per-Request Signing

/// The message `signRequest` signs: `{METHOD}:{PATH}:{TIMESTAMP}`.
///
/// The server verifies this form against the request's path alone, so anything
/// from the first `?` in `path` is left out.
public func legacyRequestMessage(method: String, path: String, timestamp: String) -> String {
    let pathOnly = path.firstIndex(of: "?").map { String(path[..<$0]) } ?? path
    return "\(method):\(pathOnly):\(timestamp)"
}

/// The message a nonce-signed request signs: a version line, then one per line
/// the DID, its key's id, the method, the path and query exactly as sent, the
/// Unix timestamp, the nonce, and the lowercase hex SHA-256 of the body (of no
/// bytes, for a request without one). Lines are joined by `\n`, with no
/// trailing newline.
public func signedRequestMessage(
    did: String,
    publicKeyId: String,
    method: String,
    pathAndQuery: String,
    timestamp: String,
    nonce: String,
    body: Data
) -> String {
    let bodyHash = CryptoKit.SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    return [
        "willow-request-v2",
        did,
        publicKeyId,
        method,
        pathAndQuery,
        timestamp,
        nonce,
        bodyHash,
    ].joined(separator: "\n")
}

/// Returns a fresh nonce for a nonce-signed request: 32 lowercase hex
/// characters from 16 random bytes. The server accepts 16 to 128 characters of
/// `A-Z a-z 0-9 - _`, and each (DID, nonce) only once.
public func newRequestNonce() throws -> String {
    return Data(try generateSecureRandomBytes(count: 16)).hexString
}

/// Signs a request with a one-time nonce over the whole request and returns the
/// authentication headers: `X-DID`, `X-Public-Key-ID`, `X-Signature`,
/// `X-Timestamp`, and `X-Nonce`.
///
/// `pathAndQuery` is the request target exactly as the server receives it,
/// percent-encoded, query string included. `body` is the exact bytes sent
/// (empty for none). The timestamp is now; the server accepts it for 300
/// seconds, and each nonce once, so sign every attempt of a retried request
/// anew.
///
/// Only this form carries the DID's read rights: a Reader permission on a
/// subgrove, or a place on a priced subgrove's free-reader list.
public func signRequestWithNonce(
    method: String,
    pathAndQuery: String,
    body: Data = Data(),
    identity: Identity
) throws -> [String: String] {
    return try signRequestWithNonce(
        method: method,
        pathAndQuery: pathAndQuery,
        body: body,
        identity: identity,
        timestamp: String(Int64(Date().timeIntervalSince1970)),
        nonce: try newRequestNonce()
    )
}

/// `signRequestWithNonce` with a fixed timestamp and nonce (for tests).
internal func signRequestWithNonce(
    method: String,
    pathAndQuery: String,
    body: Data,
    identity: Identity,
    timestamp: String,
    nonce: String
) throws -> [String: String] {
    let message = signedRequestMessage(
        did: identity.did,
        publicKeyId: identity.publicKeyId,
        method: method,
        pathAndQuery: pathAndQuery,
        timestamp: timestamp,
        nonce: nonce,
        body: body
    )
    return [
        "X-DID": identity.did,
        "X-Public-Key-ID": identity.publicKeyId,
        "X-Signature": try signRequestMessage(message, identity: identity),
        "X-Timestamp": timestamp,
        "X-Nonce": nonce,
    ]
}

/// Signs a request in the server's older form and returns the authentication
/// headers. The message is `{METHOD}:{PATH}:{TIMESTAMP}` over the path without
/// its query string (see `legacyRequestMessage`).
///
/// This form proves the DID but carries none of its read rights, and anyone
/// who sees it can replay it with any body until the timestamp expires. The
/// client signs its reads of subgrove data with `signRequestWithNonce`, and
/// its other signed requests with this form.
public func signRequest(method: String, path: String, identity: Identity) throws -> [String: String] {
    let timestamp = String(Int64(Date().timeIntervalSince1970))
    let message = legacyRequestMessage(method: method, path: path, timestamp: timestamp)
    return [
        "X-DID": identity.did,
        "X-Public-Key-ID": identity.publicKeyId,
        "X-Signature": try signRequestMessage(message, identity: identity),
        "X-Timestamp": timestamp,
    ]
}

/// Signs a request message and encodes the signature as the server decodes
/// `X-Signature`: Ed25519 as hex, secp256k1 as `0x`-prefixed hex. The server
/// reads an unprefixed secp256k1 signature as base64 first, and a hex string is
/// usually valid base64.
private func signRequestMessage(_ message: String, identity: Identity) throws -> String {
    let signature = try identity.sign(Data(message.utf8))
    switch identity.keyPair.algorithm {
    case .ed25519:
        return signature.hexString
    case .secp256k1:
        return "0x" + signature.hexString
    }
}

// MARK: - Helper Functions

/// Generates cryptographically secure random bytes.
private func generateSecureRandomBytes(count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else {
        throw CryptoError("Failed to generate random bytes")
    }
    return bytes
}

// MARK: - Data Extensions

extension Data {
    /// Initializes Data from a hex string.
    init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Returns the hex string representation.
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
