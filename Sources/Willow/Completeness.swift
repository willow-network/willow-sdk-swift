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

// MARK: - Convenience: end-to-end block-completeness check (deferred)
//
// A `verifyBlockCompleteness(subgroveId:blockNumber:)` wrapper would fetch both
// halves and call `verifyServedEvents`:
//   1. anchor — the validator ABCI store query path "events_commitment" with
//      (subgrove_id, block_number) returns { events_commitment: <hex> };
//   2. preimage — GET {indexerBaseURL}/completeness/{subgroveId}/{blockNumber}/matched-logs
//      returns the matched log set, mapped to `CompletenessLog`.
//
// It is intentionally NOT shipped here: this SDK has no generic CometBFT ABCI
// store-query client (only an RPC URL is configured), and the matched-logs
// indexer route is part of the same unreleased PR (#676). Wire it up once both
// endpoints are stable; the hashing primitives above are the load-bearing part
// and are already cross-language-verified against the canonical vectors.

// MARK: - Big-endian integer helpers

private func beBytes(_ value: UInt64) -> Data {
    return Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}

private func beBytes(_ value: UInt32) -> Data {
    return Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}
