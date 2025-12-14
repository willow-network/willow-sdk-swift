import Foundation

// MARK: - Validator Operations

/// Provides methods for validator-related queries.
public class ValidatorOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    /// Retrieves all validators.
    public func list() async throws -> [ValidatorInfo] {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/validators")
    }

    /// Retrieves information about a specific validator.
    public func get(address: String) async throws -> ValidatorInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/validators/\(address)")
    }

    /// Retrieves all active validators.
    public func getActive() async throws -> [ValidatorInfo] {
        let validators = try await list()
        return validators.filter { $0.status == .active }
    }

    /// Returns the total voting power of all active validators.
    public func getTotalVotingPower() async throws -> Int64 {
        let validators = try await list()
        return validators
            .filter { $0.status == .active }
            .reduce(0) { $0 + $1.votingPower }
    }

    /// Returns the number of active validators.
    public func getActiveCount() async throws -> Int {
        let validators = try await getActive()
        return validators.count
    }

    /// Checks if a validator is active.
    public func isActive(address: String) async throws -> Bool {
        let validator = try await get(address: address)
        return validator.status == .active
    }
}
