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
            },
            httpReachabilityProbe: { _, _ in await log.append("httpsProbe") }
        )

        let calls = await log.snapshot()
        #expect(calls == [
            "trust:Trust pairing.example.test (sha256:abcdef1234567890)",
            "httpsProbe",
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

    @Test func irohPreferredWithoutTunnelUsesHTTPForPairingAndBootstrap() async throws {
        let log = InviteBootstrapCallLog()
        let bootstrapAPI = RecordingInviteBootstrapAPI(log: log, pairDeviceToken: "http-device-token")
        let authenticatedAPI = RecordingInviteBootstrapAPI(log: log)
        var apis = [bootstrapAPI, authenticatedAPI]
        var irohPairCalled = false
        let proxyURL = try #require(URL(string: "http://127.0.0.1:41000"))

        let result = try await InviteBootstrapService.validateAndBootstrap(
            credentials: makeIrohPreferredCredentials(),
            existingCredentials: nil,
            confirmTrust: { _ in true },
            irohPairingClient: RecordingIrohInvitePairingClient(
                log: log,
                result: .success(deviceToken: "unexpected")
            ),
            apiFactory: { _, _, _ in apis.removeFirst() },
            irohProxyFactory: { _, _ in
                irohPairCalled = true
                return proxyURL
            },
            httpReachabilityProbe: { _, _ in await log.append("httpsProbe") }
        )

        #expect(await log.snapshot() == [
            "httpsProbe",
            "pair:one-time-token",
            "health",
            "me",
            "listSessions:3"
        ])
        #expect(!irohPairCalled)
        #expect(result.effectiveCredentials.token == "http-device-token")
    }

    @Test func HTTPPairingAgainstOlderServerInfersHTTPOnlyCredentialGrant() async throws {
        let log = InviteBootstrapCallLog()
        let pairingAPI = RecordingInviteBootstrapAPI(log: log, pairDeviceToken: "https-device-token")
        let authenticatedAPI = RecordingInviteBootstrapAPI(log: log)
        var apis: [RecordingInviteBootstrapAPI] = [pairingAPI, authenticatedAPI]

        let result = try await InviteBootstrapService.validateAndBootstrap(
            credentials: makeIrohPreferredTunnelCredentials(),
            existingCredentials: nil,
            confirmTrust: { _ in true },
            apiFactory: { _, _, _ in apis.removeFirst() },
            httpReachabilityProbe: { _, _ in }
        )

        let candidates = try ServerTransportPlanResolver.candidates(
            credentials: result.effectiveCredentials,
            mode: .automatic,
            discoveredLANEndpoint: nil
        )
        #expect(candidates.count == 1)
        guard case .http = candidates.first else {
            Issue.record("Older HTTP pairing must infer an HTTP-only credential grant")
            return
        }
    }

    @Test func dualInviteHTTPSPairingSendsStableIrohNodeIDAndPersistsConfirmedGrant() async throws {
        let log = InviteBootstrapCallLog()
        let pairingAPI = RecordingInviteBootstrapAPI(
            log: log,
            pairDeviceToken: "https-device-token",
            credentialTransports: [.http, .iroh]
        )
        let authenticatedAPI = RecordingInviteBootstrapAPI(log: log)
        var apis: [RecordingInviteBootstrapAPI] = [pairingAPI, authenticatedAPI]

        let result = try await InviteBootstrapService.validateAndBootstrap(
            credentials: makeIrohPreferredTunnelCredentials(),
            existingCredentials: nil,
            confirmTrust: { _ in true },
            apiFactory: { _, _, _ in apis.removeFirst() },
            httpReachabilityProbe: { _, _ in },
            irohClientNodeIDProvider: { "stable-apple-node" }
        )

        #expect(await pairingAPI.receivedClientNodeIDs() == ["stable-apple-node"])
        #expect(result.effectiveCredentials.credentialGrant == [.http, .iroh])
    }

    @Test func automaticPairingPrefersHTTPSAndDoesNotStartIroh() async throws {
        let log = InviteBootstrapCallLog()
        let pairingAPI = RecordingInviteBootstrapAPI(log: log, pairDeviceToken: "https-device-token")
        let authenticatedAPI = RecordingInviteBootstrapAPI(log: log)
        var apis: [RecordingInviteBootstrapAPI] = [pairingAPI, authenticatedAPI]
        let irohClient = RecordingIrohInvitePairingClient(
            log: log,
            result: .success(deviceToken: "unexpected")
        )
        var factoryURLs: [URL] = []
        var proxyTokens: [String] = []
        let proxyURL = try #require(URL(string: "http://127.0.0.1:41001"))

        let result = try await InviteBootstrapService.validateAndBootstrap(
            credentials: makeIrohPreferredTunnelCredentials(),
            existingCredentials: nil,
            confirmTrust: { _ in true },
            irohPairingClient: irohClient,
            apiFactory: { url, _, _ in
                factoryURLs.append(url)
                return apis.removeFirst()
            },
            irohProxyFactory: { _, token in
                proxyTokens.append(token)
                return proxyURL
            },
            httpReachabilityProbe: { _, _ in await log.append("httpsProbe") }
        )

        #expect(await log.snapshot() == [
            "httpsProbe",
            "pair:one-time-token",
            "health",
            "me",
            "listSessions:3"
        ])
        #expect(factoryURLs.map(\.absoluteString) == ["https://pairing.example.test:443", "https://pairing.example.test:443"])
        #expect(proxyTokens.isEmpty)
        #expect(result.effectiveCredentials.token == "https-device-token")
        #expect(result.effectiveCredentials.host == host)
    }

    @Test func irohPreferredTunnelFailureIsFailClosedWithoutHTTPDowngrade() async throws {
        let log = InviteBootstrapCallLog()
        var apiFactoryCalled = false

        await #expect(throws: IrohTransportError.unavailable("relay offline")) {
            _ = try await InviteBootstrapService.validateAndBootstrap(
                credentials: makeIrohPreferredTunnelCredentials(),
                existingCredentials: nil,
                confirmTrust: { _ in true },
                irohPairingClient: RecordingIrohInvitePairingClient(
                    log: log,
                    result: .success(deviceToken: "iroh-device-token")
                ),
                apiFactory: { _, _, _ in
                    apiFactoryCalled = true
                    return RecordingInviteBootstrapAPI(log: log)
                },
                irohProxyFactory: { _, _ in
                    throw IrohTransportError.unavailable("relay offline")
                },
                httpReachabilityProbe: { _, _ in throw URLError(.cannotConnectToHost) },
                irohReachabilityProbe: IrohReachabilityProbeStub()
            )
        }

        #expect(await log.snapshot() == ["irohPair:one-time-token:node-id-123"])
        #expect(!apiFactoryCalled)
    }

    @Test func preDispatchIrohPairingFailureKeepsInviteRetryable() async throws {
        let log = InviteBootstrapCallLog()
        var apiFactoryCalled = false
        let unreachableProxyURL = try #require(URL(string: "http://127.0.0.1:41002"))

        await #expect(throws: InviteBootstrapError.message(
            "Could not reach the server over Iroh. Check your network and try again."
        )) {
            _ = try await InviteBootstrapService.validateAndBootstrap(
                credentials: makeIrohPreferredTunnelCredentials(),
                existingCredentials: nil,
                confirmTrust: { _ in true },
                irohPairingClient: RecordingIrohInvitePairingClient(
                    log: log,
                    result: .transportUnavailable("relay offline")
                ),
                apiFactory: { _, _, _ in
                    apiFactoryCalled = true
                    return RecordingInviteBootstrapAPI(log: log)
                },
                irohProxyFactory: { _, _ in
                    Issue.record("Proxy must not start after pairing failure")
                    return unreachableProxyURL
                },
                httpReachabilityProbe: { _, _ in throw URLError(.cannotConnectToHost) },
                irohReachabilityProbe: IrohReachabilityProbeStub()
            )
        }

        #expect(await log.snapshot() == ["irohPair:one-time-token:node-id-123"])
        #expect(!apiFactoryCalled)
    }

    @Test func postDispatchIrohPairingFailureMayHaveConsumedInvite() async throws {
        let log = InviteBootstrapCallLog()
        let unreachableProxyURL = try #require(URL(string: "http://127.0.0.1:41006"))

        await #expect(throws: InviteBootstrapError.message(
            "Pairing may have completed, but its response was lost. Open Oppi to check, or request a fresh invite before trying again."
        )) {
            _ = try await InviteBootstrapService.validateAndBootstrap(
                credentials: makeIrohPreferredTunnelCredentials(),
                existingCredentials: nil,
                confirmTrust: { _ in true },
                irohPairingClient: RecordingIrohInvitePairingClient(
                    log: log,
                    result: .responseUnavailable
                ),
                apiFactory: { _, _, _ in
                    Issue.record("Bootstrap must not start after a lost pairing response")
                    return RecordingInviteBootstrapAPI(log: log)
                },
                irohProxyFactory: { _, _ in unreachableProxyURL },
                httpReachabilityProbe: { _, _ in throw URLError(.cannotConnectToHost) },
                irohReachabilityProbe: IrohReachabilityProbeStub()
            )
        }

        #expect(await log.snapshot() == ["irohPair:one-time-token:node-id-123"])
    }

    @Test func irohOnlyTunnelPairsAndBootstrapsWithoutHTTP() async throws {
        let log = InviteBootstrapCallLog()
        let proxyURL = try #require(URL(string: "http://127.0.0.1:41003"))
        let result = try await InviteBootstrapService.validateAndBootstrap(
            credentials: makeIrohOnlyCredentials(),
            existingCredentials: nil,
            confirmTrust: { _ in true },
            irohPairingClient: RecordingIrohInvitePairingClient(
                log: log,
                result: .success(deviceToken: "iroh-device-token")
            ),
            apiFactory: { url, _, fingerprint in
                #expect(url.host == "127.0.0.1")
                #expect(fingerprint == nil)
                return RecordingInviteBootstrapAPI(log: log, label: "tunnel")
            },
            irohProxyFactory: { _, _ in proxyURL },
            irohReachabilityProbe: IrohReachabilityProbeStub()
        )

        #expect(await log.snapshot() == [
            "irohPair:one-time-token:node-id-123",
            "tunnel:health",
            "tunnel:me",
            "tunnel:listSessions:3"
        ])
        #expect(result.effectiveCredentials.token == "iroh-device-token")
        #expect(result.effectiveCredentials.credentialGrant == [.iroh])
        #expect(result.effectiveCredentials.baseURL == nil)
    }

    @Test func irohOnlyTunnelMissingPairMetadataFailsWithoutFallback() async throws {
        let log = InviteBootstrapCallLog()
        let unreachableProxyURL = try #require(URL(string: "http://127.0.0.1:41004"))
        await #expect(throws: InviteBootstrapError.message("Selected Iroh transport is missing oppi/pair/1 metadata")) {
            _ = try await InviteBootstrapService.validateAndBootstrap(
                credentials: makeIrohOnlyCredentials(alpns: [IrohTunnelProtocol.alpn]),
                existingCredentials: nil,
                confirmTrust: { _ in true },
                irohPairingClient: RecordingIrohInvitePairingClient(
                    log: log,
                    result: .success(deviceToken: "unused")
                ),
                irohProxyFactory: { _, _ in
                    Issue.record("Proxy must not start")
                    return unreachableProxyURL
                }
            )
        }
        #expect(await log.snapshot().isEmpty)
    }

    @Test func irohProbeFailureBeforePairingKeepsInviteRetryable() async throws {
        let log = InviteBootstrapCallLog()

        await #expect(throws: InviteBootstrapError.message(
            "Could not reach the server over Iroh. Check your network and try again."
        )) {
            _ = try await InviteBootstrapService.validateAndBootstrap(
                credentials: makeIrohOnlyCredentials(),
                existingCredentials: nil,
                confirmTrust: { _ in true },
                irohPairingClient: RecordingIrohInvitePairingClient(
                    log: log,
                    result: .success(deviceToken: "unexpected")
                ),
                irohReachabilityProbe: IrohReachabilityProbeStub(
                    error: .unavailable("Iroh probe could not connect")
                )
            )
        }

        #expect(await log.snapshot().isEmpty)
    }

    @Test func irohPairingRejectionNeverFallsBackToHTTP() async throws {
        let log = InviteBootstrapCallLog()
        var apiFactoryCalled = false
        await #expect(throws: InviteBootstrapError.message("Invite link expired or was already used. Request a fresh invite.")) {
            _ = try await InviteBootstrapService.validateAndBootstrap(
                credentials: makeIrohPreferredTunnelCredentials(),
                existingCredentials: nil,
                confirmTrust: { _ in true },
                irohPairingClient: RecordingIrohInvitePairingClient(
                    log: log,
                    result: .rejected("Invalid or expired pairing token")
                ),
                apiFactory: { _, _, _ in
                    apiFactoryCalled = true
                    return RecordingInviteBootstrapAPI(log: log)
                },
                httpReachabilityProbe: { _, _ in throw URLError(.cannotConnectToHost) },
                irohReachabilityProbe: IrohReachabilityProbeStub()
            )
        }
        #expect(await log.snapshot() == ["irohPair:one-time-token:node-id-123"])
        #expect(!apiFactoryCalled)
    }

    @Test func automaticPairingUsesIrohAfterHTTPSProbeAvailabilityFailure() async throws {
        let log = InviteBootstrapCallLog()
        let proxyURL = try #require(URL(string: "http://127.0.0.1:41005"))
        var proxyTokens: [String] = []

        let result = try await InviteBootstrapService.validateAndBootstrap(
            credentials: makeIrohPreferredTunnelCredentials(),
            existingCredentials: nil,
            confirmTrust: { _ in true },
            irohPairingClient: RecordingIrohInvitePairingClient(
                log: log,
                result: .success(deviceToken: "iroh-device-token")
            ),
            apiFactory: { _, _, _ in RecordingInviteBootstrapAPI(log: log, label: "tunnel") },
            irohProxyFactory: { _, token in
                proxyTokens.append(token)
                return proxyURL
            },
            httpReachabilityProbe: { _, _ in throw URLError(.cannotConnectToHost) },
            irohReachabilityProbe: IrohReachabilityProbeStub()
        )

        #expect(await log.snapshot() == [
            "irohPair:one-time-token:node-id-123",
            "tunnel:health",
            "tunnel:me",
            "tunnel:listSessions:3"
        ])
        #expect(proxyTokens == ["iroh-device-token"])
        #expect(result.effectiveCredentials.token == "iroh-device-token")
    }

    @Test func httpsOnlyPairingNeverProbesIroh() async throws {
        let log = InviteBootstrapCallLog()
        let pairingAPI = RecordingInviteBootstrapAPI(log: log, pairDeviceToken: "https-device-token")
        let authenticatedAPI = RecordingInviteBootstrapAPI(log: log)
        var apis = [pairingAPI, authenticatedAPI]

        let result = try await InviteBootstrapService.validateAndBootstrap(
            credentials: makeHTTPOnlyCredentials(),
            existingCredentials: nil,
            confirmTrust: { _ in true },
            irohPairingClient: RecordingIrohInvitePairingClient(
                log: log,
                result: .success(deviceToken: "unexpected")
            ),
            apiFactory: { _, _, _ in apis.removeFirst() },
            httpReachabilityProbe: { _, _ in await log.append("httpsProbe") },
            irohReachabilityProbe: IrohReachabilityProbeStub(
                error: .protocolViolation("Iroh must not be probed")
            )
        )

        #expect(await log.snapshot() == [
            "httpsProbe",
            "pair:one-time-token",
            "health",
            "me",
            "listSessions:3"
        ])
        #expect(result.effectiveCredentials.token == "https-device-token")
    }

    @Test func postDispatchNetworkFailureDoesNotRetryPairingOnIroh() async throws {
        let log = InviteBootstrapCallLog()
        var apiFactoryCalls = 0
        let lostResponse = FailingInviteBootstrapAPI(
            log: log,
            label: "https",
            error: URLError(.networkConnectionLost)
        )

        await #expect(throws: InviteBootstrapError.message(
            "Pairing may have completed, but its response was lost. Open Oppi to check, or request a fresh invite before trying again."
        )) {
            _ = try await InviteBootstrapService.validateAndBootstrap(
                credentials: makeIrohPreferredTunnelCredentials(),
                existingCredentials: nil,
                confirmTrust: { _ in true },
                irohPairingClient: RecordingIrohInvitePairingClient(
                    log: log,
                    result: .success(deviceToken: "unexpected")
                ),
                apiFactory: { _, _, _ in
                    apiFactoryCalls += 1
                    return lostResponse
                },
                httpReachabilityProbe: { _, _ in await log.append("httpsProbe") },
                irohReachabilityProbe: IrohReachabilityProbeStub(
                    error: .protocolViolation("Iroh must not be probed")
                )
            )
        }

        #expect(await log.snapshot() == ["httpsProbe", "https:pair:one-time-token"])
        #expect(apiFactoryCalls == 1)
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

    private func makeIrohPreferredCredentials() -> ServerCredentials {
        ServerCredentials(
            host: host,
            port: 443,
            token: "invite-token",
            name: "Pairing Server",
            scheme: .https,
            pairingToken: "one-time-token",
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "node-id-123",
                    alpns: ["oppi/pair/1", IrohTunnelProtocol.alpn],
                    addressMode: .nodeId,
                    ticket: nil
                ),
                http: HTTPServerTransport(
                    host: host,
                    port: 443,
                    scheme: .https,
                    tlsCertFingerprint: nil
                )
            )
        )
    }

    private func makeHTTPOnlyCredentials() -> ServerCredentials {
        ServerCredentials(
            host: host,
            port: 443,
            token: "invite-token",
            name: "Pairing Server",
            scheme: .https,
            pairingToken: "one-time-token",
            transports: ServerTransports(
                preference: .httpOnly,
                http: HTTPServerTransport(
                    host: host,
                    port: 443,
                    scheme: .https,
                    tlsCertFingerprint: nil
                )
            )
        )
    }

    private func makeIrohPreferredTunnelCredentials() -> ServerCredentials {
        ServerCredentials(
            host: host,
            port: 443,
            token: "invite-token",
            name: "Pairing Server",
            scheme: .https,
            pairingToken: "one-time-token",
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "node-id-123",
                    alpns: ["oppi/pair/1", IrohTunnelProtocol.alpn],
                    addressMode: .nodeId,
                    ticket: nil
                ),
                http: HTTPServerTransport(
                    host: host,
                    port: 443,
                    scheme: .https,
                    tlsCertFingerprint: nil
                )
            )
        )
    }

    private func makeIrohPreferredWithoutHTTPCredentials() -> ServerCredentials {
        ServerCredentials(
            host: "",
            port: 0,
            token: "invite-token",
            name: "Iroh Preferred Server",
            scheme: nil,
            pairingToken: "one-time-token",
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "node-id-123",
                    alpns: ["oppi/pair/1"],
                    addressMode: .nodeId,
                    ticket: nil
                ),
                http: nil
            )
        )
    }

    private func makeIrohOnlyCredentials(alpns: [String] = ["oppi/pair/1", IrohTunnelProtocol.alpn]) -> ServerCredentials {
        ServerCredentials(
            host: "",
            port: 0,
            token: "",
            name: "Iroh Pairing Server",
            scheme: nil,
            pairingToken: "one-time-token",
            serverFingerprint: "sha256:iroh-server-fp",
            transports: ServerTransports(
                preference: .irohOnly,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "node-id-123",
                    alpns: alpns,
                    addressMode: .nodeId,
                    ticket: nil
                )
            )
        )
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
    private let credentialTransports: [CredentialTransport]?
    private let label: String?
    private var clientNodeIDs: [String?] = []

    init(
        log: InviteBootstrapCallLog,
        pairDeviceToken: String = "device-token",
        credentialTransports: [CredentialTransport]? = nil,
        label: String? = nil
    ) {
        self.log = log
        self.pairDeviceToken = pairDeviceToken
        self.credentialTransports = credentialTransports
        self.label = label
    }

    func pairDevice(
        pairingToken: String,
        deviceName: String?,
        clientNodeId: String?
    ) async throws -> PairDeviceResponse {
        await log.append(call("pair:\(pairingToken)"))
        clientNodeIDs.append(clientNodeId)
        return PairDeviceResponse(
            deviceToken: pairDeviceToken,
            credentialTransports: credentialTransports
        )
    }

    func receivedClientNodeIDs() -> [String?] {
        clientNodeIDs
    }

    func health() async throws -> Bool {
        await log.append(call("health"))
        return true
    }

    func me() async throws -> User {
        await log.append(call("me"))
        return User(user: "test-user", name: "Test User")
    }

    func listSessionsFromWorkspaces(recentDays: Int) async throws -> [Session] {
        await log.append(call("listSessions:\(recentDays)"))
        return []
    }

    private func call(_ name: String) -> String {
        guard let label else { return name }
        return "\(label):\(name)"
    }
}

