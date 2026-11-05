import Foundation

// MARK: - Token Operations

/// Provides methods for token-related queries.
public class TokenOperations {
    private weak var client: WillowClient?

    internal init(client: WillowClient) {
        self.client = client
    }

    /// Retrieves information about the WILL token (`GET /token/info`).
    public func getInfo() async throws -> TokenInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.getData(path: "/token/info", "token info")
    }

    /// Retrieves the balance for a DID (`GET /token/balance/{did}`).
    public func getBalance(did: String) async throws -> BalanceInfo {
        guard let client = client else { throw NetworkError("Client deallocated") }

        return try await client.getData(path: "/token/balance/\(pathSegment(did))", "balance")
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

    /// Retrieves the current fee schedule (`GET /fees/schedule`).
    public func getFeeSchedule() async throws -> FeeSchedule {
        guard let client = client else { throw NetworkError("Client deallocated") }

        let response: ApiResponse<FeeSchedule> = try await client.get(path: "/fees/schedule")
        return try client.unwrap(response, "fee schedule")
    }

    /// Estimates the storage fee for the given data size.
    public func estimateStorageFee(dataSizeBytes: UInt64) async throws -> String {
        let schedule = try await getFeeSchedule()
        guard let costPerByte = UInt64(schedule.costPerByte) else { return "0" }
        // The full 128-bit product: a fee schedule's price can't overflow it.
        let fee = dataSizeBytes.multipliedFullWidth(by: costPerByte)
        return U128(high: fee.high, low: fee.low).description
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
        // At most (2^64 - 1)^2 + 2^64 - 1, which fits in 128 bits.
        let perByte = dataSizeBytes.multipliedFullWidth(by: costPerByte)
        guard let fee = U128(high: perByte.high, low: perByte.low).adding(U128(baseTxCost)) else {
            throw ValidationError("The transaction fee doesn't fit in 128 bits")
        }
        return fee.description
    }
}
