import Testing
import Foundation
@testable import Oppi

@Suite("KeychainService", .serialized)
struct KeychainServiceTests {

    private func makeServer(fingerprint: String) -> PairedServer? {
        let creds = ServerCredentials(
            host: "192.168.1.10", port: 7749, token: "sk_test123", name: "Test",
            serverFingerprint: "sha256:\(fingerprint)"
        )
        return PairedServer(from: creds, sortOrder: 0)
    }

    // MARK: - Multi-Server CRUD

    @Test func saveAndLoadServer() throws {
        let fp = UUID().uuidString
        defer { KeychainService.deleteServer(id: "sha256:\(fp)") }

        guard let server = makeServer(fingerprint: fp) else {
            Issue.record("Failed to create PairedServer")
            return
        }

        try KeychainService.saveServer(server)
        let loaded = KeychainService.loadServer(id: server.id)
        #expect(loaded != nil)
        #expect(loaded?.host == "192.168.1.10")
        #expect(loaded?.port == 7749)
    }

    @Test func deleteRemovesServer() throws {
        let fp = UUID().uuidString
        guard let server = makeServer(fingerprint: fp) else {
            Issue.record("Failed to create PairedServer")
            return
        }

        try KeychainService.saveServer(server)
        KeychainService.deleteServer(id: server.id)
        #expect(KeychainService.loadServer(id: server.id) == nil)
    }

    @Test func loadServersDoesNotCrash() {
        _ = KeychainService.loadServers()
    }

    // MARK: - KeychainError

    @Test func keychainErrorDescription() {
        let err = KeychainError.saveFailed(-25299)
        #expect(err.errorDescription?.contains("-25299") == true)
    }
}
