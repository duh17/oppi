import Foundation

/// Configurable icon options for server badges in the UI.
enum ServerBadgeIcon: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    // Computers
    case macStudio = "macstudio.fill"
    case desktop = "desktopcomputer"
    case laptop = "laptopcomputer"
    case macMini = "macmini.fill"
    case macPro = "macpro.gen3.fill"
    case display = "display"

    // Infrastructure
    case serverRack = "server.rack"
    case cpu = "cpu"
    case memorychip = "memorychip"
    case externaldrive = "externaldrive.fill"

    // Network & Cloud
    case cloud = "cloud.fill"
    case network = "network"
    case antenna = "antenna.radiowaves.left.and.right"
    case wifi = "wifi"

    // Dev & Tools
    case terminal = "terminal"
    case hammer = "hammer.fill"
    case wrench = "wrench.and.screwdriver.fill"
    case gearshape = "gearshape.2.fill"

    // Abstract
    case bolt = "bolt.horizontal.circle"
    case cube = "cube.fill"
    case hexagon = "hexagon.fill"
    case atom = "atom"
    case sparkles = "sparkles"
    case shield = "shield.checkered"

    static let defaultValue: Self = .macStudio

    var id: String { rawValue }
    var symbolName: String { rawValue }
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
    /// Transport scheme (`http` or `https`).
    var scheme: ServerScheme?
    /// Auth token.
    var token: String
    /// Optional leaf-cert pin for self-signed HTTPS.
    var tlsCertFingerprint: String?
    /// Server Ed25519 fingerprint (same as `id`).
    var fingerprint: String

    // ── Local state (not from server) ──

    /// When this server was first paired.
    var addedAt: Date
    /// Manual sort order for UI.
    var sortOrder: Int

    /// Optional user-selected badge icon.
    var badgeIcon: ServerBadgeIcon?

    // MARK: - Derived

    var resolvedBadgeIcon: ServerBadgeIcon {
        badgeIcon ?? .defaultValue
    }

    var resolvedScheme: ServerScheme {
        scheme ?? .https
    }

    /// Derive `ServerCredentials` for connection and API calls.
    var credentials: ServerCredentials {
        ServerCredentials(
            host: host,
            port: port,
            token: token,
            name: name,
            scheme: resolvedScheme,
            serverFingerprint: fingerprint,
            tlsCertFingerprint: tlsCertFingerprint
        )
    }

    /// Base URL for REST calls.
    var baseURL: URL? {
        URL(string: "\(resolvedScheme.rawValue)://\(host):\(port)")
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
        self.scheme = credentials.scheme
        self.token = credentials.token
        self.tlsCertFingerprint = credentials.tlsCertFingerprint
        self.fingerprint = fp
        self.addedAt = Date()
        self.sortOrder = sortOrder
        self.badgeIcon = nil
    }

    /// Update connection details from fresh credentials (re-pair).
    /// Preserves `id`, `addedAt`, `sortOrder`.
    mutating func updateCredentials(from credentials: ServerCredentials) {
        self.name = credentials.name
        self.host = credentials.host
        self.port = credentials.port
        self.scheme = credentials.scheme
        self.token = credentials.token
        self.tlsCertFingerprint = credentials.tlsCertFingerprint
    }
}
