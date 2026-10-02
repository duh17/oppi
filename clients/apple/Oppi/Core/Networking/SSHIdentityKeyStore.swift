import CryptoKit
import Foundation
import NIOSSH
import Security

/// A dedicated SSH user identity. It is intentionally unrelated to Oppi's
/// pairing/device key and is suitable for a manual `authorized_keys` entry.
struct SSHIdentity: Sendable {
    let privateKey: NIOSSHPrivateKey
    let isHardwareBacked: Bool

    var publicKeyOpenSSH: String {
        String(openSSHPublicKey: privateKey.publicKey) + " oppi-ios"
    }

    var backingDescription: String {
        isHardwareBacked ? "Secure Enclave" : "Software key (simulator; not hardware-backed)"
    }

    init(privateKey: NIOSSHPrivateKey, isHardwareBacked: Bool) {
        self.privateKey = privateKey
        self.isHardwareBacked = isHardwareBacked
    }
}

protocol SSHIdentitySealedStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

struct KeychainSSHIdentityStorage: SSHIdentitySealedStorage {
    private static let account = "oppi.ssh.identity.v1"

    func load() throws -> Data? {
        var query = Self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SSHIdentityKeyStoreError.keychain(status) }
        guard let data = result as? Data else { throw SSHIdentityKeyStoreError.sealedDataCorrupt }
        return data
    }

    func save(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(Self.query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SSHIdentityKeyStoreError.keychain(updated) }
        var add = Self.query
        attributes.forEach { add[$0.key] = $0.value }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SSHIdentityKeyStoreError.keychain(status) }
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecAttrAccount as String: account,
        ]
    }
}

enum SSHIdentityKeyStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case sealedDataCorrupt
    case secureEnclaveUnavailable
}

/// Creates one persistent P-256 SSH key. Physical devices fail closed if the
/// Secure Enclave is unavailable. The simulator uses an explicitly labeled
/// software P-256 fallback so the fixture and enrollment flow remain usable.
enum SSHIdentityKeyStore {
    private static let enclaveTag: UInt8 = 1
    private static let softwareTag: UInt8 = 2

    static func loadOrCreate(storage: any SSHIdentitySealedStorage = KeychainSSHIdentityStorage()) throws -> SSHIdentity {
        #if targetEnvironment(simulator)
        return try loadOrCreateSoftware(storage: storage)
        #else
        return try loadOrCreateEnclave(storage: storage)
        #endif
    }

    private static func loadOrCreateEnclave(storage: any SSHIdentitySealedStorage) throws -> SSHIdentity {
        guard SecureEnclave.isAvailable else { throw SSHIdentityKeyStoreError.secureEnclaveUnavailable }
        if let sealed = try storage.load() {
            guard sealed.first == enclaveTag else { throw SSHIdentityKeyStoreError.sealedDataCorrupt }
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: sealed.dropFirst())
                return SSHIdentity(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: key), isHardwareBacked: true)
            } catch {
                throw SSHIdentityKeyStoreError.sealedDataCorrupt
            }
        }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            try storage.save(Data([enclaveTag]) + key.dataRepresentation)
            return SSHIdentity(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: key), isHardwareBacked: true)
        } catch let error as SSHIdentityKeyStoreError {
            throw error
        } catch {
            throw SSHIdentityKeyStoreError.secureEnclaveUnavailable
        }
    }

    private static func loadOrCreateSoftware(storage: any SSHIdentitySealedStorage) throws -> SSHIdentity {
        let key: P256.Signing.PrivateKey
        if let sealed = try storage.load() {
            guard sealed.first == softwareTag else { throw SSHIdentityKeyStoreError.sealedDataCorrupt }
            do {
                key = try P256.Signing.PrivateKey(rawRepresentation: sealed.dropFirst())
            } catch {
                throw SSHIdentityKeyStoreError.sealedDataCorrupt
            }
        } else {
            key = P256.Signing.PrivateKey()
            try storage.save(Data([softwareTag]) + key.rawRepresentation)
        }
        return SSHIdentity(privateKey: NIOSSHPrivateKey(p256Key: key), isHardwareBacked: false)
    }
}
