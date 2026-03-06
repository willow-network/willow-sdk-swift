import Foundation

// MARK: - Token Operations

/// Provides methods for token-related queries.
public class TokenOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    /// Retrieves information about the CAN token.
    public func getInfo() async throws -> TokenInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/token/info")
    }

    /// Retrieves the balance for a DID.
    public func getBalance(did: String) async throws -> BalanceInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/token/balance/\(did)")
    }

    /// Retrieves the balance for an app.
    public func getAppBalance(appId: String) async throws -> BalanceInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.get(path: "/token/balance/app/\(appId)")
    }

    /// Retrieves the balance for the authenticated user.
    public func getMyBalance() async throws -> BalanceInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }
        try client.requireAuth()

        guard let identity = client.getIdentity() else {
            throw AuthenticationError("Identity not set")
        }

        return try await getBalance(did: identity.did)
    }

    /// Retrieves the current fee schedule.
    public func getFeeSchedule() async throws -> FeeSchedule {
        guard let client = client else { throw NetworkError("Client deallocated") }

        do {
            return try await client.get(path: "/token/fees")
        } catch {
            // Try alternate endpoint
            return try await client.get(path: "/fees/schedule")
        }
    }

    /// Estimates the storage fee for the given data size.
    public func estimateStorageFee(dataSizeBytes: UInt64) async throws -> String {
        let schedule = try await getFeeSchedule()
        guard let costPerByte = UInt64(schedule.costPerByte) else { return "0" }
        return String(dataSizeBytes * costPerByte)
    }

    /// Estimates the query fee.
    public func estimateQueryFee() async throws -> String {
        let schedule = try await getFeeSchedule()
        return schedule.queryFee
    }

    /// Estimates the transaction fee for the given data size.
    public func estimateTransactionFee(dataSizeBytes: UInt64) async throws -> String {
        let schedule = try await getFeeSchedule()
        guard let baseTxCost = UInt64(schedule.baseTxCost),
              let costPerByte = UInt64(schedule.costPerByte) else { return "0" }
        return String(baseTxCost + dataSizeBytes * costPerByte)
    }
}
