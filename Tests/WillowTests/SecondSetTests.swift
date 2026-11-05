import XCTest
@testable import Willow

/// The messages registrations, key grants, and storage-node removals are
/// signed over, checked against the shared known answers
/// (Fixtures/signed_messages_kat_2.json, a byte-for-byte copy of the node's),
/// and the transactions the SDK sends checked against the message built from
/// their own fields.
final class SecondSetTests: XCTestCase {

    // MARK: - Fixture

    struct Fixture: Decodable {
        let privateKeySeedHex: String
        let publicKeyId: String
        let ed25519PublicKeyHex: String
        let secp256k1PublicKeyCompressedHex: String
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let name: String
        let transactionJson: String
        let unsignedBincodeHex: String?
        let message: String
        let ed25519SignatureHex: String
        let secp256k1Keccak256Hex: String
        let secp256k1CompactSignatureHex: String
    }

    /// The RegisterSubgrove vectors `RegisterSubgroveTx` holds and the SDK sends.
    static let registrations = [
        "RegisterSubgrove (data)",
        "RegisterSubgrove (data, defaults)",
        "RegisterSubgrove (file)",
        "RegisterSubgrove (private, non-ASCII, large nonce)",
    ]
    /// The vectors for the other kinds this SDK signs.
    static let otherSent = ["GrantSubgroveKey", "RotateSubgroveKey", "UnregisterStorageNode"]
    /// A BlockchainIndexing registration: its bincode is checked, but the SDK refuses to sign one.
    static let refusedMode = "RegisterSubgrove (indexing)"
    /// Kinds this SDK has no transaction for.
    static let notSent = [
        "UpdateSubgroveReadPricing", "UpdateSubgroveReadPricing (none)",
        "BlockContentHash", "UnblockContentHash", "ReportContent",
    ]

