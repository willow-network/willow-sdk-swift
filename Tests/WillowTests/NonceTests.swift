import XCTest
@testable import Willow

/// Nonce allocation: each write takes the lowest nonce above the account's
/// base that isn't used and isn't held by another write in flight, a nonce
/// refused at CheckTx is given back unless the refusal says it is taken, a
/// nonce that never lands is free again after 120 s, and no nonce above the
/// node's window is ever signed.
final class NonceTests: XCTestCase {

    // MARK: - Helpers

    /// A settable monotonic clock.
    final class Clock {
        private let lock = NSLock()
        private var seconds: TimeInterval = 1_000

        var now: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return seconds
        }

        func advance(_ by: TimeInterval) {
            lock.lock()
            seconds += by
            lock.unlock()
        }
    }

    static let account = NonceAccount(did: "did:willow:a", api: "http://api.test")

    static func chain(_ base: UInt64, used: Set<UInt64> = []) throws -> ChainNonces {
        return try ChainNonces(base: base, used: used)
    }

    /// A CometBFT `abci_query` answer for `/store/account_nonce_state`: the
    /// base, then the bitmap of `used` nonces above it.
    static func nonceStateAnswer(base: UInt64, used: Set<UInt64> = []) -> String {
        var bytes = withUnsafeBytes(of: base.bigEndian, Array.init)
        var bitmap: [UInt8] = [0, 0, 0]
        for nonce in used where nonce > base && nonce <= base + 24 {
            let i = Int(nonce - base - 1)
            bitmap[i / 8] |= 1 << (i % 8)
        }
        bytes += bitmap
        return #"{"jsonrpc":"2.0","id":1,"result":{"response":{"code":0,"log":"","value":"\#(Data(bytes).base64EncodedString())"}}}"#
    }

    /// A chain the stub server answers for: the account's base and the
    /// nonces used above it, the node's nonce checks at CheckTx, and refusals
    /// to hand out once. An accepted transaction lands at once unless
    /// `pending` is set.
    final class FakeChain {
        private let lock = NSLock()
        private var base: UInt64
        private var usedAbove: Set<UInt64>
        private var refusals: [UInt64: String] = [:]
        private var submitted: [UInt64] = []
        var pending = false
        /// Whether the RPC answers `/store/account_nonce_state` (else only the API's base is read).
        var answersNonceState = true

        init(base: UInt64, used: Set<UInt64> = []) {
            self.base = base
            self.usedAbove = used
        }

        /// The nonces of the transactions submitted, in order.
        var sent: [UInt64] {
            lock.lock()
            defer { lock.unlock() }
            return submitted
        }

        /// Refuses the next transaction under `nonce` at CheckTx with `log`.
        func refuseOnce(_ nonce: UInt64, _ log: String) {
            lock.lock()
            refusals[nonce] = log
            lock.unlock()
        }

        /// Marks `nonce` used, as another device's transaction would.
        func use(_ nonce: UInt64) {
            lock.lock()
            land(nonce)
            lock.unlock()
        }

        private func land(_ nonce: UInt64) {
            usedAbove.insert(nonce)
            while usedAbove.remove(base + 1) != nil {
                base += 1
            }
        }

        func answer(_ request: ReceivedRequest) -> (Int, String) {
            lock.lock()
            defer { lock.unlock() }
            if request.url.host == "rpc.test" {
                guard answersNonceState else {
                    return (200, #"{"jsonrpc":"2.0","id":1,"result":{"response":{"code":1,"log":"Unknown query type: account_nonce_state"}}}"#)
                }
                return (200, NonceTests.nonceStateAnswer(base: base, used: usedAbove))
            }
            if request.path.hasSuffix("/nonce") {
                return (200, #"{"success":true,"data":{"did":"did:willow:a","nonce":\#(base)},"error":null}"#)
            }
            guard request.path == "/tx/submit" else {
                return (404, #"{"success":false,"data":null,"error":"not found"}"#)
            }
            let nonce = NonceTests.nonce(of: request)
            submitted.append(nonce)
            let refusal: String?
            if let log = refusals.removeValue(forKey: nonce) {
                refusal = log
            } else if nonce <= base {
                refusal = "Invalid nonce: \(nonce) <= base nonce \(base)"
            } else if nonce > base + 24 {
                refusal = "Invalid nonce: \(nonce) is too far ahead (base=\(base), max=\(base + 24))"
            } else if usedAbove.contains(nonce) {
                refusal = "Invalid nonce: \(nonce) already used (replay)"
            } else {
                refusal = nil
            }
            if let refusal = refusal {
                return (200, #"{"success":true,"data":{"tx_hash":"AB","code":1,"log":"\#(refusal)"},"error":null}"#)
            }
            if !pending {
                land(nonce)
            }
            return (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""},"error":null}"#)
        }
    }

    /// The nonce of a `/tx/submit` body `{"<Variant>": {..., "nonce": n}}`.
    static func nonce(of request: ReceivedRequest) -> UInt64 {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: [String: Any]]
        return (body?.values.first?["nonce"] as? NSNumber)?.uint64Value ?? 0
    }

    static func stub(_ chain: FakeChain) -> StubServer {
        return StubServer { chain.answer($0) }
    }

    static func identity() throws -> Identity {
        return try RequestSigningTests.vectorIdentity(.ed25519)
    }

    static func consensus(_ stub: StubServer, _ nonces: NonceAllocator, api: String = "http://api.test") -> ConsensusClient {
        return ConsensusClient(ConsensusConfig(consensusRpcUrl: "http://rpc.test", apiUrl: api), session: stub.session, nonces: nonces)
    }

    func store(_ client: WillowClient, _ key: String) async throws {
        try await client.data.store(subgroveId: "sg", key: key, data: ["k": key])
    }

    // MARK: - The allocator

    func testWritesInFlightTakeTheLowestFreeNonces() throws {
        let nonces = NonceAllocator()
        XCTAssertEqual(try (0..<3).map { _ in try nonces.reserve(Self.account, chain: Self.chain(5)) }, [6, 7, 8])

        // A nonce the chain shows used is skipped; once the base passes a
        // held nonce, its hold ends.
        let other = NonceAllocator()
        XCTAssertEqual(try other.reserve(Self.account, chain: Self.chain(5, used: [7])), 6)
        XCTAssertEqual(try other.reserve(Self.account, chain: Self.chain(5, used: [7])), 8)
        XCTAssertEqual(try other.reserve(Self.account, chain: Self.chain(7)), 9)
        XCTAssertEqual(try other.reserve(Self.account, chain: Self.chain(9)), 10)
    }

    func testARefusedNonceIsGivenBack() throws {
        let nonces = NonceAllocator()
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 6)
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 7)
        nonces.settle(Self.account, nonce: 6, .givenBack)
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 6)
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 8)
    }

    func testANonceAnotherTransactionHoldsOrUsedIsNotGivenBack() throws {
        let clock = Clock()
        let nonces = NonceAllocator(now: { clock.now })
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 6)
        nonces.settle(Self.account, nonce: 6, .held)
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 7)
        nonces.settle(Self.account, nonce: 7, .used)
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 8)
        nonces.settle(Self.account, nonce: 8, .givenBack)
        // The hold lapses; a used nonce stays used until the base passes it.
        clock.advance(NonceAllocator.lease)
        XCTAssertEqual(try (0..<3).map { _ in try nonces.reserve(Self.account, chain: Self.chain(5)) }, [6, 8, 9])
    }

    func testANonceThatNeverLandsIsFreeAfterItsLease() throws {
        let clock = Clock()
        let nonces = NonceAllocator(now: { clock.now })
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 6)
        nonces.settle(Self.account, nonce: 6, .accepted)
        clock.advance(NonceAllocator.lease - 1)
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 7)
        clock.advance(1)
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 6)
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 8)
    }

    func testTheWindowIsNeverExceeded() throws {
        let nonces = NonceAllocator()
        XCTAssertEqual(try (0..<24).map { _ in try nonces.reserve(Self.account, chain: Self.chain(0)) }, Array(1...24))
        XCTAssertThrowsError(try nonces.reserve(Self.account, chain: Self.chain(0))) { error in
            XCTAssertEqual((error as? WillowError)?.type, .transaction)
            XCTAssertTrue("\(error)".contains("window is full"), "\(error)")
        }
        nonces.settle(Self.account, nonce: 17, .givenBack)
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(0)), 17)
        // Nonces the chain shows used fill the window too.
        let other = NonceAllocator()
        XCTAssertThrowsError(try other.reserve(Self.account, chain: Self.chain(0, used: Set(1...24))))
    }

    func testAnOlderAnswerHandsOutNoUsedNonce() throws {
        let nonces = NonceAllocator()
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 6)
        // 6 landed, and 8; then a slower answer from before both arrives.
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(6, used: [8])), 7)
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 9)
    }

    func testAccountsAreOneDIDAtOneAPI() throws {
        XCTAssertEqual(NonceAccount(did: "did:willow:a", api: "HTTP://API.test/"), Self.account)
        XCTAssertEqual(NonceAccount(did: "did:willow:a", api: "https://api.test:443/v1/"), NonceAccount(did: "did:willow:a", api: "https://api.test/v1"))
        XCTAssertNotEqual(NonceAccount(did: "did:willow:a", api: "http://other.test"), Self.account)
        XCTAssertNotEqual(NonceAccount(did: "did:willow:b", api: "http://api.test"), Self.account)
        // Two accounts keep separate nonces.
        let nonces = NonceAllocator()
        XCTAssertEqual(try nonces.reserve(Self.account, chain: Self.chain(5)), 6)
        XCTAssertEqual(try nonces.reserve(NonceAccount(did: "did:willow:a", api: "http://other.test"), chain: Self.chain(5)), 6)
    }

    func testOutcomesAreReadFromTheAnswer() {
        XCTAssertEqual(NonceOutcome.refusal("Nonce 7 of did:willow:a is held by a pending transaction; sign this one with another nonce"), .held)
        XCTAssertEqual(NonceOutcome.refusal("Invalid nonce: 7 already used (replay)"), .used)
        XCTAssertEqual(NonceOutcome.refusal("Subgrove not found (nonce 7 spent)"), .used)
        XCTAssertEqual(NonceOutcome.refusal("Invalid nonce: 3 <= base nonce 5"), .used)
        XCTAssertEqual(NonceOutcome.refusal("Invalid nonce: 40 is too far ahead (base=5, max=29)"), .givenBack)
        XCTAssertEqual(NonceOutcome.refusal("Signature verification failed"), .givenBack)

        let accepted = BroadcastResult(success: true, txHash: "AB")
        let refused = BroadcastResult(success: false, txHash: "AB", errorCode: 1, errorMessage: "Invalid nonce: 7 already used (replay)")
        let gatewayError = BroadcastResult(success: false, errorMessage: "CometBFT RPC error -32603: tx already exists in cache")
        XCTAssertEqual(NonceOutcome.submission(status: 200, result: accepted), .accepted)
        XCTAssertEqual(NonceOutcome.submission(status: 200, result: refused), .used)
        XCTAssertEqual(NonceOutcome.submission(status: 400, result: BroadcastResult(success: false)), .givenBack)
        XCTAssertEqual(NonceOutcome.submission(status: 408, result: BroadcastResult(success: false)), .unknown)
        XCTAssertEqual(NonceOutcome.submission(status: 502, result: gatewayError), .unknown)

        XCTAssertEqual(NonceOutcome.submission(error: TransactionError(message: "Insufficient balance", errorCode: 1)), .givenBack)
        XCTAssertEqual(NonceOutcome.submission(error: TransactionError(message: "Nonce 7 of did:willow:a is held by a pending transaction", errorCode: 1)), .held)
        XCTAssertEqual(NonceOutcome.submission(error: HTTPError(statusCode: 429, message: "slow down")), .givenBack)
        XCTAssertEqual(NonceOutcome.submission(error: HTTPError(statusCode: 503, message: "unavailable")), .unknown)
        XCTAssertEqual(NonceOutcome.submission(error: URLError(.timedOut)), .unknown)
    }

    func testTheNodesNonceStateIsRead() throws {
        XCTAssertEqual(try ChainNonces(nonceState: Data()), try Self.chain(0))
        var base = withUnsafeBytes(of: UInt64(2_092).bigEndian, Array.init)
        XCTAssertEqual(try ChainNonces(nonceState: Data(base)), try Self.chain(2_092))
        base += [0b0000_0101, 0, 0b1000_0000]
        XCTAssertEqual(try ChainNonces(nonceState: Data(base)), try Self.chain(2_092, used: [2_093, 2_095, 2_116]))
        XCTAssertThrowsError(try ChainNonces(nonceState: Data([1, 2, 3])))
        XCTAssertThrowsError(try ChainNonces(nonceState: Data(repeating: 0xFF, count: 11))) { error in
            XCTAssertEqual((error as? WillowError)?.type, .validation)
        }
    }

    // MARK: - Writes

    func testConcurrentWritesTakeDistinctNonces() async throws {
        let chain = FakeChain(base: 5)
        chain.pending = true
        let stub = Self.stub(chain)
        let nonces = NonceAllocator()
        let client = try stub.client(baseURL: "http://api.test", nonces: nonces)
        client.setIdentity(try Self.identity())
        let consensus = Self.consensus(stub, nonces)
        let keyPair = try SignedMessagesTests.keyPair(.ed25519)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask { try await self.store(client, "client-\(i)") }
                group.addTask {
                    let result = try await consensus.storeData(
                        subgroveId: "sg", key: "consensus-\(i)", data: ["n": i], ownerDid: "did:willow:a",
                        privateKey: keyPair.privateKey, publicKeyId: "did:willow:a#key-1",
                        signFunction: { message, _ in try keyPair.sign(message) }
                    )
                    XCTAssertTrue(result.success)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(chain.sent.sorted(), Array(6...17))
    }

    /// With 6 in flight, a write under 7 is refused at CheckTx: 7 is given
    /// back, and the next write takes it while 6 stays held.
    func testAWriteRefusedAtCheckTxGivesItsNonceBack() async throws {
        let chain = FakeChain(base: 5)
        chain.pending = true
        let stub = Self.stub(chain)
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(try Self.identity())

        try await store(client, "a")
        chain.refuseOnce(7, "Insufficient balance for the write fee")
        do {
            try await store(client, "b")
            XCTFail("the write under 7 must be refused")
        } catch is TransactionError {}
        try await store(client, "b")
        try await store(client, "c")
        XCTAssertEqual(chain.sent, [6, 7, 7, 8])
    }

    /// A refusal that says the nonce is held by a pending transaction keeps
    /// it held; one that says it is already used marks it used, so no later
    /// write signs under it again.
    func testARefusalThatSaysTheNonceIsTakenKeepsIt() async throws {
        let clock = Clock()
        let chain = FakeChain(base: 5)
        chain.refuseOnce(6, "Nonce 6 of did:willow:a is held by a pending transaction; sign this one with another nonce")
        chain.use(7) // another device's write
        let stub = Self.stub(chain)
        let client = try stub.client(baseURL: "http://api.test", nonces: NonceAllocator(now: { clock.now }))
        client.setIdentity(try Self.identity())

        for key in ["a", "b"] {
            do {
                try await store(client, key)
                XCTFail("\(key) must be refused")
            } catch is TransactionError {}
        }
        try await store(client, "c")
        XCTAssertEqual(chain.sent, [6, 7, 8])
        // 6's hold lapses; 7 is never signed under again.
        clock.advance(NonceAllocator.lease)
        try await store(client, "d")
        try await store(client, "e")
        XCTAssertEqual(chain.sent, [6, 7, 8, 6, 9])
    }

    /// Writes whose transactions never land: the client signs no nonce above
    /// the window, fails while all 24 are held, and hands out a nonce again
    /// once its hold lapses.
    func testWritesThatNeverLandDontLockTheAccount() async throws {
        let clock = Clock()
        let chain = FakeChain(base: 5)
        chain.pending = true
        let stub = Self.stub(chain)
        let client = try stub.client(baseURL: "http://api.test", nonces: NonceAllocator(now: { clock.now }))
        client.setIdentity(try Self.identity())

        for i in 0..<24 {
            try await store(client, "k\(i)")
        }
        XCTAssertEqual(chain.sent, Array(6...29))
        do {
            try await store(client, "k24")
            XCTFail("a write beyond the window must fail")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .transaction)
            XCTAssertTrue(error.message.contains("window is full"), error.message)
        }
        XCTAssertEqual(chain.sent.count, 24)

        clock.advance(NonceAllocator.lease)
        try await store(client, "k24")
        XCTAssertEqual(chain.sent.last, 6)
        XCTAssertLessThanOrEqual(chain.sent.max() ?? 0, 29)
    }

    /// The consensus client reads which nonces above the base are used, and
    /// skips them; without that query it reads the base from the API, and a
    /// refusal that says the nonce is used moves it past.
    func testTheConsensusClientSkipsNoncesTheChainShowsUsed() async throws {
        let keyPair = try SignedMessagesTests.keyPair(.ed25519)
        for answersNonceState in [true, false] {
            let chain = FakeChain(base: 5)
            chain.answersNonceState = answersNonceState
            chain.pending = true
            chain.use(7)
            let stub = Self.stub(chain)
            let consensus = Self.consensus(stub, NonceAllocator())
            var results: [Bool] = []
            for i in 0..<3 {
                let result = try await consensus.storeData(
                    subgroveId: "sg", key: "k\(i)", data: ["n": i], ownerDid: "did:willow:a",
                    privateKey: keyPair.privateKey, publicKeyId: "did:willow:a#key-1",
                    signFunction: { message, _ in try keyPair.sign(message) }
                )
                results.append(result.success)
            }
            if answersNonceState {
                XCTAssertEqual(chain.sent, [6, 8, 9])
                XCTAssertEqual(results, [true, true, true])
            } else {
                XCTAssertEqual(chain.sent, [6, 7, 8])
                XCTAssertEqual(results, [true, false, true])
            }
        }
    }

    /// The client's writes, the consensus client's, and key grants take
    /// their nonces from one allocator: none of them shares one.
    func testEveryWriteForOneAccountSharesOneAllocator() async throws {
        let chain = FakeChain(base: 5)
        chain.pending = true
        let stub = Self.stub(chain)
        let nonces = NonceAllocator()
        let identity = try Self.identity()
        let client = try stub.client(baseURL: "http://api.test", nonces: nonces)
        client.setIdentity(identity)
        // The same API, spelled differently.
        let consensus = Self.consensus(stub, nonces, api: "http://API.test/")
        let privacy = PrivacyOperations(client: client, consensus: consensus)
        let sign: (Data, Data) throws -> Data = { message, _ in try identity.sign(message) }
        let grant = EncryptedKeyGrant(
            granteeDid: "did:willow:b", keyEpoch: 1, granteePublicKeyId: "did:willow:b#key-1",
            ephemeralPublicKey: [1], encryptedKey: [2], grantedBy: "did:willow:a", grantedAt: 1
        )

        try await store(client, "a")
        _ = try await consensus.storeData(
            subgroveId: "sg", key: "b", data: ["n": 1], ownerDid: "did:willow:a",
            privateKey: Data(), publicKeyId: "did:willow:a#key-1", signFunction: sign
        )
        _ = try await privacy.grantSubgroveKey(subgroveId: "sg", grant: grant, privateKey: Data(), signFunction: sign)
        _ = try await privacy.rotateSubgroveKey(subgroveId: "sg", newEpoch: 2, newGrants: [grant], privateKey: Data(), signFunction: sign)
        _ = try await privacy.revokeSubgroveKey(subgroveId: "sg", revokeeDid: "did:willow:b", privateKey: Data(), signFunction: sign)
        _ = try await consensus.registerSubgrove(
            subgroveId: "notes", schema: "{}", ownerDid: "did:willow:a", privateKey: Data(),
            publicKeyId: "did:willow:a#key-1", signFunction: sign
        )
        try await client.registration.deleteSubgrove(subgroveId: "notes")
        XCTAssertEqual(chain.sent, Array(6...12))
    }
}
