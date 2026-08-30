import Foundation

/// Application payload on a platform-neutral WebSocket transport.
enum WebSocketTransportMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// Close metadata from a completed WebSocket close handshake.
struct WebSocketTransportClose: Sendable, Equatable {
    var code: UInt16
    var reason: Data
}

/// One live WebSocket for text, binary, ping/pong, and close.
///
/// Implementations own serialized writes and cancellation. iOS and remote
/// Mac connections keep `URLSessionWebSocketTask`; the embedded Mac path
/// uses an owner Unix-socket adapter.
protocol WebSocketTransporting: Sendable {
    func send(_ message: WebSocketTransportMessage) async throws
    func receive() async throws -> WebSocketTransportMessage
    func ping() async throws
    func close(code: UInt16, reason: Data?) async
    func cancel()
}

enum WebSocketTransportError: Error, Equatable, LocalizedError {
    case handshakeFailed(String)
    case upgradeRejected(statusCode: Int)
    case invalidFrame(String)
    case messageTooLarge
    case invalidUTF8
    case closed(WebSocketTransportClose)
    case cancelled
    case timeout

    var errorDescription: String? {
        switch self {
        case .handshakeFailed(let message):
            "WebSocket handshake failed: \(message)"
        case .upgradeRejected(let statusCode):
            "WebSocket upgrade was rejected (HTTP \(statusCode))."
        case .invalidFrame(let message):
            "Invalid WebSocket frame: \(message)"
        case .messageTooLarge:
            "WebSocket message exceeded the 16 MiB limit."
        case .invalidUTF8:
            "WebSocket text frame was not valid UTF-8."
        case .closed(let close):
            "WebSocket closed (\(close.code))."
        case .cancelled:
            "WebSocket connection was cancelled."
        case .timeout:
            "WebSocket operation timed out."
        }
    }
}
