import Foundation

/// Which backend to open the subscription WebSocket against.
///
/// - ``validator``: `{apiURL}/graphql/ws` — consensus-verified
///   chain-tip events. This is the default.
/// - ``indexer``: selected via discovery (or the explicit `indexerURL`
///   override) and opened against `{indexer.query_endpoint}/graphql/ws`.
///   Useful for `VerifyOnly` subgroves where the validator has no tail.
public enum SubscribeSource: String, Sendable {
    case validator
    case indexer
}

/// Optional subscription parameters.
public struct SubscribeOptions: Sendable {
    /// GraphQL variables passed to the subscription.
    public var variables: [String: Any]?

    /// GraphQL operation name (when the document has multiple).
    public var operationName: String?

    /// Payload for the ``connection_init`` frame (e.g., auth tokens).
    public var connectionPayload: [String: Any]?

    /// Where to open the WebSocket. Defaults to ``SubscribeSource/validator``.
    public var source: SubscribeSource

    public init(
        variables: [String: Any]? = nil,
        operationName: String? = nil,
        connectionPayload: [String: Any]? = nil,
        source: SubscribeSource = .validator
    ) {
        self.variables = variables
        self.operationName = operationName
        self.connectionPayload = connectionPayload
        self.source = source
    }
}

/// A single payload pushed by the server over a `next` frame.
///
/// Mirrors the `graphql-transport-ws` wire shape. Values are kept as
/// `Any?` for flexibility — Swift's `Codable` story for arbitrary JSON
/// trees is awkward and the use cases in practice all do their own
/// per-subgrove parsing.
public struct SubscriptionPayload: Sendable {
    public let data: [String: Any]?
    public let errors: Any?

    public init(data: [String: Any]? = nil, errors: Any? = nil) {
        self.data = data
        self.errors = errors
    }
}

/// An open subscription. Iterate with ``stream`` (an `AsyncStream`);
/// close with ``unsubscribe()`` or by breaking out of the iteration.
/// The stream finishes when the server sends `complete`, the connection
/// drops, or ``unsubscribe()`` is called.
public actor Subscription {
    /// Async stream of incoming payloads. Finishes cleanly when the
    /// subscription ends.
    public nonisolated let stream: AsyncStream<SubscriptionPayload>

    private let onCancel: @Sendable () async -> Void
    private var cancelled = false

    init(
        stream: AsyncStream<SubscriptionPayload>,
        onCancel: @escaping @Sendable () async -> Void
    ) {
        self.stream = stream
        self.onCancel = onCancel
    }

    /// Close the subscription. Sends `complete` to the server and tears
    /// down the socket. Safe to call more than once — subsequent calls
    /// are no-ops.
    public func unsubscribe() async {
        if cancelled { return }
        cancelled = true
        await onCancel()
    }

    deinit {
        // Best-effort: fire the cancel future-and-forget. Can't await
        // from deinit, so if the caller forgot to call unsubscribe()
        // explicitly the socket may linger briefly until the task
        // detects the stream has no receiver.
        let cancel = onCancel
        Task { await cancel() }
    }
}

