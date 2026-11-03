import XCTest
import CryptoKit
@testable import Willow

/// Request signing against the API server's rules (crates/api-server/src/middleware.rs
/// and crates/identity/src/did.rs), with known answers from an independent
/// implementation of the server's verification.
final class RequestSigningTests: XCTestCase {

    // The api-server's test vector (read_auth_tests.rs, the_signed_message_is_eight_lines).
    static let vectorMessage = "willow-request-v2\ndid:willow:a\ndid:willow:a#key-1\nPOST\n/query/sg?x=1\n1700000000\n"
        + "abcdefghijklmnop\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"

    // Keys from the seed 32 bytes of 0x03, and signatures over vectorMessage.
    static let seedHex = String(repeating: "03", count: 32)
    static let ed25519PublicKeyHex = "ed4928c628d1c2c6eae90338905995612959273a5c63f93636c14614ac8737d1"
    static let ed25519SignatureHex = "c117313c0d01641340e398d9a7a9ff024a1c6672bca16bbcb99e6fe2738f82e7"
        + "7870bd2c30dc62d6c50cea32a3b21086730d9c25297831dd83bc797c5b394d0d"
    static let secp256k1PublicKeyHex = "02531fe6068134503d2723133227c867ac8fa6c83c537e9a44c3c5bdbdcb1fe337"
    static let secp256k1KeccakHex = "d88e0d6795532372abf6cc33c33a8903b5b0fb108c1dc0b0ccc63fe061bd9e93"
    static let secp256k1CompactHex = "bfbad8ec000c66ed30349070db245db0c45249293c545e35dc997d6427d32238"
        + "30787244d5b3bb7e8a1b39bdba0c62261e02344a515f5e8e89f678e17d4b976d"
    static let secp256k1DERHex = "3045022100bfbad8ec000c66ed30349070db245db0c45249293c545e35dc997d6427d32238"
        + "022030787244d5b3bb7e8a1b39bdba0c62261e02344a515f5e8e89f678e17d4b976d"

    static func vectorIdentity(_ algorithm: SignatureAlgorithm) throws -> Identity {
        let keyPair = try keyPairFromPrivateKey(algorithm: algorithm, privateKeyHex: seedHex)
        let document = DidDocument(
            id: "did:willow:a",
            publicKeys: [PublicKey(id: "did:willow:a#key-1", type: algorithm.keyType, publicKeyHex: keyPair.publicKeyHex)],
            created: 0,
            updated: 0
        )
        return Identity(keyPair: keyPair, didDocument: document)
    }

    static func hex(_ string: String) -> Data {
        return Data(hexString: string)!
    }

    // MARK: - Messages

    func testSignedRequestMessageMatchesServerVector() {
        let message = signedRequestMessage(
            did: "did:willow:a",
            publicKeyId: "did:willow:a#key-1",
            method: "POST",
            pathAndQuery: "/query/sg?x=1",
            timestamp: "1700000000",
            nonce: "abcdefghijklmnop",
            body: Data("{}".utf8)
        )
        XCTAssertEqual(message, Self.vectorMessage)
    }

