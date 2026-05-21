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

    @Test func networkPathChangeRecomputesPreparedFocusedStreamURL() async {
        let connection = makeConnection(
            host: "paired.example",
            scheme: .http,
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        defer { cleanup(connection) }

        connection.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )
        connection.prepareFocusedSessionStreamEndpointForTesting(sessionId: "s1", workspaceId: "w1")

        #expect(connection.transportPath == .lan)
        #expect(connection.focusedSessionStreamURLForTesting?.absoluteString == "ws://192.168.1.42:7749/workspaces/w1/sessions/s1/stream")

        connection.wsClient?._setStatusForTesting(.connected)
        connection.handleNetworkPathChange()

        #expect(connection.transportPath == .paired)
        #expect(connection.focusedSessionStreamURLForTesting?.absoluteString == "ws://paired.example:7749/workspaces/w1/sessions/s1/stream")
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

    private func mockServerInfoResponse(for request: URLRequest) -> (Data, HTTPURLResponse) {
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
            "sessionStream": { "version": 1 }
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

    private func cleanup(_ connection: ServerConnection) {
        TestURLProtocol.handler = nil
        connection.disconnectStream()
    }
}
