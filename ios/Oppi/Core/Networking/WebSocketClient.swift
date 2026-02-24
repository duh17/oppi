import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "WebSocket")

/// WebSocket client for the multiplexed `/stream` endpoint.
///
/// Returns an `AsyncStream<StreamMessage>` from `connect()`.
/// Handles keepalive pings, reconnection, and cleanup.
///
/// Each server gets one persistent `/stream` WebSocket. Sessions are
/// subscribed/unsubscribed via `subscribe`/`unsubscribe` commands
/// sent over the same connection.
@MainActor @Observable
final class WebSocketClient {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    private(set) var status: Status = .disconnected

    /// Monotonic ID incremented on each `connect()` call.
    /// Used to prevent stale `onTermination` handlers from killing newer connections.
    private var connectionID: UInt64 = 0

    struct InboundMeta: Sendable, Equatable {
        let seq: Int?
        let currentSeq: Int?
    }

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var continuation: AsyncStream<StreamMessage>.Continuation?
    private var inboundMetaQueueBySessionID: [String: [InboundMeta]] = [:]
    private var lastReceiveErrorFingerprint: String?
    private var lastReceiveErrorLogNs: UInt64 = 0

    /// Deduplicate repeated receive error logs (common during lifecycle
    /// transitions) while preserving first occurrence signal.
    private let receiveErrorLogCooldownNs: UInt64 = 3_000_000_000

    /// Active subscriptions tracked for resubscription after reconnect.
    /// Key: sessionId, Value: subscription level.
    private(set) var activeSubscriptions: [String: StreamSubscriptionLevel] = [:]

    let credentials: ServerCredentials
    private let urlSession: URLSession

    private let maxReconnectAttempts = 10
    private let pingInterval: Duration = .seconds(30)
    private let waitForConnectionTimeout: Duration
    private let waitPollInterval: Duration
    private let sendTimeout: Duration

