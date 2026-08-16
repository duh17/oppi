import Foundation
import OSLog

private let dictationStreamLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "DictationStream")

/// Narrow transport seam for deterministic dictation reconnect tests.
/// Production still delegates every operation to `URLSessionWebSocketTask`.
@MainActor
struct DictationWebSocketTransport {
    typealias Message = URLSessionWebSocketTask.Message
    typealias CloseCode = URLSessionWebSocketTask.CloseCode

    let identity: ObjectIdentifier
    let resume: () -> Void
    let receive: () async throws -> Message
    let send: (Message) async throws -> Void
    let cancel: (CloseCode, Data?) -> Void
    let response: () -> URLResponse?

    init(task: URLSessionWebSocketTask) {
        identity = ObjectIdentifier(task)
        resume = { task.resume() }
        receive = { try await task.receive() }
        send = { message in try await task.send(message) }
        cancel = { code, reason in task.cancel(with: code, reason: reason) }
        response = { task.response }
    }

    init(
        identity: AnyObject,
        resume: @escaping () -> Void,
        receive: @escaping () async throws -> Message,
        send: @escaping (Message) async throws -> Void,
        cancel: @escaping (CloseCode, Data?) -> Void,
        response: @escaping () -> URLResponse?
    ) {
        self.identity = ObjectIdentifier(identity)
        self.resume = resume
        self.receive = receive
        self.send = send
        self.cancel = cancel
        self.response = response
    }
}

@MainActor
final class DictationStreamClient: DictationTransport {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
    }

    private(set) var status: Status = .disconnected

    private let url: URL
    private var token: String
    private let currentTokenProvider: (@Sendable () async throws -> String)?
    private let refreshTokenProvider: (@Sendable () async throws -> String)?
    private let urlSession: URLSession
    private let webSocketFactory: (URLRequest) -> DictationWebSocketTransport
    private var task: DictationWebSocketTransport?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<ServerMessage>.Continuation?
    /// True after a forced refresh has been consumed on the current socket. A
    /// second 401 on a socket that was already refreshed once is terminal, so a
    /// server that keeps rejecting freshly-issued tokens cannot loop forever.
    private var didForceRefreshForConnection = false

    init?(
        baseURL: URL,
        token: String,
        tlsCertFingerprint: String?,
        tlsServerName: String? = nil,
        currentTokenProvider: (@Sendable () async throws -> String)? = nil,
        refreshTokenProvider: (@Sendable () async throws -> String)? = nil,
        webSocketFactory: ((URLRequest) -> DictationWebSocketTransport)? = nil
    ) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/dictation/stream"
        guard let url = components.url else { return nil }
        self.url = url
        self.token = token
        self.currentTokenProvider = currentTokenProvider
        self.refreshTokenProvider = refreshTokenProvider

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.urlSession = URLSession(
            configuration: config,
            delegate: PinnedServerTrustDelegate(
                pinnedLeafFingerprint: tlsCertFingerprint,
                expectedServerName: tlsServerName
            ),
            delegateQueue: nil
        )
        self.webSocketFactory = webSocketFactory ?? { [urlSession] request in
            DictationWebSocketTransport(task: urlSession.webSocketTask(with: request))
        }
    }

    func connect() -> AsyncStream<ServerMessage> {
        disconnect()
        status = .connecting
        didForceRefreshForConnection = false

        return AsyncStream { [weak self] continuation in
            guard let self else { return }
            self.continuation = continuation
            if let currentTokenProvider = self.currentTokenProvider {
                Task { [weak self] in
                    do {
                        let current = try await currentTokenProvider()
                        guard let self,
                              self.status != .disconnected,
                              self.continuation != nil,
                              !current.isEmpty else {
                            self?.disconnect()
                            return
                        }
                        self.token = current
                        self.openSocket()
                    } catch {
                        dictationStreamLogger.error("Initial device token resolution failed: \(String(describing: error), privacy: .public)")
                        self?.disconnect()
                    }
                }
            } else {
                self.openSocket()
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.disconnect()
                }
            }
        }
    }

    private func openSocket() {
        var request = URLRequest(url: self.url)
        ServerAuthorization.apply(token: self.token, to: &request)
        let task = self.webSocketFactory(request)
        self.task = task
        task.resume()
        dictationStreamLogger.info("Connecting dictation stream: \(self.url.absoluteString, privacy: .public)")
        // Each socket owns exactly one receive loop. On a successful 401 refresh
        // the replacement socket is installed here and the old loop returns, so
        // no two loops ever read the same socket.
        receiveTask = Task { [weak self, task] in
            await self?.receiveLoop(task: task)
        }
    }

    func sendDictation(_ message: ClientMessage) async throws {
        guard let task else { throw WebSocketError.notConnected }
        let data = try JSONEncoder().encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WebSocketError.encodingFailed
        }
        try await task.send(.string(text))
        if status == .connecting { status = .connected }
    }

    func sendDictationAudio(_ data: Data) async throws {
        guard let task else { throw WebSocketError.notConnected }
        try await task.send(.data(data))
        if status == .connecting { status = .connected }
    }

    func closeDictationTransport() {
        disconnect()
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(.normalClosure, nil)
        task = nil
        continuation?.finish()
        continuation = nil
        status = .disconnected
    }

    private func decodeMessage(from text: String) throws -> ServerMessage {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(ServerMessage.self, from: data)
    }

    private func receiveLoop(task: DictationWebSocketTransport) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    let decoded = try decodeMessage(from: text)
                    if status == .connecting { status = .connected }
                    continuation?.yield(decoded)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        let decoded = try decodeMessage(from: text)
                        if status == .connecting { status = .connected }
                        continuation?.yield(decoded)
                    }
                @unknown default:
                    break
                }
            } catch {
                let statusCode = (task.response() as? HTTPURLResponse)?.statusCode
                if statusCode == 401, let refreshTokenProvider {
                    // Expired/unknown device token: force exactly one refresh, then
                    // install exactly one replacement socket and end THIS loop.
                    // Revoked/unknown device, an empty token, or a repeated 401 is
                    // terminal (no reconnect loop).
                    guard !didForceRefreshForConnection else {
                        dictationStreamLogger.error("Repeated 401 after forced refresh — disconnecting")
                        break
                    }
                    do {
                        let refreshed = try await refreshTokenProvider()
                        if !refreshed.isEmpty {
                            // Re-check socket identity, cancellation, continuation,
                            // and connection state AFTER the await. A disconnect
                            // during the refresh must not resurrect a new unowned
                            // socket and receive loop.
                            guard !Task.isCancelled,
                                  self.task?.identity == task.identity,
                                  continuation != nil,
                                  status != .disconnected else {
                                dictationStreamLogger.info("Dictation disconnected during 401 refresh — not reopening")
                                return
                            }
                            token = refreshed
                            didForceRefreshForConnection = true
                            await MainActor.run { [weak self] in self?.openSocket() }
                            return
                        }
                    } catch {
                        dictationStreamLogger.error("Device-key refresh failed on 401: \(String(describing: error), privacy: .public)")
                    }
                }
                dictationStreamLogger.warning("Dictation stream receive ended: \(String(describing: error), privacy: .public)")
                break
            }
        }
        // Terminal: this socket's loop owns the disconnect. On the success path
        // above we `return` before reaching here, leaving the replacement socket
        // and its continuation intact.
        status = .disconnected
        continuation?.finish()
    }
}
