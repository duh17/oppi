import CryptoKit
import Foundation
import Security

/// Push state the app writes and the Notification Service Extension reads, while the phone
/// may be locked (spec §1, §2.5, §2.6):
///
/// - push keys in the shared keychain group, `AfterFirstUnlockThisDeviceOnly`;
/// - the redaction snapshot and per-key replay windows as App Group files with
///   `completeUntilFirstUserAuthentication` protection.
///
/// Every read failure fails closed: no key means the fallback text, an unreadable snapshot
/// means everything is redacted, an unreadable replay file rejects the push.
enum PushSharedStore {
    // MARK: - Push keys

    struct KeyRecord: Codable, Equatable, Sendable {
        /// 32-byte X-Wing private key seed.
        let seed: Data
        let serverId: String
        /// Raw Ed25519 identity key of that server, checked against its pinned fingerprint.
        let serverPublicKey: Data
        let createdAt: Date

        var keyId: Data {
            get throws {
                let key = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: seed, publicKey: nil)
                return PushEnvelope.keyId(forPublicKey: key.publicKey.rawRepresentation)
            }
        }

        var material: PushKeyMaterial {
            PushKeyMaterial(seed: seed, serverPublicKey: serverPublicKey, serverId: serverId)
        }
    }

    static let keyService = "\(SharedConstants.keychainService).push-key"

    private static func keyQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    static func loadKey(keyId: Data) -> KeyRecord? {
        var query = keyQuery(account: keyId.base64URLEncodedPushString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(KeyRecord.self, from: data)
    }

    static func saveKey(_ record: KeyRecord) throws {
        let account = try record.keyId.base64URLEncodedPushString
        let data = try JSONEncoder().encode(record)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Pushes arrive while the phone is locked; the key never leaves this device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(keyQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PushStoreError.keychain(update) }
        let add = keyQuery(account: account).merging(attributes) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PushStoreError.keychain(status) }
    }

    /// Every stored push key, newest first.
    static func allKeys() -> [KeyRecord] {
        var query = keyQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [Data] else { return [] }
        return items
            .compactMap { try? JSONDecoder().decode(KeyRecord.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func deleteKey(keyId: Data) {
        SecItemDelete(keyQuery(account: keyId.base64URLEncodedPushString) as CFDictionary)
    }

    // MARK: - App Group files

    private static func stateDirectory() throws -> URL {
        let container = try CrossProcessFileLock.appGroupContainer(identifier: SharedConstants.appGroupIdentifier)
        let directory = container.appendingPathComponent("push-state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: 0o700,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
        return directory
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Redaction snapshot

    static func saveRedactionSnapshot(_ snapshot: PushRedactionSnapshot) throws {
        let url = try stateDirectory().appendingPathComponent("redaction.json")
        try write(JSONEncoder().encode(snapshot), to: url)
    }

    /// `.unknown` (redact everything) when missing or unreadable.
    static func loadRedactionSnapshot() -> PushRedactionSnapshot {
        guard let url = try? stateDirectory().appendingPathComponent("redaction.json"),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PushRedactionSnapshot.self, from: data) else {
            return .unknown
        }
        return snapshot
    }

    // MARK: Replay windows

    /// Record `seq` for `keyId`. False for a replay, or when the state cannot be read or saved.
    static func acceptSequence(_ seq: UInt64, keyId: Data) -> Bool {
        guard let directory = try? stateDirectory(),
              let container = try? CrossProcessFileLock.appGroupContainer(
                identifier: SharedConstants.appGroupIdentifier
              ) else { return false }
        let url = directory.appendingPathComponent("replay.json")
        let accepted = try? CrossProcessFileLock.withLock(serverId: "push-replay", container: container) { () throws -> Bool in
            var windows: [String: PushReplayWindow] = [:]
            if FileManager.default.fileExists(atPath: url.path) {
                windows = try JSONDecoder().decode([String: PushReplayWindow].self, from: Data(contentsOf: url))
            }
            let account = keyId.base64URLEncodedPushString
            var window = windows[account] ?? PushReplayWindow()
            guard window.accept(seq) else { return false }
            windows[account] = window
            // Windows for deleted keys go with them.
            let liveKeys = Set(allKeys().compactMap { try? $0.keyId.base64URLEncodedPushString })
            windows = windows.filter { liveKeys.contains($0.key) || $0.key == account }
            try write(JSONEncoder().encode(windows), to: url)
            return true
        }
        return accepted ?? false
    }
}

enum PushStoreError: Error, Equatable {
    case keychain(OSStatus)
}
