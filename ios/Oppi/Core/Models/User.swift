import Foundation

/// Authenticated user info returned by `GET /me`.
struct User: Codable, Sendable, Equatable {
    let user: String   // user id
    let name: String
}

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

/// Connection credentials from QR code scan.
///
/// Invite payload is decoded by `decodeInvitePayload(_:)`.
/// Supported invite format: unsigned v3 payloads.
struct ServerCredentials: Codable, Sendable, Equatable {
    let host: String
    let port: Int
    let token: String
    let name: String
    let scheme: ServerScheme?

    // One-time pairing bootstrap token (preferred over token when present)
    let pairingToken: String?

    // Stable server identity metadata
    let serverFingerprint: String?

    // Optional leaf-cert pin for self-signed HTTPS pairing.
    let tlsCertFingerprint: String?

    init(
        host: String,
        port: Int,
        token: String,
        name: String,
        scheme: ServerScheme = .http,
        pairingToken: String? = nil,
        serverFingerprint: String? = nil,
        tlsCertFingerprint: String? = nil
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.name = name
        self.scheme = scheme
        self.pairingToken = pairingToken
        self.serverFingerprint = serverFingerprint
        self.tlsCertFingerprint = tlsCertFingerprint
    }

    var resolvedScheme: ServerScheme {
        scheme ?? .http
    }

    /// Base URL for REST and WebSocket connections.
    /// Returns `nil` for malformed host (corrupted QR, bad keychain data).
    var baseURL: URL? {
        URL(string: "\(resolvedScheme.rawValue)://\(host):\(port)")
    }

    /// WebSocket URL for the multiplexed `/stream` endpoint.
    ///
    /// Supports subscribing to multiple sessions over a single connection.
    /// Each server gets one persistent `/stream` WebSocket.
    var streamURL: URL? {
        URL(string: "\(resolvedScheme.websocketScheme)://\(host):\(port)/stream")
    }

    /// Decode invite payload JSON.
    ///
    /// Supported format:
    /// - unsigned v3 payload (current)
    static func decodeInvitePayload(_ payload: String) -> Self? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        guard let v3 = try? decoder.decode(InvitePayloadV3.self, from: data), v3.v == 3 else {
            return nil
        }

        let hasDirectToken = !v3.token.isEmpty
        let hasPairingToken = !(v3.pairingToken?.isEmpty ?? true)
        guard !v3.host.isEmpty, (1...65_535).contains(v3.port), hasDirectToken || hasPairingToken else {
            return nil
        }

        let inviteSchemeRaw = (v3.scheme?.lowercased() ?? ServerScheme.http.rawValue)
        guard let inviteScheme = ServerScheme(rawValue: inviteSchemeRaw) else {
            return nil
        }

        return Self(
            host: v3.host,
            port: v3.port,
            token: v3.token,
            name: v3.name,
            scheme: inviteScheme,
            pairingToken: v3.pairingToken,
            serverFingerprint: v3.fingerprint,
            tlsCertFingerprint: v3.tlsCertFingerprint
        )
    }

    /// Decode a deep-link invite.
    ///
    /// Supported routes:
    /// - `pi://connect?...`
    /// - `pi://pair?...`
    /// - `oppi://connect?...`
    /// - `oppi://pair?...`
    static func decodeInviteURL(_ url: URL) -> Self? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "pi" || scheme == "oppi" else {
            return nil
        }

        let hostRoute = url.host?.lowercased()
        let pathRoute = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let route = hostRoute?.isEmpty == false ? hostRoute : (pathRoute.isEmpty ? nil : pathRoute)

        guard route == "connect" || route == "pair" else {
            return nil
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let inviteParam = queryValue(named: "invite", in: queryItems)

        if let version = queryValue(named: "v", in: queryItems),
           !version.isEmpty,
           version != "3" {
            return nil
        }

        if let inviteParam,
           let inviteData = decodeBase64URL(inviteParam),
           let invitePayload = String(data: inviteData, encoding: .utf8) {
            return decodeInvitePayload(invitePayload)
        }

        if let rawPayload = queryValue(named: "payload", in: queryItems), !rawPayload.isEmpty {
            return decodeInvitePayload(rawPayload)
        }

        return nil
    }

    /// Decode a deep-link invite from raw text.
    static func decodeInviteURLString(_ value: String) -> Self? {
        guard let url = URL(string: value) else { return nil }
        return decodeInviteURL(url)
    }

    var normalizedServerFingerprint: String? {
        guard let serverFingerprint else { return nil }
        let trimmed = serverFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedTLSCertFingerprint: String? {
        guard let tlsCertFingerprint else { return nil }
        let trimmed = tlsCertFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func withAuthToken(_ newToken: String) -> Self {
        Self(
            host: host,
            port: port,
            token: newToken,
            name: name,
            scheme: resolvedScheme,
            pairingToken: nil,
            serverFingerprint: serverFingerprint,
            tlsCertFingerprint: tlsCertFingerprint
        )
    }

    private static func queryValue(named name: String, in queryItems: [URLQueryItem]) -> String? {
        queryItems.first(where: { $0.name == name })?.value
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let rem = normalized.count % 4
        if rem > 0 {
            normalized += String(repeating: "=", count: 4 - rem)
        }

        return Data(base64Encoded: normalized)
    }
}

private struct InvitePayloadV3: Decodable {
    let v: Int
    let host: String
    let port: Int
    let scheme: String?
    let token: String
    let pairingToken: String?
    let name: String
    let tlsCertFingerprint: String?
    let fingerprint: String?
}
