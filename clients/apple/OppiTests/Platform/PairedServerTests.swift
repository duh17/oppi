import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping

// MARK: - PairedServer Model

@Suite("PairedServer")
struct PairedServerTests {

    @Test("Init from credentials with fingerprint")
    func initFromCredentialsWithFingerprint() {
        let creds = ServerCredentials(
            host: "my-server.ts.net",
            port: 7749,
            token: "sk_test123",
            name: "my-server",
            scheme: .https,
            serverFingerprint: "sha256:testfp123",
            tlsCertFingerprint: "sha256:leafpin"
        )

        let server = PairedServer(from: creds)
        #expect(server != nil)
        #expect(server?.id == "sha256:testfp123")
        #expect(server?.name == "my-server")
        #expect(server?.host == "my-server.ts.net")
        #expect(server?.port == 7749)
        #expect(server?.resolvedScheme == .https)
        #expect(server?.token == "sk_test123")
        #expect(server?.tlsCertFingerprint == "sha256:leafpin")
        #expect(server?.fingerprint == "sha256:testfp123")
        #expect(server?.sortOrder == 0)
    }

    @Test("Init from credentials without fingerprint returns nil")
    func initFromCredentialsWithoutFingerprint() {
        let creds = ServerCredentials(
            host: "localhost",
            port: 7749,
            token: "sk_test",
            name: "local"
        )

        let server = PairedServer(from: creds)
        #expect(server == nil)
    }

    @Test("Init from credentials with empty fingerprint returns nil")
    func initFromCredentialsWithEmptyFingerprint() {
        let creds = ServerCredentials(
            host: "localhost",
            port: 7749,
            token: "sk_test",
            name: "local",
            serverFingerprint: "   "
        )

        let server = PairedServer(from: creds)
        #expect(server == nil)
    }

    @Test("Derived credentials match")
    func derivedCredentials() {
        let creds = ServerCredentials(
            host: "mac-mini.local",
            port: 8080,
            token: "sk_abc",
            name: "mac-mini",
            scheme: .https,
            serverFingerprint: "sha256:minifp",
            tlsCertFingerprint: "sha256:minileaf"
        )

        let server = PairedServer(from: creds)!
        let derived = server.credentials

        #expect(derived.host == "mac-mini.local")
        #expect(derived.port == 8080)
        #expect(derived.resolvedScheme == .https)
        #expect(derived.token == "sk_abc")
        #expect(derived.name == "mac-mini")
        #expect(derived.serverFingerprint == "sha256:minifp")
        #expect(derived.tlsCertFingerprint == "sha256:minileaf")
    }

    @Test("Update credentials preserves identity and metadata")
    func updateCredentials() {
        let originalCreds = ServerCredentials(
            host: "my-server.ts.net",
            port: 7749,
            token: "sk_old",
            name: "my-server",
            serverFingerprint: "sha256:fp1"
        )

        var server = PairedServer(from: originalCreds, sortOrder: 5)!
        let originalAddedAt = server.addedAt

        let newCreds = ServerCredentials(
            host: "new-host.ts.net",
            port: 9999,
            token: "sk_new",
            name: "renamed-studio",
            scheme: .https,
            serverFingerprint: "sha256:fp1",
            tlsCertFingerprint: "sha256:newleaf"
        )

        server.updateCredentials(from: newCreds)

        // Updated fields
        #expect(server.host == "new-host.ts.net")
        #expect(server.port == 9999)
        #expect(server.resolvedScheme == .https)
        #expect(server.token == "sk_new")
        #expect(server.tlsCertFingerprint == "sha256:newleaf")
        #expect(server.name == "renamed-studio")

        // Preserved fields
        #expect(server.id == "sha256:fp1")
        #expect(server.fingerprint == "sha256:fp1")
        #expect(server.addedAt == originalAddedAt)
        #expect(server.sortOrder == 5)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let creds = ServerCredentials(
            host: "test.local",
            port: 7749,
            token: "sk_roundtrip",
            name: "test-server",
            serverFingerprint: "sha256:roundtrip"
        )

