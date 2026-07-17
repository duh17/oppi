import CryptoKit
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

enum TransportPreference: String, Codable, Sendable, Equatable, Hashable {
    case irohOnly
    case irohPreferred
    case httpOnly
}

enum IrohAddressMode: String, Codable, Sendable, Equatable, Hashable {
    case nodeId = "node-id"
    case ticket
}

struct IrohServerTransport: Codable, Sendable, Equatable, Hashable {
    let version: Int
    let nodeId: String
    let alpns: [String]
    let addressMode: IrohAddressMode
    let ticket: String?
}

struct HTTPServerTransport: Codable, Sendable, Equatable, Hashable {
    let host: String
    let port: Int
    let scheme: ServerScheme
    let tlsCertFingerprint: String?

    var baseURL: URL? {
        URL(string: "\(scheme.rawValue)://\(host):\(port)")
    }
}

struct ServerTransports: Codable, Sendable, Equatable, Hashable {
    var preference: TransportPreference
    var iroh: IrohServerTransport?
    var http: HTTPServerTransport?

    init(
        preference: TransportPreference,
        iroh: IrohServerTransport? = nil,
        http: HTTPServerTransport? = nil
    ) {
        self.preference = preference
        self.iroh = iroh
        self.http = http
    }

    static func legacyHTTP(
        host: String,
        port: Int,
        scheme: ServerScheme?,
        tlsCertFingerprint: String?
    ) -> Self {
        let http = validHTTPTransport(
            host: host,
            port: port,
            scheme: scheme ?? .https,
            tlsCertFingerprint: tlsCertFingerprint
        )
        return Self(preference: .httpOnly, http: http)
    }

    private static func validHTTPTransport(
        host: String,
        port: Int,
        scheme: ServerScheme,
        tlsCertFingerprint: String?
    ) -> HTTPServerTransport? {
        // Legacy/stored HTTP credentials used to derive baseURL directly from
        // host/port, and Foundation accepts edge host values such as an empty
        // host. Keep that compatibility here; Iroh-only credentials opt out by
        // carrying explicit transports with `http == nil`.
        guard (1...65_535).contains(port) else { return nil }
        return HTTPServerTransport(
            host: host,
            port: port,
            scheme: scheme,
            tlsCertFingerprint: tlsCertFingerprint
        )
    }
}

