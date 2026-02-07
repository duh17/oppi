import Testing
import Foundation
@testable import PiRemote

@Suite("KeychainService", .serialized)
struct KeychainServiceTests {

    private func cleanup() {
        KeychainService.deleteCredentials()
    }

    // MARK: - Save and Load

    @Test func saveAndLoad() throws {
        defer { cleanup() }

        let creds = ServerCredentials(
            host: "192.168.1.10", port: 7749, token: "sk_test123", name: "TestUser"
        )
        try KeychainService.saveCredentials(creds)

        let loaded = KeychainService.loadCredentials()
        #expect(loaded != nil)
        #expect(loaded?.host == "192.168.1.10")
        #expect(loaded?.port == 7749)
        #expect(loaded?.token == "sk_test123")
        #expect(loaded?.name == "TestUser")
    }

    // MARK: - Overwrite

    @Test func saveOverwritesExisting() throws {
        defer { cleanup() }

        let creds1 = ServerCredentials(host: "host1", port: 7749, token: "token1", name: "User1")
        try KeychainService.saveCredentials(creds1)

        let creds2 = ServerCredentials(host: "host2", port: 8080, token: "token2", name: "User2")
        try KeychainService.saveCredentials(creds2)

        let loaded = KeychainService.loadCredentials()
        #expect(loaded?.host == "host2")
        #expect(loaded?.token == "token2")
    }

    // MARK: - Delete

    @Test func deleteRemovesCredentials() throws {
        let creds = ServerCredentials(host: "host", port: 7749, token: "token", name: "User")
        try KeychainService.saveCredentials(creds)

        KeychainService.deleteCredentials()

        let loaded = KeychainService.loadCredentials()
        #expect(loaded == nil)
    }

    // MARK: - Load when empty

    @Test func loadReturnsNilWhenEmpty() {
        cleanup()
        let loaded = KeychainService.loadCredentials()
        #expect(loaded == nil)
    }

    // MARK: - Delete when empty is no-op

    @Test func deleteWhenEmptyIsNoOp() {
        cleanup()
        // Should not crash
        KeychainService.deleteCredentials()
        #expect(KeychainService.loadCredentials() == nil)
    }

    // MARK: - KeychainError

    @Test func keychainErrorDescription() {
        let err = KeychainError.saveFailed(-25299)
        #expect(err.errorDescription?.contains("-25299") == true)
    }
}
