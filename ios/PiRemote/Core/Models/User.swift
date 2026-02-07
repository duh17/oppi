import Foundation

/// Authenticated user info returned by `GET /me`.
struct User: Codable, Sendable, Equatable {
    let user: String   // user id
    let name: String
}

/// Connection credentials from QR code scan.
///
/// QR payload: `{"host":"...","port":7749,"token":"sk_...","name":"Chen"}`
struct ServerCredentials: Codable, Sendable, Equatable {
    let host: String
    let port: Int
    let token: String
    let name: String

    /// Base URL for REST and WebSocket connections.
    var baseURL: URL {
        // Host is validated during QR parse / manual entry
        guard let url = URL(string: "http://\(host):\(port)") else {
            fatalError("Invalid server credentials: host=\(host) port=\(port)")
        }
        return url
    }

    /// WebSocket URL for a specific session.
    func webSocketURL(sessionId: String) -> URL {
        guard let url = URL(string: "ws://\(host):\(port)/sessions/\(sessionId)/stream") else {
            fatalError("Invalid WebSocket URL for session \(sessionId)")
        }
        return url
    }
}