    static func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "signed_messages_kat_2", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }

    static func vector(_ name: String, in fixture: Fixture) throws -> Vector {
        return try XCTUnwrap(fixture.vectors.first { $0.name == name }, name)
    }

    /// The vector's transaction: the kind and the JSON object under it, read exactly.
    static func transaction(_ vector: Vector) throws -> (kind: String, json: WireJSON) {
        guard case .object(let members) = try WireJSON.parse(Data(vector.transactionJson.utf8)), members.count == 1 else {
            throw ValidationError("\(vector.name): not one transaction")
        }
        return (members[0].key, members[0].value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: WireJSON) throws -> T {
        return try JSONDecoder().decode(T.self, from: json.serialized)
    }

    struct UnregisterStorageNodeTx: Decodable {
        let node_did: String
        let signature: [UInt8]
        let public_key_id: String
        let nonce: UInt64
    }

    /// The SDK builder's message for a vector, from the transaction alone.
    static func message(for vector: Vector) throws -> String {
        let (kind, json) = try transaction(vector)
        switch kind {
        case "RegisterSubgrove":
            return try registerSubgroveMessage(RegisterSubgroveTx(wireJSON: json))
        case "GrantSubgroveKey":
            let tx = try decode(GrantSubgroveKeyTx.self, json)
            return try grantSubgroveKeyMessage(
                subgroveId: tx.subgroveId, senderDid: tx.senderDid, grant: tx.encryptedKeyGrant, nonce: UInt64(tx.nonce)
            )
        case "RotateSubgroveKey":
            let tx = try decode(RotateSubgroveKeyTx.self, json)
            return try rotateSubgroveKeyMessage(
                subgroveId: tx.subgroveId, senderDid: tx.senderDid, newEpoch: tx.newEpoch, newGrants: tx.newGrants, nonce: UInt64(tx.nonce)
            )
        case "UnregisterStorageNode":
            let tx = try decode(UnregisterStorageNodeTx.self, json)
            return try unregisterStorageNodeMessage(nodeDid: tx.node_did, nonce: tx.nonce)
        default:
            throw ValidationError("no builder for \(vector.name)")
        }
    }

    static func sentVectors() throws -> [Vector] {
        let fixture = try loadFixture()
        return try (registrations + otherSent).map { try vector($0, in: fixture) }
    }

    // MARK: - Known answers

    func testTheFixtureHoldsTheKnownVectors() throws {
        let fixture = try Self.loadFixture()
        XCTAssertEqual(fixture.vectors.count, 13)
        // A new vector has to be placed in one of the lists.
        XCTAssertEqual(
            Set(fixture.vectors.map { $0.name }),
            Set(Self.registrations + Self.otherSent + [Self.refusedMode] + Self.notSent)
        )
        XCTAssertEqual(fixture.privateKeySeedHex, String(repeating: "03", count: 32))
        XCTAssertEqual(fixture.publicKeyId, "did:willow:a#key-1")
        XCTAssertEqual(try SignedMessagesTests.keyPair(.ed25519).publicKeyHex, fixture.ed25519PublicKeyHex)
        XCTAssertEqual(try SignedMessagesTests.keyPair(.secp256k1).publicKeyHex, fixture.secp256k1PublicKeyCompressedHex)
    }

    func testMessagesAreTheKnownAnswersByteForByte() throws {
        for vector in try Self.sentVectors() {
            let message = try Self.message(for: vector)
            XCTAssertEqual(Array(message.utf8), Array(vector.message.utf8), vector.name)
        }
    }

    func testRegistrationsAreTheKnownBincodeAndBody() throws {
        let fixture = try Self.loadFixture()
        for name in Self.registrations {
            let vector = try Self.vector(name, in: fixture)
            let tx = try RegisterSubgroveTx(wireJSON: try Self.transaction(vector).json)
            XCTAssertEqual(try registerSubgroveUnsignedBincode(tx).hexString, vector.unsignedBincodeHex, name)
            // The body the SDK sends for it is the vector's transaction, byte for byte.
            XCTAssertEqual(String(decoding: try tx.submitBody(), as: UTF8.self), vector.transactionJson, name)
        }
    }

    func testRegistrationsKeepEveryAmountExact() throws {
        let fixture = try Self.loadFixture()
        let data = try RegisterSubgroveTx(wireJSON: try Self.transaction(Self.vector("RegisterSubgrove (data)", in: fixture)).json)
        XCTAssertEqual(data.initialFunding, U128(5_000_000_000_000_000_000))
        guard case .dataStorage(let mode) = data.mode else { return XCTFail("data mode") }
        XCTAssertEqual(mode.readPricing, ReadPricing(enabled: true, pricePerQuery: 1_000_000_000_000_000, ownerRevenueShareBps: 8000))

        let large = try RegisterSubgroveTx(wireJSON: try Self.transaction(Self.vector("RegisterSubgrove (private, non-ASCII, large nonce)", in: fixture)).json)
        XCTAssertEqual(large.nonce, 4_294_967_297)
        XCTAssertEqual(large.privacy?.commitmentFrequency, .everyNBlocks(100))
        XCTAssertEqual(large.confirmationDepth, 2)
    }

    func testTheIndexingRegistrationIsTheKnownBincodeButIsNotSigned() throws {
        let fixture = try Self.loadFixture()
        let vector = try Self.vector(Self.refusedMode, in: fixture)
        let json = try Self.transaction(vector).json
        // The encoder is a complete port, amounts above 2^64 included ...
        XCTAssertEqual(try registerSubgroveUnsignedBincode(json: json).hexString, vector.unsignedBincodeHex)
        XCTAssertEqual(Array(try registerSubgroveMessage(json: json).utf8), Array(vector.message.utf8))
        // ... but RegisterSubgroveTx can't carry that mode, so the SDK never builds one.
        XCTAssertThrowsError(try RegisterSubgroveTx(wireJSON: json))
        let tx = RegisterSubgroveTx(
            subgroveId: "idx-2", schema: "{}", ownerDid: "did:willow:a",
            mode: .blockchainIndexing(SubgroveBlockchainIndexing(retentionWindow: .blocks(1000))),
            publicKeyId: "did:willow:a#key-1", nonce: 6
        )
        for attempt in [{ _ = try registerSubgroveMessage(tx) }, { _ = try registerSubgroveUnsignedBincode(tx) }] {
            XCTAssertThrowsError(try attempt()) { error in
                XCTAssertEqual((error as? WillowError)?.type, .validation)
                XCTAssertTrue((error as? WillowError)?.message.contains("BlockchainIndexing") == true)
            }
        }
    }

    func testSecp256k1SignaturesAreTheKnownAnswers() throws {
        let keyPair = try SignedMessagesTests.keyPair(.secp256k1)
        for vector in try Self.sentVectors() {
            let message = Data(try Self.message(for: vector).utf8)
            XCTAssertEqual(keccak256(message).hexString, vector.secp256k1Keccak256Hex, vector.name)
            XCTAssertEqual(try keyPair.sign(message).hexString, vector.secp256k1CompactSignatureHex, vector.name)
        }
    }

    /// CryptoKit's Ed25519 signing is randomized, so the known signature is
    /// checked to verify over the builder's message, as is the SDK's own.
    func testEd25519SignaturesOverTheKnownAnswers() throws {
        let keyPair = try SignedMessagesTests.keyPair(.ed25519)
        for vector in try Self.sentVectors() {
            let message = Data(try Self.message(for: vector).utf8)
            XCTAssertTrue(try verify(
                algorithm: .ed25519, publicKey: keyPair.publicKey,
                message: message, signature: SignedMessagesTests.hex(vector.ed25519SignatureHex)
            ), vector.name)
            let signature = try keyPair.sign(message)
            XCTAssertTrue(try verify(algorithm: .ed25519, publicKey: keyPair.publicKey, message: message, signature: signature), vector.name)
        }
    }

    func testConfigBindsEveryField() throws {
        let fixture = try Self.loadFixture()
        let base = try RegisterSubgroveTx(wireJSON: try Self.transaction(Self.vector("RegisterSubgrove (data)", in: fixture)).json)
        let original = try registerSubgroveMessage(base)
        var changes: [(String, RegisterSubgroveTx)] = []
        var tx = base; tx.name = "Other"; changes.append(("name", tx))
        tx = base; tx.description = ""; changes.append(("description", tx))
        tx = base; tx.schema = "{}"; changes.append(("schema", tx))
        tx = base; tx.admins = []; changes.append(("admins", tx))
        tx = base; tx.initialFunding = U128(5_000_000_000_000_000_001); changes.append(("initialFunding", tx))
        tx = base; tx.mode = .dataStorage(SubgroveDataStorage(name: "Notes", writers: ["did:willow:a"], freeReaders: [])); changes.append(("mode", tx))
        tx = base; tx.confirmationDepth = 1; changes.append(("confirmationDepth", tx))
        tx = base; tx.publicKeyId = "did:willow:a#key-2"; changes.append(("publicKeyId", tx))
        for (field, changed) in changes {
            XCTAssertNotEqual(try registerSubgroveMessage(changed), original, field)
        }
        // The signature is not part of what is signed.
        tx = base; tx.signature = [1, 2, 3]
        XCTAssertEqual(try registerSubgroveMessage(tx), original)
    }

    // MARK: - Refusals

    func testALineBreakInASignedTextFieldIsRefused() throws {
        let grant = EncryptedKeyGrant(
            granteeDid: "did:willow:b", keyEpoch: 0, granteePublicKeyId: "did:willow:b#key-1",
            ephemeralPublicKey: [1], encryptedKey: [2], grantedBy: "did:willow:a", grantedAt: 1
        )
        func withBreak(_ grant: EncryptedKeyGrant, grantee: String? = nil, key: String? = nil, by: String? = nil) -> EncryptedKeyGrant {
            return EncryptedKeyGrant(
                granteeDid: grantee ?? grant.granteeDid, keyEpoch: grant.keyEpoch,
                granteePublicKeyId: key ?? grant.granteePublicKeyId, ephemeralPublicKey: grant.ephemeralPublicKey,
                encryptedKey: grant.encryptedKey, grantedBy: by ?? grant.grantedBy, grantedAt: grant.grantedAt
            )
        }
        let registration = RegisterSubgroveTx(subgroveId: "sg", schema: "{}", ownerDid: "did:willow:a", publicKeyId: "did:willow:a#key-1", nonce: 1)
        var badSubgrove = registration; badSubgrove.subgroveId = "a\r\nb"
        var badOwner = registration; badOwner.ownerDid = "did:willow:a\n"

        let attempts: [(String, () throws -> Void)] = [
            ("register subgrove", { _ = try registerSubgroveMessage(badSubgrove) }),
            ("register owner", { _ = try registerSubgroveMessage(badOwner) }),
            ("grant subgrove", { _ = try grantSubgroveKeyMessage(subgroveId: "a\nb", senderDid: "s", grant: grant, nonce: 1) }),
            ("grant sender", { _ = try grantSubgroveKeyMessage(subgroveId: "sg", senderDid: "s\r\n", grant: grant, nonce: 1) }),
            ("grant grantee", { _ = try grantSubgroveKeyMessage(subgroveId: "sg", senderDid: "s", grant: withBreak(grant, grantee: "b\n"), nonce: 1) }),
            ("grant key", { _ = try grantSubgroveKeyMessage(subgroveId: "sg", senderDid: "s", grant: withBreak(grant, key: "k\n"), nonce: 1) }),
            ("grant by", { _ = try grantSubgroveKeyMessage(subgroveId: "sg", senderDid: "s", grant: withBreak(grant, by: "a\n"), nonce: 1) }),
            ("rotate grant", {
                _ = try rotateSubgroveKeyMessage(subgroveId: "sg", senderDid: "s", newEpoch: 1, newGrants: [grant, withBreak(grant, by: "\r\n")], nonce: 1)
            }),
            ("unregister node", { _ = try unregisterStorageNodeMessage(nodeDid: "did:willow:n\n", nonce: 1) }),
        ]
        for (name, attempt) in attempts {
            XCTAssertThrowsError(try attempt(), name) { error in
                XCTAssertEqual((error as? WillowError)?.type, .validation, name)
            }
        }

        // Fields hashed into Config (not written as a line) may hold one.
        var multiline = registration
        multiline.description = "line one\nline two"
        XCTAssertNoThrow(try registerSubgroveMessage(multiline))
    }

    func testANegativeNonceIsRefused() {
        let registration = RegisterSubgroveTx(subgroveId: "sg", schema: "{}", ownerDid: "did:willow:a", publicKeyId: "did:willow:a#key-1", nonce: -1)
        XCTAssertThrowsError(try registerSubgroveMessage(registration))
    }

    // MARK: - Exact numbers and JSON

    func testU128IsExact() {
        XCTAssertEqual(U128.max.description, "340282366920938463463374607431768211455")
        XCTAssertEqual(U128("340282366920938463463374607431768211455"), .max)
        XCTAssertNil(U128("340282366920938463463374607431768211456"))
        XCTAssertNil(U128(""))
        XCTAssertNil(U128("-1"))
        XCTAssertNil(U128("1e3"))
        XCTAssertEqual(U128("10000000000000000000000")?.description, "10000000000000000000000")
        XCTAssertEqual(U128("18446744073709551616"), U128(high: 1, low: 0))
        XCTAssertEqual(U128(high: 1, low: 0).description, "18446744073709551616")
        XCTAssertEqual(U128(0).description, "0")
        XCTAssertEqual(Data(U128("10000000000000000000000")!.littleEndianBytes).hexString, "000040b2bac9e0191e02000000000000")
        XCTAssertEqual(U128(5).exactly(as: UInt8.self), 5)
        XCTAssertNil(U128(256).exactly(as: UInt8.self))
    }

    func testU128DecodesAndEncodesWithCodable() throws {
        struct Box: Codable { let v: U128 }
        let small = try JSONDecoder().decode(Box.self, from: Data(#"{"v":1000000000000000}"#.utf8))
        XCTAssertEqual(small.v, U128(1_000_000_000_000_000))
        let large = try JSONDecoder().decode(Box.self, from: Data(#"{"v":10000000000000000000000}"#.utf8))
        XCTAssertEqual(large.v.description, "10000000000000000000000")
        let text = try JSONDecoder().decode(Box.self, from: Data(#"{"v":"340282366920938463463374607431768211455"}"#.utf8))
        XCTAssertEqual(text.v, .max)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(small), as: UTF8.self), #"{"v":1000000000000000}"#)
    }

    func testWireJSONReadsAndWritesTheKnownTransactionsExactly() throws {
        for vector in try Self.loadFixture().vectors {
            let value = try WireJSON.parse(Data(vector.transactionJson.utf8))
            XCTAssertEqual(String(decoding: value.serialized, as: UTF8.self), vector.transactionJson, vector.name)
        }
    }

    func testWireJSONEscapesAsTheNodeDoes() throws {
        let value = WireJSON.object([.init("k", .string("a\"b\\c\n\t\u{01}\u{7F}é/"))])
        XCTAssertEqual(String(decoding: value.serialized, as: UTF8.self), "{\"k\":\"a\\\"b\\\\c\\n\\t\\u0001\u{7F}é/\"}")
        XCTAssertEqual(try WireJSON.parse(value.serialized), value)
        XCTAssertEqual(try WireJSON.parse(Data(#"{"k":"😀\/"}"#.utf8)), .object([.init("k", .string("😀/"))]))
    }

    func testWireJSONRefusesWhatTheNodeRefuses() {
        for text in [
            #"{"a":1,"a":2}"#, #"{"a":"\ud83d"}"#, #"{"a":1} x"#, #"{"a":01}"#, #"[1,]"#, "{\"a\":\"\u{01}\"}", #"{"a":-}"#,
        ] {
            XCTAssertThrowsError(try WireJSON.parse(Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try WireJSON.parse(Data([0x22, 0xFF, 0x22])))
        XCTAssertEqual(try WireJSON.parse(Data(" [1.5e-3, -0, true, null] ".utf8)), .array([.number("1.5e-3"), .number("-0"), .bool(true), .null]))
    }

    func testOmittedFieldsTakeTheNodesDefaults() throws {
        let fixture = try Self.loadFixture()
        let vector = try Self.vector("RegisterSubgrove (data, defaults)", in: fixture)
        // The defaults vector with every defaulted field left out hashes the same.
        let minimal = try WireJSON.parse(Data(#"""
        {"subgrove_id":"sg-1","name":"","schema":"{\"version\":1,\"fields\":{},\"indexes\":[],\"required_fields\":[]}","owner_did":"did:willow:a","signature":[],"public_key_id":"did:willow:a#key-1","nonce":4}
        """#.utf8))
        XCTAssertEqual(try registerSubgroveUnsignedBincode(json: minimal).hexString, vector.unsignedBincodeHex)
        // The indexing vector with its other defaults left out, and its
        // flexible amounts as decimal strings, hashes the same.
        let indexing = try Self.vector(Self.refusedMode, in: fixture)
        let text = indexing.transactionJson
            .replacingOccurrences(of: #","epoch_length":100"#, with: "")
            .replacingOccurrences(of: #","deferred":true,"bond_amount":0"#, with: #","deferred":true"#)
            .replacingOccurrences(of: #""reward_per_epoch":2000000000000000000"#, with: #""reward_per_epoch":"2000000000000000000""#)
            .replacingOccurrences(of: #""min_indexer_stake":10000000000000000000000"#, with: #""min_indexer_stake":"10000000000000000000000""#)
        XCTAssertNotEqual(text, indexing.transactionJson)
        guard case .object(let members) = try WireJSON.parse(Data(text.utf8)) else { return XCTFail("object") }
        XCTAssertEqual(try registerSubgroveUnsignedBincode(json: members[0].value).hexString, indexing.unsignedBincodeHex)

        // A field with no default is refused rather than guessed.
        let noName = try WireJSON.parse(Data(#"{"subgrove_id":"sg-1","schema":"{}","owner_did":"did:willow:a","signature":[],"public_key_id":"k","nonce":4}"#.utf8))
        XCTAssertThrowsError(try registerSubgroveUnsignedBincode(json: noName))
    }

    // MARK: - Transactions sent

    /// The one transaction in a `/tx/submit` body, read exactly.
    static func submitted(_ variant: String, from request: ReceivedRequest) throws -> WireJSON {
        XCTAssertEqual("\(request.method) \(request.target)", "POST /tx/submit")
        guard case .object(let members) = try WireJSON.parse(request.body), members.count == 1, members[0].key == variant else {
            throw ValidationError("not one \(variant)")
        }
        return members[0].value
    }

    func testConsensusRegisterSubgroveIsSignedOverTheTransactionSent() async throws {
        let fixture = try Self.loadFixture()
        for name in Self.registrations {
            let vector = try Self.vector(name, in: fixture)
            let registration = try RegisterSubgroveTx(wireJSON: try Self.transaction(vector).json)
            for algorithm in [SignatureAlgorithm.ed25519, .secp256k1] {
                let keyPair = try SignedMessagesTests.keyPair(algorithm)
                let (stub, consensus) = SignedMessagesTests.consensusStub(nextNonce: UInt64(registration.nonce))
                var input = registration
                input.nonce = 0 // the flow picks the nonce
                let result = try await consensus.registerSubgrove(
                    input, privateKey: keyPair.privateKey, signFunction: { message, _ in try keyPair.sign(message) }
                )
                XCTAssertTrue(result.success)

                let sent = try Self.submitted("RegisterSubgrove", from: try XCTUnwrap(stub.requests.last))
                let fields = try WireJSONObject(sent, "sent")
                let signature = try fields.required("signature").bytes("signature")
                // The message from the transaction's own fields (Config hashes it with an empty signature).
                let message = try registerSubgroveMessage(json: sent)
                XCTAssertTrue(try verify(
                    algorithm: algorithm, publicKey: keyPair.publicKey,
                    message: Data(message.utf8), signature: Data(signature)
                ), "\(name), \(algorithm)")
                XCTAssertEqual(Array(message.utf8), Array(vector.message.utf8), name)
                if algorithm == .secp256k1 {
                    XCTAssertEqual(Data(signature).hexString, vector.secp256k1CompactSignatureHex, name)
                }
                // With its signature emptied, what was sent is the vector's transaction.
                var unsigned = try RegisterSubgroveTx(wireJSON: sent)
                unsigned.signature = []
                XCTAssertEqual(String(decoding: try unsigned.submitBody(), as: UTF8.self), vector.transactionJson, name)
            }
        }
    }

    func testConsensusRegisterSubgroveConvenienceSendsTheModesName() async throws {
        let keyPair = try SignedMessagesTests.keyPair(.ed25519)
        let (stub, consensus) = SignedMessagesTests.consensusStub(nextNonce: 7)
        _ = try await consensus.registerSubgrove(
            subgroveId: "notes", schema: "{}", ownerDid: "did:willow:a", privateKey: keyPair.privateKey,
            publicKeyId: "did:willow:a#key-1", signFunction: { message, _ in try keyPair.sign(message) },
            mode: .dataStorage(SubgroveDataStorage(name: "Notes", writers: ["did:willow:a"]))
        )
        let sent = try WireJSONObject(try Self.submitted("RegisterSubgrove", from: try XCTUnwrap(stub.requests.last)), "sent")
        XCTAssertEqual(try sent.required("name").string("name"), "Notes")
        XCTAssertEqual(try sent.required("nonce").unsigned("nonce", as: UInt64.self), 7)
        // Every field goes out explicitly.
        XCTAssertEqual(sent.members.map { $0.key }, [
            "subgrove_id", "name", "description", "schema", "owner_did", "admins", "initial_funding",
            "checkpoint_verification", "mode", "privacy", "initial_owner_key_grant", "template_config",
            "confirmation_depth", "signature", "public_key_id", "nonce", "cryptographic_completeness",
        ])
    }

    func testConsensusRegisterSubgroveRefusesBeforeSigning() async throws {
        let (stub, consensus) = SignedMessagesTests.consensusStub(nextNonce: 1)
        var signed = false
        let refused = [
            RegisterSubgroveTx(
                subgroveId: "idx", schema: "{}", ownerDid: "did:willow:a",
                mode: .blockchainIndexing(SubgroveBlockchainIndexing()), publicKeyId: "did:willow:a#key-1", nonce: 0
            ),
            RegisterSubgroveTx(subgroveId: "a\nb", schema: "{}", ownerDid: "did:willow:a", publicKeyId: "did:willow:a#key-1", nonce: 0),
            // Registrations the node refuses: a subgrove ID that breaks its rule, a schema with indexes.
            RegisterSubgroveTx(subgroveId: "_sg", schema: "{}", ownerDid: "did:willow:a", publicKeyId: "did:willow:a#key-1", nonce: 0),
            RegisterSubgroveTx(
                subgroveId: "notes-1", schema: Self.indexedSchema, ownerDid: "did:willow:a",
                mode: .fileStorage(SubgroveFileStorage(name: "f", maxFileSize: 1024, replicationFactor: 1)), publicKeyId: "did:willow:a#key-1", nonce: 0
            ),
        ]
        for registration in refused {
            do {
                _ = try await consensus.registerSubgrove(
                    registration, privateKey: Data(), signFunction: { _, _ in signed = true; return Data() }
                )
                XCTFail("\(registration.subgroveId) must be refused")
            } catch let error as WillowError {
                XCTAssertEqual(error.type, .validation)
            }
        }
        XCTAssertFalse(signed)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    static let indexedSchema = #"{"version":1,"fields":{"t":"string"},"indexes":[{"name":"by_t","fields":["t"],"unique":false}],"required_fields":[]}"#

    /// The node refuses a DataStorage or FileStorage registration whose
    /// subgrove ID isn't 1 to 64 ASCII letters, digits, `-`, or `_` starting
    /// with a letter or digit, or whose schema declares indexes; the builder
    /// refuses both before anything is signed.
    func testDataAndFileRegistrationsFollowTheNodesRules() throws {
        func registration(_ id: String, schema: String = "{}", mode: SubgroveMode = .dataStorage(SubgroveDataStorage())) -> RegisterSubgroveTx {
            return RegisterSubgroveTx(subgroveId: id, schema: schema, ownerDid: "did:willow:a", mode: mode, publicKeyId: "did:willow:a#key-1", nonce: 1)
        }
        let accepted = ["a", "0", "notes-1", "a_b-C9", String(repeating: "z", count: 64)]
        for id in accepted {
            XCTAssertNoThrow(try registerSubgroveMessage(registration(id)), id)
            XCTAssertNoThrow(try registerSubgroveMessage(registration(id, mode: .fileStorage(SubgroveFileStorage(name: "f", maxFileSize: 1024, replicationFactor: 1)))), id)
        }
        XCTAssertNoThrow(try registerSubgroveMessage(registration("a", schema: #"{"version":1,"fields":{},"indexes":[],"required_fields":[]}"#)))
        let refused = ["", "-a", "_a", "a.b", "a b", "a/b", "a:b", "caf\u{E9}", String(repeating: "z", count: 65)]
        for id in refused {
            for mode in [SubgroveMode.dataStorage(SubgroveDataStorage()), .fileStorage(SubgroveFileStorage(name: "f", maxFileSize: 1024, replicationFactor: 1))] {
                XCTAssertThrowsError(try registerSubgroveMessage(registration(id, mode: mode)), id) { error in
                    XCTAssertEqual((error as? WillowError)?.type, .validation, id)
                }
            }
        }
        for mode in [SubgroveMode.dataStorage(SubgroveDataStorage()), .fileStorage(SubgroveFileStorage(name: "f", maxFileSize: 1024, replicationFactor: 1))] {
            XCTAssertThrowsError(try registerSubgroveMessage(registration("a", schema: Self.indexedSchema, mode: mode))) { error in
                XCTAssertTrue("\(error)".contains("indexes"), "\(error)")
            }
        }
    }

    /// The node also refuses a DataStorage or FileStorage registration whose
    /// admins, writers, or free readers aren't Willow DIDs, or whose schema it
    /// can't read as its schema definition, and a private DataStorage
    /// registration whose initial key grant isn't key epoch 0 to the owner.
    /// The builder refuses each before anything is signed.
    func testRegistrationDIDsSchemaAndInitialGrantFollowTheNodesRules() throws {
        func registration(
            admins: [String] = [], writers: [String] = [], readers: [String] = [], schema: String = "{}",
            file: Bool = false, privacy: PrivacyConfig? = nil, grant: EncryptedKeyGrant? = nil
        ) -> RegisterSubgroveTx {
            let mode: SubgroveMode = file
                ? .fileStorage(SubgroveFileStorage(name: "f", maxFileSize: 1024, replicationFactor: 1, writers: writers, freeReaders: readers))
                : .dataStorage(SubgroveDataStorage(writers: writers, freeReaders: readers))
            return RegisterSubgroveTx(
                subgroveId: "sg", schema: schema, ownerDid: "did:willow:a", admins: admins, mode: mode,
                privacy: privacy, initialOwnerKeyGrant: grant, publicKeyId: "did:willow:a#key-1", nonce: 1
            )
        }
        func assertRefused(_ tx: RegisterSubgroveTx, _ what: String, line: UInt = #line) {
            XCTAssertThrowsError(try registerSubgroveMessage(tx), what, line: line) { error in
                XCTAssertEqual((error as? WillowError)?.type, .validation, what, line: line)
            }
        }

        let longest: String = "did:willow:" + String(repeating: "x", count: 117) // 128 bytes
        let tooLong: String = longest + "x"
        let dids: [String] = ["did:willow:a", "did:willow:zAbc-_9", longest]
        let notDIDs: [String] = [
            "", "did:willow:", "alice", "did:key:z6Mk", "DID:willow:a", " did:willow:a", "did:willow:a b",
            "did:willow:a:b", "did:willow:a,b", "did:willow:a#key-1", "did:willow:caf\u{E9}", tooLong,
        ]
        for file in [false, true] {
            for did in dids {
                XCTAssertNoThrow(try registerSubgroveMessage(registration(admins: [did], writers: [did], readers: [did], file: file)), did)
            }
            for did in notDIDs {
                assertRefused(registration(admins: [did], file: file), "admin \(did)")
                assertRefused(registration(writers: ["did:willow:a", did], file: file), "writer \(did)")
                assertRefused(registration(readers: [did], file: file), "free reader \(did)")
            }
        }

        let readable: [String] = [
            "{}", " { } ", #"{"version":1,"fields":{},"indexes":[],"required_fields":[]}"#,
            #"{"version":4294967295,"fields":{"a":"string","b":"number","c":"boolean","d":"array","e":"object","f":"bytes","g":{"string":null}},"required_fields":["a"]}"#,
            #"{"version":0,"other":{"x":[1,2]},"note":"keys the node doesn't know are ignored"}"#,
        ]
        let unreadable: [String] = [
            "", "null", "[]", "not json", "{} x", #"{"version":1.0}"#, #"{"version":-1}"#, #"{"version":4294967296}"#,
            #"{"version":"1"}"#, #"{"version":null}"#, #"{"version":1,"version":1}"#, #"{"fields":[]}"#,
            #"{"fields":{"a":"String"}}"#, #"{"fields":{"a":"int"}}"#, #"{"fields":{"a":{"string":1}}}"#,
            #"{"indexes":null}"#, #"{"indexes":{}}"#, #"{"required_fields":"a"}"#, #"{"required_fields":[1]}"#,
        ]
        for file in [false, true] {
            for schema in readable {
                XCTAssertNoThrow(try registerSubgroveMessage(registration(schema: schema, file: file)), schema)
            }
            for schema in unreadable {
                assertRefused(registration(schema: schema, file: file), "schema \(schema)")
            }
        }

        let privacy = PrivacyConfig(commitmentFrequency: .everyUpdate)
        func grant(to grantee: String = "did:willow:a", epoch: UInt32 = 0) -> EncryptedKeyGrant {
            return EncryptedKeyGrant(
                granteeDid: grantee, keyEpoch: epoch, granteePublicKeyId: "\(grantee)#key-1",
                ephemeralPublicKey: Array(repeating: 1, count: 32), encryptedKey: [2], grantedBy: "did:willow:a", grantedAt: 1
            )
        }
        XCTAssertNoThrow(try registerSubgroveMessage(registration(privacy: privacy, grant: grant())))
        XCTAssertNoThrow(try registerSubgroveMessage(registration(privacy: privacy)))
        assertRefused(registration(privacy: privacy, grant: grant(epoch: 1)), "a grant of epoch 1")
        assertRefused(registration(privacy: privacy, grant: grant(to: "did:willow:b")), "a grant to another DID")
        // The node checks the grant of a private DataStorage registration only.
        XCTAssertNoThrow(try registerSubgroveMessage(registration(grant: grant(epoch: 1))))
        XCTAssertNoThrow(try registerSubgroveMessage(registration(file: true, privacy: privacy, grant: grant(to: "did:willow:b"))))
    }

    /// A grantee in a grant or rotation, and a revokee or sender in a revoke,
    /// must be a Willow DID, and a revoked subgrove's ID can't hold ':'. The
    /// builders refuse anything else, and the flows sign and send nothing.
    func testAGranteeOrRevokeeThatIsntADIDIsRefused() async throws {
        func grant(_ grantee: String) -> EncryptedKeyGrant {
            return EncryptedKeyGrant(
                granteeDid: grantee, keyEpoch: 1, granteePublicKeyId: "did:willow:b#key-1",
                ephemeralPublicKey: Array(repeating: 1, count: 32), encryptedKey: [2], grantedBy: "did:willow:a", grantedAt: 1
            )
        }
        let good = grant("did:willow:b")
        XCTAssertNoThrow(try grantSubgroveKeyMessage(subgroveId: "sg", senderDid: "did:willow:a", grant: good, nonce: 1))
        XCTAssertNoThrow(try rotateSubgroveKeyMessage(subgroveId: "sg", senderDid: "did:willow:a", newEpoch: 1, newGrants: [good], nonce: 1))
        XCTAssertNoThrow(try revokeSubgroveKeyMessage(subgroveId: "sg", revokeeDid: "did:willow:b", senderDid: "did:willow:a", nonce: 1))
        let tooLong: String = "did:willow:" + String(repeating: "b", count: 118)
        let notDIDs: [String] = ["b", "did:willow:", "did:key:b", "did:willow:b:c", "did:willow:b,c", tooLong]
        for bad in notDIDs {
            let attempts: [(String, () throws -> Void)] = [
                ("grant", { _ = try grantSubgroveKeyMessage(subgroveId: "sg", senderDid: "did:willow:a", grant: grant(bad), nonce: 1) }),
                ("rotate", {
                    _ = try rotateSubgroveKeyMessage(subgroveId: "sg", senderDid: "did:willow:a", newEpoch: 1, newGrants: [good, grant(bad)], nonce: 1)
                }),
                ("revokee", { _ = try revokeSubgroveKeyMessage(subgroveId: "sg", revokeeDid: bad, senderDid: "did:willow:a", nonce: 1) }),
                ("revoke sender", { _ = try revokeSubgroveKeyMessage(subgroveId: "sg", revokeeDid: "did:willow:b", senderDid: bad, nonce: 1) }),
            ]
            for (name, attempt) in attempts {
                XCTAssertThrowsError(try attempt(), "\(name) \(bad)") { error in
                    XCTAssertEqual((error as? WillowError)?.type, .validation, "\(name) \(bad)")
                }
            }
        }
        XCTAssertThrowsError(try revokeSubgroveKeyMessage(subgroveId: "s:g", revokeeDid: "did:willow:b", senderDid: "did:willow:a", nonce: 1))

        let keyPair = try SignedMessagesTests.keyPair(.ed25519)
        let stub = Self.nonceStub(next: 1)
        let (client, privacy) = try Self.privacy(stub, keyPair)
        defer { withExtendedLifetime(client) {} }
        var signed = false
        let sign: (Data, Data) throws -> Data = { _, _ in signed = true; return Data() }
        let flows: [(String, () async throws -> Void)] = [
            ("grant", { _ = try await privacy.grantSubgroveKey(subgroveId: "sg", grant: grant("bob"), privateKey: Data(), signFunction: sign) }),
            ("rotate", {
                _ = try await privacy.rotateSubgroveKey(subgroveId: "sg", newEpoch: 1, newGrants: [good, grant("bob")], privateKey: Data(), signFunction: sign)
            }),
            ("revokee", { _ = try await privacy.revokeSubgroveKey(subgroveId: "sg", revokeeDid: "bob", privateKey: Data(), signFunction: sign) }),
            ("revoke subgrove", { _ = try await privacy.revokeSubgroveKey(subgroveId: "s:g", revokeeDid: "did:willow:b", privateKey: Data(), signFunction: sign) }),
        ]
        for (name, flow) in flows {
            do {
                try await flow()
                XCTFail("\(name) must be refused")
            } catch let error as WillowError {
                XCTAssertEqual(error.type, .validation, name)
            }
        }
        XCTAssertFalse(signed)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    /// A client whose identity is the fixture's `did:willow:a#key-1` and a
    /// consensus client, both answered by `stub`. `PrivacyOperations` holds
    /// its client weakly, so the client is returned too, to be kept alive.
    static func privacy(_ stub: StubServer, _ keyPair: KeyPair) throws -> (WillowClient, PrivacyOperations) {
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(Identity(
            keyPair: keyPair,
            didDocument: DidDocument(
                id: "did:willow:a",
                publicKeys: [PublicKey(id: "did:willow:a#key-1", type: "Ed25519VerificationKey2018", publicKeyHex: keyPair.publicKeyHex)],
                created: 0, updated: 0
            )
        ))
        let consensus = ConsensusClient(ConsensusConfig(consensusRpcUrl: "http://rpc.test", apiUrl: "http://api.test"), session: stub.session)
        return (client, PrivacyOperations(client: client, consensus: consensus))
    }

    static func nonceStub(next nonce: UInt64) -> StubServer {
        return StubServer { request in
            if request.path.hasSuffix("/nonce") {
                return (200, #"{"success":true,"data":{"did":"did:willow:a","nonce":\#(nonce - 1)},"error":null}"#)
            }
            return (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""},"error":null}"#)
        }
    }

    func testKeyGrantsAreSignedOverTheTransactionSent() async throws {
        let fixture = try Self.loadFixture()
        let grantVector = try Self.vector("GrantSubgroveKey", in: fixture)
        let grantTx = try Self.decode(GrantSubgroveKeyTx.self, try Self.transaction(grantVector).json)
        let rotateVector = try Self.vector("RotateSubgroveKey", in: fixture)
        let rotateTx = try Self.decode(RotateSubgroveKeyTx.self, try Self.transaction(rotateVector).json)

        for algorithm in [SignatureAlgorithm.ed25519, .secp256k1] {
            let keyPair = try SignedMessagesTests.keyPair(algorithm)

            var stub = Self.nonceStub(next: UInt64(grantTx.nonce))
            var (client, privacy) = try Self.privacy(stub, keyPair)
            _ = try await privacy.grantSubgroveKey(
                subgroveId: grantTx.subgroveId, grant: grantTx.encryptedKeyGrant,
                privateKey: keyPair.privateKey, signFunction: { message, _ in try keyPair.sign(message) }
            )
            let grant = try Self.decode(GrantSubgroveKeyTx.self, try Self.submitted("GrantSubgroveKey", from: try XCTUnwrap(stub.requests.last)))
            let grantMessage = try grantSubgroveKeyMessage(
                subgroveId: grant.subgroveId, senderDid: grant.senderDid, grant: grant.encryptedKeyGrant, nonce: UInt64(grant.nonce)
            )
            XCTAssertEqual(Array(grantMessage.utf8), Array(grantVector.message.utf8))
            XCTAssertTrue(try verify(algorithm: algorithm, publicKey: keyPair.publicKey, message: Data(grantMessage.utf8), signature: Data(grant.signature)))
            if algorithm == .secp256k1 {
                XCTAssertEqual(Data(grant.signature).hexString, grantVector.secp256k1CompactSignatureHex)
            }

            stub = Self.nonceStub(next: UInt64(rotateTx.nonce))
            (client, privacy) = try Self.privacy(stub, keyPair)
            _ = try await privacy.rotateSubgroveKey(
                subgroveId: rotateTx.subgroveId, newEpoch: rotateTx.newEpoch, newGrants: rotateTx.newGrants,
                privateKey: keyPair.privateKey, signFunction: { message, _ in try keyPair.sign(message) }
            )
            let rotate = try Self.decode(RotateSubgroveKeyTx.self, try Self.submitted("RotateSubgroveKey", from: try XCTUnwrap(stub.requests.last)))
            let rotateMessage = try rotateSubgroveKeyMessage(
                subgroveId: rotate.subgroveId, senderDid: rotate.senderDid, newEpoch: rotate.newEpoch,
                newGrants: rotate.newGrants, nonce: UInt64(rotate.nonce)
            )
            XCTAssertEqual(Array(rotateMessage.utf8), Array(rotateVector.message.utf8))
            XCTAssertTrue(try verify(algorithm: algorithm, publicKey: keyPair.publicKey, message: Data(rotateMessage.utf8), signature: Data(rotate.signature)))
            if algorithm == .secp256k1 {
                XCTAssertEqual(Data(rotate.signature).hexString, rotateVector.secp256k1CompactSignatureHex)
            }

            stub = Self.nonceStub(next: 21)
            (client, privacy) = try Self.privacy(stub, keyPair)
            _ = try await privacy.revokeSubgroveKey(
                subgroveId: "private-1", revokeeDid: "did:willow:b",
                privateKey: keyPair.privateKey, signFunction: { message, _ in try keyPair.sign(message) }
            )
            let revoke = try Self.decode(RevokeSubgroveKeyTx.self, try Self.submitted("RevokeSubgroveKey", from: try XCTUnwrap(stub.requests.last)))
            let revokeMessage = try revokeSubgroveKeyMessage(
                subgroveId: revoke.subgroveId, revokeeDid: revoke.revokeeDid, senderDid: revoke.senderDid, nonce: UInt64(revoke.nonce)
            )
            XCTAssertEqual(revokeMessage, "RevokeSubgroveKey:private-1:did:willow:b:did:willow:a:21")
            XCTAssertTrue(try verify(algorithm: algorithm, publicKey: keyPair.publicKey, message: Data(revokeMessage.utf8), signature: Data(revoke.signature)))
            withExtendedLifetime(client) {}
        }
    }

    func testAKeyGrantWithALineBreakIsRefusedBeforeSigning() async throws {
        let keyPair = try SignedMessagesTests.keyPair(.ed25519)
        let stub = Self.nonceStub(next: 1)
        let (client, privacy) = try Self.privacy(stub, keyPair)
        defer { withExtendedLifetime(client) {} }
        let grant = EncryptedKeyGrant(
            granteeDid: "did:willow:b\n", keyEpoch: 0, granteePublicKeyId: "did:willow:b#key-1",
            ephemeralPublicKey: [1], encryptedKey: [2], grantedBy: "did:willow:a", grantedAt: 1
        )
        var signed = false
        do {
            _ = try await privacy.grantSubgroveKey(subgroveId: "sg", grant: grant, privateKey: Data(), signFunction: { _, _ in signed = true; return Data() })
            XCTFail("must be refused")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
        do {
            _ = try await privacy.rotateSubgroveKey(subgroveId: "sg", newEpoch: 1, newGrants: [grant], privateKey: Data(), signFunction: { _, _ in signed = true; return Data() })
            XCTFail("must be refused")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
        XCTAssertFalse(signed)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testUnregisterStorageNodeIsSignedOverTheTransactionSent() async throws {
        let fixture = try Self.loadFixture()
        let vector = try Self.vector("UnregisterStorageNode", in: fixture)
        for algorithm in [SignatureAlgorithm.ed25519, .secp256k1] {
            let keyPair = try SignedMessagesTests.keyPair(algorithm)
            let stub = StubServer { _ in (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""},"error":null}"#) }
            let client = try stub.client(baseURL: "http://api.test")
            try await client.files.unregisterStorageNode(nodeDid: "did:willow:a", signing: SignedMessagesTests.fileSigning(keyPair, nonce: 14))

            let tx = try Self.decode(UnregisterStorageNodeTx.self, try Self.submitted("UnregisterStorageNode", from: try XCTUnwrap(stub.requests.first)))
            XCTAssertEqual(tx.public_key_id, "did:willow:a#key-1")
            let message = try unregisterStorageNodeMessage(nodeDid: tx.node_did, nonce: tx.nonce)
            XCTAssertEqual(Array(message.utf8), Array(vector.message.utf8))
            XCTAssertTrue(try verify(algorithm: algorithm, publicKey: keyPair.publicKey, message: Data(message.utf8), signature: Data(tx.signature)))
            if algorithm == .secp256k1 {
                XCTAssertEqual(Data(tx.signature).hexString, vector.secp256k1CompactSignatureHex)
            }
        }

        let stub = StubServer { _ in (200, "{}") }
        let client = try stub.client(baseURL: "http://api.test")
        var signed = false
        let signing = FileSigningOptions(
            ownerDid: "did:willow:a", privateKey: Data(), publicKeyId: "did:willow:a#key-1",
            signFunction: { _, _ in signed = true; return Data() }, nonce: 1
        )
        do {
            try await client.files.unregisterStorageNode(nodeDid: "did:willow:n\r\n", signing: signing)
            XCTFail("must be refused")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
        XCTAssertFalse(signed)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testUnitVariantsUseSerdesForm() throws {
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(RetentionWindow.indefinite), as: UTF8.self), #""Indefinite""#)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(CommitmentFrequency.everyUpdate), as: UTF8.self), #""EveryUpdate""#)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(RetentionWindow.blocks(5)), as: UTF8.self), #"{"Blocks":5}"#)
        XCTAssertEqual(try JSONDecoder().decode(RetentionWindow.self, from: Data(#""VerifyOnly""#.utf8)), .verifyOnly)
        XCTAssertEqual(try JSONDecoder().decode(RetentionWindow.self, from: Data(#"{"Seconds":300}"#.utf8)), .seconds(300))
        XCTAssertEqual(try JSONDecoder().decode(CommitmentFrequency.self, from: Data(#""Never""#.utf8)), .never)
        XCTAssertEqual(try JSONDecoder().decode(CommitmentFrequency.self, from: Data(#"{"EveryNSeconds":60}"#.utf8)), .everyNSeconds(60))
    }
}
