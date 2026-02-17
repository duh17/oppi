import Testing
import Foundation
import CryptoKit
@testable import Oppi

// MARK: - Session Codable

@Suite("Session Codable")
struct SessionCodableTests {

    @Test func decodeFullSession() throws {
        let json = """
        {
            "id": "s1",
            "workspaceId": "w1",
            "workspaceName": "Dev",
            "name": "Test Session",
            "status": "busy",
            "createdAt": 1700000000000,
            "lastActivity": 1700003600000,
            "model": "claude-sonnet-4-20250514",
            "runtime": "container",
            "messageCount": 5,
            "tokens": {"input": 100, "output": 50},
            "cost": 0.01,
            "contextTokens": 1500,
            "contextWindow": 200000,
            "lastMessage": "Hello world"
        }
        """
        let session = try JSONDecoder().decode(Session.self, from: json.data(using: .utf8)!)

        #expect(session.id == "s1")
        #expect(session.workspaceId == "w1")
        #expect(session.workspaceName == "Dev")
        #expect(session.name == "Test Session")
        #expect(session.status == .busy)
        #expect(session.model == "claude-sonnet-4-20250514")
        #expect(session.runtime == "container")
        #expect(session.messageCount == 5)
        #expect(session.tokens.input == 100)
        #expect(session.tokens.output == 50)
        #expect(session.cost == 0.01)
        #expect(session.contextTokens == 1500)
        #expect(session.contextWindow == 200000)
        #expect(session.lastMessage == "Hello world")

        // Unix milliseconds → Date
        #expect(session.createdAt.timeIntervalSince1970 == 1700000000)
        #expect(session.lastActivity.timeIntervalSince1970 == 1700003600)
    }

    @Test func decodeMinimalSession() throws {
        let json = """
        {
            "id": "s2",
            "status": "ready",
            "createdAt": 1700000000000,
            "lastActivity": 1700000000000,
            "messageCount": 0,
            "tokens": {"input": 0, "output": 0},
            "cost": 0
        }
        """
        let session = try JSONDecoder().decode(Session.self, from: json.data(using: .utf8)!)

        #expect(session.id == "s2")
        #expect(session.workspaceId == nil)
        #expect(session.workspaceName == nil)
        #expect(session.name == nil)
        #expect(session.model == nil)
        #expect(session.runtime == nil)
        #expect(session.contextTokens == nil)
        #expect(session.contextWindow == nil)
        #expect(session.lastMessage == nil)
    }

    @Test func encodeDecodeRoundTrip() throws {
        let json = """
        {
            "id": "s3",
            "workspaceId": "w1",
            "workspaceName": "Workspace",
            "name": "Round Trip",
            "status": "stopped",
            "createdAt": 1700000000000,
            "lastActivity": 1700001000000,
            "model": "claude-sonnet-4-20250514",
            "runtime": "host",
            "messageCount": 10,
            "tokens": {"input": 200, "output": 100},
            "cost": 0.05,
            "contextTokens": 3000,
            "contextWindow": 100000,
            "lastMessage": "Done"
        }
        """
        let original = try JSONDecoder().decode(Session.self, from: json.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: encoded)

        #expect(original == decoded)
    }

    @Test func allSessionStatuses() throws {
        let statuses: [(String, SessionStatus)] = [
            ("starting", .starting),
            ("ready", .ready),
            ("busy", .busy),
            ("stopping", .stopping),
            ("stopped", .stopped),
            ("error", .error),
        ]
        for (raw, expected) in statuses {
            let json = """
            {
                "id": "s", "status": "\(raw)",
                "createdAt": 0, "lastActivity": 0,
                "messageCount": 0, "tokens": {"input": 0, "output": 0}, "cost": 0
            }
            """
            let session = try JSONDecoder().decode(Session.self, from: json.data(using: .utf8)!)
            #expect(session.status == expected)
        }
    }

    @Test func tokenUsageRoundTrip() throws {
        let json = """
        {"input": 42, "output": 17}
        """
        let original = try JSONDecoder().decode(TokenUsage.self, from: json.data(using: .utf8)!)
        #expect(original.input == 42)
        #expect(original.output == 17)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: encoded)
        #expect(original == decoded)
    }
}

