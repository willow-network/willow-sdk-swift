import XCTest
@testable import Willow

final class LightClientTests: XCTestCase {

    // MARK: - TrustThreshold Tests

    func testTrustThresholdDefault() {
        let threshold = TrustThreshold()

        XCTAssertEqual(threshold.numerator, 2)
        XCTAssertEqual(threshold.denominator, 3)
    }

    func testTrustThresholdCustom() {
        let threshold = TrustThreshold(numerator: 1, denominator: 2)

        XCTAssertEqual(threshold.numerator, 1)
        XCTAssertEqual(threshold.denominator, 2)
    }

    func testTrustThresholdValidate() {
        let threshold = TrustThreshold(numerator: 2, denominator: 3)

        // 70 / 100 >= 2/3 (66.67%) -> true
        XCTAssertTrue(threshold.validate(votingPower: 70, totalPower: 100))

        // 67 / 100 >= 2/3 (66.67%) -> true
        XCTAssertTrue(threshold.validate(votingPower: 67, totalPower: 100))

        // 66 / 100 < 2/3 (66.67%) -> false
        XCTAssertFalse(threshold.validate(votingPower: 66, totalPower: 100))

        // 50 / 100 < 2/3 -> false
        XCTAssertFalse(threshold.validate(votingPower: 50, totalPower: 100))
    }

    func testTrustThresholdValidateEdgeCases() {
        let threshold = TrustThreshold(numerator: 2, denominator: 3)

        // Zero total power
        XCTAssertTrue(threshold.validate(votingPower: 0, totalPower: 0))

        // Full voting power
        XCTAssertTrue(threshold.validate(votingPower: 100, totalPower: 100))
    }

    // MARK: - LightClientConfig Tests

    func testLightClientConfigDefault() {
        let config = LightClientConfig.default

        XCTAssertEqual(config.chainId, "willow-1")
        XCTAssertTrue(config.validatorEndpoints.isEmpty)
    }

    func testLightClientConfigCustom() {
        let config = LightClientConfig(
            chainId: "willow-testnet",
            validatorEndpoints: ["http://localhost:26657", "http://localhost:26757"],
            trustThreshold: TrustThreshold(numerator: 1, denominator: 2),
            trustingPeriod: 12 * 60 * 60,
            maxClockDrift: 5,
            minValidatorsForConsensus: 2,
            autoSync: false,
            syncInterval: 60
        )

        XCTAssertEqual(config.chainId, "willow-testnet")
        XCTAssertEqual(config.validatorEndpoints.count, 2)
        XCTAssertEqual(config.trustThreshold.numerator, 1)
        XCTAssertEqual(config.trustingPeriod, 12 * 60 * 60)
        XCTAssertEqual(config.maxClockDrift, 5)
        XCTAssertEqual(config.minValidatorsForConsensus, 2)
        XCTAssertFalse(config.autoSync)
        XCTAssertEqual(config.syncInterval, 60)
    }

    // MARK: - LightClientValidator Tests

    func testLightClientValidator() {
        let validator = LightClientValidator(
            address: "abc123",
            publicKey: "pubkey456",
            votingPower: 1000
        )

        XCTAssertEqual(validator.address, "abc123")
        XCTAssertEqual(validator.publicKey, "pubkey456")
        XCTAssertEqual(validator.votingPower, 1000)
    }

    func testLightClientValidatorEquality() {
        let v1 = LightClientValidator(address: "abc", publicKey: "pk", votingPower: 100)
        let v2 = LightClientValidator(address: "abc", publicKey: "pk", votingPower: 100)
        let v3 = LightClientValidator(address: "xyz", publicKey: "pk", votingPower: 100)

        XCTAssertEqual(v1, v2)
        XCTAssertNotEqual(v1, v3)
    }

    // MARK: - ValidatorSet Tests

    func testValidatorSetEmpty() {
        let set = ValidatorSet(validators: [])

        XCTAssertTrue(set.validators.isEmpty)
        XCTAssertEqual(set.getTotalVotingPower(), 0)
    }

