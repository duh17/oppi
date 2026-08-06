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
    /// Server hostname or IP for HTTP-capable servers.
    var host: String
    /// Server port for HTTP-capable servers.
    var port: Int
    /// Transport scheme (`http` or `https`) for HTTP-capable servers.
    var scheme: ServerScheme?
    /// Auth token.
    var token: String
    /// Optional leaf-cert pin for self-signed HTTPS.
    var tlsCertFingerprint: String?
    /// Server Ed25519 fingerprint (same as `id`).
    var fingerprint: String
    /// Signed transport metadata. Existing servers synthesize an HTTP-only value.
    var transports: ServerTransports
    /// Client-only route restriction. Missing persisted values default to automatic.
    var routeMode: PairedServerRouteMode
    /// Server-confirmed scope of the stored device token. Nil means unknown.
    var credentialGrant: CredentialTransportGrant?

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
        scheme ?? transports.http?.scheme ?? .https
    }

    /// Applies the local preference to the current signed authorization set.
    var effectiveRouteMode: PairedServerRouteMode {
        routeMode.effective(for: transports.authorizedTransports)
    }

    /// Derive `ServerCredentials` for connection and API calls.
    var credentials: ServerCredentials {
        ServerCredentials(
            host: host,
            port: port,
            token: token,
            name: name,
            scheme: transports.http?.scheme ?? scheme,
            serverFingerprint: fingerprint,
            tlsCertFingerprint: tlsCertFingerprint,
            transports: transports,
            credentialGrant: credentialGrant
        )
    }

    /// Base URL for REST calls.
    var baseURL: URL? {
        transports.http?.baseURL
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case scheme
        case token
        case tlsCertFingerprint
        case fingerprint
        case transports
        case routeMode
        case credentialGrant = "credentialTransports"
        case addedAt
        case sortOrder
        case badgeIcon
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
        self.transports = credentials.transports
        self.routeMode = .automatic
        self.credentialGrant = credentials.credentialGrant
        self.addedAt = Date()
        self.sortOrder = sortOrder
        self.badgeIcon = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        scheme = try container.decodeIfPresent(ServerScheme.self, forKey: .scheme)
        token = try container.decode(String.self, forKey: .token)
        tlsCertFingerprint = try container.decodeIfPresent(String.self, forKey: .tlsCertFingerprint)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        transports = try container.decodeIfPresent(ServerTransports.self, forKey: .transports)
            ?? ServerTransports.legacyHTTP(
                host: host,
                port: port,
                scheme: scheme,
                tlsCertFingerprint: tlsCertFingerprint
            )
        routeMode = try container.decodeIfPresent(PairedServerRouteMode.self, forKey: .routeMode) ?? .automatic
        credentialGrant = try container.decodeIfPresent(
            CredentialTransportGrant.self,
            forKey: .credentialGrant
        )
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        badgeIcon = try container.decodeIfPresent(ServerBadgeIcon.self, forKey: .badgeIcon)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        if transports.http != nil || !host.isEmpty {
            try container.encode(host, forKey: .host)
        }
        if transports.http != nil || port != 0 {
            try container.encode(port, forKey: .port)
        }
        try container.encodeIfPresent(scheme, forKey: .scheme)
        try container.encode(token, forKey: .token)
        try container.encodeIfPresent(tlsCertFingerprint, forKey: .tlsCertFingerprint)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(transports, forKey: .transports)
        try container.encode(routeMode, forKey: .routeMode)
        try container.encodeIfPresent(credentialGrant, forKey: .credentialGrant)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encodeIfPresent(badgeIcon, forKey: .badgeIcon)
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
        self.transports = credentials.transports
        self.credentialGrant = credentials.credentialGrant
    }
}
