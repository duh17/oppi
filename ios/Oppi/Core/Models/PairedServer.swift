import Foundation

/// Configurable icon options for server badges in the UI.
enum ServerBadgeIcon: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case macStudio = "macstudio.fill"
    case desktop = "desktopcomputer"
    case serverRack = "server.rack"
    case laptop = "laptopcomputer"
    case terminal = "terminal"
    case bolt = "bolt.horizontal.circle"

    static let defaultValue: Self = .macStudio

    var id: String { rawValue }
    var symbolName: String { rawValue }

    var title: String {
        switch self {
        case .macStudio: return "Mac Studio"
        case .desktop: return "Desktop"
        case .serverRack: return "Server Rack"
        case .laptop: return "Laptop"
        case .terminal: return "Terminal"
        case .bolt: return "Bolt"
        }
    }
}

/// Configurable color options for server badges in the UI.
enum ServerBadgeColor: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case orange
    case blue
    case cyan
    case green
    case purple
    case red
    case yellow
    case neutral

    static let defaultValue: Self = .orange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orange: return "Orange"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .green: return "Green"
        case .purple: return "Purple"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .neutral: return "Neutral"
        }
    }
}

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

    /// Optional user-selected badge icon.
    var badgeIcon: ServerBadgeIcon?
    /// Optional user-selected badge color.
    var badgeColor: ServerBadgeColor?

    // MARK: - Derived

    var resolvedBadgeIcon: ServerBadgeIcon {
        badgeIcon ?? .defaultValue
    }

    var resolvedBadgeColor: ServerBadgeColor {
        badgeColor ?? .defaultValue
    }

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
        self.badgeIcon = nil
        self.badgeColor = nil
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
