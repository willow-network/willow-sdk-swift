import XCTest
@testable import Willow

/// The messages data and file writes are signed over, checked against the
/// shared known answers (Fixtures/signed_messages_kat.json, a byte-for-byte
/// copy of the node's), and the transactions the SDK sends checked against
/// the message built from their own fields.
final class SignedMessagesTests: XCTestCase {

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
        let inputs: Inputs
        let message: String
        let ed25519SignatureHex: String
        let secp256k1Keccak256Hex: String
        let secp256k1CompactSignatureHex: String
    }

    struct Inputs: Decodable {
        let subgroveId: String
        let key: String?
        let fileKey: String?
        let ownerDid: String
        let dataUtf8: String?
        let filename: String?
        let contentType: String?
        let totalSize: UInt64?
        let contentHashHex: String?
        let chunkCount: UInt32?
        let chunkSize: UInt32?
        let chunkMerkleRootHex: String?
        let encryption: Encryption?
        let nonce: UInt64
    }

    struct Encryption: Decodable {
        let keyEpoch: UInt64
        let nonceHex: String
    }

    /// The vectors for the kinds this SDK signs.
    static let sendable = [
        "StoreData",
        "StoreData (non-ASCII, large nonce)",
        "StoreFileManifest",
        "StoreFileManifest (encrypted)",
        "DeleteFileManifest",
    ]
    /// The SDK sends no UpdateData or DeleteData transaction and has no builder for them.
    static let notSent = ["UpdateData", "DeleteData"]

    static func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "signed_messages_kat", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }

    static func vector(_ name: String, in fixture: Fixture) throws -> Vector {
        return try XCTUnwrap(fixture.vectors.first { $0.name == name }, name)
    }

    static func sendableVectors() throws -> [Vector] {
        let fixture = try loadFixture()
        return try sendable.map { try vector($0, in: fixture) }
    }

    static func keyPair(_ algorithm: SignatureAlgorithm) throws -> KeyPair {
        return try keyPairFromPrivateKey(algorithm: algorithm, privateKeyHex: try loadFixture().privateKeySeedHex)
    }

    static func hex(_ string: String) throws -> Data {
        return try XCTUnwrap(Data(hexString: string), string)
    }

    /// The SDK builder's message for a vector's inputs, by the kind on its first line.
    static func message(for vector: Vector) throws -> String {
        let inputs = vector.inputs
        let kind = vector.message.split(separator: "\n", omittingEmptySubsequences: false)[0]
        switch kind {
        case "StoreData":
            return try storeDataMessage(
                subgroveId: inputs.subgroveId,
                key: XCTUnwrap(inputs.key),
                ownerDid: inputs.ownerDid,
                data: Data(XCTUnwrap(inputs.dataUtf8).utf8),
                nonce: inputs.nonce
            )
        case "StoreFileManifest":
            let encryption = try inputs.encryption.map {
                FileEncryption(keyEpoch: $0.keyEpoch, nonce: try hex($0.nonceHex))
            }
            return try storeFileManifestMessage(
                subgroveId: inputs.subgroveId,
                fileKey: XCTUnwrap(inputs.fileKey),
                ownerDid: inputs.ownerDid,
                filename: XCTUnwrap(inputs.filename),
                contentType: XCTUnwrap(inputs.contentType),
                totalSize: XCTUnwrap(inputs.totalSize),
                contentHash: hex(XCTUnwrap(inputs.contentHashHex)),
                chunkCount: XCTUnwrap(inputs.chunkCount),
                chunkSize: XCTUnwrap(inputs.chunkSize),
                chunkMerkleRoot: hex(XCTUnwrap(inputs.chunkMerkleRootHex)),
                encryption: encryption,
                nonce: inputs.nonce
            )
        case "DeleteFileManifest":
            return try deleteFileManifestMessage(
                subgroveId: inputs.subgroveId,
                fileKey: XCTUnwrap(inputs.fileKey),
                ownerDid: inputs.ownerDid,
                nonce: inputs.nonce
            )
        default:
            throw ValidationError("no builder for \(vector.name)")
        }
    }

    // MARK: - Known answers

    func testTheFixtureHoldsTheKnownVectors() throws {
        let fixture = try Self.loadFixture()
        XCTAssertEqual(fixture.vectors.count, 7)
        // A new vector has to be placed in one list or the other.
        XCTAssertEqual(Set(fixture.vectors.map { $0.name }), Set(Self.sendable + Self.notSent))
        XCTAssertEqual(fixture.privateKeySeedHex, String(repeating: "03", count: 32))
        XCTAssertEqual(fixture.publicKeyId, "did:willow:a#key-1")
    }

    func testKeysFromTheSeedAreTheFixtureKeys() throws {
        let fixture = try Self.loadFixture()
        XCTAssertEqual(try Self.keyPair(.ed25519).publicKeyHex, fixture.ed25519PublicKeyHex)
        XCTAssertEqual(try Self.keyPair(.secp256k1).publicKeyHex, fixture.secp256k1PublicKeyCompressedHex)
    }

    func testMessagesAreTheKnownAnswersByteForByte() throws {
        for vector in try Self.sendableVectors() {
            let message = try Self.message(for: vector)
            XCTAssertEqual(Array(message.utf8), Array(vector.message.utf8), vector.name)
            XCTAssertFalse(message.utf8.last == 0x0A, "\(vector.name): no trailing newline")
        }
    }

    func testSecp256k1SignaturesAreTheKnownAnswers() throws {
        let keyPair = try Self.keyPair(.secp256k1)
        for vector in try Self.sendableVectors() {
            let message = Data(try Self.message(for: vector).utf8)
            XCTAssertEqual(keccak256(message).hexString, vector.secp256k1Keccak256Hex, vector.name)
            XCTAssertEqual(try keyPair.sign(message).hexString, vector.secp256k1CompactSignatureHex, vector.name)
            XCTAssertTrue(try verify(
                algorithm: .secp256k1, publicKey: keyPair.publicKey,
                message: message, signature: Self.hex(vector.secp256k1CompactSignatureHex)
            ), vector.name)
        }
    }

    /// CryptoKit's Ed25519 signing is randomized (each call gives a different,
    /// equally valid signature), so the SDK cannot reproduce the RFC 8032
    /// signature byte for byte. What is checked instead: the known signature
    /// verifies over the builder's message under the key from the seed, and
    /// the SDK's own signature does too.
    func testEd25519SignaturesOverTheKnownAnswers() throws {
        let keyPair = try Self.keyPair(.ed25519)
        for vector in try Self.sendableVectors() {
            let message = Data(try Self.message(for: vector).utf8)
            XCTAssertTrue(try verify(
                algorithm: .ed25519, publicKey: keyPair.publicKey,
                message: message, signature: Self.hex(vector.ed25519SignatureHex)
            ), vector.name)
            let signature = try keyPair.sign(message)
            XCTAssertEqual(signature.count, 64)
            XCTAssertTrue(try verify(algorithm: .ed25519, publicKey: keyPair.publicKey, message: message, signature: signature), vector.name)
        }
    }

    func testTheKnownSignaturesDoNotCoverAnotherNonce() throws {
        let keyPair = try Self.keyPair(.ed25519)
        for vector in try Self.sendableVectors() {
            let lines = vector.message.split(separator: "\n", omittingEmptySubsequences: false)
            let otherNonce = (lines.dropLast() + ["Nonce: \(vector.inputs.nonce + 1)"]).joined(separator: "\n")
            XCTAssertFalse(try verify(
                algorithm: .ed25519, publicKey: keyPair.publicKey,
                message: Data(otherNonce.utf8), signature: Self.hex(vector.ed25519SignatureHex)
            ), vector.name)
        }
    }

    // MARK: - Field rules

    static let builders: [(String, (String) throws -> String)] = {
        let hash = Data(repeating: 0x11, count: 32)
        func manifest(_ s: String = "s", _ k: String = "k", _ o: String = "o", _ f: String = "f", _ c: String = "c") throws -> String {
            return try storeFileManifestMessage(
                subgroveId: s, fileKey: k, ownerDid: o, filename: f, contentType: c, totalSize: 1,
                contentHash: hash, chunkCount: 1, chunkSize: 1, chunkMerkleRoot: hash, nonce: 1
            )
        }
        return [
            ("StoreData subgrove", { try storeDataMessage(subgroveId: $0, key: "k", ownerDid: "o", data: Data(), nonce: 1) }),
            ("StoreData key", { try storeDataMessage(subgroveId: "s", key: $0, ownerDid: "o", data: Data(), nonce: 1) }),
            ("StoreData owner", { try storeDataMessage(subgroveId: "s", key: "k", ownerDid: $0, data: Data(), nonce: 1) }),
            ("StoreFileManifest subgrove", { try manifest($0) }),
            ("StoreFileManifest key", { try manifest("s", $0) }),
            ("StoreFileManifest owner", { try manifest("s", "k", $0) }),
            ("StoreFileManifest filename", { try manifest("s", "k", "o", $0) }),
            ("StoreFileManifest content type", { try manifest("s", "k", "o", "f", $0) }),
            ("DeleteFileManifest subgrove", { try deleteFileManifestMessage(subgroveId: $0, fileKey: "k", ownerDid: "o", nonce: 1) }),
            ("DeleteFileManifest key", { try deleteFileManifestMessage(subgroveId: "s", fileKey: $0, ownerDid: "o", nonce: 1) }),
            ("DeleteFileManifest owner", { try deleteFileManifestMessage(subgroveId: "s", fileKey: "k", ownerDid: $0, nonce: 1) }),
        ]
    }()

    func testALineBreakInATextFieldIsRefused() throws {
        // Swift reads "\r\n" as one Character, so a Character search misses it.
        XCTAssertFalse("a\r\nb".contains(Character("\n")))

        for (name, build) in Self.builders {
            XCTAssertNoThrow(try build("a"), name)
            for value in ["a\nb", "a\r\nb", "\n", "a\n", "\nb"] {
                XCTAssertThrowsError(try build(value), "\(name): \(value.debugDescription)") { error in
                    XCTAssertEqual((error as? WillowError)?.type, .validation, name)
                }
            }
        }
    }

    func testOtherTextGoesInVerbatim() throws {
        // Only the byte 0x0A is a line break: a lone CR, U+0085, or U+2028 is text.
        for (name, build) in Self.builders {
            let lineCount = try build("a").utf8.filter { $0 == 0x0A }.count
            for value in ["a\rb", "a\u{85}b", "a\u{2028}b", "naïve-ключ", "a: b", ""] {
                let message = try build(value)
                XCTAssertEqual(message.utf8.filter { $0 == 0x0A }.count, lineCount, "\(name): \(value.debugDescription)")
                if !value.isEmpty {
                    XCTAssertNotNil(Data(message.utf8).range(of: Data(value.utf8)), "\(name): \(value.debugDescription)")
                }
            }
        }
    }

    func testNumbersAreUnsignedDecimal() throws {
        XCTAssertTrue(try deleteFileManifestMessage(subgroveId: "s", fileKey: "k", ownerDid: "o", nonce: 0).hasSuffix("\nNonce: 0"))
        XCTAssertTrue(try deleteFileManifestMessage(subgroveId: "s", fileKey: "k", ownerDid: "o", nonce: UInt64.max)
            .hasSuffix("\nNonce: 18446744073709551615"))
        let hash = Data(repeating: 0, count: 32)
        let message = try storeFileManifestMessage(
            subgroveId: "s", fileKey: "k", ownerDid: "o", filename: "f", contentType: "c", totalSize: UInt64.max,
            contentHash: hash, chunkCount: UInt32.max, chunkSize: 0, chunkMerkleRoot: hash, nonce: 1
        )
        XCTAssertTrue(message.contains("\nTotalSize: 18446744073709551615\n"))
        XCTAssertTrue(message.contains("\nChunkCount: 4294967295\n"))
        XCTAssertTrue(message.contains("\nChunkSize: 0\n"))
    }

    func testHashLengthsAreChecked() {
        let hash = Data(repeating: 0, count: 32)
        func build(contentHash: Data = hash, root: Data = hash, encryption: FileEncryption? = nil) throws -> String {
            return try storeFileManifestMessage(
                subgroveId: "s", fileKey: "k", ownerDid: "o", filename: "f", contentType: "c", totalSize: 1,
                contentHash: contentHash, chunkCount: 1, chunkSize: 1, chunkMerkleRoot: root, encryption: encryption, nonce: 1
            )
        }
        XCTAssertThrowsError(try build(contentHash: Data(count: 31)))
        XCTAssertThrowsError(try build(root: Data(count: 33)))
        XCTAssertThrowsError(try build(encryption: FileEncryption(keyEpoch: 1, nonce: Data(count: 23))))
        XCTAssertTrue(try build(encryption: FileEncryption(keyEpoch: 0, nonce: Data(count: 24)))
            .contains("\nEncryption: 0:" + String(repeating: "00", count: 24) + "\n"))
    }

    // MARK: - Transactions sent

    /// The chain's transactions as serde reads them from JSON: byte fields are
    /// arrays of numbers 0...255, and the nonce and sizes are unsigned.
    struct ChainStoreDataTx: Decodable {
        let subgroveId: String
        let key: String
        let data: [UInt8]
        let ownerDid: String
        let signature: [UInt8]
        let publicKeyId: String
        let nonce: UInt64
    }

    struct ChainStoreFileManifestTx: Decodable {
        let subgroveId: String
        let fileKey: String
        let filename: String
        let contentType: String
        let totalSize: UInt64
        let contentHash: [UInt8]
        let chunkCount: UInt32
        let chunkSize: UInt32
        let chunkMerkleRoot: [UInt8]
        let ownerDid: String
        let signature: [UInt8]
        let publicKeyId: String
        let nonce: UInt64
    }

    struct ChainDeleteFileManifestTx: Decodable {
        let subgroveId: String
        let fileKey: String
        let ownerDid: String
        let signature: [UInt8]
        let publicKeyId: String
        let nonce: UInt64
    }

    /// The one transaction in a `/tx/submit` body, under its variant name.
    static func submitted<T: Decodable>(_ type: T.Type, variant: String, from request: ReceivedRequest) throws -> T {
        XCTAssertEqual("\(request.method) \(request.target)", "POST /tx/submit")
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(Array(envelope.keys), [variant])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try XCTUnwrap(decoder.decode([String: T].self, from: request.body)[variant])
    }

    /// A stub API and CometBFT RPC that report `nonce - 1` as the account's
    /// base, with no nonce above it used, so the consensus client's next nonce
    /// is `nonce`, and accept every transaction.
    static func consensusStub(nextNonce nonce: UInt64) -> (StubServer, ConsensusClient) {
        let stub = StubServer { request in
            if request.url.host == "rpc.test" {
                return (200, NonceTests.nonceStateAnswer(base: nonce - 1))
            }
            if request.path.hasSuffix("/nonce") {
                return (200, #"{"success":true,"data":{"nonce":\#(nonce - 1)}}"#)
            }
            return (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""}}"#)
        }
        let consensus = ConsensusClient(
            ConsensusConfig(consensusRpcUrl: "http://rpc.test", apiUrl: "http://api.test"),
            session: stub.session
        )
        return (stub, consensus)
    }

    func testConsensusStoreDataIsSignedOverTheTransactionSent() async throws {
        let fixture = try Self.loadFixture()
        for name in ["StoreData", "StoreData (non-ASCII, large nonce)"] {
            let vector = try Self.vector(name, in: fixture)
            let inputs = vector.inputs
            let dataText = try XCTUnwrap(inputs.dataUtf8)
            for algorithm in [SignatureAlgorithm.ed25519, .secp256k1] {
                let keyPair = try Self.keyPair(algorithm)
                let (stub, consensus) = Self.consensusStub(nextNonce: inputs.nonce)

                let result = try await consensus.storeData(
                    subgroveId: inputs.subgroveId,
                    key: try XCTUnwrap(inputs.key),
                    data: try JSONSerialization.jsonObject(with: Data(dataText.utf8)),
                    ownerDid: inputs.ownerDid,
                    privateKey: keyPair.privateKey,
                    publicKeyId: fixture.publicKeyId,
                    signFunction: { message, _ in try keyPair.sign(message) }
                )
                XCTAssertTrue(result.success)

                let tx = try Self.submitted(ChainStoreDataTx.self, variant: "StoreData", from: try XCTUnwrap(stub.requests.last))
                XCTAssertEqual(tx.nonce, inputs.nonce)
                XCTAssertEqual(tx.publicKeyId, fixture.publicKeyId)
                let message = try storeDataMessage(
                    subgroveId: tx.subgroveId, key: tx.key, ownerDid: tx.ownerDid, data: Data(tx.data), nonce: tx.nonce
                )
                XCTAssertTrue(try verify(
                    algorithm: algorithm, publicKey: keyPair.publicKey,
                    message: Data(message.utf8), signature: Data(tx.signature)
                ), "\(name), \(algorithm)")

                // The value is written with sorted keys and non-ASCII text as
                // UTF-8, so the bytes sent are the vector's and this is its known answer.
                XCTAssertEqual(Data(tx.data), Data(dataText.utf8), name)
                XCTAssertEqual(Array(message.utf8), Array(vector.message.utf8), name)
                if algorithm == .secp256k1 {
                    XCTAssertEqual(Data(tx.signature).hexString, vector.secp256k1CompactSignatureHex, name)
                }
            }
        }
    }

    func testConsensusStoreDataRefusesALineBreakBeforeSigning() async throws {
        let (stub, consensus) = Self.consensusStub(nextNonce: 1)
        var signed = false
        do {
            _ = try await consensus.storeData(
                subgroveId: "sg", key: "a\r\nb", data: ["a": 1], ownerDid: "did:willow:a",
                privateKey: Data(), publicKeyId: "did:willow:a#key-1",
                signFunction: { _, _ in signed = true; return Data() }
            )
            XCTFail("a key holding a line break must be refused")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
        XCTAssertFalse(signed)
        XCTAssertFalse(stub.requests.contains { $0.path == "/tx/submit" })
    }

    func testConsensusStoreDataRefusesAValueThatIsNotJSON() async throws {
        let (stub, consensus) = Self.consensusStub(nextNonce: 1)
        do {
            _ = try await consensus.storeData(
                subgroveId: "sg", key: "k", data: "not an object", ownerDid: "did:willow:a",
                privateKey: Data(), publicKeyId: "did:willow:a#key-1",
                signFunction: { _, _ in Data() }
            )
            XCTFail("a top-level string must be refused")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testConsensusStoreFileManifestIsSignedOverTheTransactionSent() async throws {
        let fixture = try Self.loadFixture()
        let vector = try Self.vector("StoreFileManifest", in: fixture)
        let inputs = vector.inputs
        for algorithm in [SignatureAlgorithm.ed25519, .secp256k1] {
            let keyPair = try Self.keyPair(algorithm)
            let (stub, consensus) = Self.consensusStub(nextNonce: inputs.nonce)

            let result = try await consensus.storeFileManifest(
                subgroveId: inputs.subgroveId,
                fileKey: try XCTUnwrap(inputs.fileKey),
                filename: try XCTUnwrap(inputs.filename),
                contentType: try XCTUnwrap(inputs.contentType),
                totalSize: Int(try XCTUnwrap(inputs.totalSize)),
                contentHash: try XCTUnwrap(inputs.contentHashHex),
                chunkCount: Int(try XCTUnwrap(inputs.chunkCount)),
                chunkSize: Int(try XCTUnwrap(inputs.chunkSize)),
                chunkMerkleRoot: try XCTUnwrap(inputs.chunkMerkleRootHex),
                ownerDid: inputs.ownerDid,
                privateKey: keyPair.privateKey,
                publicKeyId: fixture.publicKeyId,
                signFunction: { message, _ in try keyPair.sign(message) }
            )
            XCTAssertTrue(result.success)

            let tx = try Self.submitted(ChainStoreFileManifestTx.self, variant: "StoreFileManifest", from: try XCTUnwrap(stub.requests.last))
            let message = try Self.message(for: tx)
            XCTAssertTrue(try verify(
                algorithm: algorithm, publicKey: keyPair.publicKey,
                message: Data(message.utf8), signature: Data(tx.signature)
            ), "\(algorithm)")
            XCTAssertEqual(Array(message.utf8), Array(vector.message.utf8))
            if algorithm == .secp256k1 {
                XCTAssertEqual(Data(tx.signature).hexString, vector.secp256k1CompactSignatureHex)
            }
        }
    }

    func testConsensusDeleteFileManifestIsSignedOverTheTransactionSent() async throws {
        let fixture = try Self.loadFixture()
        let vector = try Self.vector("DeleteFileManifest", in: fixture)
        let inputs = vector.inputs
        for algorithm in [SignatureAlgorithm.ed25519, .secp256k1] {
            let keyPair = try Self.keyPair(algorithm)
            let (stub, consensus) = Self.consensusStub(nextNonce: inputs.nonce)

            let result = try await consensus.deleteFileManifest(
                subgroveId: inputs.subgroveId,
                fileKey: try XCTUnwrap(inputs.fileKey),
                ownerDid: inputs.ownerDid,
                privateKey: keyPair.privateKey,
                publicKeyId: fixture.publicKeyId,
                signFunction: { message, _ in try keyPair.sign(message) }
            )
            XCTAssertTrue(result.success)

            let tx = try Self.submitted(ChainDeleteFileManifestTx.self, variant: "DeleteFileManifest", from: try XCTUnwrap(stub.requests.last))
            let message = try deleteFileManifestMessage(subgroveId: tx.subgroveId, fileKey: tx.fileKey, ownerDid: tx.ownerDid, nonce: tx.nonce)
            XCTAssertTrue(try verify(
                algorithm: algorithm, publicKey: keyPair.publicKey,
                message: Data(message.utf8), signature: Data(tx.signature)
            ), "\(algorithm)")
            XCTAssertEqual(Array(message.utf8), Array(vector.message.utf8))
            if algorithm == .secp256k1 {
                XCTAssertEqual(Data(tx.signature).hexString, vector.secp256k1CompactSignatureHex)
            }
        }
    }

    func testConsensusStoreFileManifestRefusesALineBreakBeforeSigning() async throws {
        let (stub, consensus) = Self.consensusStub(nextNonce: 1)
        let hash = String(repeating: "ab", count: 32)
        var signed = false
        do {
            _ = try await consensus.storeFileManifest(
                subgroveId: "sg", fileKey: "f", filename: "a.txt", contentType: "text/plain\n", totalSize: 5,
                contentHash: hash, chunkCount: 1, chunkSize: 5, chunkMerkleRoot: hash,
                ownerDid: "did:willow:a", privateKey: Data(), publicKeyId: "did:willow:a#key-1",
                signFunction: { _, _ in signed = true; return Data() }
            )
            XCTFail("a content type holding a line break must be refused")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
        XCTAssertFalse(signed)
        XCTAssertFalse(stub.requests.contains { $0.path == "/tx/submit" })
    }

    static func message(for tx: ChainStoreFileManifestTx) throws -> String {
        return try storeFileManifestMessage(
            subgroveId: tx.subgroveId, fileKey: tx.fileKey, ownerDid: tx.ownerDid,
            filename: tx.filename, contentType: tx.contentType, totalSize: tx.totalSize,
            contentHash: Data(tx.contentHash), chunkCount: tx.chunkCount, chunkSize: tx.chunkSize,
            chunkMerkleRoot: Data(tx.chunkMerkleRoot), nonce: tx.nonce
        )
    }

    static func fileSigning(_ keyPair: KeyPair, nonce: Int) -> FileSigningOptions {
        return FileSigningOptions(
            ownerDid: "did:willow:a", privateKey: keyPair.privateKey, publicKeyId: "did:willow:a#key-1",
            signFunction: { message, _ in try keyPair.sign(message) }, nonce: nonce
        )
    }

    func testFileUploadIsSignedOverTheManifestSent() async throws {
        for algorithm in [SignatureAlgorithm.ed25519, .secp256k1] {
            let keyPair = try Self.keyPair(algorithm)
            let stub = StubServer { _ in (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""}}"#) }
            let client = try stub.client(baseURL: "http://api.test")
            // Two chunks of 256 KiB and a remainder.
            let data = Data((0..<(2 * 262_144 + 5)).map { UInt8(truncatingIfNeeded: $0) })

            // The manifest is submitted first; the chunk upload to a closed port then fails.
            do {
                _ = try await client.files.upload(
                    subgroveId: "files-1", fileKey: "photo.png", filename: "photo.png", data: data,
                    storageNodeEndpoint: "http://127.0.0.1:1", signing: Self.fileSigning(keyPair, nonce: 9)
                )
            } catch {}

            let tx = try Self.submitted(ChainStoreFileManifestTx.self, variant: "StoreFileManifest", from: try XCTUnwrap(stub.requests.first))
            XCTAssertEqual(tx.contentType, "image/png")
            XCTAssertEqual(tx.totalSize, UInt64(data.count))
            XCTAssertEqual(tx.chunkCount, 3)
            XCTAssertEqual(tx.chunkSize, 262_144)
            XCTAssertEqual(tx.nonce, 9)
            let message = try Self.message(for: tx)
            XCTAssertTrue(message.hasPrefix("StoreFileManifest\nSubgrove: files-1\nKey: photo.png\nOwner: did:willow:a\n"
                + "Filename: photo.png\nContentType: image/png\nTotalSize: 524293\n"))
            XCTAssertTrue(message.hasSuffix("\nChunkCount: 3\nChunkSize: 262144\nChunkMerkleRoot: \(Data(tx.chunkMerkleRoot).hexString)\n"
                + "Encryption: none\nNonce: 9"))
            XCTAssertTrue(try verify(
                algorithm: algorithm, publicKey: keyPair.publicKey,
                message: Data(message.utf8), signature: Data(tx.signature)
            ), "\(algorithm)")
        }
    }

    func testFileDeleteIsSignedOverTheTransactionSent() async throws {
        let fixture = try Self.loadFixture()
        let vector = try Self.vector("DeleteFileManifest", in: fixture)
        for algorithm in [SignatureAlgorithm.ed25519, .secp256k1] {
            let keyPair = try Self.keyPair(algorithm)
            let stub = StubServer { _ in (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""}}"#) }
            let client = try stub.client(baseURL: "http://api.test")

            try await client.files.delete(
                subgroveId: "files-1", fileKey: "photo.png",
                signing: Self.fileSigning(keyPair, nonce: Int(vector.inputs.nonce))
            )

            let tx = try Self.submitted(ChainDeleteFileManifestTx.self, variant: "DeleteFileManifest", from: try XCTUnwrap(stub.requests.first))
            let message = try deleteFileManifestMessage(subgroveId: tx.subgroveId, fileKey: tx.fileKey, ownerDid: tx.ownerDid, nonce: tx.nonce)
            XCTAssertEqual(Array(message.utf8), Array(vector.message.utf8))
            XCTAssertTrue(try verify(
                algorithm: algorithm, publicKey: keyPair.publicKey,
                message: Data(message.utf8), signature: Data(tx.signature)
            ), "\(algorithm)")
        }
    }

    func testFileWritesRefuseALineBreakOrNegativeNonceBeforeSigning() async throws {
        let stub = StubServer { _ in (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""}}"#) }
        let client = try stub.client(baseURL: "http://api.test")
        var signed = false
        let signing = FileSigningOptions(
            ownerDid: "did:willow:a", privateKey: Data(), publicKeyId: "did:willow:a#key-1",
            signFunction: { _, _ in signed = true; return Data() }, nonce: 1
        )
        let negative = FileSigningOptions(
            ownerDid: "did:willow:a", privateKey: Data(), publicKeyId: "did:willow:a#key-1",
            signFunction: { _, _ in signed = true; return Data() }, nonce: -1
        )

        let attempts: [(String, () async throws -> Void)] = [
            ("upload filename", {
                _ = try await client.files.upload(
                    subgroveId: "sg", fileKey: "f", filename: "a\n.png", data: Data("x".utf8),
                    storageNodeEndpoint: "http://127.0.0.1:1", signing: signing
                )
            }),
            ("upload key", {
                _ = try await client.files.upload(
                    subgroveId: "sg", fileKey: "f\r\n", filename: "a.png", data: Data("x".utf8),
                    storageNodeEndpoint: "http://127.0.0.1:1", signing: signing
                )
            }),
            ("upload nonce", {
                _ = try await client.files.upload(
                    subgroveId: "sg", fileKey: "f", filename: "a.png", data: Data("x".utf8),
                    storageNodeEndpoint: "http://127.0.0.1:1", signing: negative
                )
            }),
            ("delete key", { try await client.files.delete(subgroveId: "sg", fileKey: "a\nb", signing: signing) }),
            ("delete nonce", { try await client.files.delete(subgroveId: "sg", fileKey: "f", signing: negative) }),
        ]
        for (name, attempt) in attempts {
            do {
                try await attempt()
                XCTFail("\(name) must be refused")
            } catch let error as WillowError {
                XCTAssertEqual(error.type, .validation, name)
            }
        }
        XCTAssertFalse(signed)
        XCTAssertTrue(stub.requests.isEmpty)
    }
}
