import CryptoKit
import Foundation
import Security

/// Persistent storage for the device signing key's sealed representation.
/// Implementations wrap the Keychain (production) or memory (tests).
protocol DeviceKeySealedStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// Keychain-backed sealed storage for the device key. The account is shared
/// with the other Oppi keychain items so app extensions can reach it.
struct KeychainDeviceKeyStorage: DeviceKeySealedStorage {
    private static let account = "oppi.device-key.v1"

    func load() throws -> Data? {
        var query = Self.query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        // Only a genuine not-found may fall through to key creation. Any other
        // Keychain error (interaction not allowed, entitlement/access-group
        // problem, transient I/O) fails closed so we never silently rotate the
        // key and strand the server-side public key.
        guard status == errSecSuccess else {
            throw DeviceKeyStoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw DeviceKeyStoreError.sealedDataCorrupt
        }
        return data
    }

    func save(_ data: Data) throws {
        // Update atomically in place. Never delete-before-add: if the add half
        // fails after a delete, the only copy of the private key is lost.
        let updateStatus = SecItemUpdate(
            Self.query() as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = Self.query()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw DeviceKeyStoreError.keychain(addStatus)
            }
            return
        }
        throw DeviceKeyStoreError.keychain(updateStatus)
    }

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecAttrAccount as String: account,
        ]
    }
}

enum DeviceKeyStoreError: Error, Equatable {
    case keychain(OSStatus)
    case sealedDataCorrupt
    case enclaveUnavailable
}

/// Creates and reloads the device P-256 signing key.
///
/// Production uses a Secure Enclave key (non-exportable). When the Secure
/// Enclave is unavailable (simulator, some platforms), it falls back to a
/// Keychain-sealed in-memory P-256 key. Both satisfy the same `DeviceKey`
/// contract so the access-token layer is identical.
enum DeviceKeyStore {
    /// Serialize first-use creation across the app, share extension, and App
    /// Intents. The load happens only after the shared flock is held, so a
    /// process that waited for another creator re-reads and adopts that key.
    static func loadOrCreateShared(
        storage: any DeviceKeySealedStorage,
        useEnclave: @Sendable () -> Bool,
        lockContainer: URL
    ) throws -> any DeviceKey {
        try CrossProcessFileLock.withLock(
            serverId: "device-key-v1",
            container: lockContainer
        ) {
            try loadOrCreate(storage: storage, useEnclave: useEnclave)
        }
    }

    /// Load the device signing key, creating one only when no sealed material
    /// exists. Existing sealed material is never overwritten on a load failure:
    /// a transient Enclave read failure fails closed instead of silently
    /// rotating the key (which would strand the server-side public key).
    static func loadOrCreate(
        storage: any DeviceKeySealedStorage,
        useEnclave: @Sendable () -> Bool
    ) throws -> any DeviceKey {
        if let existing = try storage.load() {
            // Existing material must be reused, never replaced.
            if useEnclave() {
                if let key = try loadEnclaveKey(from: existing) { return key }
            }
            // A 32-byte blob is the Keychain-sealed fallback seed.
            if existing.count == 32 {
                let key = try P256.Signing.PrivateKey(rawRepresentation: existing)
                return FallbackP256DeviceKey(privateKey: key)
            }
            // Unreadable sealed material: fail closed rather than rotate.
            throw DeviceKeyStoreError.sealedDataCorrupt
        }

        if useEnclave() {
            if let created = try createEnclaveKey(storage: storage) { return created }
        }
        return try createFallbackKey(storage: storage)
    }

    // MARK: - Secure Enclave

    private static func loadEnclaveKey(from sealed: Data) throws -> (any DeviceKey)? {
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: sealed)
            return EnclaveP256DeviceKey(privateKey: key)
        } catch {
            return nil
        }
    }

    private static func createEnclaveKey(storage: any DeviceKeySealedStorage) throws -> (any DeviceKey)? {
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            try storage.save(key.dataRepresentation)
            return EnclaveP256DeviceKey(privateKey: key)
        } catch {
            return nil
        }
    }

    // MARK: - Keychain-sealed fallback (simulator / non-Enclave platforms)

    private static func createFallbackKey(storage: any DeviceKeySealedStorage) throws -> any DeviceKey {
        let key = P256.Signing.PrivateKey()
        try storage.save(key.rawRepresentation)
        return FallbackP256DeviceKey(privateKey: key)
    }
}

/// A `DeviceKey` backed by a CryptoKit `P256.Signing.PrivateKey`.
private struct FallbackP256DeviceKey: DeviceKey {
    private let privateKey: P256.Signing.PrivateKey
    let publicKey: DevicePublicKey

    init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
        guard let publicKey = DevicePublicKey.publicKey(fromRaw: privateKey.publicKey.x963Representation) else {
            preconditionFailure("P-256 public key raw representation is always 65 bytes")
        }
        self.publicKey = publicKey
    }

    func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).rawRepresentation
    }
}

/// A `DeviceKey` backed by a CryptoKit Secure Enclave `P256.Signing.PrivateKey`.
private struct EnclaveP256DeviceKey: DeviceKey {
    private let privateKey: SecureEnclave.P256.Signing.PrivateKey
    let publicKey: DevicePublicKey

    init(privateKey: SecureEnclave.P256.Signing.PrivateKey) {
        self.privateKey = privateKey
        guard let publicKey = DevicePublicKey.publicKey(fromRaw: privateKey.publicKey.x963Representation) else {
            preconditionFailure("P-256 public key raw representation is always 65 bytes")
        }
        self.publicKey = publicKey
    }

    func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).rawRepresentation
    }
}
