import Foundation

// MARK: - Response Caps

/// The most bytes the SDK reads of one answer, by route.
///
/// A cap holds the largest honest answer of its routes where the node bounds
/// that answer. Where the request sets an answer's size, or the node keeps no
/// bound (lists that aren't paged grow with the chain), the cap is `large`,
/// and an answer past it is refused: ask for less. A cap bounds the bytes
/// read, not the memory decoding them takes.
internal enum ResponseLimit {
    /// Answers of a fixed shape, or lists the node keeps short: health, the
    /// root hash, an account's nonce, balances, the token's information, the
    /// fee schedule, a subgrove's or an indexer's or a validator's entry, a
    /// key grant and its proof, a checkpoint's root, a file's manifest and a
    /// page of the file list (at most 100 files), a `/tx/submit` answer,
    /// ERC-8004 answers, and CometBFT's `status`, `commit`, `validators` (at
    /// most 100 a page), and `abci_query`. These are a few KiB; 4 MiB is the
    /// chain's `max_tx_bytes`, the most one transaction writes.
    static let small = 4 << 20
    /// The API's `/proof` of one key: a proof of at most
    /// `GroveDBVerifier.maxSingleKeyProofBytes` (1 MiB) in hex, twice its
    /// length, with the JSON around it.
    static let proof = (2 << 20) + (64 << 10)
    /// A file chunk: the storage node's upload route takes a body of at most
    /// 2 MiB (its framework's default body limit), so it stores no longer
    /// chunk. A download reads each chunk under the manifest's chunk size, or
    /// the bytes the file has left, when that is smaller.
    static let chunk = 2 << 20
    /// An answer that carries what one transaction holds: the API's `/data`
    /// value of a key (at most what one transaction writes), and CometBFT's
    /// `tx` (a transaction of at most `max_tx_bytes`, 4 MiB, is 5.4 MiB in
    /// base64, with its result beside it).
    static let tx = 12 << 20
    /// Answers whose size the request sets, or that the node doesn't bound:
    /// a `/query` page (100 documents unless the query sets a limit), GraphQL
    /// and SQL answers, a historical query, a block's matched logs, Ethereum
    /// state and call answers, and the lists that aren't paged and grow with
    /// the chain (`/subgroves`, `/subgroves/indexed`, `/indexers`,
    /// `/validators`, a subgrove's key grantees, a DID's permissions): a
    /// registration's schema and member lists are bounded only by
    /// `max_tx_bytes`.
    static let large = 64 << 20
}

// MARK: - Reading

/// Reads HTTP answers under a cap on their size, in one place for every route
/// the SDK reads.
internal enum HTTPBody {
    /// Sends `request` through `session` and reads the answer's body a piece
    /// at a time, refusing it with `ResponseTooLargeError` once it passes
    /// `limit` bytes (or declares a longer length), before any of it is
    /// decoded. The request is cancelled when refused.
    static func read(_ session: URLSession, _ request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw ResponseTooLargeError(limit: limit)
        }
        var body: [UInt8] = []
        body.reserveCapacity(Int(min(max(response.expectedContentLength, 0), Int64(limit))))
        for try await byte in bytes {
            guard body.count < limit else {
                bytes.task.cancel()
                throw ResponseTooLargeError(limit: limit)
            }
            body.append(byte)
        }
        return (Data(body), response)
    }

    /// `read` of a GET of `url`.
    static func read(_ session: URLSession, from url: URL, limit: Int) async throws -> (Data, URLResponse) {
        return try await read(session, URLRequest(url: url), limit: limit)
    }

    /// A readable size for `limit`: in MiB when it is whole MiB, else KiB.
    static func describe(_ limit: Int) -> String {
        if limit % (1 << 20) == 0 {
            return "\(limit >> 20) MiB"
        }
        return "\(limit >> 10) KiB"
    }
}

/// Creates the error for an answer longer than `limit` bytes, the SDK's cap
/// for its route (type `.responseTooLarge`). It isn't retried.
internal func ResponseTooLargeError(limit: Int) -> WillowError {
    return WillowError(
        type: .responseTooLarge,
        message: "The answer is over the SDK's \(HTTPBody.describe(limit)) limit for its route; ask for less")
}
