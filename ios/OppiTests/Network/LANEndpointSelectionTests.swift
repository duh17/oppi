import Foundation
import Testing
@testable import Oppi

@Suite("LANEndpointSelection")
struct LANEndpointSelectionTests {

    @Test func fallsBackToPairedWhenNoDiscoveryCandidate() {
        let credentials = makeCredentials(
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: nil)

        #expect(result?.transportPath == .paired)
        #expect(result?.baseURL.absoluteString == "https://my-server.tail00000.ts.net:7749")
        #expect(result?.streamURL.absoluteString == "wss://my-server.tail00000.ts.net:7749/stream")
    }

    @Test func stillReturnsPairedSelectionForEdgeHostValues() {
        let credentials = makeCredentials(
            host: "",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: nil)
        #expect(result?.transportPath == .paired)
    }

    @Test func selectsLANWhenServerAndTLSFingerprintsMatch() {
        let credentials = makeCredentials(
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: discovered)

        #expect(result?.transportPath == .lan)
        #expect(result?.baseURL.absoluteString == "https://192.168.1.42:7749")
        #expect(result?.streamURL.absoluteString == "wss://192.168.1.42:7749/stream")
    }

    @Test func fallsBackToPairedWhenServerFingerprintPrefixDoesNotMatch() {
        let credentials = makeCredentials(
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "DIFFERENTSERVER",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: discovered)

        #expect(result?.transportPath == .paired)
        #expect(result?.baseURL.absoluteString == "https://my-server.tail00000.ts.net:7749")
    }

    @Test func fallsBackToPairedWhenPairedCredentialsLackTLSPin() {
        let credentials = makeCredentials(
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: nil
        )

        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: discovered)

        #expect(result?.transportPath == .paired)
        #expect(result?.baseURL.absoluteString == "https://my-server.tail00000.ts.net:7749")
    }

    @Test func fallsBackToPairedWhenDiscoveredTLSPrefixMismatches() {
        let credentials = makeCredentials(
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "OTHER"
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: discovered)

        #expect(result?.transportPath == .paired)
    }

    @Test func allowsLANWhenDiscoveredTLSPrefixIsMissingButServerMatches() {
        let credentials = makeCredentials(
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "sha256:SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: nil
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: discovered)

        #expect(result?.transportPath == .lan)
    }

    @Test func invalidDiscoveredPortFallsBackToPaired() {
        let credentials = makeCredentials(
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 0,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: discovered)

        #expect(result?.transportPath == .paired)
    }

    private func makeCredentials(
        host: String,
        scheme: ServerScheme,
        serverFingerprint: String,
        tlsFingerprint: String?
    ) -> ServerCredentials {
        ServerCredentials(
            host: host,
            port: 7749,
            token: "sk_test",
            name: "Test",
            scheme: scheme,
            serverFingerprint: serverFingerprint,
            tlsCertFingerprint: tlsFingerprint
        )
    }
}
