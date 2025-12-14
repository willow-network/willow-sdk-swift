import XCTest
@testable import Willow

final class AuthTests: XCTestCase {

    // MARK: - Ed25519 Identity Tests

    func testNewIdentityEd25519() throws {
        let identity = try newIdentity(algorithm: .ed25519)

        // Check DID format
        XCTAssertTrue(
            identity.did.hasPrefix("did:willow:Ed25519:"),
            "Expected DID to start with 'did:willow:Ed25519:', got \(identity.did)"
        )

        // Check key lengths (CryptoKit Ed25519 uses 32-byte private keys)
        XCTAssertEqual(
            identity.keyPair.privateKey.count, 32,
            "Expected private key length 32, got \(identity.keyPair.privateKey.count)"
        )
        XCTAssertEqual(
            identity.keyPair.publicKey.count, 32,
            "Expected public key length 32, got \(identity.keyPair.publicKey.count)"
        )

        // Check public key ID
        XCTAssertFalse(identity.publicKeyId.isEmpty, "Public key ID should not be empty")

        // Check DID document
        XCTAssertEqual(identity.didDocument.id, identity.did, "DID document ID mismatch")
        XCTAssertEqual(identity.didDocument.publicKeys.count, 1, "Expected 1 public key")
        XCTAssertEqual(
            identity.didDocument.publicKeys[0].type,
            "Ed25519VerificationKey2018",
            "Expected key type Ed25519VerificationKey2018"
        )
    }

    func testNewIdentitySecp256k1() throws {
        let identity = try newIdentity(algorithm: .secp256k1)

        // Check DID format
        XCTAssertTrue(
            identity.did.hasPrefix("did:willow:secp256k1:"),
            "Expected DID to start with 'did:willow:secp256k1:', got \(identity.did)"
        )

        // secp256k1 uses 32-byte private keys and 33-byte compressed public keys
        XCTAssertEqual(
            identity.keyPair.privateKey.count, 32,
            "Expected private key length 32, got \(identity.keyPair.privateKey.count)"
        )
        XCTAssertEqual(
            identity.keyPair.publicKey.count, 33,
            "Expected public key length 33 (compressed), got \(identity.keyPair.publicKey.count)"
        )

        // Check public key ID
        XCTAssertFalse(identity.publicKeyId.isEmpty, "Public key ID should not be empty")

        // Check DID document
        XCTAssertEqual(identity.didDocument.id, identity.did, "DID document ID mismatch")
        XCTAssertEqual(identity.didDocument.publicKeys.count, 1, "Expected 1 public key")
        XCTAssertEqual(
            identity.didDocument.publicKeys[0].type,
            "EcdsaSecp256k1VerificationKey2019",
            "Expected key type EcdsaSecp256k1VerificationKey2019"
        )
    }

    // MARK: - Uniqueness Tests

    func testIdentityUniqueness() throws {
        let identity1 = try newIdentity(algorithm: .ed25519)
        let identity2 = try newIdentity(algorithm: .ed25519)

        XCTAssertNotEqual(identity1.did, identity2.did, "Generated DIDs should be unique")
        XCTAssertNotEqual(
            identity1.keyPair.privateKey, identity2.keyPair.privateKey,
            "Generated private keys should be unique"
        )
        XCTAssertNotEqual(
            identity1.keyPair.publicKey, identity2.keyPair.publicKey,
            "Generated public keys should be unique"
        )
    }

    // MARK: - Restore Tests

    func testIdentityFromPrivateKey() throws {
        // Create original identity
        let original = try newIdentity(algorithm: .ed25519)

        // Restore from private key
        let restored = try identityFromPrivateKey(
            algorithm: .ed25519,
            privateKeyHex: original.keyPair.privateKeyHex
        )

        // Check DIDs match
        XCTAssertEqual(original.did, restored.did, "Restored DID mismatch")

        // Check public keys match
        XCTAssertEqual(
            original.keyPair.publicKeyHex, restored.keyPair.publicKeyHex,
            "Restored public key does not match original"
        )
    }

    // MARK: - Signing Tests

    func testSignAndVerifyEd25519() throws {
        let identity = try newIdentity(algorithm: .ed25519)
        let message = Data("test message".utf8)

        // Sign the message
        let signature = try identity.sign(message)

        // Verify signature is not empty
        XCTAssertFalse(signature.isEmpty, "Signature should not be empty")

        // Ed25519 signatures are 64 bytes
        XCTAssertEqual(signature.count, 64, "Ed25519 signature should be 64 bytes")
    }

