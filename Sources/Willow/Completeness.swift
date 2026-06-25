// Client-side crypto-completeness verification.
//
// Mirrors willow-network's `canonical_event_set_hash` so a client can verify
// that an indexer's served completeness data for a (subgrove, block) is the
// complete, untampered filter-matched event set the chain attests to — without
// trusting the indexer. The on-chain `events_commitment` (a 32-byte keccak
// hash) is the trusted anchor; the indexer serves the matched-log preimage; the
// client re-hashes it here and compares.
//
// This is the SDK side of willow PR #676. The canonical Rust source is
// willow-network::data_sources::types::canonical_event_set_hash.

import Foundation

/// A single filter-matched event log, the unit of the completeness preimage.
///
/// Byte-exact field widths matter: `address` is 20 bytes and each `topic` is
/// 32 bytes — the canonical hash depends on these being fixed-width.
public struct CompletenessLog: Sendable, Equatable {
    /// 20-byte contract address.
    public let address: Data
    /// Ordered list of 32-byte indexed topics (topic0 = event signature hash).
    public let topics: [Data]
    /// Raw (non-indexed) event data; may be empty.
    public let data: Data

    public init(address: Data, topics: [Data], data: Data) {
        self.address = address
        self.topics = topics
        self.data = data
    }
}

/// Domain-separation tag prepended to every completeness preimage.
///
/// 23 ASCII bytes, no null terminator — must match the Rust `b"…"` literal.
private let completenessDomainTag = Data("WILLOW_CRYPTO_EVENTS_V1".utf8)

/// keccak256 over the canonical completeness preimage for one block.
///
/// The preimage is, with all integers big-endian and no separators:
/// `"WILLOW_CRYPTO_EVENTS_V1"` (23B) ‖ blockNumber (u64 BE) ‖
/// matchedLogs.count (u64 BE), then per log in order:
/// address (20B) ‖ topics.count (u32 BE) ‖ each topic (32B) ‖
/// data.count (u32 BE) ‖ data.
///
/// Byte-identical to willow-network's `canonical_event_set_hash`.
public func canonicalEventSetHash(blockNumber: UInt64, matchedLogs: [CompletenessLog]) -> Data {
    var preimage = Data()
    preimage.append(completenessDomainTag)
    preimage.append(beBytes(blockNumber))
    preimage.append(beBytes(UInt64(matchedLogs.count)))
    for log in matchedLogs {
        preimage.append(log.address)
        preimage.append(beBytes(UInt32(log.topics.count)))
        for topic in log.topics {
            preimage.append(topic)
        }
        preimage.append(beBytes(UInt32(log.data.count)))
        preimage.append(log.data)
    }
    return keccak256(preimage)
}

/// Whether `matchedLogs` re-hash to the on-chain `commitment` for `blockNumber`.
///
/// `commitment` is the 32-byte `events_commitment` anchor the chain attests to.
/// Returns `true` only on an exact match — any tampered, dropped, added, or
/// reordered log (or a wrong block number) yields `false`.
public func verifyServedEvents(
    commitment: Data,
    blockNumber: UInt64,
    matchedLogs: [CompletenessLog]
) -> Bool {
    return canonicalEventSetHash(blockNumber: blockNumber, matchedLogs: matchedLogs) == commitment
}

// MARK: - Endpoint preimage parsing
//
// The pieces below decode the two wire payloads of the end-to-end check (willow
// PR #676) into the typed inputs of `verifyServedEvents`. They are pure (no I/O)
// so the JSON -> `CompletenessLog` mapping can be gated against the canonical
// vector without a live node; `ConsensusClient.verifyBlockCompleteness` wires
// the fetches on top.

/// Decoded `/store/events_commitment/{subgrove}/{block}` ABCI value.
///
/// The on-chain anchor: a 32-byte keccak `events_commitment` for one block.
struct EventsCommitmentAnchor: Decodable {
    let subgroveId: String
    let blockNumber: UInt64
    let eventsCommitment: String

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case blockNumber = "block_number"
        case eventsCommitment = "events_commitment"
    }
}

/// One log in the indexer's `/completeness/.../matched-logs` response.
///
/// Only `address`/`topics`/`data` feed the hash; the rest (block/tx coordinates,
/// `removed`) are positional metadata the canonical preimage ignores.
struct MatchedLogJSON: Decodable {
    let address: String
    let topics: [String]
    let data: String
}

/// The indexer's `/completeness/{subgrove}/{block}/matched-logs` 200 body.
struct MatchedLogsResponse: Decodable {
    let subgroveId: String
    let blockNumber: UInt64
    let count: Int
    let matchedLogs: [MatchedLogJSON]

    enum CodingKeys: String, CodingKey {
        case subgroveId = "subgrove_id"
        case blockNumber = "block_number"
        case count
        case matchedLogs = "matched_logs"
    }
}

/// Decodes the 32-byte commitment from an `events_commitment` ABCI value body.
///
/// `value` is the raw bytes the ABCI store query returns (already base64-decoded
/// from the CometBFT JSON-RPC envelope); they are the JSON anchor object.
func parseEventsCommitment(_ value: Data) throws -> Data {
    let anchor = try JSONDecoder().decode(EventsCommitmentAnchor.self, from: value)
    guard let commitment = Data(hexString: stripHexPrefix(anchor.eventsCommitment)),
          commitment.count == 32
    else {
        throw ValidationError("events_commitment is not 32 hex bytes")
    }
    return commitment
}

/// Maps a matched-logs response body to the `CompletenessLog` set to be hashed.
///
/// Enforces the byte widths the canonical hash depends on: 20-byte addresses and
/// 32-byte topics. `data` may be any length (including empty, "0x").
func parseMatchedLogs(_ body: Data) throws -> [CompletenessLog] {
    let response = try JSONDecoder().decode(MatchedLogsResponse.self, from: body)
    return try response.matchedLogs.map { log in
        guard let address = Data(hexString: stripHexPrefix(log.address)), address.count == 20 else {
            throw ValidationError("matched log address is not 20 hex bytes")
        }
        let topics = try log.topics.map { topic -> Data in
            guard let bytes = Data(hexString: stripHexPrefix(topic)), bytes.count == 32 else {
                throw ValidationError("matched log topic is not 32 hex bytes")
            }
            return bytes
        }
        guard let data = Data(hexString: stripHexPrefix(log.data)) else {
            throw ValidationError("matched log data is not valid hex")
        }
        return CompletenessLog(address: address, topics: topics, data: data)
    }
}

private func stripHexPrefix(_ hex: String) -> String {
    if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
        return String(hex.dropFirst(2))
    }
    return hex
}

// MARK: - Big-endian integer helpers

private func beBytes(_ value: UInt64) -> Data {
    return Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}

private func beBytes(_ value: UInt32) -> Data {
    return Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}
