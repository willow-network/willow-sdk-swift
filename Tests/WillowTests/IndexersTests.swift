import XCTest
@testable import Willow

final class IndexersTests: XCTestCase {
    func testEffectiveQueryEndpointPrefersQueryEndpoint() {
        let info = IndexerInfo(
            indexerDid: "x",
            subgroves: ["sg"],
            stakeAmount: 100,
            endpoint: "http://x:9090",
            queryEndpoint: "http://x:3032",
            status: "active",
            performanceScore: 100.0,
            lastUpdate: 0
        )
        XCTAssertEqual(info.effectiveQueryEndpoint(), "http://x:3032")
    }

    func testEffectiveQueryEndpointFallsBackToEndpoint() {
        let info = IndexerInfo(
            indexerDid: "x",
            subgroves: ["sg"],
            stakeAmount: 100,
            endpoint: "http://x:9090",
            queryEndpoint: nil,
            status: "active",
            performanceScore: 100.0,
            lastUpdate: 0
        )
        XCTAssertEqual(info.effectiveQueryEndpoint(), "http://x:9090")
    }

    func testIndexerInfoDecodesLegacyJsonWithoutQueryEndpoint() throws {
        // Pre-upgrade servers won't include `query_endpoint`. The SDK must
        // still decode such responses — if not, every client breaks on any
        // validator that hasn't been upgraded.
        let legacy = """
        {
            "indexer_did": "did:willow:legacy",
            "subgroves": ["sg-1"],
            "stake_amount": 100,
            "endpoint": "http://old:3032",
            "status": "active",
            "performance_score": 95.0,
            "last_update": 0
        }
        """.data(using: .utf8)!
        let info = try JSONDecoder().decode(IndexerInfo.self, from: legacy)
        XCTAssertNil(info.queryEndpoint)
        XCTAssertEqual(info.effectiveQueryEndpoint(), "http://old:3032")
    }

    func testIndexerInfoDecodesModernJsonWithQueryEndpoint() throws {
        let modern = """
        {
            "indexer_did": "did:willow:new",
            "subgroves": ["sg-1"],
            "stake_amount": 100,
            "endpoint": "http://new:9090",
            "query_endpoint": "http://new:3032",
            "status": "active",
            "performance_score": 99.0,
            "last_update": 0
        }
        """.data(using: .utf8)!
        let info = try JSONDecoder().decode(IndexerInfo.self, from: modern)
        XCTAssertEqual(info.queryEndpoint, "http://new:3032")
        XCTAssertEqual(info.effectiveQueryEndpoint(), "http://new:3032")
    }

    func testQuerySourceRawValues() {
        XCTAssertEqual(QuerySource.auto.rawValue, "auto")
        XCTAssertEqual(QuerySource.validator.rawValue, "validator")
        XCTAssertEqual(QuerySource.indexer.rawValue, "indexer")
    }

    func testExplicitOverrideReturnsSyntheticEntry() async throws {
        let session = URLSession.shared
        let apiURL = URL(string: "http://validator:3031")!
        let indexerURL = URL(string: "http://pinned:3032")!
        let disc = WillowIndexers(session: session, apiURL: apiURL, indexerURL: indexerURL)

        let has = await disc.hasExplicitOverride()
        XCTAssertTrue(has)

        // Must not make any HTTP call — the synthetic entry short-circuits.
        let all = try await disc.list()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.effectiveQueryEndpoint(), "http://pinned:3032")

        let picks = try await disc.forSubgrove("anything")
        XCTAssertEqual(picks.count, 1)
    }

    func testEvictDropsFromCache() async throws {
        // We can't easily inject a cache state from outside the actor, so
        // this test exercises the no-op path (evicting before any fetch)
        // to prove it doesn't crash. Fuller eviction coverage lives in
        // the language SDKs that allow direct cache manipulation.
        let disc = WillowIndexers(
            session: .shared,
            apiURL: URL(string: "http://validator:3031")!
        )
        await disc.evict(indexerDid: "absent")
    }

    func testErrorTypesHaveContext() {
        let v = ValidatorHasNoDataError(subgroveId: "sg-x", reason: "VerifyOnly")
        XCTAssertTrue("\(v)".contains("sg-x"))
        XCTAssertTrue("\(v)".contains("VerifyOnly"))

        let n = NoIndexersReachableError(subgroveId: "sg-y", details: "timed out")
        XCTAssertTrue("\(n)".contains("sg-y"))
        XCTAssertTrue("\(n)".contains("timed out"))
    }
}
