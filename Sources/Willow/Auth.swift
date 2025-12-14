import Foundation
import CryptoKit
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

/// Generates a DID string from a key pair.
public func generateDID(keyPair: KeyPair) -> String {
    return "did:willow:\(keyPair.algorithm.rawValue):\(keyPair.publicKeyHex)"
}

/// Creates a DID document from a key pair.
public func createDidDocument(keyPair: KeyPair) -> DidDocument {
    let did = generateDID(keyPair: keyPair)
    let now = Int64(Date().timeIntervalSince1970)

    let publicKey = PublicKey(
        id: "\(did)#keys-1",
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

// MARK: - Authentication Challenge Signing

/// Signs an authentication challenge.
public func signAuthenticationChallenge(
    challenge: AuthenticationChallenge,
    did: String,
    keyPair: KeyPair
) throws -> String {
    // Create message to sign: challenge + nonce + expiresAt
    let message = "\(challenge.challenge):\(challenge.nonce):\(challenge.expiresAt)"
    guard let messageData = message.data(using: .utf8) else {
        throw CryptoError("Failed to encode challenge message")
    }

    let signature = try keyPair.sign(messageData)
    return signature.map { String(format: "%02x", $0) }.joined()
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