        let original = PairedServer(from: creds, sortOrder: 3)!
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.host == original.host)
        #expect(decoded.port == original.port)
        #expect(decoded.token == original.token)
        #expect(decoded.fingerprint == original.fingerprint)
        #expect(decoded.sortOrder == original.sortOrder)
        // Date precision: within 1 second is fine
        #expect(abs(decoded.addedAt.timeIntervalSince(original.addedAt)) < 1)
    }

    @Test("Decodes payload with legacy badge color field")
    func decodesPayloadWithLegacyBadgeColorField() throws {
        let json = """
        {
          "id": "sha256:minimal",
          "name": "minimal-server",
          "host": "minimal.local",
          "port": 7749,
          "token": "sk_minimal",
          "fingerprint": "sha256:minimal",
          "addedAt": "2026-02-01T00:00:00Z",
          "sortOrder": 0,
          "badgeColor": "green"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PairedServer.self, from: Data(json.utf8))

        #expect(decoded.badgeIcon == nil)
        #expect(decoded.resolvedBadgeIcon == .defaultValue)
        #expect(decoded.routeMode == .automatic)
    }

    @Test("Re-pair preserves the local mode and falls back when it becomes impossible")
    func rePairPreservesRouteModeAndFallsBack() {
        let both = ServerCredentials(
            host: "studio.example.test",
            port: 443,
            token: "dt_both",
            name: "Studio",
            serverFingerprint: "sha256:route-mode",
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "signed-node",
                    alpns: [IrohTunnelProtocol.alpn],
                    addressMode: .nodeId,
                    ticket: nil
                ),
                http: HTTPServerTransport(
                    host: "studio.example.test",
                    port: 443,
                    scheme: .https,
                    tlsCertFingerprint: nil
                )
            )
        )
        var server = PairedServer(from: both)!
        server.routeMode = .irohOnly

        let httpOnly = ServerCredentials(
            host: "studio.example.test",
            port: 443,
            token: "dt_http",
            name: "Studio",
            serverFingerprint: "sha256:route-mode",
            transports: ServerTransports(
                preference: .httpOnly,
                http: HTTPServerTransport(
                    host: "studio.example.test",
                    port: 443,
                    scheme: .https,
                    tlsCertFingerprint: nil
                )
            )
        )
        server.updateCredentials(from: httpOnly)

        #expect(server.routeMode == .irohOnly)
        #expect(server.effectiveRouteMode == .httpsOnly)
    }

    @Test("Equatable compares all fields, not just ID")
    func equatableComparesAllFields() {
        let creds1 = ServerCredentials(
            host: "host-a.local", port: 7749, token: "sk_a", name: "A",
            serverFingerprint: "sha256:same"
        )
        let creds2 = ServerCredentials(
            host: "host-b.local", port: 8080, token: "sk_b", name: "B",
            serverFingerprint: "sha256:same"
        )

        let server1 = PairedServer(from: creds1)!
        let server2 = PairedServer(from: creds2)!

        // Same fingerprint but different fields → not equal
        #expect(server1.id == server2.id)
        #expect(server1 != server2)

        // Identical servers → equal
        let server3 = PairedServer(from: creds1)!
        // addedAt may differ by microseconds, so compare by ID + fields
        #expect(server1.id == server3.id)
        #expect(server1.host == server3.host)
        #expect(server1.token == server3.token)
    }

    @Test("BaseURL defaults to HTTPS")
    func baseURL() {
        let creds = ServerCredentials(
            host: "192.168.1.50", port: 7749, token: "sk_t", name: "LAN",
            serverFingerprint: "sha256:lan"
        )
        let server = PairedServer(from: creds)!
        #expect(server.baseURL?.absoluteString == "https://192.168.1.50:7749")
    }

    @Test("HTTP BaseURL requires explicit scheme")
    func httpBaseURL() {
        let creds = ServerCredentials(
            host: "192.168.1.50",
            port: 7749,
            token: "sk_t",
            name: "LAN",
            scheme: .http,
            serverFingerprint: "sha256:lan"
        )
        let server = PairedServer(from: creds)!
        #expect(server.baseURL?.absoluteString == "http://192.168.1.50:7749")
    }

    @Test("HTTPS BaseURL derived correctly")
    func httpsBaseURL() {
        let creds = ServerCredentials(
            host: "192.168.1.50",
            port: 7749,
            token: "sk_t",
            name: "LAN",
            scheme: .https,
            serverFingerprint: "sha256:lan",
            tlsCertFingerprint: "sha256:leaf"
        )
        let server = PairedServer(from: creds)!
        #expect(server.baseURL?.absoluteString == "https://192.168.1.50:7749")
    }

    @Test("Iroh-only transport metadata stores without HTTP base URL")
    func irohOnlyStorageRoundTrip() throws {
        let iroh = IrohServerTransport(
            version: 2,
            nodeId: "iroh-node-storage",
            alpns: ["oppi/pair/1", "oppi/http/1"],
            addressMode: .nodeId,
            ticket: nil
        )
        let transports = ServerTransports(
            preference: .irohOnly,
            iroh: iroh,
            http: nil
        )
        let creds = ServerCredentials(
            host: "",
            port: 0,
            token: "dt_iroh_storage",
            name: "Iroh Mac",
            scheme: nil,
            serverFingerprint: "sha256:irohstorage",
            tlsCertFingerprint: nil,
            transports: transports
        )

        let original = try #require(PairedServer(from: creds, sortOrder: 7))
        #expect(original.baseURL == nil)
        #expect(original.transports.preference == .irohOnly)
        #expect(original.transports.http == nil)
        #expect(original.transports.iroh == iroh)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: data)
        #expect(decoded.baseURL == nil)
        #expect(decoded.transports.preference == .irohOnly)
        #expect(decoded.transports.http == nil)
        #expect(decoded.transports.iroh == iroh)
        #expect(decoded.sortOrder == 7)

        let derived = decoded.credentials
        #expect(derived.baseURL == nil)
        #expect(derived.transports.preference == .irohOnly)
        #expect(derived.transports.http == nil)
        #expect(derived.transports.iroh == iroh)
        #expect(derived.token == "dt_iroh_storage")
    }
}
