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

    /// Reads serde's form: a unit variant as its name (`"EveryUpdate"`), a
    /// variant with a count as `{"EveryNBlocks": n}`.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
            switch value {
            case "EveryUpdate":
                self = .everyUpdate
            case "Never":
                self = .never
            default:
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Unknown CommitmentFrequency value: \(value)"
                )
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try container.decodeIfPresent(UInt64.self, forKey: .everyNBlocks) {
            self = .everyNBlocks(n)
        } else if let n = try container.decodeIfPresent(UInt64.self, forKey: .everyNSeconds) {
            self = .everyNSeconds(n)
        } else if container.contains(.everyUpdate) {
            self = .everyUpdate
        } else if container.contains(.never) {
            self = .never
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "Unknown CommitmentFrequency value"
            ))
        }
    }

    /// Writes serde's form: a unit variant as its name, a count as `{"EveryNBlocks": n}`.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .everyUpdate:
            var container = encoder.singleValueContainer()
            try container.encode("EveryUpdate")
        case .everyNBlocks(let n):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(n, forKey: .everyNBlocks)
        case .everyNSeconds(let n):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(n, forKey: .everyNSeconds)
        case .never:
            var container = encoder.singleValueContainer()
            try container.encode("Never")
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
    public var signature: [UInt8]
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
        signature: [UInt8] = [],
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
    public var signature: [UInt8]
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
        signature: [UInt8] = [],
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
    public var signature: [UInt8]
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
        signature: [UInt8] = [],
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

/// A key grant's GroveDB proof as `GET /proof/key-grant/{subgroveId}/{did}`
/// serves it.
public struct KeyGrantProofResponse: Codable {
    /// The proof bytes, from the hex the API serves.
    public let proof: Data
    public let subgroveId: String
    public let granteeDid: String

    enum CodingKeys: String, CodingKey {
        case proof
        case subgroveId = "subgrove_id"
        case granteeDid = "grantee_did"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hex = try container.decode(String.self, forKey: .proof)
        guard let bytes = Data(hexString: hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex) else {
            throw DecodingError.dataCorruptedError(forKey: .proof, in: container, debugDescription: "proof is not hex")
        }
        proof = bytes
        subgroveId = try container.decode(String.self, forKey: .subgroveId)
        granteeDid = try container.decode(String.self, forKey: .granteeDid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(proof.hexString, forKey: .proof)
        try container.encode(subgroveId, forKey: .subgroveId)
        try container.encode(granteeDid, forKey: .granteeDid)
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
/// the `WillowClient` REST API, which answers them only for a caller whose
/// request is signed with a one-time nonce; the client signs them so when an
/// identity is set. Transaction methods (`grantSubgroveKey`,
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

        let path = "/key-grants/\(pathSegment(subgroveId))/\(pathSegment(identity.did))"
        return try await client.getData(path: path, "key grant")
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

        let path = "/key-grants/\(pathSegment(subgroveId))"
        return try await client.getData(path: path, "key grantees")
    }

    /// Gets the GroveDB Merkle proof for a key grant.
    ///
    /// The API answers it only for a nonce-signed caller, so an identity
    /// must be set.
    ///
    /// - Parameters:
    ///   - subgroveId: The subgrove ID.
    ///   - did: The DID to get the key grant proof for.
    /// - Returns: The proof response containing proof bytes and root hash.
    public func getKeyGrantProof(subgroveId: String, did: String) async throws -> KeyGrantProofResponse {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        let path = "/proof/key-grant/\(pathSegment(subgroveId))/\(pathSegment(did))"
        return try await client.getData(path: path, "key grant proof")
    }

    // MARK: - Transaction Operations

    /// Grants a DID access to a subgrove's encryption key.
    ///
    /// Broadcasts a `GrantSubgroveKey` transaction via consensus.
    /// `signFunction` signs `grantSubgroveKeyMessage` over the subgrove ID, the
    /// sender DID, every field of the grant, and the transaction's nonce. A
    /// text field holding a line break is refused with a validation error
    /// before anything is signed.
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

        // Refuse a line break before spending a request on the nonce.
        _ = try grantSubgroveKeyMessage(subgroveId: subgroveId, senderDid: identity.did, grant: grant, nonce: 0)

        return try await consensus.submitUnderNextNonce(did: identity.did) { nonce in
            var tx = GrantSubgroveKeyTx(
                subgroveId: subgroveId,
                encryptedKeyGrant: grant,
                senderDid: identity.did,
                publicKeyId: identity.publicKeyId,
                nonce: nonce
            )
            let signMessage = try grantSubgroveKeyMessage(
                subgroveId: tx.subgroveId,
                senderDid: tx.senderDid,
                grant: tx.encryptedKeyGrant,
                nonce: unsignedField("nonce", tx.nonce, as: UInt64.self)
            )
            tx.signature = Array(try signFunction(Data(signMessage.utf8), privateKey))
            return try encodeTransaction(txType: "GrantSubgroveKey", transaction: tx)
        }
    }

    /// Revokes a DID's access to a subgrove's encryption key.
    ///
    /// Broadcasts a `RevokeSubgroveKey` transaction via consensus, signed over
    /// `revokeSubgroveKeyMessage`.
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

        return try await consensus.submitUnderNextNonce(did: identity.did) { nonce in
            var tx = RevokeSubgroveKeyTx(
                subgroveId: subgroveId,
                revokeeDid: revokeeDid,
                senderDid: identity.did,
                publicKeyId: identity.publicKeyId,
                nonce: nonce
            )
            let signMessage = revokeSubgroveKeyMessage(
                subgroveId: tx.subgroveId,
                revokeeDid: tx.revokeeDid,
                senderDid: tx.senderDid,
                nonce: try unsignedField("nonce", tx.nonce, as: UInt64.self)
            )
            tx.signature = Array(try signFunction(Data(signMessage.utf8), privateKey))
            return try encodeTransaction(txType: "RevokeSubgroveKey", transaction: tx)
        }
    }

    /// Rotates the subgrove encryption key to a new epoch with new grants.
    ///
    /// Broadcasts a `RotateSubgroveKey` transaction via consensus. This replaces
    /// the current encryption key with a new one and re-grants access to the
    /// specified DIDs with the new key material. `signFunction` signs
    /// `rotateSubgroveKeyMessage` over the subgrove ID, the sender DID, the new
    /// epoch, every field of every grant in order, and the transaction's nonce.
    /// A text field holding a line break is refused with a validation error
    /// before anything is signed.
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

        // Refuse a line break before spending a request on the nonce.
        _ = try rotateSubgroveKeyMessage(subgroveId: subgroveId, senderDid: identity.did, newEpoch: newEpoch, newGrants: newGrants, nonce: 0)

        return try await consensus.submitUnderNextNonce(did: identity.did) { nonce in
            var tx = RotateSubgroveKeyTx(
                subgroveId: subgroveId,
                newEpoch: newEpoch,
                newGrants: newGrants,
                senderDid: identity.did,
                publicKeyId: identity.publicKeyId,
                nonce: nonce
            )
            let signMessage = try rotateSubgroveKeyMessage(
                subgroveId: tx.subgroveId,
                senderDid: tx.senderDid,
                newEpoch: tx.newEpoch,
                newGrants: tx.newGrants,
                nonce: unsignedField("nonce", tx.nonce, as: UInt64.self)
            )
            tx.signature = Array(try signFunction(Data(signMessage.utf8), privateKey))
            return try encodeTransaction(txType: "RotateSubgroveKey", transaction: tx)
        }
    }
}
