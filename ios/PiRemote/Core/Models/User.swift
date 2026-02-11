import CryptoKit
import Foundation

/// Authenticated user info returned by `GET /me`.
struct User: Codable, Sendable, Equatable {
    let user: String   // user id
    let name: String
}

/// Connection credentials from QR code scan.
///
/// Legacy v1 QR payload:
/// `{"host":"...","port":7749,"token":"sk_...","name":"Chen"}`
///
/// Signed v2 payload is an envelope decoded by `decodeInvitePayload(_:)`.
struct ServerCredentials: Codable, Sendable, Equatable {
    let host: String
    let port: Int
    let token: String
    let name: String

    // Optional v2 trust metadata
    let serverFingerprint: String?
    let securityProfile: String?
    let inviteVersion: Int?
    let inviteKeyId: String?

    // Server-authored transport + trust policy (from /security/profile)
    let requireTlsOutsideTailnet: Bool?
    let allowInsecureHttpInTailnet: Bool?
    let requirePinnedServerIdentity: Bool?

    init(
        host: String,
        port: Int,
        token: String,
        name: String,
        serverFingerprint: String? = nil,
        securityProfile: String? = nil,
        inviteVersion: Int? = nil,
        inviteKeyId: String? = nil,
        requireTlsOutsideTailnet: Bool? = nil,
        allowInsecureHttpInTailnet: Bool? = nil,
        requirePinnedServerIdentity: Bool? = nil
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.name = name
        self.serverFingerprint = serverFingerprint
        self.securityProfile = securityProfile
        self.inviteVersion = inviteVersion
        self.inviteKeyId = inviteKeyId
        self.requireTlsOutsideTailnet = requireTlsOutsideTailnet
        self.allowInsecureHttpInTailnet = allowInsecureHttpInTailnet
        self.requirePinnedServerIdentity = requirePinnedServerIdentity
    }

    /// Base URL for REST and WebSocket connections.
    /// Returns `nil` for malformed host (corrupted QR, bad keychain data).
    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }

    /// WebSocket URL for a specific session.
    ///
    /// Workspace-scoped v2 path only.
    func webSocketURL(sessionId: String, workspaceId: String) -> URL? {
        URL(string: "ws://\(host):\(port)/workspaces/\(workspaceId)/sessions/\(sessionId)/stream")
    }

    /// Decode either legacy v1 invite JSON or signed v2 envelope JSON.
    static func decodeInvitePayload(_ payload: String) -> ServerCredentials? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        // v1 legacy path
        if let legacy = try? decoder.decode(ServerCredentials.self, from: data) {
            guard !legacy.host.isEmpty, (1...65_535).contains(legacy.port), !legacy.token.isEmpty else {
                return nil
            }
            return legacy
        }

        // v2 signed envelope path
        guard let env = try? decoder.decode(InviteEnvelopeV2.self, from: data) else {
            return nil
        }
        guard env.v == 2, env.alg == "Ed25519" else { return nil }

        let now = Int(Date().timeIntervalSince1970)
        // Allow modest clock skew on issue time, enforce expiry.
        guard env.exp >= now, env.iat <= now + 300 else { return nil }

        guard verifyV2Signature(env) else { return nil }

        let p = env.payload
        guard !p.host.isEmpty, (1...65_535).contains(p.port), !p.token.isEmpty else {
            return nil
        }

        return ServerCredentials(
            host: p.host,
            port: p.port,
            token: p.token,
            name: p.name,
            serverFingerprint: p.fingerprint,
            securityProfile: p.securityProfile,
            inviteVersion: 2,
            inviteKeyId: env.kid
        )
    }

    var normalizedServerFingerprint: String? {
        guard let serverFingerprint else { return nil }
        let trimmed = serverFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func applyingSecurityProfile(_ profile: ServerSecurityProfile) -> ServerCredentials {
        let profileFingerprint = profile.identity.normalizedFingerprint
        return ServerCredentials(
            host: host,
            port: port,
            token: token,
            name: name,
            serverFingerprint: profileFingerprint ?? normalizedServerFingerprint,
            securityProfile: profile.profile,
            inviteVersion: inviteVersion,
            inviteKeyId: inviteKeyId ?? profile.identity.keyId,
            requireTlsOutsideTailnet: profile.requireTlsOutsideTailnet,
            allowInsecureHttpInTailnet: profile.allowInsecureHttpInTailnet,
            requirePinnedServerIdentity: profile.requirePinnedServerIdentity
        )
    }

    private static func verifyV2Signature(_ env: InviteEnvelopeV2) -> Bool {
        guard let publicKeyData = decodeBase64URL(env.publicKey),
              let signatureData = decodeBase64URL(env.sig) else {
            return false
        }

        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            let input = buildInviteSigningInput(env)
            return publicKey.isValidSignature(signatureData, for: Data(input.utf8))
        } catch {
            return false
        }
    }

    private static func buildInviteSigningInput(_ env: InviteEnvelopeV2) -> String {
        let p = env.payload
        return [
            "v=\(env.v)",
            "alg=\(env.alg)",
            "kid=\(env.kid)",
            "iat=\(env.iat)",
            "exp=\(env.exp)",
            "nonce=\(env.nonce)",
            "publicKey=\(env.publicKey)",
            "host=\(p.host)",
            "port=\(p.port)",
            "token=\(p.token)",
            "name=\(p.name)",
            "fingerprint=\(p.fingerprint)",
            "securityProfile=\(p.securityProfile)",
        ].joined(separator: "\n")
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

private struct InviteEnvelopeV2: Decodable {
    let v: Int
    let alg: String
    let kid: String
    let iat: Int
    let exp: Int
    let nonce: String
    let publicKey: String
    let payload: InvitePayloadV2
    let sig: String
}

private struct InvitePayloadV2: Decodable {
    let host: String
    let port: Int
    let token: String
    let name: String
    let fingerprint: String
    let securityProfile: String
}

/// Server-authored security posture returned by `GET /security/profile`.
struct ServerSecurityProfile: Codable, Sendable, Equatable {
    struct Identity: Codable, Sendable, Equatable {
        let enabled: Bool?
        let algorithm: String
        let keyId: String
        let fingerprint: String

        var normalizedFingerprint: String? {
            let trimmed = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    struct Invite: Codable, Sendable, Equatable {
        let format: String
        let allowLegacyV1Unsigned: Bool
        let maxAgeSeconds: Int
    }

    let configVersion: Int
    let profile: String
    let requireTlsOutsideTailnet: Bool?
    let allowInsecureHttpInTailnet: Bool?
    let requirePinnedServerIdentity: Bool?
    let identity: Identity
    let invite: Invite
}
