import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.PiRemote", category: "WebSocket")

/// WebSocket client for streaming session events.
///
/// Returns an `AsyncStream<ServerMessage>` from `connect()`.
/// Handles keepalive pings, reconnection, and cleanup.
///
/// v1 policy: one active WebSocket at a time. Opening a new connection
/// disconnects the previous one.
@MainActor @Observable
final class WebSocketClient {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    private(set) var status: Status = .disconnected
    private(set) var connectedSessionId: String?
    private var connectedWorkspaceId: String?

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
    private var continuation: AsyncStream<ServerMessage>.Continuation?
    private var inboundMetaQueue: [InboundMeta] = []

    private let credentials: ServerCredentials
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

    /// Connect to a session's WebSocket stream.
    ///
    /// Disconnects any existing connection first (v1 one-stream policy).
    /// Returns an `AsyncStream` that yields `ServerMessage` until disconnect.
    ///
    /// When `workspaceId` is provided, uses the v2 workspace-scoped WS path.
    func connect(sessionId: String, workspaceId: String? = nil) -> AsyncStream<ServerMessage> {
        // Disconnect previous connection
        disconnect()

        connectionID &+= 1
        let thisConnection = connectionID
        connectedSessionId = sessionId
        connectedWorkspaceId = workspaceId
        status = .connecting

        return AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            self?.openWebSocket(sessionId: sessionId, workspaceId: workspaceId, continuation: continuation)

            // Guard: only disconnect if WE are still the active connection.
            // Without this, a stale stream's onTermination fires async and
            // kills a newer connection that already took over.
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.connectionID == thisConnection else { return }
                    self.disconnect()
                }
            }
        }
    }

    /// Send a client message over the WebSocket.
    ///
    /// If the connection is in `.connecting` or `.reconnecting` state (e.g.,
    /// app returning from background), waits for a bounded window before
    /// giving up. This prevents messages from being silently dropped during
    /// brief reconnect windows while still failing fast.
    ///
    /// Once connected, enforces a bounded send timeout to prevent hangs.
    func send(_ message: ClientMessage) async throws {
        // NOTE: All logger calls in send() use .error level intentionally.
        // os.log .info/.warning are NOT persisted in device log archives,
        // so .error is the minimum level that survives for post-hoc debugging.

        // Wait for connection if reconnecting (background → foreground)
        if status != .connected {
            logger.error("WS send: status=\(String(describing: self.status)), waiting for connection...")
            ClientLog.warning(
                "WebSocket",
                "Send waiting for connection",
                metadata: ["status": String(describing: status)]
            )
            let waited = try await waitForConnection()
            if !waited {
                logger.error("WS send: wait failed, throwing notConnected")
                ClientLog.error("WebSocket", "Send failed waiting for connection")
                throw WebSocketError.notConnected
            }
            logger.error("WS send: wait succeeded, now connected")
            ClientLog.info("WebSocket", "Send wait succeeded")
        }

        guard let ws = webSocket, status == .connected else {
            logger.error("WS send: guard failed — ws=\(self.webSocket != nil) status=\(String(describing: self.status))")
            ClientLog.error(
                "WebSocket",
                "Send guard failed",
                metadata: [
                    "hasSocket": String(self.webSocket != nil),
                    "status": String(describing: self.status),
                ]
            )
            throw WebSocketError.notConnected
        }
        let data = try message.jsonString()
        logger.error("WS send: \(message.typeLabel) (\(data.count) bytes)")
        ClientLog.info(
            "WebSocket",
            "WS send",
            metadata: ["type": message.typeLabel, "bytes": String(data.count)]
        )
        let sendTimeout = self.sendTimeout

        do {
            // NOTE: do NOT use TaskGroup timeout racing here.
            // If `ws.send` hangs and ignores cancellation, TaskGroup waits forever
            // for child task teardown, which wedges the send path.
            try await sendWithTimeout(payload: data, over: ws, timeout: sendTimeout)
        } catch {
            if let wsError = error as? WebSocketError, case .sendTimeout = wsError {
                logger.error("WS send timed out for \(message.typeLabel, privacy: .public) — forcing reconnect")
                ClientLog.error(
                    "WebSocket",
                    "WS send timed out",
                    metadata: ["type": message.typeLabel]
                )
                if self.webSocket === ws {
                    ws.cancel(with: .goingAway, reason: nil)
                    self.webSocket = nil
                    if connectedSessionId != nil {
                        attemptReconnect()
                    } else {
                        status = .disconnected
                    }
                }
            }
            throw error
        }

        logger.error("WS send: \(message.typeLabel) complete")
        ClientLog.info("WebSocket", "WS send complete", metadata: ["type": message.typeLabel])
    }

    /// Send payload with a hard timeout that cannot be wedged by a stuck async send.
    ///
    /// Uses callback-based `URLSessionWebSocketTask.send` plus a timeout task.
    /// Whichever path resolves first wins; late completions are ignored.
    private func sendWithTimeout(
        payload: String,
        over ws: URLSessionWebSocketTask,
        timeout: Duration
    ) async throws {
        let timeoutMs = Self.durationMilliseconds(timeout)

        try await withCheckedThrowingContinuation { continuation in
            let resolver = SendResolver(continuation: continuation)

            let timeoutWorkItem = DispatchWorkItem {
                logger.error("WS send hard timeout fired (\(timeoutMs)ms)")
                ClientLog.error(
                    "WebSocket",
                    "WS send hard timeout fired",
                    metadata: ["timeoutMs": String(timeoutMs)]
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
                        metadata: ["error": String(describing: error)]
                    )
                    resolver.resolve(.failure(error))
                } else {
                    logger.error("WS send callback success")
                    ClientLog.info("WebSocket", "WS send callback success")
                    resolver.resolve(.success(()))
                }
            }
        }
    }

    /// Wait for the connection to reach `.connected` state.
    /// Returns true if connected, false if timed out or disconnected.
    private func waitForConnection() async throws -> Bool {
        // Already disconnected with no reconnect in progress — don't wait
        if status == .disconnected { return false }

        logger.info("Waiting for connection (status: \(String(describing: self.status)))")
        let deadline = ContinuousClock.now + waitForConnectionTimeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: waitPollInterval)
            if status == .connected { return true }
            if status == .disconnected { return false }
        }
        logger.warning("Timed out waiting for connection")
        return false
    }

    /// Disconnect and clean up.
    func disconnect() {
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
        inboundMetaQueue.removeAll(keepingCapacity: false)

        connectedSessionId = nil
        connectedWorkspaceId = nil
        status = .disconnected
    }

    // MARK: - Private

    private func openWebSocket(sessionId: String, workspaceId: String? = nil, continuation: AsyncStream<ServerMessage>.Continuation) {
        guard let url = credentials.webSocketURL(sessionId: sessionId, workspaceId: workspaceId) else {
            logger.error("Invalid WebSocket URL for session \(sessionId) — disconnecting")
            disconnect()
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")

        let ws = urlSession.webSocketTask(with: request)
        self.webSocket = ws
        ws.resume()

        logger.info("Connecting to \(url.absoluteString)")

        startReceiveLoop(ws: ws, continuation: continuation)
        startPingTimer(ws: ws)
    }

    private func startReceiveLoop(ws: URLSessionWebSocketTask, continuation: AsyncStream<ServerMessage>.Continuation) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    MainThreadBreadcrumb.set("ws-receive-await")
                    let wsMessage = try await ws.receive()
                    MainThreadBreadcrumb.set("ws-decode")
                    let text: String
                    switch wsMessage {
                    case .string(let s):
                        text = s
                    case .data(let d):
                        text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default:
                        continue
                    }

                    let serverMessage: ServerMessage
                    do {
                        serverMessage = try ServerMessage.decode(from: text)
                    } catch {
                        // Log decode error but DON'T break — keep the stream alive.
                        // MUST be .error — .warning/.info are NOT persisted in device log archives.
                        logger.error("PIPE: DECODE FAILED: \(error.localizedDescription, privacy: .public) — raw: \(text.prefix(300), privacy: .public)")
                        ClientLog.error(
                            "WebSocket",
                            "PIPE decode failed",
                            metadata: ["error": error.localizedDescription]
                        )
                        continue
                    }

                    let inboundMeta = Self.extractInboundMeta(from: text)
                    await MainActor.run {
                        self?.inboundMetaQueue.append(inboundMeta)
                    }

                    // First successful message = connected
                    await MainActor.run {
                        if case .connecting = self?.status {
                            self?.status = .connected
                        } else if case .reconnecting = self?.status {
                            self?.status = .connected
                        }
                    }

                    if case .unknown(let type) = serverMessage {
                        logger.debug("Received unknown server message: \(type)")
                    }

                    continuation.yield(serverMessage)
                } catch {
                    if Task.isCancelled { break }
                    logger.error("WebSocket receive error: \(error)")
                    ClientLog.error(
                        "WebSocket",
                        "WebSocket receive error",
                        metadata: ["error": String(describing: error)]
                    )
                    break
                }
            }

            // Connection lost — attempt reconnect
            logger.error("Receive loop exited — cancelled=\(Task.isCancelled)")
            ClientLog.warning(
                "WebSocket",
                "Receive loop exited",
                metadata: ["cancelled": String(Task.isCancelled)]
            )
            await MainActor.run {
                guard let self, self.connectedSessionId != nil else { return }
                self.attemptReconnect()
            }
        }
    }

    private func startPingTimer(ws: URLSessionWebSocketTask) {
        pingTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pingInterval ?? .seconds(30))
                guard !Task.isCancelled else { break }

                let failed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    ws.sendPing { error in
                        cont.resume(returning: error != nil)
                        if let error {
                            logger.warning("Ping failed: \(error)")
                        }
                    }
                }

                if failed {
                    consecutiveFailures += 1
                    // Two consecutive failures → treat as dead connection.
                    // Single failures can be transient (brief network blip).
                    if consecutiveFailures >= 2 {
                        logger.error("Ping watchdog: \(consecutiveFailures) consecutive failures — triggering reconnect")
                        ClientLog.error(
                            "WebSocket",
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
        guard let sessionId = connectedSessionId else { return }

        var attempt = 0
        if case .reconnecting(let a) = status { attempt = a }

        guard attempt < maxReconnectAttempts else {
            logger.error("Max reconnect attempts reached")
            ClientLog.error("WebSocket", "Max reconnect attempts reached", metadata: ["sessionId": sessionId])
            disconnect()
            return
        }

        let nextAttempt = attempt + 1
        status = .reconnecting(attempt: nextAttempt)
        let delay = Self.reconnectDelay(attempt: nextAttempt)
        logger.info("Reconnecting in \(delay)s (attempt \(nextAttempt))")

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
                self.openWebSocket(sessionId: sessionId, workspaceId: self.connectedWorkspaceId, continuation: cont)
            }
        }
    }

    func consumeInboundMeta() -> InboundMeta? {
        guard !inboundMetaQueue.isEmpty else { return nil }
        return inboundMetaQueue.removeFirst()
    }

    /// Exponential backoff with jitter: 2^(attempt-1) seconds, capped at 30s, ±25% jitter.
    /// Jitter prevents thundering herd when server restarts with multiple clients.
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

    private static func extractInboundMeta(from text: String) -> InboundMeta {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return InboundMeta(seq: nil, currentSeq: nil)
        }

        let seq = (object["seq"] as? NSNumber)?.intValue
        let currentSeq = (object["currentSeq"] as? NSNumber)?.intValue
        return InboundMeta(seq: seq, currentSeq: currentSeq)
    }

    /// Test seam for deterministic send/reconnect behavior tests.
    func _setStatusForTesting(_ status: Status) {
        self.status = status
    }

    /// Test seam for lifecycle race tests that need to simulate ownership handoff.
    func _setConnectedSessionIdForTesting(_ sessionId: String?) {
        self.connectedSessionId = sessionId
    }

    /// Thread-safe one-shot resolver for callback + timeout races.
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
