import XCTest
@testable import Willow

/// Writes go through `POST /tx/submit` (the API serves no REST write route),
/// and every read unwraps the API's `{ success, data, error }` envelope where
/// the handler sends one, with the shapes the handlers serve.
final class ApiRoutesTests: XCTestCase {

    static let submitted = #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""},"error":null}"#

    /// A stub that reports `nonce - 1` as the account's nonce and accepts every transaction.
    static func writeStub(nextNonce nonce: UInt64) -> StubServer {
        return StubServer { request in
            if request.path.hasPrefix("/account/"), request.path.hasSuffix("/nonce") {
                return (200, #"{"success":true,"data":{"did":"did:willow:a","nonce":\#(nonce - 1)},"error":null}"#)
            }
            return (200, submitted)
        }
    }

    static func identity(_ algorithm: SignatureAlgorithm = .ed25519) throws -> Identity {
        return try RequestSigningTests.vectorIdentity(algorithm)
    }

    // MARK: - Data writes

    func testStoreIsAStoreDataTransactionSignedByTheIdentity() async throws {
        for algorithm in [SignatureAlgorithm.ed25519, .secp256k1] {
            let identity = try Self.identity(algorithm)
            let stub = Self.writeStub(nextNonce: 7)
            let client = try stub.client(baseURL: "http://api.test")
            client.setIdentity(identity)

            let result = try await client.data.store(subgroveId: "sg-1", key: "doc1", data: ["value": 42, "title": "Hello"])
            XCTAssertEqual(result.txHash, "AB")

            XCTAssertEqual(stub.requests.map { "\($0.method) \($0.path)" }, ["GET /account/did:willow:a/nonce", "POST /tx/submit"])
            let tx = try SignedMessagesTests.submitted(SignedMessagesTests.ChainStoreDataTx.self, variant: "StoreData", from: stub.requests[1])
            XCTAssertEqual(tx.nonce, 7)
            XCTAssertEqual(tx.ownerDid, "did:willow:a")
            XCTAssertEqual(tx.publicKeyId, "did:willow:a#key-1")
            // Sorted keys: the bytes of the first known answer's data.
            XCTAssertEqual(String(decoding: tx.data, as: UTF8.self), #"{"title":"Hello","value":42}"#)
            let message = try storeDataMessage(subgroveId: tx.subgroveId, key: tx.key, ownerDid: tx.ownerDid, data: Data(tx.data), nonce: tx.nonce)
            XCTAssertTrue(try verify(
                algorithm: algorithm, publicKey: identity.keyPair.publicKey, message: Data(message.utf8), signature: Data(tx.signature)
            ))
        }
    }

    /// Writes sent before the previous one lands take the next free nonce
    /// (the node refuses a nonce a pending transaction holds); a write the
    /// API doesn't accept gives its nonce back, so a retry signs under it.
    func testBackToBackWritesTakeConsecutiveNoncesAndARefusalGivesItsNonceBack() async throws {
        var refuse = false
        let stub = StubServer { request in
            if request.path.hasSuffix("/nonce") {
                return (200, #"{"success":true,"data":{"did":"did:willow:a","nonce":6},"error":null}"#)
            }
            return refuse
                ? (200, #"{"success":true,"data":{"tx_hash":"AB","code":5,"log":"refused"},"error":null}"#)
                : (200, Self.submitted)
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(try Self.identity())

        try await client.data.store(subgroveId: "sg", key: "a", data: ["n": 1])
        try await client.data.store(subgroveId: "sg", key: "b", data: ["n": 2])
        refuse = true
        do {
            try await client.data.store(subgroveId: "sg", key: "c", data: ["n": 3])
            XCTFail("a refused transaction must throw")
        } catch is TransactionError {}
        refuse = false
        try await client.data.store(subgroveId: "sg", key: "c", data: ["n": 3])
        try await client.registration.deleteSubgrove(subgroveId: "sg")

        let nonces = try stub.requests.filter { $0.path == "/tx/submit" }.map { request -> UInt64 in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: [String: Any]])
            return try XCTUnwrap((body.values.first?["nonce"] as? NSNumber)?.uint64Value)
        }
        XCTAssertEqual(nonces, [7, 8, 9, 9, 10])
    }

    func testAnOutOfRangeAccountNonceIsRefused() async throws {
        let stub = StubServer { _ in (200, #"{"success":true,"data":{"did":"did:willow:a","nonce":18446744073709551615},"error":null}"#) }
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(try Self.identity())
        do {
            try await client.data.store(subgroveId: "sg", key: "k", data: ["a": 1])
            XCTFail("must throw")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
        XCTAssertFalse(stub.requests.contains { $0.path == "/tx/submit" })
    }

    func testStoreRefusesBeforeSending() async throws {
        let stub = Self.writeStub(nextNonce: 1)
        let client = try stub.client(baseURL: "http://api.test")
        do {
            _ = try await client.data.store(subgroveId: "sg", key: "k", data: ["a": 1])
            XCTFail("a write needs an identity")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .authentication)
        }
        client.setIdentity(try Self.identity())
        do {
            _ = try await client.data.store(subgroveId: "sg", key: "a\r\nb", data: ["a": 1])
            XCTFail("a key holding a line break must be refused")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
        XCTAssertTrue(stub.requests.isEmpty)

        // A StoreData value must be a JSON object: the node refuses anything else in the block.
        let (consensusStub, consensus) = SignedMessagesTests.consensusStub(nextNonce: 1)
        do {
            _ = try await consensus.storeData(
                subgroveId: "sg", key: "k", data: [1, 2], ownerDid: "did:willow:a",
                privateKey: Data(), publicKeyId: "did:willow:a#key-1", signFunction: { _, _ in Data() }
            )
            XCTFail("an array must be refused")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .validation)
        }
        XCTAssertTrue(consensusStub.requests.isEmpty)
    }

    @available(*, deprecated)
    func testWritesWithNoTransactionThrowAndSendNothing() async throws {
        let stub = Self.writeStub(nextNonce: 1)
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(try Self.identity())
        let attempts: [(String, () async throws -> Void)] = [
            ("batchStore", { try await client.data.batchStore(subgroveId: "sg", items: [StoreRequest(key: "k", data: ["a": 1])]) }),
            ("update", { try await client.data.update(subgroveId: "sg", key: "k", data: ["a": 1]) }),
            ("delete", { try await client.data.delete(subgroveId: "sg", key: "k") }),
            ("updateSubgrove", { _ = try await client.registration.updateSubgrove(subgroveId: "sg", updates: ["name": "x"]) }),
            ("grantPermission", {
                let permission = try JSONDecoder().decode(Permission.self, from: Data(#"{"did":"d","granted_by":"o","granted_at":1}"#.utf8))
                try await client.registration.grantPermission(permission)
            }),
            ("revokePermission", { try await client.registration.revokePermission(did: "d", subgroveId: "sg") }),
            ("registerDID", { _ = try await client.registerDID(try Self.identity().didDocument) }),
            ("getIndexerStatus", { _ = try await client.indexing.getIndexerStatus(indexerId: "i", subgroveId: "sg") }),
        ]
        for (name, attempt) in attempts {
            do {
                try await attempt()
                XCTFail("\(name) must throw")
            } catch let error as WillowError {
                XCTAssertEqual(error.type, .validation, name)
            }
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: - Registration writes

    func testRegisterSubgroveIsARegisterSubgroveTransaction() async throws {
        let identity = try Self.identity()
        let stub = Self.writeStub(nextNonce: 3)
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(identity)

        let schema = SchemaBuilder(name: "notes").stringField("title", required: true).intField("n").build()
        let request = SubgroveBuilder(subgroveId: "notes-1", name: "Notes").description("Team notes").schema(schema)
            .writers(["did:willow:a"]).readers(["did:willow:c"]).build()
        try await client.registration.registerSubgrove(request)

        XCTAssertEqual(stub.requests.map { "\($0.method) \($0.path)" }, ["GET /account/did:willow:a/nonce", "POST /tx/submit"])
        let sent = try SecondSetTests.submitted("RegisterSubgrove", from: stub.requests[1])
        let tx = try RegisterSubgroveTx(wireJSON: sent)
        XCTAssertEqual(tx.nonce, 3)
        XCTAssertEqual(tx.name, "Notes")
        XCTAssertEqual(tx.description, "Team notes")
        XCTAssertEqual(tx.ownerDid, "did:willow:a")
        // The schema in the node's form.
        XCTAssertEqual(tx.schema, #"{"fields":{"n":"number","title":"string"},"indexes":[],"required_fields":["title"],"version":1}"#)
        guard case .dataStorage(let mode) = tx.mode else { return XCTFail("DataStorage") }
        XCTAssertEqual(mode.writers, ["did:willow:a"])
        XCTAssertEqual(mode.freeReaders, ["did:willow:c"])
        let message = try registerSubgroveMessage(json: sent)
        XCTAssertTrue(try verify(algorithm: .ed25519, publicKey: identity.keyPair.publicKey, message: Data(message.utf8), signature: Data(tx.signature)))
    }

    @available(*, deprecated)
    func testRegisterSubgroveRefusesWhatItCantSign() async throws {
        let stub = Self.writeStub(nextNonce: 1)
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(try Self.identity())
        let refused = [
            RegisterSubgroveRequest(subgroveId: "sg", name: "n", ownerDid: "did:willow:someone-else"),
            RegisterSubgroveRequest(subgroveId: "sg", name: "n", rewardRate: 5),
            RegisterSubgroveRequest(subgroveId: "sg", name: "n", retentionWindow: .indefinite),
            RegisterSubgroveRequest(subgroveId: "sg", name: "n", schema: SchemaDefinition(name: "s", fields: [SchemaField(name: "f", type: "uuid")])),
            RegisterSubgroveRequest(subgroveId: "s\ng", name: "n"),
            // The node refuses a data subgrove whose ID breaks its rule or whose schema declares indexes.
            RegisterSubgroveRequest(subgroveId: "", name: "n"),
            RegisterSubgroveRequest(subgroveId: "-sg", name: "n"),
            RegisterSubgroveRequest(subgroveId: "sg.1", name: "n"),
            RegisterSubgroveRequest(subgroveId: String(repeating: "a", count: 65), name: "n"),
            RegisterSubgroveRequest(subgroveId: "notes-1", name: "n", schema: SchemaBuilder(name: "notes").stringField("title").hashIndex("by_title", fields: ["title"]).build()),
            // ... or whose writers or readers aren't DIDs.
            RegisterSubgroveRequest(subgroveId: "sg", name: "n", writers: ["alice"]),
            RegisterSubgroveRequest(subgroveId: "sg", name: "n", readers: ["did:willow:"]),
        ]
        for request in refused {
            do {
                try await client.registration.registerSubgrove(request)
                XCTFail("must be refused")
            } catch let error as WillowError {
                XCTAssertEqual(error.type, .validation)
            }
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testDeleteSubgroveIsADeregisterSubgroveTransaction() async throws {
        let identity = try Self.identity(.secp256k1)
        let stub = Self.writeStub(nextNonce: 9)
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(identity)

        try await client.registration.deleteSubgrove(subgroveId: "sg-1")

        let tx = try JSONDecoder().decode([String: DeregisterSubgroveTx].self, from: stub.requests[1].body)["DeregisterSubgrove"]
        let deregister = try XCTUnwrap(tx)
        XCTAssertEqual(deregister.nonce, 9)
        XCTAssertTrue(try verify(
            algorithm: .secp256k1, publicKey: identity.keyPair.publicKey,
            message: Data("DeregisterSubgrove:sg-1:did:willow:a:9".utf8), signature: Data(deregister.signature)
        ))
    }

    // MARK: - Envelopes

    func testTokenReadsUnwrapTheEnvelopeAndKeepAmountsExact() async throws {
        let stub = StubServer { request in
            switch request.path {
            case "/token/info":
                return (200, #"{"success":true,"data":{"name":"Willow","symbol":"WILL","decimals":18,"genesis_supply":100000000000000000000000000,"minted_supply":0,"max_supply":1000000000000000000000000000,"circulating_supply":5},"error":null}"#)
            case "/token/balance/did:willow:a":
                return (200, #"{"success":true,"data":{"did":"did:willow:a","available":25000000000000000000,"staked":0,"locked":1},"error":null}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")

        let info = try await client.token.getInfo()
        XCTAssertEqual(info.symbol, "WILL")
        XCTAssertEqual(info.maxSupply, "1000000000000000000000000000")
        XCTAssertEqual(info.genesisSupply, "100000000000000000000000000")
        let balance = try await client.token.getBalance(did: "did:willow:a")
        XCTAssertEqual(balance.available, "25000000000000000000")
        XCTAssertEqual(balance.locked, "1")
    }

    func testValidatorReadsUnwrapTheEnvelope() async throws {
        let stub = StubServer { request in
            switch request.path {
            case "/validators":
                return (200, #"{"success":true,"data":[{"did":"did:willow:v1","total_stake":100000000000000000000000,"self_stake":100000000000000000000000,"active":true,"jailed":false,"jail_end_time":null,"consensus_pubkey":"pk"},{"did":"did:willow:v2","total_stake":200000000000000000000000,"self_stake":1,"active":true,"jailed":false,"jail_end_time":null,"consensus_pubkey":null}],"error":null}"#)
            default:
                return (404, #"{"success":false,"data":null,"error":"Validator did:willow:x not found"}"#)
            }
        }
        let client = try stub.client(baseURL: "http://api.test")

        let validators = try await client.validators.list()
        XCTAssertEqual(validators.map { $0.did }, ["did:willow:v1", "did:willow:v2"])
        XCTAssertEqual(validators[0].status, .active)
        let total = try await client.validators.getTotalStake()
        XCTAssertEqual(total, "300000000000000000000000")
        do {
            _ = try await client.validators.get(address: "did:willow:x")
            XCTFail("a missing validator must throw")
        } catch let error as HTTPError {
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertEqual(error.message, "Validator did:willow:x not found")
        }
    }

    func testSubgroveAndIndexerReadsUnwrapTheEnvelope() async throws {
        let stub = StubServer { request in
            switch request.path {
            case "/subgroves/notes-1":
                return (200, #"{"success":true,"data":{"subgrove_id":"notes-1","name":"Notes","owner_did":"did:willow:a","status":"active","latest_block":0,"deployment_block":0,"indexers":[]},"error":null}"#)
            case "/subgroves/indexed":
                return (200, #"{"success":true,"data":[{"subgrove_id":"idx","name":"Index","owner_did":"did:willow:a","status":"active","latest_block":21000000,"deployment_block":12,"indexers":["did:willow:i"],"chain":"mainnet"}],"error":null}"#)
            case "/subgroves":
                return (200, #"{"success":true,"data":[{"subgrove_id":"notes-1","name":"Notes","description":"","admins":[],"schema":{"version":1,"fields":{"title":"string"},"indexes":[],"required_fields":[]},"owner_did":"did:willow:a","writers":["did:willow:a"],"free_readers":[],"read_pricing":{"enabled":true,"price_per_query":1000000000000000,"owner_revenue_share_bps":8000},"checkpoint_verification":{"required_tee":null},"template_config":null,"privacy":null,"retention_window":"Indefinite","confirmation_depth":0,"cryptographic_completeness":false,"created_at":1,"updated_at":2,"mode":"DataStorage","indexer_count":0}],"error":null}"#)
            case "/indexers":
                return (200, #"{"success":true,"data":[{"indexer_did":"did:willow:i","subgroves":["idx"],"stake_amount":10000000000000000000000,"endpoint":"http://i","status":"active","performance_score":0.99,"last_update":5}],"error":null}"#)
            case "/checkpoints/idx/aa/state-root":
                return (200, #"{"success":true,"data":{"checkpoint_id":"aa","subgrove_id":"idx","state_root":"bb","block_range":[1,2],"is_trusted":true},"error":null}"#)
            default:
                return (404, "")
            }
        }
        let client = try stub.client(baseURL: "http://api.test")

        let subgrove = try await client.registration.getSubgrove(subgroveId: "notes-1")
        XCTAssertEqual(subgrove.ownerDid, "did:willow:a")
        let indexed = try await client.indexing.listSubgroves()
        XCTAssertEqual(indexed.first?.chain, "mainnet")
        let listed = try await client.registration.listSubgroves()
        XCTAssertEqual(listed.first?.schema.fields, ["title": "string"])
        XCTAssertEqual(listed.first?.readPricing?.pricePerQuery, U128(1_000_000_000_000_000))
        XCTAssertEqual(listed.first?.retentionWindow, .indefinite)
        let indexers = try await client.indexing.listIndexers()
        XCTAssertEqual(indexers.first?.stakeAmount, "10000000000000000000000")
        let checkpoint = try await client.data.getCheckpointStateRoot(subgroveId: "idx", checkpointId: "aa")
        XCTAssertEqual(checkpoint.stateRoot, "bb")
        XCTAssertNil(checkpoint.indexerDid)
    }

    func testAnEnvelopesErrorIsSurfaced() async throws {
        let stub = StubServer { _ in (200, #"{"success":false,"data":null,"error":"Subgrove registry unavailable"}"#) }
        let client = try stub.client(baseURL: "http://api.test")
        do {
            _ = try await client.indexing.listIndexers()
            XCTFail("an envelope with an error must throw")
        } catch let error as WillowError {
            XCTAssertTrue(error.message.contains("Subgrove registry unavailable"), error.message)
        }
    }

    func testKeyGrantReadsAreNonceSignedAndUnwrapped() async throws {
        let identity = try Self.identity()
        let stub = StubServer { request in
            switch request.path {
            case "/key-grants/private-1/did:willow:a":
                return (200, #"{"success":true,"data":{"grantee_did":"did:willow:a","key_epoch":0,"grantee_public_key_id":"did:willow:a#key-1","ephemeral_public_key":[1,2],"encrypted_key":[3],"granted_by":"did:willow:a","granted_at":1800000000},"error":null}"#)
            case "/key-grants/private-1":
                return (200, #"{"success":true,"data":["did:willow:a","did:willow:b"],"error":null}"#)
            case "/proof/key-grant/private-1/did:willow:b":
                return (200, #"{"success":true,"data":{"proof":"00ff","subgrove_id":"private-1","grantee_did":"did:willow:b"},"error":null}"#)
            default:
                return (404, #"{"success":false,"data":null,"error":"Key grant not found: did:willow:c"}"#)
            }
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(identity)
        let consensus = ConsensusClient(ConsensusConfig(consensusRpcUrl: "http://rpc.test", apiUrl: "http://api.test"), session: stub.session)
        let privacy = PrivacyOperations(client: client, consensus: consensus)

        let grant = try await privacy.getMyKeyGrant(subgroveId: "private-1")
        XCTAssertEqual(grant.grantedAt, 1_800_000_000)
        let grantees = try await privacy.listKeyGrantees(subgroveId: "private-1")
        XCTAssertEqual(grantees, ["did:willow:a", "did:willow:b"])
        let proof = try await privacy.getKeyGrantProof(subgroveId: "private-1", did: "did:willow:b")
        XCTAssertEqual(proof.proof, Data([0x00, 0xFF]))
        for request in stub.requests {
            try request.assertNonceSigned(by: identity)
        }
    }

    func testFileListingsWithoutStorageNodesDecode() async throws {
        let stub = StubServer { _ in
            (200, #"{"files":[{"file_key":"photo.png","filename":"photo.png","content_type":"image/png","total_size":5,"content_hash":"11","chunk_count":1,"chunk_size":5,"chunk_merkle_root":"22","owner_did":"did:willow:a","created_at":1,"updated_at":1,"encrypted":false}],"limit":50,"start_after":null,"has_more":false}"#)
        }
        let client = try stub.client(baseURL: "http://api.test")
        let files = try await client.files.list(subgroveId: "files-1")
        XCTAssertEqual(files.first?.fileKey, "photo.png")
        XCTAssertEqual(files.first?.storageNodes, [])
    }

    func testHealthIsTheBareHealthReport() async throws {
        let stub = StubServer { _ in
            (200, #"{"status":"healthy","timestamp":"1970-01-01T00:00:00Z","version":"1.0.0","checks":{"storage":{"status":"healthy","message":"ok"},"system":{"uptime_seconds":5}}}"#)
        }
        let client = try stub.client(baseURL: "http://api.test")
        let health = try await client.getHealth()
        XCTAssertTrue(health.healthy)
        XCTAssertEqual(health.version, "1.0.0")
    }
}
