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
    /// CometBFT's `block`: a block of at most `block.max_bytes`, 21 MiB, carries
    /// its transactions in base64, 28 MiB, with its header and last commit.
    static let block = 32 << 20
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
    /// decoded. The request is cancelled when refused. A `json` answer (every
    /// answer but a file chunk's) nested deeper than `maxJSONDepth` is
    /// refused too (see `checkNesting`), whatever its status, since even an
    /// error's body is read as JSON.
    static func read(_ session: URLSession, _ request: URLRequest, limit: Int, json: Bool = true) async throws -> (Data, URLResponse) {
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
        if json {
            try checkNesting(body)
        }
        return (Data(body), response)
    }

    /// `read` of a GET of `url`.
    static func read(_ session: URLSession, from url: URL, limit: Int, json: Bool = true) async throws -> (Data, URLResponse) {
        return try await read(session, URLRequest(url: url), limit: limit, json: json)
    }

    /// The deepest an answer's JSON may nest. `JSONDecoder`, `AnyCodable`,
    /// and `JSONSerialization` read JSON recursively, several stack frames a
    /// level, and a task's thread has a small stack: an answer nested 500
    /// levels overflowed it, crashing the process. The node stores no value
    /// nested more than 127 levels (serde_json's limit), and the deepest
    /// answer that carries one (a query's document) wraps it in 4 more.
    static let maxJSONDepth = 160

    /// Refuses JSON text whose arrays and objects nest more than
    /// `maxJSONDepth` deep, with `ResponseTooLargeError`, before it is
    /// decoded: a scan of its bytes that counts `[` and `{` against `]` and
    /// `}`, skipping what is inside strings (a `\` escapes the byte after
    /// it). Text that isn't JSON is left for the decoder to refuse. A NUL byte
    /// is refused too: UTF-8 JSON never holds one, and the decoders also read
    /// UTF-16 and UTF-32 text, whose bytes this scan would misread.
    static func checkNesting<Bytes: Sequence>(_ text: Bytes) throws where Bytes.Element == UInt8 {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in text {
            if byte == 0 {
                throw WillowError(
                    type: .responseTooLarge,
                    message: "The answer isn't UTF-8 JSON (it holds a NUL byte); the SDK reads only UTF-8")
            }
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                guard depth <= maxJSONDepth else {
                    throw WillowError(
                        type: .responseTooLarge,
                        message: "The answer nests JSON more than \(maxJSONDepth) levels deep, past the SDK's limit")
                }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth = max(0, depth - 1)
            default:
                break
            }
        }
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