private actor FailingInviteBootstrapAPI: InviteBootstrapAPI {
    private let log: InviteBootstrapCallLog
    private let label: String
    private let error: Error

    init(log: InviteBootstrapCallLog, label: String, error: Error) {
        self.log = log
        self.label = label
        self.error = error
    }

    func pairDevice(
        pairingToken: String,
        deviceName: String?,
        clientNodeId: String?
    ) async throws -> PairDeviceResponse {
        await log.append("\(label):pair:\(pairingToken)")
        throw error
    }

    func health() async throws -> Bool {
        await log.append("\(label):health")
        throw error
    }

    func me() async throws -> User {
        await log.append("\(label):me")
        throw error
    }

    func listSessionsFromWorkspaces(recentDays: Int) async throws -> [Session] {
        await log.append("\(label):listSessions:\(recentDays)")
        throw error
    }
}

private struct IrohReachabilityProbeStub: IrohInvitePairingReachabilityProbing {
    let error: IrohTransportError?

    init(error: IrohTransportError? = nil) {
        self.error = error
    }

    func probe(iroh: IrohServerTransport) async throws {
        if let error { throw error }
    }
}

private actor RecordingIrohInvitePairingClient: IrohInvitePairingClient {
    private let log: InviteBootstrapCallLog
    private let result: IrohInvitePairingResult

    init(log: InviteBootstrapCallLog, result: IrohInvitePairingResult) {
        self.log = log
        self.result = result
    }

    func pairDevice(
        pairingToken: String,
        iroh: IrohServerTransport,
        deviceName: String?
    ) async -> IrohInvitePairingResult {
        await log.append("irohPair:\(pairingToken):\(iroh.nodeId)")
        return result
    }
}
