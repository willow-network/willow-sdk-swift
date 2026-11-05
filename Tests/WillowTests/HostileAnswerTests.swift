import XCTest
@testable import Willow

/// Numbers a server supplies that the SDK sums, multiplies, or uses as a
/// length: each is refused or computed exactly, never trapping.
final class HostileAnswerTests: XCTestCase {

    static func validator(_ address: String, _ power: Int64) -> LightClientValidator {
        return LightClientValidator(address: address, publicKey: "AAAA", votingPower: power)
    }

    static func commitSig(_ address: String) throws -> CommitSig {
        let json = #"{"block_id_flag":2,"validator_address":"\#(address)","timestamp":"2025-01-01T00:00:00Z","signature":"c2ln"}"#
        return try JSONDecoder().decode(CommitSig.self, from: Data(json.utf8))
    }

    /// A light block at height 11 over `validators`, signed by `signers`, and
    /// the trusted state at height 10 it is checked against.
    static func block(_ validators: [LightClientValidator], signedBy signers: [String]) throws -> (LightBlock, TrustedState) {
        let now = Date()
        let header = Header(chainId: "willow-chain", height: 11, time: now.addingTimeInterval(-5), appHash: "AB")
        let commit = Commit(height: 11, round: 0, signatures: try signers.map { try commitSig($0) })
        let block = LightBlock(header: header, validatorSet: ValidatorSet(validators: validators), commit: commit)
        let trusted = TrustedState(
            header: TrustedHeader(height: 10, appHash: "AA", headerTime: now.addingTimeInterval(-10)),
            validatorSet: ValidatorSet(validators: validators))
        return (block, trusted)
    }

    static func lightClient() throws -> LightClient {
        return try LightClient(LightClientConfig(chainId: "willow-chain", validatorEndpoints: ["http://rpc.test"], autoSync: false))
    }

    /// One validator at voting power 2^62 that signs: three times its power
    /// overflowed `Int64` and trapped. CometBFT bounds a set's total at
    /// `Int64.max / 8`, so the set is refused.
    func testAVotingPowerThatWouldOverflowIsRefused() throws {
        let (block, trusted) = try Self.block([Self.validator("A1", 1 << 62)], signedBy: ["A1"])
        let result = try Self.lightClient().verify(block: block, trustedState: trusted)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.error?.contains("total voting power") ?? false, result.error ?? "")

        // Two validators whose powers sum past Int64.max.
        let (pair, pairTrusted) = try Self.block(
            [Self.validator("A1", Int64.max / 2 + 1), Self.validator("A2", Int64.max / 2 + 1)], signedBy: ["A1", "A2"])
        XCTAssertFalse(try Self.lightClient().verify(block: pair, trustedState: pairTrusted).verified)
        XCTAssertEqual(ValidatorSet(validators: pair.validatorSet.validators).getTotalVotingPower(), Int64.max)

        // A negative power, and one address listed twice.
        let (negative, negativeTrusted) = try Self.block(
            [Self.validator("A1", 10), Self.validator("A2", -5)], signedBy: ["A1"])
        XCTAssertFalse(try Self.lightClient().verify(block: negative, trustedState: negativeTrusted).verified)
        let (twice, twiceTrusted) = try Self.block(
            [Self.validator("A1", 10), Self.validator("a1", 10)], signedBy: ["A1"])
        XCTAssertFalse(try Self.lightClient().verify(block: twice, trustedState: twiceTrusted).verified)

