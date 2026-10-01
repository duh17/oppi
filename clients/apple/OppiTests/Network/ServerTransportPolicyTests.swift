import Foundation
import Testing
@testable import Oppi

@Suite("Server transport policy")
struct ServerTransportPolicyTests {
    @Test func automaticUsesHTTPSOnly() throws {
        let candidates = try ServerTransportPlanResolver.candidates(
            credentials: makeCredentials(),
            discoveredLANEndpoint: nil
        )

        #expect(candidates.count == 1)
        #expect(candidates[0].baseURL.scheme == "https")
    }

    @Test func verifiedLANHTTPSPrecedesPairedHTTPSOnWiFi() throws {
        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 443,
            serverFingerprintPrefix: "server",
            tlsCertFingerprintPrefix: nil
        )
        let candidates = try ServerTransportPlanResolver.candidates(
            credentials: makeCredentials(),
            discoveredLANEndpoint: discovered,
            pathType: "wifi"
        )

        #expect(candidates.map(\.transportPath) == [.lan, .paired])
        #expect(candidates.allSatisfy { $0.baseURL.scheme == "https" })
    }

    @Test(arguments: ["cell", "unknown", "other"]) func nonLocalPathsSkipLAN(path: String) throws {
        let candidates = try ServerTransportPlanResolver.candidates(
            credentials: makeCredentials(),
            discoveredLANEndpoint: LANDiscoveredEndpoint(host: "192.168.1.42", port: 443, serverFingerprintPrefix: "server", tlsCertFingerprintPrefix: nil),
            pathType: path
        )
        #expect(candidates.map(\.transportPath) == [.paired])
    }

    @Test func plaintextHTTPIsRejected() throws {
        let credentials = ServerCredentials(
            host: "server.example.test",
            port: 7749,
            token: "dt_test",
            name: "Test",
            scheme: .http
        )

        #expect(throws: APIError.self) {
            _ = try ServerTransportPlanResolver.candidates(
                credentials: credentials,
                discoveredLANEndpoint: nil
            )
        }
    }

    @Test func networkPathRouteKindDistinguishesSocksFromSystemVpn() {
        #expect(
            NetworkPathTelemetry.routeKind(
                transportPath: .lan,
                host: "mac-studio.tail00000.ts.net",
                socksPublished: true
            ) == .lan
        )
        #expect(
            NetworkPathTelemetry.routeKind(
                transportPath: .paired,
                host: "mac-studio.tail00000.ts.net",
                socksPublished: true
            ) == .socks
        )
        #expect(
            NetworkPathTelemetry.routeKind(
                transportPath: .paired,
                host: "mac-studio.tail00000.ts.net",
                socksPublished: false
            ) == .systemVpn
        )
        #expect(
            NetworkPathTelemetry.routeKind(
                transportPath: .paired,
                host: "192.168.1.9",
                socksPublished: true
            ) == .paired
        )
    }

    @Test func networkPathHostKindClassifiesTailscaleAndLAN() {
        #expect(NetworkPathTelemetry.hostKind(for: "mac-mini.tail00000.ts.net") == .tailscale)
        #expect(NetworkPathTelemetry.hostKind(for: "Mac-Studio.local") == .local)
        #expect(NetworkPathTelemetry.hostKind(for: "192.168.68.66") == .ip)
        #expect(NetworkPathTelemetry.hostKind(for: "example.com") == .dns)
    }

    private func makeCredentials() -> ServerCredentials {
        ServerCredentials(
            host: "server.tail00000.ts.net",
            port: 443,
            token: "dt_test",
            name: "Test",
            scheme: .https,
            serverFingerprint: "sha256:server"
        )
    }
}
