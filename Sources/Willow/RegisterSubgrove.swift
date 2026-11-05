import Foundation

// MARK: - Bincode

/// bincode 1.x's default encoding, the one the node hashes a RegisterSubgrove
/// transaction with: fixed-width little-endian integers, a u64 length before
/// each string and vector, a u32 index before each enum variant's fields, one
/// byte for a bool or an `Option`'s tag, and fixed-size arrays with no length.
internal struct BincodeWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u32(_ value: UInt32) { bytes += withUnsafeBytes(of: value.littleEndian, Array.init) }
    mutating func u64(_ value: UInt64) { bytes += withUnsafeBytes(of: value.littleEndian, Array.init) }
    mutating func u128(_ value: U128) { bytes += value.littleEndianBytes }
    mutating func bool(_ value: Bool) { u8(value ? 1 : 0) }
    mutating func fixed(_ value: [UInt8]) { bytes += value }

    mutating func byteVector(_ value: [UInt8]) {
        u64(UInt64(value.count))
        bytes += value
    }

    mutating func string(_ value: String) { byteVector(Array(value.utf8)) }

    mutating func strings(_ values: [String]) {
        u64(UInt64(values.count))
        for value in values { string(value) }
    }

    /// An `Option`: 0 for none, else 1 then the value.
    mutating func option(_ value: WireJSON?, _ write: (inout BincodeWriter, WireJSON) throws -> Void) rethrows {
        guard let value = value, !value.isNull else {
            u8(0)
            return
        }
        u8(1)
        try write(&self, value)
    }
}

// MARK: - RegisterSubgrove's bincode, from the JSON the node decodes

private let teeTypes = ["AwsNitro", "IntelSgx", "AmdSev"]
private let subgroveModes = ["DataStorage", "FileStorage", "BlockchainIndexing"]
private let executionModes = ["ConsensusExecution", "IndexerExecution", "TeeExecution"]
private let retentionWindows = ["Blocks", "Seconds", "Indefinite", "VerifyOnly"]
private let historicalAuthModes = ["BftEquivalent", "CanonizedAccumulator"]
private let commitmentFrequencies = ["EveryUpdate", "EveryNBlocks", "EveryNSeconds", "Never"]

/// The u32 variant index of `name` among `variants`, refused when unknown.
private func variantIndex(_ name: String, in variants: [String], _ what: String) throws -> UInt32 {
    guard let index = variants.firstIndex(of: name) else {
        throw ValidationError("\(what) has no variant \(name)")
    }
    return UInt32(index)
}

