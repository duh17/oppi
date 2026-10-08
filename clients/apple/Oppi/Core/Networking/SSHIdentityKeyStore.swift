import CryptoKit
import Foundation
import LocalAuthentication
import NIOSSH
import Security

/// A dedicated SSH user identity, unrelated to Oppi's pairing/device key.
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
    func requireReplacement() throws
}

struct KeychainSSHIdentityStorage: SSHIdentitySealedStorage {
    private static let account = "oppi.ssh.identity.presence.v2"
    private static let replacementAccount = "oppi.ssh.identity.replacement-required"

    func load() throws -> Data? {
        // The v1 enclave reference allowed signing without presence and was
        // shared with extensions. Remove it even if v2 restoration later fails.
        var legacy = Self.query(account: "oppi.ssh.identity.v1")
        legacy[kSecAttrAccessGroup as String] = SharedConstants.keychainAccessGroup
        try Self.delete(legacy)
        if try Self.read(account: Self.replacementAccount) != nil {
            throw SSHIdentityKeyStoreError.devicePasscodeChanged
        }
        return try Self.read(account: Self.account)
    }

    func save(_ data: Data) throws {
        try Self.write(data, account: Self.account)
        try Self.delete(Self.query(account: Self.replacementAccount))
    }

    func requireReplacement() throws {
        // Persist the recovery state before deleting the unusable sealed key.
        // A subsequent launch must not silently create a different identity.
        try Self.write(Data([1]), account: Self.replacementAccount)
        try Self.delete(Self.query(account: Self.account))
    }

    private static func read(account: String) throws -> Data? {
        var query = Self.query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SSHIdentityKeyStoreError.keychain(status) }
        guard let data = result as? Data else { throw SSHIdentityKeyStoreError.sealedDataCorrupt }
        return data
    }

    private static func write(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let query = Self.query(account: account)
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SSHIdentityKeyStoreError.keychain(updated) }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SSHIdentityKeyStoreError.keychain(status) }
    }

    private static func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHIdentityKeyStoreError.keychain(status)
        }
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConstants.keychainService,
            kSecAttrAccount as String: account,
        ]
    }
}

enum SSHIdentityKeyStoreError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case sealedDataCorrupt
    case secureEnclaveUnavailable
    case devicePasscodeChanged
    case authenticationExpired
    case authenticationFailed(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            switch status {
            case errSecUserCanceled: return "SSH key approval was cancelled."
            case errSecInteractionNotAllowed: return "SSH key access is unavailable while the device is locked. Unlock it and try again."
            default: return "SSH identity Keychain access failed (\(status)). Try again after unlocking your device."
            }
        case .sealedDataCorrupt: return "The saved SSH identity cannot be read. It has not been replaced."
        case .secureEnclaveUnavailable: return "Secure Enclave SSH identity is unavailable. Set a device passcode and try again."
        case .devicePasscodeChanged: return "Device passcode changed — create a new key"
        case .authenticationExpired: return "SSH key approval expired. Connect again to approve sign-in."
        case .authenticationFailed(let message): return "SSH key approval failed: \(message)"
        }
    }

    static func securityStatus(_ error: any Error) -> OSStatus? {
        if case CryptoKitError.underlyingCoreCryptoError(let status) = error { return status }
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain { return OSStatus(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
            return securityStatus(underlying)
        }
        return nil
    }
}

/// Presence is evaluated away from NIO before dialing. This boundary owns both
/// the prompt and the context that restores/signs with the enclave key.
protocol SSHKeyPresenceContext: Sendable {
    func evaluate() async throws
    func identity() throws -> SSHIdentity
    func invalidate()
}

private final class DeviceSSHKeyPresenceContext: SSHKeyPresenceContext, @unchecked Sendable {
    private let context = LAContext()

    init() {
        context.localizedReason = "Sign in to your SSH host"
        context.touchIDAuthenticationAllowableReuseDuration = 0
    }

    func evaluate() async throws {
        #if !targetEnvironment(simulator)
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: context.localizedReason)
        } catch {
            throw SSHIdentityKeyStoreError.authenticationFailed(error.localizedDescription)
        }
        #endif
        // Reuse only this attempt's approval for the immediately following
        // signature. Never let NIOSSH's synchronous signer present another UI.
        context.touchIDAuthenticationAllowableReuseDuration = 30
        context.interactionNotAllowed = true
    }

    func identity() throws -> SSHIdentity {
        let identity = try SSHIdentityKeyStore.loadOrCreate(authenticationContext: context)
        #if !targetEnvironment(simulator)
        // Prove the authenticated context can sign noninteractively before any
        // dial. If its authorization expired, fail here, not on the NIO loop.
        let keyData = try KeychainSSHIdentityStorage().load()
        guard let keyData else { throw SSHIdentityKeyStoreError.sealedDataCorrupt }
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData.dropFirst(), authenticationContext: context)
        do { _ = try key.signature(for: Data("Oppi SSH approval check".utf8)) } catch { throw SSHIdentityKeyStoreError.authenticationExpired }
        #endif
        return identity
    }

    func invalidate() { context.invalidate() }
}