    func testValidatorSetTotalVotingPower() {
        let validators = [
            LightClientValidator(address: "a", publicKey: "pk1", votingPower: 100),
            LightClientValidator(address: "b", publicKey: "pk2", votingPower: 200),
            LightClientValidator(address: "c", publicKey: "pk3", votingPower: 300)
        ]
        let set = ValidatorSet(validators: validators)

        XCTAssertEqual(set.getTotalVotingPower(), 600)
    }

    func testValidatorSetWithStoredTotal() {
        let validators = [
            LightClientValidator(address: "a", publicKey: "pk1", votingPower: 100)
        ]
        let set = ValidatorSet(validators: validators, totalVotingPower: 500)

        // Should use stored value
        XCTAssertEqual(set.getTotalVotingPower(), 500)
    }

    func testValidatorSetWithZeroStoredTotal() {
        let validators = [
            LightClientValidator(address: "a", publicKey: "pk1", votingPower: 100)
        ]
        let set = ValidatorSet(validators: validators, totalVotingPower: 0)

        // Should calculate from validators
        XCTAssertEqual(set.getTotalVotingPower(), 100)
    }

    // MARK: - Header Tests

    func testHeaderCreation() {
        let header = Header(
            chainId: "willow-1",
            height: 12345,
            time: Date(),
            appHash: "abcd1234"
        )

        XCTAssertEqual(header.chainId, "willow-1")
        XCTAssertEqual(header.height, 12345)
        XCTAssertEqual(header.appHash, "abcd1234")
    }

    // MARK: - Commit Tests

    func testCommitCreation() {
        let commit = Commit(height: 100, round: 0)

        XCTAssertEqual(commit.height, 100)
        XCTAssertEqual(commit.round, 0)
        XCTAssertNil(commit.blockId)
        XCTAssertNil(commit.signatures)
    }

    // MARK: - CommitSig Tests

    func testCommitSigIsAbsent() throws {
        let jsonAbsent = """
        {"block_id_flag": 1}
        """
        let decoder = JSONDecoder()
        // CommitSig has explicit CodingKeys, so no need for convertFromSnakeCase
        let sig = try decoder.decode(CommitSig.self, from: jsonAbsent.data(using: .utf8)!)

        XCTAssertTrue(sig.isAbsent)
        XCTAssertFalse(sig.isCommit)
    }

    func testCommitSigIsCommit() throws {
        let jsonCommit = """
        {"block_id_flag": 2, "validator_address": "abc123"}
        """
        let decoder = JSONDecoder()
        // CommitSig has explicit CodingKeys, so no need for convertFromSnakeCase
        let sig = try decoder.decode(CommitSig.self, from: jsonCommit.data(using: .utf8)!)

        XCTAssertFalse(sig.isAbsent)
        XCTAssertTrue(sig.isCommit)
        XCTAssertEqual(sig.validatorAddress, "abc123")
    }

    // MARK: - BlockID Tests

    func testBlockIDCreation() {
        let blockId = BlockID(hash: "blockhash123")

        XCTAssertEqual(blockId.hash, "blockhash123")
        XCTAssertNil(blockId.partSetHeader)
    }

    func testBlockIDEquality() {
        let b1 = BlockID(hash: "abc")
        let b2 = BlockID(hash: "abc")
        let b3 = BlockID(hash: "xyz")

        XCTAssertEqual(b1, b2)
        XCTAssertNotEqual(b1, b3)
    }

    // MARK: - TrustedHeader Tests

    func testTrustedHeaderCreation() {
        let header = TrustedHeader(height: 1000, appHash: "apphash123")

        XCTAssertEqual(header.height, 1000)
        XCTAssertEqual(header.appHash, "apphash123")
        XCTAssertNotNil(header.trustedAt)
    }

    // MARK: - SyncStatus Tests

    func testSyncStatusDefault() {
        let status = SyncStatus()

        XCTAssertEqual(status.latestTrustedHeight, 0)
        XCTAssertEqual(status.latestKnownHeight, 0)
        XCTAssertFalse(status.isSynced)
        XCTAssertNil(status.lastSyncAttempt)
        XCTAssertNil(status.lastSyncError)
    }

