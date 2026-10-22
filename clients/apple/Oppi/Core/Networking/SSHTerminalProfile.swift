import Foundation
import LocalAuthentication
import Security

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
    /// A password saved for the terminal's own prompts (`sudo`) on a host that
    /// signs in with this device's key. The secret is in the Keychain; this
    /// flag lets the terminal offer it without reading the Keychain. Password
    /// hosts fill their sign-in password instead and never set it.
    var savesSudoPassword = false
    /// Optional command run on the PTY instead of a login shell, like
    /// `ssh -t host 'command'`. Optional so older saved profiles still decode.
    var startupCommand: String?

    init(
        id: UUID = UUID(),
        host: String = "",
        port: UInt16 = 22,
        username: String = "",
        authentication: Authentication = .password,
        savesPassword: Bool = false,
        savesSudoPassword: Bool = false,
        startupCommand: String? = nil
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.savesPassword = savesPassword
        self.savesSudoPassword = savesSudoPassword
        self.startupCommand = startupCommand
    }

    /// Catalogs saved before the sudo password existed have no such key.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(UInt16.self, forKey: .port)
        username = try values.decode(String.self, forKey: .username)
        authentication = try values.decode(Authentication.self, forKey: .authentication)
        savesPassword = try values.decode(Bool.self, forKey: .savesPassword)
        savesSudoPassword = try values.decodeIfPresent(Bool.self, forKey: .savesSudoPassword) ?? false
        startupCommand = try values.decodeIfPresent(String.self, forKey: .startupCommand)
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

    /// Whether a shell opened with `other` is still the shell this profile
    /// describes: same host, port, user, sign-in, and Run on Connect. Whether a
    /// password is saved for it (`savesPassword`, `savesSudoPassword`) does not
    /// change the connection.
    func sameConnection(as other: Self) -> Bool {
        sameCredentials(as: other) && startupCommand == other.startupCommand
    }

    /// Whether `saved` keeps a stored password that still belongs to this
    /// host: Save Password was on, and host, port, user and method are unchanged.
    func reusesSavedPassword(of saved: Self?) -> Bool {
        guard let saved else { return false }
        return saved.savesPassword && sameCredentials(as: saved)
    }

    /// Whether `saved` keeps a stored sudo password that still belongs to this
    /// host: one was saved, and host, port, user and method are unchanged.
    func reusesSudoPassword(of saved: Self?) -> Bool {
        guard let saved else { return false }
        return saved.savesSudoPassword && sameCredentials(as: saved)
    }

    /// This profile as the form saves it: the sudo password is kept only on a
    /// device-key host, and only when the person typed one (`supplied`) or the
    /// one `saved` still belongs to this host.
    func settingSudoPassword(supplied: Bool, saved: Self?) -> Self {
        var result = self
        result.savesSudoPassword = authentication == .deviceKey && (supplied || reusesSudoPassword(of: saved))
        return result
    }

    /// Whether a password prompt in this host's terminal can be filled: the
    /// saved sign-in password of a password host, or the sudo password of a
    /// device-key host.
    var hasPasswordToFill: Bool {
        authentication == .password ? savesPassword : savesSudoPassword
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
        if result.authentication == .password { result.savesSudoPassword = false }
        return result
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
            return "The saved host list cannot be read. Reset the host list, then add your hosts again."
        }
    }
}

/// Only nonsecret profile metadata lives in defaults. A changed target or
/// authentication method cannot accidentally reuse that profile's password.
/// Another profile's password is a different Keychain account.
struct SSHTerminalProfileStore {
    static let catalogKey = "\(AppIdentifiers.subsystem).ssh.terminal.catalog.v1"

    /// One Keychain account per saved host.
    static func passwordAccount(for id: UUID) -> String {
        "terminal.password.\(id.uuidString)"
    }

    /// The sudo password's own Keychain account, beside the sign-in password's.
    static func sudoPasswordAccount(for id: UUID) -> String {
        "terminal.sudoPassword.\(id.uuidString)"
    }

    private struct BoundPassword: Codable {
        let profileID: UUID
        let profile: SSHTerminalProfile
        let password: String
    }

