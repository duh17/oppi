import Foundation
import Security

/// Secure storage for server credentials in the iOS Keychain.
///
/// Items are stored in the shared App Group keychain access group so
/// the widget extension can read them for Live Activity intent actions.
///
/// Reads fail closed through `PairedServerKeychain`: only `errSecItemNotFound`
/// means a server is absent.
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
        if let latest = try loadServer(id: server.id),
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

    /// Load the paired servers named by the UserDefaults id index, one query
    /// per id. An id whose item is not found is skipped; the Keychain is never
    /// scanned for servers the index does not name, so a reinstall (index
    /// wiped, Keychain kept) pairs again.
    ///
    /// Throws `PairedServerKeychain.ReadFailed` when the device is locked or
    /// no item can be read. Another item's read failure skips that item and
    /// names it in `unreadableIds`.
    static func loadServers() throws -> PairedServerKeychain.Read<PairedServer> {
        syncUserDefaultsIndex()

        let ids = SharedConstants.sharedDefaults.stringArray(forKey: SharedConstants.pairedServerIdsKey)
            ?? UserDefaults.standard.stringArray(forKey: SharedConstants.pairedServerIdsKey)
            ?? []
        return try PairedServerKeychain.read(PairedServer.self, ids: ids)
    }

    /// Load a single server by fingerprint ID; nil only when it is not stored.
    static func loadServer(id: String) throws -> PairedServer? {
        try PairedServerKeychain.record(PairedServer.self, id: id)
    }

    // MARK: - Private Helpers

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