/// The bincode (1.x default) of the `RegisterSubgroveTx` that `tx`, the JSON
/// object inside a `/tx/submit` body's `{"RegisterSubgrove": tx}`, decodes to
/// on the node, with an empty signature: what a RegisterSubgrove message's
/// `Config` line hashes.
///
/// Fields the JSON leaves out take the defaults the node fills in
/// (`description` "", `admins` [], `initial_funding`, `privacy`,
/// `initial_owner_key_grant`, and `template_config` none,
/// `checkpoint_verification` with no TEE, `confirmation_depth` 0,
/// `cryptographic_completeness` false; in a mode, `read_pricing` and
/// `completeness` none, `retention_period` 0, `wasm_modules` [],
/// `retention_window` Indefinite, `historical_auth_mode` BftEquivalent; an
/// indexer config's `epoch_length` 100; a completeness's `deferred` false and
/// `bond_amount` 0; a missing `mode` is DataStorage with empty name, writers,
/// and readers). Any other field it leaves out is refused rather than
/// guessed. `initial_funding`, `reward_per_epoch`, and `min_indexer_stake`
/// read as a JSON number or a decimal string, as on the node; every other
/// integer must be a JSON number.
internal func registerSubgroveUnsignedBincode(json tx: WireJSON) throws -> Data {
    let t = try WireJSONObject(tx, "RegisterSubgrove")
    var w = BincodeWriter()
    w.string(try t.required("subgrove_id").string(t.label("subgrove_id")))
    w.string(try t.required("name").string(t.label("name")))
    w.string(try t.value("description", default: .string("")).string(t.label("description")))
    w.string(try t.required("schema").string(t.label("schema")))
    w.string(try t.required("owner_did").string(t.label("owner_did")))
    w.strings(try t.value("admins", default: .array([])).strings(t.label("admins")))
    try w.option(t.optional("initial_funding")) { w, value in
        w.u128(try value.flexibleU128(t.label("initial_funding")))
    }

    let checkpoint = try WireJSONObject(
        t.value("checkpoint_verification", default: .object([])), t.label("checkpoint_verification")
    )
    try w.option(checkpoint.optional("required_tee")) { w, value in
        let (name, _) = try value.variant(checkpoint.label("required_tee"))
        w.u32(try variantIndex(name, in: teeTypes, checkpoint.label("required_tee")))
    }

    let defaultMode = WireJSON.variant("DataStorage", .object([
        .init("name", .string("")), .init("writers", .array([])), .init("free_readers", .array([])),
    ]))
    try writeSubgroveMode(&w, t.value("mode", default: defaultMode), t.label("mode"))

    try w.option(t.optional("privacy")) { w, value in
        let p = try WireJSONObject(value, t.label("privacy"))
        try w.option(p.optional("allowed_indexers")) { w, indexers in
            w.strings(try indexers.strings(p.label("allowed_indexers")))
        }
        let (name, payload) = try p.required("commitment_frequency").variant(p.label("commitment_frequency"))
        w.u32(try variantIndex(name, in: commitmentFrequencies, p.label("commitment_frequency")))
        if name == "EveryNBlocks" || name == "EveryNSeconds" {
            guard let payload = payload else { throw ValidationError("\(p.label("commitment_frequency")) \(name) needs a count") }
            w.u64(try payload.unsigned(p.label("commitment_frequency"), as: UInt64.self))
        }
    }
    try w.option(t.optional("initial_owner_key_grant")) { w, value in
        try writeKeyGrant(&w, value, t.label("initial_owner_key_grant"))
    }
    try w.option(t.optional("template_config")) { w, value in
        let c = try WireJSONObject(value, t.label("template_config"))
        w.string(try c.required("template_id").string(c.label("template_id")))
        w.u32(try c.required("template_version").unsigned(c.label("template_version"), as: UInt32.self))
        w.string(try c.required("variant_id").string(c.label("variant_id")))
        w.byteVector(try c.required("parameters").bytes(c.label("parameters")))
        w.strings(try c.required("contracts").strings(c.label("contracts")))
        w.strings(try c.required("event_signatures").strings(c.label("event_signatures")))
        try w.option(c.optional("chain")) { w, chain in
            w.string(try chain.string(c.label("chain")))
        }
    }
    w.u32(try t.value("confirmation_depth", default: .number("0")).unsigned(t.label("confirmation_depth"), as: UInt32.self))
    // The signature the message is signed over is empty: a u64 length of 0.
    _ = try t.required("signature").array(t.label("signature"))
    w.byteVector([])
    w.string(try t.required("public_key_id").string(t.label("public_key_id")))
    w.u64(try t.required("nonce").unsigned(t.label("nonce"), as: UInt64.self))
    w.bool(try t.value("cryptographic_completeness", default: .bool(false)).bool(t.label("cryptographic_completeness")))
    return Data(w.bytes)
}

private func writeReadPricing(_ w: inout BincodeWriter, _ value: WireJSON, _ what: String) throws {
    let p = try WireJSONObject(value, what)
    w.bool(try p.required("enabled").bool(p.label("enabled")))
    w.u128(try p.required("price_per_query").u128(p.label("price_per_query")))
    w.u32(try p.required("owner_revenue_share_bps").unsigned(p.label("owner_revenue_share_bps"), as: UInt32.self))
}

