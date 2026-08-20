import CryptoKit
import Foundation
import Network

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
    let pairingToken: String?
    let serverFingerprint: String?
    let tlsCertFingerprint: String?
    let deviceCredential: DeviceCredential?

    init(
        host: String,
        port: Int,
        token: String,
        name: String,
        scheme: ServerScheme? = .https,
        pairingToken: String? = nil,
        serverFingerprint: String? = nil,
        tlsCertFingerprint: String? = nil,
        deviceCredential: DeviceCredential? = nil
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.name = name
        self.scheme = scheme
        self.pairingToken = pairingToken
        self.serverFingerprint = serverFingerprint
        self.tlsCertFingerprint = tlsCertFingerprint
        self.deviceCredential = deviceCredential
    }

    var effectiveAccessToken: String { deviceCredential?.accessToken ?? token }

    var resolvedScheme: ServerScheme { scheme ?? .https }

    /// Route identity for connection reuse. Rotating `at_` fields, display name,
    /// and pairing tokens are excluded; a leftover static token is kept when this
    /// server has no device credential.
    var transportIdentity: ServerTransportIdentity { ServerTransportIdentity(self) }

    var baseURL: URL? {
        guard !host.isEmpty, (1...65_535).contains(port) else { return nil }
        return URL(string: "\(resolvedScheme.rawValue)://\(host):\(port)")
    }

    enum CodingKeys: String, CodingKey {
        case host, port, token, name, scheme, pairingToken, serverFingerprint
        case tlsCertFingerprint, transports, deviceCredential
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        let port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
        if container.contains(.transports), host.isEmpty && port == 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .transports,
                in: container,
                debugDescription: "Unsupported connection; pair this server over HTTPS/Tailscale again"
            )
        }
        self.init(
            host: host,
            port: port,
            token: try container.decodeIfPresent(String.self, forKey: .token) ?? "",
            name: try container.decode(String.self, forKey: .name),
            scheme: try container.decodeIfPresent(ServerScheme.self, forKey: .scheme),
            pairingToken: try container.decodeIfPresent(String.self, forKey: .pairingToken),
            serverFingerprint: try container.decodeIfPresent(String.self, forKey: .serverFingerprint),
            tlsCertFingerprint: try container.decodeIfPresent(String.self, forKey: .tlsCertFingerprint),
            deviceCredential: try container.decodeIfPresent(DeviceCredential.self, forKey: .deviceCredential)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(token, forKey: .token)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(scheme, forKey: .scheme)
        try container.encodeIfPresent(pairingToken, forKey: .pairingToken)
        try container.encodeIfPresent(serverFingerprint, forKey: .serverFingerprint)
        try container.encodeIfPresent(tlsCertFingerprint, forKey: .tlsCertFingerprint)
        try container.encodeIfPresent(deviceCredential, forKey: .deviceCredential)
    }

    static func decodeInvitePayload(_ payload: String) -> Self? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(SignedInviteEnvelopeV3.self, from: data), envelope.v == 3 {
            guard let signedData = decodeBase64URL(envelope.signedPayload),
                  let publicKeyData = decodeBase64URL(envelope.publicKey),
                  let signatureData = decodeBase64URL(envelope.signature),
                  let signedPayload = String(data: signedData, encoding: .utf8) else { return nil }
            do {
                let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
                guard publicKey.isValidSignature(signatureData, for: signedData) else { return nil }
            } catch { return nil }
            guard var credentials = decodeUnsignedInvitePayload(signedPayload, allowPinnedUnsigned: true) else {
                return nil
            }
            let fingerprint = "sha256:\(Data(SHA256.hash(data: publicKeyData)).base64URLEncodedString)"
            guard credentials.serverFingerprint == fingerprint else { return nil }
            credentials = credentials.withServerFingerprint(fingerprint)
            return credentials
        }
        return decodeUnsignedInvitePayload(payload, allowPinnedUnsigned: false)
    }

    static func decodeInviteURL(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "oppi" else { return nil }
        let route = url.host?.lowercased() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard route == "connect" || route == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let queryItems = components.queryItems ?? []
        if let version = queryItems.first(where: { $0.name == "v" })?.value,
           !version.isEmpty, version != "3" { return nil }
        if let invite = queryItems.first(where: { $0.name == "invite" })?.value,
           let decoded = decodeBase64URL(invite),
           let raw = String(data: decoded, encoding: .utf8) {
            return decodeInvitePayload(raw)
        }
        if let raw = queryItems.first(where: { $0.name == "payload" })?.value, !raw.isEmpty {
            return decodeInvitePayload(raw)
        }
        return nil
    }

    static func decodeInviteURLString(_ value: String) -> Self? {
        guard let url = URL(string: value) else { return nil }
        return decodeInviteURL(url)
    }

    var normalizedServerFingerprint: String? {
        guard let value = serverFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var normalizedTLSCertFingerprint: String? {
        guard let value = tlsCertFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func withAuthToken(_ newToken: String) -> Self {
        Self(host: host, port: port, token: newToken, name: name, scheme: scheme,
             serverFingerprint: serverFingerprint, tlsCertFingerprint: tlsCertFingerprint,
             deviceCredential: deviceCredential)
    }

    func withDeviceCredential(_ credential: DeviceCredential) -> Self {
        Self(host: host, port: port, token: "", name: name, scheme: scheme,
             serverFingerprint: serverFingerprint, tlsCertFingerprint: tlsCertFingerprint,
             deviceCredential: credential)
    }

    private func withServerFingerprint(_ fingerprint: String) -> Self {
        Self(host: host, port: port, token: token, name: name, scheme: scheme,
             pairingToken: pairingToken, serverFingerprint: fingerprint,
             tlsCertFingerprint: tlsCertFingerprint, deviceCredential: deviceCredential)
    }

    private static func decodeUnsignedInvitePayload(_ payload: String, allowPinnedUnsigned: Bool) -> Self? {
        guard let data = payload.data(using: .utf8), let v3 = try? JSONDecoder().decode(InvitePayloadV3.self, from: data), v3.v == 3 else { return nil }
        if !allowPinnedUnsigned && (!(v3.fingerprint?.isEmpty ?? true) || !(v3.tlsCertFingerprint?.isEmpty ?? true)) { return nil }
        let hasDirectToken = !v3.token.isEmpty
        let hasPairingToken = !(v3.pairingToken?.isEmpty ?? true)
        guard !v3.host.isEmpty, (1...65_535).contains(v3.port), hasDirectToken || hasPairingToken else { return nil }
        let rawScheme = v3.scheme?.lowercased() ?? ServerScheme.https.rawValue
        guard let scheme = ServerScheme(rawValue: rawScheme) else { return nil }
        return Self(host: v3.host, port: v3.port, token: v3.token, name: v3.name,
                    scheme: scheme, pairingToken: v3.pairingToken,
                    serverFingerprint: v3.fingerprint, tlsCertFingerprint: v3.tlsCertFingerprint)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }
}

/// Stable HTTPS/WSS route identity. Token rotation on the same device must not
/// look like a new server.
struct ServerTransportIdentity: Equatable, Hashable, Sendable {
    let host: String
    let port: Int
    let scheme: ServerScheme
    let serverFingerprint: String?
    let tlsCertFingerprint: String?
    let deviceId: String?
    let leftoverToken: String?

    init(_ credentials: ServerCredentials) {
        self.host = credentials.host
        self.port = credentials.port
        self.scheme = credentials.resolvedScheme
        self.serverFingerprint = credentials.normalizedServerFingerprint
        self.tlsCertFingerprint = credentials.normalizedTLSCertFingerprint
        if let deviceId = credentials.deviceCredential?.deviceId, !deviceId.isEmpty {
            self.deviceId = deviceId
            self.leftoverToken = nil
        } else {
            self.deviceId = nil
            self.leftoverToken = credentials.token
        }
    }
}

private struct SignedInviteEnvelopeV3: Decodable {
    let v: Int
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

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