/// Physical devices fail closed without the enclave. The simulator uses an
/// explicitly labeled software key; it cannot prove hardware presence behavior.
enum SSHIdentityKeyStore {
    private static let enclaveTag: UInt8 = 1
    private static let softwareTag: UInt8 = 2

    static func authenticatedIdentity(context: any SSHKeyPresenceContext = DeviceSSHKeyPresenceContext()) async throws -> SSHIdentity {
        let work = Task.detached {
            try Task.checkCancellation()
            try await context.evaluate()
            try Task.checkCancellation()
            return try context.identity()
        }
        return try await withTaskCancellationHandler {
            let identity = try await work.value
            try Task.checkCancellation()
            return identity
        } onCancel: {
            context.invalidate()
            work.cancel()
        }
    }

    static func loadOrCreate(
        storage: any SSHIdentitySealedStorage = KeychainSSHIdentityStorage(),
        authenticationContext: LAContext = LAContext(),
        createReplacement: Bool = false
    ) throws -> SSHIdentity {
        // Loading/exporting the public key must not trigger presence either.
        authenticationContext.interactionNotAllowed = true
        let sealed: Data?
        do { sealed = try storage.load() } catch SSHIdentityKeyStoreError.devicePasscodeChanged where createReplacement { sealed = nil }
        #if targetEnvironment(simulator)
        return try loadOrCreateSoftware(sealed: sealed, storage: storage)
        #else
        return try loadOrCreateEnclave(sealed: sealed, storage: storage, context: authenticationContext)
        #endif
    }

    /// Only a definitive missing enclave reference permits deletion. Locked
    /// device, cancelled approval, decode failures and unknown errors retain it.
    static func restore<Key>(sealed: Data, storage: any SSHIdentitySealedStorage, using restore: (Data) throws -> Key) throws -> Key {
        do { return try restore(sealed) } catch {
            if let status = SSHIdentityKeyStoreError.securityStatus(error) {
                if status == errSecItemNotFound {
                    try storage.requireReplacement()
                    throw SSHIdentityKeyStoreError.devicePasscodeChanged
                }
                throw SSHIdentityKeyStoreError.keychain(status)
            }
            throw SSHIdentityKeyStoreError.authenticationFailed(error.localizedDescription)
        }
    }

    private static func loadOrCreateEnclave(sealed: Data?, storage: any SSHIdentitySealedStorage, context: LAContext) throws -> SSHIdentity {
        guard SecureEnclave.isAvailable else { throw SSHIdentityKeyStoreError.secureEnclaveUnavailable }
        if let sealed {
            guard sealed.first == enclaveTag else { throw SSHIdentityKeyStoreError.sealedDataCorrupt }
            let key = try restore(sealed: Data(sealed.dropFirst()), storage: storage) {
                try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: $0, authenticationContext: context)
            }
            return SSHIdentity(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: key), isHardwareBacked: true)
        }
        do {
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                [.privateKeyUsage, .userPresence], &accessError) else {
                throw SSHIdentityKeyStoreError.secureEnclaveUnavailable
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
            try storage.save(Data([enclaveTag]) + key.dataRepresentation)
            return SSHIdentity(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: key), isHardwareBacked: true)
        } catch let error as SSHIdentityKeyStoreError {
            throw error
        } catch {
            if let status = SSHIdentityKeyStoreError.securityStatus(error) { throw SSHIdentityKeyStoreError.keychain(status) }
            throw SSHIdentityKeyStoreError.secureEnclaveUnavailable
        }
    }

    private static func loadOrCreateSoftware(sealed: Data?, storage: any SSHIdentitySealedStorage) throws -> SSHIdentity {
        let key: P256.Signing.PrivateKey
        if let sealed {
            guard sealed.first == softwareTag else { throw SSHIdentityKeyStoreError.sealedDataCorrupt }
            do { key = try P256.Signing.PrivateKey(rawRepresentation: sealed.dropFirst()) } catch { throw SSHIdentityKeyStoreError.sealedDataCorrupt }
        } else {
            key = P256.Signing.PrivateKey()
            try storage.save(Data([softwareTag]) + key.rawRepresentation)
        }
        return SSHIdentity(privateKey: NIOSSHPrivateKey(p256Key: key), isHardwareBacked: false)
    }
}