// MARK: - SessionMessage Codable

@Suite("SessionMessage Codable")
struct SessionMessageCodableTests {

    @Test func decodeUserMessage() throws {
        let json = """
        {
            "id": "m1", "sessionId": "s1", "role": "user",
            "content": "Hello", "timestamp": 1700000000000
        }
        """
        let msg = try JSONDecoder().decode(SessionMessage.self, from: json.data(using: .utf8)!)
        #expect(msg.role == .user)
        #expect(msg.content == "Hello")
        #expect(msg.model == nil)
        #expect(msg.tokens == nil)
        #expect(msg.cost == nil)
        #expect(msg.timestamp.timeIntervalSince1970 == 1700000000)
    }

    @Test func decodeAssistantWithOptionals() throws {
        let json = """
        {
            "id": "m2", "sessionId": "s1", "role": "assistant",
            "content": "Hi!", "timestamp": 1700000000000,
            "model": "claude-sonnet-4-20250514",
            "tokens": {"input": 10, "output": 5},
            "cost": 0.001
        }
        """
        let msg = try JSONDecoder().decode(SessionMessage.self, from: json.data(using: .utf8)!)
        #expect(msg.role == .assistant)
        #expect(msg.model == "claude-sonnet-4-20250514")
        #expect(msg.tokens?.input == 10)
        #expect(msg.cost == 0.001)
    }

    @Test func encodeDecodeRoundTrip() throws {
        let json = """
        {
            "id": "m3", "sessionId": "s1", "role": "system",
            "content": "You are helpful", "timestamp": 1700000000000,
            "model": "test", "tokens": {"input": 1, "output": 2}, "cost": 0.0
        }
        """
        let original = try JSONDecoder().decode(SessionMessage.self, from: json.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionMessage.self, from: encoded)
        #expect(original == decoded)
    }

    @Test func allMessageRoles() throws {
        for role in ["user", "assistant", "system"] {
            let json = """
            {"id":"m","sessionId":"s","role":"\(role)","content":"x","timestamp":0}
            """
            let msg = try JSONDecoder().decode(SessionMessage.self, from: json.data(using: .utf8)!)
            #expect(msg.role.rawValue == role)
        }
    }
}

// MARK: - ModelInfo Codable

@Suite("ModelInfo Codable")
struct ModelInfoCodableTests {

    @Test func decodeModelInfo() throws {
        let json = """
        {
            "id": "claude-sonnet-4-20250514",
            "name": "Claude Sonnet 4",
            "provider": "anthropic",
            "contextWindow": 200000
        }
        """
        let model = try JSONDecoder().decode(ModelInfo.self, from: json.data(using: .utf8)!)
        #expect(model.id == "claude-sonnet-4-20250514")
        #expect(model.name == "Claude Sonnet 4")
        #expect(model.provider == "anthropic")
        #expect(model.contextWindow == 200000)
    }
}

// MARK: - Permission Codable

@Suite("Permission Codable")
struct PermissionCodableTests {

    @Test func decodePermissionRequest() throws {
        let json = """
        {
            "id": "p1",
            "sessionId": "s1",
            "tool": "bash",
            "input": {"command": "rm -rf /"},
            "displaySummary": "bash: rm -rf /",
            "risk": "critical",
            "reason": "Destructive command",
            "timeoutAt": 1700003600000
        }
        """
        let perm = try JSONDecoder().decode(PermissionRequest.self, from: json.data(using: .utf8)!)

        #expect(perm.id == "p1")
        #expect(perm.sessionId == "s1")
        #expect(perm.tool == "bash")
        #expect(perm.input["command"] == .string("rm -rf /"))
        #expect(perm.displaySummary == "bash: rm -rf /")
        #expect(perm.risk == .critical)
        #expect(perm.reason == "Destructive command")
        #expect(perm.timeoutAt.timeIntervalSince1970 == 1700003600)
        #expect(perm.expires)
    }

