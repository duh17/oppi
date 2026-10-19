import Foundation
import Security

/// Reads paired-server records from the shared Keychain group by id. The app
/// and the share extension read through this one rule: only
/// `errSecItemNotFound` means a server is not stored. Items are
/// `WhenUnlockedThisDeviceOnly`, so a read while the device is locked fails,
/// and that must never read as "no paired servers".
enum PairedServerKeychain {
    /// A paired-server record could not be read (for example, the device is locked).
    struct ReadFailed: LocalizedError, Equatable {
        let status: OSStatus

        var errorDescription: String? {
            "Keychain read failed: \(status)"
        }
    }

    /// The records for `ids`, in order. An id that is not stored is skipped.
    static func records<Record: Decodable>(_ type: Record.Type, ids: [String]) throws -> [Record] {
        try ids.compactMap { try record(type, id: $0) }
    }

    /// The record for one server id, or nil when it is not stored.
    static func record<Record: Decodable>(_ type: Record.Type, id: String) throws -> Record? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecAttrAccount as String: "\(SharedConstants.serverAccountPrefix)\(id)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try decode(type, status: status, result: result)
    }

    /// Maps one `SecItemCopyMatching` lookup. A stored record that no longer
    /// decodes stays unusable after unlock too, so it is skipped, not thrown.
    static func decode<Record: Decodable>(
        _ type: Record.Type,
        status: OSStatus,
        result: AnyObject?
    ) throws -> Record? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ReadFailed(status: status) }
        guard let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
