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
    /// A verified read the SDK can't check as asked, though nothing shows the
    /// API's answer is wrong (see `NotVerifiableError`).
    case notVerifiable = "not_verifiable"
    /// A verified read whose proof is of a state too far from the chain's
    /// latest height (see `ProofHeightOutOfRangeError`).
    case proofHeightOutOfRange = "proof_height_out_of_range"
    case lightClient = "light_client"
    case config = "config"
    case consensus = "consensus"
    case transaction = "transaction"
    case insufficientFunds = "insufficient_funds"
    /// An answer longer than the SDK's cap for its route, refused before any
    /// of it is decoded and not retried. The caps: 4 MiB for answers of a
    /// fixed shape (an account's nonce, a balance, a subgrove's entry, a
    /// file's manifest, a `/tx/submit` answer, CometBFT's status, commit,
    /// validators, and ABCI queries); 2 MiB and 64 KiB for a `/proof` of one
    /// key; 2 MiB for a file chunk (less when the manifest's chunk is
    /// smaller); 12 MiB for a `/data` value and CometBFT's `tx`; 64 MiB for
    /// queries, GraphQL, SQL, historical queries, matched logs, Ethereum
    /// state and call answers, and the lists the node doesn't page
    /// (subgroves, indexers, validators, key grantees, permissions). A query
    /// past its cap asks for less (a lower limit, a narrower query).
    case responseTooLarge = "response_too_large"
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

/// Transaction-specific error: CheckTx refused the transaction.
public struct TransactionError: Error, LocalizedError {
    public let message: String
    public let txHash: String?
    public let errorCode: Int
    /// The signed transaction refused, for a write the SDK signed under a
    /// nonce it chose (see `SignedSubmission`).
    public let submission: SignedSubmission?

    public init(message: String, txHash: String? = nil, errorCode: Int = 0, submission: SignedSubmission? = nil) {
        self.message = message
        self.txHash = txHash
        self.errorCode = errorCode
        self.submission = submission
    }

    public var errorDescription: String? {
        if let txHash = txHash, !txHash.isEmpty {
            return "transaction error (code \(errorCode), tx \(txHash)): \(message)"
        }
        return "transaction error (code \(errorCode)): \(message)"
    }
}

// MARK: - Transaction Submit Error

/// A write whose outcome is unknown: its submission failed in transit (a
/// network error), or the API answered a 5xx, a 408, or a 2xx that isn't
/// JSON. The transaction may have reached the node and may still land, so
/// its nonce stays held.
///
/// Retry it only with `resubmit(_:)` on the client that sent it, which
/// sends `submission`, the identical signed transaction, again under the
/// same nonce: whichever copy lands first spends the nonce and the other is
/// refused, so the write runs at most once. Calling the write again would
/// sign it under a fresh nonce, and both could run. To learn whether it
/// took effect, read what it wrote.
public struct TransactionSubmitError: Error, LocalizedError {
    /// The signed transaction sent.
    public let submission: SignedSubmission
    /// What failed: a `URLError`, an `HTTPError`, or the API's answer.
    public let cause: Error

    public init(submission: SignedSubmission, cause: Error) {
        self.submission = submission
        self.cause = cause
    }

    public var errorDescription: String? {
        return "the transaction under nonce \(submission.nonce) of \(submission.did) may have reached the node "
            + "(\(cause.localizedDescription)); resubmit it under the same nonce with resubmit(_:), "
            + "not as a new write, or it may run twice"
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

/// Creates the error for a verified read the SDK can't check as asked: the
/// proof may be genuine, but the SDK can't reproduce the node's answer from it
/// or can't return the proven value exactly. The unverified read
/// (`getUnverified`, `queryUnverified`) returns the node's answer, unchecked.
/// A proof that doesn't check out is a `ProofError` instead.
public func NotVerifiableError(_ message: String) -> WillowError {
    return WillowError(type: .notVerifiable, message: message)
}

/// Creates the error for a verified read whose proof is of a state more than
/// `LightClientConfig.maxProofLagBlocks` blocks behind the chain's latest
/// height (a stale answer), or whose height is that far ahead of it. The
/// proof itself may be genuine, and reading again may get a current one. A
/// proof whose root the header it must match doesn't carry is a `ProofError`
/// instead.
public func ProofHeightOutOfRangeError(_ message: String) -> WillowError {
    return WillowError(type: .proofHeightOutOfRange, message: message)
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
