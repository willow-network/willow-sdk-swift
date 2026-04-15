import XCTest
@testable import Willow

/// Unit tests for `WillowSubscriptions`.
///
/// Swift doesn't have a lightweight built-in WebSocket server and we
/// don't want to pull Swift-NIO in as a dev dependency, so these tests
/// cover what's self-testable without a server: enum defaults, option
/// propagation, and the discovery-failure paths before any socket is
/// opened. The wire-level protocol (`connection_init` / `subscribe` /
/// `next` / `complete` / ping/pong) is identical to the Rust, Python,
/// and Go SDKs — all three have full integration-test coverage that
/// would catch protocol regressions before they reach Swift.
final class SubscriptionsTests: XCTestCase {
    // MARK: - Enum defaults

    func testSubscribeSourceRawValues() {
        XCTAssertEqual(SubscribeSource.validator.rawValue, "validator")
        XCTAssertEqual(SubscribeSource.indexer.rawValue, "indexer")
    }

    func testSubscribeOptionsDefault() {
        let opts = SubscribeOptions()
        XCTAssertEqual(opts.source, .validator)
        XCTAssertNil(opts.variables)
        XCTAssertNil(opts.operationName)
        XCTAssertNil(opts.connectionPayload)
    }

    func testSubscribeOptionsCustom() {
        let opts = SubscribeOptions(
            variables: ["a": "hello"],
            operationName: "Foo",
            connectionPayload: ["auth": "token"],
            source: .indexer
        )
        XCTAssertEqual(opts.source, .indexer)
        XCTAssertEqual(opts.variables?["a"] as? String, "hello")
        XCTAssertEqual(opts.operationName, "Foo")
        XCTAssertEqual(opts.connectionPayload?["auth"] as? String, "token")
    }

    // MARK: - Discovery failure paths

    func testIndexerSourceRequiresAnIndexersInstance() async {
        let subs = WillowSubscriptions(
            apiURL: URL(string: "http://validator:3031")!,
            indexers: nil
        )

        do {
            _ = try await subs.subscribe(
                subgroveId: "any",
                query: "subscription { x }",
                options: SubscribeOptions(source: .indexer)
            )
            XCTFail("expected subscribe to throw when no WillowIndexers provided")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("WillowIndexers"),
                "error should mention WillowIndexers: \(error)"
            )
        }
    }

    func testIndexerSourceFailsFastWithNoServingIndexer() async {
        // Point discovery at a dead address so `/indexers` fetch fails.
        // Regardless of whether the failure surfaces as an HTTP error
        // or as an empty-list-from-discovery, subscribe() must throw
        // before opening any WebSocket.
        let apiURL = URL(string: "http://127.0.0.1:1")!
        // Short-timeout session so the test doesn't hang.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        let indexers = WillowIndexers(
            session: URLSession(configuration: config),
            apiURL: apiURL,
            indexerURL: nil
        )
        let subs = WillowSubscriptions(apiURL: apiURL, indexers: indexers)

        do {
            _ = try await subs.subscribe(
                subgroveId: "my-subgrove",
                query: "subscription { x }",
                options: SubscribeOptions(source: .indexer)
            )
            XCTFail("expected subscribe to throw when no indexer is reachable")
        } catch {
            // Either the discovery fetch error bubbles up or our
            // "no indexer serves" error — both are acceptable.
        }
    }

    // MARK: - Explicit indexer URL override

    func testExplicitIndexerUrlResolvesToConfiguredEndpoint() async throws {
        // With an explicit indexerURL, `forSubgrove` returns a synthetic
        // entry regardless of subgrove; the subscribe call should try
        // to open a socket against that URL. We don't have a server
        // here so it will fail at connect time, but the test verifies
        // we got past discovery (i.e., we tried the pinned URL).
        let apiURL = URL(string: "http://validator:3031")!
        // Dead address — ensures the connect fails deterministically
        // and fast.
        let indexerURL = URL(string: "http://127.0.0.1:1")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        let indexers = WillowIndexers(
            session: URLSession(configuration: config),
            apiURL: apiURL,
            indexerURL: indexerURL
        )
        let subs = WillowSubscriptions(apiURL: apiURL, indexers: indexers)

        do {
            _ = try await subs.subscribe(
                subgroveId: "any-subgrove",
                query: "subscription { x }",
                options: SubscribeOptions(source: .indexer)
            )
            XCTFail("expected subscribe to throw — no server at override URL")
        } catch {
            // Error is expected; the point of the test is that we got
            // past discovery without the "no indexer serves" error.
            let msg = "\(error)"
            XCTAssertFalse(
                msg.contains("No indexer serves"),
                "subscribe should have used the explicit override rather than discovery: \(msg)"
            )
        }
    }
}
