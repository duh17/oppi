import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "WebSocket")

/// WebSocket client for the active focused-session stream endpoint.
///
/// Returns an `AsyncStream<StreamFrameEvent>` from `connect()`.
/// Handles keepalive pings, reconnection, and cleanup for the URL-bound
/// session stream prepared by `ServerConnection`.
@MainActor @Observable
final class WebSocketClient {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    private(set) var status: Status = .disconnected
    private(set) var lastHTTPStatusCode: Int?

    /// Monotonic ID incremented on each `connect()` call.
    /// Used to prevent stale `onTermination` handlers from killing newer connections.
    private var connectionID: UInt64 = 0

    typealias InboundMeta = InboundStreamMeta

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var continuation: AsyncStream<StreamFrameEvent>.Continuation?
    private var lastReceiveErrorFingerprint: String?
    private var lastReceiveErrorLogNs: UInt64 = 0
    private var suppressedReceiveErrorCount = 0

    /// Deduplicate repeated receive error uploads while preserving first
    /// occurrence and periodic/terminal summaries. Reconnect storms can last
    /// minutes; logging every backoff attempt hides rarer failures.
    private let receiveErrorLogCooldownNs: UInt64 = 60_000_000_000

    let credentials: ServerCredentials
    private var preferredEndpoint: EndpointSelection?
    private var streamURL: URL?
    private var diagnosticSessionId: String?
    private var diagnosticWorkspaceId: String?
    private let diagnosticRole: String
    private let urlSession: URLSession
    private let trustDelegate: PinnedServerTrustDelegate

    private let maxReconnectAttempts = 10
    private let pingInterval: Duration = .seconds(30)
    private let waitForConnectionTimeout: Duration
    private let sendTimeout: Duration

    /// Continuations waiting for `.connected` status. Resolved on status
    /// transition to `.connected` or `.disconnected`.
    private var connectionWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    private var nextWaiterId: UInt64 = 0

    init(
        credentials: ServerCredentials,
        preferredEndpoint: EndpointSelection? = nil,
        diagnosticRole: String = "focused_session",
        waitForConnectionTimeout: Duration = .seconds(3),
        sendTimeout: Duration = .seconds(5)
    ) {
        self.credentials = credentials
        self.preferredEndpoint = preferredEndpoint
        self.diagnosticRole = diagnosticRole
        self.waitForConnectionTimeout = waitForConnectionTimeout
        self.sendTimeout = sendTimeout
        self.trustDelegate = PinnedServerTrustDelegate(
            pinnedLeafFingerprint: credentials.normalizedTLSCertFingerprint
        )
        let config = URLSessionConfiguration.default
        // No timeout for WebSocket — we handle keepalive ourselves
        config.timeoutIntervalForRequest = 60
        self.urlSession = URLSession(
            configuration: config,
            delegate: trustDelegate,
            delegateQueue: nil
        )
    }

    // MARK: - Connect

