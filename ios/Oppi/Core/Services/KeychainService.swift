import Foundation
import Security

/// Secure storage for server credentials in the iOS Keychain.
///
/// Supports multiple paired servers, each stored as a separate Keychain item
/// keyed by the server's Ed25519 fingerprint.
///
/// Legacy single-credential storage is preserved for migration.
enum KeychainService {
    private static let service = "dev.chenda.Oppi"

    // Legacy single-credential account (pre-multi-server)
    private static let legacyAccount = "server-credentials"

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
    /// Uses the `pairedServerIds` UserDefaults index to discover which
    /// Keychain items to read. Returns them in index order.
    static func loadServers() -> [PairedServer] {
        guard let ids = UserDefaults.standard.stringArray(forKey: "pairedServerIds") else {
            return []
        }

        var servers: [PairedServer] = []
        for id in ids {
            if let server = loadServer(id: id) {
                servers.append(server)
            }
        }
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

    private static func serverAccount(for id: String) -> String {
        "\(serverAccountPrefix)\(id)"
    }

    // MARK: - Legacy Migration

    /// Migrate a legacy single-credential entry to a `PairedServer`.
    ///
    /// Returns the migrated server if migration occurred, `nil` if no
    /// legacy credential exists or migration already happened.
    ///
    /// The legacy Keychain item is deleted after successful migration.
    static func migrateLegacyCredential() -> PairedServer? {
        // Skip if we already have multi-server entries
        if let ids = UserDefaults.standard.stringArray(forKey: "pairedServerIds"), !ids.isEmpty {
            return nil
        }

        // Load legacy credential
        guard let creds = loadLegacyCredentials() else {
            return nil
        }

        // Create PairedServer from legacy credentials
        guard let server = PairedServer(from: creds, sortOrder: 0) else {
            // Credentials lack fingerprint — can't migrate to multi-server.
            // Keep legacy credential in place; user will need to re-pair.
            return nil
        }

        // Save as multi-server entry
        do {
            try saveServer(server)
            // Delete legacy entry
            deleteLegacyCredentials()
            return server
        } catch {
            return nil
        }
    }

    // MARK: - Legacy Single-Credential (kept for migration + backward compat)

    /// Save credentials to Keychain (legacy single-credential format).
    static func saveCredentials(_ credentials: ServerCredentials) throws {
        let data = try JSONEncoder().encode(credentials)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load credentials from Keychain (legacy single-credential format).
    static func loadCredentials() -> ServerCredentials? {
        loadLegacyCredentials()
    }

    /// Delete credentials from Keychain (legacy single-credential format).
    static func deleteCredentials() {
        deleteLegacyCredentials()
    }

    private static func loadLegacyCredentials() -> ServerCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(ServerCredentials.self, from: data)
    }

    private static func deleteLegacyCredentials() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
        ]
        SecItemDelete(query as CFDictionary)
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
