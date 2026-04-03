import Foundation

// MARK: - Privacy Configuration

/// Privacy configuration for a private subgrove.
public struct PrivacyConfig: Codable {
    /// Optional whitelist of indexer DIDs allowed to index this subgrove.
    public var allowedIndexers: [String]?
    /// How often the provider must commit state roots to consensus.
    public var commitmentFrequency: CommitmentFrequency

    enum CodingKeys: String, CodingKey {
        case allowedIndexers = "allowed_indexers"
        case commitmentFrequency = "commitment_frequency"
    }

    public init(allowedIndexers: [String]? = nil, commitmentFrequency: CommitmentFrequency = .everyUpdate) {
        self.allowedIndexers = allowedIndexers
        self.commitmentFrequency = commitmentFrequency
    }
}

/// How often the provider must publish state root commitments on-chain.
public enum CommitmentFrequency: Codable, Equatable {
    /// Commit after every write/block update.
    case everyUpdate
    /// Commit every N blocks processed.
    case everyNBlocks(UInt64)
    /// Commit at least every N seconds.
    case everyNSeconds(UInt64)
    /// No on-chain commitments.
    case never

    enum CodingKeys: String, CodingKey {
        case everyUpdate = "EveryUpdate"
        case everyNBlocks = "EveryNBlocks"
        case everyNSeconds = "EveryNSeconds"
        case never = "Never"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if (try? container.decodeNil(forKey: .everyUpdate)) == false || container.contains(.everyUpdate) {
            if let _ = try? container.decode(String.self, forKey: .everyUpdate) {
                self = .everyUpdate
                return
            }
            self = .everyUpdate
            return
        }
        if let n = try? container.decode(UInt64.self, forKey: .everyNBlocks) {
            self = .everyNBlocks(n)
            return
        }
        if let n = try? container.decode(UInt64.self, forKey: .everyNSeconds) {
            self = .everyNSeconds(n)
            return
        }
        if container.contains(.never) {
            self = .never
            return
        }

        // Try single-value string for simple variants
        let singleContainer = try decoder.singleValueContainer()
        let value = try singleContainer.decode(String.self)
        switch value {
        case "EveryUpdate":
            self = .everyUpdate
        case "Never":
            self = .never
        default:
            throw DecodingError.dataCorruptedError(
                in: singleContainer,
                debugDescription: "Unknown CommitmentFrequency value: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .everyUpdate:
            try container.encode("EveryUpdate", forKey: .everyUpdate)
        case .everyNBlocks(let n):
            try container.encode(n, forKey: .everyNBlocks)
        case .everyNSeconds(let n):
            try container.encode(n, forKey: .everyNSeconds)
        case .never:
            try container.encode("Never", forKey: .never)
        }
    }
}

// MARK: - Encrypted Key Grant

/// An encrypted key grant for a subgrove.
///
/// Contains the encryption key material needed for a grantee to decrypt
/// a private subgrove's data, encrypted to the grantee's public key.
public struct EncryptedKeyGrant: Codable {
    /// DID of the grantee receiving access.
    public let granteeDid: String
    /// Key epoch this grant is valid for.
    public let keyEpoch: UInt32
    /// ID of the grantee's public key used for encryption.
    public let granteePublicKeyId: String
    /// Ephemeral public key used in the key exchange.
    public let ephemeralPublicKey: [UInt8]
    /// The subgrove key encrypted to the grantee's public key.
    public let encryptedKey: [UInt8]
    /// DID of the entity that created this grant.
    public let grantedBy: String
    /// Timestamp when the grant was created (Unix seconds).
    public let grantedAt: UInt64

    enum CodingKeys: String, CodingKey {
        case granteeDid = "grantee_did"
        case keyEpoch = "key_epoch"
        case granteePublicKeyId = "grantee_public_key_id"
        case ephemeralPublicKey = "ephemeral_public_key"
        case encryptedKey = "encrypted_key"
        case grantedBy = "granted_by"
        case grantedAt = "granted_at"
    }

