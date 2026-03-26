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
        let receivedAtMs: Int64?

        init(seq: Int?, currentSeq: Int?, receivedAtMs: Int64? = nil) {
            self.seq = seq
            self.currentSeq = currentSeq
            self.receivedAtMs = receivedAtMs
        }
    }

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var continuation: AsyncStream<StreamMessage>.Continuation?
    private var inboundMetaQueueBySessionID: [String: [InboundMeta]] = [:]
    private var inboundMetaQueueHighWaterBySessionID: [String: Int] = [:]
    private var lastReceiveErrorFingerprint: String?
    private var lastReceiveErrorLogNs: UInt64 = 0

    /// Deduplicate repeated receive error logs (common during lifecycle
    /// transitions) while preserving first occurrence signal.
    private let receiveErrorLogCooldownNs: UInt64 = 3_000_000_000

    /// Active subscriptions tracked for resubscription after reconnect.
    /// Key: sessionId, Value: subscription level.
    private(set) var activeSubscriptions: [String: StreamSubscriptionLevel] = [:]

    let credentials: ServerCredentials
    private var preferredEndpoint: EndpointSelection?
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
        waitForConnectionTimeout: Duration = .seconds(3),
        sendTimeout: Duration = .seconds(5)
    ) {
        self.credentials = credentials
        self.preferredEndpoint = preferredEndpoint
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
        let oldConn = connectionID
        disconnect()

        connectionID &+= 1
        let thisConnection = connectionID
        status = .connecting
        wsLogInfo(
            "Connect requested to /stream (old=\(oldConn) new=\(thisConnection))",
            metadata: [
                "url": (preferredEndpoint?.streamURL ?? credentials.streamURL)?.absoluteString ?? "invalid",
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

        // Track subscribe state BEFORE sending so the receive loop's meta
        // guard (`activeSubscriptions[sessionId] == .full`) passes for the
        // server's immediate response (connected, state, command_result).
        //
        // Without this, there's a race: `sendWithTimeout` suspends the
        // MainActor, the server responds, the receive loop hops to
        // MainActor to store InboundMeta but `activeSubscriptions` isn't
        // set yet → meta (carrying `currentSeq`) is dropped → catch-up
        // is skipped → timeline stays empty for idle sessions.
        //
        // Unsubscribe is tracked AFTER send to avoid premature rejection
        // of in-flight messages.
        preTrackSubscription(message)

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
            // Rollback pre-tracked subscription on send failure so stale
            // entries don't leak into the meta guard.
            rollbackPreTrackSubscription(message)
            throw error
        }

        // Post-send tracking: handles unsubscribe and is a no-op for
        // subscribe (already tracked above).
        trackSubscription(message)
    }

    // MARK: - Subscription Tracking

    /// Pre-send: set subscription level for `.subscribe` so the receive
    /// loop's meta guard passes for the server's immediate response.
    /// No-op for other message types.
    private func preTrackSubscription(_ message: ClientMessage) {
        guard case .subscribe(let sessionId, let level, _, _) = message else { return }
        activeSubscriptions[sessionId] = level
        inboundMetaQueueBySessionID.removeValue(forKey: sessionId)
        inboundMetaQueueHighWaterBySessionID.removeValue(forKey: sessionId)
    }

    /// Undo `preTrackSubscription` when the send fails — prevents stale
    /// subscription entries from leaking.
    private func rollbackPreTrackSubscription(_ message: ClientMessage) {
        guard case .subscribe(let sessionId, _, _, _) = message else { return }
        activeSubscriptions.removeValue(forKey: sessionId)
        inboundMetaQueueBySessionID.removeValue(forKey: sessionId)
        inboundMetaQueueHighWaterBySessionID.removeValue(forKey: sessionId)
    }

    /// Post-send: track subscribe/unsubscribe for reconnect resubscription.
    /// For `.subscribe` this is a no-op (already pre-tracked).
    private func trackSubscription(_ message: ClientMessage) {
        switch message {
        case .subscribe(let sessionId, let level, _, _):
            activeSubscriptions[sessionId] = level
            // Meta queue already cleared by preTrackSubscription; no-op here.
        case .unsubscribe(let sessionId, _):
            activeSubscriptions.removeValue(forKey: sessionId)
            inboundMetaQueueBySessionID.removeValue(forKey: sessionId)
            inboundMetaQueueHighWaterBySessionID.removeValue(forKey: sessionId)
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
                    metadata: Self.mergeMetadata(baseMetadata, extra: ["error": String(describing: error)])
                )
                resolver.resolve(.failure(error))
            } else {
                resolver.resolve(.success(()))
            }
        }
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
    /// Unlike `disconnect()`, this preserves active subscriptions and the
    /// continuation so `handleStreamReconnected()` can re-subscribe after
    /// the new connection opens.
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
    /// timer since no pongs can be sent while suspended. Preserves subscriptions
    /// and continuation so `reconnectIfNeeded()` can reopen on foreground.
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
        inboundMetaQueueHighWaterBySessionID.removeAll(keepingCapacity: false)
        activeSubscriptions.removeAll()
        lastReceiveErrorFingerprint = nil
        lastReceiveErrorLogNs = 0

        status = .disconnected
        resolveConnectionWaiters()
    }

    // MARK: - Private

    private func wsLogMetadata(extra: [String: String] = [:]) -> [String: String] {
        var metadata = extra
        metadata["status"] = String(describing: status)
        metadata["connectionID"] = String(connectionID)
        metadata["subscriptions"] = activeSubscriptions.keys.joined(separator: ",")
        metadata["transportPath"] = preferredEndpoint?.transportPath.rawValue ?? ConnectionTransportPath.paired.rawValue
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
        let url = preferredEndpoint?.streamURL ?? credentials.streamURL

        guard let url else {
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

                    let transportTag = self?.preferredEndpoint?.transportPath.rawValue ?? ConnectionTransportPath.paired.rawValue
                    let messageType = streamMessage.message.typeLabel

                    let inboundReceivedAtMs = ChatMetricsService.nowMs()
                    let inboundMeta = InboundMeta(
                        seq: streamMessage.seq,
                        currentSeq: streamMessage.currentSeq,
                        receivedAtMs: inboundReceivedAtMs
                    )
                    let mainActorHopStartedAtMs = ChatMetricsService.nowMs()
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

                        let depth = queue.count
                        let previousHighWater = self.inboundMetaQueueHighWaterBySessionID[sessionId] ?? 0
                        if depth > previousHighWater {
                            self.inboundMetaQueueHighWaterBySessionID[sessionId] = depth
                            Task.detached(priority: .utility) {
                                await ChatMetricsService.shared.record(
                                    metric: .inboundQueueDepth,
                                    value: Double(depth),
                                    unit: .count,
                                    sessionId: sessionId
                                )
                            }
                        }
                    }
                    let mainActorHopDurationMs = max(0, ChatMetricsService.nowMs() - mainActorHopStartedAtMs)
                    if mainActorHopDurationMs >= 1_000 {
                        self?.wsLogError(
                            "WS main-actor hop lag",
                            metadata: [
                                "type": messageType,
                                "hopMs": String(mainActorHopDurationMs),
                                "transport": transportTag,
                            ]
                        )
                    }

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

    // periphery:ignore - used by OppiTests via @testable import
    /// Test seam: read subscription level for a session.
    func _activeSubscriptionForTesting(_ sessionId: String) -> StreamSubscriptionLevel? {
        activeSubscriptions[sessionId]
    }

    // periphery:ignore - used by OppiTests via @testable import
    /// Test seam: exercise pre-track subscription logic without a real send.
    func _preTrackSubscriptionForTesting(_ message: ClientMessage) {
        preTrackSubscription(message)
    }

    // periphery:ignore - used by OppiTests via @testable import
    /// Test seam: exercise rollback logic without a real send failure.
    func _rollbackPreTrackSubscriptionForTesting(_ message: ClientMessage) {
        rollbackPreTrackSubscription(message)
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
