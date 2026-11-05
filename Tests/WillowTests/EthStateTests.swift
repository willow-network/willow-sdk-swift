import XCTest
@testable import Willow

final class EthStateTests: XCTestCase {

    func testMptRejectsShortRoot() {
        XCTAssertThrowsError(try verifyMptProof(
            root: Data(repeating: 0, count: 16),
            keyHash: Data(repeating: 0, count: 32),
            expectedValue: Data([0x80]),
            proofNodes: [Data([0xc0])]
        )) { error in
            XCTAssertTrue("\(error)".contains("root must be 32 bytes"))
        }
    }

    func testMptRejectsEmptyProof() {
        XCTAssertThrowsError(try verifyMptProof(
            root: Data(repeating: 0, count: 32),
            keyHash: Data(repeating: 0, count: 32),
            expectedValue: Data(),
            proofNodes: []
        )) { error in
            XCTAssertTrue("\(error)".contains("proof is empty"))
        }
    }

    func testMptVerifiesSingleLeafTrie() throws {
        let keyHash = keccak256(Data("hello".utf8))
        // Compact-encoded leaf path: 0x20 prefix (leaf, even nibbles) + key.
        var encodedPath = Data([0x20])
        encodedPath.append(keyHash)
        let value = Data([0xab, 0xcd, 0xef])
        let leafNode = rlpEncodeList([
            rlpEncodeBytes(encodedPath),
            rlpEncodeBytes(value),
        ])
        let root = keccak256(leafNode)
        try verifyMptProof(
            root: root,
            keyHash: keyHash,
            expectedValue: value,
            proofNodes: [leafNode]
        )
    }

    func testRlpRoundTrips() throws {
        let raw: [Data] = [
            Data([0x01]),
            Data([0xab, 0xcd]),
            Data(repeating: 0x77, count: 60),
        ]
        let encoded = raw.map { rlpEncodeBytes($0) }
        let list = rlpEncodeList(encoded)
        let decoded = try rlpDecodeList(list)
        XCTAssertEqual(decoded.count, raw.count)
        for (i, want) in raw.enumerated() {
            XCTAssertEqual(decoded[i], want, "item \(i) mismatch")
        }
    }

    // MARK: - Answers must be about what was asked

    static let token = Data(repeating: 0xaa, count: 20)
    static let other = Data(repeating: 0xbb, count: 20)
    static let codeHash = Data(repeating: 0xcc, count: 32)

    /// A single-leaf trie holding `value` under `keccak256(key)`: its root
    /// and its one node.
    static func leafTrie(key: Data, value: Data) -> (root: Data, node: Data) {
        let node = rlpEncodeList([rlpEncodeBytes(Data([0x20]) + keccak256(key)), rlpEncodeBytes(value)])
        return (keccak256(node), node)
    }

    static func ints(_ data: Data) -> String {
        return "[" + data.map { String($0) }.joined(separator: ",") + "]"
    }

