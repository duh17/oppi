import Foundation
import LocalAuthentication
import Security
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal profile and private Keychain", .serialized)
struct SSHTerminalProfileTests {
    @Test func emptyProfileNeverSuppliesADefaultHostAndMetadataRoundTrips() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: SSHKeychain(service: name))
        #expect(store.load().isEmpty)
        #expect(!SSHTerminalProfile().isConfigured)
        let profile = SSHTerminalProfile(host: "example.ts.net", port: 2222, username: "alice", authentication: .password)
        try store.save(profile)
        #expect(store.profile(id: profile.id) == profile)
        try store.delete(id: profile.id)
        #expect(store.load().isEmpty)
    }

    @Test func savedPasswordIsDeviceOnlyPresenceProtectedAndProfileDeletionRemovesIt() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = SSHKeychain(service: name)
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let profile = SSHTerminalProfile(host: "example.ts.net", username: "alice", savesPassword: true)
        defer { try? store.delete(id: profile.id) }
        try store.save(profile, password: "disposable-fixture-password")
        #expect(store.profile(id: profile.id) == profile)
        let account = SSHTerminalProfileStore.passwordAccount(for: profile.id)
        var query = keychain.query(account: account)
        query[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        #expect(attributes[kSecAttrAccessControl as String] != nil)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
        #expect((attributes[kSecAttrAccessGroup as String] as? String)?.contains("group.") != true)
        let metadata = try #require(defaults.data(forKey: SSHTerminalProfileStore.catalogKey))
        #expect(!String(decoding: metadata, as: UTF8.self).contains("disposable-fixture-password"))
        try store.delete(id: profile.id)
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
        #expect(store.profile(id: profile.id) == nil)
    }

    @Test func changingCredentialsCannotRetainAnOldPasswordAndDisablingSaveDeletesIt() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = SSHKeychain(service: name)
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let old = SSHTerminalProfile(host: "one.ts.net", username: "alice", savesPassword: true)
        defer { try? store.delete(id: old.id) }
        try store.save(old, password: "fixture-only")
        var changed = old
        changed.host = "two.ts.net"
        #expect(throws: SSHKeychainError.self) { try store.save(changed) }
        #expect(store.profile(id: old.id) == old)
        changed.savesPassword = false
        try store.save(changed)
        #expect(store.profile(id: old.id) == changed)
        #expect(SecItemCopyMatching(keychain.query(account: SSHTerminalProfileStore.passwordAccount(for: old.id)) as CFDictionary, nil) == errSecItemNotFound)
    }

    @Test func replacedSecretCannotCrossHostOrUsernameEvenBeforeMetadataChanges() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = SSHKeychain(service: name)
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let expected = SSHTerminalProfile(host: "one.ts.net", username: "alice", savesPassword: true)
        defer { try? keychain.delete(account: SSHTerminalProfileStore.passwordAccount(for: expected.id)) }
        defaults.set(try JSONEncoder().encode(SSHTerminalCatalog(profiles: [expected])), forKey: SSHTerminalProfileStore.catalogKey)
        // Fixture-only unprotected data lets this test isolate target binding
        // without a biometric prompt; the separate Security integration test
        // checks the production password item's protection policy.
        for (host, username) in [("two.ts.net", "alice"), ("one.ts.net", "bob")] {
            try keychain.save(try boundSecret(id: expected.id, host: host, username: username, password: "other-target-fixture"),
                              account: SSHTerminalProfileStore.passwordAccount(for: expected.id))
            #expect(throws: SSHKeychainError.passwordRequired) { try store.password(for: expected) }
        }
        let other = UUID()
        try keychain.save(try boundSecret(id: other, host: expected.host, username: expected.username, password: "swapped-id-fixture"),
                          account: SSHTerminalProfileStore.passwordAccount(for: expected.id))
        #expect(throws: SSHKeychainError.passwordRequired) { try store.password(for: expected) }
    }

    @Test func corruptMetadataStillAllowsExplicitPasswordDeletion() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = SSHKeychain(service: name)
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let unrelatedAccount = "host:example.ts.net:22"
        let otherProfile = UUID()
        defer {
            try? keychain.delete(account: SSHTerminalProfileStore.passwordAccount)
            try? keychain.delete(account: unrelatedAccount)
            try? keychain.delete(account: SSHTerminalProfileStore.passwordAccount(for: otherProfile))
        }
        try keychain.save(Data("legacy-fixture".utf8), account: SSHTerminalProfileStore.passwordAccount)
        try keychain.save(Data("trusted-host-key".utf8), account: unrelatedAccount)
        try keychain.save(Data("other-profile-fixture".utf8), account: SSHTerminalProfileStore.passwordAccount(for: otherProfile))
        defaults.set(Data("corrupt fixture".utf8), forKey: SSHTerminalProfileStore.catalogKey)
        #expect(store.metadataIsCorrupt)
        #expect(store.load().isEmpty)
        try store.deleteLegacyPasswordItem()
        store.discardCorruptMetadata()
        #expect(!store.metadataIsCorrupt)
        #expect(SecItemCopyMatching(keychain.query(account: SSHTerminalProfileStore.passwordAccount) as CFDictionary, nil) == errSecItemNotFound)
        #expect(SecItemCopyMatching(keychain.query(account: unrelatedAccount) as CFDictionary, nil) == errSecSuccess)
        #expect(SecItemCopyMatching(keychain.query(account: SSHTerminalProfileStore.passwordAccount(for: otherProfile)) as CFDictionary, nil) == errSecSuccess)
    }

    @Test func migrationWritesTheCatalogBeforeRemovingTheLegacyKeyAndDoesNotTouchKeychain() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = RecordingKeychain()
        let legacy = SSHTerminalLegacyProfile(host: "example.ts.net", port: 2222, username: "alice", savesPassword: true, startupCommand: "tmux")
        defaults.set(try JSONEncoder().encode(legacy), forKey: SSHTerminalProfileStore.storageKey)
        keychain.items[SSHTerminalProfileStore.passwordAccount] = Data("legacy-secret".utf8)
        defaults.events.removeAll()
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let migrated = try #require(store.load().first)
        let again = try #require(store.load().first)
        #expect(keychain.calls.isEmpty)
        #expect(keychain.items[SSHTerminalProfileStore.passwordAccount] == Data("legacy-secret".utf8))
        #expect(keychain.items[SSHTerminalProfileStore.passwordAccount(for: migrated.id)] == nil)
        #expect(defaults.data(forKey: SSHTerminalProfileStore.storageKey) == nil)
        #expect(defaults.data(forKey: SSHTerminalProfileStore.catalogKey) != nil)
        #expect(migrated.host == legacy.host && migrated.port == legacy.port && migrated.username == legacy.username)
        #expect(migrated.startupCommand == "tmux")
        #expect(migrated.passwordUsesLegacyAccount)
        #expect(migrated.id == again.id)
        let setIndex = try #require(defaults.events.firstIndex { $0 == "set:\(SSHTerminalProfileStore.catalogKey)" })
        let removeIndex = try #require(defaults.events.firstIndex { $0 == "remove:\(SSHTerminalProfileStore.storageKey)" })
        #expect(setIndex < removeIndex)
        let unsaved = SSHTerminalLegacyProfile(host: "other.ts.net", username: "bob", savesPassword: false)
        defaults.set(try JSONEncoder().encode(unsaved), forKey: SSHTerminalProfileStore.storageKey)
        defaults.removeObject(forKey: SSHTerminalProfileStore.catalogKey)
        let plain = try #require(SSHTerminalProfileStore(defaults: defaults, keychain: keychain).load().first)
        #expect(!plain.passwordUsesLegacyAccount)
        #expect(keychain.calls.isEmpty)
    }

    @Test func passwordRebindRunsOnlyInsidePasswordForAndAFailedRebindKeepsTheLegacyItem() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = RecordingKeychain()
        let legacy = SSHTerminalLegacyProfile(host: "example.ts.net", username: "alice", savesPassword: true)
        defaults.set(try JSONEncoder().encode(legacy), forKey: SSHTerminalProfileStore.storageKey)
        keychain.items[SSHTerminalProfileStore.passwordAccount] = try legacySecret(host: "example.ts.net", username: "alice", password: "rebind-fixture")
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let migrated = try #require(store.load().first)
        #expect(keychain.calls.isEmpty)
        let perID = SSHTerminalProfileStore.passwordAccount(for: migrated.id)
        keychain.failSaveAccounts.insert(perID)
        #expect(throws: SSHKeychainError.self) { try store.password(for: migrated) }
        #expect(keychain.items[SSHTerminalProfileStore.passwordAccount] != nil)
        #expect(!keychain.calls.contains { $0.kind == .delete })
        #expect(store.profile(id: migrated.id)?.passwordUsesLegacyAccount == true)

        keychain.failSaveAccounts.removeAll()
        keychain.calls.removeAll()
        #expect(try store.password(for: migrated) == "rebind-fixture")
        #expect(keychain.items[SSHTerminalProfileStore.passwordAccount] == nil)
        #expect(keychain.items[perID] != nil)
        #expect(store.profile(id: migrated.id)?.passwordUsesLegacyAccount == false)
        #expect(keychain.calls.contains { $0.kind == .load && $0.account == SSHTerminalProfileStore.passwordAccount && $0.requirePresence })
        #expect(keychain.calls.contains { $0.kind == .save && $0.account == perID && $0.requirePresence })
        let saveIndex = try #require(keychain.calls.firstIndex { $0.kind == .save && $0.account == perID })
        let deleteIndex = try #require(keychain.calls.firstIndex { $0.kind == .delete && $0.account == SSHTerminalProfileStore.passwordAccount })
        #expect(saveIndex < deleteIndex)

        keychain.calls.removeAll()
        #expect(try store.password(for: migrated) == "rebind-fixture")
        #expect(!keychain.calls.contains { $0.account == SSHTerminalProfileStore.passwordAccount })
    }

    @Test func profilesIsolatePasswordsAndASwappedSecretCannotBeRead() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = RecordingKeychain()
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let shared = SSHTerminalProfile(host: "one.ts.net", username: "alice", savesPassword: true, startupCommand: "tmux new -A -s main")
        let other = SSHTerminalProfile(host: "one.ts.net", username: "alice", savesPassword: true, startupCommand: "herdr")
        try store.save(shared, password: "shared-secret")
        try store.save(other, password: "other-secret")
        #expect(shared.id != other.id)
        #expect(try store.password(for: shared) == "shared-secret")
        #expect(try store.password(for: other) == "other-secret")

        var moved = shared
        moved.host = "two.ts.net"
        #expect(throws: SSHKeychainError.self) { try store.save(moved) }
        var renamed = shared
        renamed.username = "bob"
        #expect(throws: SSHKeychainError.self) { try store.save(renamed) }
        var otherPort = other
        otherPort.port = 2222
        #expect(throws: SSHKeychainError.self) { try store.save(otherPort) }
        #expect(store.profile(id: shared.id) == shared)
        #expect(store.profile(id: other.id) == other)
        #expect(try store.password(for: other) == "other-secret")

        keychain.items[SSHTerminalProfileStore.passwordAccount(for: other.id)] = keychain.items[SSHTerminalProfileStore.passwordAccount(for: shared.id)]
        #expect(throws: SSHKeychainError.passwordRequired) { try store.password(for: other) }
        #expect(try store.password(for: shared) == "shared-secret")

        var deviceKey = shared
        deviceKey.authentication = .deviceKey
        try store.save(deviceKey)
        #expect(store.profile(id: shared.id)?.authentication == .deviceKey)
        #expect(store.profile(id: shared.id)?.savesPassword == false)
        #expect(keychain.items[SSHTerminalProfileStore.passwordAccount(for: shared.id)] == nil)
        #expect(keychain.items[SSHTerminalProfileStore.passwordAccount(for: other.id)] != nil)
    }

    @Test func deletingOneProfileRemovesOnlyItsPassword() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = RecordingKeychain()
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let legacy = SSHTerminalLegacyProfile(host: "old.ts.net", username: "alice", savesPassword: true)
        defaults.set(try JSONEncoder().encode(legacy), forKey: SSHTerminalProfileStore.storageKey)
        keychain.items[SSHTerminalProfileStore.passwordAccount] = try legacySecret(host: "old.ts.net", username: "alice", password: "legacy-fixture")
        let migrated = try #require(store.load().first)
        let second = SSHTerminalProfile(host: "old.ts.net", username: "alice", savesPassword: true, startupCommand: "herdr")
        try store.save(second, password: "second-secret")
        let hostKey = "host:old.ts.net:22"
        let deviceKey = "oppi.ssh.identity.presence.v2"
        keychain.items[hostKey] = Data("trusted".utf8)
        keychain.items[deviceKey] = Data("device-key".utf8)
        try store.delete(id: migrated.id)
        #expect(store.profile(id: migrated.id) == nil)
        #expect(store.profile(id: second.id)?.startupCommand == "herdr")
        #expect(keychain.items[SSHTerminalProfileStore.passwordAccount] == nil)
        #expect(keychain.items[SSHTerminalProfileStore.passwordAccount(for: migrated.id)] == nil)
        #expect(try store.password(for: second) == "second-secret")
        #expect(keychain.items[hostKey] == Data("trusted".utf8))
        #expect(keychain.items[deviceKey] == Data("device-key".utf8))
        let deleted = Set(keychain.calls.filter { $0.kind == .delete }.map(\.account))
        #expect(deleted.contains(SSHTerminalProfileStore.passwordAccount(for: migrated.id)))
        #expect(deleted.contains(SSHTerminalProfileStore.passwordAccount))
        #expect(!deleted.contains(hostKey))
        #expect(!deleted.contains(deviceKey))
        #expect(!deleted.contains(SSHTerminalProfileStore.passwordAccount(for: second.id)))
    }

    @Test func hostRowShowsUserAtHostPortWhenNot22AndStartupCommandOrLoginShell() {
        let custom = SSHTerminalProfile(host: "example.ts.net", port: 2222, username: "alice", startupCommand: "herdr")
        #expect(custom.endpointLabel == "alice@example.ts.net")
        #expect(custom.portLabel == "Port 2222")
        #expect(custom.startupLabel == "herdr")
        let shell = SSHTerminalProfile(host: "example.ts.net", username: "alice", startupCommand: "  ")
        #expect(shell.portLabel == nil)
        #expect(shell.startupLabel == "Login shell")
    }

    @Test @MainActor func experimentGateHidesTerminalForPhoneAndPadUnlessAHostExists() throws {
        for idiom in [UIUserInterfaceIdiom.phone, .pad] {
            #expect(!WorkspaceSidebarPrimaryUtilities.items(for: idiom, sshTerminalEnabled: false, hasSSHProfile: true).contains { $0.target == .sshTerminal })
            #expect(!WorkspaceSidebarPrimaryUtilities.items(for: idiom, sshTerminalEnabled: true, hasSSHProfile: false).contains { $0.target == .sshTerminal })
            let visible = WorkspaceSidebarPrimaryUtilities.items(for: idiom, sshTerminalEnabled: true, hasSSHProfile: true)
            let mcp = visible.firstIndex { $0.target == .mcpServers }
            #expect(mcp != nil)
            if let mcp { #expect(visible[mcp + 1].target == .sshTerminal) }
        }
        let configured = SSHTerminalCatalog(profiles: [SSHTerminalProfile(host: "example.ts.net", username: "alice")])
        #expect(SSHTerminalProfileStore.hasConfiguredHost(catalogData: try JSONEncoder().encode(configured), legacyData: Data()))
        #expect(!SSHTerminalProfileStore.hasConfiguredHost(catalogData: Data(), legacyData: Data()))
        let legacy = try JSONEncoder().encode(SSHTerminalLegacyProfile(host: "example.ts.net", username: "alice"))
        #expect(SSHTerminalProfileStore.hasConfiguredHost(catalogData: Data(), legacyData: legacy))
    }
}

