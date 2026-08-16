import Foundation
import OSLog

private let appEventClientLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "AppEventStreamClient")

/// Narrow transport seam for deterministic app-event reconnect tests.
/// Production still delegates every operation to `URLSessionWebSocketTask`.
@MainActor
struct AppEventWebSocketTransport {
    typealias Message = URLSessionWebSocketTask.Message
    typealias CloseCode = URLSessionWebSocketTask.CloseCode

    let identity: ObjectIdentifier
    let resume: () -> Void
    let receive: () async throws -> Message
    let sendPing: (@escaping @Sendable (Error?) -> Void) -> Void
    let cancel: (CloseCode, Data?) -> Void
    let state: () -> URLSessionTask.State
    let response: () -> URLResponse?
    let closeCode: () -> CloseCode

    init(task: URLSessionWebSocketTask) {
        identity = ObjectIdentifier(task)
        resume = { task.resume() }
        receive = { try await task.receive() }
        sendPing = { handler in task.sendPing(pongReceiveHandler: handler) }
        cancel = { code, reason in task.cancel(with: code, reason: reason) }
        state = { task.state }
        response = { task.response }
        closeCode = { task.closeCode }
    }

    init(
        identity: AnyObject,
        resume: @escaping () -> Void,
        receive: @escaping () async throws -> Message,
        sendPing: @escaping (@escaping @Sendable (Error?) -> Void) -> Void,
        cancel: @escaping (CloseCode, Data?) -> Void,
        state: @escaping () -> URLSessionTask.State,
        response: @escaping () -> URLResponse?,
        closeCode: @escaping () -> CloseCode
    ) {
        self.identity = ObjectIdentifier(identity)
        self.resume = resume
        self.receive = receive
        self.sendPing = sendPing
        self.cancel = cancel
        self.state = state
        self.response = response
        self.closeCode = closeCode
    }
}

/// WebSocket client for the global app event stream.
///
/// It decodes `AppEventMessage` directly and never produces `ServerMessage`, so
/// focused timeline routing cannot accidentally consume global frames.
@MainActor
final class AppEventStreamClient {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    private(set) var status: Status = .disconnected

    private let url: URL
    private var token: String
    private let currentTokenProvider: (@Sendable () async throws -> String)?
    /// Distinct forced refresh used only after a 401. Static-token streams leave
    /// both providers nil and treat 401 as terminal.
    private let refreshTokenProvider: (@Sendable () async throws -> String)?
    private let trustDelegate: PinnedServerTrustDelegate
    private let urlSession: URLSession
    private let reconnectDelay: @Sendable (Int) -> TimeInterval
    private let webSocketFactory: (URLRequest) -> AppEventWebSocketTransport
    private let diagnosticRemoteIdentity: String?
    private let pingInterval: Duration
    private let pingTimeout: Duration
    var onTransportHealthFailure: (@MainActor @Sendable (PersistentStreamHealthFailure) async -> Void)?

    private var webSocket: AppEventWebSocketTransport?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var healthReportTask: Task<Void, Never>?
    private var continuation: AsyncStream<AppEventMessage>.Continuation?
    private var openStartedNs: UInt64?
    private var reconnectAttempt = 0

    /// Monotonic ID incremented on each `connect()` call.
    /// Prevents stale stream termination handlers from closing a newer socket.
    private var connectionID: UInt64 = 0

    /// True after a forced refresh has been consumed since the last successful
    /// frame. A second 401 on a socket that was already refreshed once is
    /// terminal, so a server that keeps rejecting freshly-issued tokens cannot
    /// recurse into an unbounded refresh/reconnect loop.
    private var didForceRefreshForConnection = false

