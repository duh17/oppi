import Foundation
import OSLog

private let appEventClientLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "AppEventStreamClient")

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
    private let token: String
    private let trustDelegate: PinnedServerTrustDelegate
    private let urlSession: URLSession
    private let reconnectDelay: @Sendable (Int) -> TimeInterval

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var continuation: AsyncStream<AppEventMessage>.Continuation?

    /// Monotonic ID incremented on each `connect()` call.
    /// Prevents stale stream termination handlers from closing a newer socket.
    private var connectionID: UInt64 = 0

    init(
        url: URL,
        token: String,
        tlsCertFingerprint: String? = nil,
        reconnectDelay: @escaping @Sendable (Int) -> TimeInterval = WebSocketRecoveryPolicy.reconnectDelay
    ) {
        self.url = url
        self.token = token
        self.reconnectDelay = reconnectDelay
        self.trustDelegate = PinnedServerTrustDelegate(pinnedLeafFingerprint: tlsCertFingerprint)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.urlSession = URLSession(configuration: config, delegate: trustDelegate, delegateQueue: nil)
    }

    func connect() -> AsyncStream<AppEventMessage> {
        disconnect()
        connectionID &+= 1
        let thisConnection = connectionID
        status = .connecting

        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.continuation = continuation
            self.open(continuation: continuation)

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
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        continuation?.finish()
        continuation = nil
        status = .disconnected
    }

    private func open(continuation: AsyncStream<AppEventMessage>.Continuation) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let ws = urlSession.webSocketTask(with: request)
        webSocket = ws
        ws.resume()
        startReceiveLoop(ws: ws, continuation: continuation)
        startPingTimer(ws: ws)
    }

    private func startReceiveLoop(
        ws: URLSessionWebSocketTask,
        continuation: AsyncStream<AppEventMessage>.Continuation
    ) {
        receiveTask = Task { [weak self] in
            var shouldAttemptReconnect = true
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
                        continue
                    }

                    await MainActor.run { [weak self] in
                        switch self?.status {
                        case .connecting, .reconnecting(_):
                            self?.status = .connected
                        case .connected, .disconnected, nil:
                            break
                        }
                    }
                    continuation.yield(event)
                } catch {
                    if Task.isCancelled {
                        shouldAttemptReconnect = false
                        break
                    }

                    let statusCode = (ws.response as? HTTPURLResponse)?.statusCode
                    if let statusCode, WebSocketRecoveryPolicy.isNonRetryableHandshakeStatus(statusCode) {
                        shouldAttemptReconnect = false
                        appEventClientLogger.error("App event stream handshake rejected with HTTP \(statusCode, privacy: .public)")
                    } else if WebSocketRecoveryPolicy.isRecoverableReceiveError(error, closeCode: ws.closeCode) {
                        appEventClientLogger.info("App event stream recoverable close: \(String(describing: error), privacy: .public)")
                    } else {
                        appEventClientLogger.warning("App event stream receive error: \(String(describing: error), privacy: .public)")
                    }
                    break
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.webSocket === ws else { return }
                if shouldAttemptReconnect {
                    self.attemptReconnect()
                } else {
                    self.disconnect()
                }
            }
        }
    }

    private func startPingTimer(ws: URLSessionWebSocketTask) {
        pingTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: WebSocketRecoveryPolicy.pingInterval)
                guard !Task.isCancelled else { break }
                guard ws.state == .running else { break }

                let failed = await withUnsafeContinuation { (cont: UnsafeContinuation<Bool, Never>) in
                    let oneShot = OneShotBoolContinuation(cont)
                    ws.sendPing { error in
                        oneShot.resume(returning: error != nil)
                    }
                }

                if failed {
                    consecutiveFailures += 1
                    if consecutiveFailures >= WebSocketRecoveryPolicy.maxConsecutivePingFailures {
                        appEventClientLogger.warning("App event ping watchdog reconnect after \(consecutiveFailures) failures")
                        await MainActor.run { [weak self] in
                            guard let self, self.webSocket === ws else { return }
                            self.receiveTask?.cancel()
                            self.receiveTask = nil
                            ws.cancel(with: .goingAway, reason: nil)
                            self.webSocket = nil
                            self.attemptReconnect()
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
        guard status != .disconnected else { return }

        var attempt = 0
        if case .reconnecting(let currentAttempt) = status {
            attempt = currentAttempt
        }

        guard attempt < WebSocketRecoveryPolicy.maxReconnectAttempts else {
            appEventClientLogger.error("App event stream max reconnect attempts reached")
            disconnect()
            return
        }

        let nextAttempt = attempt + 1
        status = .reconnecting(attempt: nextAttempt)
        let delay = reconnectDelay(nextAttempt)

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
            await MainActor.run { [weak self] in
                guard let self, let continuation = self.continuation else { return }
                self.open(continuation: continuation)
            }
        }
    }
}