    func testSyncStatusSynced() {
        let status = SyncStatus(
            latestTrustedHeight: 100,
            latestTrustedTime: Date(),
            latestKnownHeight: 100,
            isSynced: true
        )

        XCTAssertEqual(status.latestTrustedHeight, 100)
        XCTAssertTrue(status.isSynced)
    }

    // MARK: - LightClient Creation Tests

    func testLightClientRequiresEndpoints() {
        let config = LightClientConfig(
            chainId: "test",
            validatorEndpoints: []
        )

        XCTAssertThrowsError(try LightClient(config)) { error in
            XCTAssertTrue(error is WillowError)
        }
    }

    func testLightClientCreation() throws {
        let config = LightClientConfig(
            chainId: "test",
            validatorEndpoints: ["http://localhost:26657"],
            autoSync: false
        )

        let lc = try LightClient(config)
        XCTAssertNotNil(lc)

        let status = lc.getSyncStatus()
        XCTAssertEqual(status.latestTrustedHeight, 0)
    }

    func testLightClientWithTrustedHeader() throws {
        let config = LightClientConfig(
            chainId: "test",
            validatorEndpoints: ["http://localhost:26657"],
            autoSync: false
        )

        let trustedHeader = TrustedHeader(
            height: 1000,
            appHash: "abc123def456",
            trustedAt: Date()
        )

        let validators = [
            LightClientValidator(address: "val1", publicKey: "pk1", votingPower: 100)
        ]
        let validatorSet = ValidatorSet(validators: validators)

        let lc = try LightClient(config, trustedHeader: trustedHeader, validatorSet: validatorSet)
        XCTAssertNotNil(lc)

        let status = lc.getSyncStatus()
        XCTAssertEqual(status.latestTrustedHeight, 1000)
        XCTAssertTrue(status.isSynced)
    }

    func testLightClientWithTrustedState() throws {
        let config = LightClientConfig(
            chainId: "test",
            validatorEndpoints: ["http://localhost:26657"],
            autoSync: false
        )

        let trustedHeader = TrustedHeader(
            height: 2000,
            appHash: "xyz789",
            trustedAt: Date()
        )

        let validators = [
            LightClientValidator(address: "val1", publicKey: "pk1", votingPower: 100),
            LightClientValidator(address: "val2", publicKey: "pk2", votingPower: 200)
        ]
        let validatorSet = ValidatorSet(validators: validators)
        let trustedState = TrustedState(header: trustedHeader, validatorSet: validatorSet)

        let lc = try LightClient(config, trustedState: trustedState)
        XCTAssertNotNil(lc)

        let status = lc.getSyncStatus()
        XCTAssertEqual(status.latestTrustedHeight, 2000)
        XCTAssertTrue(status.isSynced)

        // Export should return the same state
        let exported = try lc.exportTrustedState()
        XCTAssertEqual(exported.header.height, 2000)
        XCTAssertEqual(exported.validatorSet.validators.count, 2)
    }

    func testLightClientRejectsExpiredTrustedHeader() throws {
        let config = LightClientConfig(
            chainId: "test",
            validatorEndpoints: ["http://localhost:26657"],
            trustingPeriod: 60, // 60 seconds
            autoSync: false
        )

        // Create a header that's expired (older than trusting period)
        let expiredHeader = TrustedHeader(
            height: 1000,
            appHash: "abc123",
            trustedAt: Date().addingTimeInterval(-120) // 2 minutes ago
        )

        let validatorSet = ValidatorSet(validators: [
            LightClientValidator(address: "val1", publicKey: "pk1", votingPower: 100)
        ])

        XCTAssertThrowsError(try LightClient(config, trustedHeader: expiredHeader, validatorSet: validatorSet)) { error in
            XCTAssertTrue(error is WillowError)
            if let willowError = error as? WillowError {
                XCTAssertTrue(willowError.message.contains("expired"))
            }
        }
    }

