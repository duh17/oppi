import Foundation

struct SSHTerminalProfile: Codable, Equatable, Sendable {
    enum Authentication: String, Codable, CaseIterable {
        case password, deviceKey
    }

    var host = ""
    var port: UInt16 = 22
    var username = ""
    var authentication: Authentication = .password
    var savesPassword = false

    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port > 0
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func sameCredentials(as other: Self) -> Bool {
        SSHKnownHosts.entryKey(host: host, port: port) == SSHKnownHosts.entryKey(host: other.host, port: other.port)
            && username == other.username && authentication == other.authentication
    }
}

/// Only nonsecret profile metadata lives in defaults. A changed target or
/// authentication method cannot accidentally reuse the previous password.
struct SSHTerminalProfileStore {
    static let storageKey = "\(AppIdentifiers.subsystem).ssh.terminal.profile.v1"
    static let passwordAccount = "terminal.password"
    /// Bind the secret to the target inside the protected item, not just in
    /// separately-written defaults. A second setup window may replace the item
    /// between a profile check and a user-presence read.
    private struct SavedPassword: Codable {
        let profile: SSHTerminalProfile
        let password: String
    }

    private let defaults: UserDefaults
    private let keychain: SSHKeychain

    init(defaults: UserDefaults = .standard, keychain: SSHKeychain = SSHKeychain()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    var hasStoredProfile: Bool { defaults.object(forKey: Self.storageKey) != nil }

    func load() -> SSHTerminalProfile? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(SSHTerminalProfile.self, from: data)
    }

    func save(_ profile: SSHTerminalProfile, password: String? = nil) throws {
        let data = try JSONEncoder().encode(profile)
        let old = load()
        let retain = old.map { profile.sameCredentials(as: $0) && $0.savesPassword } ?? false
        if profile.authentication == .password && profile.savesPassword {
            if let password {
                let secret = try JSONEncoder().encode(SavedPassword(profile: profile, password: password))
                try keychain.save(secret, account: Self.passwordAccount, requirePresence: true)
            } else if !retain {
                throw SSHKeychainError.passwordRequired
            }
        } else {
            try keychain.delete(account: Self.passwordAccount)
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Must run off the main actor: Security may wait for user presence.
    func password(for expected: SSHTerminalProfile) throws -> String? {
        guard let current = load(), current.savesPassword, expected.sameCredentials(as: current) else {
            throw SSHKeychainError.passwordRequired
        }
        guard let data = try keychain.load(account: Self.passwordAccount, requirePresence: true) else { return nil }
        guard let secret = try? JSONDecoder().decode(SavedPassword.self, from: data),
              expected.sameCredentials(as: secret.profile) else {
            throw SSHKeychainError.passwordRequired
        }
        return secret.password
    }

    func delete() throws {
        // Do not claim the profile was deleted if credential deletion failed.
        try keychain.delete(account: Self.passwordAccount)
        defaults.removeObject(forKey: Self.storageKey)
    }
}