    @Test func decodePermissionRequestWithoutExpiry() throws {
        let json = """
        {
            "id": "p1",
            "sessionId": "s1",
            "tool": "bash",
            "input": {"command": "git push origin main"},
            "displaySummary": "bash: git push origin main",
            "risk": "high",
            "reason": "Git push",
            "timeoutAt": 1700003600000,
            "expires": false
        }
        """
        let perm = try JSONDecoder().decode(PermissionRequest.self, from: json.data(using: .utf8)!)

        #expect(!perm.expires)
        #expect(!perm.hasExpiry)
    }

    @Test func encodeDecodeRoundTrip() throws {
        let json = """
        {
            "id": "p2", "sessionId": "s1", "tool": "read",
            "input": {"path": "/etc/passwd"},
            "displaySummary": "read: /etc/passwd",
            "risk": "low", "reason": "Read access",
            "timeoutAt": 1700000060000
        }
        """
        let original = try JSONDecoder().decode(PermissionRequest.self, from: json.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PermissionRequest.self, from: encoded)
        #expect(original == decoded)
    }

    @Test func allRiskLevels() throws {
        for level in ["low", "medium", "high", "critical"] {
            let json = """
            {
                "id":"p","sessionId":"s","tool":"t","input":{},"displaySummary":"x",
                "risk":"\(level)","reason":"r","timeoutAt":0
            }
            """
            let perm = try JSONDecoder().decode(PermissionRequest.self, from: json.data(using: .utf8)!)
            #expect(perm.risk.rawValue == level)
        }
    }

    @Test func permissionActionCodable() throws {
        for action in ["allow", "deny"] {
            let json = "\"\(action)\""
            let decoded = try JSONDecoder().decode(PermissionAction.self, from: json.data(using: .utf8)!)
            #expect(decoded.rawValue == action)

            let encoded = try JSONEncoder().encode(decoded)
            let reDecoded = try JSONDecoder().decode(PermissionAction.self, from: encoded)
            #expect(reDecoded == decoded)
        }
    }
}

// MARK: - User + ServerCredentials

@Suite("User Codable")
struct UserCodableTests {

    @Test func decodeUser() throws {
        let json = """
        {"user": "u1", "name": "Chen"}
        """
        let user = try JSONDecoder().decode(User.self, from: json.data(using: .utf8)!)
        #expect(user.user == "u1")
        #expect(user.name == "Chen")
    }

    @Test func encodeDecodeRoundTrip() throws {
        let json = """
        {"user": "u2", "name": "Alice"}
        """
        let original = try JSONDecoder().decode(User.self, from: json.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(User.self, from: encoded)
        #expect(original == decoded)
    }
}

@Suite("ServerCredentials")
struct ServerCredentialsTests {

    @Test func baseURLValid() {
        let creds = ServerCredentials(host: "192.168.1.10", port: 7749, token: "sk_test", name: "Test")
        let url = creds.baseURL
        #expect(url != nil)
        #expect(url?.absoluteString == "http://192.168.1.10:7749")
    }

    @Test func baseURLWithHostname() {
        let creds = ServerCredentials(host: "mac-studio.ts.net", port: 7749, token: "sk_test", name: "Test")
        let url = creds.baseURL
        #expect(url != nil)
        #expect(url?.absoluteString == "http://mac-studio.ts.net:7749")
    }

    @Test func webSocketURLValid() {
        let creds = ServerCredentials(host: "192.168.1.10", port: 7749, token: "sk_test", name: "Test")
        let url = creds.webSocketURL(sessionId: "abc-123", workspaceId: "w1")
        #expect(url != nil)
        #expect(url?.absoluteString == "ws://192.168.1.10:7749/workspaces/w1/sessions/abc-123/stream")
    }

    @Test func credentialsCodableRoundTrip() throws {
        let json = """
        {"host":"10.0.0.1","port":8080,"token":"sk_abc","name":"Dev"}
        """
        let original = try JSONDecoder().decode(ServerCredentials.self, from: json.data(using: .utf8)!)
        #expect(original.host == "10.0.0.1")
        #expect(original.port == 8080)
        #expect(original.token == "sk_abc")
        #expect(original.name == "Dev")

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerCredentials.self, from: encoded)
        #expect(original == decoded)
    }

