import Foundation
import os
@testable import Oppi
import Testing

@Suite("ServerConnection Stream Recovery", .serialized)
@MainActor
struct ServerConnectionStreamRecoveryTests {
    @Test func transientCapabilityRefreshFailureIsRetryable() async {
        let connection = makeConnection()
        connection.setAPIClientForTesting(makeMockAPIClient())
        defer { cleanup(connection) }

        var calls = 0
        TestURLProtocol.handler = { request in
            #expect(request.url?.path == "/server/info")
            calls += 1
            if calls == 1 {
                throw URLError(.networkConnectionLost)
            }
            return self.mockServerInfoResponse(for: request)
        }

        await connection.refreshStreamCapabilitiesIfNeeded()
        #expect(!connection.hasRequiredSplitStreamCapabilities)
        #expect(connection.requiredSplitStreamCapabilitiesStatusForDiagnostics == "refreshFailed")

        await connection.refreshStreamCapabilitiesIfNeeded()
        #expect(connection.hasRequiredSplitStreamCapabilities)
        #expect(connection.requiredSplitStreamCapabilitiesStatusForDiagnostics == "ready")
        #expect(calls == 2)
    }

    @Test func knownGoodCapabilitiesSurviveTransientRefreshFailure() async {
        let connection = makeConnection()
        connection.setAPIClientForTesting(makeMockAPIClient())
        defer { cleanup(connection) }

        var calls = 0
        TestURLProtocol.handler = { request in
            #expect(request.url?.path == "/server/info")
            calls += 1
            if calls == 2 {
                throw URLError(.networkConnectionLost)
            }
            return self.mockServerInfoResponse(for: request)
        }

        await connection.refreshStreamCapabilities()
        #expect(connection.hasRequiredSplitStreamCapabilities)

        await connection.refreshStreamCapabilities()
        #expect(connection.hasRequiredSplitStreamCapabilities)
        #expect(connection.requiredSplitStreamCapabilitiesStatusForDiagnostics == "ready:refreshFailed")
        #expect(calls == 2)
    }

    @Test func coldSessionListRefreshDiscoversAndStartsAppEventStream() async {
        let connection = makeConnection()
        connection.setAPIClientForTesting(makeMockAPIClient())
        connection.workspaceStore.workspaces = [makeTestWorkspace(id: "w1")]
        connection.workspaceStore.isLoaded = true
        connection.sessionStore.upsert(makeTestSession(id: "seed", workspaceId: "w1"))
        defer { cleanup(connection) }

        var requestedPaths: [String] = []
        var startedStreamURL: URL?
        connection._startAppEventStreamForTesting = { url in
            startedStreamURL = url
        }

        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requestedPaths.append(path)
            switch path {
            case "/server/info":
                return self.mockServerInfoResponse(for: request, appEventStream: true)
            case "/sessions/recent":
                return self.jsonResponse("{\"sessions\":[]}", for: request)
            default:
                Issue.record("Unexpected request path: \(path)")
                return self.jsonResponse("{}", for: request, statusCode: 404)
            }
        }

        await connection.refreshSessionList(force: true)

