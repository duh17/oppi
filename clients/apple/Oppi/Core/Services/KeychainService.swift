import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Keychain")

/// Secure storage for server credentials in the iOS Keychain.
///
/// Items are stored in the shared App Group keychain access group so
/// the widget extension can read them for Live Activity intent actions.
///
/// Legacy items in the app's default keychain group remain readable and are
/// migrated into the shared group on load so app extensions can use existing
/// pairings without asking the user to pair again.
enum KeychainService {
    private static let service = SharedConstants.keychainService
    private static let accessGroup = SharedConstants.keychainAccessGroup
    private static let serverAccountPrefix = SharedConstants.serverAccountPrefix

    // MARK: - Save / Delete

    /// Save a paired server to Keychain (shared access group).
    ///
    /// Update-in-place: the existing item is replaced via `SecItemUpdate`;
    /// `SecItemAdd` runs only when the item is genuinely absent. The
    /// delete-before-add pattern is avoided so a concurrent process never
    /// observes a window where the only stored record is missing.
    ///
    /// The write is serialized across processes with an advisory `flock` and
    /// merges the incoming `deviceCredential` against the latest stored record
    /// (freshest per-transport token wins), so a stale full-record writer in
    /// another process cannot roll back a token it never observed.
    static func saveServer(
        _ server: PairedServer,
        replacingStoredDeviceCredential: Bool = false
    ) throws {
        let container = try CrossProcessFileLock.appGroupContainer(
            identifier: SharedConstants.appGroupIdentifier
        )
        try CrossProcessFileLock.withLock(serverId: server.id, container: container) {
            try saveServerLocked(
                server,
                replacingStoredDeviceCredential: replacingStoredDeviceCredential
            )
        }
    }

    private static func saveServerLocked(
        _ server: PairedServer,
        replacingStoredDeviceCredential: Bool = false
    ) throws {
        var toWrite = server
        let account = serverAccount(for: server.id)
        if let latest = loadServerFromGroup(account: account, accessGroup: accessGroup),
           let stored = latest.deviceCredential {
            if let incoming = toWrite.deviceCredential {
                let merged = incoming.freshestMerge(with: stored)
                toWrite.deviceCredential = merged
                if !merged.accessToken.isEmpty {
                    toWrite.token = ""
                }
            } else if replacingStoredDeviceCredential {
                // User-initiated pair: persist the incoming token and drop the
                // stored at_ so a fresh dt_ is not pinned to a dead credential.
                toWrite.deviceCredential = nil
            } else {
                // A leftover dt_ writer must not wipe a replacement already
                // persisted by migrate. Keep the stored at_ and clear dt_.
                toWrite.deviceCredential = stored
                toWrite.token = ""
            }
        }

        let data = try JSONEncoder().encode(toWrite)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(
            sharedQuery(account: account) as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.saveFailed(updateStatus)
        }

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

    // periphery:ignore - used by ConnectionCoordinatorTests via @testable import
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
    /// 1. Uses stored server IDs when available (fast path).
    /// 2. Discovery scans both shared-group and any-group keychain entries.
    /// 3. Legacy entries are migrated to the shared group for extension access.
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

        // Discovery: scan both shared-group and any-group so mixed states
        // (some migrated, some legacy) still discover and heal correctly.
        let sharedDiscovered = discoverServers(inAccessGroup: accessGroup)
        let anyGroupDiscovered = discoverServersAnyGroup()

        var discoveredById: [String: PairedServer] = [:]
        for server in sharedDiscovered {
            discoveredById[server.id] = server
        }

        var migratedCount = 0
        for server in anyGroupDiscovered {
            if discoveredById[server.id] == nil {
                discoveredById[server.id] = server
            }

            if migrateToSharedGroupIfNeeded(server) {
                migratedCount += 1
            }
        }

        if migratedCount > 0 {
            logger.error("Found \(migratedCount) server(s) in legacy keychain group, re-saving to shared group")
        }

        let discovered = discoveredById.values.sorted { $0.sortOrder < $1.sortOrder }

        if !discovered.isEmpty {
            let ids = discovered.map(\.id)
            SharedConstants.sharedDefaults.set(ids, forKey: SharedConstants.pairedServerIdsKey)
            UserDefaults.standard.set(ids, forKey: SharedConstants.pairedServerIdsKey)
        }
        return discovered
    }

    /// Explicitly migrate legacy keychain entries into the shared group.
    /// Call this when the user enables Live Activities.
    @discardableResult
    static func migrateLegacyServersToSharedGroup() -> Int {
        var migratedCount = 0
        for server in discoverServersAnyGroup() where migrateToSharedGroupIfNeeded(server) {
            migratedCount += 1
        }

        if migratedCount > 0 {
            logger.error("Found \(migratedCount) server(s) in legacy keychain group, re-saving to shared group")
        }

        return migratedCount
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
            if migrateToSharedGroupIfNeeded(server) {
                logger.error("Found server \(id.prefix(8), privacy: .public) in legacy group, re-saving to shared")
            }
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

    @discardableResult
    private static func migrateToSharedGroupIfNeeded(_ server: PairedServer) -> Bool {
        let account = serverAccount(for: server.id)
        guard loadServerFromGroup(account: account, accessGroup: accessGroup) == nil else {
            return false
        }

        do {
            try saveServer(server)
            return true
        } catch {
            logger.error(
                "Failed to migrate server \(server.id.prefix(8), privacy: .public) to shared keychain: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
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

enum KeychainError: LocalizedError, Equatable {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed: \(status)"
        }
    }
}
