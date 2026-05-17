// Canonical WillowManifest builder.
//
// Mirrors willow_types::consensus::manifest::WillowManifest in the Rust
// workspace. The consensus validator rejects any manifest_content that
// doesn't decode into this exact shape, so SDK callers should build
// their on-chain manifest bytes via `serializeManifest(_:)`.
//
// v1 scope is EVM-only. Solana data sources have a different shape
// (program_id + start_slot + instructions) and follow when there's a
// real Swift consumer.

import Foundation

// MARK: - SupportedChain

/// Canonical chain identifier accepted by Willow's consensus validator.
/// Adding a chain is a consensus change: bump willow-types first, then
/// mirror here.
public enum SupportedChain: String, CaseIterable, Codable, Sendable {
    case mainnet
    case sepolia
    case holesky
    case bsc
    case optimism
    case arbitrumOne = "arbitrum-one"
    case base
    case polygon
    case solanaMainnet = "solana-mainnet"
}

public enum ChainFamily: String, Sendable {
    case evm
    case solana
}

public extension SupportedChain {
    /// Family the chain belongs to. Drives data-source dispatch.
    var family: ChainFamily {
        self == .solanaMainnet ? .solana : .evm
    }

    /// EIP-155 chain id for EVM-family chains, `nil` for Solana.
    var evmChainID: UInt64? {
        switch self {
        case .mainnet: return 1
        case .sepolia: return 11_155_111
        case .holesky: return 17_000
        case .bsc: return 56
        case .optimism: return 10
        case .arbitrumOne: return 42_161
        case .base: return 8453
        case .polygon: return 137
        case .solanaMainnet: return nil
        }
    }

    /// Parse a canonical string into the enum. Returns `nil` for any
    /// non-canonical value — no aliases (`"ethereum"`, etc.) are
    /// accepted.
    static func from(canonicalID: String) -> SupportedChain? {
        SupportedChain(rawValue: canonicalID)
    }

    /// Map an EIP-155 chain id back to a canonical chain.
    static func from(evmChainID id: UInt64) -> SupportedChain? {
        SupportedChain.allCases.first { $0.evmChainID == id }
    }
}

// MARK: - WillowManifest

/// Schema version pinned by the consensus validator.
public let manifestSpecVersion = "1.0.0"

/// Mirrors MAX_* constants in willow-types.
public let maxDataSources = 64
public let maxEventsPerSource = 32
public let maxNameLen = 64
public let maxAbiLen = 64
public let maxDescriptionLen = 1024

/// Dynamic CodingKey for scanning unknown fields.
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownKeys(
    _ decoder: Decoder, allowed: Set<String>, path: String
) throws {
    let raw = try decoder.container(keyedBy: AnyKey.self)
    for k in raw.allKeys where !allowed.contains(k.stringValue) {
        throw ManifestValidationError(
            "\(path) has unknown field \"\(k.stringValue)\"",
            field: path.isEmpty ? k.stringValue : "\(path).\(k.stringValue)")
    }
}

/// One indexed EVM contract within a manifest.
public struct EvmDataSource: Sendable, Equatable {
    public var name: String
    public var network: SupportedChain
    public var address: String  // 0x + 40 hex (lowercased on serialize)
    public var abi: String
    public var startBlock: UInt64
    public var events: [String]

    enum CodingKeys: String, CodingKey {
        case name, network, address, abi
        case startBlock = "start_block"
        case events
    }

    static let allowedKeys: Set<String> = [
        "name", "network", "address", "abi", "start_block", "events",
    ]

    public init(
        name: String,
        network: SupportedChain,
        address: String,
        abi: String,
        startBlock: UInt64,
        events: [String]
    ) {
        self.name = name
        self.network = network
        self.address = address
        self.abi = abi
        self.startBlock = startBlock
        self.events = events
    }
}

extension EvmDataSource: Codable {
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Self.allowedKeys, path: "data_sources[?]")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.network = try c.decode(SupportedChain.self, forKey: .network)
        self.address = try c.decode(String.self, forKey: .address)
        self.abi = try c.decode(String.self, forKey: .abi)
        self.startBlock = try c.decode(UInt64.self, forKey: .startBlock)
        self.events = try c.decode([String].self, forKey: .events)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(network, forKey: .network)
        try c.encode(address, forKey: .address)
        try c.encode(abi, forKey: .abi)
        try c.encode(startBlock, forKey: .startBlock)
        try c.encode(events, forKey: .events)
    }
}

/// Canonical manifest for `BlockchainIndexing` subgroves.
public struct WillowManifest: Sendable, Equatable {
    public var specVersion: String
    public var description: String?
    public var dataSources: [EvmDataSource]

    enum CodingKeys: String, CodingKey {
        case specVersion = "spec_version"
        case description
        case dataSources = "data_sources"
    }

    static let allowedKeys: Set<String> = [
        "spec_version", "description", "data_sources",
    ]

    public init(
        specVersion: String = manifestSpecVersion,
        description: String? = nil,
        dataSources: [EvmDataSource] = []
    ) {
        self.specVersion = specVersion
        self.description = description
        self.dataSources = dataSources
    }
}

extension WillowManifest: Codable {
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Self.allowedKeys, path: "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.specVersion = try c.decode(String.self, forKey: .specVersion)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.dataSources = try c.decode([EvmDataSource].self, forKey: .dataSources)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(specVersion, forKey: .specVersion)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(dataSources, forKey: .dataSources)
    }
}

// MARK: - Errors

/// Raised when a manifest fails to satisfy the canonical schema.
public struct ManifestValidationError: Error, CustomStringConvertible {
    public let message: String
    /// Field path (e.g. `"data_sources[1].address"`) attributing the failure.
    public let field: String