    func testLightClientRejectsExpiredTrustedState() throws {
        let config = LightClientConfig(
            chainId: "test",
            validatorEndpoints: ["http://localhost:26657"],
            trustingPeriod: 60, // 60 seconds
            autoSync: false
        )

        // Create a state that's expired
        let expiredState = TrustedState(
            header: TrustedHeader(
                height: 1000,
                appHash: "abc123",
                trustedAt: Date().addingTimeInterval(-120) // 2 minutes ago
            ),
            validatorSet: ValidatorSet(validators: [
                LightClientValidator(address: "val1", publicKey: "pk1", votingPower: 100)
            ])
        )

        XCTAssertThrowsError(try LightClient(config, trustedState: expiredState)) { error in
            XCTAssertTrue(error is WillowError)
            if let willowError = error as? WillowError {
                XCTAssertTrue(willowError.message.contains("expired"))
            }
        }
    }

    // MARK: - Verification Result Tests

    func testLightClientVerificationResult() {
        let result = LightClientVerificationResult(
            verified: true,
            height: 100,
            appHash: "abc123",
            votingPower: 70,
            totalPower: 100,
            signatureCount: 3
        )

        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.height, 100)
        XCTAssertEqual(result.appHash, "abc123")
        XCTAssertEqual(result.votingPower, 70)
        XCTAssertEqual(result.totalPower, 100)
        XCTAssertEqual(result.signatureCount, 3)
        XCTAssertNil(result.error)
    }

    func testLightClientVerificationResultWithError() {
        let result = LightClientVerificationResult(
            verified: false,
            height: 100,
            appHash: "abc123",
            error: "Chain ID mismatch"
        )

        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.error, "Chain ID mismatch")
    }

    // MARK: - ProofVerificationResult Tests

    func testProofVerificationResult() {
        let result = ProofVerificationResult(
            verified: true,
            rootHash: "roothash",
            expectedHash: "expected",
            height: 500
        )

        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.rootHash, "roothash")
        XCTAssertEqual(result.expectedHash, "expected")
        XCTAssertEqual(result.height, 500)
    }

    // MARK: - Accepting headers

    static func pinned(height: Int64, appHash: String, headerTime: Date? = nil, stub: StubServer, chainId: String = "willow-chain") throws -> LightClient {
        let config = LightClientConfig(chainId: chainId, validatorEndpoints: ["http://rpc.test"], autoSync: false, headerWaitTimeout: 0.3)
        let state = TrustedState(
            header: TrustedHeader(height: height, appHash: appHash, trustedAt: Date(), headerTime: headerTime),
            validatorSet: ValidatorSet(validators: []))
        let lc = try LightClient(config, trustedState: state)
        lc.session = stub.session
        return lc
    }

    func testAHeaderMayBeOldButNotFromTheFuture() throws {
        let config = LightClientConfig(chainId: "c", validatorEndpoints: ["http://rpc.test"], maxClockDrift: 10, autoSync: false)
        let lc = try LightClient(config)
        let anchor = TrustedState(header: TrustedHeader(height: 1, appHash: "00", trustedAt: Date()), validatorSet: ValidatorSet(validators: []))
        let signature = try JSONDecoder().decode(CommitSig.self, from: Data(#"{"block_id_flag":2,"validator_address":"v"}"#.utf8))
        func block(_ time: Date) -> LightBlock {
            return LightBlock(
                header: Header(chainId: "c", height: 2, time: time, appHash: "aa"),
                validatorSet: ValidatorSet(validators: [LightClientValidator(address: "v", publicKey: "p", votingPower: 10)]),
                commit: Commit(height: 2, round: 0, signatures: [signature]))
        }
        // The header after a proof's block may be read long after it was
        // made, so it can be hours old.
        XCTAssertTrue(try lc.verify(block: block(Date().addingTimeInterval(-6 * 3600)), trustedState: anchor).verified)
        XCTAssertTrue(try lc.verify(block: block(Date().addingTimeInterval(5)), trustedState: anchor).verified)
        let future = try lc.verify(block: block(Date().addingTimeInterval(60)), trustedState: anchor)
        XCTAssertFalse(future.verified)
        XCTAssertTrue(future.error?.contains("Clock drift") ?? false, future.error ?? "")
    }

    func testHeadersAreAcceptedOutOfOrderAndAgainAtTheSameHeight() async throws {
        let now = Date()
        let chain = StubChain(headers: [
            42: ("42" + String(repeating: "0", count: 62), now.addingTimeInterval(-500)),
            43: ("43" + String(repeating: "0", count: 62), now.addingTimeInterval(-400)),
            45: ("45" + String(repeating: "0", count: 62), now.addingTimeInterval(-200)),
        ])
        let stub = StubServer(chain.answer)
        let lc = try Self.pinned(height: 40, appHash: "00", headerTime: now.addingTimeInterval(-600), stub: stub)

        let at45 = try await lc.verifiedAppHash(atHeight: 45)
        XCTAssertEqual(at45, chain.headers[45]!.appHash)
        // Below the trusted header, checked against the header at 40.
        let at42 = try await lc.verifiedAppHash(atHeight: 42)
        XCTAssertEqual(at42, chain.headers[42]!.appHash)
        XCTAssertEqual(lc.getSyncStatus().latestTrustedHeight, 45)

        // Two reads of the same header at once both succeed.
        async let first = lc.verifiedAppHash(atHeight: 43)
        async let second = lc.verifiedAppHash(atHeight: 43)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)

        // A root any accepted header at or after the next height carries is
        // the chain's state then; no header is fetched.
        let fetched = stub.requests.count
        let carrying45 = try await lc.verifyAppHash(chain.headers[45]!.appHash.uppercased(), forStateAfter: 41)
        XCTAssertEqual(carrying45, 45)
        let carrying42 = try await lc.verifyAppHash(chain.headers[42]!.appHash, forStateAfter: 41)
        XCTAssertEqual(carrying42, 42)
        XCTAssertEqual(stub.requests.count, fetched)
        // The header at the next height carries another root.
        do {
            _ = try await lc.verifyAppHash(String(repeating: "ff", count: 32), forStateAfter: 41)
            XCTFail("no accepted header carries that root")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .proof)
        }

        // A header served again at an accepted height must carry the same app hash.
        let forked = StubChain(headers: [42: (String(repeating: "ee", count: 32), now.addingTimeInterval(-500))])
        let stub2 = StubServer(forked.answer)
        lc.session = stub2.session
        do {
            try await lc.syncTo(height: 42)
            XCTFail("another header at an accepted height")
        } catch let error as WillowError {
            XCTAssertTrue(error.message.contains("carries app hash"), error.message)
        }

        // A header out of order must be earlier than the accepted one above it.
        let late = StubChain(headers: [44: (String(repeating: "dd", count: 32), now.addingTimeInterval(-100))])
        let stub3 = StubServer(late.answer)
        lc.session = stub3.session
        do {
            _ = try await lc.verifiedAppHash(atHeight: 44)
            XCTFail("a header later than the one above it")
        } catch let error as WillowError {
            XCTAssertTrue(error.message.contains("not earlier"), error.message)
        }
    }

    func testSyncingToTheTrustedHeaderIsNotAnError() async throws {
        let chain = StubChain(headers: [40: (String(repeating: "aa", count: 32), Date().addingTimeInterval(-60))])
        let stub = StubServer(chain.answer)
        let lc = try Self.pinned(height: 40, appHash: String(repeating: "AA", count: 32), stub: stub)
        try await lc.sync()
        XCTAssertEqual(lc.getSyncStatus().latestTrustedHeight, 40)
        XCTAssertEqual(stub.requests.map { $0.target }, ["/commit", "/validators?height=40&page=1&per_page=100"])
    }

    func testImportingAStateReplacesTheAcceptedHeaders() async throws {
        let stub = StubServer { _ in (404, "") }
        let old = String(repeating: "aa", count: 32)
        let lc = try Self.pinned(height: 50, appHash: old, stub: stub)
        let carrying = try await lc.verifyAppHash(old, forStateAfter: 41)
        XCTAssertEqual(carrying, 50)

        let imported = String(repeating: "bb", count: 32)
        try lc.importTrustedState(TrustedState(
            header: TrustedHeader(height: 60, appHash: imported, trustedAt: Date()), validatorSet: ValidatorSet(validators: [])))
        XCTAssertEqual(try lc.exportTrustedState().header.appHash, imported)
        let at60 = try await lc.verifiedAppHash(atHeight: 60)
        XCTAssertEqual(at60, imported)
        for height: Int64 in [50, 42] {
            do {
                _ = try await lc.verifiedAppHash(atHeight: height)
                XCTFail("the header at \(height) is no longer accepted")
            } catch let error as WillowError {
                XCTAssertTrue(error.message.contains("below every header"), error.message)
            }
        }
        do {
            _ = try await lc.verifyAppHash(old, forStateAfter: 41)
            XCTFail("the header at 50 is no longer accepted")
        } catch {}
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testEveryPageOfTheValidatorSetIsRead() async throws {
        let chain = StubChain(headers: [42: (String(repeating: "cc", count: 32), Date().addingTimeInterval(-30))], validators: 150)
        let stub = StubServer(chain.answer)
        let lc = try Self.pinned(height: 41, appHash: "00", stub: stub)
        let at42 = try await lc.verifiedAppHash(atHeight: 42)
        XCTAssertEqual(at42, chain.headers[42]!.appHash)
        XCTAssertEqual(stub.requests.map { $0.target }, [
            "/commit?height=42", "/validators?height=42&page=1&per_page=100", "/validators?height=42&page=2&per_page=100",
        ])
    }

    // MARK: - CometBFT's JSON

    func testRFC3339Times() throws {
        XCTAssertEqual(RFC3339.date(from: "1970-01-01T00:00:00Z")?.timeIntervalSince1970, 0)
        XCTAssertEqual(try XCTUnwrap(RFC3339.date(from: "1970-01-02T03:04:05.123456789Z")).timeIntervalSince1970, 97445.123456789, accuracy: 1e-6)
        XCTAssertEqual(RFC3339.date(from: "1970-01-01T07:00:00+07:00")?.timeIntervalSince1970, 0)
        XCTAssertEqual(RFC3339.date(from: "1969-12-31T19:00:00.5-05:00")?.timeIntervalSince1970, 0.5)
        XCTAssertEqual(RFC3339.date(from: "2000-03-01T00:00:00Z")?.timeIntervalSince1970, 951868800)
        XCTAssertNotNil(RFC3339.date(from: "0001-01-01T00:00:00Z"))
        for bad in ["1970-13-01T00:00:00Z", "1970-01-01 00:00:00Z", "1970-01-01T00:00:00", "1970-01-01T00:00:00.Z", "1970-01-01T00:00:00Zx"] {
            XCTAssertNil(RFC3339.date(from: bad), bad)
        }
    }

    func testHeadersAndCommitsDecodeAsCometBFTWritesThem() throws {
        let time = Date().addingTimeInterval(-10)
        let chain = StubChain(headers: [7: (String(repeating: "AB", count: 32), time)])
        let request = ReceivedRequest(method: "GET", url: URL(string: "http://rpc.test/commit?height=7")!, fields: [:], body: Data())
        struct Response: Decodable {
            struct Result: Decodable { let signed_header: SignedHeader }
            struct SignedHeader: Decodable { let header: Header; let commit: Commit }
            let result: Result
        }
        let decoded = try JSONDecoder().decode(Response.self, from: Data(chain.answer(request).1.utf8)).result.signed_header
        XCTAssertEqual(decoded.header.height, 7)
        XCTAssertEqual(decoded.header.chainId, "willow-chain")
        XCTAssertEqual(decoded.header.appHash, String(repeating: "AB", count: 32))
        XCTAssertEqual(decoded.header.time.timeIntervalSince1970, time.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(decoded.header.lastBlockId?.partSetHeader?.total, 1)
        XCTAssertEqual(decoded.commit.height, 7)
        XCTAssertEqual(decoded.commit.signatures?.map { $0.isCommit }, [true, false])
        let signed = try XCTUnwrap(decoded.commit.signatures?.first?.timestamp)
        XCTAssertEqual(signed.timeIntervalSince1970, time.timeIntervalSince1970 + 1, accuracy: 1e-6)
        XCTAssertNotNil(decoded.commit.signatures?.last?.timestamp, "CometBFT's zero time is RFC 3339 text")
    }
}

/// Answers CometBFT's `/commit` and `/validators` for the headers it holds,
/// in CometBFT's JSON (heights as strings, RFC 3339 times with nanoseconds),
/// every validator signing; a height it doesn't hold is one the chain hasn't
/// reached. With no height, `/commit` answers the highest.
struct StubChain {
    let chainId: String
    let headers: [Int64: (appHash: String, time: Date)]
    let validators: Int

    init(chainId: String = "willow-chain", headers: [Int64: (appHash: String, time: Date)], validators: Int = 1) {
        self.chainId = chainId
        self.headers = headers
        self.validators = validators
    }

    static func address(_ index: Int) -> String {
        return String(format: "%040X", index + 1)
    }

    static func rfc3339(_ date: Date) -> String {
        let whole = floor(date.timeIntervalSince1970)
        let nanos = Int(((date.timeIntervalSince1970 - whole) * 1e9).rounded())
        let base = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: whole))
        return String(base.dropLast()) + String(format: ".%09dZ", min(nanos, 999_999_999))
    }

    func answer(_ request: ReceivedRequest) -> (Int, String) {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> Int? { return items.first { $0.name == name }?.value.flatMap { Int($0) } }
        let height = item("height").map(Int64.init) ?? headers.keys.max() ?? 0
        guard let header = headers[height] else {
            return (500, #"{"jsonrpc":"2.0","id":-1,"error":{"code":-32603,"message":"Internal error","data":"height \#(height) must be less than or equal to the current blockchain height 1"}}"#)
        }
        let hash = String(repeating: "E3", count: 32)
        let parts = #"{"total":1,"hash":"\#(hash)"}"#
        switch request.path {
        case "/commit":
            let signatures = (0..<validators).map { index in
                #"{"block_id_flag":2,"validator_address":"\#(Self.address(index))","timestamp":"\#(Self.rfc3339(header.time.addingTimeInterval(1)))","signature":"c2lnbmF0dXJl"}"#
            } + [#"{"block_id_flag":1,"validator_address":"","timestamp":"0001-01-01T00:00:00Z","signature":null}"#]
            let body = #"""
            {"jsonrpc":"2.0","id":-1,"result":{"signed_header":{"header":{"version":{"block":"11","app":"1"},"chain_id":"\#(chainId)","height":"\#(height)","time":"\#(Self.rfc3339(header.time))","last_block_id":{"hash":"\#(hash)","parts":\#(parts)},"last_commit_hash":"\#(hash)","data_hash":"\#(hash)","validators_hash":"\#(hash)","next_validators_hash":"\#(hash)","consensus_hash":"\#(hash)","app_hash":"\#(header.appHash)","last_results_hash":"\#(hash)","evidence_hash":"\#(hash)","proposer_address":"\#(Self.address(0))"},"commit":{"height":"\#(height)","round":0,"block_id":{"hash":"\#(hash)","parts":\#(parts)},"signatures":[\#(signatures.joined(separator: ","))]}},"canonical":true}}
            """#
            return (200, body)
        case "/validators":
            let page = item("page") ?? 1
            let perPage = item("per_page") ?? 30
            let slice = (0..<validators).dropFirst((page - 1) * perPage).prefix(perPage)
            let entries = slice.map { index in
                #"{"address":"\#(Self.address(index))","pub_key":{"type":"tendermint/PubKeyEd25519","value":"AAAA"},"voting_power":"10","proposer_priority":"0"}"#
            }
            return (200, #"{"jsonrpc":"2.0","id":-1,"result":{"block_height":"\#(height)","validators":[\#(entries.joined(separator: ","))],"count":"\#(entries.count)","total":"\#(validators)"}}"#)
        default:
            return (404, "")
        }
    }
}
