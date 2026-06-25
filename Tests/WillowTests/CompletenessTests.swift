import XCTest
@testable import Willow

final class CompletenessTests: XCTestCase {

    // Cross-language correctness gate. These hashes are produced by the
    // canonical Rust `canonical_event_set_hash`; any byte-layout or endianness
    // drift in `canonicalEventSetHash` flips them.

    func testVectorAEmptySet() {
        let hash = canonicalEventSetHash(blockNumber: 0, matchedLogs: [])
        XCTAssertEqual(
            hash.hexString,
            "52089e4c924fbab0475d310d7f74bf8cae542d006a45d3c5d94adacda6937da5"
        )
    }

    func testVectorBTwoLogs() {
        let logs = Self.vectorBLogs
        let hash = canonicalEventSetHash(blockNumber: 7, matchedLogs: logs)
        XCTAssertEqual(
            hash.hexString,
            "e1544ae919458663e8fce14bdcd06df6a777410c068302c0584dff1587524dfd"
        )
    }

    func testVerifyServedEventsAcceptsExactMatch() {
        let commitment = Data(hexString:
            "e1544ae919458663e8fce14bdcd06df6a777410c068302c0584dff1587524dfd")!
        XCTAssertTrue(verifyServedEvents(
            commitment: commitment,
            blockNumber: 7,
            matchedLogs: Self.vectorBLogs
        ))
    }

    func testVerifyServedEventsRejectsTampering() {
        let commitment = Data(hexString:
            "e1544ae919458663e8fce14bdcd06df6a777410c068302c0584dff1587524dfd")!

        // Wrong block number.
        XCTAssertFalse(verifyServedEvents(
            commitment: commitment, blockNumber: 8, matchedLogs: Self.vectorBLogs))

        // Dropped log.
        XCTAssertFalse(verifyServedEvents(
            commitment: commitment, blockNumber: 7,
            matchedLogs: [Self.vectorBLogs[0]]))

        // Added log.
        var extended = Self.vectorBLogs
        extended.append(CompletenessLog(
            address: Data(repeating: 0x44, count: 20), topics: [], data: Data()))
        XCTAssertFalse(verifyServedEvents(
            commitment: commitment, blockNumber: 7, matchedLogs: extended))

        // Flipped one data byte.
        var flipped = Self.vectorBLogs
        flipped[0] = CompletenessLog(
            address: flipped[0].address,
            topics: flipped[0].topics,
            data: Data([0x01, 0x02, 0x03, 0x05]))
        XCTAssertFalse(verifyServedEvents(
            commitment: commitment, blockNumber: 7, matchedLogs: flipped))
    }

    private static let vectorBLogs: [CompletenessLog] = [
        CompletenessLog(
            address: Data(repeating: 0x42, count: 20),
            topics: [Data(repeating: 0xdd, count: 32), Data(repeating: 0x11, count: 32)],
            data: Data([0x01, 0x02, 0x03, 0x04])
        ),
        CompletenessLog(
            address: Data(repeating: 0x43, count: 20),
            topics: [Data(repeating: 0xaa, count: 32)],
            data: Data()
        ),
    ]
}