    /// A `/verifiable-rpc/eth/state` answer whose proofs walk: `address`'s
    /// account at `block`, its storage a single leaf holding `stored` at
    /// `storedSlot`, and the answer claiming `values` for `slots`.
    static func stateAnswer(
        address: Data = token, block: UInt64 = 100, storedSlot: Data, stored: Data,
        slots: [Data], values: [Data], proofs: Int = 1
    ) -> String {
        let storage = leafTrie(key: storedSlot, value: rlpEncodeBytes(stored))
        let account = rlpEncodeAccount(nonce: 1, balance: BigUInt(5), storageHash: storage.root, codeHash: codeHash)
        let state = leafTrie(key: address, value: account)
        let storageProofs = zip(slots, values).map { slot, value in
            #"{"slot":\#(ints(slot)),"value":\#(ints(value)),"proof":{"key":[],"value":[],"proof_nodes":[\#(ints(storage.node))]}}"#
        }.joined(separator: ",")
        let proof = #"""
        {"address":\#(ints(address)),"block_number":\#(block),"block_hash":\#(ints(Data(repeating: 1, count: 32))),
         "state_root":\#(ints(state.root)),
         "account_proof":{"key":[],"value":[],"proof_nodes":[\#(ints(state.node))]},
         "account_state":{"nonce":1,"balance":[5],"storage_hash":\#(ints(storage.root)),"code_hash":\#(ints(codeHash))},
         "storage_proofs":[\#(storageProofs)]}
        """#
        return #"{"answer":"","state_root":\#(ints(state.root)),"block_range":[\#(block),\#(block)],"state_proofs":[\#(Array(repeating: proof, count: proofs).joined(separator: ","))]}"#
    }

    static func operations(_ answer: String) -> (EthOperations, StubServer) {
        let stub = StubServer { _ in (200, answer) }
        return (EthOperations(indexerBaseURL: URL(string: "http://indexer.test")!, session: stub.session), stub)
    }

    /// An answer whose proofs walk, but about another address, block, or
    /// slot than asked (or with two state proofs, or a value longer than a
    /// uint256), was returned as the read: the walk checks the answer only
    /// against its own root. Each is refused, in every mode.
    func testAStateAnswerMustBeAboutWhatWasAsked() async throws {
        let holder = Data(repeating: 0x11, count: 20)
        let slot = mappingSlotForAddress(holder, slotIndex: 0)
        let otherSlot = mappingSlotForAddress(Data(repeating: 0x22, count: 20), slotIndex: 0)
        let seven = Data([7])

        let (ok, okStub) = Self.operations(Self.stateAnswer(storedSlot: slot, stored: seven, slots: [slot], values: [seven]))
        let balance = try await ok.erc20Balance(token: "0x" + Self.token.hexString, holder: "0x" + holder.hexString, balanceSlot: 0, block: 100)
        XCTAssertEqual(balance, BigUInt(7))
        let sent = try JSONSerialization.jsonObject(with: try XCTUnwrap(okStub.requests.first).body) as? [String: Any]
        XCTAssertEqual(sent?["slots"] as? [String], ["0x" + slot.hexString])

        let wrong: [(String, String)] = [
            ("another address", Self.stateAnswer(address: Self.other, storedSlot: slot, stored: seven, slots: [slot], values: [seven])),
            ("another block", Self.stateAnswer(block: 101, storedSlot: slot, stored: seven, slots: [slot], values: [seven])),
            ("another slot", Self.stateAnswer(storedSlot: otherSlot, stored: seven, slots: [otherSlot], values: [seven])),
            ("no slot", Self.stateAnswer(storedSlot: slot, stored: seven, slots: [], values: [])),
            ("two proofs", Self.stateAnswer(storedSlot: slot, stored: seven, slots: [slot], values: [seven], proofs: 2)),
            ("a 33-byte value", Self.stateAnswer(
                storedSlot: slot, stored: Data(repeating: 9, count: 33), slots: [slot], values: [Data(repeating: 9, count: 33)])),
        ]
        for mode in [StateVerifyMode.strict, .disabled] {
            for (what, answer) in wrong {
                let (operations, _) = Self.operations(answer)
                await operations.setMode(mode)
                do {
                    let value = try await operations.erc20Balance(
                        token: "0x" + Self.token.hexString, holder: "0x" + holder.hexString, balanceSlot: 0, block: 100)
                    XCTFail("\(mode) \(what): returned \(value)")
                } catch EthStateError.unexpectedAnswer {
                } catch {
                    XCTFail("\(mode) \(what): \(error)")
                }
            }
        }
    }

    /// A zero value isn't stored, so its proof shows the slot absent; that
    /// read as a mismatch. A proof showing it absent while the answer claims
    /// a value is refused.
    func testAZeroValueIsProvedByTheSlotsAbsence() async throws {
        let holder = Data(repeating: 0x11, count: 20)
        let slot = mappingSlotForAddress(holder, slotIndex: 0)
        let storedSlot = mappingSlotForAddress(Data(repeating: 0x22, count: 20), slotIndex: 0)
        let (operations, _) = Self.operations(Self.stateAnswer(storedSlot: storedSlot, stored: Data([7]), slots: [slot], values: [Data()]))
        let balance = try await operations.erc20Balance(
            token: "0x" + Self.token.hexString, holder: "0x" + holder.hexString, balanceSlot: 0, block: 100)
        XCTAssertEqual(balance, BigUInt(0))

        let (claims, _) = Self.operations(Self.stateAnswer(storedSlot: storedSlot, stored: Data([7]), slots: [slot], values: [Data([7])]))
        do {
            let value = try await claims.erc20Balance(token: "0x" + Self.token.hexString, holder: "0x" + holder.hexString, balanceSlot: 0, block: 100)
            XCTFail("returned \(value) for a slot the proof shows absent")
        } catch EthStateError.verificationFailed {
        }
    }

    /// A call's answer and state proofs must be for the block asked, under
    /// the answer's root.
    func testACallAnswerMustBeForTheBlockAsked() async throws {
        let slot = Data(repeating: 3, count: 32)
        let answer = Self.stateAnswer(storedSlot: slot, stored: Data([7]), slots: [slot], values: [Data([7])])
        let (ok, _) = Self.operations(answer)
        let call = try await ok.getCall(tx: ["to": "0x" + Self.token.hexString], block: 100)
        XCTAssertEqual(call.accessStateReads.count, 1)

        let (wrong, _) = Self.operations(answer)
        do {
            _ = try await wrong.getCall(tx: ["to": "0x" + Self.token.hexString], block: 99)
            XCTFail("returned an answer for another block")
        } catch EthStateError.unexpectedAnswer {
        }
    }

    func testBigUIntDropsLeadingZeros() {
        XCTAssertEqual(BigUInt(bytesBE: [0, 0, 1, 0]), BigUInt(256))
        XCTAssertEqual(BigUInt(bytesBE: [UInt8](repeating: 0, count: 100_000)), BigUInt(0))
        XCTAssertEqual(BigUInt(bytesBE: []).description, "0")
    }
}
