import Foundation
import OSLog
import Security

/// Reads paired-server records from the shared Keychain group by id. The app
/// and the share extension read through this one rule: only
/// `errSecItemNotFound` means a server is not stored. Items are
/// `WhenUnlockedThisDeviceOnly`, so a read while the device is locked fails,
/// and that must never read as "no paired servers".
enum PairedServerKeychain {
    private static let logger = Logger(subsystem: "dev.chenda.Oppi", category: "PairedServerKeychain")

    /// A paired-server record could not be read (for example, the device is locked).
    struct ReadFailed: LocalizedError, Equatable {
        let status: OSStatus

        var errorDescription: String? {
            "Keychain read failed: \(status)"
        }
    }

    /// The readable records, and the ids whose stored record could not be
    /// read. Those ids are still paired: an index write must keep them.
    struct Read<Record> {
        var records: [Record]
        var unreadableIds: [String]
    }

    /// The records for `ids`, in order. An id that is not stored is skipped.
    static func records<Record: Decodable>(_ type: Record.Type, ids: [String]) throws -> [Record] {
        try read(type, ids: ids).records
    }

    /// The records for `ids`, in order, with the ids that could not be read.
    static func read<Record: Decodable>(_ type: Record.Type, ids: [String]) throws -> Read<Record> {
        try read(ids: ids) { try record(type, id: $0) }
    }

    /// `lookup` reads one id: nil when it is not stored.
    ///
    /// A locked device (`errSecInteractionNotAllowed`) fails the whole read:
    /// every record is unreadable then. Any other failure is that one
    /// record's: it is skipped and reported in `unreadableIds`, so one bad
    /// item cannot hide every other server. When nothing is readable and
    /// something failed, the read fails: an unreadable list is never "no
    /// paired servers".
    static func read<Record>(
        ids: [String],
        lookup: (String) throws -> Record?
    ) throws -> Read<Record> {
        var result = Read<Record>(records: [], unreadableIds: [])
        var firstFailure: ReadFailed?
        for id in ids {
            do {
                if let record = try lookup(id) {
                    result.records.append(record)
                }
            } catch let failure as ReadFailed where failure.status != errSecInteractionNotAllowed {
                logger.error(
                    "Skipping unreadable paired server \(id.prefix(16), privacy: .public): \(failure.status, privacy: .public)"
                )
                firstFailure = firstFailure ?? failure
                result.unreadableIds.append(id)
            }
        }
        if result.records.isEmpty, let firstFailure {
            throw firstFailure
        }
        return result
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
