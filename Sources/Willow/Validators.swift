import Foundation

// MARK: - Validator Operations

/// Provides methods for validator-related queries.
public class ValidatorOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    /// Retrieves the validators `GET /validators` lists: the active, unjailed ones.
    public func list() async throws -> [ValidatorInfo] {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.getData(path: "/validators", "validators")
    }

    /// Retrieves one validator by its DID (`GET /validators/{did}`).
    public func get(address: String) async throws -> ValidatorInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.getData(path: "/validators/\(pathSegment(address))", "validator")
    }

    /// Retrieves all active validators.
    public func getActive() async throws -> [ValidatorInfo] {
        let validators = try await list()
        return validators.filter { $0.status == .active }
    }

    /// Returns the total stake of all active validators, in the token's
    /// smallest unit, as decimal digits.
    public func getTotalStake() async throws -> String {
        var total = U128.zero
        for validator in try await list() where validator.status == .active {
            guard let stake = U128(validator.totalStake), let sum = total.adding(stake) else {
                throw SerializationError("Validator stake \(validator.totalStake) is not a u128 amount")
            }
            total = sum
        }
        return total.description
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
