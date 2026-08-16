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

    @Test func discoveredLANHTTPSPrecedesPairedHTTPS() throws {
        let discovered = LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 443,
            serverFingerprintPrefix: "server",
            tlsCertFingerprintPrefix: nil
        )
        let candidates = try ServerTransportPlanResolver.candidates(
            credentials: makeCredentials(),
            discoveredLANEndpoint: discovered
        )

        #expect(candidates.map(\.transportPath) == [.lan, .paired])
        #expect(candidates.allSatisfy { $0.baseURL.scheme == "https" })
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
