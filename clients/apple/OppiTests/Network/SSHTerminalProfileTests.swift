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
        #expect(store.load() == nil)
        #expect(!SSHTerminalProfile().isConfigured)
        let profile = SSHTerminalProfile(host: "example.ts.net", port: 2222, username: "alice", authentication: .password)
        try store.save(profile)
        #expect(store.load() == profile)
        try store.delete()
        #expect(store.load() == nil)
    }

    @Test func savedPasswordIsDeviceOnlyPresenceProtectedAndProfileDeletionRemovesIt() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = SSHKeychain(service: name)
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        defer { try? store.delete() }
        let profile = SSHTerminalProfile(host: "example.ts.net", username: "alice", savesPassword: true)
        try store.save(profile, password: "disposable-fixture-password")
        #expect(store.load() == profile)
        var query = keychain.query(account: SSHTerminalProfileStore.passwordAccount)
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
        // Metadata is the entire defaults footprint, not a secret string.
        let metadata = try #require(defaults.data(forKey: SSHTerminalProfileStore.storageKey))
        #expect(!String(decoding: metadata, as: UTF8.self).contains("disposable-fixture-password"))
        try store.delete()
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
        #expect(store.load() == nil)
    }

    @Test func changingCredentialsCannotRetainAnOldPasswordAndDisablingSaveDeletesIt() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = SSHKeychain(service: name)
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        defer { try? store.delete() }
        let old = SSHTerminalProfile(host: "one.ts.net", username: "alice", savesPassword: true)
        try store.save(old, password: "fixture-only")
        var changed = old
        changed.host = "two.ts.net"
        #expect(throws: SSHKeychainError.self) { try store.save(changed) }
        #expect(store.load() == old)
        changed.savesPassword = false
        try store.save(changed)
        #expect(store.load() == changed)
        #expect(SecItemCopyMatching(keychain.query(account: SSHTerminalProfileStore.passwordAccount) as CFDictionary, nil) == errSecItemNotFound)
    }

    @Test func replacedSecretCannotCrossHostOrUsernameEvenBeforeMetadataChanges() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = SSHKeychain(service: name)
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        defer { try? store.delete() }
        let expected = SSHTerminalProfile(host: "one.ts.net", username: "alice", savesPassword: true)
        defaults.set(try JSONEncoder().encode(expected), forKey: SSHTerminalProfileStore.storageKey)
        // Fixture-only unprotected data lets this test isolate target binding
        // without a biometric prompt; the separate Security integration test
        // checks the production password item's protection policy.
        for (host, username) in [("two.ts.net", "alice"), ("one.ts.net", "bob")] {
            let record: [String: Any] = [
                "profile": ["host": host, "port": 22, "username": username,
                            "authentication": "password", "savesPassword": true],
                "password": "other-target-fixture",
            ]
            try keychain.save(JSONSerialization.data(withJSONObject: record), account: SSHTerminalProfileStore.passwordAccount)
            #expect(throws: SSHKeychainError.passwordRequired) { try store.password(for: expected) }
        }
    }

    @Test func corruptMetadataStillAllowsExplicitPasswordDeletion() throws {
        let name = "SSHTerminalProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = SSHKeychain(service: name)
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let profile = SSHTerminalProfile(host: "example.ts.net", username: "alice", savesPassword: true)
        try store.save(profile, password: "disposable-fixture-password")
        defer { try? store.delete() }
        defaults.set(Data("corrupt fixture".utf8), forKey: SSHTerminalProfileStore.storageKey)
        #expect(store.load() == nil)
        #expect(store.hasStoredProfile)
        try store.delete()
        #expect(!store.hasStoredProfile)
        #expect(SecItemCopyMatching(keychain.query(account: SSHTerminalProfileStore.passwordAccount) as CFDictionary, nil) == errSecItemNotFound)
    }

    @Test @MainActor func experimentGateHidesTerminalForPhoneAndPadUnlessAHostExists() {
        for idiom in [UIUserInterfaceIdiom.phone, .pad] {
            #expect(!WorkspaceSidebarPrimaryUtilities.items(for: idiom, sshTerminalEnabled: false, hasSSHProfile: true).contains { $0.target == .sshTerminal })
            #expect(!WorkspaceSidebarPrimaryUtilities.items(for: idiom, sshTerminalEnabled: true, hasSSHProfile: false).contains { $0.target == .sshTerminal })
            let visible = WorkspaceSidebarPrimaryUtilities.items(for: idiom, sshTerminalEnabled: true, hasSSHProfile: true)
            let mcp = visible.firstIndex { $0.target == .mcpServers }
            #expect(mcp != nil)
            if let mcp { #expect(visible[mcp + 1].target == .sshTerminal) }
        }
    }
}
