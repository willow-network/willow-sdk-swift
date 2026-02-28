import Foundation

// MARK: - Transaction Types

/// Transaction to link an ETH address to a Willow DID.
public struct LinkEthAddressTx: Codable {
    public var did: String
    public var ethAddress: String
    public var publicKeyId: String
    public var signature: String?
    public var nonce: UInt64?

    enum CodingKeys: String, CodingKey {
        case did
        case ethAddress = "eth_address"
        case publicKeyId = "public_key_id"
        case signature
        case nonce
    }

    public init(did: String, ethAddress: String, publicKeyId: String, signature: String? = nil, nonce: UInt64? = nil) {
        self.did = did
        self.ethAddress = ethAddress
        self.publicKeyId = publicKeyId
        self.signature = signature
        self.nonce = nonce
    }
}

/// Transaction to record an ERC-8004 agent registration.
public struct RegisterErc8004AgentTx: Codable {
    public var did: String
    public var chainId: UInt64
    public var registryAddress: String
    public var agentId: UInt64
    public var agentUri: String
    public var signature: String?
    public var publicKeyId: String?
    public var nonce: UInt64?

    enum CodingKeys: String, CodingKey {
        case did
        case chainId = "chain_id"
        case registryAddress = "registry_address"
        case agentId = "agent_id"
        case agentUri = "agent_uri"
        case signature
        case publicKeyId = "public_key_id"
        case nonce
    }

    public init(did: String, chainId: UInt64, registryAddress: String, agentId: UInt64, agentUri: String, signature: String? = nil, publicKeyId: String? = nil, nonce: UInt64? = nil) {
        self.did = did
        self.chainId = chainId
        self.registryAddress = registryAddress
        self.agentId = agentId
        self.agentUri = agentUri
        self.signature = signature
        self.publicKeyId = publicKeyId
        self.nonce = nonce
    }
}

// MARK: - Response Types

/// Summary of an agent's reputation.
public struct AgentReputationSummary: Codable {
    public var score: UInt32
    public var tier: String
    public var checkpointSuccessRate: Double
    public var verificationAccuracy: Double
    public var activeDays: UInt32
    public var lastUpdated: UInt64

    enum CodingKeys: String, CodingKey {
        case score
        case tier
        case checkpointSuccessRate = "checkpoint_success_rate"
        case verificationAccuracy = "verification_accuracy"
        case activeDays = "active_days"
        case lastUpdated = "last_updated"
    }
}

/// ERC-8004 compliant agent registration JSON.
public struct AgentRegistrationJson: Codable {
    public var type: String
    public var name: String
    public var description: String
    public var services: [AgentService]
    public var x402Support: Bool
    public var active: Bool
    public var registrations: [AgentChainRegistration]
    public var supportedTrust: [String]
    public var reputation: AgentReputationSummary?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case description
        case services
        case x402Support = "x402_support"
        case active
        case registrations
        case supportedTrust = "supported_trust"
        case reputation
    }
}

/// Reputation attestation with GroveDB Merkle proof.
public struct ReputationAttestation: Codable {
    public var did: String
    public var score: UInt32
    public var tier: String
    public var metrics: [String: AnyCodable]
    public var proof: String
    public var blockHeight: UInt64
    public var lastUpdated: UInt64

    enum CodingKeys: String, CodingKey {
        case did
        case score
        case tier
        case metrics
        case proof
        case blockHeight = "block_height"
        case lastUpdated = "last_updated"
    }
}

/// A single reputation history event.
public struct ReputationHistoryEvent: Codable {
    public var eventType: String
    public var scoreDelta: Int32
    public var newScore: UInt32
    public var blockHeight: UInt64
    public var timestamp: UInt64
    public var reference: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case scoreDelta = "score_delta"
        case newScore = "new_score"
        case blockHeight = "block_height"
        case timestamp
        case reference
    }
}

/// ERC-8004 formatted reputation history response.
public struct ReputationHistoryResponse: Codable {
    public var did: String
    public var events: [ReputationHistoryEvent]
    public var totalEvents: Int

    enum CodingKeys: String, CodingKey {
        case did
        case events
        case totalEvents = "total_events"
    }
}

/// Type-erased Codable wrapper for dynamic JSON values.
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else {
            value = try container.decode([String: AnyCodable].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let intVal = value as? Int {
            try container.encode(intVal)
        } else if let doubleVal = value as? Double {
            try container.encode(doubleVal)
        } else if let stringVal = value as? String {
            try container.encode(stringVal)
        } else if let boolVal = value as? Bool {
            try container.encode(boolVal)
        } else if let dictVal = value as? [String: AnyCodable] {
            try container.encode(dictVal)
        }
    }
}

