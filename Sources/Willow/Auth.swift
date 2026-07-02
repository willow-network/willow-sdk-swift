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
private func signSecp256k1(message: Data, privateKey: Data) throws -> Data {
    let signingKey = try P256K.Signing.PrivateKey(dataRepresentation: [UInt8](privateKey))
    // P256K.Signing already hashes the message internally
    let signature = try signingKey.signature(for: message)
    return signature.dataRepresentation
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

/// Verifies a secp256k1 signature.
private func verifySecp256k1(publicKey: Data, message: Data, signature: Data) throws -> Bool {
    let verifyingKey = try P256K.Signing.PublicKey(dataRepresentation: [UInt8](publicKey), format: .compressed)
    let ecdsaSignature = try P256K.Signing.ECDSASignature(dataRepresentation: [UInt8](signature))
    return verifyingKey.isValidSignature(ecdsaSignature, for: message)
}

// MARK: - Per-Request Signing

/// Signs a request and returns the authentication headers.
/// Message format: {METHOD}:{PATH}:{TIMESTAMP}
public func signRequest(method: String, path: String, identity: Identity) throws -> [String: String] {
    let timestamp = String(Int(Date().timeIntervalSince1970))
    let message = "\(method):\(path):\(timestamp)"
    guard let messageData = message.data(using: .utf8) else {
        throw CryptoError("Failed to encode request message")
    }

    let signature = try identity.sign(messageData)
    let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

    return [
        "X-DID": identity.did,
        "X-Public-Key-ID": identity.publicKeyId,
        "X-Signature": signatureHex,
        "X-Timestamp": timestamp,
    ]
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
