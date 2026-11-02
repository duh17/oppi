import Foundation
import Testing
@testable import Oppi

@Suite("ServerConnectionLANTransport")
@MainActor
struct ServerConnectionLANTransportTests {
    @Test func configureDefaultsToPairedTransport() async {
        let connection = ServerConnection()
        let credentials = makeCredentials()

        let configured = await configureTestConnection(connection, credentials: credentials)

        #expect(configured == true)
        #expect(connection.transportPath == .paired)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://my-server.tail00000.ts.net:7749")
    }

    @Test func verifiedLANDiscoveryUpdatesTransportClients() async {
        let connection = ServerConnection()
        let credentials = makeCredentials()
        #expect(await configureTestConnection(connection, credentials: credentials) == true)

        await discoverTestLANEndpoint(on: connection,
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )

        #expect(connection.transportPath == .lan)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://192.168.1.42:7749")
    }

    @Test func activeTurnKeepsPairedCompositionWhenLANIsDiscovered() async {
        let connection = ServerConnection()
        connection.route.networkPathType = { "wifi" }
        var session = makeTestSession(id: "active", workspaceId: "w1")
        session.status = .busy
        connection.sessionStore.upsert(session)
        let credentials = makeCredentials()
        #expect(await configureTestConnection(connection, credentials: credentials) == true)

        let initialWebSocketClient = connection.wsClient
        connection.wsClient?._setStatusForTesting(.connected)

        connection.route.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )

        #expect(connection.transportPath == .paired)
        #expect(connection.wsClient === initialWebSocketClient)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://my-server.tail00000.ts.net:7749")
    }

    @Test func removingLANDiscoveryRebuildsPairedComposition() async {
        let connection = ServerConnection()
        let credentials = makeCredentials()
        #expect(await configureTestConnection(connection, credentials: credentials) == true)

        await discoverTestLANEndpoint(on: connection,
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )
        #expect(connection.transportPath == .lan)

        let activeWebSocketClient = connection.wsClient

        await connection.route.setDiscoveredLANEndpoint(nil)?.value

        #expect(connection.transportPath == .paired)
        #expect(connection.wsClient !== activeWebSocketClient)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://my-server.tail00000.ts.net:7749")
    }

    @Test func mismatchedLANDiscoveryKeepsPairedTransport() async {
        let connection = ServerConnection()
        let credentials = makeCredentials()
        #expect(await configureTestConnection(connection, credentials: credentials) == true)

        connection.route.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "OTHER",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )

        #expect(connection.transportPath == .paired)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://my-server.tail00000.ts.net:7749")
    }

    @Test func unpinnedTailscaleCertificateUsesSignedNameOverLANIP() async {
        let connection = ServerConnection()
        let credentials = makeCredentials(tlsFingerprint: nil)
        #expect(await configureTestConnection(connection, credentials: credentials) == true)
        #expect(connection.wsClient?.configuredTLSServerName == nil)

        await discoverTestLANEndpoint(on: connection,
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )

        #expect(connection.transportPath == .lan)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://192.168.1.42:7749")
        #expect(await connection.apiClient?.environment.tlsServerName == "my-server.tail00000.ts.net")
        #expect(connection.wsClient?.configuredTLSServerName == "my-server.tail00000.ts.net")
    }

    private func makeCredentials(tlsFingerprint: String? = "sha256:TLSFINGERPRINTABCDEF") -> ServerCredentials {
        ServerCredentials(
            host: "my-server.tail00000.ts.net",
            port: 7749,
            token: "sk_test",
            name: "Studio",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: tlsFingerprint
        )
    }
}
