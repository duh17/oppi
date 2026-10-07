import Foundation

struct SSHTerminalProfile: Codable, Equatable, Sendable, Identifiable {
    enum Authentication: String, Codable, CaseIterable {
        case password, deviceKey
    }

    var id: UUID
    var host: String
    var port: UInt16
    var username: String
    var authentication: Authentication
    var savesPassword: Bool
    /// Optional command run on the PTY instead of a login shell, like
    /// `ssh -t host 'command'`. Optional so older saved profiles still decode.
    var startupCommand: String?
    /// The migrated single-host profile keeps its password at `terminal.password`
    /// until `password(for:)` rebinds it. Never set this from the setup form.
    var passwordUsesLegacyAccount: Bool

    init(
        id: UUID = UUID(),
        host: String = "",
        port: UInt16 = 22,
        username: String = "",
        authentication: Authentication = .password,
        savesPassword: Bool = false,
        startupCommand: String? = nil,
        passwordUsesLegacyAccount: Bool = false
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.savesPassword = savesPassword
        self.startupCommand = startupCommand
        self.passwordUsesLegacyAccount = passwordUsesLegacyAccount
    }

    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port > 0
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Identity is `id`, not this tuple. Two saved hosts may share a machine
    /// and differ only by Run on Connect.
    func sameCredentials(as other: Self) -> Bool {
        SSHKnownHosts.entryKey(host: host, port: port) == SSHKnownHosts.entryKey(host: other.host, port: other.port)
            && username == other.username && authentication == other.authentication
    }

    var endpointLabel: String {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty { return name }
        if name.isEmpty { return user }
        return "\(user)@\(name)"
    }

    /// Nil on the default SSH port so the row does not repeat 22.
    var portLabel: String? { port == 22 ? nil : "Port \(port)" }

    var startupLabel: String {
        let command = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? "Login shell" : command
    }

    func normalized() -> Self {
        var result = self
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        result.startupCommand = command.isEmpty ? nil : command
        if result.authentication == .deviceKey { result.savesPassword = false }
        return result
    }
}

/// The pre-catalog single profile. It has no id. Decoding it must not require
/// the catalog fields, and migration must not read the Keychain to build one.
struct SSHTerminalLegacyProfile: Codable, Equatable, Sendable {
    var host = ""
    var port: UInt16 = 22
    var username = ""
    var authentication: SSHTerminalProfile.Authentication = .password
    var savesPassword = false
    var startupCommand: String?

    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port > 0
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func migrated(id: UUID = UUID()) -> SSHTerminalProfile {
        SSHTerminalProfile(
            id: id, host: host, port: port, username: username, authentication: authentication,
            savesPassword: savesPassword, startupCommand: startupCommand,
            passwordUsesLegacyAccount: savesPassword
        )
    }
}

struct SSHTerminalCatalog: Codable, Equatable, Sendable {
    var profiles: [SSHTerminalProfile]
}

enum SSHTerminalProfileStoreError: LocalizedError, Equatable {
    case corruptMetadata

    var errorDescription: String? {
        switch self {
        case .corruptMetadata:
            return "The saved host list cannot be read. Delete the saved password, then add the host again."
        }
    }
}

/// Only nonsecret profile metadata lives in defaults. A changed target or
/// authentication method cannot accidentally reuse that profile's password.
/// Another profile's password is a different Keychain account.
struct SSHTerminalProfileStore {
    /// Pre-catalog single profile. Migration reads this, writes `catalogKey`,
    /// then removes it. Do not store new hosts here.
    static let storageKey = "\(AppIdentifiers.subsystem).ssh.terminal.profile.v1"
    static let catalogKey = "\(AppIdentifiers.subsystem).ssh.terminal.catalog.v1"
    /// The single-host password item. A migrated profile records that its
    /// secret still lives here; `password(for:)` is the only rebind.
    static let passwordAccount = "terminal.password"

    static func passwordAccount(for id: UUID) -> String {
        "\(passwordAccount).\(id.uuidString)"
    }

    /// Sidebar visibility before the list has migrated. Catalog wins when it
    /// is present. A legacy profile still counts so Terminal does not disappear
    /// until the list is opened. This does not write and does not touch the Keychain.
    static func hasConfiguredHost(catalogData: Data, legacyData: Data) -> Bool {
        if !catalogData.isEmpty {
            guard let catalog = try? JSONDecoder().decode(SSHTerminalCatalog.self, from: catalogData) else { return false }
            return catalog.profiles.contains(where: \.isConfigured)
        }
        guard !legacyData.isEmpty,
              let legacy = try? JSONDecoder().decode(SSHTerminalLegacyProfile.self, from: legacyData) else { return false }
        return legacy.isConfigured
    }