private func writeKeyGrant(_ w: inout BincodeWriter, _ value: WireJSON, _ what: String) throws {
    let g = try WireJSONObject(value, what)
    w.string(try g.required("grantee_did").string(g.label("grantee_did")))
    w.u32(try g.required("key_epoch").unsigned(g.label("key_epoch"), as: UInt32.self))
    w.string(try g.required("grantee_public_key_id").string(g.label("grantee_public_key_id")))
    w.byteVector(try g.required("ephemeral_public_key").bytes(g.label("ephemeral_public_key")))
    w.byteVector(try g.required("encrypted_key").bytes(g.label("encrypted_key")))
    w.string(try g.required("granted_by").string(g.label("granted_by")))
    w.u64(try g.required("granted_at").unsigned(g.label("granted_at"), as: UInt64.self))
}

private func writeSubgroveMode(_ w: inout BincodeWriter, _ value: WireJSON, _ what: String) throws {
    let (name, payload) = try value.variant(what)
    w.u32(try variantIndex(name, in: subgroveModes, what))
    guard let payload = payload else { throw ValidationError("\(what) \(name) needs its fields") }
    let m = try WireJSONObject(payload, "\(what).\(name)")
    switch name {
    case "DataStorage":
        w.string(try m.required("name").string(m.label("name")))
        w.strings(try m.required("writers").strings(m.label("writers")))
        // `free_readers` also reads as `readers` in this mode.
        let readers = try m.optional("free_readers") ?? m.required("readers")
        w.strings(try readers.strings(m.label("free_readers")))
        try w.option(m.optional("read_pricing")) { w, pricing in
            try writeReadPricing(&w, pricing, m.label("read_pricing"))
        }
    case "FileStorage":
        w.string(try m.required("name").string(m.label("name")))
        w.u64(try m.required("max_file_size").unsigned(m.label("max_file_size"), as: UInt64.self))
        w.u8(try m.required("replication_factor").unsigned(m.label("replication_factor"), as: UInt8.self))
        w.strings(try m.required("writers").strings(m.label("writers")))
        w.strings(try m.required("free_readers").strings(m.label("free_readers")))
        try w.option(m.optional("read_pricing")) { w, pricing in
            try writeReadPricing(&w, pricing, m.label("read_pricing"))
        }
        w.u64(try m.value("retention_period", default: .number("0")).unsigned(m.label("retention_period"), as: UInt64.self))
    default: // BlockchainIndexing
        w.byteVector(try m.required("manifest_content").bytes(m.label("manifest_content")))
        let modules = try m.value("wasm_modules", default: .array([])).array(m.label("wasm_modules"))
        w.u64(UInt64(modules.count))
        for module in modules {
            let wasm = try WireJSONObject(module, m.label("wasm_modules"))
            w.string(try wasm.required("name").string(wasm.label("name")))
            let hash = try wasm.required("hash").bytes(wasm.label("hash"))
            guard hash.count == 32 else { throw ValidationError("\(wasm.label("hash")) must be 32 bytes") }
            w.fixed(hash)
            w.byteVector(try wasm.required("content").bytes(wasm.label("content")))
        }
        let (execution, executionFields) = try m.required("execution_mode").variant(m.label("execution_mode"))
        w.u32(try variantIndex(execution, in: executionModes, m.label("execution_mode")))
        if execution != "ConsensusExecution" {
            guard let executionFields = executionFields else {
                throw ValidationError("\(m.label("execution_mode")) \(execution) needs its fields")
            }
            let e = try WireJSONObject(executionFields, m.label("execution_mode"))
            if execution == "IndexerExecution" {
                w.u8(try e.required("sampling_rate_percent").unsigned(e.label("sampling_rate_percent"), as: UInt8.self))
            } else {
                let (tee, _) = try e.required("tee_type").variant(e.label("tee_type"))
                w.u32(try variantIndex(tee, in: teeTypes, e.label("tee_type")))
            }
        }
        let c = try WireJSONObject(m.required("indexer_config"), m.label("indexer_config"))
        w.u8(try c.required("min_indexers").unsigned(c.label("min_indexers"), as: UInt8.self))
        w.u8(try c.required("max_indexers").unsigned(c.label("max_indexers"), as: UInt8.self))
        w.u128(try c.required("reward_per_epoch").flexibleU128(c.label("reward_per_epoch")))
        w.u64(try c.value("epoch_length", default: .number("100")).unsigned(c.label("epoch_length"), as: UInt64.self))
        w.u128(try c.required("min_indexer_stake").flexibleU128(c.label("min_indexer_stake")))
        let (window, windowValue) = try m.value("retention_window", default: .string("Indefinite")).variant(m.label("retention_window"))
        w.u32(try variantIndex(window, in: retentionWindows, m.label("retention_window")))
        if window == "Blocks" || window == "Seconds" {
            guard let windowValue = windowValue else { throw ValidationError("\(m.label("retention_window")) \(window) needs a count") }
            w.u64(try windowValue.unsigned(m.label("retention_window"), as: UInt64.self))
        }
        try w.option(m.optional("completeness")) { w, value in
            let k = try WireJSONObject(value, m.label("completeness"))
            for key in ["log_config_hash", "tx_config_hash"] {
                let words = try k.required(key).array(k.label(key))
                guard words.count == 4 else { throw ValidationError("\(k.label(key)) must hold 4 numbers") }
                for word in words { w.u32(try word.unsigned(k.label(key), as: UInt32.self)) }
            }
            w.bool(try k.value("deferred", default: .bool(false)).bool(k.label("deferred")))
            w.u128(try k.value("bond_amount", default: .number("0")).u128(k.label("bond_amount")))
        }
        let (auth, _) = try m.value("historical_auth_mode", default: .string("BftEquivalent")).variant(m.label("historical_auth_mode"))
        w.u32(try variantIndex(auth, in: historicalAuthModes, m.label("historical_auth_mode")))
    }
}

