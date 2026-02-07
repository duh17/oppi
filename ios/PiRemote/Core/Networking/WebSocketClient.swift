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

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var continuation: AsyncStream<ServerMessage>.Continuation?

    private let credentials: ServerCredentials
    private let urlSession: URLSession

    private let maxReconnectAttempts = 10
    private let pingInterval: Duration = .seconds(30)

    init(credentials: ServerCredentials) {
        self.credentials = credentials
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
    func connect(sessionId: String) -> AsyncStream<ServerMessage> {
        // Disconnect previous connection
        disconnect()

        connectedSessionId = sessionId
        status = .connecting

        return AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            self?.openWebSocket(sessionId: sessionId, continuation: continuation)

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.disconnect()
                }
            }
        }
    }

    /// Send a client message over the WebSocket.
    func send(_ message: ClientMessage) async throws {
        guard let ws = webSocket else {
            throw WebSocketError.notConnected
        }
        let data = try message.jsonString()
        try await ws.send(.string(data))
    }

    /// Disconnect and clean up.
    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil

        continuation?.finish()
        continuation = nil

        connectedSessionId = nil
        status = .disconnected
    }

    // MARK: - Private

    private func openWebSocket(sessionId: String, continuation: AsyncStream<ServerMessage>.Continuation) {
        guard let url = credentials.webSocketURL(sessionId: sessionId) else {
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
                        // Log decode error but DON'T break — keep the stream alive
                        logger.warning("Failed to decode message: \(error.localizedDescription) — raw: \(text.prefix(200))")
                        continue
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
                        logger.debug("Skipping unknown server message: \(type)")
                        continue
                    }

                    continuation.yield(serverMessage)
                } catch {
                    if Task.isCancelled { break }
                    logger.error("WebSocket receive error: \(error)")
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
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pingInterval ?? .seconds(30))
                guard !Task.isCancelled else { break }
                ws.sendPing { error in
                    if let error {
                        logger.warning("Ping failed: \(error)")
                    }
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
            disconnect()
            return
        }

        let nextAttempt = attempt + 1
        status = .reconnecting(attempt: nextAttempt)
        let delay = Self.reconnectDelay(attempt: nextAttempt)
        logger.info("Reconnecting in \(delay)s (attempt \(nextAttempt))")

        // Cancel old tasks
        receiveTask?.cancel()
        pingTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let cont = self.continuation else { return }
                self.openWebSocket(sessionId: sessionId, continuation: cont)
            }
        }
    }

    /// Exponential backoff with jitter: 2^(attempt-1) seconds, capped at 30s, ±25% jitter.
    /// Jitter prevents thundering herd when server restarts with multiple clients.
    nonisolated static func reconnectDelay(attempt: Int) -> TimeInterval {
        let base = min(pow(2, Double(attempt - 1)), 30)
        let jitterFactor = Double.random(in: 0.75...1.25)
        return base * jitterFactor
    }
}

// MARK: - Errors

enum WebSocketError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: return "WebSocket not connected"
        }
    }
}
