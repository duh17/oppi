import Foundation

/// The one paired-server record. The app and the Share extension decode the
/// same Keychain item into it (`PairedServerKeychain`); the app adds pairing
/// and credential updates on top (`Oppi/Core/Models/PairedServer+Credentials.swift`).

enum ServerScheme: String, Codable, Sendable {
    case http
    case https

    var websocketScheme: String {
        switch self {
        case .http:
            "ws"
        case .https:
            "wss"
        }
    }
}

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

    var baseURL: URL? {
        guard !host.isEmpty, (1...65_535).contains(port) else { return nil }
        return URL(string: "\(resolvedScheme.rawValue)://\(host):\(port)")
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, scheme, token, tlsCertFingerprint, transports
        case credentialGrant = "credentialTransports"
        case deviceCredential, addedAt, sortOrder, badgeIcon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        let port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        if container.contains(.transports) || container.contains(.credentialGrant), host.isEmpty && port == 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .transports,
                in: container,
                debugDescription: "Unsupported connection; pair this server over HTTPS/Tailscale again"
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
}
