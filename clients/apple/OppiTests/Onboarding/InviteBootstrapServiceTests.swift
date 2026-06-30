import Testing
import Foundation
@testable import Oppi

@MainActor
@Suite("InviteBootstrapService")
struct InviteBootstrapServiceTests {
    private let host = "pairing.example.test"

    @Test func trustConfirmationPrecedesPairingTokenExchange() async throws {
        let log = InviteBootstrapCallLog()
        let bootstrapAPI = RecordingInviteBootstrapAPI(log: log, pairDeviceToken: "device-token")
        let authenticatedAPI = RecordingInviteBootstrapAPI(log: log)
        var apis: [RecordingInviteBootstrapAPI] = [bootstrapAPI, authenticatedAPI]
        var factoryTokens: [String] = []

        let credentials = ServerCredentials(
            host: host,
            port: 443,
            token: "invite-token",
            name: "Pairing Server",
            scheme: .https,
            pairingToken: "one-time-token",
            serverFingerprint: "sha256:abcdef1234567890"
        )

        let result = try await InviteBootstrapService.validateAndBootstrap(
            credentials: credentials,
            existingCredentials: nil,
            confirmTrust: { reason in
                await log.append("trust:\(reason)")
                return true
            },
            apiFactory: { _, token, _ in
                factoryTokens.append(token)
                return apis.removeFirst()
            }
        )

        let calls = await log.snapshot()
        #expect(calls == [
            "trust:Trust pairing.example.test (sha256:abcdef1234567890)",
            "pair:one-time-token",
            "health",
            "me",
            "listSessions:3"
        ])
        #expect(factoryTokens == ["invite-token", "device-token"])
        #expect(result.effectiveCredentials.token == "device-token")
    }

    @Test func cancelledTrustDoesNotExchangePairingToken() async throws {
        let log = InviteBootstrapCallLog()
        var factoryCalled = false
        let credentials = ServerCredentials(
            host: host,
            port: 443,
            token: "invite-token",
            name: "Pairing Server",
            scheme: .https,
            pairingToken: "one-time-token",
            serverFingerprint: "sha256:abcdef1234567890"
        )

        await #expect(throws: InviteBootstrapError.message("Trust confirmation cancelled")) {
            _ = try await InviteBootstrapService.validateAndBootstrap(
                credentials: credentials,
                existingCredentials: nil,
                confirmTrust: { reason in
                    await log.append("trust:\(reason)")
                    return false
                },
                apiFactory: { _, _, _ in
                    factoryCalled = true
                    return RecordingInviteBootstrapAPI(log: log)
                }
            )
        }

        #expect(await log.snapshot() == ["trust:Trust pairing.example.test (sha256:abcdef1234567890)"])
        #expect(factoryCalled == false)
    }

    @Test func decodesCredentialsFromInviteURL() throws {
        let payload = #"{"v":3,"host":"pairing.example.test","port":7749,"token":"invite-token","name":"Pairing Server"}"#
        let encodedPayload = try #require(payload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        let inviteURL = try #require(URL(string: "oppi://connect?v=3&payload=\(encodedPayload)"))

        let credentials = InviteBootstrapService.credentials(from: inviteURL)

        #expect(credentials?.host == host)
        #expect(credentials?.port == 7749)
        #expect(credentials?.token == "invite-token")
    }

    @Test func pairingFailureMessageForExpiredInvite() {
        let message = InviteBootstrapService.pairingFailureMessage(
            for: APIError.server(status: 401, message: "Invalid or expired pairing token"),
            host: host
        )

        #expect(message == "Invite link expired or was already used. Request a fresh invite.")
    }

    @Test func pairingFailureMessageForRateLimit() {
        let message = InviteBootstrapService.pairingFailureMessage(
            for: APIError.server(status: 429, message: "Too many invalid pairing attempts. Try again later."),
            host: host
        )

        #expect(message == "Too many invalid pairing attempts. Wait a moment, request a fresh invite, and try again.")
    }

    @Test func pairingFailureMessageForNetworkLookupFailure() {
        let message = InviteBootstrapService.pairingFailureMessage(
            for: URLError(.cannotFindHost),
            host: host
        )

        #expect(message == "Could not reach pairing.example.test. Check the address, VPN, or network and try again.")
    }

    @Test func pairingFailureMessageForTLSFailure() {
        let message = InviteBootstrapService.pairingFailureMessage(
            for: URLError(.serverCertificateUntrusted),
            host: host
        )

        #expect(message == "Secure connection to pairing.example.test failed. Verify the invite host and certificate, then try again.")
    }
}

@Suite("WhatsNewManager")
@MainActor
struct WhatsNewManagerTests {
    @Test func releaseIdentifierIncludesBuildNumber() {
        #expect(
            WhatsNewManager.releaseIdentifier(marketingVersion: "1.1.0", buildNumber: "40")
                == "1.1.0 (40)"
        )
        #expect(
            WhatsNewManager.releaseIdentifier(marketingVersion: "1.1.0", buildNumber: "")
                == "1.1.0"
        )
    }

    @Test func markSeenSuppressesPromptForCurrentVersion() {
        let key = "\(AppIdentifiers.subsystem).whatsNew.lastSeenVersion"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(WhatsNewManager.shouldShow)

        WhatsNewManager.markSeen()

        #expect(!WhatsNewManager.shouldShow)
    }
}

private actor InviteBootstrapCallLog {
    private var calls: [String] = []

    func append(_ call: String) {
        calls.append(call)
    }

    func snapshot() -> [String] {
        calls
    }
}

private actor RecordingInviteBootstrapAPI: InviteBootstrapAPI {
    private let log: InviteBootstrapCallLog
    private let pairDeviceToken: String

    init(log: InviteBootstrapCallLog, pairDeviceToken: String = "device-token") {
        self.log = log
        self.pairDeviceToken = pairDeviceToken
    }

    func pairDevice(pairingToken: String, deviceName: String?) async throws -> PairDeviceResponse {
        await log.append("pair:\(pairingToken)")
        return PairDeviceResponse(deviceToken: pairDeviceToken)
    }

    func health() async throws -> Bool {
        await log.append("health")
        return true
    }

    func me() async throws -> User {
        await log.append("me")
        return User(user: "test-user", name: "Test User")
    }

    func listSessionsFromWorkspaces(recentDays: Int) async throws -> [Session] {
        await log.append("listSessions:\(recentDays)")
        return []
    }
}