    public init(
        granteeDid: String,
        keyEpoch: UInt32,
        granteePublicKeyId: String,
        ephemeralPublicKey: [UInt8],
        encryptedKey: [UInt8],
        grantedBy: String,
        grantedAt: UInt64
    ) {
        self.granteeDid = granteeDid
        self.keyEpoch = keyEpoch
        self.granteePublicKeyId = granteePublicKeyId
        self.ephemeralPublicKey = ephemeralPublicKey
        self.encryptedKey = encryptedKey
        self.grantedBy = grantedBy
        self.grantedAt = grantedAt
    }
}

// MARK: - Transaction Types

/// Transaction for granting a subgrove encryption key.
public struct GrantSubgroveKeyTx: Codable {
    public var subgroveId: String
    public var encryptedKeyGrant: EncryptedKeyGrant
    public var senderDid: String
    public var signature: String
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case encryptedKeyGrant = "encrypted_key_grant"
        case senderDid = "sender_did"
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(
        subgroveId: String,
        encryptedKeyGrant: EncryptedKeyGrant,
        senderDid: String,
        signature: String = "",
        publicKeyId: String,
        nonce: Int
    ) {
        self.subgroveId = subgroveId
        self.encryptedKeyGrant = encryptedKeyGrant
        self.senderDid = senderDid
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }
}

/// Transaction for revoking a subgrove encryption key.
public struct RevokeSubgroveKeyTx: Codable {
    public var subgroveId: String
    public var revokeeDid: String
    public var senderDid: String
    public var signature: String
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case revokeeDid = "revokee_did"
        case senderDid = "sender_did"
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(
        subgroveId: String,
        revokeeDid: String,
        senderDid: String,
        signature: String = "",
        publicKeyId: String,
        nonce: Int
    ) {
        self.subgroveId = subgroveId
        self.revokeeDid = revokeeDid
        self.senderDid = senderDid
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }
}

/// Transaction for rotating a subgrove encryption key.
public struct RotateSubgroveKeyTx: Codable {
    public var subgroveId: String
    public var newEpoch: UInt32
    public var newGrants: [EncryptedKeyGrant]
    public var senderDid: String
    public var signature: String
    public var publicKeyId: String
    public var nonce: Int

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case newEpoch = "new_epoch"
        case newGrants = "new_grants"
        case senderDid = "sender_did"
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(
        subgroveId: String,
        newEpoch: UInt32,
        newGrants: [EncryptedKeyGrant],
        senderDid: String,
        signature: String = "",
        publicKeyId: String,
        nonce: Int
    ) {
        self.subgroveId = subgroveId
        self.newEpoch = newEpoch
        self.newGrants = newGrants
        self.senderDid = senderDid
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }
}

// MARK: - Key Grant Proof Response

/// Response containing a GroveDB Merkle proof for a key grant.
public struct KeyGrantProofResponse: Codable {
    public let proof: Data?
    public let rootHash: String?

    enum CodingKeys: String, CodingKey {
        case proof
        case rootHash = "root_hash"
    }
}

// MARK: - Privacy Operations

/// Provides methods for managing private subgroves.
///
/// This class handles key grant management for private subgroves, including
/// querying grants via the REST API and broadcasting grant/revoke/rotate
/// transactions via the consensus client.
///
/// Query methods (`getMyKeyGrant`, `listKeyGrantees`, `getKeyGrantProof`) use
/// the `WillowClient` REST API. Transaction methods (`grantSubgroveKey`,
/// `revokeSubgroveKey`, `rotateSubgroveKey`) require a `ConsensusClient` to
/// broadcast transactions to the blockchain.
public class PrivacyOperations {
    private weak var client: WillowClient?
    private let consensus: ConsensusClient

    /// Creates privacy operations.
    ///
    /// - Parameters:
    ///   - client: The Willow REST API client for query operations.
    ///   - consensus: The consensus client for broadcasting transactions.
    public init(client: WillowClient, consensus: ConsensusClient) {
        self.client = client
        self.consensus = consensus
    }

    // MARK: - Query Operations

    /// Gets the encryption key grant for the authenticated DID.
    ///
    /// Returns the encrypted key grant that allows the current identity
    /// to decrypt a private subgrove's data.
    ///
    /// - Parameters:
    ///   - subgroveId: The subgrove ID.
    /// - Returns: The encrypted key grant for this DID.
    /// - Throws: `AuthenticationError` if no identity is set. `NotFoundError` if no grant exists.
    public func getMyKeyGrant(subgroveId: String) async throws -> EncryptedKeyGrant {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        guard let identity = client.getIdentity() else {
            throw AuthenticationError("Identity not set")
        }

        let path = "/key-grants/\(subgroveId)/\(identity.did)"
        let response: ApiResponse<EncryptedKeyGrant> = try await client.get(path: path)

        guard let grant = response.data else {
            throw NotFoundError("Key grant")
        }

        return grant
    }

    /// Lists all grantee DIDs for a subgrove.
    ///
    /// Only the subgrove owner or admin can call this.
    ///
    /// - Parameters:
    ///   - subgroveId: The subgrove ID.
    /// - Returns: Array of DID strings that have been granted access.
    /// - Throws: `AuthenticationError` if no identity is set.
    public func listKeyGrantees(subgroveId: String) async throws -> [String] {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/key-grants/\(subgroveId)"
        let response: ApiResponse<[String]> = try await client.get(path: path)

        guard let grantees = response.data else {
            throw NotFoundError("Key grantees")
        }

        return grantees
    }

    /// Gets the GroveDB Merkle proof for a key grant.
    ///
    /// Public endpoint -- proofs are non-sensitive.
    ///
    /// - Parameters:
    ///   - subgroveId: The subgrove ID.
    ///   - did: The DID to get the key grant proof for.
    /// - Returns: The proof response containing proof bytes and root hash.
    public func getKeyGrantProof(subgroveId: String, did: String) async throws -> KeyGrantProofResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let path = "/proof/key-grant/\(subgroveId)/\(did)"
        let response: ApiResponse<KeyGrantProofResponse> = try await client.get(path: path)