        #expect(requestedPaths.first == "/server/info")
        #expect(requestedPaths.contains("/sessions/recent"))
        #expect(connection.appEventStreamAvailable)
        #expect(startedStreamURL?.path == "/app/events/stream")
    }

    @Test func networkPathChangeRecomputesPreparedFocusedStreamURL() async throws {
        let (connection, _) = try await makeProductionLANConnectionWithFocusedStream()
        defer { cleanup(connection) }

        #expect(connection.transportPath == .lan)
        #expect(connection.focusedSessionStreamURLForTesting?.absoluteString == "wss://192.168.1.42:7749/workspaces/w1/sessions/s1/stream")

        connection.handleNetworkPathChange()
        try await waitForPairedFocusedStream(connection)

        #expect(connection.transportPath == .paired)
        #expect(connection.focusedSessionStreamURLForTesting?.absoluteString == "wss://100.64.0.2:7749/workspaces/w1/sessions/s1/stream")
    }

    /// Walking off Wi‑Fi often kills the LAN socket first. By the time the path
    /// monitor demotes LAN, the focused WS may already be `.disconnected` with
    /// no consumption task. Recovery must still rebind the prepared session
    /// stream onto paired/Tailscale instead of settling with a dead socket.
    @Test func lanPathLossWithDisconnectedSocketStillReconnectsFocusedStream() async throws {
        let (connection, connectCalls) = try await makeProductionLANConnectionWithFocusedStream()
        defer { cleanup(connection) }

        connection.wsClient?._setStatusForTesting(.disconnected)
        #expect(connection.transportPath == .lan)
        #expect(connection.focusedSessionStreamURLForTesting?.host == "192.168.1.42")

        connection.handleNetworkPathChange()
        try await waitForPairedFocusedStream(connection, minConnectCalls: 1, connectCalls: connectCalls)

        #expect(connection.transportPath == .paired)
        #expect(await connection.apiClient?.baseURL.host == "100.64.0.2")
        #expect(connection.wsClient != nil)
        #expect(
            connection.focusedSessionStreamURLForTesting?.absoluteString
                == "wss://100.64.0.2:7749/workspaces/w1/sessions/s1/stream"
        )
        #expect(connectCalls() == 1, "Focused stream must be explicitly reopened after LAN path loss")
    }

    /// Incident shape: LAN WS is already burning reconnect backoff against a
    /// private IP when Wi‑Fi disappears. Demotion must stop that dead-LAN socket
    /// and reopen the focused stream on paired.
    @Test func lanPathLossWhileReconnectingDoesNotLeaveMissingEndpointSelection() async throws {
        let (connection, connectCalls) = try await makeProductionLANConnectionWithFocusedStream()
        defer { cleanup(connection) }

        connection.wsClient?._setStatusForTesting(.reconnecting(attempt: 3))
        connection.handleNetworkPathChange()
        try await waitForPairedFocusedStream(connection, minConnectCalls: 1, connectCalls: connectCalls)

        #expect(connection.transportPath == .paired)
        #expect(await connection.apiClient?.baseURL.host == "100.64.0.2")
        #expect(connection.wsClient != nil)
        #expect(
            connection.focusedSessionStreamURLForTesting?.absoluteString
                == "wss://100.64.0.2:7749/workspaces/w1/sessions/s1/stream"
        )
        #expect(connectCalls() == 1, "Reconnecting LAN socket must be replaced by a paired stream open")
    }

    private func makeProductionLANConnectionWithFocusedStream() async throws -> (
        connection: ServerConnection,
        connectCalls: () -> Int
    ) {
        let connection = ServerConnection()
        var connectCalls = 0
        connection._connectStreamForTesting = {
            connectCalls += 1
            return AsyncStream { $0.finish() }
        }
        connection.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )
        let configured = await connection.configureForUse(
            credentials: pairedCredentials(),
            serverInfoBootstrap: { _, _ in try self.mockServerInfo() }
        )
        #expect(configured)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s1", workspaceId: "w1")
        return (connection, { connectCalls })
    }

    private func pairedCredentials() -> ServerCredentials {
        ServerCredentials(
            host: "100.64.0.2",
            port: 7749,
            token: "sk_test",
            name: "Test",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
    }

    private func pairedServer() -> PairedServer {
        PairedServer(from: pairedCredentials())!
    }

    private func waitForPairedFocusedStream(
        _ connection: ServerConnection,
        minConnectCalls: Int = 0,
        connectCalls: (() -> Int)? = nil,
        timeoutMs: Int = 1000
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while true {
            let pairedURLReady = connection.transportPath == .paired
                && connection.focusedSessionStreamURLForTesting?.absoluteString
                    == "wss://100.64.0.2:7749/workspaces/w1/sessions/s1/stream"
            let connectsReady = (connectCalls?() ?? minConnectCalls) >= minConnectCalls
            if pairedURLReady && connectsReady {
                return
            }
            if ContinuousClock.now >= deadline {
                Issue.record(
                    "Timed out waiting for paired focused stream (transport=\(connection.transportPath), url=\(String(describing: connection.focusedSessionStreamURLForTesting)), connects=\(connectCalls?() ?? -1))"
                )
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// If the first paired bootstrap after LAN loss fails, automatic recovery
    /// must retry with budget instead of settling with nil clients forever.
    @Test func lanPathLossFailedDemotionRetriesUntilPairedSucceeds() async throws {
        let connection = ServerConnection()
        defer { cleanup(connection) }

        var bootstrapCalls = 0
        var now = Date(timeIntervalSince1970: 1_700_000_100)
        connection._automaticIrohRecoveryNowForTesting = { now }
        connection._refreshAfterAutomaticIrohRecoveryForTesting = {}
        var connectCalls = 0
        connection._connectStreamForTesting = {
            connectCalls += 1
            return AsyncStream { $0.finish() }
        }

        connection.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )
        #expect(await connection.configureForUse(
            credentials: pairedCredentials(),
            serverInfoBootstrap: { _, _ in
                bootstrapCalls += 1
                // 1 = initial LAN success. 2 = first demotion attempt fails.
                // 3+ = automatic retry succeeds.
                if bootstrapCalls == 2 {
                    throw URLError(.notConnectedToInternet)
                }
                return try self.mockServerInfo()
            }
        ))
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s1", workspaceId: "w1")
        #expect(connection.transportPath == .lan)

        connection.handleNetworkPathChange()

        // First demotion pass fails and should leave recovery armed.
        let failedDeadline = ContinuousClock.now + .milliseconds(1_000)
        while connection.apiClient != nil && ContinuousClock.now < failedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.apiClient == nil)
        #expect(connection.isTransportDemoting || connection.hasScheduledAutomaticRouteRecoveryForTesting)

        // Advance past the first automatic backoff and wait for retry.
        now = now.addingTimeInterval(1.1)
        try await waitForPairedFocusedStream(
            connection,
            minConnectCalls: 1,
            connectCalls: { connectCalls },
            timeoutMs: 3_000
        )

        #expect(connection.transportPath == .paired)
        #expect(await connection.apiClient?.baseURL.host == "100.64.0.2")
        #expect(connectCalls >= 1)
        #expect(!connection.isTransportDemoting)
        #expect(bootstrapCalls >= 3)
    }

    /// While demotion is in flight, diagnostics/UI must not present a settled
    /// "local network" connection with nil clients.
    @Test func lanPathLossMarksTransportDemotingDuringReconfigureHole() async throws {
        let connection = ServerConnection()
        defer { cleanup(connection) }

        let holdFirstDemotion = OSAllocatedUnfairLock(initialState: true)
        defer { holdFirstDemotion.withLock { $0 = false } }

        connection.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )
        var bootstrapCalls = 0
        #expect(await connection.configureForUse(
            credentials: pairedCredentials(),
            serverInfoBootstrap: { _, _ in
                bootstrapCalls += 1
                if bootstrapCalls >= 2 {
                    while holdFirstDemotion.withLock({ $0 }) {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                return try self.mockServerInfo()
            }
        ))
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s1", workspaceId: "w1")

        connection.handleNetworkPathChange()

        let holeDeadline = ContinuousClock.now + .milliseconds(1_000)
        while ContinuousClock.now < holeDeadline {
            if connection.isTransportDemoting,
               connection.apiClient == nil,
               connection.wsClient == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(connection.isTransportDemoting)
        #expect(connection.apiClient == nil)
        #expect(connection.wsClient == nil)
        #expect(connection.serverHealth().transportState == .connecting)
        #expect(
            ServerConnectionLanePresentation.title(
                server: pairedServer(),
                connection: connection,
                state: .recovering,
                isPreparing: false
            ) == "Recovering connection"
        )

        holdFirstDemotion.withLock { $0 = false }
        try await waitForPairedFocusedStream(connection, timeoutMs: 2_000)
        #expect(!connection.isTransportDemoting)
        #expect(connection.transportPath == .paired)
    }

    /// Silence-watchdog / session re-entry during demotion must wait for the
    /// next route instead of permanently failing with missingEndpointSelection.
    @Test func streamSessionWaitsForTransportDemotionBeforeMissingEndpoint() async throws {
        let connection = ServerConnection()
        defer { cleanup(connection) }

        let holdDemotion = OSAllocatedUnfairLock(initialState: true)
        defer { holdDemotion.withLock { $0 = false } }
        var bootstrapCalls = 0
        var connectCalls = 0
        connection._connectStreamForTesting = {
            connectCalls += 1
            return AsyncStream { $0.finish() }
        }

        connection.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )
        #expect(await connection.configureForUse(
            credentials: pairedCredentials(),
            serverInfoBootstrap: { _, _ in
                bootstrapCalls += 1
                if bootstrapCalls >= 2 {
                    while holdDemotion.withLock({ $0 }) {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                return try self.mockServerInfo()
            }
        ))
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s1", workspaceId: "w1")

        connection.handleNetworkPathChange()

        let holeDeadline = ContinuousClock.now + .milliseconds(1_000)
        while ContinuousClock.now < holeDeadline {
            if connection.isTransportDemoting, connection.apiClient == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(connection.isTransportDemoting)
        #expect(connection.apiClient == nil)

        async let stream = connection.streamSession("s1", workspaceId: "w1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(connectCalls == 0, "Must not open a stream against a nil endpoint mid-demotion")

        holdDemotion.withLock { $0 = false }
        let opened = await stream
        #expect(opened != nil)
        #expect(connection.transportPath == .paired)
        #expect(
            connection.focusedSessionStreamURLForTesting?.absoluteString
                == "wss://100.64.0.2:7749/workspaces/w1/sessions/s1/stream"
        )
        #expect(connectCalls >= 1)
    }

    @Test func endpointDiagnosticsRedactHostsAndQueryStrings() {
        let url = URL(string: "wss://secret-node.tail123.ts.net:7749/workspaces/private/sessions/private/stream?token=abc")

        let metadata = ClientLog.endpointMetadata(url, prefix: "stream")

        #expect(metadata["streamScheme"] == "wss")
        #expect(metadata["streamHostKind"] == "tailscale")
        #expect(metadata["streamPort"] == "7749")
        #expect(!metadata.values.contains { value in
            value.contains("secret-node") || value.contains("private") || value.contains("token") || value.contains("abc")
        })
    }

    private func makeConnection(
        host: String = "127.0.0.1",
        scheme: ServerScheme = .http,
        tlsFingerprint: String? = nil
    ) -> ServerConnection {
        let connection = ServerConnection()
        let configured = connection.configure(credentials: ServerCredentials(
            host: host,
            port: 7749,
            token: "sk_test",
            name: "Test",
            scheme: scheme,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: tlsFingerprint
        ))
        #expect(configured)
        return connection
    }

    private func makeMockAPIClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://127.0.0.1:7749")!,
            token: "sk_test",
            configuration: config
        )
    }

    private func mockServerInfo() throws -> ServerInfo {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:7749/server/info")!)
        let (data, _) = mockServerInfoResponse(for: request)
        return try JSONDecoder().decode(ServerInfo.self, from: data)
    }

    private func mockServerInfoResponse(
        for request: URLRequest,
        appEventStream: Bool = false
    ) -> (Data, HTTPURLResponse) {
        let appEventCapability = appEventStream ? ",\n            \"appEventStream\": { \"version\": 1 }" : ""
        let data = """
        {
          "name": "Test",
          "version": "0.0.0-test",
          "uptime": 1,
          "os": "darwin",
          "arch": "arm64",
          "hostname": "test-host",
          "nodeVersion": "v22.0.0",
          "piVersion": "0.0.0-test",
          "configVersion": 2,
          "capabilities": {
            "sessionStream": { "version": 1 }\(appEventCapability)
          },
          "stats": {
            "workspaceCount": 1,
            "activeSessionCount": 1,
            "totalSessionCount": 1,
            "skillCount": 0,
            "modelCount": 0
          }
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1:7749/server/info")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    private func jsonResponse(
        _ json: String,
        for request: URLRequest,
        statusCode: Int = 200
    ) -> (Data, HTTPURLResponse) {
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1:7749")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    private func cleanup(_ connection: ServerConnection) {
        TestURLProtocol.handler = nil
        connection._startAppEventStreamForTesting = nil
        connection.disconnectAppEventStream()
        connection.disconnectStream()
    }
}