        // The threshold compares the full products.
        XCTAssertTrue(TrustThreshold().validate(votingPower: Int64.max, totalPower: Int64.max))
        XCTAssertFalse(TrustThreshold().validate(votingPower: Int64.max / 3 * 2 - 1, totalPower: Int64.max))
        XCTAssertFalse(TrustThreshold(numerator: 2, denominator: 0).validate(votingPower: 1, totalPower: 1))
        XCTAssertFalse(TrustThreshold().validate(votingPower: -1, totalPower: 1))
    }

    /// A commit that names one validator many times counts its power once.
    func testEachValidatorCountsOnce() throws {
        let validators = [Self.validator("A1", 10), Self.validator("A2", 10), Self.validator("A3", 10)]
        let (block, trusted) = try Self.block(validators, signedBy: ["A1", "A1", "a1"])
        let result = try Self.lightClient().verify(block: block, trustedState: trusted)
        XCTAssertFalse(result.verified, "one validator of three signed")
        XCTAssertEqual(result.votingPower, 10)
        XCTAssertEqual(result.signatureCount, 1)

        let (enough, enoughTrusted) = try Self.block(validators, signedBy: ["A1", "A2", "A2"])
        let passed = try Self.lightClient().verify(block: enough, trustedState: enoughTrusted)
        XCTAssertTrue(passed.verified, passed.error ?? "")
        XCTAssertEqual(passed.votingPower, 20)
    }

    /// Through `data.get`: an RPC that serves a validator at 2^62 fails the
    /// read with a light client error instead of crashing the caller.
    func testAVerifiedReadRefusesAnRPCValidatorSetThatWouldOverflow() async throws {
        let f = try GroveDBProofTests.fixture("nested_single_key_user_bob", as: GroveDBProofTests.SingleKey.self)
        let chain = StubChain(headers: [42: (f.expected_root_hex, Date().addingTimeInterval(-30))], votingPower: "4611686018427387904")
        let stub = try VerifiedReadsTests.bobServer(height: 41, rpc: chain.answer)
        let client = try stub.client(baseURL: "http://api.test")
        client.setLightClient(try VerifiedReadsTests.pinnedLightClient(height: 41, appHash: "00", stub: stub))

        do {
            let response = try await client.data.get(subgroveId: "my-sub", key: "user:bob")
            XCTFail("a header from a set with an impossible voting power was accepted: \(response.data)")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .lightClient, error.message)
            XCTAssertTrue(error.message.contains("total voting power"), error.message)
        }

        // A negative power is refused as the set is read.
        let negativeChain = StubChain(headers: [42: (f.expected_root_hex, Date().addingTimeInterval(-30))], votingPower: "-1")
        let negativeStub = try VerifiedReadsTests.bobServer(height: 41, rpc: negativeChain.answer)
        let negative = try negativeStub.client(baseURL: "http://api.test")
        negative.setLightClient(try VerifiedReadsTests.pinnedLightClient(height: 41, appHash: "00", stub: negativeStub))
        do {
            _ = try await negative.data.get(subgroveId: "my-sub", key: "user:bob")
            XCTFail("a negative voting power was accepted")
        } catch let error as WillowError {
            XCTAssertEqual(error.type, .lightClient, error.message)
        }
    }

    /// An RLP length near `Int.max`, or one with its top bit set, is refused
    /// as past the input; adding it to an index overflowed or made a range
    /// that trapped.
    func testAnRLPLengthPastTheInputIsRefused() {
        for header: [UInt8] in [
            [0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            [0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0],
            [0xF9, 0xFF, 0xFF],
        ] {
            XCTAssertThrowsError(try rlpDecodeList(Data(header + [0x01, 0x02])), "\(header)")
        }
        // A string inside a list whose length is past the list.
        XCTAssertThrowsError(try rlpDecodeList(Data([0xCA, 0xBF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])))
        XCTAssertThrowsError(try rlpDecodeList(Data([0xCA, 0xBF, 0x80, 0, 0, 0, 0, 0, 0, 0, 0x01])))
        // A well-formed long list still reads.
        let long = [UInt8](repeating: 0x01, count: 60)
        XCTAssertEqual(try rlpDecodeList(Data([0xF8, 60] + long)).count, 60)
    }

    /// The node's own fee schedule (8.64e13 per byte) times a 512 KiB payload
    /// is past `UInt64`; the estimate is the exact product.
    func testFeeEstimatesDontOverflow() async throws {
        let stub = StubServer { _ in
            (200, #"""
            {"success":true,"data":{"did_registration":1,"subgrove_registration":1,"base_tx_cost":18446744073709551615,
             "cost_per_byte":86400000000000,"query_fee":1,"transfer_fee_percentage":10,
             "max_tx_size_bytes":67108864,"max_data_payload_bytes":524288},"error":null}
            """#)
        }
        let client = try stub.client(baseURL: "http://api.test")
        let storage = try await client.token.estimateStorageFee(dataSizeBytes: 524_288)
        XCTAssertEqual(storage, "45298483200000000000")
        let transaction = try await client.token.estimateTransactionFee(dataSizeBytes: UInt64.max)
        // (2^64 - 1) * 86400000000000 + (2^64 - 1)
        XCTAssertEqual(transaction, "1593798687968523706280073709551615")
    }

    /// Every session the SDK makes bounds a request's whole time, not only
    /// the wait between bytes (`URLSession`'s default resource timeout is 7
    /// days), so an endpoint that trickles an answer can't hold a read.
    func testEverySessionHasAResourceTimeout() {
        XCTAssertEqual(LightClient.makeSession(rpcTimeout: 10).configuration.timeoutIntervalForResource, 20)
        XCTAssertEqual(LightClient.makeSession(rpcTimeout: 10).configuration.timeoutIntervalForRequest, 10)
        let consensus = ConsensusClient.makeSession(ConsensusConfig(consensusRpcUrl: "http://rpc.test", requestTimeoutSecs: 7))
        XCTAssertEqual(consensus.configuration.timeoutIntervalForResource, 14)
        XCTAssertEqual(consensus.configuration.timeoutIntervalForRequest, 7)
        XCTAssertEqual(WillowClient.makeSession(timeout: 30).configuration.timeoutIntervalForResource, 60)
        let client = WillowClient(config: ClientConfig(baseURL: URL(string: "http://api.test")!, timeout: 5), session: URLSession.shared)
        XCTAssertEqual(client.storageSession.configuration.timeoutIntervalForResource, 10)
    }

    /// JSON nested `perLevel` arrays deep, around a serde raw value token
    /// holding the same, `levels` times, around `0`.
    static func rawNested(levels: Int, perLevel: Int = 125) -> String {
        var text = "0"
        for _ in 0..<levels {
            let wrapped = String(repeating: "[", count: perLevel) + text + String(repeating: "]", count: perLevel)
            text = #"{"$serde_json::private::RawValue":"# + String(decoding: WireJSON.string(wrapped).serialized, as: UTF8.self) + "}"
        }
        return text
    }

    /// serde_json gives each raw value token's text its own 127-level limit,
    /// so an item of 36 KB nests 1,638 levels. The reader recursed once per
    /// level, on a task's thread, and ran out of its stack. Nesting past 256
    /// levels in all is refused as not verifiable (a verified read can't
    /// reproduce the node's reading of it), not skipped and not read past
    /// the stack; 252 levels read, and a verified query returns them.
    func testDeepNestingAcrossRawValuesIsRefused() async throws {
        let deep = Self.rawNested(levels: 13)
        let deepest = Self.rawNested(levels: 16)
        let fits = Self.rawNested(levels: 2)
        let outcome: (deep: [String], fits: Int) = try await Task.detached {
            var deepOutcomes: [String] = []
            for text in [deep, deepest] {
                do {
                    _ = try NodeJSON.parse(Array(text.utf8))
                    deepOutcomes.append("parsed")
                } catch NodeJSON.ReadError.unsupported(let why) {
                    deepOutcomes.append("unsupported: \(why)")
                } catch {
                    deepOutcomes.append("\(error)")
                }
            }
            var current = try NodeJSON.parse(Array(fits.utf8))
            var depth = 0
            while case .array(let elements) = current, let first = elements.first {
                depth += 1
                current = first
            }
            return (deepOutcomes, depth)
        }.value
        for result in outcome.deep {
            XCTAssertTrue(result.hasPrefix("unsupported"), result)
        }
        XCTAssertEqual(outcome.fits, 250)
        XCTAssertThrowsError(try NodeJSON.parse(Array(Self.rawNested(levels: 3).utf8)), "378 levels")

        // A verified query and get over an item that deep: not verifiable,
        // neither skipped nor read as bytes.
        let tree = VerifiedReadsTests.dataTree([("a", #"{"n":"# + deep + "}"), ("b", #"{"n":1}"#)])
        let shallow = VerifiedReadsTests.dataTree([("a", #"{"n":"# + fits + "}"), ("b", #"{"n":1}"#)])
        let path = DataOperations.dataPath("sg")
        let returned: Int = try await Task.detached {
            try DataOperations.answer(QueryRequest(), proof: shallow.proof, path: path).results.count
        }.value
        XCTAssertEqual(returned, 2)
        let errors: [WillowErrorType?] = await Task.detached {
            var types: [WillowErrorType?] = []
            do {
                let answer = try DataOperations.answer(QueryRequest(), proof: tree.proof, path: path)
                types.append(answer.results.count == 1 ? nil : .proof)
            } catch {
                types.append((error as? WillowError)?.type)
            }
            do {
                let result = try GroveDBVerifier.verifyProof(proofBytes: tree.proof, expectedPath: path)
                _ = try DataOperations.requireProven(subgroveId: "sg", key: "a", value: ["n": AnyCodable(0)], in: result)
                types.append(nil)
            } catch {
                types.append((error as? WillowError)?.type)
            }
            return types
        }.value
        XCTAssertEqual(errors, [.notVerifiable, .notVerifiable])
    }
}