    /// Connect to the configured session WebSocket endpoint.
    ///
    /// Disconnects any existing connection first.
    /// Returns an `AsyncStream` that yields `StreamFrameEvent` (message + sessionId + metadata)
    /// until disconnect.
    ///
    /// The first message will be `streamConnected(userName:)`.
    /// After reconnection, `streamConnected` is yielded again so the focused
    /// session coordinator can refresh queue/catch-up state.
    func connect() -> AsyncStream<StreamFrameEvent> {
        // Disconnect previous connection
        let oldConn = connectionID
        disconnect()

        connectionID &+= 1
        let thisConnection = connectionID
        lastHTTPStatusCode = nil
        status = .connecting
        wsLogInfo(
            "Connect requested to session stream (old=\(oldConn) new=\(thisConnection))",
            metadata: [
                "url": streamURL?.absoluteString ?? "invalid",
            ]
        )

        return AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            self?.openStreamWebSocket(continuation: continuation)

            continuation.onTermination = { [weak self] termination in
                Task { @MainActor in
                    guard let self else { return }
                    if self.connectionID != thisConnection {
                        self.wsLogInfo("onTermination skipped (stale: conn=\(thisConnection) current=\(self.connectionID) reason=\(termination))")
                        return
                    }
                    self.wsLogInfo("onTermination disconnect (conn=\(thisConnection) reason=\(termination))")
                    self.disconnect()
                }
            }
        }
    }

    func setPreferredEndpoint(_ endpoint: EndpointSelection) {
        preferredEndpoint = endpoint
    }

    func setStreamURL(_ url: URL?, sessionId: String? = nil, workspaceId: String? = nil) {
        streamURL = url
        diagnosticSessionId = sessionId
        diagnosticWorkspaceId = workspaceId
    }

    // MARK: - Send

    /// Send a client message over the active focused-session stream.
    ///
    /// `sessionId` is ignored for split streams because the target session is bound
    /// in the WebSocket URL prepared by `ServerConnection`.
    ///
    /// If the connection is reconnecting, waits briefly before failing.
    func send(_ message: ClientMessage, sessionId _: String? = nil) async throws {
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

        let payload = try message.jsonString()

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

            let timeoutWorkItem = Self.makeSendTimeoutWorkItem(
                timeoutMs: timeoutMs,
                baseMetadata: baseMetadata,
                resolver: resolver
            )
            resolver.setTimeoutWorkItem(timeoutWorkItem)

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(timeoutMs),
                execute: timeoutWorkItem
            )

            Self.sendPayload(
                payload,
                over: ws,
                baseMetadata: baseMetadata,
                resolver: resolver
            )
        }
    }

    nonisolated private static func makeSendTimeoutWorkItem(
        timeoutMs: Int,
        baseMetadata: [String: String],
        resolver: SendResolver
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            logger.error("WS send hard timeout fired (\(timeoutMs)ms)")
            ClientLog.error(
                "WebSocket",
                "WS send hard timeout fired",
                metadata: Self.mergeMetadata(baseMetadata, extra: ["timeoutMs": String(timeoutMs)])
            )
            resolver.resolve(.failure(WebSocketError.sendTimeout))
        }
    }

    nonisolated private static func sendPayload(
        _ payload: String,
        over ws: URLSessionWebSocketTask,
        baseMetadata: [String: String],
        resolver: SendResolver
    ) {
        ws.send(.string(payload)) { error in
            if let error {
                logger.error("WS send callback error: \(String(describing: error), privacy: .public)")
                ClientLog.error(
                    "WebSocket",
                    "WS send callback error",
                    metadata: Self.mergeMetadata(baseMetadata, extra: ClientLog.networkErrorMetadata(error))
                )
                resolver.resolve(.failure(error))
            } else {
                resolver.resolve(.success(()))
            }
        }
    }

    /// Send raw binary data as a WebSocket binary frame.
    /// Used for streaming PCM audio to the server's dictation pipeline.
    func sendBinary(_ data: Data) async throws {
        guard let ws = webSocket, status == .connected else {
            throw WebSocketError.notConnected
        }
        try await ws.send(.data(data))
    }

    /// Wait for the connection to reach `.connected` state.
    ///
    /// Uses continuation-based waiting instead of polling. Resolves
    /// immediately if already connected, or when the status transitions
    /// to `.connected` / `.disconnected`. Falls back to timeout.
    private func waitForConnection() async throws -> Bool {
        if status == .connected { return true }
        if status == .disconnected { return false }

        let waiterId = nextWaiterId
        nextWaiterId &+= 1

        return await withCheckedContinuation { continuation in
            connectionWaiters[waiterId] = continuation

            // Timeout: resolve with false if not connected within deadline
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.waitForConnectionTimeout ?? .seconds(3))
                guard let self else { return }
                if let waiter = self.connectionWaiters.removeValue(forKey: waiterId) {
                    waiter.resume(returning: false)
                }
            }
        }
    }

    /// Resolve all pending connection waiters with the current status.
    private func resolveConnectionWaiters() {
        let connected = status == .connected
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.resume(returning: connected)
        }
    }

    /// Cancel an in-progress reconnect backoff so a fresh connection can start immediately.
    ///
    /// Called on foreground recovery: reconnect attempts that accumulated during
    /// background suspension reflect process suspension failures, not real server
    /// errors. Resetting here lets `connectStream()` start a fresh connection
    /// without waiting for the stale backoff timer.
    ///
    /// Unlike `disconnect()`, this preserves the focused-session reconnect intent
    /// and the continuation so `ServerConnection` can reopen the same endpoint.
    func cancelReconnectBackoff() {
        guard case .reconnecting(let attempt) = status else { return }
        wsLogInfo("Cancelling reconnect backoff (was attempt \(attempt))")
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        status = .disconnected
        resolveConnectionWaiters()
    }

    /// Send a graceful close frame before iOS suspends the app.
    ///
    /// Sends `.goingAway` (1001) so the server sees a clean close instead of
    /// discovering the dead connection via ping timeout (1006). Stops the ping
    /// timer since no pongs can be sent while suspended. Keeps the stream
    /// continuation so `reconnectIfNeeded()` can reopen on foreground.
    func prepareForBackground() {
        guard let ws = webSocket, status == .connected else { return }
        wsLogInfo("Preparing for background — sending goingAway close")
        pingTask?.cancel()
        pingTask = nil
        ws.cancel(with: .goingAway, reason: nil)
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
        lastReceiveErrorFingerprint = nil
        lastReceiveErrorLogNs = 0
        suppressedReceiveErrorCount = 0

        status = .disconnected
        resolveConnectionWaiters()
    }

    // MARK: - Private

    private func wsLogMetadata(extra: [String: String] = [:]) -> [String: String] {
        var metadata = extra
        metadata.merge(
            ClientLog.endpointMetadata(streamURL ?? preferredEndpoint?.baseURL, prefix: "ws")
        ) { current, _ in current }
        metadata["status"] = String(describing: status)
        metadata["connectionID"] = String(connectionID)
        metadata["transportPath"] = preferredEndpoint?.transportPath.rawValue ?? ConnectionTransportPath.paired.rawValue
        metadata["streamRole"] = diagnosticRole
        if let diagnosticSessionId {
            metadata["sessionId"] = diagnosticSessionId
        }
        if let diagnosticWorkspaceId {
            metadata["workspaceId"] = diagnosticWorkspaceId
        }
        if let lastHTTPStatusCode {
            metadata["httpStatusCode"] = String(lastHTTPStatusCode)
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

    private func wsLogWarning(_ message: String, metadata: [String: String] = [:]) {
        ClientLog.warning("WebSocket", message, metadata: wsLogMetadata(extra: metadata))
    }

    private func wsLogError(_ message: String, metadata: [String: String] = [:]) {
        ClientLog.error("WebSocket", message, metadata: wsLogMetadata(extra: metadata))
    }

    private func shouldLogReceiveError(_ error: Error) -> Bool {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let fingerprint = String(describing: error)

        if lastReceiveErrorFingerprint == fingerprint,
           nowNs &- lastReceiveErrorLogNs < receiveErrorLogCooldownNs {
            suppressedReceiveErrorCount += 1
            return false
        }

        lastReceiveErrorFingerprint = fingerprint
        lastReceiveErrorLogNs = nowNs
        return true
    }

    private func consumeReceiveErrorSuppressionMetadata() -> [String: String] {
        guard suppressedReceiveErrorCount > 0 else { return [:] }
        let count = suppressedReceiveErrorCount
        suppressedReceiveErrorCount = 0
        return ["suppressedReceiveErrorCount": String(count)]
    }

    private func receiveFailureMetadata(for ws: URLSessionWebSocketTask, error: Error) -> [String: String] {
        var metadata = ClientLog.networkErrorMetadata(error)
        if let statusCode = (ws.response as? HTTPURLResponse)?.statusCode {
            metadata["httpStatusCode"] = String(statusCode)
        }
        metadata["webSocketCloseCode"] = String(ws.closeCode.rawValue)
        return metadata
    }

    private func isNonRetryableHandshakeStatus(_ statusCode: Int) -> Bool {
        [400, 401, 403, 404, 410, 426].contains(statusCode)
    }

    private func openStreamWebSocket(continuation: AsyncStream<StreamFrameEvent>.Continuation) {
        guard let url = streamURL else {
            logger.error("Invalid stream URL — disconnecting")
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

    private func startReceiveLoop(ws: URLSessionWebSocketTask, continuation: AsyncStream<StreamFrameEvent>.Continuation) {
        receiveTask = Task { [weak self] in
            var shouldAttemptReconnect = true
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
                        logger.error("PIPE: DECODE FAILED: \(error.localizedDescription, privacy: .public) — rawLen=\(text.count)")
                        self?.wsLogError(
                            "PIPE decode failed",
                            metadata: [
                                "error": error.localizedDescription,
                                "rawLen": String(text.count),
                            ]
                        )
                        continue
                    }

                    let transportPath = self?.preferredEndpoint?.transportPath ?? .paired
                    let inboundMeta = InboundMeta(
                        seq: streamMessage.seq,
                        currentSeq: streamMessage.currentSeq,
                        receivedAtMs: Date.nowMs(),
                        transportPath: transportPath
                    )
                    let frameEvent = StreamFrameEvent(
                        sessionId: streamMessage.sessionId,
                        message: streamMessage.message,
                        meta: inboundMeta
                    )

                    // First successful message = connected
                    await MainActor.run {
                        if case .connecting = self?.status {
                            self?.status = .connected
                            self?.resolveConnectionWaiters()
                        } else if case .reconnecting = self?.status {
                            self?.status = .connected
                            self?.resolveConnectionWaiters()
                        }
                    }

                    if case .unknown(let type) = streamMessage.message {
                        logger.debug("Received unknown server message: \(type)")
                    }

                    continuation.yield(frameEvent)
                } catch {
                    let statusCode = (ws.response as? HTTPURLResponse)?.statusCode
                    if let statusCode {
                        self?.lastHTTPStatusCode = statusCode
                    }
                    if Task.isCancelled { break }
                    if let self, let statusCode, self.isNonRetryableHandshakeStatus(statusCode) {
                        shouldAttemptReconnect = false
                        let metadata = self.receiveFailureMetadata(for: ws, error: error)
                            .merging(self.consumeReceiveErrorSuppressionMetadata()) { _, new in new }
                        logger.error("WebSocket handshake rejected with HTTP \(statusCode)")
                        self.wsLogError(
                            "WebSocket handshake rejected",
                            metadata: metadata
                        )
                    } else if let self, self.shouldLogReceiveError(error) {
                        logger.error("WebSocket receive error: \(error)")
                        self.wsLogError(
                            "WebSocket receive error",
                            metadata: self.receiveFailureMetadata(for: ws, error: error)
                                .merging(self.consumeReceiveErrorSuppressionMetadata()) { _, new in new }
                        )
                    } else {
                        logger.debug("Suppressed duplicate WebSocket receive error: \(String(describing: error), privacy: .public)")
                    }
                    break
                }
            }

            // Connection lost — attempt reconnect unless the server rejected the endpoint/auth.
            await MainActor.run {
                if shouldAttemptReconnect {
                    self?.attemptReconnect()
                } else {
                    self?.disconnect()
                }
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
            wsLogError("Max reconnect attempts reached", metadata: consumeReceiveErrorSuppressionMetadata())
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

    /// Reconnect delay curve tuned for mobile networking:
    ///
    /// - Attempts 1-3: 500ms (transient — suspension wake, network handoff)
    /// - Attempts 4-6: 2s, 4s, 8s (moderate — server restart, Tailscale reconnect)
    /// - Attempts 7+:  15s cap (real problems — server down)
    ///
    /// ±25% jitter prevents synchronized retries if multiple connections exist.
    nonisolated static func reconnectDelay(attempt: Int) -> TimeInterval {
        let base: Double
        switch attempt {
        case 1...3: base = 0.5
        case 4:     base = 2
        case 5:     base = 4
        case 6:     base = 8
        default:    base = 15
        }
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

    // periphery:ignore - used by OppiTests via @testable import
    /// Test seam for deterministic send/reconnect behavior tests.
    func _setStatusForTesting(_ status: Status) {
        self.status = status
        if status == .connected || status == .disconnected {
            resolveConnectionWaiters()
        }
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
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: return "WebSocket not connected"
        case .sendTimeout: return "Send timed out — server may still be starting"
        case .encodingFailed: return "WebSocket message encoding failed"
        }
    }
}
