import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Keychain")

/// Secure storage for server credentials in the iOS Keychain.
///
/// Items are stored in the shared App Group keychain access group so
/// the widget extension can read them for Live Activity intent actions.
///
/// On first launch after the access-group migration, `loadServers()`
/// automatically detects items in the app's default group and re-saves
/// them to the shared group. No separate migration step needed.
enum KeychainService {
    private static let service = SharedConstants.keychainService
    private static let accessGroup = SharedConstants.keychainAccessGroup
    private static let serverAccountPrefix = SharedConstants.serverAccountPrefix

    // MARK: - Save / Delete

    /// Save a paired server to Keychain (shared access group).
    static func saveServer(_ server: PairedServer) throws {
        let data = try JSONEncoder().encode(server)
        let account = serverAccount(for: server.id)

        // Delete from shared group only
        SecItemDelete(sharedQuery(account: account) as CFDictionary)

        var addQuery = sharedQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Delete a paired server from Keychain (shared group).
    static func deleteServer(id: String) {
        let account = serverAccount(for: id)
        SecItemDelete(sharedQuery(account: account) as CFDictionary)
    }

    /// Delete ALL server entries. Test use only.
    static func deleteAllServers() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Load

    /// Load all paired servers from Keychain.
    ///
    /// 1. Tries shared group (fast path for post-migration installs).
    /// 2. Falls back to any-group scan (finds legacy items).
    /// 3. Re-saves any legacy items to the shared group for extension access.
    static func loadServers() -> [PairedServer] {
        syncUserDefaultsIndex()

        let ids = SharedConstants.sharedDefaults.stringArray(forKey: SharedConstants.pairedServerIdsKey)
            ?? UserDefaults.standard.stringArray(forKey: SharedConstants.pairedServerIdsKey)

        if let ids, !ids.isEmpty {
            var servers: [PairedServer] = []
            for id in ids {
                if let server = loadServer(id: id) {
                    servers.append(server)
                }
            }
            if !servers.isEmpty {
                return servers
            }
            // IDs exist but no keychain items found — fall through to discovery.
        }

        // Discovery: scan shared group first, then any-group fallback.
        var discovered = discoverServers(inAccessGroup: accessGroup)
        if discovered.isEmpty {
            discovered = discoverServersAnyGroup()
            if !discovered.isEmpty {
                logger.error("Found \(discovered.count) server(s) in legacy keychain group, re-saving to shared group")
                for server in discovered {
                    try? saveServer(server)
                }
            }
        }

        if !discovered.isEmpty {
            let ids = discovered.map(\.id)
            SharedConstants.sharedDefaults.set(ids, forKey: SharedConstants.pairedServerIdsKey)
            UserDefaults.standard.set(ids, forKey: SharedConstants.pairedServerIdsKey)
        }
        return discovered
    }

    /// Load a single server by fingerprint ID.
    /// Tries shared group first, falls back to any-group.
    static func loadServer(id: String) -> PairedServer? {
        let account = serverAccount(for: id)

        // Shared group (fast path)
        if let server = loadServerFromGroup(account: account, accessGroup: accessGroup) {
            return server
        }

        // Any-group fallback (legacy items)
        if let server = loadServerFromGroup(account: account, accessGroup: nil) {
            logger.error("Found server \(id.prefix(8), privacy: .public) in legacy group, re-saving to shared")
            try? saveServer(server)
            return server
        }

        return nil
    }

    // MARK: - Private Helpers

    private static func loadServerFromGroup(account: String, accessGroup: String?) -> PairedServer? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(PairedServer.self, from: data)
    }

    private static func discoverServers(inAccessGroup group: String) -> [PairedServer] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: group,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        return decodeServerItems(query: query)
    }

    private static func discoverServersAnyGroup() -> [PairedServer] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        return decodeServerItems(query: query)
    }

    private static func decodeServerItems(query: [String: Any]) -> [PairedServer] {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }

        var servers: [PairedServer] = []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(serverAccountPrefix),
                  let data = item[kSecValueData as String] as? Data,
                  let server = try? JSONDecoder().decode(PairedServer.self, from: data)
            else { continue }
            servers.append(server)
        }
        servers.sort { $0.sortOrder < $1.sortOrder }
        return servers
    }

    /// Ensure the shared UserDefaults suite has the server ID index.
    /// Copies from standard defaults if missing.
    private static func syncUserDefaultsIndex() {
        let sharedDefaults = SharedConstants.sharedDefaults
        if sharedDefaults.stringArray(forKey: SharedConstants.pairedServerIdsKey) == nil,
           let legacyIds = UserDefaults.standard.stringArray(forKey: SharedConstants.pairedServerIdsKey) {
            sharedDefaults.set(legacyIds, forKey: SharedConstants.pairedServerIdsKey)
        }
    }

    private static func serverAccount(for id: String) -> String {
        "\(serverAccountPrefix)\(id)"
    }

    private static func sharedQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed: \(status)"
        }
    }
}
