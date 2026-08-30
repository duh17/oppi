import Foundation
import OSLog

private let macDictationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacDictation"
)

/// Owner Unix-socket endpoint for `/dictation/stream`.
///
/// `sk_` travels only in `Authorization: Bearer`. The stream path is a
/// constant and must never be turned into an HTTPS/WSS URL.
struct MacDictationEndpoint: Equatable, Sendable {
    let socketPath: String
    let token: String

    var streamPath: String { DictationComposerPolicy.streamPath }

    func ownerHeaders() -> [String: String] {
        MacUnixWebSocketTransport.ownerHeaders(token: token)
    }

    var authorizationHeader: String {
        ownerHeaders()["Authorization"] ?? ""
    }

    static func localOwner(
        dataDir: String = NSString("~/.config/oppi").expandingTildeInPath
    ) -> MacDictationEndpoint? {
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else { return nil }
        return MacDictationEndpoint(
            socketPath: MacLocalAPISocket.path(dataDir: dataDir),
            token: token
        )
    }
}

protocol MacDictationSocketTransporting: WebSocketTransporting {
    func connect() async throws
}

extension MacUnixWebSocketTransport: MacDictationSocketTransporting {}

@MainActor
protocol MacDictationTransporting: AnyObject {
    func connect() async throws
    func sendControl(_ message: ClientMessage) async throws
    func sendAudio(_ data: Data) async throws
    func receive() async throws -> ServerMessage
    func close()
}

/// Encodes dictation control/audio onto the owner Unix-socket WebSocket.
@MainActor
final class MacDictationStreamClient: MacDictationTransporting {
    let endpoint: MacDictationEndpoint
    private let transport: any MacDictationSocketTransporting

    var streamPath: String { endpoint.streamPath }
    var authorizationHeader: String { endpoint.authorizationHeader }

    init(
        endpoint: MacDictationEndpoint,
        transport: (any MacDictationSocketTransporting)? = nil
    ) {
        self.endpoint = endpoint
        self.transport = transport ?? MacUnixWebSocketTransport(
            socketPath: endpoint.socketPath,
            path: endpoint.streamPath,
            headers: endpoint.ownerHeaders()
        )
    }

    func connect() async throws {
        macDictationLogger.info("Connecting dictation stream: \(self.streamPath, privacy: .public)")
        try await transport.connect()
    }

    func sendControl(_ message: ClientMessage) async throws {
        try await transport.send(.text(try message.jsonString()))
    }

    func sendAudio(_ data: Data) async throws {
        try await transport.send(.data(data))
    }

    func receive() async throws -> ServerMessage {
        switch try await transport.receive() {
        case .text(let text):
            return try ServerMessage.decode(from: text)
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw WebSocketTransportError.invalidUTF8
            }
            return try ServerMessage.decode(from: text)
        }
    }

    func close() {
        transport.cancel()
    }
}
