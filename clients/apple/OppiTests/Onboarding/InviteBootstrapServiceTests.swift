import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("InviteBootstrapService")
struct InviteBootstrapServiceTests {
    private let host = "pairing.example.test"

    @Test func trustConfirmationPrecedesHTTPSPairingMutation() async throws {
        let log = InviteBootstrapCallLog()
        let pairingAPI = RecordingInviteBootstrapAPI(log: log, accessToken: "at_paired")
        let authenticatedAPI = RecordingInviteBootstrapAPI(log: log)
        var apis = [pairingAPI, authenticatedAPI]
        var factoryTokens: [String] = []

        let result = try await InviteBootstrapService.validateAndBootstrap(
            credentials: credentials(),
            existingCredentials: nil,
            confirmTrust: { reason in
                await log.append("trust:\(reason)")
                return true
            },
            apiFactory: { _, token, _ in
                factoryTokens.append(token)
                return apis.removeFirst()
            },
            deviceKeyProvider: { InMemoryP256DeviceKey() }
        )

        #expect(await log.snapshot() == [
            "trust:Trust pairing.example.test (sha256:abcdef1234567890)",
            "pair:one-time-token",
            "health",
            "me",
            "listSessions:3",
        ])
        #expect(factoryTokens == ["", "at_paired"])
        #expect(result.effectiveCredentials.token.isEmpty)
        #expect(result.effectiveCredentials.deviceCredential?.accessToken == "at_paired")
    }

    @Test func olderServerPairingResponseKeepsTheIssuedDeviceToken() async throws {
        let log = InviteBootstrapCallLog()
        let pairingAPI = RecordingInviteBootstrapAPI(log: log, deviceToken: "dt_old_server")
        let authenticatedAPI = RecordingInviteBootstrapAPI(log: log)
        var apis = [pairingAPI, authenticatedAPI]
        var factoryTokens: [String] = []

        let result = try await InviteBootstrapService.validateAndBootstrap(
            credentials: credentials(),
            existingCredentials: nil,
            confirmTrust: { _ in true },
            apiFactory: { _, token, _ in
                factoryTokens.append(token)
                return apis.removeFirst()
            },
            deviceKeyProvider: { InMemoryP256DeviceKey() }
        )

        #expect(factoryTokens == ["", "dt_old_server"])
        #expect(result.effectiveCredentials.token == "dt_old_server")
        #expect(result.effectiveCredentials.deviceCredential == nil)
    }

    @Test func cancelledTrustDoesNotProbeOrExchangePairingToken() async throws {
        let log = InviteBootstrapCallLog()
        var factoryCalled = false

        await #expect(throws: InviteBootstrapError.message("Trust confirmation cancelled")) {
            _ = try await InviteBootstrapService.validateAndBootstrap(
                credentials: credentials(),
                existingCredentials: nil,
                confirmTrust: { _ in false },
                apiFactory: { _, _, _ in
                    factoryCalled = true
                    return RecordingInviteBootstrapAPI(log: log)
                }
            )
        }

        #expect(!factoryCalled)
        #expect(await log.snapshot().isEmpty)
    }

    @Test func lostHTTPSPairingResponseIsNotReplayed() async throws {
        let log = InviteBootstrapCallLog()
        let failing = FailingInviteBootstrapAPI(log: log, error: URLError(.networkConnectionLost))
        var factoryCalls = 0

        await #expect(throws: InviteBootstrapError.message(
            "Pairing may have completed, but its response was lost. Open Oppi to check, or request a fresh invite before trying again."
        )) {
            _ = try await InviteBootstrapService.validateAndBootstrap(
                credentials: credentials(),
                existingCredentials: nil,
                confirmTrust: { _ in true },
                apiFactory: { _, _, _ in
                    factoryCalls += 1
                    return failing
                },
                    deviceKeyProvider: { InMemoryP256DeviceKey() }
            )
        }

        #expect(factoryCalls == 1)
        #expect(await log.snapshot() == ["pair:one-time-token"])
    }

    @Test func TLSFailureMessageRemainsActionable() {
        #expect(InviteBootstrapService.pairingFailureMessage(
            for: URLError(.serverCertificateUntrusted),
            host: host
        ) == "Secure connection to pairing.example.test failed. Verify the invite host and certificate, then try again.")
    }

    @Test func decodesCredentialsFromInviteURL() throws {
        let payload = #"{"v":3,"host":"pairing.example.test","port":7749,"token":"invite-token","name":"Pairing Server"}"#
        let encoded = try #require(payload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        let inviteURL = try #require(URL(string: "oppi://connect?v=3&payload=\(encoded)"))
        let decoded = InviteBootstrapService.credentials(from: inviteURL)

        #expect(decoded?.host == host)
        #expect(decoded?.resolvedScheme == .https)
        #expect(decoded?.token == "invite-token")
    }

    private func credentials() -> ServerCredentials {
        ServerCredentials(
            host: host,
            port: 443,
            token: "",
            name: "Pairing Server",
            scheme: .https,
            pairingToken: "one-time-token",
            serverFingerprint: "sha256:abcdef1234567890"
        )
    }
}

