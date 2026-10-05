import Foundation
import LocalAuthentication
import Security

/// The three Keychain operations the SSH profile store is allowed to perform.
/// Callers name an account. Nothing here lists or matches other items.
protocol SSHCredentialStoring: Sendable {
    func load(account: String, requirePresence: Bool) throws -> Data?
    func save(_ data: Data, account: String, requirePresence: Bool) throws
    func delete(account: String) throws
}

/// SSH items are app-private, never synchronised or placed in the app group.
struct SSHKeychain: Sendable {
    let service: String

    init(service: String = "\(AppIdentifiers.subsystem).ssh.private.v1") {
        self.service = service
    }

    func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load(account: String, requirePresence: Bool = false) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if requirePresence {
            // A fresh context for every connect prevents cached Face ID approval
            // from becoming silent password access on a later connection.
            let context = LAContext()
            context.localizedReason = "Sign in to your SSH host"
            context.touchIDAuthenticationAllowableReuseDuration = 0
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SSHKeychainError.status(status)
        }
        return data
    }

    func save(_ data: Data, account: String, requirePresence: Bool = false) throws {
        var attributes: [String: Any] = [kSecValueData as String: data]
        if requirePresence {
            guard let control = SecAccessControlCreateWithFlags(nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) else {
                throw SSHKeychainError.accessControl
            }
            attributes[kSecAttrAccessControl as String] = control
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        // Each account has one fixed protection policy. Replacing only its
        // value is atomic and preserves that policy: failed/cancelled updates
        // must leave the old credential or trusted host pin intact.
        let update = SecItemUpdate(query(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SSHKeychainError.status(update) }
        var add = query(account: account)
        attributes.forEach { add[$0.key] = $0.value }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SSHKeychainError.status(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SSHKeychainError.status(status) }
    }
}

extension SSHKeychain: SSHCredentialStoring {}

enum SSHKeychainError: LocalizedError, Equatable {
    case status(OSStatus), accessControl, passwordRequired

    var errorDescription: String? {
        switch self {
        case .passwordRequired: return "Enter your SSH password again. The saved credential is missing or belongs to a different host or username."
        case .accessControl: return "SSH password protection is unavailable. Set a device passcode before saving a password."
        case .status(let status):
            if status == errSecUserCanceled { return "SSH password access was cancelled." }
            return "SSH Keychain access failed (\(status)). Unlock your device and try again."
        }
    }
}
