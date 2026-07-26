import CryptoKit
import Testing
import Foundation
@testable import Oppi

// swiftlint:disable force_unwrapping

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
            "lastAgentReplyAt": 1700003500000,
            "model": "claude-sonnet-4-20250514",
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
        #expect(session.lastAgentReplyAt?.timeIntervalSince1970 == 1700003500)
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
        #expect(session.contextTokens == nil)
        #expect(session.contextWindow == nil)
        #expect(session.lastMessage == nil)
        #expect(session.tokens.cacheRead == nil)
        #expect(session.tokens.cacheWrite == nil)
    }

    @Test func decodeSessionTokenUsageCacheFields() throws {
        let json = """
        {
            "id": "s-cache",
            "status": "ready",
            "createdAt": 1700000000000,
            "lastActivity": 1700000000000,
            "messageCount": 0,
            "tokens": {
                "input": 120,
                "output": 45,
                "cacheRead": 30,
                "cacheWrite": 12
            },
            "cost": 0
        }
        """
        let session = try JSONDecoder().decode(Session.self, from: json.data(using: .utf8)!)

        #expect(session.tokens.input == 120)
        #expect(session.tokens.output == 45)
        #expect(session.tokens.cacheRead == 30)
        #expect(session.tokens.cacheWrite == 12)
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
            "lastAgentReplyAt": 1700000900000,
            "model": "claude-sonnet-4-20250514",
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

// MARK: - Provider Auth Codable

@Suite("ProviderAuth Codable")
struct ProviderAuthCodableTests {

    @Test func decodeProviderStatus() throws {
        let json = """
        {
            "id": "openai-codex",
            "name": "ChatGPT (Codex)",
            "supportsApiKey": false,
            "oauth": {
                "flowType": "oauth_callback",
                "supportsServerBrowserLaunch": true,
                "supportsPhoneBrowserLaunch": true,
                "supportsManualCodeInput": true,
                "mayPromptForInput": true
            },
            "authenticated": true,
            "credentialType": "oauth",
            "expiresAt": 1700003600000
        }
        """

        let status = try JSONDecoder().decode(
            ProviderAuthProviderStatus.self,
            from: json.data(using: .utf8)!
        )

        #expect(status.id == "openai-codex")
        #expect(status.oauth?.flowType == .oauthCallback)
        #expect(status.authenticated)
        #expect(status.credentialType == .oauth)
        #expect(status.expiresAtDate?.timeIntervalSince1970 == 1700003600)
    }

    @Test func decodeFlowSnapshot() throws {
        let json = """
        {
            "flowId": "pa_123",
            "providerId": "openai-codex",
            "flowType": "oauth_callback",
            "launchMode": "server_browser",
            "status": "awaiting_manual_code",
            "auth": {
                "url": "https://auth.openai.com/oauth/authorize?foo=bar",
                "instructions": "Complete sign-in in browser"
            },
            "prompt": null,
            "lastProgress": "waiting",
            "error": null,
            "createdAt": 1700000000000,
            "updatedAt": 1700000100000,
            "expiresAt": 1700000600000
        }
        """

        let flow = try JSONDecoder().decode(
            ProviderAuthFlowSnapshot.self,
            from: json.data(using: .utf8)!
        )

        #expect(flow.id == "pa_123")
        #expect(flow.flowType == .oauthCallback)
        #expect(flow.launchMode == .serverBrowser)
        #expect(flow.status == .awaitingManualCode)
        #expect(flow.auth?.url == "https://auth.openai.com/oauth/authorize?foo=bar")
        #expect(flow.status.isTerminal == false)
    }
}

// MARK: - User + ServerCredentials

@Suite("User Codable")
struct UserCodableTests {

    @Test func decodeUser() throws {
        let json = """
        {"user": "u1", "name": "Test User"}
        """
        let user = try JSONDecoder().decode(User.self, from: json.data(using: .utf8)!)
        #expect(user.user == "u1")
        #expect(user.name == "Test User")
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

    @Test func baseURLDefaultsToHTTPS() {
        let creds = ServerCredentials(host: "192.168.1.10", port: 7749, token: "sk_test", name: "Test")
        let url = creds.baseURL
        #expect(url != nil)
        #expect(url?.absoluteString == "https://192.168.1.10:7749")
    }

    @Test func baseURLWithHostnameDefaultsToHTTPS() {
        let creds = ServerCredentials(host: "my-server.ts.net", port: 7749, token: "sk_test", name: "Test")
        let url = creds.baseURL
        #expect(url != nil)
        #expect(url?.absoluteString == "https://my-server.ts.net:7749")
    }

    @Test func httpSchemeRequiresExplicitOptIn() {
        let creds = ServerCredentials(
            host: "192.168.1.10",
            port: 7749,
            token: "sk_test",
            name: "Test",
            scheme: .http
        )
        let url = creds.baseURL
        #expect(url != nil)
        #expect(url?.absoluteString == "http://192.168.1.10:7749")
    }

    @Test func httpsSchemeProducesHttpsAndWssURLs() {
        let creds = ServerCredentials(
            host: "tls.local",
            port: 7749,
            token: "sk_test",
            name: "TLS",
            scheme: .https,
            tlsCertFingerprint: "sha256:testleaf"
        )

        #expect(creds.baseURL?.absoluteString == "https://tls.local:7749")
        #expect(creds.normalizedTLSCertFingerprint == "sha256:testleaf")
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

    @Test func decodeCredentialPayloadWithFingerprint() throws {
        let json = """
        {
            "host":"secure-host",
            "port":7749,
            "token":"sk_secure",
            "name":"Secure",
            "serverFingerprint":"sha256:abc123"
        }
        """

        let decoded = try JSONDecoder().decode(ServerCredentials.self, from: json.data(using: .utf8)!)

        #expect(decoded.serverFingerprint == "sha256:abc123")
    }
}

private struct SignedInviteEnvelopeV3Fixture: Codable {
    var v: Int
    var signedPayload: String
    var publicKey: String
    var signature: String
}

private struct InvitePayloadV3Fixture: Codable {
    var v: Int
    var host: String
    var port: Int
    var scheme: String?
    var token: String
    var pairingToken: String?
    var name: String
    var tlsCertFingerprint: String?
    var fingerprint: String?
}

private struct SignedInviteEnvelopeV4Fixture: Codable {
    var v: Int
    var alg: String
    var signedPayload: String
    var publicKey: String
    var signature: String
}

private struct InvitePayloadV4Fixture: Codable {
    var v: Int
    var name: String
    var pairingToken: String
    var fingerprint: String
    var preference: String
    var transports: InviteTransportsV4Fixture
}

private struct InviteTransportsV4Fixture: Codable {
    var iroh: IrohInviteTransportV4Fixture?
    var http: HTTPInviteTransportV4Fixture?
}

private struct IrohInviteTransportV4Fixture: Codable {
    var version: Int
    var nodeId: String
    var alpns: [String]
    var addressMode: String
    var ticket: String?
}

private struct HTTPInviteTransportV4Fixture: Codable {
    var host: String
    var port: Int
    var scheme: String
    var tlsCertFingerprint: String?
}

private struct SignedInviteV4Fixture {
    var url: URL
    var envelope: SignedInviteEnvelopeV4Fixture
    var payload: InvitePayloadV4Fixture
    var fingerprint: String
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
    private func defaultPayloadV3() -> InvitePayloadV3Fixture {
        InvitePayloadV3Fixture(
            v: 3,
            host: "my-server.tail12345.ts.net",
            port: 7749,
            scheme: "https",
            token: "",
            pairingToken: "pt_test_invite",
            name: "my-server",
            tlsCertFingerprint: "sha256:test-leaf",
            fingerprint: "sha256:test-fingerprint"
        )
    }

    private func defaultPayloadV4() -> InvitePayloadV4Fixture {
        InvitePayloadV4Fixture(
            v: 4,
            name: "host-free-mac",
            pairingToken: "pt_v4_invite",
            fingerprint: "sha256:test-fingerprint",
            preference: "irohOnly",
            transports: InviteTransportsV4Fixture(
                iroh: IrohInviteTransportV4Fixture(
                    version: 2,
                    nodeId: "iroh-node-v4",
                    alpns: ["oppi/pair/1", "oppi/http/1"],
                    addressMode: "node-id",
                    ticket: nil
                ),
                http: nil
            )
        )
    }

    private func makeSignedV4Invite(payload: InvitePayloadV4Fixture? = nil) throws -> SignedInviteV4Fixture {
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation
        let fingerprint = "sha256:\(Data(SHA256.hash(data: publicKey)).base64URLEncodedString)"
        var signedPayload = payload ?? defaultPayloadV4()
        signedPayload.fingerprint = fingerprint
        let signedPayloadData = try JSONEncoder().encode(signedPayload)
        let signedPayloadString = signedPayloadData.base64URLEncodedString
        let signature = try signingKey.signature(for: Data(signedPayloadString.utf8))
        let envelope = SignedInviteEnvelopeV4Fixture(
            v: 4,
            alg: "ed25519",
            signedPayload: signedPayloadString,
            publicKey: publicKey.base64URLEncodedString,
            signature: signature.base64URLEncodedString
        )
        let envelopeData = try JSONEncoder().encode(envelope)
        let invite = envelopeData.base64URLEncodedString
        let url = try #require(URL(string: "oppi://connect?v=4&invite=\(invite)"))
        return SignedInviteV4Fixture(
            url: url,
            envelope: envelope,
            payload: signedPayload,
            fingerprint: fingerprint
        )
    }

    @Test func decodeInvitePayloadRejectsUnsignedV3PayloadWithPins() throws {
        let payload = defaultPayloadV3()
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))

        let creds = ServerCredentials.decodeInvitePayload(json)

        #expect(creds == nil)
    }

    @Test func decodeInvitePayloadAcceptsSignedV3PayloadWithPins() throws {
        let payload = defaultPayloadV3()
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation
        let fingerprint = "sha256:\(Data(SHA256.hash(data: publicKey)).base64URLEncodedString)"
        var signedPayload = payload
        signedPayload.fingerprint = fingerprint
        let signedData = try JSONEncoder().encode(signedPayload)
        let signature = try signingKey.signature(for: signedData)
        let envelope = SignedInviteEnvelopeV3Fixture(
            v: 3,
            signedPayload: signedData.base64URLEncodedString,
            publicKey: publicKey.base64URLEncodedString,
            signature: signature.base64URLEncodedString
        )
        let envelopeData = try JSONEncoder().encode(envelope)
        let envelopeJson = try #require(String(data: envelopeData, encoding: .utf8))

        let creds = ServerCredentials.decodeInvitePayload(envelopeJson)

        #expect(creds?.host == payload.host)
        #expect(creds?.port == payload.port)
        #expect(creds?.resolvedScheme == .https)
        #expect(creds?.pairingToken == payload.pairingToken)
        #expect(creds?.normalizedTLSCertFingerprint == payload.tlsCertFingerprint)
        #expect(creds?.normalizedServerFingerprint == fingerprint)
    }

    @Test func decodeInvitePayloadDefaultsSchemeToHttpsWhenMissing() throws {
        var payload = defaultPayloadV3()
        payload.scheme = nil
        payload.tlsCertFingerprint = nil
        payload.fingerprint = nil

        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))

        let creds = ServerCredentials.decodeInvitePayload(json)
        #expect(creds?.resolvedScheme == .https)
    }

    @Test func decodeInviteURLAcceptsSignedV4IrohOnlyWithoutHTTPTransport() throws {
        let fixture = try makeSignedV4Invite()

        let creds = ServerCredentials.decodeInviteURL(fixture.url)

        #expect(creds?.name == "host-free-mac")
        #expect(creds?.pairingToken == "pt_v4_invite")
        #expect(creds?.normalizedServerFingerprint == fixture.fingerprint)
        #expect(creds?.transports.preference == .irohOnly)
        #expect(creds?.transports.http == nil)
        #expect(creds?.transports.iroh?.version == 2)
        #expect(creds?.transports.iroh?.nodeId == "iroh-node-v4")
        #expect(creds?.transports.iroh?.alpns == ["oppi/pair/1", "oppi/http/1"])
        #expect(creds?.transports.iroh?.addressMode == .nodeId)
        #expect(creds?.transports.iroh?.ticket == nil)
        #expect(creds?.baseURL == nil)
    }

    @Test func decodeInviteURLRejectsV4SignedPayloadTampering() throws {
        let fixture = try makeSignedV4Invite()
        var tamperedPayload = fixture.payload
        tamperedPayload.transports.iroh?.nodeId = "iroh-node-tampered"
        let tamperedPayloadData = try JSONEncoder().encode(tamperedPayload)
        var tamperedEnvelope = fixture.envelope
        tamperedEnvelope.signedPayload = tamperedPayloadData.base64URLEncodedString
        let tamperedEnvelopeData = try JSONEncoder().encode(tamperedEnvelope)
        let tamperedInvite = tamperedEnvelopeData.base64URLEncodedString
        let tamperedURL = try #require(URL(string: "oppi://connect?v=4&invite=\(tamperedInvite)"))

        let creds = ServerCredentials.decodeInviteURL(tamperedURL)

        #expect(creds == nil)
    }

    @Test func decodeInviteURLRejectsUnsignedV3DeepLinkWithPins() throws {
        let payload = defaultPayloadV3()
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        let inviteB64 = Data(json.utf8).base64URLEncodedString

        let connectURL = try #require(URL(string: "oppi://connect?v=3&invite=\(inviteB64)"))
        let pairURL = try #require(URL(string: "oppi://pair?v=3&invite=\(inviteB64)"))

        let connectCreds = ServerCredentials.decodeInviteURL(connectURL)
        let pairCreds = ServerCredentials.decodeInviteURL(pairURL)

        #expect(connectCreds == nil)
        #expect(pairCreds == nil)
    }

    @Test func decodeInviteURLRejectsUnsupportedVersion() throws {
        let payload = defaultPayloadV3()
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        let inviteB64 = Data(json.utf8).base64URLEncodedString

        let unsupported = try #require(URL(string: "oppi://connect?v=2&invite=\(inviteB64)"))
        let creds = ServerCredentials.decodeInviteURL(unsupported)

        #expect(creds == nil)
    }

    @Test func decodeInviteURLRejectsUnknownRoute() throws {
        let payload = defaultPayloadV3()
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        let inviteB64 = Data(json.utf8).base64URLEncodedString

        let unsupported = try #require(URL(string: "oppi://migrate?invite=\(inviteB64)"))
        let creds = ServerCredentials.decodeInviteURL(unsupported)
        #expect(creds == nil)
    }

    @Test func decodeInvitePayloadRejectsUnsignedPayload() {
        let unsigned = """
        {
            "host": "my-server.tail12345.ts.net",
            "port": 7749,
            "token": "sk_test_unsigned",
            "name": "unsigned"
        }
        """

        let creds = ServerCredentials.decodeInvitePayload(unsigned)
        #expect(creds == nil)
    }
}

