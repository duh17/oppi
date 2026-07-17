import Foundation
import OSLog

private let dictationStreamLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "DictationStream")

@MainActor
final class DictationStreamClient: DictationTransport {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
    }

    private(set) var status: Status = .disconnected

    private let url: URL
    private let token: String
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<ServerMessage>.Continuation?

    init?(baseURL: URL, token: String, tlsCertFingerprint: String?) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/dictation/stream"
        guard let url = components.url else { return nil }
        self.url = url
        self.token = token

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.urlSession = URLSession(
            configuration: config,
            delegate: PinnedServerTrustDelegate(pinnedLeafFingerprint: tlsCertFingerprint),
            delegateQueue: nil
        )
    }

    func connect() -> AsyncStream<ServerMessage> {
        disconnect()
        status = .connecting

        return AsyncStream { [weak self] continuation in
            guard let self else { return }
            self.continuation = continuation

            var request = URLRequest(url: self.url)
            ServerAuthorization.apply(token: self.token, to: &request)

            let task = self.urlSession.webSocketTask(with: request)
            self.task = task
            task.resume()
            dictationStreamLogger.info("Connecting dictation stream: \(self.url.absoluteString, privacy: .public)")
            self.receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.disconnect()
                }
            }
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
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
        status = .disconnected
    }

    private func decodeMessage(from text: String) throws -> ServerMessage {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(ServerMessage.self, from: data)
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let task {
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
                dictationStreamLogger.warning("Dictation stream receive ended: \(String(describing: error), privacy: .public)")
                break
            }
        }
        status = .disconnected
        continuation?.finish()
    }
}
