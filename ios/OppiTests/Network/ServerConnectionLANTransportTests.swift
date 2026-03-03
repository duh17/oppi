import Foundation
import Testing
@testable import Oppi

@Suite("ServerConnectionLANTransport")
@MainActor
struct ServerConnectionLANTransportTests {
    @Test func configureDefaultsToPairedTransport() async {
        let connection = ServerConnection()
        let credentials = makeCredentials()

        let configured = connection.configure(credentials: credentials)

        #expect(configured == true)
        #expect(connection.transportPath == .paired)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://mac-studio.taila3ebc.ts.net:7749")
    }

    @Test func matchingLANDiscoverySwitchesTransportWithoutReplacingWebSocketClient() async {
        let connection = ServerConnection()
        let credentials = makeCredentials()
        #expect(connection.configure(credentials: credentials) == true)

        let initialWebSocketClient = connection.wsClient

        connection.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )

        #expect(connection.transportPath == .lan)
        #expect(connection.wsClient === initialWebSocketClient)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://192.168.1.42:7749")
    }

    @Test func removingLANDiscoveryFallsBackToPairedWithoutReplacingWebSocketClient() async {
        let connection = ServerConnection()
        let credentials = makeCredentials()
        #expect(connection.configure(credentials: credentials) == true)

        connection.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )
        #expect(connection.transportPath == .lan)

        let activeWebSocketClient = connection.wsClient

        connection.setDiscoveredLANEndpoint(nil)

        #expect(connection.transportPath == .paired)
        #expect(connection.wsClient === activeWebSocketClient)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://mac-studio.taila3ebc.ts.net:7749")
    }

    @Test func mismatchedLANDiscoveryKeepsPairedTransport() async {
        let connection = ServerConnection()
        let credentials = makeCredentials()
        #expect(connection.configure(credentials: credentials) == true)

        connection.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "OTHER",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )

        #expect(connection.transportPath == .paired)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://mac-studio.taila3ebc.ts.net:7749")
    }

    @Test func lanDiscoveryIsIgnoredWithoutPinnedTLSFingerprint() async {
        let connection = ServerConnection()
        let credentials = makeCredentials(tlsFingerprint: nil)
        #expect(connection.configure(credentials: credentials) == true)

        connection.setDiscoveredLANEndpoint(
            LANDiscoveredEndpoint(
                host: "192.168.1.42",
                port: 7749,
                serverFingerprintPrefix: "SERVERFINGERPRINT",
                tlsCertFingerprintPrefix: "TLSFINGERPRINT"
            )
        )

        #expect(connection.transportPath == .paired)
        #expect(await connection.apiClient?.baseURL.absoluteString == "https://mac-studio.taila3ebc.ts.net:7749")
    }

    private func makeCredentials(tlsFingerprint: String? = "sha256:TLSFINGERPRINTABCDEF") -> ServerCredentials {
        ServerCredentials(
            host: "mac-studio.taila3ebc.ts.net",
            port: 7749,
            token: "sk_test",
            name: "Studio",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsCertFingerprint: tlsFingerprint
        )
    }
}
