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
///
/// Auto-reconnect is on by default. On unexpected disconnect the SDK
/// applies exponential backoff; for ``SubscribeSource/indexer`` it
/// re-resolves a different indexer via discovery. Set ``reconnect`` to
/// `false` to opt out.
public struct SubscribeOptions: @unchecked Sendable {
    /// GraphQL variables passed to the subscription.
    public var variables: [String: Any]?

    /// GraphQL operation name (when the document has multiple).
    public var operationName: String?

    /// Payload for the ``connection_init`` frame (e.g., auth tokens).
    public var connectionPayload: [String: Any]?

    /// Where to open the WebSocket. Defaults to ``SubscribeSource/validator``.
    public var source: SubscribeSource

    /// Automatically reconnect on unexpected disconnect. Defaults to
    /// `true`.
    ///
    /// Reconnection is reconnect-only: messages that were in flight
    /// when the socket dropped are not replayed, and the new connection
    /// may redeliver events the old one already emitted. Callers that
    /// need exactly-once should dedupe by a stable field (e.g., block
    /// number or entity id) themselves.
    public var reconnect: Bool

    /// Maximum consecutive reconnect attempts before giving up. `nil`
    /// means retry forever. The counter resets only after a
    /// reconnection delivers at least one real payload — this avoids an
    /// infinite loop against a server that accepts the subscription but
    /// immediately drops the socket.
    public var maxReconnectAttempts: Int?

    /// Initial reconnect delay, in seconds. Doubles on each consecutive
    /// failure up to ``maxReconnectBackoff``. Defaults to 0.5.
    public var reconnectBackoff: TimeInterval

    /// Maximum reconnect delay, in seconds. Defaults to 30.
    public var maxReconnectBackoff: TimeInterval

    /// Called when a reconnect attempt is scheduled. `attempt` is
    /// 1-indexed; `delay` is the backoff we'll sleep before trying.
    public var onReconnect: (@Sendable (Int, TimeInterval) -> Void)?

    public init(
        variables: [String: Any]? = nil,
        operationName: String? = nil,
        connectionPayload: [String: Any]? = nil,
        source: SubscribeSource = .validator,
        reconnect: Bool = true,
        maxReconnectAttempts: Int? = nil,
        reconnectBackoff: TimeInterval = 0.5,
        maxReconnectBackoff: TimeInterval = 30.0,
        onReconnect: (@Sendable (Int, TimeInterval) -> Void)? = nil
    ) {
        self.variables = variables
        self.operationName = operationName
        self.connectionPayload = connectionPayload
        self.source = source
        self.reconnect = reconnect
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBackoff = reconnectBackoff
        self.maxReconnectBackoff = maxReconnectBackoff
        self.onReconnect = onReconnect
    }
}

/// A single payload pushed by the server over a `next` frame.
///
/// Mirrors the `graphql-transport-ws` wire shape. Values are kept as
/// `Any?` for flexibility — Swift's `Codable` story for arbitrary JSON
/// trees is awkward and the use cases in practice all do their own
/// per-subgrove parsing.
public struct SubscriptionPayload: @unchecked Sendable {
    public let data: [String: Any]?
    public let errors: Any?

    public init(data: [String: Any]? = nil, errors: Any? = nil) {
        self.data = data
        self.errors = errors
    }
}

