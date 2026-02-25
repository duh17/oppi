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

    /// Save an item to the legacy keychain location (no access group).
    /// This simulates what the pre-migration app did.
    private func saveLegacyKeychainItem(_ server: PairedServer) throws {
        let data = try JSONEncoder().encode(server)
        let account = "\(SharedConstants.serverAccountPrefix)\(server.id)"

        // Delete any existing legacy item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Save WITHOUT kSecAttrAccessGroup — goes to app's default group
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            Issue.record("Failed to save legacy keychain item: \(status)")
            return
        }
    }

    /// Check if an item exists in the shared access group.
    private func existsInSharedGroup(serverId: String) -> Bool {
        let account = "\(SharedConstants.serverAccountPrefix)\(serverId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
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

    // MARK: - Access Group Migration

    /// Simulates an existing user upgrading: items exist in the legacy
    /// (default) keychain group. After calling `loadServer(id:)`, the item
    /// should be transparently migrated to the shared access group without
    /// requiring the user to re-pair.
    @Test func legacyItemMigratesToSharedGroupOnLoad() throws {
        let fp = UUID().uuidString
        guard let server = makeServer(fingerprint: fp) else {
            Issue.record("Failed to create PairedServer")
            return
        }
        defer { cleanupAll(serverId: server.id) }

        // 1. Save to legacy location (no access group), clear shared group
        try saveLegacyKeychainItem(server)
        KeychainService.deleteServer(id: server.id) // only deletes from shared group

        // 2. Shared group should NOT have the item yet
        #expect(!existsInSharedGroup(serverId: server.id),
                "Shared group should not contain item before migration")

        // 3. loadServer should find via any-group fallback and migrate
        let loaded = KeychainService.loadServer(id: server.id)
        #expect(loaded != nil, "loadServer must find legacy items — re-pairing should never be required")
        #expect(loaded?.host == "192.168.1.10")
        #expect(loaded?.port == 7749)

        // 4. After migration, item should now exist in shared group
        #expect(existsInSharedGroup(serverId: server.id),
                "Item should be migrated to shared group after load")
    }

    /// Like the per-ID test but using the discovery path in `loadServers()`.
    /// Covers the case where UserDefaults is empty (e.g. app reinstall but
    /// Keychain persists).
    @Test func legacyDiscoveryMigratesToSharedGroup() throws {
        let fp = UUID().uuidString
        guard let server = makeServer(fingerprint: fp) else {
            Issue.record("Failed to create PairedServer")
            return
        }
        defer { cleanupAll(serverId: server.id) }

        // Save to legacy, clear shared group and UserDefaults index
        try saveLegacyKeychainItem(server)
        KeychainService.deleteServer(id: server.id)
        UserDefaults.standard.removeObject(forKey: SharedConstants.pairedServerIdsKey)
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.pairedServerIdsKey)

        // loadServers should discover and migrate
        let servers = KeychainService.loadServers()
        let found = servers.first(where: { $0.id == server.id })
        #expect(found != nil, "loadServers discovery must find legacy items")

        // Verify migrated to shared group
        #expect(existsInSharedGroup(serverId: server.id),
                "Discovery should migrate legacy items to shared group")

        // Verify UserDefaults index was rebuilt
        let sharedIds = SharedConstants.sharedDefaults.stringArray(forKey: SharedConstants.pairedServerIdsKey)
        #expect(sharedIds?.contains(server.id) == true,
                "Shared UserDefaults index should be rebuilt after discovery")
    }

    /// After migration, the migrated item should be loadable from the shared
    /// group directly (fast path), without needing the any-group fallback.
    @Test func migratedItemLoadableFromSharedGroupDirectly() throws {
        let fp = UUID().uuidString
        guard let server = makeServer(fingerprint: fp) else {
            Issue.record("Failed to create PairedServer")
            return
        }
        defer { cleanupAll(serverId: server.id) }

        // Save via the normal (new) path — goes to shared group
        try KeychainService.saveServer(server)

        // Should be in shared group
        #expect(existsInSharedGroup(serverId: server.id))

        // Load should succeed
        let loaded = KeychainService.loadServer(id: server.id)
        #expect(loaded != nil)
        #expect(loaded?.host == server.host)
    }

    // MARK: - KeychainError

    @Test func keychainErrorDescription() {
        let err = KeychainError.saveFailed(-25299)
        #expect(err.errorDescription?.contains("-25299") == true)
    }
}
