import Foundation
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
        let connection = ServerConnection()
        defer { cleanup(connection) }

        connection.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )
        let configured = await connection.configureForUse(
            credentials: ServerCredentials(
                host: "100.64.0.2",
                port: 7749,
                token: "sk_test",
                name: "Test",
                scheme: .https,
                serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
                tlsCertFingerprint: "sha256:TLSFINGERPRINTABCDEF"
            ),
            serverInfoBootstrap: { _, _ in try self.mockServerInfo() }
        )
        #expect(configured)
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s1", workspaceId: "w1")

        #expect(connection.transportPath == .lan)
        #expect(connection.focusedSessionStreamURLForTesting?.absoluteString == "wss://192.168.1.42:7749/workspaces/w1/sessions/s1/stream")

        connection.handleNetworkPathChange()
        for _ in 0..<100 where connection.transportPath != .paired {
            await Task.yield()
        }

        #expect(connection.transportPath == .paired)
        #expect(connection.focusedSessionStreamURLForTesting?.absoluteString == "wss://100.64.0.2:7749/workspaces/w1/sessions/s1/stream")
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
