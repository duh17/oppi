import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("E2E app auth bootstrap")
struct E2EAppAuthBootstrapTests {
    private let fingerprint = "sha256:e2e-server-fingerprint"

    @Test func relaunchPreservesMatchingDeviceAuthPairing() throws {
        let invite = inviteCredentials()
        let server = try #require(PairedServer(from: invite.withDeviceCredential(deviceCredential())))

        #expect(E2EAppAuthBootstrap.shouldPreserveServer(server, matching: invite))
        #expect(E2EAppAuthBootstrap.shouldReuseExistingPairing(
            existing: server.credentials,
            invite: invite
        ))
    }

    @Test func relaunchDropsStaticTokenPairingWithoutDeviceCredential() throws {
        let invite = inviteCredentials()
        let staticCreds = invite.withAuthToken("at_script")
        let server = try #require(PairedServer(from: staticCreds))

        #expect(!E2EAppAuthBootstrap.shouldPreserveServer(server, matching: invite))
        #expect(!E2EAppAuthBootstrap.shouldReuseExistingPairing(
            existing: staticCreds,
            invite: invite
        ))
    }

    @Test func relaunchDropsADifferentServerFingerprint() throws {
        let invite = inviteCredentials()
        let other = ServerCredentials(
            host: invite.host,
            port: invite.port,
            token: "",
            name: invite.name,
            scheme: .http,
            pairingToken: invite.pairingToken,
            serverFingerprint: "sha256:other-server",
            deviceCredential: deviceCredential()
        )
        let server = try #require(PairedServer(from: other))

        #expect(!E2EAppAuthBootstrap.shouldPreserveServer(server, matching: invite))
        #expect(!E2EAppAuthBootstrap.shouldReuseExistingPairing(
            existing: other,
            invite: invite
        ))
    }

    @Test func httpPairingStoresDeviceCredentialInsteadOfAStaticToken() async throws {
        let log = E2EAppAuthBootstrapCallLog()
        let pairingAPI = E2EAppAuthRecordingAPI(log: log, accessToken: "at_paired")
        let authenticatedAPI = E2EAppAuthRecordingAPI(log: log)
        var apis = [pairingAPI, authenticatedAPI]
        var factoryTokens: [String] = []

        let result = try await E2EAppAuthBootstrap.pairInvite(
            credentials: inviteCredentials(),
            deviceKeyProvider: { InMemoryP256DeviceKey() },
            apiFactory: { _, token, _ in
                factoryTokens.append(token)
                return apis.removeFirst()
            }
        )

        #expect(await log.snapshot() == ["pair:pt_e2e", "listSessions:3"])
        #expect(factoryTokens == ["", "at_paired"])
        #expect(result.effectiveCredentials.token.isEmpty)
        #expect(result.effectiveCredentials.deviceCredential?.accessToken == "at_paired")
        #expect(result.effectiveCredentials.deviceCredential?.deviceId == "dev_e2e")
        #expect(result.effectiveCredentials.pairingToken == nil)
    }

    @Test func httpPairingRejectsADeviceTokenOnlyResponse() async throws {
        let log = E2EAppAuthBootstrapCallLog()
        let pairingAPI = E2EAppAuthRecordingAPI(log: log, deviceToken: "dt_old_server")

        await #expect(throws: InviteBootstrapError.message(
            "Server returned an invalid pairing response. Request a fresh invite and try again."
        )) {
            _ = try await E2EAppAuthBootstrap.pairInvite(
                credentials: inviteCredentials(),
                deviceKeyProvider: { InMemoryP256DeviceKey() },
                apiFactory: { _, _, _ in pairingAPI }
            )
        }

        #expect(await log.snapshot() == ["pair:pt_e2e"])
    }

    private func inviteCredentials() -> ServerCredentials {
        ServerCredentials(
            host: "127.0.0.1",
            port: 17760,
            token: "",
            name: "E2E Server",
            scheme: .http,
            pairingToken: "pt_e2e",
            serverFingerprint: fingerprint
        )
    }

    private func deviceCredential() -> DeviceCredential {
        DeviceCredential(
            deviceId: "dev_e2e",
            accessToken: "at_app",
            expiresAt: 4_102_444_800_000,
            refreshChallenge: nil
        )
    }
}

private actor E2EAppAuthBootstrapCallLog {
    private var calls: [String] = []
    func append(_ call: String) { calls.append(call) }
    func snapshot() -> [String] { calls }
}

private actor E2EAppAuthRecordingAPI: InviteBootstrapAPI {
    private let log: E2EAppAuthBootstrapCallLog
    private let accessToken: String
    private let deviceToken: String?

    init(
        log: E2EAppAuthBootstrapCallLog,
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
            deviceId: "dev_e2e",
            accessToken: accessToken,
            expiresAt: 4_102_444_800_000
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