    init(
        url: URL,
        token: String,
        tlsCertFingerprint: String? = nil,
        tlsServerName: String? = nil,
        diagnosticRemoteIdentity: String? = nil,
        currentTokenProvider: (@Sendable () async throws -> String)? = nil,
        refreshTokenProvider: (@Sendable () async throws -> String)? = nil,
        pingInterval: Duration = WebSocketRecoveryPolicy.pingInterval,
        pingTimeout: Duration = WebSocketRecoveryPolicy.pingTimeout,
        reconnectDelay: @escaping @Sendable (Int) -> TimeInterval = WebSocketRecoveryPolicy.reconnectDelay,
        onTransportHealthFailure: (@MainActor @Sendable (PersistentStreamHealthFailure) async -> Void)? = nil,
        webSocketFactory: ((URLRequest) -> AppEventWebSocketTransport)? = nil
    ) {
        self.url = url
        self.token = token
        self.currentTokenProvider = currentTokenProvider
        self.refreshTokenProvider = refreshTokenProvider
        self.reconnectDelay = reconnectDelay
        self.diagnosticRemoteIdentity = diagnosticRemoteIdentity
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        self.onTransportHealthFailure = onTransportHealthFailure
        self.trustDelegate = PinnedServerTrustDelegate(
            pinnedLeafFingerprint: tlsCertFingerprint,
            expectedServerName: tlsServerName
        )
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        let urlSession = URLSession(configuration: config, delegate: trustDelegate, delegateQueue: nil)
        self.urlSession = urlSession
        self.webSocketFactory = webSocketFactory ?? { request in
            AppEventWebSocketTransport(task: urlSession.webSocketTask(with: request))
        }
    }

