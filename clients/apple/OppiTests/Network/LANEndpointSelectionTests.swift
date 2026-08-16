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
    }

    @Test func stillReturnsPairedSelectionForEdgeHostValues() {
        let credentials = makeCredentials(
            host: "",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: nil)
        #expect(result == nil)
    }

    @Test func selectsDiscoveredLANIPForPinnedHTTPS() {
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

        // The paired leaf pin authenticates the discovered endpoint directly;
        // retaining the Tailscale hostname here would not be LAN transport.
        #expect(result?.transportPath == .lan)
        #expect(result?.baseURL.absoluteString == "https://192.168.1.42:7749")
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

    @Test func unpinnedTailscaleCertificateUsesSignedNameOverLANIP() {
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

        #expect(result?.transportPath == .lan)
        #expect(result?.baseURL.absoluteString == "https://192.168.1.42:7749")
        #expect(result?.tlsServerName == "my-server.tail00000.ts.net")
    }

    @Test func fallsBackToPairedForUnpinnedNonTailscaleHost() {
        let credentials = makeCredentials(
            host: "oppi.example.com",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: nil
        )
        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: nil
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: discovered)

        #expect(result?.transportPath == .paired)
        #expect(result?.baseURL.absoluteString == "https://oppi.example.com:7749")
    }

    @Test func fallsBackToPairedForUnpinnedTailscaleHostOnUnexpectedPort() {
        let credentials = makeCredentials(
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: nil
        )
        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 8443,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: nil
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

    @Test func rejectsPlaintextLANEvenWhenDiscoveryIdentityMatches() {
        let credentials = makeCredentials(
            host: "my-server.tail00000.ts.net",
            scheme: .http,
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

        #expect(result == nil)
    }

    @Test func selectsLANWithDiscoveredIPWhenPairedHostIsIPAddress() {
        let credentials = makeCredentials(
            host: "192.168.68.66",
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

        // HTTPS + IP-based paired host: no hostname to preserve, use discovered IP
        #expect(result?.transportPath == .lan)
        #expect(result?.baseURL.absoluteString == "https://192.168.1.42:7749")
    }

    @Test func usesDiscoveredIPAndPortForPinnedLAN() {
        let credentials = makeCredentials(
            host: "my-server.tail00000.ts.net",
            scheme: .https,
            serverFingerprint: "sha256:SERVERFINGERPRINTABCDEF",
            tlsFingerprint: "sha256:TLSFINGERPRINTABCDEF"
        )

        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 8443,
            serverFingerprintPrefix: "SERVERFINGERPRINT",
            tlsCertFingerprintPrefix: "TLSFINGERPRINT"
        )

        let result = LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: discovered)

        #expect(result?.transportPath == .lan)
        #expect(result?.baseURL.absoluteString == "https://192.168.1.42:8443")
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
        #expect(result?.baseURL.absoluteString == "https://192.168.1.42:7749")
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
