import XCTest
import CryptoKit
@testable import Willow

/// File writes are signed (by the client's identity under its nonce
/// allocator when no signing options are given), and a download refuses a
/// manifest the chain would refuse before fetching any chunk.
final class FilesTests: XCTestCase {

    static let anyHash = String(repeating: "ab", count: 32)

    /// `GET /files/sg/f`'s answer for a manifest with these fields.
    static func manifest(
        totalSize: String = "5", chunkCount: String = "1", chunkSize: String = "262144",
        contentHash: String = anyHash, merkleRoot: String = anyHash
    ) -> String {
        return #"""
        {"file_key":"f","filename":"a.txt","content_type":"text/plain","total_size":\#(totalSize),"content_hash":"\#(contentHash)",
         "chunk_count":\#(chunkCount),"chunk_size":\#(chunkSize),"chunk_merkle_root":"\#(merkleRoot)","owner_did":"did:willow:a",
         "created_at":1,"updated_at":1,"encrypted":false,"storage_nodes":["http://storage.test"]}
        """#
    }

    /// A manifest the chain would refuse is refused before any chunk is
    /// fetched: a count of 2^32 - 1 chunks for 1 byte made the download
    /// loop over that many requests, and a hash holding a space made a URL
    /// that is nil on older systems, which was force-unwrapped.
    func testADownloadRefusesAManifestTheChainWouldRefuse() async throws {
        let refused = [
            Self.manifest(totalSize: "1", chunkCount: "4294967295", chunkSize: "4096"),
            Self.manifest(totalSize: "0", chunkCount: "1"),
            Self.manifest(chunkCount: "0"),
            Self.manifest(chunkSize: "0"),
            Self.manifest(totalSize: "1073741825", chunkCount: "4097", chunkSize: "262144"),
            Self.manifest(totalSize: "1048577", chunkCount: "262145", chunkSize: "4"),
            Self.manifest(totalSize: "600000", chunkCount: "1", chunkSize: "262144"),
            Self.manifest(totalSize: "5", chunkCount: "2", chunkSize: "262144"),
            Self.manifest(contentHash: "ab ab"),
            Self.manifest(contentHash: String(repeating: "00", count: 32)),
            Self.manifest(merkleRoot: "xyz"),
        ]
        for answer in refused {
            let stub = StubServer { request in
                request.url.host == "api.test" ? (200, answer) : (404, "")
            }
            let client = try stub.client(baseURL: "http://api.test")
            do {
                let data = try await client.files.download(subgroveId: "sg", fileKey: "f", storageNodeEndpoint: "http://storage.test")
                XCTFail("downloaded \(data.count) bytes for \(answer)")
            } catch let error as WillowError {
                XCTAssertEqual(error.type, .validation, "\(answer): \(error.message)")
            }
            XCTAssertEqual(stub.requests.filter { $0.url.host != "api.test" }.count, 0, answer)
        }
    }

    /// A manifest the chain takes downloads; a storage node serving more
    /// bytes than it names is refused.
    func testADownloadChecksTheBytesServed() async throws {
        let file = Data("hello".utf8)
        let leaf = Data(SHA256.hash(data: file))
        let root = Data(SHA256.hash(data: leaf + leaf)).hexString
        let content = Data(SHA256.hash(data: file)).hexString
        for (served, ok) in [(file, true), (file + Data("!".utf8), false)] {
            let stub = StubServer { request in
                if request.url.host == "api.test" {
                    return (200, Self.manifest(contentHash: content, merkleRoot: root))
                }
                XCTAssertEqual(request.target, "/chunk/sg/my%20file/0?content_hash=\(content)")
                return (200, String(decoding: served, as: UTF8.self))
            }
            let client = try stub.client(baseURL: "http://api.test")
            do {
                let data = try await client.files.download(subgroveId: "sg", fileKey: "my file", storageNodeEndpoint: "http://storage.test/")
                XCTAssertTrue(ok)
                XCTAssertEqual(data, file)
            } catch let error as WillowError {
                XCTAssertFalse(ok, error.message)
                XCTAssertEqual(error.type, .validation)
            }
        }
    }

    /// A manifest whose chunks are under the 4,096 bytes the chain now
    /// requires of a file of more than one downloads: the chain refuses such
    /// a manifest only from a later height, so one stored before it may have
    /// them.
    func testADownloadTakesAManifestWithChunksUnderTheCurrentMinimum() async throws {
        let file = Data("hello world".utf8)
        let chunks = [file.prefix(4), file.dropFirst(4).prefix(4), file.dropFirst(8)]
        let leaves = chunks.map { Data(SHA256.hash(data: $0)) }
        let left = Data(SHA256.hash(data: leaves[0] + leaves[1]))
        let right = Data(SHA256.hash(data: leaves[2] + leaves[2]))
        let root = Data(SHA256.hash(data: left + right)).hexString
        let content = Data(SHA256.hash(data: file)).hexString
        let stub = StubServer { request in
            if request.url.host == "api.test" {
                return (200, Self.manifest(totalSize: "11", chunkCount: "3", chunkSize: "4", contentHash: content, merkleRoot: root))
            }
            guard let index = Int(request.path.split(separator: "/").last ?? ""), index < chunks.count else {
                return (404, "")
            }
            return (200, String(decoding: chunks[index], as: UTF8.self))
        }
        let client = try stub.client(baseURL: "http://api.test")
        let data = try await client.files.download(subgroveId: "sg", fileKey: "f", storageNodeEndpoint: "http://storage.test")
        XCTAssertEqual(data, file)
    }

    /// With no signing options and no identity, an upload or delete sends
    /// nothing: the node refuses an unsigned manifest.
    func testAnUnsignedFileWriteIsRefusedBeforeSending() async throws {
        let stub = StubServer { _ in (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""}}"#) }
        let client = try stub.client(baseURL: "http://api.test")
        do {
            _ = try await client.files.upload(
                subgroveId: "sg", fileKey: "f", filename: "a.txt", data: Data("hello".utf8), storageNodeEndpoint: "http://storage.test")
            XCTFail("an unsigned manifest was sent")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .authentication)
        }
        do {
            try await client.files.delete(subgroveId: "sg", fileKey: "f")
            XCTFail("an unsigned deletion was sent")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .authentication)
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    /// With no signing options, the client's identity signs a file write under
    /// a nonce from its allocator, which a write in flight doesn't share.
    func testFileWritesSignedByTheIdentityTakeTheAllocatorsNonce() async throws {
        let chain = NonceTests.FakeChain(base: 5)
        chain.pending = true
        let stub = StubServer { request in
            if request.url.host == "storage.test" {
                return (200, "")
            }
            return chain.answer(request)
        }
        let client = try stub.client(baseURL: "http://api.test")
        let identity = try NonceTests.identity()
        client.setIdentity(identity)

        try await client.data.store(subgroveId: "sg", key: "a", data: ["k": "a"])
        _ = try await client.files.upload(
            subgroveId: "sg", fileKey: "f", filename: "a.txt", data: Data("hello".utf8), storageNodeEndpoint: "http://storage.test")
        try await client.files.delete(subgroveId: "sg", fileKey: "f")
        XCTAssertEqual(chain.sent, [6, 7, 8])

        let submits = stub.requests.filter { $0.path == "/tx/submit" }
        let manifest = try SignedMessagesTests.submitted(
            SignedMessagesTests.ChainStoreFileManifestTx.self, variant: "StoreFileManifest", from: submits[1])
        XCTAssertEqual(manifest.ownerDid, identity.did)
        XCTAssertEqual(manifest.publicKeyId, identity.publicKeyId)
        let message = try SignedMessagesTests.message(for: manifest)
        XCTAssertTrue(try verify(
            algorithm: identity.keyPair.algorithm, publicKey: identity.keyPair.publicKey,
            message: Data(message.utf8), signature: Data(manifest.signature)))
        let deletion = try SignedMessagesTests.submitted(
            SignedMessagesTests.ChainDeleteFileManifestTx.self, variant: "DeleteFileManifest", from: submits[2])
        XCTAssertEqual(deletion.ownerDid, identity.did)
        let deleteMessage = try deleteFileManifestMessage(
            subgroveId: deletion.subgroveId, fileKey: deletion.fileKey, ownerDid: deletion.ownerDid, nonce: deletion.nonce)
        XCTAssertTrue(try verify(
            algorithm: identity.keyPair.algorithm, publicKey: identity.keyPair.publicKey,
            message: Data(deleteMessage.utf8), signature: Data(deletion.signature)))
    }

    /// The storage node refuses a chunk until the manifest is on chain, which
    /// is after the submission returns: the chunk is posted again until taken.
    func testAnUploadPostsAChunkAgainUntilTheManifestLands() async throws {
        let chain = NonceTests.FakeChain(base: 5)
        var refusals = 2
        let stub = StubServer { request in
            if request.url.host == "storage.test" {
                if refusals > 0 { refusals -= 1; return (403, #"{"error":"No on-chain manifest found."}"#) }
                return (200, "{}")
            }
            return chain.answer(request)
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(try NonceTests.identity())
        let manifest = try await client.files.upload(
            subgroveId: "sg", fileKey: "f", filename: "a.txt", data: Data("hello".utf8),
            storageNodeEndpoint: "http://storage.test", pollInterval: 0.01)
        XCTAssertEqual(manifest.fileKey, "f")
        XCTAssertEqual(stub.requests.filter { $0.url.host == "storage.test" }.count, 3)
    }

    /// A manifest whose outcome is unknown that did land: its chunks go up, so
    /// the file isn't left without them.
    func testAnUploadWhoseManifestAnswerWasLostStillPostsItsChunks() async throws {
        let chain = NonceTests.FakeChain(base: 5)
        let stub = StubServer { request in
            if request.url.host == "storage.test" { return (200, "{}") }
            if request.path == "/tx/submit" { return (502, #"{"success":false,"error":"Failed to reach CometBFT RPC"}"#) }
            return chain.answer(request)
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(try NonceTests.identity())
        let manifest = try await client.files.upload(
            subgroveId: "sg", fileKey: "f", filename: "a.txt", data: Data("hello".utf8),
            storageNodeEndpoint: "http://storage.test", pollInterval: 0.01)
        XCTAssertEqual(manifest.fileKey, "f")
        XCTAssertEqual(stub.requests.filter { $0.url.host == "storage.test" }.count, 1)
    }

    /// One that didn't land: the chunks are never taken, and the submission's
    /// error comes back with what `resubmit` needs.
    func testAnUploadWhoseManifestNeverLandsThrowsItsSubmission() async throws {
        let chain = NonceTests.FakeChain(base: 5)
        let stub = StubServer { request in
            if request.url.host == "storage.test" { return (403, "{}") }
            if request.path == "/tx/submit" { return (502, #"{"success":false,"error":"Failed to reach CometBFT RPC"}"#) }
            return chain.answer(request)
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(try NonceTests.identity())
        do {
            _ = try await client.files.upload(
                subgroveId: "sg", fileKey: "f", filename: "a.txt", data: Data("hello".utf8),
                storageNodeEndpoint: "http://storage.test", landingTimeout: 0.05, pollInterval: 0.01)
            XCTFail("uploaded a file whose manifest never landed")
        } catch let error as TransactionSubmitError {
            XCTAssertEqual(error.submission.nonce, 6)
        }
    }
}
