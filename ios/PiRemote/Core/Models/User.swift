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
    /// Returns `nil` for malformed host (corrupted QR, bad keychain data).
    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }

    /// WebSocket URL for a specific session.
    ///
    /// Uses workspace-scoped v2 path when `workspaceId` is provided,
    /// falls back to legacy v1 path otherwise.
    func webSocketURL(sessionId: String, workspaceId: String? = nil) -> URL? {
        if let workspaceId, !workspaceId.isEmpty {
            return URL(string: "ws://\(host):\(port)/workspaces/\(workspaceId)/sessions/\(sessionId)/stream")
        }
        return URL(string: "ws://\(host):\(port)/sessions/\(sessionId)/stream")
    }
}