// MARK: - Schema

/// The field types the node's schema definition names.
private let schemaFieldTypes: Set<String> = ["string", "number", "boolean", "array", "object", "bytes"]

/// Refuses a data or file subgrove's `schema` unless the node reads it as its
/// schema definition with no indexes: a JSON object whose `version` (if
/// present) is a u32, whose `fields` (if present) maps each name to
/// "string", "number", "boolean", "array", "object", or "bytes", whose
/// `indexes` (if present) is empty, and whose `required_fields` (if present)
/// is a list of strings. Other keys are ignored, as the node ignores them.
internal func checkSubgroveSchema(_ schema: String) throws {
    let value: WireJSON
    do {
        value = try WireJSON.parse(Data(schema.utf8))
    } catch let error as WillowError {
        throw ValidationError("The schema isn't JSON the node can read: \(error.message)")
    }
    let s = try WireJSONObject(value, "The schema")
    _ = try s.value("version", default: .number("1")).unsigned(s.label("version"), as: UInt32.self)
    guard case .object(let fields) = s.value("fields", default: .object([])) else {
        throw ValidationError("\(s.label("fields")) must be a JSON object")
    }
    for field in fields {
        let (type, payload) = try field.value.variant(s.label("fields.\(field.key)"))
        guard payload == nil, schemaFieldTypes.contains(type) else {
            throw ValidationError(
                "Schema field \(field.key) must be \"string\", \"number\", \"boolean\", \"array\", \"object\", or \"bytes\""
            )
        }
    }
    guard try s.value("indexes", default: .array([])).array(s.label("indexes")).isEmpty else {
        throw ValidationError("The node refuses a data or file subgrove whose schema declares indexes")
    }
    _ = try s.value("required_fields", default: .array([])).strings(s.label("required_fields"))
}

// MARK: - RegisterSubgroveTx as JSON