/// An open subscription. Iterate with ``stream`` (an `AsyncStream`);
/// close with ``unsubscribe()`` or by breaking out of the iteration.
///
/// Reconnects are transparent: the stream stays open across transient
/// drops and only finishes when the subscription is definitively over
/// (server `complete`, caller ``unsubscribe()``, reconnect disabled +
/// socket drop, or ``SubscribeOptions/maxReconnectAttempts`` exhausted).
public actor Subscription {
    /// Async stream of incoming payloads. Finishes cleanly when the
    /// subscription ends.
    public nonisolated let stream: AsyncStream<SubscriptionPayload>

    private let loopTask: Task<Void, Never>
    private let taskRef: WSTaskRef
    private let subId: String
    private var cancelled = false

    init(
        stream: AsyncStream<SubscriptionPayload>,
        loopTask: Task<Void, Never>,
        taskRef: WSTaskRef,
        subId: String
    ) {
        self.stream = stream
        self.loopTask = loopTask
        self.taskRef = taskRef
        self.subId = subId
    }

    /// Close the subscription. Sends `complete` to the current server
    /// (best-effort) and tears down the socket. Safe to call more than
    /// once — subsequent calls are no-ops.
    public func unsubscribe() async {
        if cancelled { return }
        cancelled = true
        // Best-effort send of `complete` on the currently-open socket,
        // then cancel the loop so it exits promptly.
        if let t = await taskRef.task {
            let completeFrame: [String: Any] = [
                "type": "complete", "id": subId,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: completeFrame, options: []),
                let text = String(data: data, encoding: .utf8)
            {
                try? await t.send(.string(text))
            }
        }
        loopTask.cancel()
    }

    deinit {
        // Best-effort: cancel the loop if the caller forgot to call
        // unsubscribe() explicitly.
        loopTask.cancel()
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
    /// Awaits the initial `connection_init` → `connection_ack` →
    /// `subscribe` handshake before returning, so first-attempt errors
    /// surface to the caller here rather than through the stream. Once
    /// a socket is up, a background task handles frames and reconnects
    /// transparently.
    ///
    /// For ``SubscribeSource/indexer``, discovery happens inside this
    /// call on the first attempt. On each reconnect, the previously
    /// used indexer is evicted from the discovery cache so failover to
    /// a different indexer is automatic.
    public func subscribe(
        subgroveId: String,
        query: String,
        options: SubscribeOptions = SubscribeOptions()
    ) async throws -> Subscription {
        counter += 1
        let subId =
            "sub-\(counter)-\(Int(Date().timeIntervalSince1970 * 1_000_000))"

        // Initial connect — eager-fail.
        let (initialTask, initialDID) = try await resolveAndConnect(
            subgroveId: subgroveId,
            query: query,
            subId: subId,
            options: options,
            skipIndexerDID: nil
        )

        let taskRef = WSTaskRef()
        await taskRef.set(initialTask)

        let apiURLCopy = self.apiURL
        let indexersRef = self.indexers

        // Wrap the continuation in a holder so the cancellation handler
        // and the loop both see it; AsyncStream's continuation isn't
        // Sendable by default.
        var continuationBox: AsyncStream<SubscriptionPayload>.Continuation!
        let stream = AsyncStream<SubscriptionPayload> { c in
            continuationBox = c
        }
        let continuation = continuationBox!

        let loopTask = Task {
            await WillowSubscriptions.subscriptionLoop(
                initialTask: initialTask,
                initialIndexerDID: initialDID,
                apiURL: apiURLCopy,
                indexers: indexersRef,
                subgroveId: subgroveId,
                query: query,
                subId: subId,
                options: options,
                continuation: continuation,
                taskRef: taskRef
            )
        }

        // If the consumer drops the stream before calling unsubscribe,
        // make sure the loop still tears down cleanly.
        continuation.onTermination = { _ in
            loopTask.cancel()
        }

        return Subscription(
            stream: stream,
            loopTask: loopTask,
            taskRef: taskRef,
            subId: subId
        )
    }

    // MARK: - Connect / resolve

    /// Pick an endpoint (evicting any last-failed indexer first), open
    /// the WebSocket, and drive the graphql-transport-ws handshake.
    /// Returns `(task, indexerDID)`; `indexerDID` is `nil` for validator
    /// mode. On failure, closes any partially opened socket.
    func resolveAndConnect(
        subgroveId: String,
        query: String,
        subId: String,
        options: SubscribeOptions,
        skipIndexerDID: String?
    ) async throws -> (URLSessionWebSocketTask, String?) {
        let wsURL: URL
        var indexerDID: String? = nil

        switch options.source {
        case .validator:
            wsURL = httpToWS(apiURL).appendingPathComponent("graphql/ws")
        case .indexer:
            guard let indexers = indexers else {
                throw NetworkError(
                    "source=indexer requires a WillowIndexers instance"
                )
            }
            // Evict the failed indexer (if any) before re-resolving so
            // discovery picks a different candidate.
            if let did = skipIndexerDID {
                await indexers.evict(indexerDid: did)
            }
            let candidates = try await indexers.forSubgrove(subgroveId)
            if candidates.isEmpty {
                throw NetworkError(
                    "No indexer serves subgrove \"\(subgroveId)\" — cannot open indexer subscription"
                )
            }
            indexerDID = candidates[0].indexerDid
            guard
                let endpointURL = URL(
                    string: candidates[0].effectiveQueryEndpoint())
            else {
                throw NetworkError(
                    "Invalid query endpoint: \(candidates[0].effectiveQueryEndpoint())"
                )
            }
            wsURL = httpToWS(endpointURL).appendingPathComponent("graphql/ws")
        }

        let task = try await connectAndHandshake(
            wsURL: wsURL, subId: subId, query: query, options: options
        )
        return (task, indexerDID)
    }

    /// Open the WebSocket and drive the graphql-transport-ws handshake.
    /// On any failure, cancels the underlying task before propagating.
    private func connectAndHandshake(
        wsURL: URL,
        subId: String,
        query: String,
        options: SubscribeOptions
    ) async throws -> URLSessionWebSocketTask {
        var request = URLRequest(url: wsURL)
        request.setValue(
            "graphql-transport-ws",
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()

        do {
            let initPayload = options.connectionPayload ?? [:]
            try await sendFrame(
                task: task,
                frame: [
                    "type": "connection_init",
                    "payload": initPayload,
                ]
            )

            // Wait for connection_ack. Tolerate pings during handshake;
            // reject a connection_error frame loudly.
            while true {
                let msg = try await task.receive()
                guard let frame = decodeFrame(from: msg) else { continue }
                switch frame["type"] as? String {
                case "connection_ack":
                    break
                case "ping":
                    try await sendFrame(task: task, frame: ["type": "pong"])
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

            var subPayload: [String: Any] = ["query": query]
            if let vars = options.variables {
                subPayload["variables"] = vars
            }
            if let op = options.operationName {
                subPayload["operationName"] = op
            }
            try await sendFrame(
                task: task,
                frame: [
                    "type": "subscribe",
                    "id": subId,
                    "payload": subPayload,
                ]
            )
            return task
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            throw error
        }
    }

    // MARK: - Subscription loop

    private static func subscriptionLoop(
        initialTask: URLSessionWebSocketTask,
        initialIndexerDID: String?,
        apiURL: URL,
        indexers: WillowIndexers?,
        subgroveId: String,
        query: String,
        subId: String,
        options: SubscribeOptions,
        continuation: AsyncStream<SubscriptionPayload>.Continuation,
        taskRef: WSTaskRef
    ) async {
        defer { continuation.finish() }

        var task: URLSessionWebSocketTask? = initialTask
        var lastIndexerDID = initialIndexerDID
        var attempts = 0

        while let current = task {
            let exit = await pump(
                task: current, subId: subId, continuation: continuation
            )

            // Tear down current socket.
            current.cancel(with: .normalClosure, reason: nil)
            await taskRef.set(nil)
            task = nil

            if exit.kind == .serverComplete || exit.kind == .cancelled {
                return
            }
            if Task.isCancelled {
                return
            }
            if !options.reconnect {
                return
            }

            // Reset the retry counter only when the just-ended connection
            // actually delivered data. Without this rule, a server that
            // accepts the subscription but immediately drops the socket
            // would reset the counter on every cycle and loop forever.
            if exit.deliveredPayload {
                attempts = 0
            }

            // Inner retry loop: backoff, then try to reconnect.
            while task == nil {
                if let maxAtt = options.maxReconnectAttempts,
                    attempts >= maxAtt
                {
                    return
                }
                attempts += 1
                let delay = min(
                    options.reconnectBackoff * pow(2.0, Double(attempts - 1)),
                    options.maxReconnectBackoff
                )
                options.onReconnect?(attempts, delay)

                // Cancellation-sensitive sleep.
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                } catch {
                    // Task was cancelled during backoff.
                    return
                }

                // Re-resolve (indexer mode evicts lastIndexerDID first,
                // which is handled inside resolveAndConnect) and retry.
                // We need a WillowSubscriptions instance to call
                // resolveAndConnect, but the loop runs outside the actor
                // context — reconstruct the logic inline so we don't
                // need to re-enter the actor on each retry.
                do {
                    let (newTask, newDID) =
                        try await Self.reconnectOnce(
                            apiURL: apiURL,
                            indexers: indexers,
                            subgroveId: subgroveId,
                            query: query,
                            subId: subId,
                            options: options,
                            skipIndexerDID: lastIndexerDID
                        )
                    task = newTask
                    lastIndexerDID = newDID
                    await taskRef.set(newTask)
                } catch {
                    if Task.isCancelled {
                        return
                    }
                    // Loop around for another backoff + retry.
                    continue
                }
            }
        }
    }

    /// Performs the same resolve+connect+handshake as
    /// `resolveAndConnect`, but from a non-actor context. Duplicates a
    /// small amount of logic to avoid re-entering the actor on each
    /// reconnect attempt.
    private static func reconnectOnce(
        apiURL: URL,
        indexers: WillowIndexers?,
        subgroveId: String,
        query: String,
        subId: String,
        options: SubscribeOptions,
        skipIndexerDID: String?
    ) async throws -> (URLSessionWebSocketTask, String?) {
        let wsURL: URL
        var indexerDID: String? = nil

        switch options.source {
        case .validator:
            wsURL = httpToWS(apiURL).appendingPathComponent("graphql/ws")
        case .indexer:
            guard let indexers = indexers else {
                throw NetworkError(
                    "source=indexer requires a WillowIndexers instance"
                )
            }
            if let did = skipIndexerDID {
                await indexers.evict(indexerDid: did)
            }
            let candidates = try await indexers.forSubgrove(subgroveId)
            if candidates.isEmpty {
                throw NetworkError(
                    "No indexer serves subgrove \"\(subgroveId)\" — cannot open indexer subscription"
                )
            }
            indexerDID = candidates[0].indexerDid
            guard
                let endpointURL = URL(
                    string: candidates[0].effectiveQueryEndpoint())
            else {
                throw NetworkError(
                    "Invalid query endpoint: \(candidates[0].effectiveQueryEndpoint())"
                )
            }
            wsURL = httpToWS(endpointURL).appendingPathComponent("graphql/ws")
        }

        var request = URLRequest(url: wsURL)
        request.setValue(
            "graphql-transport-ws",
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()

        do {
            try await sendFrame(
                task: task,
                frame: [
                    "type": "connection_init",
                    "payload": options.connectionPayload ?? [:],
                ]
            )
            while true {
                let msg = try await task.receive()
                guard let frame = decodeFrame(from: msg) else { continue }
                switch frame["type"] as? String {
                case "connection_ack":
                    break
                case "ping":
                    try await sendFrame(task: task, frame: ["type": "pong"])
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
            var subPayload: [String: Any] = ["query": query]
            if let vars = options.variables {
                subPayload["variables"] = vars
            }
            if let op = options.operationName {
                subPayload["operationName"] = op
            }
            try await sendFrame(
                task: task,
                frame: [
                    "type": "subscribe",
                    "id": subId,
                    "payload": subPayload,
                ]
            )
            return (task, indexerDID)
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            throw error
        }
    }
}

// MARK: - Internal helpers

/// Holds the currently-active WebSocket task so ``Subscription`` can
/// send a best-effort `complete` on the right socket when the caller
/// unsubscribes, even after one or more reconnects have swapped the
/// underlying task out.
actor WSTaskRef {
    var task: URLSessionWebSocketTask?

    func set(_ t: URLSessionWebSocketTask?) {
        task = t
    }
}

enum PumpExitKind {
    case serverComplete
    case disconnected
    case cancelled
}

struct PumpExit {
    let kind: PumpExitKind
    let deliveredPayload: Bool
}

@Sendable
func pump(
    task: URLSessionWebSocketTask,
    subId: String,
    continuation: AsyncStream<SubscriptionPayload>.Continuation
) async -> PumpExit {
    var deliveredPayload = false

    while !Task.isCancelled {
        let msg: URLSessionWebSocketTask.Message
        do {
            // withTaskCancellationHandler ensures that cancelling the
            // outer Task also tears down the WebSocket task, so a
            // blocked `receive()` returns promptly.
            msg = try await withTaskCancellationHandler {
                try await task.receive()
            } onCancel: {
                task.cancel(with: .normalClosure, reason: nil)
            }
        } catch {
            if Task.isCancelled {
                return PumpExit(
                    kind: .cancelled, deliveredPayload: deliveredPayload
                )
            }
            return PumpExit(
                kind: .disconnected, deliveredPayload: deliveredPayload
            )
        }

        guard let frame = decodeFrame(from: msg) else { continue }
        switch frame["type"] as? String {
        case "next":
            guard (frame["id"] as? String) == subId else { continue }
            let payload = frame["payload"] as? [String: Any]
            let p = SubscriptionPayload(
                data: payload?["data"] as? [String: Any],
                errors: payload?["errors"]
            )
            continuation.yield(p)
            deliveredPayload = true
        case "complete":
            if (frame["id"] as? String) == subId {
                return PumpExit(
                    kind: .serverComplete, deliveredPayload: deliveredPayload
                )
            }
        case "error":
            if (frame["id"] as? String) == subId {
                continuation.yield(
                    SubscriptionPayload(data: nil, errors: frame["payload"])
                )
            }
        case "ping":
            try? await sendFrame(task: task, frame: ["type": "pong"])
        default:
            // Ignore unknown types.
            break
        }
    }
    return PumpExit(
        kind: .cancelled, deliveredPayload: deliveredPayload
    )
}

@Sendable
func sendFrame(
    task: URLSessionWebSocketTask, frame: [String: Any]
) async throws {
    let data = try JSONSerialization.data(withJSONObject: frame, options: [])
    guard let text = String(data: data, encoding: .utf8) else {
        throw NetworkError("Frame is not UTF-8 encodable")
    }
    try await task.send(.string(text))
}

@Sendable
func decodeFrame(
    from msg: URLSessionWebSocketTask.Message
) -> [String: Any]? {
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

func httpToWS(_ url: URL) -> URL {
    let s = url.absoluteString
    var mapped = s
    if s.hasPrefix("https://") {
        mapped = "wss://" + s.dropFirst("https://".count)
    } else if s.hasPrefix("http://") {
        mapped = "ws://" + s.dropFirst("http://".count)
    }
    return URL(string: mapped) ?? url
}