    init(
        credentials: ServerCredentials,
        waitForConnectionTimeout: Duration = .seconds(3),
        waitPollInterval: Duration = .milliseconds(100),
        sendTimeout: Duration = .seconds(5)
    ) {
        self.credentials = credentials
        self.waitForConnectionTimeout = waitForConnectionTimeout
        self.waitPollInterval = waitPollInterval
        self.sendTimeout = sendTimeout
        let config = URLSessionConfiguration.default
        // No timeout for WebSocket — we handle keepalive ourselves
        config.timeoutIntervalForRequest = 60
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Connect

    /// Connect to the server's multiplexed `/stream` WebSocket.
    ///
    /// Disconnects any existing connection first.
    /// Returns an `AsyncStream` that yields `StreamMessage` (message + sessionId)
    /// until disconnect.
    ///
    /// The first message will be `streamConnected(userName:)`.
    /// After reconnection, `streamConnected` is yielded again — ServerConnection
    /// uses this as the signal to re-subscribe to sessions.
    func connect() -> AsyncStream<StreamMessage> {
        // Disconnect previous connection
        disconnect()

        connectionID &+= 1
        let thisConnection = connectionID
        status = .connecting
        wsLogInfo("Connect requested to /stream")

        return AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            self?.openStreamWebSocket(continuation: continuation)

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.connectionID == thisConnection else { return }
                    self.disconnect()
                }
            }
        }
    }

    // MARK: - Send

    /// Send a client message over the WebSocket.
    ///
    /// For session-scoped commands on `/stream`, provide `sessionId` to wrap
    /// the message in a `SessionScopedMessage` envelope.
    /// Commands like `subscribe`, `unsubscribe`, and `permission_response` don't
    /// need a sessionId wrapper (they include it in their own encoding).
    ///
    /// If the connection is reconnecting, waits briefly before failing.
    func send(_ message: ClientMessage, sessionId: String? = nil) async throws {
        // Wait for connection if reconnecting (background → foreground)
        if status != .connected {
            let waited = try await waitForConnection()
            if !waited {
                logger.error("WS send: wait failed, throwing notConnected")
                wsLogError("Send failed waiting for connection")
                throw WebSocketError.notConnected
            }
        }

        guard let ws = webSocket, status == .connected else {
            logger.error("WS send: guard failed — ws=\(self.webSocket != nil) status=\(String(describing: self.status))")
            wsLogError(
                "Send guard failed",
                metadata: [
                    "hasSocket": String(self.webSocket != nil),
                    "status": String(describing: self.status),
                ]
            )
            throw WebSocketError.notConnected
        }

        // Encode with session scope if needed
        let payload: String
        if let sessionId, !Self.isStreamLevelCommand(message) {
            payload = try SessionScopedMessage(sessionId: sessionId, message: message).jsonString()
        } else {
            payload = try message.jsonString()
        }

        let sendTimeout = self.sendTimeout

        do {
            try await sendWithTimeout(payload: payload, over: ws, timeout: sendTimeout)
        } catch {
            if let wsError = error as? WebSocketError, case .sendTimeout = wsError {
                logger.error("WS send timed out for \(message.typeLabel, privacy: .public) — forcing reconnect")
                wsLogError(
                    "WS send timed out",
                    metadata: ["type": message.typeLabel]
                )
                if self.webSocket === ws {
                    ws.cancel(with: .goingAway, reason: nil)
                    self.webSocket = nil
                    attemptReconnect()
                }
            }
            throw error
        }

        // Track subscription state
        trackSubscription(message)
    }

    // MARK: - Subscription Tracking

    /// Track subscribe/unsubscribe commands for reconnect resubscription.
    private func trackSubscription(_ message: ClientMessage) {
        switch message {
        case .subscribe(let sessionId, let level, _, _):
            activeSubscriptions[sessionId] = level
            inboundMetaQueueBySessionID.removeValue(forKey: sessionId)
        case .unsubscribe(let sessionId, _):
            activeSubscriptions.removeValue(forKey: sessionId)
            inboundMetaQueueBySessionID.removeValue(forKey: sessionId)
        default:
            break
        }
    }

    /// Commands that include their own sessionId and don't need the envelope.
    nonisolated private static func isStreamLevelCommand(_ message: ClientMessage) -> Bool {
        switch message {
        case .subscribe, .unsubscribe, .permissionResponse:
            return true
        default:
            return false
        }
    }

    /// Send payload with a hard timeout that cannot be wedged by a stuck async send.
    private func sendWithTimeout(
        payload: String,
        over ws: URLSessionWebSocketTask,
        timeout: Duration
    ) async throws {
        let timeoutMs = Self.durationMilliseconds(timeout)
        let baseMetadata = wsLogMetadata()

        try await withCheckedThrowingContinuation { continuation in
            let resolver = SendResolver(continuation: continuation)

            let timeoutWorkItem = DispatchWorkItem {
                logger.error("WS send hard timeout fired (\(timeoutMs)ms)")
                ClientLog.error(
                    "WebSocket",
                    "WS send hard timeout fired",
                    metadata: Self.mergeMetadata(baseMetadata, extra: ["timeoutMs": String(timeoutMs)])
                )
                resolver.resolve(.failure(WebSocketError.sendTimeout))
            }
            resolver.setTimeoutWorkItem(timeoutWorkItem)

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(timeoutMs),
                execute: timeoutWorkItem
            )

            ws.send(.string(payload)) { error in
                if let error {
                    logger.error("WS send callback error: \(String(describing: error), privacy: .public)")
                    ClientLog.error(
                        "WebSocket",
                        "WS send callback error",
                        metadata: Self.mergeMetadata(baseMetadata, extra: ["error": String(describing: error)])
                    )
                    resolver.resolve(.failure(error))
                } else {
                    resolver.resolve(.success(()))
                }
            }
        }
    }

    /// Wait for the connection to reach `.connected` state.
    private func waitForConnection() async throws -> Bool {
        if status == .disconnected { return false }

        let deadline = ContinuousClock.now + waitForConnectionTimeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: waitPollInterval)
            if status == .connected { return true }
            if status == .disconnected { return false }
        }
        return false
    }

    /// Disconnect and clean up.
    func disconnect() {
        wsLogInfo(
            "Disconnect",
            metadata: [
                "hasSocket": String(webSocket != nil),
                "hasReceiveTask": String(receiveTask != nil),
                "hasPingTask": String(pingTask != nil),
                "hasReconnectTask": String(reconnectTask != nil),
                "subscriptions": String(activeSubscriptions.count),
            ]
        )

        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil

        continuation?.finish()
        continuation = nil
        inboundMetaQueueBySessionID.removeAll(keepingCapacity: false)
        activeSubscriptions.removeAll()
        lastReceiveErrorFingerprint = nil
        lastReceiveErrorLogNs = 0

        status = .disconnected
    }

    // MARK: - Private

    private func wsLogMetadata(extra: [String: String] = [:]) -> [String: String] {
        var metadata = extra
        metadata["status"] = String(describing: status)
        metadata["connectionID"] = String(connectionID)
        metadata["subscriptions"] = activeSubscriptions.keys.joined(separator: ",")
        return metadata
    }

    nonisolated private static func mergeMetadata(
        _ base: [String: String],
        extra: [String: String]
    ) -> [String: String] {
        var merged = base
        for (key, value) in extra {
            merged[key] = value
        }
        return merged
    }

    private func wsLogInfo(_ message: String, metadata: [String: String] = [:]) {
        ClientLog.info("WebSocket", message, metadata: wsLogMetadata(extra: metadata))
    }

    private func wsLogError(_ message: String, metadata: [String: String] = [:]) {
        ClientLog.error("WebSocket", message, metadata: wsLogMetadata(extra: metadata))
    }

    private func shouldLogReceiveError(_ error: Error) -> Bool {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let fingerprint = String(describing: error)

        if lastReceiveErrorFingerprint == fingerprint,
           nowNs &- lastReceiveErrorLogNs < receiveErrorLogCooldownNs {
            return false
        }

        lastReceiveErrorFingerprint = fingerprint
        lastReceiveErrorLogNs = nowNs
        return true
    }

    private func openStreamWebSocket(continuation: AsyncStream<StreamMessage>.Continuation) {
        guard let url = credentials.streamURL else {
            logger.error("Invalid /stream URL — disconnecting")
            disconnect()
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")

        let ws = urlSession.webSocketTask(with: request)
        self.webSocket = ws
        ws.resume()

        startReceiveLoop(ws: ws, continuation: continuation)
        startPingTimer(ws: ws)
    }

    private func startReceiveLoop(ws: URLSessionWebSocketTask, continuation: AsyncStream<StreamMessage>.Continuation) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let wsMessage = try await ws.receive()
                    let text: String
                    switch wsMessage {
                    case .string(let s):
                        text = s
                    case .data(let d):
                        text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default:
                        continue
                    }

                    let streamMessage: StreamMessage
                    do {
                        streamMessage = try StreamMessage.decode(from: text)
                    } catch {
                        logger.error("PIPE: DECODE FAILED: \(error.localizedDescription, privacy: .public) — raw: \(text.prefix(300), privacy: .public)")
                        self?.wsLogError(
                            "PIPE decode failed",
                            metadata: [
                                "error": error.localizedDescription,
                                "rawPrefix": String(text.prefix(120)),
                            ]
                        )
                        continue
                    }

                    let inboundMeta = InboundMeta(seq: streamMessage.seq, currentSeq: streamMessage.currentSeq)
                    await MainActor.run {
                        guard let self,
                              let sessionId = streamMessage.sessionId,
                              !sessionId.isEmpty,
                              self.activeSubscriptions[sessionId] == .full else {
                            return
                        }

                        var queue = self.inboundMetaQueueBySessionID[sessionId] ?? []
                        queue.append(inboundMeta)
                        // Cap per-session queue to prevent unbounded growth if
                        // messages arrive faster than they are consumed.
                        if queue.count > 100 {
                            queue.removeFirst(queue.count - 100)
                        }
                        self.inboundMetaQueueBySessionID[sessionId] = queue
                    }

                    // First successful message = connected
                    await MainActor.run {
                        if case .connecting = self?.status {
                            self?.status = .connected
                        } else if case .reconnecting = self?.status {
                            self?.status = .connected
                        }
                    }

                    if case .unknown(let type) = streamMessage.message {
                        logger.debug("Received unknown server message: \(type)")
                    }

                    continuation.yield(streamMessage)
                } catch {
                    if Task.isCancelled { break }
                    if let self, self.shouldLogReceiveError(error) {
                        logger.error("WebSocket receive error: \(error)")
                        self.wsLogError(
                            "WebSocket receive error",
                            metadata: ["error": String(describing: error)]
                        )
                    } else {
                        logger.debug("Suppressed duplicate WebSocket receive error: \(String(describing: error), privacy: .public)")
                    }
                    break
                }
            }

            // Connection lost — attempt reconnect
            await MainActor.run {
                self?.attemptReconnect()
            }
        }
    }

    private func startPingTimer(ws: URLSessionWebSocketTask) {
        pingTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pingInterval ?? .seconds(30))
                guard !Task.isCancelled else { break }

                guard ws.state == .running else { break }

                let failed = await withUnsafeContinuation { (cont: UnsafeContinuation<Bool, Never>) in
                    let oneShot = OneShotPingContinuation(cont)
                    ws.sendPing { error in
                        oneShot.resume(returning: error != nil)
                    }
                }

                if failed {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 2 {
                        logger.error("Ping watchdog: \(consecutiveFailures) consecutive failures — triggering reconnect")
                        self?.wsLogError(
                            "Ping watchdog reconnect",
                            metadata: ["failures": String(consecutiveFailures)]
                        )
                        await MainActor.run { [weak self] in
                            self?.receiveTask?.cancel()
                            self?.receiveTask = nil
                            ws.cancel(with: .goingAway, reason: nil)
                            self?.webSocket = nil
                            self?.attemptReconnect()
                        }
                        break
                    }
                } else {
                    consecutiveFailures = 0
                }
            }
        }
    }

    private func attemptReconnect() {
        // Don't reconnect if explicitly disconnected (no subscriptions = intentional)
        guard status != .disconnected else { return }

        var attempt = 0
        if case .reconnecting(let a) = status { attempt = a }

        guard attempt < maxReconnectAttempts else {
            logger.error("Max reconnect attempts reached")
            wsLogError("Max reconnect attempts reached")
            disconnect()
            return
        }

        let nextAttempt = attempt + 1
        status = .reconnecting(attempt: nextAttempt)
        let delay = Self.reconnectDelay(attempt: nextAttempt)

        // Cancel old tasks
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let cont = self.continuation else { return }
                self.openStreamWebSocket(continuation: cont)
            }
        }
    }

    func consumeInboundMeta(sessionId: String) -> InboundMeta? {
        guard var queue = inboundMetaQueueBySessionID[sessionId], !queue.isEmpty else {
            return nil
        }

        let meta = queue.removeFirst()
        if queue.isEmpty {
            inboundMetaQueueBySessionID.removeValue(forKey: sessionId)
        } else {
            inboundMetaQueueBySessionID[sessionId] = queue
        }
        return meta
    }

    /// Exponential backoff with jitter: 2^(attempt-1) seconds, capped at 30s, ±25% jitter.
    nonisolated static func reconnectDelay(attempt: Int) -> TimeInterval {
        let base = min(pow(2, Double(attempt - 1)), 30)
        let jitterFactor = Double.random(in: 0.75...1.25)
        return base * jitterFactor
    }

    /// Convert `Duration` to positive milliseconds for GCD timers.
    nonisolated private static func durationMilliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let wholeMs = Double(components.seconds) * 1_000
        let fractionalMs = Double(components.attoseconds) / 1_000_000_000_000_000
        return max(1, Int((wholeMs + fractionalMs).rounded(.up)))
    }

    /// Test seam for deterministic send/reconnect behavior tests.
    func _setStatusForTesting(_ status: Status) {
        self.status = status
    }

    /// Thread-safe one-shot resolver for callback + timeout races.
    ///
    /// SAFETY (`@unchecked Sendable`):
    /// - Mutable state (`continuation`, `timeoutWorkItem`) is protected by `lock`.
    /// - `resolve(_:)` is one-shot: first caller nils stored state; subsequent callers no-op.
    /// - Continuation resume happens after lock release, preventing re-entrancy while locked.
    private final class SendResolver: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeoutWorkItem: DispatchWorkItem?

        init(continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func setTimeoutWorkItem(_ workItem: DispatchWorkItem) {
            lock.lock()
            timeoutWorkItem = workItem
            lock.unlock()
        }

        func resolve(_ result: Result<Void, Error>) {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            let timeoutWorkItem = self.timeoutWorkItem
            self.timeoutWorkItem = nil
            lock.unlock()

            timeoutWorkItem?.cancel()
            continuation.resume(with: result)
        }
    }
}

// MARK: - One-Shot Ping Continuation

private final class OneShotPingContinuation: @unchecked Sendable {
    // SAFETY (`@unchecked Sendable`):
    // - `continuation` is protected by `lock` and consumed exactly once.
    // - Resume is always executed after lock release.
    // - Double-resume is prevented by nil-ing `continuation` under lock.
    private var continuation: UnsafeContinuation<Bool, Never>?
    private let lock = NSLock()

    init(_ continuation: UnsafeContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Bool) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}

// MARK: - Errors

enum WebSocketError: LocalizedError {
    case notConnected
    case sendTimeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return "WebSocket not connected"
        case .sendTimeout: return "Send timed out — server may still be starting"
        }
    }
}