    @Test func decodeLegacyCredentialPayloadDefaultsSecurityFields() throws {
        let json = """
        {"host":"legacy-host","port":7749,"token":"sk_legacy","name":"Legacy"}
        """

        let decoded = try JSONDecoder().decode(ServerCredentials.self, from: json.data(using: .utf8)!)

        #expect(decoded.serverFingerprint == nil)
        #expect(decoded.securityProfile == nil)
        #expect(decoded.inviteVersion == nil)
        #expect(decoded.inviteKeyId == nil)
        #expect(decoded.requireTlsOutsideTailnet == nil)
        #expect(decoded.allowInsecureHttpInTailnet == nil)
        #expect(decoded.requirePinnedServerIdentity == nil)
    }

    @Test func decodeCredentialPayloadWithSecurityFields() throws {
        let json = """
        {
            "host":"secure-host",
            "port":7749,
            "token":"sk_secure",
            "name":"Secure",
            "serverFingerprint":"sha256:abc123",
            "securityProfile":"host",
            "inviteVersion":2,
            "inviteKeyId":"srv-key-1",
            "requireTlsOutsideTailnet":true,
            "allowInsecureHttpInTailnet":false,
            "requirePinnedServerIdentity":true
        }
        """

        let decoded = try JSONDecoder().decode(ServerCredentials.self, from: json.data(using: .utf8)!)

        #expect(decoded.serverFingerprint == "sha256:abc123")
        #expect(decoded.securityProfile == "host")
        #expect(decoded.inviteVersion == 2)
        #expect(decoded.inviteKeyId == "srv-key-1")
        #expect(decoded.requireTlsOutsideTailnet == true)
        #expect(decoded.allowInsecureHttpInTailnet == false)
        #expect(decoded.requirePinnedServerIdentity == true)
    }
}

private struct InvitePayloadFixture: Codable {
    var host: String
    var port: Int
    var token: String
    var name: String
    var fingerprint: String
    var securityProfile: String
}

private struct InviteEnvelopeFixture: Codable {
    var v: Int
    var alg: String
    var kid: String
    var iat: Int
    var exp: Int
    var nonce: String
    var publicKey: String
    var payload: InvitePayloadFixture
    var sig: String
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@Suite("ServerCredentials Invite Security")
struct ServerCredentialsInviteSecurityTests {
    private func defaultPayload() -> InvitePayloadFixture {
        InvitePayloadFixture(
            host: "mac-studio.taila3ebc.ts.net",
            port: 7749,
            token: "sk_test_invite",
            name: "mac-studio",
            fingerprint: "sha256:test-fingerprint",
            securityProfile: "tailscale-permissive"
        )
    }

    private func buildSigningInput(_ envelope: InviteEnvelopeFixture) -> String {
        let p = envelope.payload
        return [
            "v=\(envelope.v)",
            "alg=\(envelope.alg)",
            "kid=\(envelope.kid)",
            "iat=\(envelope.iat)",
            "exp=\(envelope.exp)",
            "nonce=\(envelope.nonce)",
            "publicKey=\(envelope.publicKey)",
            "host=\(p.host)",
            "port=\(p.port)",
            "token=\(p.token)",
            "name=\(p.name)",
            "fingerprint=\(p.fingerprint)",
            "securityProfile=\(p.securityProfile)",
        ].joined(separator: "\n")
    }

    private func makeSignedEnvelope(
        iat: Int,
        exp: Int,
        payload: InvitePayloadFixture? = nil
    ) throws -> InviteEnvelopeFixture {
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = Data(signingKey.publicKey.rawRepresentation).base64URLEncodedString

        var envelope = InviteEnvelopeFixture(
            v: 2,
            alg: "Ed25519",
            kid: "srv-test",
            iat: iat,
            exp: exp,
            nonce: "nonce-123",
            publicKey: publicKey,
            payload: payload ?? defaultPayload(),
            sig: ""
        )

        let signingInput = buildSigningInput(envelope)
        let signature = try signingKey.signature(for: Data(signingInput.utf8))
        envelope.sig = signature.base64URLEncodedString
        return envelope
    }

    private func encodeEnvelope(_ envelope: InviteEnvelopeFixture) throws -> String {
        let data = try JSONEncoder().encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ServerCredentialsInviteSecurityTests", code: -1)
        }
        return json
    }