extension RegisterSubgroveTx {
    /// The transaction as the JSON object `/tx/submit` takes inside
    /// `{"RegisterSubgrove": ...}`, every field written out, so the node
    /// decodes the values the SDK hashed. Refuses a mode this SDK can't build
    /// (BlockchainIndexing) and a negative nonce.
    internal func wireJSON() throws -> WireJSON {
        return .object([
            .init("subgrove_id", .string(subgroveId)),
            .init("name", .string(name)),
            .init("description", .string(description)),
            .init("schema", .string(schema)),
            .init("owner_did", .string(ownerDid)),
            .init("admins", .strings(admins)),
            .init("initial_funding", .optional(initialFunding, WireJSON.u128)),
            .init("checkpoint_verification", .object([.init("required_tee", .null)])),
            .init("mode", try mode.wireJSON()),
            .init("privacy", .optional(privacy) { $0.wireJSON() }),
            .init("initial_owner_key_grant", .optional(initialOwnerKeyGrant) { $0.wireJSON() }),
            .init("template_config", .null),
            .init("confirmation_depth", .unsigned(confirmationDepth)),
            .init("signature", .bytes(signature)),
            .init("public_key_id", .string(publicKeyId)),
            .init("nonce", .unsigned(try unsignedField("nonce", nonce, as: UInt64.self))),
            .init("cryptographic_completeness", .bool(false)),
        ])
    }

    /// The node's rules for a DataStorage or FileStorage registration. The
    /// node refuses a registration that breaks one (in its block, spending
    /// the nonce), so the SDK refuses it before signing:
    /// - a subgrove ID of 1 to 64 ASCII letters, digits, `-`, or `_`, starting
    ///   with a letter or digit;
    /// - admins, writers, and free readers that are Willow DIDs (`did:willow:`
    ///   then one or more ASCII letters, digits, `-`, or `_`, at most 128
    ///   bytes);
    /// - a schema that reads as the node's schema definition and declares no
    ///   indexes (`checkSubgroveSchema`);
    /// - for a private DataStorage subgrove, an initial key grant (if any) of
    ///   key epoch 0 to the owner.
    internal func checkStorageRules() throws {
        let writers: [String]
        let freeReaders: [String]
        switch mode {
        case .dataStorage(let storage):
            (writers, freeReaders) = (storage.writers, storage.freeReaders)
            if privacy != nil, let grant = initialOwnerKeyGrant {
                guard grant.keyEpoch == 0 else {
                    throw ValidationError("A private subgrove's initial key grant must be key epoch 0, not \(grant.keyEpoch)")
                }
                guard grant.granteeDid == ownerDid else {
                    throw ValidationError("A private subgrove's initial key grant must be to its owner \(ownerDid), not \(grant.granteeDid)")
                }
                try checkWillowDID(grant.granteeDid, "The initial key grant's grantee")
            }
        case .fileStorage(let storage):
            (writers, freeReaders) = (storage.writers, storage.freeReaders)
        case .blockchainIndexing:
            return
        }
        let id = Array(subgroveId.utf8)
        guard (1...64).contains(id.count), isASCIILetterOrDigit(id[0]), id.allSatisfy(isIdentifierByte) else {
            throw ValidationError(
                "A subgrove ID must be 1 to 64 ASCII letters, digits, '-', or '_', starting with a letter or digit: \(subgroveId)"
            )
        }
        for admin in admins {
            try checkWillowDID(admin, "An admin")
        }
        for writer in writers {
            try checkWillowDID(writer, "A writer")
        }
        for reader in freeReaders {
            try checkWillowDID(reader, "A free reader")
        }
        try checkSubgroveSchema(schema)
    }

    /// The `/tx/submit` body: `{"RegisterSubgrove": ...}`.
    internal func submitBody() throws -> Data {
        return WireJSON.variant("RegisterSubgrove", try wireJSON()).serialized
    }

