import Testing
import Foundation
import Security
@testable import Oppi

@Suite("KeychainService", .serialized)
struct KeychainServiceTests {

    private func makeServer(fingerprint: String, sortOrder: Int = 0) -> PairedServer? {
        let creds = ServerCredentials(
            host: "192.168.1.10", port: 7749, token: "sk_test123", name: "Test",
            serverFingerprint: "sha256:\(fingerprint)"
        )
        return PairedServer(from: creds, sortOrder: sortOrder)
    }

    /// Clean up ALL keychain items for a given server ID (all groups).
    private func cleanupAll(serverId: String) {
        let account = "\(SharedConstants.serverAccountPrefix)\(serverId)"
        // Unscoped delete removes from all accessible groups
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Sets both paired-server indexes; the returned closure restores them.
    private func replacePairedServerIndex(with ids: [String]) -> () -> Void {
        let key = SharedConstants.pairedServerIdsKey
        let shared = SharedConstants.sharedDefaults.stringArray(forKey: key)
        let standard = UserDefaults.standard.stringArray(forKey: key)
        SharedConstants.sharedDefaults.set(ids, forKey: key)
        UserDefaults.standard.set(ids, forKey: key)
        return {
            SharedConstants.sharedDefaults.set(shared, forKey: key)
            UserDefaults.standard.set(standard, forKey: key)
        }
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
        let loaded = try KeychainService.loadServer(id: server.id)
        #expect(loaded != nil)
        #expect(loaded?.host == "192.168.1.10")
        #expect(loaded?.port == 7749)
    }

    @Test func saveServerUpdatesInPlaceWithoutOrphaningOrDuplicating() throws {
        let fp = UUID().uuidString
        let id = "sha256:\(fp)"
        defer { cleanupAll(serverId: id) }

        guard let server = makeServer(fingerprint: fp) else {
            Issue.record("Failed to create PairedServer")
            return
        }
        try KeychainService.saveServer(server)

        // Update the SAME account: this must take the update-in-place path
        // (never delete-before-add) and replace the stored value.
        let updatedCreds = ServerCredentials(
            host: "10.0.0.9", port: 7749, token: "sk_updated", name: "Updated",
            serverFingerprint: id
        )
        let updated = try #require(PairedServer(from: updatedCreds))
        try KeychainService.saveServer(updated)

        // The item survived the update (no delete-before-add data loss) and the
        // stored value is the replacement.
        let reloaded = try #require(try KeychainService.loadServer(id: id))
        #expect(reloaded.host == "10.0.0.9")
        #expect(reloaded.token == "sk_updated")

        // The indexed load returns exactly one server for this account.
        let restoreIndex = replacePairedServerIndex(with: [id])
        defer { restoreIndex() }
        let matches = try KeychainService.loadServers().filter { $0.id == id }
        #expect(matches.count == 1)
    }

    /// Paired servers come only from the id index. A Keychain item the index
    /// does not name (a reinstall wipes the index, not the Keychain) is not
    /// discovered, and the load never rewrites the index.
    @Test func loadServersReadsOnlyTheIdIndex() throws {
        let unindexed = try #require(makeServer(fingerprint: UUID().uuidString))
        let missingId = "sha256:missing-\(UUID().uuidString)"
        defer { cleanupAll(serverId: unindexed.id) }
        try KeychainService.saveServer(unindexed)

        let restoreIndex = replacePairedServerIndex(with: [missingId])
        defer { restoreIndex() }

        let loaded = try KeychainService.loadServers()

        #expect(!loaded.contains { $0.id == unindexed.id })
        #expect(SharedConstants.sharedDefaults.stringArray(forKey: SharedConstants.pairedServerIdsKey) == [missingId])
    }

    /// Only `errSecItemNotFound` means absent. Any other failure, such as the
    /// locked-device `errSecInteractionNotAllowed`, must not read as "not paired".
    @Test func onlyItemNotFoundReadsAsAbsent() throws {
        #expect(try PairedServerKeychain.decode(PairedServer.self, status: errSecItemNotFound, result: nil) == nil)
        #expect(throws: PairedServerKeychain.ReadFailed(status: errSecInteractionNotAllowed)) {
            try PairedServerKeychain.decode(PairedServer.self, status: errSecInteractionNotAllowed, result: nil)
        }
        #expect(throws: PairedServerKeychain.ReadFailed(status: errSecAuthFailed)) {
            try PairedServerKeychain.decode(PairedServer.self, status: errSecAuthFailed, result: nil)
        }