    @Test func decodeInvitePayloadAcceptsSignedV2Envelope() throws {
        let now = Int(Date().timeIntervalSince1970)
        let envelope = try makeSignedEnvelope(iat: now, exp: now + 600)

        let json = try encodeEnvelope(envelope)
        let creds = ServerCredentials.decodeInvitePayload(json)

        #expect(creds != nil)
        #expect(creds?.host == envelope.payload.host)
        #expect(creds?.port == envelope.payload.port)
        #expect(creds?.token == envelope.payload.token)
        #expect(creds?.inviteVersion == 2)
        #expect(creds?.inviteKeyId == envelope.kid)
        #expect(creds?.securityProfile == envelope.payload.securityProfile)
        #expect(creds?.normalizedServerFingerprint == envelope.payload.fingerprint)
    }

    @Test func decodeInviteURLAcceptsSignedV2DeepLink() throws {
        let now = Int(Date().timeIntervalSince1970)
        let envelope = try makeSignedEnvelope(iat: now, exp: now + 600)
        let inviteJSON = try encodeEnvelope(envelope)
        let inviteB64 = Data(inviteJSON.utf8).base64URLEncodedString

        let piConnectURL = try #require(URL(string: "pi://connect?v=2&invite=\(inviteB64)"))
        let oppiConnectURL = try #require(URL(string: "oppi://connect?v=2&invite=\(inviteB64)"))
        let oppiPairURL = try #require(URL(string: "oppi://pair?invite=\(inviteB64)"))

        let piConnectCreds = ServerCredentials.decodeInviteURL(piConnectURL)
        let oppiConnectCreds = ServerCredentials.decodeInviteURL(oppiConnectURL)
        let oppiPairCreds = ServerCredentials.decodeInviteURL(oppiPairURL)
        let decodedFromString = ServerCredentials.decodeInviteURLString("oppi://pair?invite=\(inviteB64)")

        #expect(piConnectCreds?.host == envelope.payload.host)
        #expect(oppiConnectCreds?.host == envelope.payload.host)
        #expect(oppiPairCreds?.host == envelope.payload.host)
        #expect(decodedFromString?.host == envelope.payload.host)
        #expect(piConnectCreds?.inviteVersion == 2)
        #expect(oppiConnectCreds?.inviteVersion == 2)
        #expect(oppiPairCreds?.inviteVersion == 2)
    }

    @Test func decodeInviteURLRejectsLegacyUnsignedDeepLink() throws {
        let legacyURL = try #require(
            URL(string: "pi://connect?host=mac-studio.taila3ebc.ts.net&port=7749&token=sk_legacy&name=legacy")
        )

        let creds = ServerCredentials.decodeInviteURL(legacyURL)
        #expect(creds == nil)
    }

    @Test func decodeInviteURLRejectsUnknownRoute() throws {
        let now = Int(Date().timeIntervalSince1970)
        let envelope = try makeSignedEnvelope(iat: now, exp: now + 600)
        let inviteJSON = try encodeEnvelope(envelope)
        let inviteB64 = Data(inviteJSON.utf8).base64URLEncodedString

        let unsupported = try #require(URL(string: "oppi://migrate?invite=\(inviteB64)"))
        let creds = ServerCredentials.decodeInviteURL(unsupported)
        #expect(creds == nil)
    }

    @Test func decodeInvitePayloadRejectsLegacyUnsignedPayload() {
        let legacy = """
        {
            "host": "mac-studio.taila3ebc.ts.net",
            "port": 7749,
            "token": "sk_legacy",
            "name": "legacy"
        }
        """

        let creds = ServerCredentials.decodeInvitePayload(legacy)
        #expect(creds == nil)
    }

    @Test func decodeInvitePayloadRejectsTamperedSignedEnvelope() throws {
        let now = Int(Date().timeIntervalSince1970)
        var envelope = try makeSignedEnvelope(iat: now, exp: now + 600)

        // Adversary mutates payload after signature is produced.
        envelope.payload.host = "evil.example.com"

        let json = try encodeEnvelope(envelope)
        let creds = ServerCredentials.decodeInvitePayload(json)

        #expect(creds == nil)
    }

    @Test func decodeInvitePayloadRejectsExpiredSignedEnvelope() throws {
        let now = Int(Date().timeIntervalSince1970)
        let envelope = try makeSignedEnvelope(iat: now - 600, exp: now - 1)

        let json = try encodeEnvelope(envelope)
        let creds = ServerCredentials.decodeInvitePayload(json)

        #expect(creds == nil)
    }

    @Test func decodeInvitePayloadRejectsFutureIssuedAtBeyondClockSkew() throws {
        let now = Int(Date().timeIntervalSince1970)
        let envelope = try makeSignedEnvelope(iat: now + 301, exp: now + 900)

        let json = try encodeEnvelope(envelope)
        let creds = ServerCredentials.decodeInvitePayload(json)

        #expect(creds == nil)
    }
}