private func boundSecret(id: UUID, host: String, username: String, password: String) throws -> Data {
    let record: [String: Any] = [
        "profileID": id.uuidString,
        "profile": [
            "id": id.uuidString,
            "host": host,
            "port": 22,
            "username": username,
            "authentication": "password",
            "savesPassword": true,
            "passwordUsesLegacyAccount": false,
        ],
        "password": password,
    ]
    return try JSONSerialization.data(withJSONObject: record)
}

private func legacySecret(host: String, username: String, password: String) throws -> Data {
    let record: [String: Any] = [
        "profile": [
            "host": host,
            "port": 22,
            "username": username,
            "authentication": "password",
            "savesPassword": true,
        ],
        "password": password,
    ]
    return try JSONSerialization.data(withJSONObject: record)
}

private final class RecordingKeychain: SSHCredentialStoring, @unchecked Sendable {
    struct Call: Equatable {
        enum Kind: Equatable { case load, save, delete }
        var kind: Kind
        var account: String
        var requirePresence: Bool
    }

    var items: [String: Data] = [:]
    var calls: [Call] = []
    var failSaveAccounts: Set<String> = []

    func load(account: String, requirePresence: Bool) throws -> Data? {
        calls.append(Call(kind: .load, account: account, requirePresence: requirePresence))
        return items[account]
    }

    func save(_ data: Data, account: String, requirePresence: Bool) throws {
        calls.append(Call(kind: .save, account: account, requirePresence: requirePresence))
        if failSaveAccounts.contains(account) { throw SSHKeychainError.status(errSecAuthFailed) }
        items[account] = data
    }

    func delete(account: String) throws {
        calls.append(Call(kind: .delete, account: account, requirePresence: false))
        items.removeValue(forKey: account)
    }
}

private final class RecordingDefaults: UserDefaults, @unchecked Sendable {
    var events: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        events.append("set:\(defaultName)")
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        events.append("remove:\(defaultName)")
        super.removeObject(forKey: defaultName)
    }
}
