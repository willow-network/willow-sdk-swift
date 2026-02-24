import Foundation

// MARK: - Error Types

/// Type of Willow error.
public enum WillowErrorType: String {
    case network = "network"
    case http = "http"
    case authentication = "authentication"
    case validation = "validation"
    case notFound = "not_found"
    case permissionDenied = "permission_denied"
    case serialization = "serialization"
    case crypto = "crypto"
    case proof = "proof"
    case lightClient = "light_client"
    case config = "config"
    case consensus = "consensus"
    case transaction = "transaction"
    case insufficientFunds = "insufficient_funds"
}

/// Main error type for the Willow SDK.
public struct WillowError: Error, LocalizedError, Equatable {
    public let type: WillowErrorType
    public let message: String
    public let cause: Error?

    public init(type: WillowErrorType, message: String, cause: Error? = nil) {
        self.type = type
        self.message = message
        self.cause = cause
    }

    public var errorDescription: String? {
        if let cause = cause {
            return "\(type.rawValue): \(message): \(cause.localizedDescription)"
        }
        return "\(type.rawValue): \(message)"
    }

    public static func == (lhs: WillowError, rhs: WillowError) -> Bool {
        return lhs.type == rhs.type
    }
}

// MARK: - HTTP Error

/// HTTP-specific error with status code.
public struct HTTPError: Error, LocalizedError {
    public let statusCode: Int
    public let message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    public var errorDescription: String? {
        return "HTTP \(statusCode): \(message)"
    }
}

// MARK: - Transaction Error

/// Transaction-specific error.
public struct TransactionError: Error, LocalizedError {
    public let message: String
    public let txHash: String?
    public let errorCode: Int

    public init(message: String, txHash: String? = nil, errorCode: Int = 0) {
        self.message = message
        self.txHash = txHash
        self.errorCode = errorCode
    }

    public var errorDescription: String? {
        if let txHash = txHash, !txHash.isEmpty {
            return "transaction error (code \(errorCode), tx \(txHash)): \(message)"
        }
        return "transaction error (code \(errorCode)): \(message)"
    }
}

// MARK: - Insufficient Funds Error

/// Error for insufficient funds.
public struct InsufficientFundsError: Error, LocalizedError {
    public let required: UInt64
    public let available: UInt64

    public init(required: UInt64, available: UInt64) {
        self.required = required
        self.available = available
    }

    public var errorDescription: String? {
        return "insufficient funds: required \(required), available \(available)"
    }
}

// MARK: - Sentinel Errors

/// Common error instances for comparison.
public enum WillowErrors {
    public static let notAuthenticated = WillowError(type: .authentication, message: "not authenticated")
}

// MARK: - Error Factory Functions

/// Creates a network error.
public func NetworkError(_ message: String, cause: Error? = nil) -> WillowError {
    return WillowError(type: .network, message: message, cause: cause)
}

/// Creates an authentication error.
public func AuthenticationError(_ message: String) -> WillowError {
    return WillowError(type: .authentication, message: message)
}

/// Creates a validation error.
public func ValidationError(_ message: String) -> WillowError {
    return WillowError(type: .validation, message: message)
}

/// Creates a not found error.
public func NotFoundError(_ resource: String) -> WillowError {
    return WillowError(type: .notFound, message: "\(resource) not found")
}

/// Creates a permission denied error.
public func PermissionDeniedError(_ message: String) -> WillowError {
    return WillowError(type: .permissionDenied, message: message)
}

/// Creates a serialization error.
public func SerializationError(_ message: String, cause: Error? = nil) -> WillowError {
    return WillowError(type: .serialization, message: message, cause: cause)
}

/// Creates a crypto error.
public func CryptoError(_ message: String, cause: Error? = nil) -> WillowError {
    return WillowError(type: .crypto, message: message, cause: cause)
}

/// Creates a proof verification error.
public func ProofError(_ message: String) -> WillowError {
    return WillowError(type: .proof, message: message)
}

/// Creates a light client error.
public func LightClientError(_ message: String, cause: Error? = nil) -> WillowError {
    return WillowError(type: .lightClient, message: message, cause: cause)
}

/// Creates a config error.
public func ConfigError(_ message: String) -> WillowError {
    return WillowError(type: .config, message: message)
}

/// Creates a consensus error.
public func ConsensusError(_ message: String, cause: Error? = nil) -> WillowError {
    return WillowError(type: .consensus, message: message, cause: cause)
}

/// Creates a GraphQL query error.
public func GraphQLQueryError(_ message: String) -> WillowError {
    return WillowError(type: .validation, message: message)
}

/// Creates a light client configuration error.
public func LightClientConfigError(_ message: String) -> WillowError {
    return WillowError(type: .config, message: message)
}

// MARK: - Error Checking Functions

/// Checks if an error indicates not authenticated.
public func isNotAuthenticated(_ error: Error) -> Bool {
    if let willowError = error as? WillowError {
        return willowError == WillowErrors.notAuthenticated
    }
    return false
}

/// Checks if an error is a not found error.
public func isNotFound(_ error: Error) -> Bool {
    if let willowError = error as? WillowError {
        return willowError.type == .notFound
    }
    return false
}

/// Checks if an error is a validation error.
public func isValidationError(_ error: Error) -> Bool {
    if let willowError = error as? WillowError {
        return willowError.type == .validation
    }
    return false
}

/// Checks if an error is an HTTP error and returns the status code.
public func isHTTPError(_ error: Error) -> Int? {
    if let httpError = error as? HTTPError {
        return httpError.statusCode
    }
    return nil
}
