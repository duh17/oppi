import Foundation

/// A paired oppi server that the app can connect to.
///
/// Each server has a unique Ed25519 identity fingerprint used as the stable ID.
/// The same server may change host/port/token across re-pairs, but the
/// fingerprint (identity key) remains stable.
struct PairedServer: Identifiable, Codable, Sendable, Hashable {
    /// Server fingerprint (sha256:...) — unique, stable identity.
    let id: String
    /// Display name (from invite, editable by user).
    var name: String
    /// Server hostname or IP.
    var host: String
    /// Server port.
    var port: Int
    /// Auth token.
    var token: String
    /// Server Ed25519 fingerprint (same as `id`).
    var fingerprint: String

    // ── Local state (not from server) ──

    /// When this server was first paired.
    var addedAt: Date
    /// Manual sort order for UI.
    var sortOrder: Int

    // MARK: - Derived

    /// Derive `ServerCredentials` for connection and API calls.
    var credentials: ServerCredentials {
        ServerCredentials(
            host: host,
            port: port,
            token: token,
            name: name,
            serverFingerprint: fingerprint
        )
    }

    /// Base URL for REST calls.
    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }

    // MARK: - Init from ServerCredentials

    /// Create a `PairedServer` from validated `ServerCredentials`.
    ///
    /// The fingerprint becomes the stable server ID. If the credentials
    /// have no fingerprint, this returns `nil` — unpinned servers can't
    /// be uniquely identified across sessions.
    init?(from credentials: ServerCredentials, sortOrder: Int = 0) {
        guard let fp = credentials.normalizedServerFingerprint, !fp.isEmpty else {
            return nil
        }
        self.id = fp
        self.name = credentials.name
        self.host = credentials.host
        self.port = credentials.port
        self.token = credentials.token
        self.fingerprint = fp
        self.addedAt = Date()
        self.sortOrder = sortOrder
    }

    /// Update connection details from fresh credentials (re-pair).
    /// Preserves `id`, `addedAt`, `sortOrder`.
    mutating func updateCredentials(from credentials: ServerCredentials) {
        self.name = credentials.name
        self.host = credentials.host
        self.port = credentials.port
        self.token = credentials.token
    }
}