/// Subscription client.
///
/// Normally constructed alongside a ``WillowIndexers`` instance so
/// ``SubscribeSource/indexer`` can resolve a query endpoint. Callers
/// that only use validator subscriptions can pass `indexers: nil`.
public actor WillowSubscriptions {
    private let apiURL: URL
    private let indexers: WillowIndexers?
    private var counter: UInt64 = 0

    public init(apiURL: URL, indexers: WillowIndexers?) {
        self.apiURL = apiURL
        self.indexers = indexers
    }

    /// Open a subscription.
    ///
    /// Awaits the `connection_init` → `connection_ack` → `subscribe`
    /// handshake before returning, so connection errors surface to the
    /// caller here rather than through the stream.
    ///
    /// For ``SubscribeSource/indexer``, discovery happens inside this
    /// call. If the explicit `indexerURL` override was set on the
    /// ``WillowIndexers`` instance, that URL is used directly.
    public func subscribe(
        subgroveId: String,
        query: String,
        options: SubscribeOptions = SubscribeOptions()
    ) async throws -> Subscription {
        let wsURL = try await resolveWSURL(
            subgroveId: subgroveId, source: options.source
        )

        var request = URLRequest(url: wsURL)
        request.setValue(
            "graphql-transport-ws", forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )

        // URLSessionWebSocketTask doesn't expose subprotocol negotiation
        // directly — it advertises whatever we put in the header. When
        // the server responds with the matching Sec-WebSocket-Protocol,
        // the connection succeeds.
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()

        // 1) Send connection_init.
        let initPayload = options.connectionPayload ?? [:]
        let initFrame: [String: Any] = [
            "type": "connection_init",
            "payload": initPayload,
        ]
        try await send(task: task, frame: initFrame)

        // 2) Wait for connection_ack. Handle pings along the way.
        while true {
            let msg = try await task.receive()
            guard let frame = try decodeFrame(from: msg) else { continue }
            switch frame["type"] as? String {
            case "connection_ack":
                // proceed to subscribe
                break
            case "ping":
                try await send(task: task, frame: ["type": "pong"])
                continue
            case "connection_error":
                task.cancel(with: .policyViolation, reason: nil)
                throw NetworkError(
                    "Server refused connection: \(frame["payload"] ?? "-")"
                )
            default:
                continue
            }
            break
        }

        // 3) Send subscribe frame.
        counter += 1
        let subId = "sub-\(counter)-\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        var subPayload: [String: Any] = ["query": query]
        if let vars = options.variables {
            subPayload["variables"] = vars
        }
        if let op = options.operationName {
            subPayload["operationName"] = op
        }
        let subFrame: [String: Any] = [
            "type": "subscribe",
            "id": subId,
            "payload": subPayload,
        ]
        try await send(task: task, frame: subFrame)

        // 4) Build the AsyncStream + pump.
        let taskBox = TaskBox(task: task)

        let stream = AsyncStream<SubscriptionPayload> { continuation in
            let pumpTask = Task {
                await pump(
                    task: taskBox.task, subId: subId, continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                pumpTask.cancel()
                taskBox.task.cancel(with: .normalClosure, reason: nil)
            }
        }

        let onCancel: @Sendable () async -> Void = {
            // Best-effort `complete` then close. If the socket is
            // already gone, both calls no-op.
            let completeFrame: [String: Any] = [
                "type": "complete",
                "id": subId,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: completeFrame, options: []),
                let text = String(data: data, encoding: .utf8)
            {
                try? await taskBox.task.send(.string(text))
            }
            taskBox.task.cancel(with: .normalClosure, reason: nil)
        }

        return Subscription(stream: stream, onCancel: onCancel)
    }

    private func resolveWSURL(
        subgroveId: String, source: SubscribeSource
    ) async throws -> URL {
        switch source {
        case .validator:
            return httpToWS(apiURL).appendingPathComponent("graphql/ws")
        case .indexer:
            guard let indexers = indexers else {
                throw NetworkError(
                    "source=indexer requires a WillowIndexers instance"
                )
            }
            let candidates = try await indexers.forSubgrove(subgroveId)
            if candidates.isEmpty {
                throw NetworkError(
                    "No indexer serves subgrove \"\(subgroveId)\" — cannot open indexer subscription"
                )
            }
            guard
                let endpointURL = URL(
                    string: candidates[0].effectiveQueryEndpoint())
            else {
                throw NetworkError(
                    "Invalid query endpoint: \(candidates[0].effectiveQueryEndpoint())"
                )
            }
            return httpToWS(endpointURL).appendingPathComponent("graphql/ws")
        }
    }
}

// MARK: - Internal helpers

/// Boxes a URLSessionWebSocketTask so we can reference it from
/// @Sendable closures. The task itself is thread-safe.
final class TaskBox: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }
}

private func send(
    task: URLSessionWebSocketTask, frame: [String: Any]
) async throws {
    let data = try JSONSerialization.data(withJSONObject: frame, options: [])
    guard let text = String(data: data, encoding: .utf8) else {
        throw NetworkError("Frame is not UTF-8 encodable")
    }
    try await task.send(.string(text))
}

private func decodeFrame(
    from msg: URLSessionWebSocketTask.Message
) throws -> [String: Any]? {
    switch msg {
    case .string(let text):
        return try? JSONSerialization.jsonObject(
            with: Data(text.utf8), options: []
        ) as? [String: Any]
    case .data(let data):
        return try? JSONSerialization.jsonObject(with: data, options: [])
            as? [String: Any]
    @unknown default:
        return nil
    }
}

@Sendable
private func pump(
    task: URLSessionWebSocketTask,
    subId: String,
    continuation: AsyncStream<SubscriptionPayload>.Continuation
) async {
    defer { continuation.finish() }

    while !Task.isCancelled {
        let msg: URLSessionWebSocketTask.Message
        do {
            msg = try await task.receive()
        } catch {
            // Transport error or cancelled — either way, finish the stream.
            return
        }

        guard let frame = try? decodeFrame(from: msg) ?? nil else {
            continue
        }
        switch frame["type"] as? String {
        case "next":
            guard (frame["id"] as? String) == subId else { continue }
            let payload = frame["payload"] as? [String: Any]
            let p = SubscriptionPayload(
                data: payload?["data"] as? [String: Any],
                errors: payload?["errors"]
            )
            continuation.yield(p)
        case "complete":
            if (frame["id"] as? String) == subId {
                return
            }
        case "error":
            if (frame["id"] as? String) == subId {
                continuation.yield(
                    SubscriptionPayload(data: nil, errors: frame["payload"])
                )
            }
        case "ping":
            try? await send(task: task, frame: ["type": "pong"])
        default:
            // Ignore unknown types.
            break
        }
    }
}

private func httpToWS(_ url: URL) -> URL {
    let s = url.absoluteString
    var mapped = s
    if s.hasPrefix("https://") {
        mapped = "wss://" + s.dropFirst("https://".count)
    } else if s.hasPrefix("http://") {
        mapped = "ws://" + s.dropFirst("http://".count)
    }
    return URL(string: mapped) ?? url
}
