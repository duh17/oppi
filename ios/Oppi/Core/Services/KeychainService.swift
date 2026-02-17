import Foundation
import Security

/// Secure storage for server credentials in the iOS Keychain.
///
/// Each paired server is stored as a separate Keychain item keyed by
/// its Ed25519 fingerprint.
enum KeychainService {
    private static let service = AppIdentifiers.subsystem

    // Multi-server account prefix
    private static let serverAccountPrefix = "server-"

    // MARK: - Multi-Server

    /// Save a paired server to Keychain.
    static func saveServer(_ server: PairedServer) throws {
        let data = try JSONEncoder().encode(server)
        let account = serverAccount(for: server.id)

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load all paired servers from Keychain.
    ///
    /// Primary: uses `pairedServerIds` UserDefaults index for ordering.
    /// Fallback: if UserDefaults is empty (e.g. after app reinstall, since
    /// Keychain persists but UserDefaults doesn't), scans Keychain directly
    /// for all `server-*` entries and rebuilds the index.
    static func loadServers() -> [PairedServer] {
        let ids = UserDefaults.standard.stringArray(forKey: "pairedServerIds")

        if let ids, !ids.isEmpty {
            // Fast path: load in index order
            var servers: [PairedServer] = []
            for id in ids {
                if let server = loadServer(id: id) {
                    servers.append(server)
                }
            }
            return servers
        }

        // Fallback: scan Keychain for all server entries (survives reinstall)
        let discovered = discoverAllServers()
        if !discovered.isEmpty {
            // Rebuild the UserDefaults index
            let ids = discovered.map(\.id)
            UserDefaults.standard.set(ids, forKey: "pairedServerIds")
        }
        return discovered
    }

    /// Scan Keychain for all items matching the server account prefix.
    /// Used to recover after app reinstall wipes UserDefaults.
    private static func discoverAllServers() -> [PairedServer] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

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

    /// Load a single server by fingerprint ID.
    static func loadServer(id: String) -> PairedServer? {
        let account = serverAccount(for: id)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(PairedServer.self, from: data)
    }

    /// Delete a paired server from Keychain.
    static func deleteServer(id: String) {
        let account = serverAccount(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Delete ALL server entries from Keychain.
    ///
    /// Used by tests to ensure a clean slate. Not for production use.
    static func deleteAllServers() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func serverAccount(for id: String) -> String {
        "\(serverAccountPrefix)\(id)"
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