    private struct BoundPassword: Codable {
        let profileID: UUID
        let profile: SSHTerminalProfile
        let password: String
    }

    private struct LegacySavedPassword: Codable {
        let profile: SSHTerminalLegacyProfile
        let password: String
    }

    private let defaults: UserDefaults
    private let keychain: any SSHCredentialStoring

    init(defaults: UserDefaults = .standard, keychain: any SSHCredentialStoring = SSHKeychain()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    var hasConfiguredHost: Bool {
        Self.hasConfiguredHost(
            catalogData: defaults.data(forKey: Self.catalogKey) ?? Data(),
            legacyData: defaults.data(forKey: Self.storageKey) ?? Data()
        )
    }

    /// True when a defaults value is present but is not a catalog or legacy
    /// profile. Opening the list uses this to offer an explicit legacy-password
    /// delete. It does not read the Keychain.
    var metadataIsCorrupt: Bool {
        if let data = defaults.data(forKey: Self.catalogKey) {
            return (try? JSONDecoder().decode(SSHTerminalCatalog.self, from: data)) == nil
        }
        if defaults.object(forKey: Self.storageKey) != nil {
            guard let data = defaults.data(forKey: Self.storageKey),
                  (try? JSONDecoder().decode(SSHTerminalLegacyProfile.self, from: data)) != nil else { return true }
        }
        return false
    }

    func load() -> [SSHTerminalProfile] {
        if let data = defaults.data(forKey: Self.catalogKey) {
            guard let catalog = try? JSONDecoder().decode(SSHTerminalCatalog.self, from: data) else { return [] }
            // A crash between the catalog write and the legacy-key removal must
            // not migrate again, and must not touch the Keychain. A catalog that
            // only exists in the argument domain (screenshot launches) is not
            // saved, so it must not finish the migration and drop the legacy host.
            let catalogIsUnsaved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[Self.catalogKey] != nil
            if !catalogIsUnsaved, defaults.object(forKey: Self.storageKey) != nil {
                defaults.removeObject(forKey: Self.storageKey)
            }
            return catalog.profiles
        }
        guard let legacyData = defaults.data(forKey: Self.storageKey),
              let legacy = try? JSONDecoder().decode(SSHTerminalLegacyProfile.self, from: legacyData) else { return [] }
        let profile = legacy.migrated()
        guard let encoded = try? JSONEncoder().encode(SSHTerminalCatalog(profiles: [profile])) else { return [profile] }
        defaults.set(encoded, forKey: Self.catalogKey)
        guard let written = defaults.data(forKey: Self.catalogKey),
              let stored = try? JSONDecoder().decode(SSHTerminalCatalog.self, from: written),
              stored.profiles.contains(where: { $0.id == profile.id }) else { return [profile] }
        defaults.removeObject(forKey: Self.storageKey)
        return stored.profiles
    }

    func profile(id: UUID) -> SSHTerminalProfile? {
        load().first { $0.id == id }
    }

    func contains(_ id: UUID) -> Bool { profile(id: id) != nil }

    func save(_ profile: SSHTerminalProfile, password: String? = nil) throws {
        let value = profile.normalized()
        var profiles = try editableProfiles()
        let old = profiles.first { $0.id == value.id }
        let retain = old.map { value.sameCredentials(as: $0) && $0.savesPassword } ?? false
        var stored = value
        if value.authentication == .password && value.savesPassword {
            if let password {
                stored.passwordUsesLegacyAccount = false
                let secret = try JSONEncoder().encode(BoundPassword(profileID: stored.id, profile: stored, password: password))
                try keychain.save(secret, account: Self.passwordAccount(for: stored.id), requirePresence: true)
                if old?.passwordUsesLegacyAccount == true {
                    try keychain.delete(account: Self.passwordAccount)
                }
            } else if retain {
                stored.passwordUsesLegacyAccount = old?.passwordUsesLegacyAccount ?? false
            } else {
                throw SSHKeychainError.passwordRequired
            }
        } else {
            try deletePassword(for: old ?? stored)
            stored.passwordUsesLegacyAccount = false
            if stored.authentication != .password { stored.savesPassword = false }
        }
        if let index = profiles.firstIndex(where: { $0.id == stored.id }) {
            profiles[index] = stored
        } else {
            profiles.append(stored)
        }
        try write(profiles)
    }

    /// Must run off the main actor: Security may wait for user presence.
    /// This is the only path that moves a migrated password off `terminal.password`.
    /// A failed rebind leaves that item in place.
    func password(for expected: SSHTerminalProfile) throws -> String? {
        guard let current = profile(id: expected.id), current.savesPassword, expected.sameCredentials(as: current) else {
            throw SSHKeychainError.passwordRequired
        }
        if current.passwordUsesLegacyAccount {
            if let existing = try boundPassword(for: expected) {
                try finishLegacyRebind(id: expected.id)
                return existing
            }
            return try rebindLegacyPassword(for: expected)
        }
        return try boundPassword(for: expected)
    }

    /// That profile and its saved password only. Does not remove the device
    /// key or a trusted host key, and does not search the Keychain.
    func delete(id: UUID) throws {
        let profiles = try editableProfiles()
        let existing = profiles.first { $0.id == id }
        try deletePassword(for: existing ?? SSHTerminalProfile(id: id))
        try write(profiles.filter { $0.id != id })
    }

    /// Explicit delete of the pre-catalog password item. One account. Callers
    /// use this when catalog metadata cannot be decoded; it does not scan.
    func deleteLegacyPasswordItem() throws {
        try keychain.delete(account: Self.passwordAccount)
    }

    /// Drops defaults values that do not decode. A valid catalog or legacy
    /// profile is left alone. Does not read or write the Keychain.
    func discardCorruptMetadata() {
        if let data = defaults.data(forKey: Self.catalogKey),
           (try? JSONDecoder().decode(SSHTerminalCatalog.self, from: data)) == nil {
            defaults.removeObject(forKey: Self.catalogKey)
        }
        if defaults.object(forKey: Self.storageKey) != nil {
            let data = defaults.data(forKey: Self.storageKey)
            if data == nil || (try? JSONDecoder().decode(SSHTerminalLegacyProfile.self, from: data ?? Data())) == nil {
                defaults.removeObject(forKey: Self.storageKey)
            }
        }
    }

    private func editableProfiles() throws -> [SSHTerminalProfile] {
        if metadataIsCorrupt { throw SSHTerminalProfileStoreError.corruptMetadata }
        return load()
    }

    private func write(_ profiles: [SSHTerminalProfile]) throws {
        defaults.set(try JSONEncoder().encode(SSHTerminalCatalog(profiles: profiles)), forKey: Self.catalogKey)
    }

    private func deletePassword(for profile: SSHTerminalProfile) throws {
        try keychain.delete(account: Self.passwordAccount(for: profile.id))
        if profile.passwordUsesLegacyAccount {
            try keychain.delete(account: Self.passwordAccount)
        }
    }

    private func boundPassword(for expected: SSHTerminalProfile) throws -> String? {
        guard let data = try keychain.load(account: Self.passwordAccount(for: expected.id), requirePresence: true) else {
            return nil
        }
        guard let secret = try? JSONDecoder().decode(BoundPassword.self, from: data),
              secret.profileID == expected.id,
              secret.profile.id == expected.id,
              expected.sameCredentials(as: secret.profile) else {
            throw SSHKeychainError.passwordRequired
        }
        return secret.password
    }

    private func rebindLegacyPassword(for expected: SSHTerminalProfile) throws -> String? {
        guard let data = try keychain.load(account: Self.passwordAccount, requirePresence: true) else {
            try clearLegacyFlag(id: expected.id)
            return nil
        }
        let legacy = try? JSONDecoder().decode(LegacySavedPassword.self, from: data)
        guard let legacy, expected.sameCredentials(as: legacy.profile.migrated(id: expected.id)) else {
            throw SSHKeychainError.passwordRequired
        }
        var rebound = expected
        rebound.passwordUsesLegacyAccount = false
        let secret = try JSONEncoder().encode(BoundPassword(profileID: expected.id, profile: rebound, password: legacy.password))
        try keychain.save(secret, account: Self.passwordAccount(for: expected.id), requirePresence: true)
        try keychain.delete(account: Self.passwordAccount)
        try clearLegacyFlag(id: expected.id)
        return legacy.password
    }

    /// The per-profile item is already the password. Delete the legacy item
    /// only; do not write over the newer secret.
    private func finishLegacyRebind(id: UUID) throws {
        try keychain.delete(account: Self.passwordAccount)
        try clearLegacyFlag(id: id)
    }

    private func clearLegacyFlag(id: UUID) throws {
        var profiles = load()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].passwordUsesLegacyAccount = false
        try write(profiles)
    }
}
