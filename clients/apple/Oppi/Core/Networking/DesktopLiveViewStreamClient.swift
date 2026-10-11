import Foundation
import OSLog

private let liveViewStreamLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "DesktopLiveView")

@MainActor
struct DesktopLiveViewWebSocketTransport {
    typealias Message = URLSessionWebSocketTask.Message
    typealias CloseCode = URLSessionWebSocketTask.CloseCode

    let resume: () -> Void
    let receive: () async throws -> Message
    let send: (Message) async throws -> Void
    let cancel: (CloseCode, Data?) -> Void
    let response: () -> URLResponse?
    let closeCode: () -> CloseCode
    let closeReason: () -> Data?

    init(task: URLSessionWebSocketTask) {
        resume = { task.resume() }
        receive = { try await task.receive() }
        send = { message in try await task.send(message) }
        cancel = { code, reason in task.cancel(with: code, reason: reason) }
        response = { task.response }
        closeCode = { task.closeCode }
        closeReason = { task.closeReason }
    }

    init(
        resume: @escaping () -> Void,
        receive: @escaping () async throws -> Message,
        send: @escaping (Message) async throws -> Void,
        cancel: @escaping (CloseCode, Data?) -> Void,
        response: @escaping () -> URLResponse?,
        closeCode: @escaping () -> CloseCode,
        closeReason: @escaping () -> Data?
    ) {
        self.resume = resume
        self.receive = receive
        self.send = send
        self.cancel = cancel
        self.response = response
        self.closeCode = closeCode
        self.closeReason = closeReason
    }
}

/// Dedicated device-token WebSocket to `/desktop/view/stream`. Never the session or app-event stream.
@MainActor
final class DesktopLiveViewStreamClient {
    enum Event: Sendable {
        case media(header: DesktopViewMediaHeader, payload: Data)
        case hello(DesktopViewHello)
        case error(DesktopViewErrorMessage)
        case closed(code: Int, reason: String)
    }

    private let url: URL
    private var token: String
    private let currentTokenProvider: (@Sendable () async throws -> String)?
    private let refreshTokenProvider: (@Sendable () async throws -> String)?
    private let urlSession: URLSession
    private let webSocketFactory: (URLRequest) -> DesktopLiveViewWebSocketTransport
    private var task: DesktopLiveViewWebSocketTransport?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    private var generation = 0
    private var didForceRefreshForConnection = false