    public var description: String { message }

    init(_ message: String, field: String = "") {
        self.message = message
        self.field = field
    }
}

// MARK: - Validation

private let addressRegex = try! NSRegularExpression(pattern: "^0x[0-9a-fA-F]{40}$")
private let nameRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]+$")
private let eventNameRegex = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
private let eventParamRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9_\\[\\]]+$")

private func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
    let range = NSRange(s.startIndex..., in: s)
    return regex.firstMatch(in: s, options: [], range: range) != nil
}

private func validateEventSignature(_ sig: String, path: String) throws {
    if sig.isEmpty {
        throw ManifestValidationError("\(path) must not be empty", field: path)
    }
    guard let openIdx = sig.firstIndex(of: "(") else {
        throw ManifestValidationError("\(path) \"\(sig)\" missing '('", field: path)
    }
    guard sig.hasSuffix(")") else {
        throw ManifestValidationError("\(path) \"\(sig)\" missing trailing ')'", field: path)
    }
    let name = String(sig[..<openIdx])
    let after = sig.index(after: openIdx)
    let before = sig.index(before: sig.endIndex)
    let params = String(sig[after..<before])
    if !matches(eventNameRegex, name) {
        throw ManifestValidationError(
            "\(path) event name \"\(name)\" is not a valid identifier", field: path)
    }
    if params.isEmpty { return }
    for part in params.split(separator: ",", omittingEmptySubsequences: false) {
        if !matches(eventParamRegex, String(part)) {
            throw ManifestValidationError(
                "\(path) has invalid parameter type \"\(part)\"", field: path)
        }
    }
}

private func validateDataSource(_ ds: EvmDataSource, path: String) throws {
    if ds.name.isEmpty {
        throw ManifestValidationError("\(path).name must not be empty", field: "\(path).name")
    }
    if ds.name.count > maxNameLen {
        throw ManifestValidationError(
            "\(path).name length \(ds.name.count) exceeds maximum \(maxNameLen)",
            field: "\(path).name")
    }
    if !matches(nameRegex, ds.name) {
        throw ManifestValidationError(
            "\(path).name \"\(ds.name)\" must be alphanumeric, '-', or '_'",
            field: "\(path).name")
    }
    if ds.network.family != .evm {
        throw ManifestValidationError(
            "\(path).network \"\(ds.network.rawValue)\" is non-EVM; Solana data sources have a different shape and are not yet supported by this builder",
            field: "\(path).network")
    }
    if !matches(addressRegex, ds.address) {
        throw ManifestValidationError(
            "\(path).address must be 0x + 40 hex chars (got \"\(ds.address)\")",
            field: "\(path).address")
    }
    if ds.abi.isEmpty {
        throw ManifestValidationError("\(path).abi must not be empty", field: "\(path).abi")
    }
    if ds.abi.count > maxAbiLen {
        throw ManifestValidationError(
            "\(path).abi length \(ds.abi.count) exceeds maximum \(maxAbiLen)",
            field: "\(path).abi")
    }
    if ds.events.isEmpty {
        throw ManifestValidationError(
            "\(path).events must declare at least one event",
            field: "\(path).events")
    }
    if ds.events.count > maxEventsPerSource {
        throw ManifestValidationError(
            "\(path).events has \(ds.events.count) entries (maximum \(maxEventsPerSource))",
            field: "\(path).events")
    }
    for (i, sig) in ds.events.enumerated() {
        try validateEventSignature(sig, path: "\(path).events[\(i)]")
    }
}

/// Apply every canonical-schema check. Same rules as
/// `WillowManifest::from_bytes` + `validate()` in willow-types.
public func validateManifest(_ m: WillowManifest) throws {
    if m.specVersion != manifestSpecVersion {
        throw ManifestValidationError(
            "unsupported spec_version \"\(m.specVersion)\" (expected \"\(manifestSpecVersion)\")",
            field: "spec_version")
    }
    if let desc = m.description, desc.count > maxDescriptionLen {
        throw ManifestValidationError(
            "description length \(desc.count) exceeds maximum \(maxDescriptionLen)",
            field: "description")
    }
    if m.dataSources.isEmpty {
        throw ManifestValidationError(
            "manifest must declare at least one data source",
            field: "data_sources")
    }
    if m.dataSources.count > maxDataSources {
        throw ManifestValidationError(
            "manifest has \(m.dataSources.count) data sources (maximum \(maxDataSources))",
            field: "data_sources")
    }
    for (i, ds) in m.dataSources.enumerated() {
        try validateDataSource(ds, path: "data_sources[\(i)]")
    }
}

/// Validate and serialize to the canonical JSON byte form that goes
/// on-chain via `SubgroveMode.BlockchainIndexing.manifest_content`.
///
/// EVM addresses are normalised to lowercase so the emitted bytes
/// round-trip bit-for-bit with what `WillowManifest::from_bytes`
/// produces in Rust.
public func serializeManifest(_ m: WillowManifest) throws -> Data {
    try validateManifest(m)
    var normalized = m
    normalized.dataSources = m.dataSources.map {
        var ds = $0
        ds.address = ds.address.lowercased()
        return ds
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(normalized)
}

/// Validate and decode canonical manifest bytes.
public func parseManifest(_ data: Data) throws -> WillowManifest {
    let decoder = JSONDecoder()
    let manifest: WillowManifest
    do {
        manifest = try decoder.decode(WillowManifest.self, from: data)
    } catch {
        throw ManifestValidationError(
            "manifest is not valid JSON or does not match canonical schema: \(error)",
            field: "")
    }
    try validateManifest(manifest)
    return manifest
}