// MARK: - Workspace Codable

@Suite("Workspace Codable")
struct WorkspaceCodableTests {

    @Test func decodeFullWorkspace() throws {
        let json = """
        {
            "id": "w1",
            "name": "Development",
            "description": "Dev workspace",
            "icon": "hammer",
            "runtime": "host",
            "skills": ["searxng", "fetch"],
            "policyPreset": "restricted",
            "systemPrompt": "You are helpful",
            "hostMount": "/Users/me/workspace",
            "memoryEnabled": true,
            "memoryNamespace": "dev",
            "extensionMode": "explicit",
            "extensions": ["memory", "todos"],
            "defaultModel": "claude-sonnet-4-20250514",
            "createdAt": 1700000000000,
            "updatedAt": 1700001000000
        }
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: json.data(using: .utf8)!)

        #expect(ws.id == "w1")
        #expect(ws.name == "Development")
        #expect(ws.description == "Dev workspace")
        #expect(ws.icon == "hammer")
        #expect(ws.runtime == "host")
        #expect(ws.skills == ["searxng", "fetch"])
        #expect(ws.policyPreset == "restricted")
        #expect(ws.systemPrompt == "You are helpful")
        #expect(ws.hostMount == "/Users/me/workspace")
        #expect(ws.memoryEnabled == true)
        #expect(ws.memoryNamespace == "dev")
        #expect(ws.extensions == ["memory", "todos"])
        #expect(ws.defaultModel == "claude-sonnet-4-20250514")
        #expect(ws.createdAt.timeIntervalSince1970 == 1700000000)
        #expect(ws.updatedAt.timeIntervalSince1970 == 1700001000)
    }

    @Test func decodeMinimalWorkspace() throws {
        let json = """
        {
            "id": "w2",
            "name": "Minimal",
            "skills": [],
            "createdAt": 1700000000000,
            "updatedAt": 1700000000000
        }
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: json.data(using: .utf8)!)

