import XCTest
@testable import Willow

/// Values the SDK writes read back verified: a `Double` is written in its
/// shortest form, the text the node keeps, which the verified reader returns
/// as that same `Double`.
final class StoredNumbersTests: XCTestCase {

    /// The JSON text `data.store` writes for `value`, as the node keeps it,
    /// read back by the verified `get` and `query` paths. Returns the value
    /// each returns for the field `n`.
    static func roundTrip(_ value: Any) throws -> (get: Any?, query: Any?) {
        let text = try storeDataText(["n": value, "k": "a"])
        let tree = VerifiedReadsTests.dataTree([("a", text)])
        let path = DataOperations.dataPath("sg")
        // The API serves the value as the node read it; the SDK decodes the
        // answer with JSONSerialization.
        let served = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let result = try GroveDBVerifier.verifyProof(proofBytes: tree.proof, expectedPath: path)
        let got = try DataOperations.requireProven(subgroveId: "sg", key: "a", value: served.mapValues { AnyCodable($0) }, in: result)
        let answer = try DataOperations.answer(QueryRequest(), proof: tree.proof, path: path)
        return (got["n"]?.value, answer.results.first?.data["n"]?.value)
    }

    func testDoublesTheSDKStoresReadBackVerified() throws {
        let now = Date().timeIntervalSince1970 * 1000
        let doubles: [Double] = [
            0.1, 0.3, 1.1, 2.675, 19.99, 3.14, 100.25, 0.1 + 0.2, 1730793600123.4561, 1762329618574.8271, now, now + 0.5,
            1e-7, 5e-324, 1e21, 1.7976931348623157e308, 123456789.123456789, -2.5, 5.0, -0.0,
        ]
        for double in doubles {
            let (get, query) = try Self.roundTrip(double)
            for (path, read) in [("get", get), ("query", query)] {
                let value = try XCTUnwrap(read as? Double, "\(path) \(double): \(String(describing: read))")
                XCTAssertEqual(value.bitPattern, double.bitPattern, "\(path) \(double)")
            }
        }
        // Every price with two decimals below 1000, and as an NSNumber, as
        // JSONSerialization makes one.
        for cents in stride(from: 1, to: 100_000, by: 7) {
            let price = Double(cents) / 100
            let text = try storeDataText(["p": price, "q": NSNumber(value: price)])
            let read = try XCTUnwrap(try NodeJSON.parse(Data(text.utf8)).foundationValue() as? [String: Any], text)
            XCTAssertEqual(read["p"] as? Double, price, text)
            XCTAssertEqual(read["q"] as? Double, price, text)
        }
        // Integers and the rest keep their kinds.
        let text = try storeDataText([
            "i": 42, "u": UInt64.max, "b": true, "nb": NSNumber(value: true), "n1": NSNumber(value: 1), "s": "x\"/",
            "a": [1 as Int, 2.5 as Double] as [Any], "z": NSNull(), "d": Decimal(string: "0.12345678901234567891")!, "f": Float(0.5),
        ])
        XCTAssertEqual(
            text,
            #"{"a":[1,2.5],"b":true,"d":0.12345678901234567891,"f":0.5,"i":42,"n1":1,"nb":true,"s":"x\"/","u":18446744073709551615,"z":null}"#)
        for invalid: Any in [["n": Double.nan], ["n": Double.infinity], ["n": Date()], [1: 2], ["n": [Float.infinity]]] {
            XCTAssertThrowsError(try storeDataText(invalid), "\(invalid)") { error in
                XCTAssertEqual((error as? WillowError)?.type, .validation)
            }
        }
    }

    /// `equals(field, 0.1)` matches a `0.1` the SDK stored: the filter's
    /// value goes out in the same form, and the node compares number text.
    func testAnEqualityFilterMatchesADoubleTheSDKStored() throws {
        let tree = VerifiedReadsTests.dataTree([
            ("a", try storeDataText(["price": 0.1])),
            ("b", try storeDataText(["price": 0.2])),
            ("c", try storeDataText(["price": 1762329618574.8271])),
            ("d", try storeDataText(["price": 5.0])),
        ])
        let path = DataOperations.dataPath("sg")
        func keys(_ value: Any) throws -> [String] {
            return try DataOperations.answer(QueryBuilder().equals("price", value).build(), proof: tree.proof, path: path).results.map { $0.key }
        }
        XCTAssertEqual(try keys(0.1), ["a"])
        XCTAssertEqual(try keys(NSNumber(value: 0.2)), ["b"])
        XCTAssertEqual(try keys(1762329618574.8271), ["c"])
        XCTAssertEqual(try keys(5.0), ["d"])
        XCTAssertEqual(
            String(decoding: try QueryBuilder().equals("price", 0.1).limit(3).build().nodeBody(), as: UTF8.self),
            #"{"filters":{"price":0.1},"include_proof":false,"limit":3}"#)
    }

    /// Through the client: the StoreData body carries the shortest form, and
    /// the query sent carries the same.
    func testTheClientSendsShortestFormDoubles() async throws {
        let stub = StubServer { request in
            if request.path.hasSuffix("/nonce") {
                return (200, #"{"success":true,"data":{"did":"did:willow:a","nonce":6},"error":null}"#)
            }
            if request.path == "/query/sg" {
                return (200, #"{"success":true,"data":{"documents":[],"total":0,"offset":0,"limit":100}}"#)
            }
            return (200, #"{"success":true,"data":{"tx_hash":"AB","code":0,"log":""},"error":null}"#)
        }
        let client = try stub.client(baseURL: "http://api.test")
        client.setIdentity(try RequestSigningTests.vectorIdentity(.ed25519))

        try await client.data.store(subgroveId: "sg", key: "k", data: ["price": 19.99, "at": 1762329618574.8271])
        let tx = try SignedMessagesTests.submitted(SignedMessagesTests.ChainStoreDataTx.self, variant: "StoreData", from: stub.requests[1])
        XCTAssertEqual(String(decoding: tx.data, as: UTF8.self), #"{"at":1762329618574.8271,"price":19.99}"#)

        _ = try await client.data.queryUnverified(subgroveId: "sg", query: QueryBuilder().equals("price", 19.99).build())
        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(String(decoding: sent.body, as: UTF8.self), #"{"filters":{"price":19.99},"include_proof":false}"#)
    }
}