/// Connection credentials from QR code scan or deep link.
///
/// Invite payload is decoded by `decodeInvitePayload(_:)`.
/// Current invites use signed v3 envelopes. Unsigned v3 payloads are
/// accepted only when they do not carry pinned identity metadata.
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

    // Signed transport metadata. v3 credentials synthesize an HTTP-only value.
    let transports: ServerTransports

    init(
        host: String,
        port: Int,
        token: String,
        name: String,
        scheme: ServerScheme? = .https,
        pairingToken: String? = nil,
        serverFingerprint: String? = nil,
        tlsCertFingerprint: String? = nil,
        transports: ServerTransports? = nil
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.name = name
        self.scheme = scheme
        self.pairingToken = pairingToken
        self.serverFingerprint = serverFingerprint
        self.tlsCertFingerprint = tlsCertFingerprint
        self.transports = transports ?? ServerTransports.legacyHTTP(
            host: host,
            port: port,
            scheme: scheme,
            tlsCertFingerprint: tlsCertFingerprint
        )
    }

    var resolvedScheme: ServerScheme {
        scheme ?? transports.http?.scheme ?? .https
    }

    /// Base URL for REST and WebSocket connections.
    /// Returns `nil` for malformed host (corrupted QR, bad keychain data) or Iroh-only servers.
    var baseURL: URL? {
        transports.http?.baseURL
    }

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case token
        case name
        case scheme
        case pairingToken
        case serverFingerprint
        case tlsCertFingerprint
        case transports
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        let port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        let token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        let name = try container.decode(String.self, forKey: .name)
        let scheme = try container.decodeIfPresent(ServerScheme.self, forKey: .scheme)
        let pairingToken = try container.decodeIfPresent(String.self, forKey: .pairingToken)
        let serverFingerprint = try container.decodeIfPresent(String.self, forKey: .serverFingerprint)
        let tlsCertFingerprint = try container.decodeIfPresent(String.self, forKey: .tlsCertFingerprint)
        let transports = try container.decodeIfPresent(ServerTransports.self, forKey: .transports)

        self.init(
            host: host,
            port: port,
            token: token,
            name: name,
            scheme: scheme,
            pairingToken: pairingToken,
            serverFingerprint: serverFingerprint,
            tlsCertFingerprint: tlsCertFingerprint,
            transports: transports
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if transports.http != nil || !host.isEmpty {
            try container.encode(host, forKey: .host)
        }
        if transports.http != nil || port != 0 {
            try container.encode(port, forKey: .port)
        }
        try container.encode(token, forKey: .token)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(scheme, forKey: .scheme)
        try container.encodeIfPresent(pairingToken, forKey: .pairingToken)
        try container.encodeIfPresent(serverFingerprint, forKey: .serverFingerprint)
        try container.encodeIfPresent(tlsCertFingerprint, forKey: .tlsCertFingerprint)
        try container.encode(transports, forKey: .transports)
    }

    /// Decode invite payload JSON.
    ///
    /// Supported formats:
    /// - signed v4 envelope with host-free transport metadata
    /// - signed v3 envelope with pinned server identity metadata
    /// - unsigned v3 payload without pinned identity metadata
    static func decodeInvitePayload(_ payload: String) -> Self? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(SignedInviteEnvelopeV4.self, from: data), envelope.v == 4 {
            guard envelope.alg == "ed25519",
                  let signedPayloadData = decodeBase64URL(envelope.signedPayload),
                  let publicKeyData = decodeBase64URL(envelope.publicKey),
                  let signatureData = decodeBase64URL(envelope.signature) else {
                return nil
            }

            do {
                let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
                let signatureInput = Data(envelope.signedPayload.utf8)
                guard publicKey.isValidSignature(signatureData, for: signatureInput) else { return nil }
            } catch {
                return nil
            }

            guard let signedPayload = try? decoder.decode(InvitePayloadV4.self, from: signedPayloadData) else {
                return nil
            }
            let derivedFingerprint = "sha256:\(Data(SHA256.hash(data: publicKeyData)).base64URLEncodedString)"
            guard signedPayload.v == 4,
                  !signedPayload.name.isEmpty,
                  !signedPayload.pairingToken.isEmpty,
                  signedPayload.fingerprint == derivedFingerprint,
                  let transports = buildTransports(from: signedPayload) else {
                return nil
            }

            let http = transports.http
            return ServerCredentials(
                host: http?.host ?? "",
                port: http?.port ?? 0,
                token: "",
                name: signedPayload.name,
                scheme: http?.scheme,
                pairingToken: signedPayload.pairingToken,
                serverFingerprint: derivedFingerprint,
                tlsCertFingerprint: http?.tlsCertFingerprint,
                transports: transports
            )
        }

        if let envelope = try? decoder.decode(SignedInviteEnvelopeV3.self, from: data), envelope.v == 3 {
            guard let signedData = decodeBase64URL(envelope.signedPayload),
                  let publicKeyData = decodeBase64URL(envelope.publicKey),
                  let signatureData = decodeBase64URL(envelope.signature),
                  let signedPayload = String(data: signedData, encoding: .utf8) else {
                return nil
            }

            do {
                let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
                guard publicKey.isValidSignature(signatureData, for: signedData) else { return nil }
            } catch {
                return nil
            }

            guard var credentials = decodeUnsignedInvitePayload(signedPayload, allowPinnedUnsigned: true) else {
                return nil
            }
            let derivedFingerprint = "sha256:\(Data(SHA256.hash(data: publicKeyData)).base64URLEncodedString)"
            guard credentials.normalizedServerFingerprint == derivedFingerprint else { return nil }
            credentials = ServerCredentials(
                host: credentials.host,
                port: credentials.port,
                token: credentials.token,
                name: credentials.name,
                scheme: credentials.resolvedScheme,
                pairingToken: credentials.pairingToken,
                serverFingerprint: derivedFingerprint,
                tlsCertFingerprint: credentials.tlsCertFingerprint
            )
            return credentials
        }

        return decodeUnsignedInvitePayload(payload, allowPinnedUnsigned: false)
    }

    /// Decode a deep-link invite.
    ///
    /// Supported routes:
    /// - `oppi://connect?...`
    /// - `oppi://pair?...`
    static func decodeInviteURL(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "oppi" else {
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
           version != "3",
           version != "4" {
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
            scheme: transports.http?.scheme ?? scheme,
            pairingToken: nil,
            serverFingerprint: serverFingerprint,
            tlsCertFingerprint: tlsCertFingerprint,
            transports: transports
        )
    }

    private static func decodeUnsignedInvitePayload(
        _ payload: String,
        allowPinnedUnsigned: Bool
    ) -> Self? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        guard let v3 = try? decoder.decode(InvitePayloadV3.self, from: data), v3.v == 3 else {
            return nil
        }

        if !allowPinnedUnsigned,
           (!(v3.fingerprint?.isEmpty ?? true) || !(v3.tlsCertFingerprint?.isEmpty ?? true)) {
            return nil
        }

        let hasDirectToken = !v3.token.isEmpty
        let hasPairingToken = !(v3.pairingToken?.isEmpty ?? true)
        guard !v3.host.isEmpty, (1...65_535).contains(v3.port), hasDirectToken || hasPairingToken else {
            return nil
        }

        let inviteSchemeRaw = (v3.scheme?.lowercased() ?? ServerScheme.https.rawValue)
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

    private static func buildTransports(from payload: InvitePayloadV4) -> ServerTransports? {
        let iroh = payload.transports.iroh
        let http = payload.transports.http

        if let iroh {
            guard !iroh.nodeId.isEmpty, !iroh.alpns.isEmpty else { return nil }
        }
        if let http {
            guard !http.host.isEmpty, (1...65_535).contains(http.port) else { return nil }
        }

        switch payload.preference {
        case .irohOnly:
            guard iroh != nil, http == nil else { return nil }
        case .irohPreferred:
            guard iroh != nil, http != nil else { return nil }
        case .httpOnly:
            guard http != nil else { return nil }
        }

        return ServerTransports(preference: payload.preference, iroh: iroh, http: http)
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

private struct SignedInviteEnvelopeV3: Decodable {
    let v: Int
    let signedPayload: String
    let publicKey: String
    let signature: String
}

private struct SignedInviteEnvelopeV4: Decodable {
    let v: Int
    let alg: String
    let signedPayload: String
    let publicKey: String
    let signature: String
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

private struct InvitePayloadV4: Decodable {
    let v: Int
    let name: String
    let pairingToken: String
    let fingerprint: String
    let preference: TransportPreference
    let transports: InviteTransportsV4
}

private struct InviteTransportsV4: Decodable {
    let iroh: IrohServerTransport?
    let http: HTTPServerTransport?
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