        #expect(ws.id == "w2")
        #expect(ws.description == nil)
        #expect(ws.icon == nil)
        #expect(ws.runtime == "container")
        #expect(ws.skills.isEmpty)
        #expect(ws.policyPreset == "container") // default
        #expect(ws.systemPrompt == nil)
        #expect(ws.hostMount == nil)
        #expect(ws.memoryEnabled == nil)
        #expect(ws.memoryNamespace == nil)
        #expect(ws.extensions == nil)
        #expect(ws.defaultModel == nil)
    }

    @Test func encodeDecodeRoundTrip() throws {
        let json = """
        {
            "id": "w3", "name": "RT",
            "description": "test", "icon": "star",
            "runtime": "host", "skills": ["fetch"], "policyPreset": "container",
            "systemPrompt": "prompt", "hostMount": "/work",
            "memoryEnabled": false, "memoryNamespace": "ns",
            "extensionMode": "explicit", "extensions": ["custom-ext"],
            "defaultModel": "model-1",
            "createdAt": 1700000000000, "updatedAt": 1700001000000
        }
        """
        let original = try JSONDecoder().decode(Workspace.self, from: json.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Workspace.self, from: encoded)
        #expect(original == decoded)
    }

    @Test func policyPresetDefaultsToContainer() throws {
        let json = """
        {
            "id": "w4", "name": "NoPolicyField",
            "skills": [], "createdAt": 0, "updatedAt": 0
        }
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: json.data(using: .utf8)!)
        #expect(ws.policyPreset == "container")
        #expect(ws.runtime == "container")
    }
}

// MARK: - TraceEvent Codable

@Suite("TraceEvent Codable")
struct TraceEventCodableTests {

    @Test func decodeUserEvent() throws {
        let json = """
        {"id":"e1","type":"user","timestamp":"2025-01-01T00:00:00Z","text":"hello"}
        """
        let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
        #expect(event.id == "e1")
        #expect(event.type == .user)
        #expect(event.text == "hello")
        #expect(event.tool == nil)
    }

    @Test func decodeAssistantEvent() throws {
        let json = """
        {"id":"e2","type":"assistant","timestamp":"2025-01-01T00:00:00Z","text":"world"}
        """
        let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
        #expect(event.type == .assistant)
        #expect(event.text == "world")
    }

    @Test func decodeToolCallEvent() throws {
        let json = """
        {
            "id":"e3","type":"toolCall","timestamp":"2025-01-01T00:00:00Z",
            "tool":"bash","args":{"command":"ls -la"}
        }
        """
        let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
        #expect(event.type == .toolCall)
        #expect(event.tool == "bash")
        #expect(event.args?["command"] == .string("ls -la"))
        #expect(event.text == nil)
    }

    @Test func decodeToolResultEvent() throws {
        let json = """
        {
            "id":"e4","type":"toolResult","timestamp":"2025-01-01T00:00:00Z",
            "output":"file.txt","toolCallId":"tc1","toolName":"bash","isError":false
        }
        """
        let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
        #expect(event.type == .toolResult)
        #expect(event.output == "file.txt")
        #expect(event.toolCallId == "tc1")
        #expect(event.toolName == "bash")
        #expect(event.isError == false)
    }

    @Test func decodeThinkingEvent() throws {
        let json = """
        {"id":"e5","type":"thinking","timestamp":"2025-01-01T00:00:00Z","thinking":"Let me consider..."}
        """
        let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
        #expect(event.type == .thinking)
        #expect(event.thinking == "Let me consider...")
    }

    @Test func decodeSystemEvent() throws {
        let json = """
        {"id":"e6","type":"system","timestamp":"2025-01-01T00:00:00Z","text":"Session started"}
        """
        let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
        #expect(event.type == .system)
    }

    @Test func decodeCompactionEvent() throws {
        let json = """
        {"id":"e7","type":"compaction","timestamp":"2025-01-01T00:00:00Z","text":"Context compacted"}
        """
        let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
        #expect(event.type == .compaction)
    }

    @Test func allEventTypes() throws {
        let types: [(String, TraceEventType)] = [
            ("user", .user),
            ("assistant", .assistant),
            ("toolCall", .toolCall),
            ("toolResult", .toolResult),
            ("thinking", .thinking),
            ("system", .system),
            ("compaction", .compaction),
        ]
        for (raw, expected) in types {
            let json = """
            {"id":"e","type":"\(raw)","timestamp":"t"}
            """
            let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
            #expect(event.type == expected)
        }
    }
}

// MARK: - SkillInfo Codable

@Suite("SkillInfo Codable")
struct SkillInfoCodableTests {

    @Test func decodeSkillInfo() throws {
        let json = """
        {
            "name": "searxng",
            "description": "Private web search",
            "containerSafe": true,
            "hasScripts": false,
            "path": "/Users/me/.pi/agent/skills/searxng"
        }
        """
        let skill = try JSONDecoder().decode(SkillInfo.self, from: json.data(using: .utf8)!)
        #expect(skill.name == "searxng")
        #expect(skill.description == "Private web search")
        #expect(skill.containerSafe == true)
        #expect(skill.hasScripts == false)
        #expect(skill.id == "searxng")
    }

    @Test func encodeDecodeRoundTrip() throws {
        let json = """
        {
            "name": "tmux",
            "description": "Terminal multiplexer",
            "containerSafe": false,
            "hasScripts": true,
            "path": "/path/to/tmux"
        }
        """
        let original = try JSONDecoder().decode(SkillInfo.self, from: json.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SkillInfo.self, from: encoded)
        #expect(original == decoded)
    }
}
