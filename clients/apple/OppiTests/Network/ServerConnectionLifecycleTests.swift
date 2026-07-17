import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Lifecycle")
@MainActor
struct ServerConnectionLifecycleTests {

    @Test func configureWithValidCredentials() {
        let conn = ServerConnection()
        let result = conn.configure(credentials: ServerCredentials(
            host: "192.168.1.10", port: 7749, token: "sk_abc", name: "Test"
        ))
        #expect(result == true)
        #expect(conn.apiClient != nil)
        #expect(conn.wsClient != nil)
        #expect(conn.credentials?.host == "192.168.1.10")
    }

    @Test func configureIrohOnlyUsesTransparentHTTPAndWebSocketClients() async throws {
        let conn = ServerConnection()
        let credentials = makeTestIrohOnlyCredentials()
        let localURL = try #require(URL(string: "http://127.0.0.1:41991"))
        let result = await conn.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in (nil, localURL) }
        )

        #expect(result)
        #expect(conn.transportPath == .iroh)
        #expect(conn.apiClient != nil)
        #expect(conn.wsClient != nil)
        #expect(conn.currentServerId == "sha256:iroh-server-fp")
        #expect(await conn.apiClient?.baseURL == localURL)
        #expect(conn.credentials?.baseURL == nil, "Loopback URL must not become persisted remote metadata")

        conn.setDiscoveredLANEndpoint(LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "iroh-server-fp",
            tlsCertFingerprintPrefix: nil
        ))
        #expect(conn.transportPath == .iroh)
        #expect(await conn.apiClient?.baseURL == localURL)
    }

    @Test func configureIrohOnlyRequiresTunnelMetadataAndFailsClosed() async {
        let conn = ServerConnection()
        var proxyStarted = false
        let result = await conn.configureForUse(
            credentials: makeTestIrohOnlyCredentials(alpns: ["oppi/pair/1"]),
            irohProxyFactory: { _, _ in
                proxyStarted = true
                return (nil, URL(string: "http://127.0.0.1:41992")!)
            }
        )

        #expect(!result)
        #expect(!proxyStarted)
        #expect(conn.credentials == nil)
        #expect(conn.apiClient == nil)
        #expect(conn.wsClient == nil)
    }

    @Test func disconnectSessionClearsActiveId() {
        let scenario = EventFlowServerConnectionScenario()
        let conn = scenario.connection

        conn.disconnectSession()

        // After disconnect, messages should be ignored (no active session)
        scenario.whenHandle(.connected(session: makeTestSession(status: .busy)))
        #expect(conn.sessionStore.sessions.isEmpty)
    }

    @Test func flushAndSuspendDelivers() {
        let scenario = EventFlowServerConnectionScenario()

        scenario
            .whenHandle(.agentStart)
            .whenHandle(.textDelta(delta: "buffered"))
            .whenFlush()

        #expect(scenario.timelineItemCount(of: .assistantMessage) == 1)
    }

    @Test func requestStateUsesDispatchSendHook() async throws {
        let conn = ServerConnection()
        var sawGetState = false

        conn._sendMessageForTesting = { message in
            if case .getState = message {
                sawGetState = true
            }
        }

        try await conn.requestState()
        #expect(sawGetState)
    }

    @Test func isConnectedDefaultFalse() {
        let conn = ServerConnection()
        #expect(!conn.isConnected)
    }

    @Test func switchServerConfiguresNewServer() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_studio",
            name: "studio", serverFingerprint: "sha256:studio-fp"
        )
        guard let server = PairedServer(from: creds) else {
            Issue.record("Expected PairedServer to be created from credentials")
            return
        }

        let result = conn.switchServer(to: server)
        #expect(result == true)
        #expect(conn.currentServerId == "sha256:studio-fp")
        #expect(conn.apiClient != nil)
    }

    @Test func switchServerSkipsIfAlreadyTargeting() {
        let conn = ServerConnection()
        let creds = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_a",
            name: "studio", serverFingerprint: "sha256:same-fp"
        )
        guard let server = PairedServer(from: creds) else {
            Issue.record("Expected PairedServer to be created from credentials")
            return
        }

        _ = conn.switchServer(to: server)
        let result = conn.switchServer(to: server)
        #expect(result == true)
        #expect(conn.currentServerId == "sha256:same-fp")
    }

    @Test func switchServerChangesTarget() {
        let conn = ServerConnection()
        let creds1 = ServerCredentials(
            host: "studio.ts.net", port: 7749, token: "sk_a",
            name: "studio", serverFingerprint: "sha256:fp-a"
        )
        let creds2 = ServerCredentials(
            host: "mini.ts.net", port: 7749, token: "sk_b",
            name: "mini", serverFingerprint: "sha256:fp-b"
        )
        guard let server1 = PairedServer(from: creds1),
              let server2 = PairedServer(from: creds2)
        else {
            Issue.record("Expected PairedServer values to be created from credentials")
            return
        }

        _ = conn.switchServer(to: server1)
        #expect(conn.currentServerId == "sha256:fp-a")

        _ = conn.switchServer(to: server2)
        #expect(conn.currentServerId == "sha256:fp-b")
    }

    @Test func currentServerIdNilByDefault() {
        let conn = ServerConnection()
        #expect(conn.currentServerId == nil)
    }

}