        guard let proof = response.data else {
            throw NotFoundError("Key grant proof")
        }

        return proof
    }

    // MARK: - Transaction Operations

    /// Grants a DID access to a subgrove's encryption key.
    ///
    /// Broadcasts a `GrantSubgroveKey` transaction via consensus.
    ///
    /// - Parameters:
    ///   - subgroveId: The subgrove ID.
    ///   - grant: The encrypted key grant containing the encrypted key material.
    ///   - privateKey: The sender's private key for signing.
    ///   - signFunction: Function to sign the transaction message.
    /// - Returns: The broadcast result with transaction hash and status.
    /// - Throws: `AuthenticationError` if no identity is set.
    public func grantSubgroveKey(
        subgroveId: String,
        grant: EncryptedKeyGrant,
        privateKey: Data,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        guard let identity = client.getIdentity() else {
            throw AuthenticationError("Identity not set")
        }

        let nonce = try await consensus.getNextNonce(did: identity.did)

        let signMessage = "GrantSubgroveKey:\(subgroveId):\(grant.granteeDid):\(identity.did):\(nonce)"
        let signatureData = try signFunction(Data(signMessage.utf8), privateKey)

        var tx = GrantSubgroveKeyTx(
            subgroveId: subgroveId,
            encryptedKeyGrant: grant,
            senderDid: identity.did,
            publicKeyId: identity.publicKeyId,
            nonce: nonce
        )
        tx.signature = signatureData.map { String(format: "%02x", $0) }.joined()

        return try await consensus.broadcastPrivacyTransaction(txType: "GrantSubgroveKey", transaction: tx)
    }

    /// Revokes a DID's access to a subgrove's encryption key.
    ///
    /// Broadcasts a `RevokeSubgroveKey` transaction via consensus.
    ///
    /// - Parameters:
    ///   - subgroveId: The subgrove ID.
    ///   - revokeeDid: The DID to revoke access from.
    ///   - privateKey: The sender's private key for signing.
    ///   - signFunction: Function to sign the transaction message.
    /// - Returns: The broadcast result with transaction hash and status.
    /// - Throws: `AuthenticationError` if no identity is set.
    public func revokeSubgroveKey(
        subgroveId: String,
        revokeeDid: String,
        privateKey: Data,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        guard let identity = client.getIdentity() else {
            throw AuthenticationError("Identity not set")
        }

        let nonce = try await consensus.getNextNonce(did: identity.did)

        let signMessage = "RevokeSubgroveKey:\(subgroveId):\(revokeeDid):\(identity.did):\(nonce)"
        let signatureData = try signFunction(Data(signMessage.utf8), privateKey)

        var tx = RevokeSubgroveKeyTx(
            subgroveId: subgroveId,
            revokeeDid: revokeeDid,
            senderDid: identity.did,
            publicKeyId: identity.publicKeyId,
            nonce: nonce
        )
        tx.signature = signatureData.map { String(format: "%02x", $0) }.joined()

        return try await consensus.broadcastPrivacyTransaction(txType: "RevokeSubgroveKey", transaction: tx)
    }

    /// Rotates the subgrove encryption key to a new epoch with new grants.
    ///
    /// Broadcasts a `RotateSubgroveKey` transaction via consensus. This replaces
    /// the current encryption key with a new one and re-grants access to the
    /// specified DIDs with the new key material.
    ///
    /// - Parameters:
    ///   - subgroveId: The subgrove ID.
    ///   - newEpoch: The new key epoch number.
    ///   - newGrants: Array of encrypted key grants for the new epoch.
    ///   - privateKey: The sender's private key for signing.
    ///   - signFunction: Function to sign the transaction message.
    /// - Returns: The broadcast result with transaction hash and status.
    /// - Throws: `AuthenticationError` if no identity is set.
    public func rotateSubgroveKey(
        subgroveId: String,
        newEpoch: UInt32,
        newGrants: [EncryptedKeyGrant],
        privateKey: Data,
        signFunction: (Data, Data) throws -> Data
    ) async throws -> BroadcastResult {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        guard let identity = client.getIdentity() else {
            throw AuthenticationError("Identity not set")
        }

        let nonce = try await consensus.getNextNonce(did: identity.did)

        let signMessage = "RotateSubgroveKey:\(subgroveId):\(newEpoch):\(identity.did):\(nonce)"
        let signatureData = try signFunction(Data(signMessage.utf8), privateKey)

        var tx = RotateSubgroveKeyTx(
            subgroveId: subgroveId,
            newEpoch: newEpoch,
            newGrants: newGrants,
            senderDid: identity.did,
            publicKeyId: identity.publicKeyId,
            nonce: nonce
        )
        tx.signature = signatureData.map { String(format: "%02x", $0) }.joined()

        return try await consensus.broadcastPrivacyTransaction(txType: "RotateSubgroveKey", transaction: tx)
    }
}