/// A service advertised by the agent.
public struct AgentService: Codable {
    public var name: String
    public var endpoint: String
}

/// On-chain registration details.
public struct AgentChainRegistration: Codable {
    public var chainId: UInt64
    public var registry: String
    public var agentId: UInt64

    enum CodingKeys: String, CodingKey {
        case chainId = "chain_id"
        case registry
        case agentId = "agent_id"
    }
}

/// Stored ERC-8004 registration details.
public struct Erc8004Registration: Codable {
    public var chainId: UInt64
    public var registryAddress: [UInt8]
    public var agentId: UInt64
    public var agentUri: String
    public var registeredAt: UInt64

    enum CodingKeys: String, CodingKey {
        case chainId = "chain_id"
        case registryAddress = "registry_address"
        case agentId = "agent_id"
        case agentUri = "agent_uri"
        case registeredAt = "registered_at"
    }
}

// MARK: - Agent Discovery Types

/// Brief reputation summary in agent listings.
public struct AgentReputationBrief: Codable {
    public var score: Int64
    public var tier: String
}

/// A single agent in the discovery listing.
public struct Erc8004AgentListItem: Codable {
    public var did: String
    public var ethAddress: String?
    public var agentUri: String
    public var chainId: UInt64
    public var agentId: UInt64
    public var reputation: AgentReputationBrief
    public var validationCount: Int
    public var averageValidationScore: Double
    public var registeredAt: UInt64

    enum CodingKeys: String, CodingKey {
        case did
        case ethAddress = "eth_address"
        case agentUri = "agent_uri"
        case chainId = "chain_id"
        case agentId = "agent_id"
        case reputation
        case validationCount = "validation_count"
        case averageValidationScore = "average_validation_score"
        case registeredAt = "registered_at"
    }
}

/// Paginated response from the agent discovery endpoint.
public struct Erc8004AgentListResponse: Codable {
    public var agents: [Erc8004AgentListItem]
    public var total: Int
    public var offset: Int
    public var limit: Int
}

// MARK: - Validation Registry Types

/// A single ERC-8004 validation record.
public struct Erc8004ValidationRecord: Codable {
    public var requestHash: String
    public var subgroveId: String
    public var blockRange: [UInt64]
    public var stateRoot: String
    public var response: UInt32
    public var status: String
    public var teeVerified: Bool
    public var teeType: String?
    public var submittedAtBlock: UInt64
    public var challengeDeadline: UInt64?
    public var tag: String

    enum CodingKeys: String, CodingKey {
        case requestHash = "request_hash"
        case subgroveId = "subgrove_id"
        case blockRange = "block_range"
        case stateRoot = "state_root"
        case response
        case status
        case teeVerified = "tee_verified"
        case teeType = "tee_type"
        case submittedAtBlock = "submitted_at_block"
        case challengeDeadline = "challenge_deadline"
        case tag
    }
}

/// Response for the validation-status endpoint.
public struct Erc8004ValidationStatusResponse: Codable {
    public var did: String
    public var validations: [Erc8004ValidationRecord]
    public var total: Int
}

/// Breakdown of validation statuses.
public struct ValidationStatusBreakdown: Codable {
    public var trusted: UInt64
    public var pendingChallenge: UInt64
    public var teeAttested: UInt64
    public var disputed: UInt64
    public var invalidated: UInt64

    enum CodingKeys: String, CodingKey {
        case trusted
        case pendingChallenge = "pending_challenge"
        case teeAttested = "tee_attested"
        case disputed
        case invalidated
    }
}

/// Dispute participation statistics.
public struct DisputeStats: Codable {
    public var disputesWonAsDefendant: UInt64
    public var disputesLostAsDefendant: UInt64
    public var disputesWonAsChallenger: UInt64
    public var disputesLostAsChallenger: UInt64

    enum CodingKeys: String, CodingKey {
        case disputesWonAsDefendant = "disputes_won_as_defendant"
        case disputesLostAsDefendant = "disputes_lost_as_defendant"
        case disputesWonAsChallenger = "disputes_won_as_challenger"
        case disputesLostAsChallenger = "disputes_lost_as_challenger"
    }
}

/// Aggregated ERC-8004 validation summary.
public struct Erc8004ValidationSummary: Codable {
    public var did: String
    public var count: Int
    public var averageResponse: Double
    public var statusBreakdown: ValidationStatusBreakdown
    public var disputeStats: DisputeStats

    enum CodingKeys: String, CodingKey {
        case did
        case count
        case averageResponse = "average_response"
        case statusBreakdown = "status_breakdown"
        case disputeStats = "dispute_stats"
    }
}