// MARK: - IconChoice Codable

@Suite("IconChoice Codable")
struct IconChoiceCodableTests {
    @Test func roundTripsEveryTaggedCase() throws {
        let assetId = "ia_" + String(repeating: "A", count: 43)
        let choices: [IconChoice] = [
            .defaultValue,
            .emoji("🧘"),
            .symbol("checkmark.shield"),
            .genmoji(assetId: assetId, contentDescription: "A smiling fox"),
        ]

        for choice in choices {
            let encoded = try JSONEncoder().encode(choice)
            let decoded = try JSONDecoder().decode(IconChoice.self, from: encoded)
            #expect(decoded == choice)
        }
    }

    @Test func malformedAndUnknownCasesDecodeAsDefault() throws {
        let payloads = [
            #"{"kind":"future","payload":"ignored"}"#,
            #"{"kind":"emoji","value":"not emoji"}"#,
            #"{"kind":"symbol","name":"not/a/symbol"}"#,
            #"{"kind":"genmoji","assetId":"../../etc/passwd","contentDescription":"bad"}"#,
            #"{"kind":"genmoji","assetId":"ia_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","contentDescription":"   "}"#,
            #""historical-string""#,
            #"null"#,
        ]

        for payload in payloads {
            let decoded = try JSONDecoder().decode(IconChoice.self, from: Data(payload.utf8))
            #expect(decoded == .defaultValue)
        }
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
            "icon": {"kind":"symbol","name":"hammer"},
            "skills": ["searxng", "fetch"],
            "systemPrompt": "You are helpful",
            "systemPromptMode": "append",
            "hostMount": "/Users/me/workspace",
            "extensionMode": "explicit",
            "extensions": ["memory", "todos"],
            "createdAt": 1700000000000,
            "updatedAt": 1700001000000
        }
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: json.data(using: .utf8)!)

        #expect(ws.id == "w1")
        #expect(ws.name == "Development")
        #expect(ws.description == "Dev workspace")
        #expect(ws.icon == .symbol("hammer"))
        #expect(ws.systemPrompt == "You are helpful")
        #expect(ws.systemPromptMode == .append)
        #expect(ws.hostMount == "/Users/me/workspace")
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
        #expect(ws.icon == .defaultValue)
        #expect(ws.systemPrompt == nil)
        #expect(ws.systemPromptMode == .append)
        #expect(ws.hostMount == nil)
    }

    @Test func encodeDecodeRoundTrip() throws {
        let json = """
        {
            "id": "w3", "name": "RT",
            "description": "test", "icon": {"kind":"symbol","name":"star"},
            "skills": ["fetch"],
            "systemPrompt": "prompt", "systemPromptMode": "append", "hostMount": "/work",
            "extensionMode": "explicit", "extensions": ["custom-ext"],
            "createdAt": 1700000000000, "updatedAt": 1700001000000
        }
        """
        let original = try JSONDecoder().decode(Workspace.self, from: json.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(original)
        let encodedObject = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(encodedObject["skills"] == nil)
        #expect(encodedObject["extensions"] == nil)
        let decoded = try JSONDecoder().decode(Workspace.self, from: encoded)
        #expect(original == decoded)
    }

    @Test func decodeWorkspaceWithoutRuntimeField() throws {
        let json = """
        {
            "id": "w4", "name": "NoRuntimeField",
            "skills": [], "createdAt": 0, "updatedAt": 0
        }
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: json.data(using: .utf8)!)
        #expect(ws.id == "w4")
        #expect(ws.name == "NoRuntimeField")
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
            "tool":"bash","args":{"command":"ls -la"},
            "callSegments":[{"text":"$ ","style":"bold"},{"text":"ls -la","style":"accent"}]
        }
        """
        let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
        #expect(event.type == .toolCall)
        #expect(event.tool == "bash")
        #expect(event.args?["command"] == .string("ls -la"))
        #expect(event.callSegments?.map(\.text) == ["$ ", "ls -la"])
        #expect(event.text == nil)
    }

    @Test func decodeToolResultEvent() throws {
        let json = """
        {
            "id":"e4","type":"toolResult","timestamp":"2025-01-01T00:00:00Z",
            "output":"file.txt","toolCallId":"tc1","toolName":"bash","isError":false,
            "resultSegments":[{"text":"done","style":"success"}]
        }
        """
        let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
        #expect(event.type == .toolResult)
        #expect(event.output == "file.txt")
        #expect(event.toolCallId == "tc1")
        #expect(event.toolName == "bash")
        #expect(event.isError == false)
        #expect(event.resultSegments?.map(\.text) == ["done"])
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

    @Test func decodeCompatibleLifecycleMetadata() throws {
        let json = """
        {
            "id":"result-1","type":"toolResult","timestamp":"2025-01-01T00:00:03Z",
            "output":"done","toolCallId":"tc1","toolName":"bash","isError":false,
            "lifecycleBefore":[
                {"id":"start-1","event":"toolStart","timestamp":"2025-01-01T00:00:01Z","toolCallId":"tc1","toolName":"bash"},
                {"id":"end-1","event":"toolEnd","timestamp":"2025-01-01T00:00:03Z","toolCallId":"tc1","toolName":"bash","isError":false}
            ]
        }
        """
        let event = try JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)

        #expect(event.type == .toolResult)
        #expect(event.lifecycleBefore?.map(\.event) == [.toolStart, .toolEnd])
        #expect(event.lifecycleBefore?.allSatisfy { $0.toolCallId == "tc1" } == true)
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
            "path": "/Users/me/.pi/agent/skills/searxng"
        }
        """
        let skill = try JSONDecoder().decode(SkillInfo.self, from: json.data(using: .utf8)!)
        #expect(skill.name == "searxng")
        #expect(skill.description == "Private web search")
        #expect(skill.builtIn == true)
        #expect(skill.id == "searxng")
    }

    @Test func encodeDecodeRoundTrip() throws {
        let json = """
        {
            "name": "tmux",
            "description": "Terminal multiplexer",
            "path": "/path/to/tmux",
            "builtIn": false
        }
        """
        let original = try JSONDecoder().decode(SkillInfo.self, from: json.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SkillInfo.self, from: encoded)
        #expect(original == decoded)
    }
}
