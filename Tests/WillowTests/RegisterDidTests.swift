import XCTest
import CryptoKit
@testable import Willow

/// RegisterDid known answers.
///
/// The node verifies a RegisterDid over `serde_json::to_vec` of the
/// transaction's `DidDocument`: its fields in declaration order (`id`,
/// `public_keys`, `authentication`, `service`, `created`, `updated`, `proof`;
/// a key's `id`, `type`, `controller`, `public_key_base58`, `public_key_hex`;
/// a service's `id`, `type`, `service_endpoint`; a proof's `type`, `created`,
/// `verification_method`, `proof_purpose`, `jws`), none as `null`, no
/// whitespace. serde_json escapes `"` and `\`, writes backspace, form feed,
/// line feed, carriage return, and tab as `\b \f \n \r \t`, every other byte
/// below 0x20 as `\u00xx` with lowercase hex, and nothing else: DEL, `/`,
/// non-ASCII text, and U+2028 go in as their UTF-8. Messages are compared as
/// bytes: Swift compares `String`s up to Unicode canonical equivalence.
///
/// The messages below are written out by hand from those rules (the same
/// known answers the other SDKs test against); the signatures were made over
/// them with an independent Ed25519 and secp256k1 (RFC 6979, lower-S)
/// implementation, seed `03` x 32.
final class RegisterDidTests: XCTestCase {

    static let seed = String(repeating: "03", count: 32)
    static let edDID = "did:willow:zF5GZ1jk3Sqbqh6Q6hG4HrQa3ZMhs794Hbhv7yytr1Y9d"
    static let edPublicKey = "ed4928c628d1c2c6eae90338905995612959273a5c63f93636c14614ac8737d1"
    static let k1DID = "did:willow:z5AzUUsCPyDPxpAWq23RAgvXpvqqx2C4Y824gEss4HyvL"
    static let k1PublicKey = "02531fe6068134503d2723133227c867ac8fa6c83c537e9a44c3c5bdbdcb1fe337"

    static var edDocument: [String: Any] {
        return [
            "id": edDID,
            "public_keys": [[
                "id": "\(edDID)#key-1",
                "type": "Ed25519VerificationKey2018",
                "controller": edDID,
                "public_key_base58": NSNull(),
                "public_key_hex": edPublicKey,
            ]],
            "authentication": ["\(edDID)#key-1"],
            "service": [[
                "id": "\(edDID)#profile",
                "type": "Profile \"main\"",
                "service_endpoint": "https://example.com/a\\b\tc\u{01}\u{1F}\u{7F} é\u{1F33F}\u{2028}",
            ]],
            "created": 1_700_000_000,
            "updated": 4_294_967_297,
            "proof": [
                "type": "Ed25519Signature2018",
                "created": 1_700_000_001,
                "verification_method": "\(edDID)#key-1",
                "proof_purpose": "assertionMethod",
                "jws": "a.b.c",
            ],
        ]
    }

    static let edMessage =
        #"{"id":"\#(edDID)","#
        + #""public_keys":[{"id":"\#(edDID)#key-1","type":"Ed25519VerificationKey2018","#
        + #""controller":"\#(edDID)","public_key_base58":null,"public_key_hex":"\#(edPublicKey)"}],"#
        + #""authentication":["\#(edDID)#key-1"],"#
        + #""service":[{"id":"\#(edDID)#profile","type":"Profile \"main\"","#
        + #""service_endpoint":"https://example.com/a\\b\tc\u0001\u001f"# + "\u{7F} é\u{1F33F}\u{2028}" + #""}],"#
        + #""created":1700000000,"updated":4294967297,"#
        + #""proof":{"type":"Ed25519Signature2018","created":1700000001,"#
        + #""verification_method":"\#(edDID)#key-1","proof_purpose":"assertionMethod","jws":"a.b.c"}}"#
    static let edMessageSHA256 = "d5e8588d155adb6dc693d86657212c2ec9b9dfab82ebff11d5421692f0bcda0e"
    static let edSignature =
        "887e46d4b9afd7e954fa4e630834df2a586b49c565a4054c4a91428f3376acc4"
        + "f8b7279c34913ac360106eb02dba3503766a13262a87069bf6b89f70bf25ac0f"

    /// `service` and `proof` left out: the SDK sends `[]` and `null`, as the
    /// node serializes them.
    static var k1Document: [String: Any] {
        return [
            "id": k1DID,
            "public_keys": [[
                "id": "\(k1DID)#key-1",
                "type": "EcdsaSecp256k1VerificationKey2019",
                "controller": k1DID,
                "public_key_hex": k1PublicKey,
            ]],
            "authentication": ["\(k1DID)#key-1"],
            "created": 0,
            "updated": 0,
        ]
    }

    static let k1Message =
        #"{"id":"\#(k1DID)","#
        + #""public_keys":[{"id":"\#(k1DID)#key-1","type":"EcdsaSecp256k1VerificationKey2019","#
        + #""controller":"\#(k1DID)","public_key_base58":null,"public_key_hex":"\#(k1PublicKey)"}],"#
        + #""authentication":["\#(k1DID)#key-1"],"#
        + #""service":[],"created":0,"updated":0,"proof":null}"#
    static let k1Keccak256 = "37ba9e634af66aa88838b106b0b9fa744dda06effb9b6253d0763d2571dc2453"
    static let k1Signature =
        "1cb18d5113042faa3f35edd89452b1eb573c7cfc381a09b71060cda460283723"
        + "510a4e400b5ea62a6287ae6566e65dd2202c5491d3603f0de7a559c6f163aed8"