    func testSignedRequestMessageHashesAnEmptyBody() {
        let message = signedRequestMessage(
            did: "d", publicKeyId: "k", method: "GET", pathAndQuery: "/data/sg/k",
            timestamp: "1", nonce: "n", body: Data()
        )
        XCTAssertTrue(message.hasSuffix("\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
        XCTAssertFalse(message.hasSuffix("\n\n"))
    }

    func testLegacyRequestMessageSignsThePathAlone() throws {
        XCTAssertEqual(
            legacyRequestMessage(method: "GET", path: "/data/sg/k?include_proof=true", timestamp: "1700000000"),
            "GET:/data/sg/k:1700000000"
        )
        XCTAssertEqual(
            legacyRequestMessage(method: "GET", path: "/data/sg/k", timestamp: "1700000000"),
            "GET:/data/sg/k:1700000000"
        )

        let identity = try Self.vectorIdentity(.ed25519)
        let headers = try signRequest(method: "GET", path: "/data/sg/k?include_proof=true", identity: identity)
        XCTAssertNil(headers["X-Nonce"], "the older form carries no nonce")
        XCTAssertEqual(Set(headers.keys), ["X-DID", "X-Public-Key-ID", "X-Signature", "X-Timestamp"])
        let message = "GET:/data/sg/k:" + headers["X-Timestamp"]!
        XCTAssertTrue(try verify(
            algorithm: .ed25519, publicKey: identity.keyPair.publicKey,
            message: Data(message.utf8), signature: Self.hex(headers["X-Signature"]!)
        ))
    }

    func testLegacySecp256k1SignatureIsPrefixedKeccakOverThePath() throws {
        let identity = try Self.vectorIdentity(.secp256k1)
        let headers = try signRequest(method: "POST", path: "/tx/submit?x=1", identity: identity)
        let signature = try XCTUnwrap(headers["X-Signature"])
        XCTAssertTrue(signature.hasPrefix("0x"), "an unprefixed secp256k1 signature is read as base64 first")
        XCTAssertEqual(signature.count, 2 + 128)
        let message = "POST:/tx/submit:" + headers["X-Timestamp"]!
        XCTAssertTrue(try verify(
            algorithm: .secp256k1, publicKey: identity.keyPair.publicKey,
            message: Data(message.utf8), signature: Self.hex(String(signature.dropFirst(2)))
        ))
    }

    // MARK: - Known answers

    /// CryptoKit's Ed25519 signing is randomized (each call gives a different,
    /// equally valid signature), so the SDK cannot reproduce the RFC 8032
    /// signature byte for byte. What is checked instead: the key from the seed
    /// is the known one, the SDK's signature over the vector verifies under it,
    /// and the SDK's verify accepts the known signature.
    func testEd25519NonceSigningOverTheVector() throws {
        let identity = try Self.vectorIdentity(.ed25519)
        XCTAssertEqual(identity.keyPair.publicKeyHex, Self.ed25519PublicKeyHex)

        let headers = try signRequestWithNonce(
            method: "POST", pathAndQuery: "/query/sg?x=1", body: Data("{}".utf8),
            identity: identity, timestamp: "1700000000", nonce: "abcdefghijklmnop"
        )
        XCTAssertEqual(Set(headers.keys), ["X-DID", "X-Public-Key-ID", "X-Signature", "X-Timestamp", "X-Nonce"])
        XCTAssertEqual(headers["X-DID"], "did:willow:a")
        XCTAssertEqual(headers["X-Public-Key-ID"], "did:willow:a#key-1")
        XCTAssertEqual(headers["X-Timestamp"], "1700000000")
        XCTAssertEqual(headers["X-Nonce"], "abcdefghijklmnop")

        let signature = try XCTUnwrap(headers["X-Signature"])
        XCTAssertNotNil(signature.range(of: "^[0-9a-f]{128}$", options: .regularExpression), "lowercase hex, 64 bytes")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Self.hex(Self.ed25519PublicKeyHex))
        XCTAssertTrue(publicKey.isValidSignature(Self.hex(signature), for: Data(Self.vectorMessage.utf8)))

        XCTAssertTrue(try verify(
            algorithm: .ed25519, publicKey: identity.keyPair.publicKey,
            message: Data(Self.vectorMessage.utf8), signature: Self.hex(Self.ed25519SignatureHex)
        ))
    }

    func testSecp256k1NonceSigningKnownAnswer() throws {
        let identity = try Self.vectorIdentity(.secp256k1)
        XCTAssertEqual(identity.keyPair.publicKeyHex, Self.secp256k1PublicKeyHex, "DID documents carry the 33-byte compressed key")
        XCTAssertEqual(keccak256(Data(Self.vectorMessage.utf8)).hexString, Self.secp256k1KeccakHex)

        let headers = try signRequestWithNonce(
            method: "POST", pathAndQuery: "/query/sg?x=1", body: Data("{}".utf8),
            identity: identity, timestamp: "1700000000", nonce: "abcdefghijklmnop"
        )
        XCTAssertEqual(headers["X-Signature"], "0x" + Self.secp256k1CompactHex)
        XCTAssertEqual(headers["X-Nonce"], "abcdefghijklmnop")

        let message = Data(Self.vectorMessage.utf8)
        let publicKey = identity.keyPair.publicKey
        XCTAssertTrue(try verify(algorithm: .secp256k1, publicKey: publicKey, message: message, signature: Self.hex(Self.secp256k1CompactHex)))
        XCTAssertTrue(try verify(algorithm: .secp256k1, publicKey: publicKey, message: message, signature: Self.hex(Self.secp256k1DERHex)))
        XCTAssertFalse(try verify(algorithm: .secp256k1, publicKey: publicKey, message: Data("other".utf8), signature: Self.hex(Self.secp256k1CompactHex)))
    }

    func testSecp256k1VerifyRefusesHigherS() throws {
        let identity = try Self.vectorIdentity(.secp256k1)
        let compact = [UInt8](Self.hex(Self.secp256k1CompactHex))
        // n - s: the same signature with the other S, which the server refuses.
        let n = [UInt8](Self.hex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"))
        var highS = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for i in stride(from: 31, through: 0, by: -1) {
            var digit = Int(n[i]) - Int(compact[32 + i]) - borrow
            borrow = digit < 0 ? 1 : 0
            if digit < 0 { digit += 256 }
            highS[i] = UInt8(digit)
        }
        let flipped = Data(compact[0..<32] + highS)
        XCTAssertFalse(try verify(
            algorithm: .secp256k1, publicKey: identity.keyPair.publicKey,
            message: Data(Self.vectorMessage.utf8), signature: flipped
        ))
    }

    func testSecp256k1VerifyAcceptsUncompressedKeys() throws {
        let uncompressed = Self.hex("04531fe6068134503d2723133227c867ac8fa6c83c537e9a44c3c5bdbdcb1fe337"
            + "9e92c265e71e481ba82a84675a47ac705a200fcd524e92d93b0e7386f26a5458")
        let message = Data(Self.vectorMessage.utf8)
        let signature = Self.hex(Self.secp256k1CompactHex)
        XCTAssertTrue(try verify(algorithm: .secp256k1, publicKey: uncompressed, message: message, signature: signature))
        // The 64-byte form, uncompressed without its 0x04 tag.
        XCTAssertTrue(try verify(algorithm: .secp256k1, publicKey: uncompressed.dropFirst(), message: message, signature: signature))
    }

    // MARK: - Nonces

    func testNewRequestNonce() throws {
        var seen = Set<String>()
        for _ in 0..<200 {
            let nonce = try newRequestNonce()
            XCTAssertNotNil(nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression), nonce)
            XCTAssertNotNil(nonce.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression), "outside the server's nonce rule")
            XCTAssertTrue(seen.insert(nonce).inserted, "nonce \(nonce) repeated")
        }
    }