        let server = try #require(makeServer(fingerprint: "lookup-success"))
        let data = try JSONEncoder().encode(server) as NSData
        #expect(try PairedServerKeychain.decode(PairedServer.self, status: errSecSuccess, result: data)?.id == server.id)
    }

    @Test func leftoverDtPersistAfterMigrateKeepsReplacementAccessToken() throws {
        let fp = UUID().uuidString
        let id = "sha256:\(fp)"
        defer { cleanupAll(serverId: id) }

        let leftoverCreds = ServerCredentials(
            host: "pairing.example.test",
            port: 7749,
            token: "dt_leftover",
            name: "Studio",
            scheme: .https,
            serverFingerprint: id
        )
        let leftover = try #require(PairedServer(from: leftoverCreds))
        try KeychainService.saveServer(leftover)

        let replacement = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_replacement",
            expiresAt: 2_000_000,
            refreshChallenge: nil
        )
        let migratedCreds = leftoverCreds.withDeviceCredential(replacement)
        let migrated = try #require(PairedServer(from: migratedCreds))
        try KeychainService.saveServer(migrated)

        // A stale leftover writer must not restore revoked dt_ or drop at_.
        try KeychainService.saveServer(leftover)

        let reloaded = try #require(try KeychainService.loadServer(id: id))
        #expect(reloaded.deviceCredential?.accessToken == "at_replacement")
        #expect(reloaded.token.isEmpty)
        #expect(reloaded.credentials.effectiveAccessToken == "at_replacement")
    }

    @Test func userInitiatedPairSaveReplacesStoredAccessToken() throws {
        let fp = UUID().uuidString
        let id = "sha256:\(fp)"
        defer { cleanupAll(serverId: id) }

        let leftoverCreds = ServerCredentials(
            host: "pairing.example.test",
            port: 7749,
            token: "dt_leftover",
            name: "Studio",
            scheme: .https,
            serverFingerprint: id
        )
        let leftover = try #require(PairedServer(from: leftoverCreds))
        try KeychainService.saveServer(leftover)

        let replacement = DeviceCredential(
            deviceId: "dev_1",
            accessToken: "at_replacement",
            expiresAt: 2_000_000,
            refreshChallenge: nil
        )
        try KeychainService.saveServer(
            try #require(PairedServer(from: leftoverCreds.withDeviceCredential(replacement)))
        )

        let freshPair = try #require(PairedServer(from: leftoverCreds.withAuthToken("dt_fresh_pair")))
        try KeychainService.saveServer(freshPair, replacingStoredDeviceCredential: true)

        let reloaded = try #require(try KeychainService.loadServer(id: id))
        #expect(reloaded.deviceCredential == nil)
        #expect(reloaded.token == "dt_fresh_pair")
        #expect(reloaded.credentials.effectiveAccessToken == "dt_fresh_pair")
    }

    @Test func deleteRemovesServer() throws {
        let fp = UUID().uuidString
        guard let server = makeServer(fingerprint: fp) else {
            Issue.record("Failed to create PairedServer")
            return
        }

        try KeychainService.saveServer(server)
        KeychainService.deleteServer(id: server.id)
        #expect(try KeychainService.loadServer(id: server.id) == nil)
    }

    // MARK: - KeychainError

    @Test func keychainErrorDescription() {
        let err = KeychainError.saveFailed(-25299)
        #expect(err.errorDescription?.contains("-25299") == true)
    }
}