    private let defaults: UserDefaults
    private let keychain: any SSHCredentialStoring

    init(defaults: UserDefaults = .standard, keychain: any SSHCredentialStoring = SSHKeychain()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    /// True when the catalog value is present but does not decode. Opening the
    /// list uses this to offer an explicit reset. It does not read the Keychain.
    var metadataIsCorrupt: Bool {
        guard defaults.object(forKey: Self.catalogKey) != nil else { return false }
        guard let data = defaults.data(forKey: Self.catalogKey) else { return true }
        return (try? JSONDecoder().decode(SSHTerminalCatalog.self, from: data)) == nil
    }

    func load() -> [SSHTerminalProfile] {
        guard let data = defaults.data(forKey: Self.catalogKey),
              let catalog = try? JSONDecoder().decode(SSHTerminalCatalog.self, from: data) else { return [] }
        return catalog.profiles
    }

    func profile(id: UUID) -> SSHTerminalProfile? {
        load().first { $0.id == id }
    }

    func contains(_ id: UUID) -> Bool { profile(id: id) != nil }

    /// `sudoPassword` is a new sudo password for a device-key host. Without
    /// one, a saved sudo password stays only while host, port, user and method
    /// are unchanged; otherwise it is deleted and the host stops offering it.
    func save(_ profile: SSHTerminalProfile, password: String? = nil, sudoPassword: String? = nil) throws {
        let value = profile.normalized()
        var profiles = try editableProfiles()
        let old = profiles.first { $0.id == value.id }
        let retain = value.reusesSavedPassword(of: old)
        var stored = value
        if value.authentication == .password && value.savesPassword {
            if let password {
                let secret = try JSONEncoder().encode(BoundPassword(profileID: stored.id, profile: stored, password: password))
                try keychain.save(secret, account: Self.passwordAccount(for: stored.id), requirePresence: true)
            } else if !retain {
                throw SSHKeychainError.passwordRequired
            }
        } else {
            try deletePassword(for: stored.id)
            if stored.authentication != .password { stored.savesPassword = false }
        }
        if value.authentication == .deviceKey && value.savesSudoPassword {
            if let sudoPassword {
                let secret = try JSONEncoder().encode(BoundPassword(profileID: stored.id, profile: stored, password: sudoPassword))
                try keychain.save(secret, account: Self.sudoPasswordAccount(for: stored.id), requirePresence: true)
            } else if !value.reusesSudoPassword(of: old) {
                try keychain.delete(account: Self.sudoPasswordAccount(for: stored.id))
                stored.savesSudoPassword = false
            }
        } else {
            try keychain.delete(account: Self.sudoPasswordAccount(for: stored.id))
            stored.savesSudoPassword = false
        }
        if let index = profiles.firstIndex(where: { $0.id == stored.id }) {
            profiles[index] = stored
        } else {
            profiles.append(stored)
        }
        try write(profiles)
    }

    /// Must run off the main actor: Security may wait for user presence.
    func password(for expected: SSHTerminalProfile, authenticationContext: LAContext? = nil) throws -> String? {
        guard expected.reusesSavedPassword(of: profile(id: expected.id)) else {
            throw SSHKeychainError.passwordRequired
        }
        return try boundPassword(for: expected, authenticationContext: authenticationContext)
    }

    /// The saved password, behind the person's approval. An approval from the
    /// last few minutes for this host's password is reused (`SSHApprovalCache`);
    /// otherwise the system asks. The Keychain read runs off the main actor.
    func approvedPassword(for expected: SSHTerminalProfile, approvals: SSHApprovalCache = .shared) async throws -> String? {
        guard expected.reusesSavedPassword(of: profile(id: expected.id)) else {
            throw SSHKeychainError.passwordRequired
        }
        let store = self
        return try await approvals.approved(
            for: .savedPassword(account: Self.passwordAccount(for: expected.id)),
            evaluate: { context in
                try await SSHApprovalCache.evaluateDeviceOwner(context) { error in
                    switch (error as? LAError)?.code {
                    case .userCancel, .appCancel, .systemCancel: SSHKeychainError.status(errSecUserCanceled)
                    default: SSHKeychainError.status(errSecAuthFailed)
                    }
                }
            },
            use: { context in
                try await Task.detached { try store.boundPassword(for: expected, authenticationContext: context) }.value
            }
        )
    }

    /// The system prompt (Face ID, Touch ID, or the passcode) with `reason`.
    static let askDeviceOwner: @Sendable (LAContext, String) async throws -> Void = { context, reason in
        try await SSHApprovalCache.evaluateDeviceOwner(context, reason: reason) { error in
            switch (error as? LAError)?.code {
            case .userCancel, .appCancel, .systemCancel: SSHKeychainError.status(errSecUserCanceled)
            default: SSHKeychainError.status(errSecAuthFailed)
            }
        }
    }

    /// The password to type at a terminal prompt (`sudo`, `su`) for `expected`:
    /// its saved sign-in password, or the sudo password of a device-key host.
    /// The person approves every time, with `reason` on the system prompt; an
    /// approval kept for a sign-in (`SSHApprovalCache`) is never used. The bytes
    /// are the password's UTF-8, for the caller to clear after sending. The
    /// Keychain read runs off the main actor.
    func passwordToFill(
        for expected: SSHTerminalProfile,
        reason: String,
        evaluate: @escaping @Sendable (LAContext, String) async throws -> Void = SSHTerminalProfileStore.askDeviceOwner
    ) async throws -> Data {
        let saved = profile(id: expected.id)
        let account: String
        switch expected.authentication {
        case .password:
            guard expected.reusesSavedPassword(of: saved) else { throw SSHKeychainError.passwordRequired }
            account = Self.passwordAccount(for: expected.id)
        case .deviceKey:
            guard expected.reusesSudoPassword(of: saved) else { throw SSHKeychainError.passwordRequired }
            account = Self.sudoPasswordAccount(for: expected.id)
        }
        let context = LAContext()
        defer { context.invalidate() }
        // Leaving the prompt (the screen closed, the prompt ended) dismisses
        // the system sheet instead of leaving it up.
        try await withTaskCancellationHandler {
            try await evaluate(context, reason)
        } onCancel: {
            context.invalidate()
        }
        try Task.checkCancellation()
        let store = self
        return try await Task.detached {
            guard let password = try store.boundPassword(
                for: expected, account: account, authenticationContext: context
            ) else { throw SSHKeychainError.passwordRequired }
            return Data(password.utf8)
        }.value
    }

    /// That profile and its saved passwords only. Does not remove the device
    /// key or a trusted host key, and does not search the Keychain.
    func delete(id: UUID) throws {
        let profiles = try editableProfiles()
        try deletePassword(for: id)
        try keychain.delete(account: Self.sudoPasswordAccount(for: id))
        try write(profiles.filter { $0.id != id })
    }

    /// Drops a catalog value that does not decode. A readable catalog is left
    /// alone. Unreadable metadata cannot name its hosts' password accounts, so
    /// this does not read, write, or search the Keychain.
    func discardCorruptMetadata() {
        if metadataIsCorrupt { defaults.removeObject(forKey: Self.catalogKey) }
    }

    private func editableProfiles() throws -> [SSHTerminalProfile] {
        if metadataIsCorrupt { throw SSHTerminalProfileStoreError.corruptMetadata }
        return load()
    }

    private func write(_ profiles: [SSHTerminalProfile]) throws {
        defaults.set(try JSONEncoder().encode(SSHTerminalCatalog(profiles: profiles)), forKey: Self.catalogKey)
    }

    private func deletePassword(for id: UUID) throws {
        try keychain.delete(account: Self.passwordAccount(for: id))
    }

    private func boundPassword(
        for expected: SSHTerminalProfile,
        account: String? = nil,
        authenticationContext: LAContext?
    ) throws -> String? {
        guard let data = try keychain.load(
            account: account ?? Self.passwordAccount(for: expected.id), requirePresence: true,
            authenticationContext: authenticationContext
        ) else {
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
}

// Its members are a thread-safe `UserDefaults` and a `Sendable` Keychain wrapper.
extension SSHTerminalProfileStore: @unchecked Sendable {}
