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
            serverFingerprint: "sha256:testfp123"
        )

        let server = PairedServer(from: creds)
        #expect(server != nil)
        #expect(server?.id == "sha256:testfp123")
        #expect(server?.name == "my-server")
        #expect(server?.host == "my-server.ts.net")
        #expect(server?.port == 7749)
        #expect(server?.token == "sk_test123")
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
            serverFingerprint: "sha256:minifp"
        )

        let server = PairedServer(from: creds)!
        let derived = server.credentials

        #expect(derived.host == "mac-mini.local")
        #expect(derived.port == 8080)
        #expect(derived.token == "sk_abc")
        #expect(derived.name == "mac-mini")
        #expect(derived.serverFingerprint == "sha256:minifp")
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
            serverFingerprint: "sha256:fp1"
        )

        server.updateCredentials(from: newCreds)

        // Updated fields
        #expect(server.host == "new-host.ts.net")
        #expect(server.port == 9999)
        #expect(server.token == "sk_new")
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

    @Test("Decodes payload without badge customization")
    func decodesPayloadWithoutBadgeFields() throws {
        let json = """
        {
          "id": "sha256:minimal",
          "name": "minimal-server",
          "host": "minimal.local",
          "port": 7749,
          "token": "sk_minimal",
          "fingerprint": "sha256:minimal",
          "addedAt": "2026-02-01T00:00:00Z",
          "sortOrder": 0
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PairedServer.self, from: Data(json.utf8))

        #expect(decoded.badgeIcon == nil)
        #expect(decoded.badgeColor == nil)
        #expect(decoded.resolvedBadgeIcon == .defaultValue)
        #expect(decoded.resolvedBadgeColor == .defaultValue)
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

    @Test("BaseURL derived correctly")
    func baseURL() {
        let creds = ServerCredentials(
            host: "192.168.1.50", port: 7749, token: "sk_t", name: "LAN",
            serverFingerprint: "sha256:lan"
        )
        let server = PairedServer(from: creds)!
        #expect(server.baseURL?.absoluteString == "http://192.168.1.50:7749")
    }
}
