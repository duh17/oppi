import Foundation
import Security

enum KeychainCredentialMergeError: LocalizedError, Equatable {
    case itemNotFound
    case corruptRecord
    case readFailed(OSStatus)
    case writeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            "Paired server record not found in Keychain"
        case .corruptRecord:
            "Paired server record could not be decoded"
        case .readFailed(let status):
            "Keychain read failed: \(status)"
        case .writeFailed(let status):
            "Keychain write failed: \(status)"
        }
    }
}

/// Merges one production HTTPS refresh into the latest shared Keychain record.
/// The app-group flock spans read/modify/write, so another process cannot lose
/// a token update or replace fields from a newer record.
enum KeychainDeviceCredentialMerger {
    static func mergeRefresh(
        serverId: String,
        accessToken: String,
        expiresAt: Int64,
        refreshChallenge: DeviceAuthChallenge?
    ) throws -> DeviceCredential {
        let container = try CrossProcessFileLock.appGroupContainer(
            identifier: SharedConstants.appGroupIdentifier
        )

        return try CrossProcessFileLock.withLock(serverId: serverId, container: container) {
            guard var object = try loadRawObject(serverId: serverId) else {
                throw KeychainCredentialMergeError.itemNotFound
            }
            guard let current = decodeCredential(object["deviceCredential"]) else {
                throw KeychainCredentialMergeError.corruptRecord
            }

            let updated = current.updatingAccessToken(
                accessToken,
                expiresAt: expiresAt,
                refreshChallenge: refreshChallenge
            )
            object["deviceCredential"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(updated)
            )
            object["token"] = ""
            try writeObject(object, serverId: serverId)
            return updated
        }
    }

    private static func baseQuery(serverId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecAttrAccount as String: "\(SharedConstants.serverAccountPrefix)\(serverId)",
        ]
    }

    private static func loadRawObject(serverId: String) throws -> [String: Any]? {
        var query = baseQuery(serverId: serverId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainCredentialMergeError.readFailed(status)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KeychainCredentialMergeError.corruptRecord
        }
        return object
    }

    private static func writeObject(_ object: [String: Any], serverId: String) throws {
        let query = baseQuery(serverId: serverId)
        let data = try JSONSerialization.data(withJSONObject: object)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainCredentialMergeError.itemNotFound
            }
            throw KeychainCredentialMergeError.writeFailed(status)
        }
    }

    private static func decodeCredential(_ value: Any?) -> DeviceCredential? {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? JSONDecoder().decode(DeviceCredential.self, from: data)
    }
}