    // MARK: - Client wiring

    func testClientNonceSignsReadsAsReceived() async throws {
        let identity = try Self.vectorIdentity(.ed25519)
        var queryAttempts = 0
        let stub = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/data/sg/k"), ("GET", "/data/sg/a%20b"):
                return (200, #"{"success":true,"data":{"a":1},"error":null}"#)
            case ("POST", "/query/sg"):
                queryAttempts += 1
                if queryAttempts == 1 {
                    return (502, "bad gateway")
                }
                return (200, #"{"success":true,"data":{"documents":[{"a":1}],"total":1,"offset":0,"limit":100}}"#)
            case ("POST", "/sql/sg"):
                return (200, #"{"columns":["a"],"rows":[[1]],"total":1}"#)
            case ("POST", "/graphql/sg"):
                return (200, #"{"data":null}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(identity)

        _ = try await client.data.getUnverified(subgroveId: "sg", key: "k")
        let query = try await client.data.queryUnverified(subgroveId: "sg", query: QueryRequest(limit: 5))
        XCTAssertEqual(query.results.count, 1)
        _ = try await client.indexing.sqlQuery(subgroveId: "sg", query: "SELECT a FROM items")
        _ = try await client.indexing.queryUnverified(subgroveId: "sg", request: GraphQLRequest(query: "{ x }"))
        // A path that needs encoding, and a query string.
        let _: ApiResponse<AnyCodable> = try await client.get(
            path: "/data/sg/\(pathSegment("a b"))", query: [("x", "1"), ("y", "two words & more")])

        let requests = stub.requests
        // The GET, the refused POST, its retry, SQL, GraphQL, and the encoded GET.
        XCTAssertEqual(requests.map { "\($0.method) \($0.target)" }, [
            "GET /data/sg/k",
            "POST /query/sg",
            "POST /query/sg",
            "POST /sql/sg",
            "POST /graphql/sg",
            "GET /data/sg/a%20b?x=1&y=two%20words%20%26%20more",
        ])
        for request in requests {
            try request.assertNonceSigned(by: identity)
        }
        XCTAssertEqual(Set(requests.map { $0.header("X-Nonce")! }).count, requests.count, "a retry must be signed with a new nonce")
        XCTAssertEqual(requests[1].body, requests[2].body, "the retry sends the same body")
        XCTAssertFalse(requests[1].body.isEmpty)
    }

    func testClientSignsOtherRequestsInTheOlderForm() async throws {
        let identity = try Self.vectorIdentity(.ed25519)
        let stub = StubServer { request in
            switch request.path {
            case "/state/root-hash":
                return (200, #"{"success":true,"data":{"root_hash":"ab"}}"#)
            case "/tx/submit":
                return (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""}}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(identity)

        _ = try await client.getRootHash()
        try await client.submitTransaction(Data(#"{"Transfer":{}}"#.utf8))

        XCTAssertEqual(stub.requests.count, 2)
        for request in stub.requests {
            XCTAssertNil(request.header("X-Nonce"), "\(request.target) is not a read of subgrove data")
            let message = "\(request.method):\(request.path):\(request.header("X-Timestamp")!)"
            XCTAssertTrue(try verify(
                algorithm: .ed25519, publicKey: identity.keyPair.publicKey,
                message: Data(message.utf8), signature: Self.hex(request.header("X-Signature")!)
            ), "\(request.target): the older form does not cover METHOD:PATH:TIMESTAMP")
        }
    }

    func testRequestsToAnIndexerCarryNoNonce() async throws {
        let identity = try Self.vectorIdentity(.ed25519)
        let stub = StubServer { _ in (200, #"{"columns":[],"rows":[]}"#) }
        let client = try stub.client(baseURL: "http://api.test", indexerURL: "http://indexer.test")
        client.setIdentity(identity)

        _ = try await client.indexing.sqlQuery(subgroveId: "sg", query: "SELECT 1")

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.url.host, "indexer.test")
        XCTAssertNil(request.header("X-Nonce"))
    }

    func testBaseURLPathIsLeftOutOfTheSignedTarget() async throws {
        let identity = try Self.vectorIdentity(.ed25519)
        let stub = StubServer { _ in (200, #"{"success":true,"data":{"a":1}}"#) }
        let client = try stub.client(baseURL: "https://proxy.example/willow/")
        client.setIdentity(identity)

        _ = try await client.data.getUnverified(subgroveId: "sg", key: "k")

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.path, "/willow/data/sg/k")
        // The proxy strips its mount path, so the API sees /data/sg/k.
        try request.assertNonceSigned(by: identity, target: "/data/sg/k")
    }

    func testRequestURLKeepsTheQueryString() throws {
        let base = URL(string: "https://api.example/base/")!
        XCTAssertEqual(
            try WillowClient.requestURL(base: base, path: "/data/sg/k", query: [("include_proof", "false")]).absoluteString,
            "https://api.example/base/data/sg/k?include_proof=false"
        )
        XCTAssertEqual(
            try WillowClient.requestURL(base: URL(string: "http://h:3031")!, path: "/did/did:willow:z1/permissions").absoluteString,
            "http://h:3031/did/did:willow:z1/permissions"
        )
    }

    func testSubgroveReadRoutes() {
        XCTAssertTrue(WillowClient.isSubgroveReadRoute(method: "GET", target: "/data/sg/k"))
        XCTAssertTrue(WillowClient.isSubgroveReadRoute(method: "GET", target: "/data/sg/k?include_proof=true"))
        XCTAssertTrue(WillowClient.isSubgroveReadRoute(method: "GET", target: "/proof/sg/k"))
        XCTAssertTrue(WillowClient.isSubgroveReadRoute(method: "POST", target: "/query/sg"))
        XCTAssertTrue(WillowClient.isSubgroveReadRoute(method: "POST", target: "/sql/sg"))
        XCTAssertTrue(WillowClient.isSubgroveReadRoute(method: "POST", target: "/graphql/sg"))

        XCTAssertFalse(WillowClient.isSubgroveReadRoute(method: "POST", target: "/data/sg"))
        XCTAssertFalse(WillowClient.isSubgroveReadRoute(method: "PUT", target: "/data/sg/k"))
        XCTAssertFalse(WillowClient.isSubgroveReadRoute(method: "GET", target: "/proof/key-grant/sg/did"))
        XCTAssertFalse(WillowClient.isSubgroveReadRoute(method: "GET", target: "/proof/file/sg/k"))
        XCTAssertFalse(WillowClient.isSubgroveReadRoute(method: "POST", target: "/tx/submit"))
        XCTAssertFalse(WillowClient.isSubgroveReadRoute(method: "GET", target: "/fees/schedule"))
        XCTAssertFalse(WillowClient.isSubgroveReadRoute(method: "GET", target: "/did/d/permissions"))
    }
}

// MARK: - Stub transport

/// One request as the stub transport received it.
struct ReceivedRequest {
    let method: String
    let url: URL
    /// Header fields, keyed by lowercased name.
    let fields: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        return fields[name.lowercased()]
    }

    /// The percent-encoded path, as on the request line.
    var path: String {
        return URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath
    }

    /// The percent-encoded path and query, as on the request line.
    var target: String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        return components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    /// Rebuilds the eight-line message from the request as received and checks
    /// the signature over it, as the server does.
    func assertNonceSigned(by identity: Identity, target: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let nonce = try XCTUnwrap(header("X-Nonce"), "\(method) \(self.target): no X-Nonce", file: file, line: line)
        let message = signedRequestMessage(
            did: (header("X-DID") ?? ""),
            publicKeyId: (header("X-Public-Key-ID") ?? ""),
            method: method,
            pathAndQuery: target ?? self.target,
            timestamp: (header("X-Timestamp") ?? ""),
            nonce: nonce,
            body: body
        )
        let signature = try XCTUnwrap(Data(hexString: (header("X-Signature") ?? "")), file: file, line: line)
        XCTAssertEqual(header("X-DID"), identity.did, file: file, line: line)
        XCTAssertTrue(try verify(
            algorithm: identity.keyPair.algorithm, publicKey: identity.keyPair.publicKey,
            message: Data(message.utf8), signature: signature
        ), "\(method) \(self.target): the signature does not cover the request as received", file: file, line: line)
    }
}

/// A `URLSession` whose requests are answered by a closure and recorded.
final class StubServer {
    typealias Handler = (ReceivedRequest) -> (Int, String)

    private let lock = NSLock()
    private var received: [ReceivedRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
        StubServerProtocol.current = self
    }

    var requests: [ReceivedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServerProtocol.self]
        return URLSession(configuration: configuration)
    }

    func client(baseURL: String, indexerURL: String? = nil) throws -> WillowClient {
        let config = ClientConfig(
            baseURL: URL(string: baseURL)!,
            indexerURL: indexerURL.flatMap { URL(string: $0) },
            retryConfig: RetryConfig(maxRetries: 2, initialBackoff: 0.001, maxBackoff: 0.001, backoffFactor: 1)
        )
        return WillowClient(config: config, session: session)
    }

    fileprivate func answer(_ request: URLRequest) -> (Int, Data) {
        var fields: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            fields[key.lowercased()] = value
        }
        let received = ReceivedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            fields: fields,
            body: StubServerProtocol.body(of: request)
        )
        lock.lock()
        self.received.append(received)
        lock.unlock()
        let (status, body) = handler(received)
        return (status, Data(body.utf8))
    }
}

/// Answers every request from the most recently created `StubServer` (tests
/// run one at a time).
final class StubServerProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: StubServer?

    static var current: StubServer? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); defer { lock.unlock() }; _current = newValue }
    }

    /// The body URLSession hands a protocol: `httpBody`, or the stream it was moved to.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }

    override func startLoading() {
        guard let server = Self.current else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = server.answer(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
