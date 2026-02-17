import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "WebSocket")

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
    /// Uses the workspace-scoped v2 WS path.
    func connect(sessionId: String, workspaceId: String) -> AsyncStream<ServerMessage> {
        // Disconnect previous connection
        disconnect()

        connectionID &+= 1
        let thisConnection = connectionID
        connectedSessionId = sessionId
        connectedWorkspaceId = workspaceId
        status = .connecting
        wsLogInfo(
            "Connect requested",
            metadata: [
                "sessionId": sessionId,
                "workspaceId": workspaceId,
            ]
        )

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
        let data = try message.jsonString()
        let sendTimeout = self.sendTimeout

        do {
            // NOTE: do NOT use TaskGroup timeout racing here.
            // If `ws.send` hangs and ignores cancellation, TaskGroup waits forever
            // for child task teardown, which wedges the send path.
            try await sendWithTimeout(payload: data, over: ws, timeout: sendTimeout)
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
                    if connectedSessionId != nil {
                        attemptReconnect()
                    } else {
                        status = .disconnected
                    }
                }
            }
            throw error
        }
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
    /// Returns true if connected, false if timed out or disconnected.
    private func waitForConnection() async throws -> Bool {
        // Already disconnected with no reconnect in progress — don't wait
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
        inboundMetaQueue.removeAll(keepingCapacity: false)

        connectedSessionId = nil
        connectedWorkspaceId = nil
        status = .disconnected
    }

    // MARK: - Private

    private func wsLogMetadata(extra: [String: String] = [:]) -> [String: String] {
        var metadata = extra
        metadata["sessionId"] = connectedSessionId ?? metadata["sessionId"] ?? "unknown"
        metadata["status"] = String(describing: status)
        metadata["connectionID"] = String(connectionID)
        if let connectedWorkspaceId {
            metadata["workspaceId"] = connectedWorkspaceId
        }
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

    private func openWebSocket(sessionId: String, workspaceId: String, continuation: AsyncStream<ServerMessage>.Continuation) {
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

        startReceiveLoop(ws: ws, continuation: continuation)
        startPingTimer(ws: ws)
    }

    private func startReceiveLoop(ws: URLSessionWebSocketTask, continuation: AsyncStream<ServerMessage>.Continuation) {
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

                    let serverMessage: ServerMessage
                    do {
                        serverMessage = try ServerMessage.decode(from: text)
                    } catch {
                        // Log decode error but DON'T break — keep the stream alive.
                        // MUST be .error — .warning/.info are NOT persisted in device log archives.
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
                    self?.wsLogError(
                        "WebSocket receive error",
                        metadata: ["error": String(describing: error)]
                    )
                    break
                }
            }

            // Connection lost — attempt reconnect
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

                // Guard: skip ping if the task is no longer running.
                // This avoids sending pings into a cancelled/completed task.
                guard ws.state == .running else { break }

                // Use a one-shot wrapper around the continuation because
                // URLSessionWebSocketTask.sendPing can invoke its completion
                // handler more than once when the task is cancelled during an
                // in-flight ping (race with reconnect/disconnect paths).
                // withCheckedContinuation crashes on double-resume; the
                // OneShotPingContinuation silently drops subsequent resumes.
                let failed = await withUnsafeContinuation { (cont: UnsafeContinuation<Bool, Never>) in
                    let oneShot = OneShotPingContinuation(cont)
                    ws.sendPing { error in
                        oneShot.resume(returning: error != nil)
                    }
                }

                if failed {
                    consecutiveFailures += 1
                    // Two consecutive failures → treat as dead connection.
                    // Single failures can be transient (brief network blip).
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
        guard let sessionId = connectedSessionId else { return }

        var attempt = 0
        if case .reconnecting(let a) = status { attempt = a }

        guard attempt < maxReconnectAttempts else {
            logger.error("Max reconnect attempts reached")
            wsLogError("Max reconnect attempts reached", metadata: ["sessionId": sessionId])
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
                guard let self,
                      let cont = self.continuation,
                      let workspaceId = self.connectedWorkspaceId,
                      !workspaceId.isEmpty else { return }
                self.openWebSocket(sessionId: sessionId, workspaceId: workspaceId, continuation: cont)
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

// MARK: - One-Shot Ping Continuation

/// Thread-safe wrapper that ensures an `UnsafeContinuation` is resumed
/// exactly once. Subsequent calls to `resume(returning:)` are silently
/// dropped. This prevents crashes when `URLSessionWebSocketTask.sendPing`
/// invokes its completion handler more than once during cancellation races.
private final class OneShotPingContinuation: @unchecked Sendable {
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