    /// Reads the JSON object `wireJSON` writes. Refuses what this type can't
    /// hold (a BlockchainIndexing mode, a template, a TEE requirement, or
    /// receipts completeness) rather than drop it.
    internal init(wireJSON value: WireJSON) throws {
        let t = try WireJSONObject(value, "RegisterSubgrove")
        if let template = t.optional("template_config"), !template.isNull {
            throw ValidationError("RegisterSubgroveTx can't hold a template_config")
        }
        if let checkpoint = t.optional("checkpoint_verification") {
            let c = try WireJSONObject(checkpoint, t.label("checkpoint_verification"))
            if let tee = c.optional("required_tee"), !tee.isNull {
                throw ValidationError("RegisterSubgroveTx can't hold a required_tee")
            }
        }
        if try t.value("cryptographic_completeness", default: .bool(false)).bool(t.label("cryptographic_completeness")) {
            throw ValidationError("RegisterSubgroveTx can't hold cryptographic_completeness")
        }
        let nonce = try t.required("nonce").unsigned(t.label("nonce"), as: UInt64.self)
        guard let nonceValue = Int(exactly: nonce) else { throw ValidationError("nonce is out of range") }
        self.init(
            subgroveId: try t.required("subgrove_id").string(t.label("subgrove_id")),
            name: try t.required("name").string(t.label("name")),
            description: try t.value("description", default: .string("")).string(t.label("description")),
            schema: try t.required("schema").string(t.label("schema")),
            ownerDid: try t.required("owner_did").string(t.label("owner_did")),
            admins: try t.value("admins", default: .array([])).strings(t.label("admins")),
            initialFunding: try t.optionalValue("initial_funding") { try $0.u128(t.label("initial_funding")) },
            mode: try t.optional("mode").map { try SubgroveMode(wireJSON: $0) } ?? .dataStorage(SubgroveDataStorage()),
            privacy: try t.optionalValue("privacy") { try PrivacyConfig(wireJSON: $0) },
            initialOwnerKeyGrant: try t.optionalValue("initial_owner_key_grant") { try EncryptedKeyGrant(wireJSON: $0) },
            confirmationDepth: try t.value("confirmation_depth", default: .number("0")).unsigned(t.label("confirmation_depth"), as: UInt32.self),
            signature: try t.required("signature").bytes(t.label("signature")),
            publicKeyId: try t.required("public_key_id").string(t.label("public_key_id")),
            nonce: nonceValue
        )
    }
}

extension SubgroveMode {
    internal func wireJSON() throws -> WireJSON {
        switch self {
        case .dataStorage(let mode):
            return .variant("DataStorage", .object([
                .init("name", .string(mode.name)),
                .init("writers", .strings(mode.writers)),
                .init("free_readers", .strings(mode.freeReaders)),
                .init("read_pricing", .optional(mode.readPricing) { $0.wireJSON() }),
            ]))
        case .fileStorage(let mode):
            return .variant("FileStorage", .object([
                .init("name", .string(mode.name)),
                .init("max_file_size", .unsigned(mode.maxFileSize)),
                .init("replication_factor", .unsigned(mode.replicationFactor)),
                .init("writers", .strings(mode.writers)),
                .init("free_readers", .strings(mode.freeReaders)),
                .init("read_pricing", .optional(mode.readPricing) { $0.wireJSON() }),
                .init("retention_period", .unsigned(mode.retentionPeriod)),
            ]))
        case .blockchainIndexing:
            throw ValidationError(
                "This SDK can't build a BlockchainIndexing registration: the node needs its manifest, "
                    + "execution mode, and indexer config, which SubgroveBlockchainIndexing doesn't carry, "
                    + "so it signs none"
            )
        }
    }

    internal init(wireJSON value: WireJSON) throws {
        let (name, payload) = try value.variant("mode")
        guard let payload = payload else { throw ValidationError("mode \(name) needs its fields") }
        let m = try WireJSONObject(payload, "mode.\(name)")
        switch name {
        case "DataStorage":
            let readers = try m.optional("free_readers") ?? m.required("readers")
            self = .dataStorage(SubgroveDataStorage(
                name: try m.required("name").string(m.label("name")),
                writers: try m.required("writers").strings(m.label("writers")),
                freeReaders: try readers.strings(m.label("free_readers")),
                readPricing: try m.optionalValue("read_pricing") { try ReadPricing(wireJSON: $0) }
            ))
        case "FileStorage":
            self = .fileStorage(SubgroveFileStorage(
                name: try m.required("name").string(m.label("name")),
                maxFileSize: try m.required("max_file_size").unsigned(m.label("max_file_size"), as: UInt64.self),
                replicationFactor: try m.required("replication_factor").unsigned(m.label("replication_factor"), as: UInt8.self),
                writers: try m.required("writers").strings(m.label("writers")),
                freeReaders: try m.required("free_readers").strings(m.label("free_readers")),
                readPricing: try m.optionalValue("read_pricing") { try ReadPricing(wireJSON: $0) },
                retentionPeriod: try m.value("retention_period", default: .number("0")).unsigned(m.label("retention_period"), as: UInt64.self)
            ))
        default:
            throw ValidationError("SubgroveMode can't hold a \(name) registration")
        }
    }
}

