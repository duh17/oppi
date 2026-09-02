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
    let closeCode: () -> CloseCode

    init(task: URLSessionWebSocketTask) {
        identity = ObjectIdentifier(task)
        resume = { task.resume() }
        receive = { try await task.receive() }
        send = { message in try await task.send(message) }
        cancel = { code, reason in task.cancel(with: code, reason: reason) }
        response = { task.response }
        closeCode = { task.closeCode }
    }

    init(
        identity: AnyObject,
        resume: @escaping () -> Void,
        receive: @escaping () async throws -> Message,
        send: @escaping (Message) async throws -> Void,
        cancel: @escaping (CloseCode, Data?) -> Void,
        response: @escaping () -> URLResponse?,
        closeCode: @escaping () -> CloseCode
    ) {
        self.identity = ObjectIdentifier(identity)
        self.resume = resume
        self.receive = receive
        self.send = send
        self.cancel = cancel
        self.response = response
        self.closeCode = closeCode
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
    /// Queued until the current socket is writable, then replayed after a 401
    /// refresh or leftover-token rotate so start lands on the surviving socket.
    /// Cleared once the server accepts, completes, or fatally rejects the take
    /// so a later 4001 cannot start a phantom second recording.
    private var pendingDictationStart = false
    /// True only while a 401 refresh or leftover-token rotate is replacing the
    /// current socket. sendDictation may requeue dictation_start in that window.
    private var isRecoveringFromAuthFailure = false
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
        isRecoveringFromAuthFailure = false
        didForceRefreshForConnection = false

        return AsyncStream { [weak self] continuation in
            guard let self else { return }
            self.continuation = continuation
            self.startConnection(currentTokenProvider: self.currentTokenProvider)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.disconnect()
                }
            }
        }
    }

    private func startConnection(
        currentTokenProvider: (@Sendable () async throws -> String)?
    ) {
        // A live device session can have a fresher token than the leftover
        // ServerConnection.credentials snapshot. Resolve that first so the
        // initial /dictation/stream socket is not opened with a stale bearer.
        // Leftover-open only when that resolve fails or returns empty.
        guard let currentTokenProvider else {
            if token.isEmpty {
                disconnect()
            } else {
                openSocket()
            }
            return
        }
        Task { [weak self] in
            await self?.applyResolvedToken(currentTokenProvider)
        }
    }

    private func applyResolvedToken(
        _ currentTokenProvider: @Sendable () async throws -> String
    ) async {
        do {
            let current = try await currentTokenProvider()
            guard status != .disconnected, continuation != nil else { return }
            let resolved = ServerAuthorization.resolvedToken(current, fallback: token)
            if resolved.isEmpty {
                disconnect()
                return
            }
            if task == nil {
                token = resolved
                openSocket()
                await replayPendingDictationStart()
                return
            }
            guard resolved != token else { return }
            // A 401-forced refresh has already installed a server-issued token on the
            // current socket. The cached value just resolved is necessarily <= that token
            // and may already be evicted server-side (unknown_token); do not regress
            // self.token or cancel/reopen the socket the 401 handler owns.
            guard !didForceRefreshForConnection else { return }
            isRecoveringFromAuthFailure = true
            token = resolved
            task?.cancel(.goingAway, nil)
            openSocket()
            await replayPendingDictationStart()
            isRecoveringFromAuthFailure = false
        } catch {
            dictationStreamLogger.error("Initial device token resolution failed: \(String(describing: error), privacy: .public)")
            // Re-check after the await. A disconnect during currentAccessToken()
            // must not leftover-open an unowned socket.
            guard status != .disconnected, continuation != nil else { return }
            if token.isEmpty {
                disconnect()
            } else if task == nil {
                openSocket()
                await replayPendingDictationStart()
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
        switch message {
        case .dictationStart:
            pendingDictationStart = true
        case .dictationStop, .dictationCancel:
            // User stop/cancel is terminal for replay even if the send later
            // suspends and a 4001 refresh installs a replacement socket.
            pendingDictationStart = false
        default:
            break
        }
        guard let task else {
            // Queue dictation_start until the first writable socket exists.
            if case .dictationStart = message, status != .disconnected, continuation != nil {
                return
            }
            throw WebSocketError.notConnected
        }
        do {
            try await sendEncoded(message, on: task)
        } catch {
            // Only a 401 refresh or leftover rotate may requeue start. A 403/500/
            // TLS/network handshake failure must fail enable immediately.
            if case .dictationStart = message,
               isRecoveringFromAuthFailure,
               status != .disconnected,
               continuation != nil {
                return
            }
            throw error
        }
    }

    private func sendEncoded(_ message: ClientMessage, on task: DictationWebSocketTransport) async throws {
        let data = try JSONEncoder().encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WebSocketError.encodingFailed
        }
        try await task.send(.string(text))
        if status == .connecting { status = .connected }
    }

    private func clearPendingStartIfAcceptedOrCompleted(_ message: ServerMessage) {
        switch message {
        case .dictationReady, .dictationFinal:
            pendingDictationStart = false
        case .dictationError(_, let fatal) where fatal:
            pendingDictationStart = false
        default:
            break
        }
    }

    private func replayPendingDictationStart() async {
        guard pendingDictationStart, let task, status != .disconnected, continuation != nil else {
            return
        }
        do {
            try await sendEncoded(.dictationStart, on: task)
        } catch {
            dictationStreamLogger.error(
                "Failed to send queued dictation_start: \(String(describing: error), privacy: .public)"
            )
        }
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
        pendingDictationStart = false
        isRecoveringFromAuthFailure = false
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
                    clearPendingStartIfAcceptedOrCompleted(decoded)
                    continuation?.yield(decoded)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        let decoded = try decodeMessage(from: text)
                        if status == .connecting { status = .connected }
                        clearPendingStartIfAcceptedOrCompleted(decoded)
                        continuation?.yield(decoded)
                    }
                @unknown default:
                    break
                }
            } catch {
                let statusCode = (task.response() as? HTTPURLResponse)?.statusCode
                if let refreshTokenProvider,
                   statusCode == 401 || WebSocketRecoveryPolicy.isAuthExpiredCloseCode(task.closeCode()) {
                    // Expired/unknown device token: force exactly one refresh, then
                    // install exactly one replacement socket and end THIS loop.
                    // Revoked/unknown device, an empty token, or a repeated 401 is
                    // terminal (no reconnect loop).
                    guard !didForceRefreshForConnection else {
                        dictationStreamLogger.error("Repeated 401 after forced refresh — disconnecting")
                        break
                    }
                    isRecoveringFromAuthFailure = true
                    do {
                        if let currentTokenProvider {
                            let current = try await currentTokenProvider()
                            if !current.isEmpty, current != token {
                                guard !Task.isCancelled,
                                      self.task?.identity == task.identity,
                                      continuation != nil,
                                      status != .disconnected else {
                                    isRecoveringFromAuthFailure = false
                                    dictationStreamLogger.info("Dictation disconnected during 401 refresh — not reopening")
                                    return
                                }
                                token = current
                                openSocket()
                                await replayPendingDictationStart()
                                isRecoveringFromAuthFailure = false
                                return
                            }
                        }
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
                                isRecoveringFromAuthFailure = false
                                dictationStreamLogger.info("Dictation disconnected during 401 refresh — not reopening")
                                return
                            }
                            token = refreshed
                            didForceRefreshForConnection = true
                            openSocket()
                            await replayPendingDictationStart()
                            isRecoveringFromAuthFailure = false
                            return
                        }
                    } catch {
                        dictationStreamLogger.error("Device-key refresh failed on 401: \(String(describing: error), privacy: .public)")
                    }
                    isRecoveringFromAuthFailure = false
                }
                dictationStreamLogger.warning("Dictation stream receive ended: \(String(describing: error), privacy: .public)")
                break
            }
        }
        // Terminal: this socket's loop owns the disconnect. On the success path
        // above we `return` before reaching here, leaving the replacement socket
        // and its continuation intact. A superseded loop must not tear down the
        // socket that replaced it.
        guard self.task?.identity == task.identity else { return }
        status = .disconnected
        continuation?.finish()
    }
}