    func testTheEd25519DocumentIsTheKnownMessage() throws {
        let message = try registerDidMessage(Self.edDocument)
        XCTAssertEqual(Array(message.utf8), Array(Self.edMessage.utf8))
        XCTAssertEqual(Data(SHA256.hash(data: Data(message.utf8))).hexString, Self.edMessageSHA256)
    }

    /// CryptoKit's Ed25519 signing is randomized, so the known signature is
    /// checked to verify over the message, as is the SDK's own.
    func testTheEd25519SignatureVerifiesOverTheKnownMessage() throws {
        let keyPair = try keyPairFromPrivateKey(algorithm: .ed25519, privateKeyHex: Self.seed)
        XCTAssertEqual(keyPair.publicKeyHex, Self.edPublicKey)
        XCTAssertEqual(deriveWillowDID(algorithm: .ed25519, publicKey: keyPair.publicKey), Self.edDID)
        let message = Data(try registerDidMessage(Self.edDocument).utf8)
        XCTAssertTrue(try verify(
            algorithm: .ed25519, publicKey: keyPair.publicKey, message: message,
            signature: try XCTUnwrap(Data(hexString: Self.edSignature))))
        XCTAssertTrue(try verify(algorithm: .ed25519, publicKey: keyPair.publicKey, message: message, signature: try keyPair.sign(message)))
    }

    func testTheSecp256k1DocumentAndSignatureAreTheKnownAnswers() throws {
        let message = try registerDidMessage(Self.k1Document)
        XCTAssertEqual(Array(message.utf8), Array(Self.k1Message.utf8))
        XCTAssertEqual(keccak256(Data(message.utf8)).hexString, Self.k1Keccak256)
        let keyPair = try keyPairFromPrivateKey(algorithm: .secp256k1, privateKeyHex: Self.seed)
        XCTAssertEqual(keyPair.publicKeyHex, Self.k1PublicKey)
        XCTAssertEqual(deriveWillowDID(algorithm: .secp256k1, publicKey: keyPair.publicKey), Self.k1DID)
        XCTAssertEqual(try keyPair.sign(Data(message.utf8)).hexString, Self.k1Signature)
    }

    /// Fields the node doesn't read are dropped, the aliases the node's other
    /// forms use are read, and a document the node can't read is refused.
    func testTheDocumentIsTheNodesForm() throws {
        var document = Self.k1Document
        document["extra"] = ["ignored": true]
        document["public_keys"] = [[
            "id": "\(Self.k1DID)#key-1",
            "key_type": "EcdsaSecp256k1VerificationKey2019",
            "controller": Self.k1DID,
            "public_key_hex": Self.k1PublicKey,
            "note": "dropped",
        ]]
        document["service"] = NSNull()
        document["proof"] = NSNull()
        XCTAssertEqual(Array(try registerDidMessage(document).utf8), Array(Self.k1Message.utf8))

        for (key, value) in [("created", 1.5 as Any), ("updated", -1 as Any), ("created", "0" as Any), ("authentication", "k" as Any)] {
            var refused = Self.k1Document
            refused[key] = value
            XCTAssertThrowsError(try registerDidMessage(refused), key) { error in
                XCTAssertEqual((error as? WillowError)?.type, .validation, "\(key): \(error)")
            }
        }
        var noController = Self.k1Document
        noController["public_keys"] = [["id": "\(Self.k1DID)#key-1", "type": "EcdsaSecp256k1VerificationKey2019"]]
        XCTAssertThrowsError(try registerDidMessage(noController))
    }

    /// `ConsensusClient.registerDid` signs the document as the node
    /// serializes the one it sends, and sends it under nonce 1.
    func testRegisterDidSignsWhatTheNodeSerializes() async throws {
        let keyPair = try keyPairFromPrivateKey(algorithm: .ed25519, privateKeyHex: Self.seed)
        let stub = StubServer { request in
            if request.path.hasSuffix("/nonce") {
                return (200, #"{"success":true,"data":{"did":"d","nonce":0},"error":null}"#)
            }
            if request.path == "/tx/submit" {
                return (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""},"error":null}"#)
            }
            return (404, "")
        }
        let consensus = ConsensusClient(ConsensusConfig(consensusRpcUrl: "http://rpc.test", apiUrl: "http://api.test"), session: stub.session)
        let result = try await consensus.registerDid(
            didDocument: Self.edDocument, privateKey: keyPair.privateKey, publicKeyId: "\(Self.edDID)#key-1"
        ) { message, privateKey in
            try keyPairFromPrivateKey(algorithm: .ed25519, privateKeyHex: privateKey.hexString).sign(message)
        }
        XCTAssertTrue(result.success)

        let sent = try XCTUnwrap(stub.requests.first { $0.path == "/tx/submit" })
        let tx = try WireJSONObject(try WireJSONObject(try WireJSON.parse(sent.body), "body").required("RegisterDid"), "RegisterDid")
        // What the node signs: its serialization of the document it decodes.
        let document = try tx.required("did_document")
        XCTAssertEqual(document.serialized, Data(Self.edMessage.utf8))
        XCTAssertEqual(try tx.required("nonce").unsigned("nonce", as: UInt64.self), 1)
        XCTAssertEqual(try tx.required("public_key_id").string("public_key_id"), "\(Self.edDID)#key-1")
        XCTAssertTrue(try verify(
            algorithm: .ed25519, publicKey: keyPair.publicKey, message: Data(Self.edMessage.utf8),
            signature: Data(try tx.required("signature").bytes("signature"))))
    }
}
