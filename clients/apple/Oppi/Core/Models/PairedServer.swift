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

/// A paired Oppi server reachable over HTTPS/WSS.
struct PairedServer: Identifiable, Codable, Sendable, Hashable {
    let id: String
    var name: String
    var host: String
    var port: Int
    var scheme: ServerScheme?
    var token: String
    var tlsCertFingerprint: String?
    var deviceCredential: DeviceCredential?
    var addedAt: Date
    var sortOrder: Int
    var badgeIcon: ServerBadgeIcon?

    var resolvedBadgeIcon: ServerBadgeIcon { badgeIcon ?? .defaultValue }
    var resolvedScheme: ServerScheme { scheme ?? .https }
    var credentials: ServerCredentials {
        ServerCredentials(host: host, port: port, token: token, name: name, scheme: scheme,
                          serverFingerprint: id, tlsCertFingerprint: tlsCertFingerprint,
                          deviceCredential: deviceCredential)
    }

    var baseURL: URL? { credentials.baseURL }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, scheme, token, tlsCertFingerprint, transports
        case credentialGrant = "credentialTransports"
        case deviceCredential, addedAt, sortOrder, badgeIcon
    }

    init?(from credentials: ServerCredentials, sortOrder: Int = 0) {
        guard let fingerprint = credentials.normalizedServerFingerprint, !fingerprint.isEmpty else { return nil }
        self.id = fingerprint
        self.name = credentials.name
        self.host = credentials.host
        self.port = credentials.port
        self.scheme = credentials.scheme
        self.token = credentials.token
        self.tlsCertFingerprint = credentials.tlsCertFingerprint
        self.deviceCredential = credentials.deviceCredential
        self.addedAt = Date()
        self.sortOrder = sortOrder
        self.badgeIcon = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        let port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        if (container.contains(.transports) || container.contains(.credentialGrant)), host.isEmpty && port == 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .transports,
                in: container,
                debugDescription: "Unsupported Iroh connection; migrate this server to HTTPS/Tailscale"
            )
        }
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.host = host
        self.port = port
        self.scheme = try container.decodeIfPresent(ServerScheme.self, forKey: .scheme)
        self.token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        self.tlsCertFingerprint = try container.decodeIfPresent(String.self, forKey: .tlsCertFingerprint)
        self.deviceCredential = try container.decodeIfPresent(DeviceCredential.self, forKey: .deviceCredential)
        self.addedAt = try container.decode(Date.self, forKey: .addedAt)
        self.sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        self.badgeIcon = try container.decodeIfPresent(ServerBadgeIcon.self, forKey: .badgeIcon)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(scheme, forKey: .scheme)
        try container.encode(token, forKey: .token)
        try container.encodeIfPresent(tlsCertFingerprint, forKey: .tlsCertFingerprint)
        try container.encodeIfPresent(deviceCredential, forKey: .deviceCredential)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encodeIfPresent(badgeIcon, forKey: .badgeIcon)
    }

    mutating func updateCredentials(from credentials: ServerCredentials) {
        self.name = credentials.name
        self.host = credentials.host
        self.port = credentials.port
        self.scheme = credentials.scheme
        self.token = credentials.token
        self.tlsCertFingerprint = credentials.tlsCertFingerprint
        self.deviceCredential = credentials.deviceCredential
    }
}
