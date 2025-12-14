import Foundation

// MARK: - Devnet Test Account

/// Pre-funded test account credentials for local devnet development.
///
/// This account is pre-registered and funded in the devnet genesis.
/// Use it for SDK testing and development - DO NOT use in production!
///
/// Example usage:
/// ```swift
/// let client = try WillowClient(baseURL: "http://localhost:3031")
/// let identity = try DevnetTestAccount.toIdentity()
/// try await client.authenticate(identity)
/// ```
public struct DevnetTestAccount {
    /// DID of the test account.
    public static let did = "did:willow:devnet-test"

    /// Private key (hex) - DO NOT USE IN PRODUCTION.
    public static let privateKey = "b5ecc03536f5e039e3c5bc46ad178d7faf80cee5f063016a4f4084e163409b3c"

    /// Public key (hex).
    public static let publicKey = "c153874d3d284a11e3cb12b524e1a9cc32fef966d56b903c79688a95d5193c8f"

    /// Key ID for authentication.
    public static let publicKeyId = "did:willow:devnet-test#key-1"

    /// Converts the test account credentials to an Identity for authentication.
    ///
    /// This creates an Identity with the pre-registered devnet-test DID,
    /// not a newly generated DID from the key.
    ///
    /// - Returns: An Identity configured with the devnet test credentials.
    /// - Throws: If the private key cannot be parsed.
    public static func toIdentity() throws -> Identity {
        // Create key pair from private key
        let keyPair = try keyPairFromPrivateKey(algorithm: .ed25519, privateKeyHex: privateKey)

        // Create DID document with the pre-registered DID (not generated from key)
        let now = Int64(Date().timeIntervalSince1970)
        let publicKeyEntry = PublicKey(
            id: publicKeyId,
            type: SignatureAlgorithm.ed25519.keyType,
            publicKeyHex: publicKey
        )
        let didDocument = DidDocument(
            id: did,
            publicKeys: [publicKeyEntry],
            created: now,
            updated: now
        )

        return Identity(keyPair: keyPair, didDocument: didDocument)
    }

    private init() {} // Prevent instantiation
}

/// Global constant for convenient access to the devnet test account.
///
/// Example:
/// ```swift
/// let identity = try DEVNET_TEST_ACCOUNT.toIdentity()
/// ```
public let DEVNET_TEST_ACCOUNT = DevnetTestAccount.self