@MainActor
@Suite("WhatsNewManager")
struct WhatsNewManagerTests {
    @Test func releaseIdentifierIncludesBuildNumber() {
        #expect(WhatsNewManager.releaseIdentifier(marketingVersion: "1.1.0", buildNumber: "40") == "1.1.0 (40)")
        #expect(WhatsNewManager.releaseIdentifier(marketingVersion: "1.1.0", buildNumber: "") == "1.1.0")
    }
}

private actor InviteBootstrapCallLog {
    private var calls: [String] = []
    func append(_ call: String) { calls.append(call) }
    func snapshot() -> [String] { calls }
}

private actor RecordingInviteBootstrapAPI: InviteBootstrapAPI {
    private let log: InviteBootstrapCallLog
    private let accessToken: String
    private let deviceToken: String?

    init(
        log: InviteBootstrapCallLog,
        accessToken: String = "at_current",
        deviceToken: String? = nil
    ) {
        self.log = log
        self.accessToken = accessToken
        self.deviceToken = deviceToken
    }

    func pairDevice(
        pairingToken: String,
        deviceName _: String?,
        devicePublicKey: DevicePublicKey
    ) async throws -> PairDeviceResponse {
        await log.append("pair:\(pairingToken)")
        #expect(devicePublicKey.kty == "EC")
        #expect(devicePublicKey.crv == "P-256")
        if let deviceToken {
            return PairDeviceResponse(
                deviceId: "",
                accessToken: "",
                expiresAt: 0,
                deviceToken: deviceToken
            )
        }
        return PairDeviceResponse(
            deviceId: "dev_https",
            accessToken: accessToken,
            expiresAt: 4_102_444_800_000,
            refreshChallenge: DeviceAuthChallenge(
                nonce: "next",
                audience: DeviceAuthSession.refreshAudience,
                expiresAt: 4_102_444_800_000
            )
        )
    }

    func health() async throws -> Bool {
        await log.append("health")
        return true
    }

    func me() async throws -> User {
        await log.append("me")
        return User(user: "owner", name: "Owner")
    }

    func listSessionsFromWorkspaces(recentDays: Int) async throws -> [Session] {
        await log.append("listSessions:\(recentDays)")
        return []
    }
}

private actor FailingInviteBootstrapAPI: InviteBootstrapAPI {
    private let log: InviteBootstrapCallLog
    private let error: Error

    init(log: InviteBootstrapCallLog, error: Error) {
        self.log = log
        self.error = error
    }

    func pairDevice(
        pairingToken: String,
        deviceName _: String?,
        devicePublicKey _: DevicePublicKey
    ) async throws -> PairDeviceResponse {
        await log.append("pair:\(pairingToken)")
        throw error
    }

    func health() async throws -> Bool { throw error }
    func me() async throws -> User { throw error }
    func listSessionsFromWorkspaces(recentDays _: Int) async throws -> [Session] { throw error }
}
