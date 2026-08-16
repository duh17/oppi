import CryptoKit
import Foundation
import Security
import Testing
@testable import Oppi

private final class InMemorySealedStorage: DeviceKeySealedStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var saves = 0

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func save(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
        saves += 1
    }

    func saveCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }
}

/// Injects Keychain statuses to prove transient read errors and write failures
/// fail closed without generating or replacing the device key.
private final class InjectingSealedStorage: DeviceKeySealedStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var loadError: DeviceKeyStoreError?
    var saveError: DeviceKeyStoreError?

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let loadError { throw loadError }
        return data
    }

    func save(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if let saveError { throw saveError }
        self.data = data
    }

    func set(_ data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    func stored() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private func decodeBase64URL(_ value: String) -> Data {
    var normalized = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while normalized.count % 4 != 0 { normalized += "=" }
    return Data(base64Encoded: normalized)!
}

@Suite("DeviceKeyStore")
struct DeviceKeyStoreTests {
    @Test func concurrentCreatorsShareOneLockedKeyCreation() async throws {
        let storage = InMemorySealedStorage()
        let lockContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: lockContainer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lockContainer) }

        let keys = try await withThrowingTaskGroup(of: DevicePublicKey.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try DeviceKeyStore.loadOrCreateShared(
                        storage: storage,
                        useEnclave: { false },
                        lockContainer: lockContainer
                    ).publicKey
                }
            }
            var values: [DevicePublicKey] = []
            for try await key in group { values.append(key) }
            return values
        }

        #expect(keys.count == 2)
        #expect(keys[0] == keys[1])
        #expect(storage.saveCount() == 1)
    }

    @Test func fallbackKeyIsPersistentAndIdempotent() throws {
        let storage = InMemorySealedStorage()

        let first = try DeviceKeyStore.loadOrCreate(storage: storage, useEnclave: { false })
        let second = try DeviceKeyStore.loadOrCreate(storage: storage, useEnclave: { false })

        // Reloading the sealed representation yields the same public key.
        #expect(first.publicKey == second.publicKey)
    }

    @Test func publicKeyIsCanonicalP256JWK() throws {
        let key = InMemoryP256DeviceKey()
        let jwk = key.publicKey

        #expect(jwk.kty == "EC")
        #expect(jwk.crv == "P-256")
        let x = decodeBase64URL(jwk.x)
        let y = decodeBase64URL(jwk.y)
        #expect(x.count == 32)
        #expect(y.count == 32)
    }

    @Test func signatureVerifiesAgainstPublicKey() throws {
        let key = InMemoryP256DeviceKey()
        let input = Data("oppi:refresh:v1.nonce-value".utf8)
        let signature = try key.sign(input)

        #expect(signature.count == 64)

        let raw = Data([0x04]) + decodeBase64URL(key.publicKey.x) + decodeBase64URL(key.publicKey.y)
        let publicKey = try P256.Signing.PublicKey(x963Representation: raw)
        let signatureObject = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        #expect(publicKey.isValidSignature(signatureObject, for: input))
    }

    @Test func fallbackStorePersistsSeedForReload() throws {
        let storage = InMemorySealedStorage()
        let key = try DeviceKeyStore.loadOrCreate(storage: storage, useEnclave: { false })

        let sealed = try #require(try storage.load())
        // The fallback seals the raw 32-byte P-256 seed.
        #expect(sealed.count == 32)

        // A fresh store instance reading the same sealed bytes recovers the key.
        let reloaded = try P256.Signing.PrivateKey(rawRepresentation: sealed)
        let recoveredPublic = try #require(
            DevicePublicKey.publicKey(fromRaw: reloaded.publicKey.x963Representation)
        )
        #expect(recoveredPublic == key.publicKey)
    }

    @Test func doesNotOverwriteSealedMaterialWhenEnclaveLoadFails() throws {
        // A 32-byte fallback seed already exists, but the caller prefers the
        // Enclave. The store must reuse the seed rather than generate + save a
        // new Enclave key (which would silently rotate the server-side key).
        let seedKey = P256.Signing.PrivateKey()
        let storage = InMemorySealedStorage()
        try storage.save(seedKey.rawRepresentation)

        let key = try DeviceKeyStore.loadOrCreate(storage: storage, useEnclave: { true })

        let expected = try #require(DevicePublicKey.publicKey(fromRaw: seedKey.publicKey.x963Representation))
        #expect(key.publicKey == expected)
        #expect(try storage.load() == seedKey.rawRepresentation)
    }

    @Test func failsClosedOnCorruptNonFallbackSealedMaterial() throws {
        let storage = InMemorySealedStorage()
        try storage.save(Data(repeating: 0, count: 64))

        #expect(throws: DeviceKeyStoreError.self) {
            _ = try DeviceKeyStore.loadOrCreate(storage: storage, useEnclave: { true })
        }
        // The corrupt blob is preserved, not overwritten.
        #expect(try storage.load() == Data(repeating: 0, count: 64))
    }

    @Test func transientReadErrorFailsClosedWithoutGeneratingAKey() throws {
        let storage = InjectingSealedStorage()
        storage.set(nil)
        storage.loadError = .keychain(errSecInteractionNotAllowed)

        #expect(throws: DeviceKeyStoreError.self) {
            _ = try DeviceKeyStore.loadOrCreate(storage: storage, useEnclave: { false })
        }
        // No key material was written while the read path was in a transient
        // error state.
        #expect(storage.stored() == nil)
    }

    @Test func addFailureFailsClosedWithoutSilentReplacement() throws {
        // Simulates SecItemAdd failing after a not-found read. No key is
        // persisted and the caller surfaces the error rather than silently
        // producing a credential that could not be stored.
        let storage = InjectingSealedStorage()
        storage.set(nil)
        storage.saveError = .keychain(errSecNotAvailable)

        #expect(throws: DeviceKeyStoreError.self) {
            _ = try DeviceKeyStore.loadOrCreate(storage: storage, useEnclave: { false })
        }
        #expect(storage.stored() == nil)
    }

    @Test func updateFailurePreservesExistingSealedMaterial() throws {
        // An existing key must be reused on load; a later write failure cannot
        // reach the load path (the sealed bytes are returned before any save).
        let seedKey = P256.Signing.PrivateKey()
        let storage = InjectingSealedStorage()
        storage.set(seedKey.rawRepresentation)
        storage.saveError = .keychain(errSecNotAvailable)

        let key = try DeviceKeyStore.loadOrCreate(storage: storage, useEnclave: { false })
        let expected = try #require(
            DevicePublicKey.publicKey(fromRaw: seedKey.publicKey.x963Representation)
        )
        #expect(key.publicKey == expected)
        #expect(storage.stored() == seedKey.rawRepresentation)
    }

    @Test func keychainStoragePersistsThisDeviceOnlyInAccessGroup() throws {
        let storage = KeychainDeviceKeyStorage()
        try storage.save(Data(repeating: 1, count: 32))

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: "oppi.device-key.v1",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecSuccess)
        let attributes = result as? [String: Any]
        #expect(
            attributes?[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        #expect(attributes?[kSecAttrAccessGroup as String] as? String == SharedConstants.keychainAccessGroup)

        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: "oppi.device-key.v1",
        ] as CFDictionary)
    }
}