    func connect() -> AsyncStream<AppEventMessage> {
        disconnect()
        connectionID &+= 1
        let thisConnection = connectionID
        didForceRefreshForConnection = false
        status = .connecting
        reconnectAttempt = 0

        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.continuation = continuation
            if let currentTokenProvider = self.currentTokenProvider {
                Task { [weak self] in
                    do {
                        let current = try await currentTokenProvider()
                        guard let self,
                              self.connectionID == thisConnection,
                              self.status != .disconnected,
                              !current.isEmpty else {
                            self?.disconnect()
                            return
                        }
                        self.token = current
                        self.open(continuation: continuation)
                    } catch {
                        self?.logStreamError("Initial device token resolution failed", error: error)
                        self?.disconnect()
                    }
                }
            } else {
                self.open(continuation: continuation)
            }

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.connectionID == thisConnection else { return }
                    self.disconnect()
                }
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        healthReportTask?.cancel()
        healthReportTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocket?.cancel(.normalClosure, nil)
        webSocket = nil
        continuation?.finish()
        continuation = nil
        status = .disconnected
    }

    private func open(continuation: AsyncStream<AppEventMessage>.Continuation) {
        var request = URLRequest(url: url)
        ServerAuthorization.apply(token: token, to: &request)

        let ws = webSocketFactory(request)
        webSocket = ws
        openStartedNs = DispatchTime.now().uptimeNanoseconds
        ws.resume()
        startReceiveLoop(ws: ws, continuation: continuation)
        startPingTimer(ws: ws)
    }

    private func startReceiveLoop(
        ws: AppEventWebSocketTransport,
        continuation: AsyncStream<AppEventMessage>.Continuation
    ) {
        receiveTask = Task { [weak self] in
            var shouldAttemptReconnect = true
            var reconnectReason = "receive_error"
            var reconnectCloseCode: String?
            while !Task.isCancelled {
                do {
                    let message = try await ws.receive()
                    let text: String
                    switch message {
                    case .string(let value):
                        text = value
                    case .data(let data):
                        text = String(data: data, encoding: .utf8) ?? ""
                    @unknown default:
                        continue
                    }

                    let event: AppEventMessage
                    do {
                        event = try AppEventMessage.decode(from: text)
                    } catch {
                        appEventClientLogger.error("App event decode failed: \(error.localizedDescription, privacy: .public)")
                        await MainActor.run { [weak self] in
                            self?.recordDecodeErrorMetric(error: error)
                            self?.logStreamWarning("Decode failed", error: error)
                        }
                        continue
                    }

                    await MainActor.run { [weak self] in
                        switch self?.status {
                        case .connecting, .reconnecting(_):
                            self?.status = .connected
                            // A successfully received frame resets the forced-refresh
                            // budget so a later natural token expiry can refresh again.
                            self?.didForceRefreshForConnection = false
                        case .connected, .disconnected, nil:
                            break
                        }

                        if case .connected(_, let snapshotRequired) = event {
                            self?.recordConnectMetric(snapshotRequired: snapshotRequired)
                        }
                    }
                    continuation.yield(event)
                } catch {
                    if Task.isCancelled {
                        shouldAttemptReconnect = false
                        break
                    }

                    let statusCode = (ws.response() as? HTTPURLResponse)?.statusCode
                    reconnectReason = "receive_error"
                    reconnectCloseCode = String(ws.closeCode().rawValue)
                    if statusCode == 401, let self, self.refreshTokenProvider != nil {
                        // Expired/unknown device token: force-refresh exactly once, then
                        // reconnect exactly once. A failed/empty refresh or a repeated
                        // 401 disconnects terminally without a retry loop. Never call
                        // `disconnect()` on the success path.
                        shouldAttemptReconnect = false
                        if await self.handleAuthFailure(ws: ws) {
                            return
                        }
                    } else if let statusCode, WebSocketRecoveryPolicy.isNonRetryableHandshakeStatus(statusCode) {
                        shouldAttemptReconnect = false
                        reconnectReason = "handshake_http"
                        appEventClientLogger.error("App event stream handshake rejected with HTTP \(statusCode, privacy: .public)")
                        await MainActor.run { [weak self] in
                            self?.logStreamError(
                                "Handshake rejected",
                                error: error,
                                extra: ["httpStatusCode": String(statusCode)]
                            )
                        }
                    } else if WebSocketRecoveryPolicy.isNonRetryableCloseCode(ws.closeCode()) {
                        shouldAttemptReconnect = false
                        reconnectReason = "protocol_close"
                        appEventClientLogger.error("App event stream terminal close code \(ws.closeCode().rawValue, privacy: .public)")
                        await MainActor.run { [weak self] in
                            self?.logStreamError(
                                "Terminal protocol close",
                                error: error,
                                extra: ["closeCode": String(ws.closeCode().rawValue)]
                            )
                        }
                    } else if WebSocketRecoveryPolicy.isRecoverableReceiveError(error, closeCode: ws.closeCode()) {
                        reconnectReason = "recoverable_receive"
                        appEventClientLogger.info("App event stream recoverable close: \(String(describing: error), privacy: .public)")
                    } else {
                        appEventClientLogger.warning("App event stream receive error: \(String(describing: error), privacy: .public)")
                        await MainActor.run { [weak self] in
                            self?.logStreamWarning("Receive error", error: error)
                        }
                    }
                    break
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.webSocket?.identity == ws.identity else { return }
                if shouldAttemptReconnect {
                    self.attemptReconnect(reason: reconnectReason, closeCode: reconnectCloseCode)
                } else {
                    self.disconnect()
                }
            }
        }
    }

    private func startPingTimer(ws: AppEventWebSocketTransport) {
        pingTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pingInterval ?? WebSocketRecoveryPolicy.pingInterval)
                guard !Task.isCancelled,
                      let self,
                      self.webSocket?.identity == ws.identity,
                      ws.state() == .running else { break }

                let result = await WebSocketPingDeadline.wait(timeout: self.pingTimeout) { callback in
                    ws.sendPing(callback)
                }
                guard !Task.isCancelled, self.webSocket?.identity == ws.identity else { break }

                switch result {
                case .succeeded:
                    consecutiveFailures = 0
                    continue

                case .failed:
                    consecutiveFailures += 1
                    guard consecutiveFailures >= WebSocketRecoveryPolicy.maxConsecutivePingFailures else {
                        continue
                    }
                    await self.onTransportHealthFailure?(.pingFailures(count: consecutiveFailures))

                case .timedOut:
                    await self.onTransportHealthFailure?(.pingTimeout)
                }

                guard !Task.isCancelled, self.webSocket?.identity == ws.identity else { break }
                appEventClientLogger.warning("App event ping watchdog detected an unhealthy socket")
                self.receiveTask?.cancel()
                self.receiveTask = nil
                ws.cancel(.goingAway, nil)
                self.webSocket = nil
                self.logStreamWarning(
                    "Ping watchdog reconnect",
                    extra: [
                        "consecutiveFailures": String(consecutiveFailures),
                        "result": result == .timedOut ? "timeout" : "callback_error",
                    ]
                )
                self.attemptReconnect(reason: "ping_watchdog")
                break
            }
        }
    }

    private func recordConnectMetric(snapshotRequired: Bool) {
        guard let startedNs = openStartedNs else { return }
        openStartedNs = nil
        let durationMs = Double((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
        let attempt = reconnectAttempt
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .appEventStreamConnectMs,
                value: durationMs,
                unit: .ms,
                tags: [
                    "status": "ok",
                    "attempt": WebSocketRecoveryPolicy.reconnectAttemptTag(attempt),
                    "snapshot_required": snapshotRequired ? "1" : "0",
                ]
            )
        }
    }

    private func recordDecodeErrorMetric(error: Error) {
        let errorKind = streamErrorKind(error)
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .appEventStreamDecodeError,
                value: 1,
                unit: .count,
                tags: ["error_kind": errorKind]
            )
        }
    }

    private func recordReconnectMetric(status: String, reason: String, attempt: Int, closeCode: String?) {
        var tags = [
            "status": status,
            "reason": reason,
            "attempt": WebSocketRecoveryPolicy.reconnectAttemptTag(attempt),
        ]
        if let closeCode {
            tags["close_code"] = closeCode
        }
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .appEventStreamReconnect,
                value: 1,
                unit: .count,
                tags: tags
            )
        }
    }

    private func streamErrorKind(_ error: Error) -> String {
        if error is DecodingError { return "decode" }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return "network" }
        return "other"
    }

    private func streamLogMetadata(extra: [String: String] = [:]) -> [String: String] {
        var metadata: [String: String]
        if let diagnosticRemoteIdentity {
            metadata = ["remoteIdentity": diagnosticRemoteIdentity]
        } else {
            metadata = ClientLog.endpointMetadata(url, prefix: "appStream")
        }
        metadata["streamRole"] = "app_event_stream"
        metadata["status"] = String(describing: status)
        metadata["connectionID"] = String(connectionID)
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    private func logStreamWarning(_ message: String, error: Error? = nil, extra: [String: String] = [:]) {
        var metadata = error.map(ClientLog.networkErrorMetadata) ?? [:]
        for (key, value) in extra {
            metadata[key] = value
        }
        ClientLog.warning("AppEventStream", message, metadata: streamLogMetadata(extra: metadata))
    }

    private func logStreamError(_ message: String, error: Error? = nil, extra: [String: String] = [:]) {
        var metadata = error.map(ClientLog.networkErrorMetadata) ?? [:]
        for (key, value) in extra {
            metadata[key] = value
        }
        ClientLog.error("AppEventStream", message, metadata: streamLogMetadata(extra: metadata))
    }

    /// Handle an auth 401 on `ws`: force-refresh exactly once, then reconnect
    /// exactly once on success. A failed refresh, an empty token, or a repeated
    /// 401 (already refreshed this connection) disconnects terminally.
    /// Returns `true` when the socket has been replaced (the caller must stop
    /// touching the old loop); `false` when the caller should disconnect.
    private func handleAuthFailure(ws: AppEventWebSocketTransport) async -> Bool {
        guard let refreshTokenProvider else { return false }
        guard webSocket?.identity == ws.identity, status != .disconnected else { return true }
        guard !didForceRefreshForConnection else {
            appEventClientLogger.error("Repeated 401 after forced refresh — disconnecting")
            return false
        }
        do {
            let refreshed = try await refreshTokenProvider()
            guard webSocket?.identity == ws.identity, status != .disconnected else { return true }
            guard !refreshed.isEmpty else {
                appEventClientLogger.error("Refresh returned an empty access token — disconnecting")
                return false
            }
            token = refreshed
            didForceRefreshForConnection = true
            attemptReconnect(reason: "auth_refresh")
            return true
        } catch {
            logStreamError(
                "Device-key refresh failed on 401",
                error: error
            )
            return false
        }
    }

    private func attemptReconnect(reason: String, closeCode: String? = nil) {
        guard status != .disconnected else { return }

        var attempt = 0
        if case .reconnecting(let currentAttempt) = status {
            attempt = currentAttempt
        }

        // This stream owns the list-repair snapshot contract. Keep retrying recoverable
        // outages until its coordinator explicitly disconnects it; otherwise cached list
        // state can remain stranded after the transport itself becomes reachable again.
        let nextAttempt = WebSocketRecoveryPolicy.nextReconnectAttempt(after: attempt)
        reconnectAttempt = nextAttempt
        recordReconnectMetric(status: "scheduled", reason: reason, attempt: nextAttempt, closeCode: closeCode)
        status = .reconnecting(attempt: nextAttempt)
        let delay = reconnectDelay(nextAttempt)
        if WebSocketRecoveryPolicy.shouldReportUnhealthyReconnect(attempt: nextAttempt),
           let onTransportHealthFailure {
            let reportingConnectionID = connectionID
            healthReportTask?.cancel()
            healthReportTask = Task { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.connectionID == reportingConnectionID,
                      self.status != .disconnected else { return }
                await onTransportHealthFailure(.reconnectThreshold(attempt: nextAttempt))
            }
        }

        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        webSocket?.cancel(.goingAway, nil)
        webSocket = nil

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, let continuation = self.continuation else { return }
                self.open(continuation: continuation)
            }
        }
    }
}