    init?(
        baseURL: URL,
        token: String,
        tlsCertFingerprint: String?,
        tlsServerName: String? = nil,
        tailnetRoute: TailnetTransportRoute.Snapshot? = nil,
        currentTokenProvider: (@Sendable () async throws -> String)? = nil,
        refreshTokenProvider: (@Sendable () async throws -> String)? = nil,
        webSocketFactory: ((URLRequest) -> DesktopLiveViewWebSocketTransport)? = nil
    ) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = DesktopViewStream.path
        guard let url = components.url else { return nil }
        self.url = url
        self.token = token
        self.currentTokenProvider = currentTokenProvider
        self.refreshTokenProvider = refreshTokenProvider
        let config = TailnetTransportRoute.defaultSessionConfiguration(
            route: tailnetRoute ?? .forHost(baseURL.host)
        )
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
            DesktopLiveViewWebSocketTransport(task: urlSession.webSocketTask(with: request))
        }
    }

    func connect() -> AsyncStream<Event> {
        disconnect()
        didForceRefreshForConnection = false
        generation += 1
        let current = generation
        return AsyncStream { [weak self] continuation in
            guard let self else { return }
            self.continuation = continuation
            Task { @MainActor in
                await self.open(generation: current)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.disconnect()
                }
            }
        }
    }

    func disconnect() {
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(.goingAway, nil)
        task = nil
        continuation?.finish()
        continuation = nil
    }

    private func open(generation current: Int) async {
        if let currentTokenProvider {
            do {
                let resolved = ServerAuthorization.resolvedToken(
                    try await currentTokenProvider(),
                    fallback: token
                )
                guard current == generation else { return }
                if !resolved.isEmpty { token = resolved }
            } catch {
                liveViewStreamLogger.error(
                    "Live view token resolve failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        guard current == generation, continuation != nil else { return }
        var request = URLRequest(url: url)
        ServerAuthorization.apply(token: token, to: &request)
        let socket = webSocketFactory(request)
        task = socket
        socket.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket, generation: current)
        }
    }

    private func receiveLoop(
        socket: DesktopLiveViewWebSocketTransport,
        generation current: Int
    ) async {
        while current == generation, !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard current == generation else { return }
                switch message {
                case .string(let text):
                    await handleText(text)
                case .data(let data):
                    await handleMedia(data)
                @unknown default:
                    continue
                }
            } catch {
                guard current == generation else { return }
                let status = (socket.response() as? HTTPURLResponse)?.statusCode
                if status == 404 {
                    finishUpgradeRejected()
                    return
                }
                if status == 401, await refreshAfterUnauthorized(generation: current, socket: socket) {
                    return
                }
                finishClosed(socket)
                return
            }
        }
    }

    private func handleText(_ text: String) async {
        guard let inbound = DesktopViewPhoneInbound.parse(Data(text.utf8)) else { return }
        switch inbound {
        case .ping(let ping):
            await send(.pong(t: ping.t))
        case .hello(let hello):
            didForceRefreshForConnection = false
            continuation?.yield(.hello(hello))
        case .error(let error):
            continuation?.yield(.error(error))
        case .ignored:
            break
        }
    }

    private func handleMedia(_ data: Data) async {
        let receivedAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        guard let header = try? DesktopViewMediaCodec.parseHeader(data) else { return }
        await send(.ack(frameId: header.frameId, receivedAt: receivedAt))
        continuation?.yield(.media(header: header, payload: data))
    }

    private func send(_ outbound: DesktopViewPhoneOutbound) async {
        guard let task else { return }
        let text = String(decoding: outbound.encode(), as: UTF8.self)
        do {
            try await task.send(.string(text))
        } catch {
            finishClosed(task)
        }
    }

    private func finishClosed(_ socket: DesktopLiveViewWebSocketTransport) {
        guard continuation != nil else { return }
        let code = Int(socket.closeCode().rawValue)
        let reason = String(data: socket.closeReason() ?? Data(), encoding: .utf8) ?? ""
        continuation?.yield(.closed(code: code, reason: reason))
        continuation?.finish()
        continuation = nil
    }

    private func finishUpgradeRejected() {
        guard continuation != nil else { return }
        continuation?.yield(.error(DesktopViewErrorMessage(
            code: 0,
            message: "",
            fatal: true
        )))
        continuation?.finish()
        continuation = nil
    }

    private func refreshAfterUnauthorized(
        generation current: Int,
        socket: DesktopLiveViewWebSocketTransport
    ) async -> Bool {
        guard current == generation, let refreshTokenProvider, !didForceRefreshForConnection else {
            return false
        }
        didForceRefreshForConnection = true
        do {
            if let currentTokenProvider {
                let currentToken = try await currentTokenProvider()
                if !currentToken.isEmpty, currentToken != token {
                    return installReplacementSocket(
                        token: currentToken,
                        generation: current,
                        replacing: socket
                    )
                }
            }
            let refreshed = try await refreshTokenProvider()
            guard !refreshed.isEmpty else { return false }
            return installReplacementSocket(
                token: refreshed,
                generation: current,
                replacing: socket
            )
        } catch {
            liveViewStreamLogger.error(
                "Live view token refresh failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    private func installReplacementSocket(
        token: String,
        generation current: Int,
        replacing previous: DesktopLiveViewWebSocketTransport
    ) -> Bool {
        guard current == generation, continuation != nil else { return true }
        self.token = token
        var request = URLRequest(url: url)
        ServerAuthorization.apply(token: token, to: &request)
        let socket = webSocketFactory(request)
        task = socket
        previous.cancel(.goingAway, nil)
        socket.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket, generation: current)
        }
        return true
    }
}
