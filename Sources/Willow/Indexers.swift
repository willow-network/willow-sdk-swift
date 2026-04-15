import Foundation

/// Which backend should serve a query.
///
/// - ``validator``: consensus-verified chain-tip. Every row is Merkle-provable.
///   Throws ``ValidatorHasNoDataError`` for `VerifyOnly` subgroves.
/// - ``indexer``: full history + analytics via an indexer. Throws
///   ``NoIndexersReachableError`` if none are reachable.
/// - ``auto`` (default): indexer when one serves this subgrove, otherwise
///   validator. On indexer failure, falls back to validator and sets
///   `fallback = true` on the returned result.
public enum QuerySource: String, Sendable {
    case validator
    case indexer
    case auto
}

/// Which backend actually served a routed query.
public enum ServedBy: String, Sendable {
    case validator
    case indexer
}

/// Result envelope surfacing which backend served a query.
public struct RoutedQueryResult<T: Sendable>: Sendable {
    public let result: T
    public let source: ServedBy
    /// DID of the indexer that served the query. `nil` for validator.
    public let indexerDid: String?
    /// `true` when `auto` routing fell back from indexer to validator.
    public let fallback: Bool

    public init(result: T, source: ServedBy, indexerDid: String? = nil, fallback: Bool = false) {
        self.result = result
        self.source = source
        self.indexerDid = indexerDid
        self.fallback = fallback
    }
}

/// Thrown when `QuerySource.validator` was requested but the validator has
/// no data for the subgrove (VerifyOnly retention, pruned, or not indexed).
public struct ValidatorHasNoDataError: Error, CustomStringConvertible {
    public let subgroveId: String
    public let reason: String

    public var description: String {
        "Validator cannot serve data for subgrove \"\(subgroveId)\": \(reason)"
    }
}

/// Thrown when `QuerySource.indexer` was requested but either no indexer
/// serves the subgrove or every candidate failed.
public struct NoIndexersReachableError: Error, CustomStringConvertible {
    public let subgroveId: String
    public let details: String

    public var description: String {
        "No indexer could serve subgrove \"\(subgroveId)\": \(details)"
    }
}

/// Default TTL for cached `/indexers` responses.
public let defaultIndexerCacheTTL: TimeInterval = 30

struct IndexersListEnvelope: Codable {
    let success: Bool
    let data: [IndexerInfo]?
}

/// Indexer discovery client wrapping the validator's `GET /indexers` endpoint.
///
/// Uses a simple in-memory cache (default 30s). When the SDK is constructed
/// with an explicit `indexerURL`, discovery is bypassed and a synthetic
/// single-entry list is returned so the routing code path stays uniform.
public actor WillowIndexers {
    private let session: URLSession
    private let apiURL: URL
    private let indexerURL: URL?
    private let cacheTTL: TimeInterval
    private var cache: [IndexerInfo]?
    private var cacheFilledAt: Date?

    public init(
        session: URLSession,
        apiURL: URL,
        indexerURL: URL? = nil,
        cacheTTL: TimeInterval = defaultIndexerCacheTTL
    ) {
        self.session = session
        self.apiURL = apiURL
        self.indexerURL = indexerURL
        self.cacheTTL = cacheTTL
    }

    /// Whether an explicit indexer URL was configured (bypasses discovery).
    public func hasExplicitOverride() -> Bool {
        return indexerURL != nil
    }

    /// Force the next `list()` to re-fetch from the validator.
    public func invalidate() {
        cache = nil
        cacheFilledAt = nil
    }

    /// Drop a specific indexer from the cache (e.g., after a 5xx).
    public func evict(indexerDid: String) {
        guard var current = cache else { return }
        current.removeAll { $0.indexerDid == indexerDid }
        cache = current
    }

    /// Return all registered indexers, cached for `cacheTTL`.
    public func list() async throws -> [IndexerInfo] {
        if let override = indexerURL {
            return [Self.syntheticEntry(override.absoluteString)]
        }
        if let cached = cache, let filled = cacheFilledAt,
           Date().timeIntervalSince(filled) < cacheTTL {
            return cached
        }

        let url = apiURL.appendingPathComponent("indexers")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NetworkError("Failed to fetch /indexers")
        }
        let envelope = try JSONDecoder().decode(IndexersListEnvelope.self, from: data)
        let list = envelope.data ?? []
        cache = list
        cacheFilledAt = Date()
        return list
    }

    /// Active indexers serving `subgroveId`, sorted by `performanceScore` desc.
    ///
    /// With an explicit `indexerURL` override, always returns a single
    /// synthetic entry — the routing code doesn't need to special-case this.
    public func forSubgrove(_ subgroveId: String) async throws -> [IndexerInfo] {
        if let override = indexerURL {
            return [Self.syntheticEntry(override.absoluteString)]
        }
        let all = try await list()
        return all
            .filter { $0.status == "active" && $0.subgroves.contains(subgroveId) }
            .sorted { $0.performanceScore > $1.performanceScore }
    }

    private static func syntheticEntry(_ url: String) -> IndexerInfo {
        IndexerInfo(
            indexerDid: "explicit-override",
            subgroves: [],
            stakeAmount: 0,
            endpoint: url,
            queryEndpoint: url,
            status: "active",
            performanceScore: 100,
            lastUpdate: 0
        )
    }
}
