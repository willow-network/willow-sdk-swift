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
}