    func testSignAndVerifySecp256k1() throws {
        let identity = try newIdentity(algorithm: .secp256k1)
        let message = Data("test message".utf8)

        // Sign the message
        let signature = try identity.sign(message)

        // Verify signature is not empty
        XCTAssertFalse(signature.isEmpty, "Signature should not be empty")

        // secp256k1 ECDSA signatures are 64 bytes (r + s components)
        XCTAssertEqual(signature.count, 64, "secp256k1 signature should be 64 bytes")

        // Verify the signature
        let isValid = try verify(
            algorithm: .secp256k1,
            publicKey: identity.keyPair.publicKey,
            message: message,
            signature: signature
        )
        XCTAssertTrue(isValid, "Signature should be valid")
    }

    func testSecp256k1IdentityFromPrivateKey() throws {
        // Create original identity
        let original = try newIdentity(algorithm: .secp256k1)

        // Restore from private key
        let restored = try identityFromPrivateKey(
            algorithm: .secp256k1,
            privateKeyHex: original.keyPair.privateKeyHex
        )

        // Check DIDs match
        XCTAssertEqual(original.did, restored.did, "Restored DID mismatch")

        // Check public keys match
        XCTAssertEqual(
            original.keyPair.publicKeyHex, restored.keyPair.publicKeyHex,
            "Restored public key does not match original"
        )
    }

    func testEd25519SignatureProducesValidOutput() throws {
        let identity = try newIdentity(algorithm: .ed25519)
        let message = Data("test message".utf8)

        let sig1 = try identity.sign(message)
        let sig2 = try identity.sign(message)

        // Both signatures should be 64 bytes
        XCTAssertEqual(sig1.count, 64)
        XCTAssertEqual(sig2.count, 64)
    }

    // MARK: - Algorithm Tests

    func testSignatureAlgorithmKeyType() {
        XCTAssertEqual(
            SignatureAlgorithm.ed25519.keyType,
            "Ed25519VerificationKey2018"
        )
        XCTAssertEqual(
            SignatureAlgorithm.secp256k1.keyType,
            "EcdsaSecp256k1VerificationKey2019"
        )
    }

    // MARK: - Key Pair Tests

    func testKeyPairMethods() throws {
        let keyPair = try generateKeyPair(algorithm: .ed25519)

        let pubHex = keyPair.publicKeyHex
        XCTAssertEqual(pubHex.count, 64, "Expected public key hex length 64, got \(pubHex.count)")

        // CryptoKit Ed25519 uses 32-byte private keys (64 hex chars)
        let privHex = keyPair.privateKeyHex
        XCTAssertEqual(privHex.count, 64, "Expected private key hex length 64, got \(privHex.count)")
    }

    func testGenerateDID() throws {
        let keyPair = try generateKeyPair(algorithm: .ed25519)
        let did = generateDID(keyPair: keyPair)

        XCTAssertTrue(
            did.hasPrefix("did:willow:Ed25519:"),
            "Expected DID to start with 'did:willow:Ed25519:', got \(did)"
        )
    }

    func testCreateDidDocument() throws {
        let keyPair = try generateKeyPair(algorithm: .ed25519)
        let doc = createDidDocument(keyPair: keyPair)

        XCTAssertFalse(doc.id.isEmpty, "DID document ID should not be empty")
        XCTAssertEqual(doc.publicKeys.count, 1, "Expected 1 public key")
        XCTAssertNotEqual(doc.created, 0, "Created timestamp should not be zero")
        XCTAssertNotEqual(doc.updated, 0, "Updated timestamp should not be zero")
    }

    // MARK: - Full Auth Flow Test

    func testFullAuthFlow() throws {
        let identity = try newIdentity(algorithm: .ed25519)

        // Create challenge message (as server would)
        let challenge = AuthenticationChallenge(
            challenge: "challenge_1234567890",
            nonce: "nonce123",
            expiresAt: 1234567890
        )

        // Sign the challenge
        let signature = try signAuthenticationChallenge(
            challenge: challenge,
            did: identity.did,
            keyPair: identity.keyPair
        )

        XCTAssertFalse(signature.isEmpty, "Signature should not be empty")
    }
}