extension ReadPricing {
    internal func wireJSON() -> WireJSON {
        return .object([
            .init("enabled", .bool(enabled)),
            .init("price_per_query", .u128(pricePerQuery)),
            .init("owner_revenue_share_bps", .unsigned(ownerRevenueShareBps)),
        ])
    }

    internal init(wireJSON value: WireJSON) throws {
        let p = try WireJSONObject(value, "read_pricing")
        self.init(
            enabled: try p.required("enabled").bool(p.label("enabled")),
            pricePerQuery: try p.required("price_per_query").u128(p.label("price_per_query")),
            ownerRevenueShareBps: try p.required("owner_revenue_share_bps").unsigned(p.label("owner_revenue_share_bps"), as: UInt32.self)
        )
    }
}

extension PrivacyConfig {
    internal func wireJSON() -> WireJSON {
        let frequency: WireJSON
        switch commitmentFrequency {
        case .everyUpdate: frequency = .string("EveryUpdate")
        case .everyNBlocks(let n): frequency = .variant("EveryNBlocks", .unsigned(n))
        case .everyNSeconds(let n): frequency = .variant("EveryNSeconds", .unsigned(n))
        case .never: frequency = .string("Never")
        }
        return .object([
            .init("allowed_indexers", .optional(allowedIndexers, WireJSON.strings)),
            .init("commitment_frequency", frequency),
        ])
    }

    internal init(wireJSON value: WireJSON) throws {
        let p = try WireJSONObject(value, "privacy")
        let (name, payload) = try p.required("commitment_frequency").variant(p.label("commitment_frequency"))
        let frequency: CommitmentFrequency
        switch name {
        case "EveryUpdate": frequency = .everyUpdate
        case "Never": frequency = .never
        case "EveryNBlocks", "EveryNSeconds":
            guard let payload = payload else { throw ValidationError("commitment_frequency \(name) needs a count") }
            let count = try payload.unsigned(p.label("commitment_frequency"), as: UInt64.self)
            frequency = name == "EveryNBlocks" ? .everyNBlocks(count) : .everyNSeconds(count)
        default:
            throw ValidationError("commitment_frequency has no variant \(name)")
        }
        self.init(
            allowedIndexers: try p.optionalValue("allowed_indexers") { try $0.strings(p.label("allowed_indexers")) },
            commitmentFrequency: frequency
        )
    }
}

extension EncryptedKeyGrant {
    internal func wireJSON() -> WireJSON {
        return .object([
            .init("grantee_did", .string(granteeDid)),
            .init("key_epoch", .unsigned(keyEpoch)),
            .init("grantee_public_key_id", .string(granteePublicKeyId)),
            .init("ephemeral_public_key", .bytes(ephemeralPublicKey)),
            .init("encrypted_key", .bytes(encryptedKey)),
            .init("granted_by", .string(grantedBy)),
            .init("granted_at", .unsigned(grantedAt)),
        ])
    }

    internal init(wireJSON value: WireJSON) throws {
        let g = try WireJSONObject(value, "encrypted_key_grant")
        self.init(
            granteeDid: try g.required("grantee_did").string(g.label("grantee_did")),
            keyEpoch: try g.required("key_epoch").unsigned(g.label("key_epoch"), as: UInt32.self),
            granteePublicKeyId: try g.required("grantee_public_key_id").string(g.label("grantee_public_key_id")),
            ephemeralPublicKey: try g.required("ephemeral_public_key").bytes(g.label("ephemeral_public_key")),
            encryptedKey: try g.required("encrypted_key").bytes(g.label("encrypted_key")),
            grantedBy: try g.required("granted_by").string(g.label("granted_by")),
            grantedAt: try g.required("granted_at").unsigned(g.label("granted_at"), as: UInt64.self)
        )
    }
}