// MARK: - Client

/// Client for ERC-8004 agent identity operations.
public class Erc8004Client {
    private let baseURL: String
    private let session: URLSession

    public init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.session = session
    }

    /// List/search ERC-8004 registered agents with optional filters.
    public func listAgents(limit: Int? = nil, offset: Int? = nil, minScore: Int64? = nil, tier: String? = nil) async throws -> Erc8004AgentListResponse {
        var params: [String] = []
        if let limit = limit { params.append("limit=\(limit)") }
        if let offset = offset { params.append("offset=\(offset)") }
        if let minScore = minScore { params.append("min_score=\(minScore)") }
        if let tier = tier { params.append("tier=\(tier)") }
        let qs = params.isEmpty ? "" : "?\(params.joined(separator: "&"))"
        let data = try await get(path: "/agents\(qs)")
        return try JSONDecoder().decode(Erc8004AgentListResponse.self, from: data)
    }

    /// Fetch the ERC-8004 registration JSON for an agent DID.
    public func getAgentRegistration(did: String) async throws -> AgentRegistrationJson {
        let data = try await get(path: "/agent/\(did)/registration.json")
        return try JSONDecoder().decode(AgentRegistrationJson.self, from: data)
    }

    /// Get the ETH address linked to a DID.
    public func getEthAddress(did: String) async throws -> String? {
        struct Response: Codable { let eth_address: String }
        do {
            let data = try await get(path: "/did/\(did)/eth-address")
            let response = try JSONDecoder().decode(Response.self, from: data)
            return response.eth_address
        } catch {
            return nil
        }
    }

    /// Get the DID linked to an ETH address.
    public func getDidForEth(ethAddress: String) async throws -> String? {
        struct Response: Codable { let did: String }
        do {
            let data = try await get(path: "/eth-address/\(ethAddress)/did")
            let response = try JSONDecoder().decode(Response.self, from: data)
            return response.did
        } catch {
            return nil
        }
    }

    /// Get stored ERC-8004 registration details for a DID.
    public func getErc8004Details(did: String) async throws -> Erc8004Registration? {
        do {
            let data = try await get(path: "/did/\(did)/erc8004")
            return try JSONDecoder().decode(Erc8004Registration.self, from: data)
        } catch {
            return nil
        }
    }

    /// Fetch reputation attestation with GroveDB Merkle proof for a DID.
    public func getReputationAttestation(did: String) async throws -> ReputationAttestation {
        let data = try await get(path: "/agent/\(did)/reputation-attestation")
        return try JSONDecoder().decode(ReputationAttestation.self, from: data)
    }

    /// Fetch ERC-8004 formatted reputation history for a DID.
    public func getReputationHistory(did: String, limit: Int? = nil) async throws -> ReputationHistoryResponse {
        var path = "/agent/\(did)/reputation-history"
        if let limit = limit {
            path += "?limit=\(limit)"
        }
        let data = try await get(path: path)
        return try JSONDecoder().decode(ReputationHistoryResponse.self, from: data)
    }

    /// Fetch ERC-8004 validation status (checkpoint validations) for a DID.
    public func getValidationStatus(did: String, limit: Int? = nil, subgroveId: String? = nil) async throws -> Erc8004ValidationStatusResponse {
        var params: [String] = []
        if let limit = limit { params.append("limit=\(limit)") }
        if let sg = subgroveId { params.append("subgrove_id=\(sg)") }
        let qs = params.isEmpty ? "" : "?\(params.joined(separator: "&"))"
        let data = try await get(path: "/agent/\(did)/validation-status\(qs)")
        return try JSONDecoder().decode(Erc8004ValidationStatusResponse.self, from: data)
    }

    /// Fetch aggregated ERC-8004 validation summary for a DID.
    public func getValidationSummary(did: String, subgroveId: String? = nil) async throws -> Erc8004ValidationSummary {
        let qs = subgroveId != nil ? "?subgrove_id=\(subgroveId!)" : ""
        let data = try await get(path: "/agent/\(did)/validation-summary\(qs)")
        return try JSONDecoder().decode(Erc8004ValidationSummary.self, from: data)
    }

    // MARK: - Private

    private struct APIResponse: Codable {
        let success: Bool
        let data: Data?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case success, data, error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            success = try container.decode(Bool.self, forKey: .success)
            error = try container.decodeIfPresent(String.self, forKey: .error)
            // Store raw data for later decoding
            data = nil
        }
    }

    private func get(path: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // Extract the "data" field from the API envelope
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let innerData = json["data"] {
            return try JSONSerialization.data(withJSONObject: innerData)
        }
        return data
    }
}
