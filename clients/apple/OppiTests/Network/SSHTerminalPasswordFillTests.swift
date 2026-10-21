import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Oppi

@Suite("SSH terminal Fill Password", .serialized)
struct SSHTerminalPasswordFillTests {
    // MARK: Offer

    @Test func offeredOnlyAtAPromptOnTheLiveScreenForAHostWithAPassword() {
        let password = SSHTerminalProfile(host: "a.ts.net", username: "duh", authentication: .password, savesPassword: true)
        let sudo = SSHTerminalProfile(host: "a.ts.net", username: "duh", authentication: .deviceKey, savesSudoPassword: true)
        let none = SSHTerminalProfile(host: "a.ts.net", username: "duh", authentication: .deviceKey)
        let unsaved = SSHTerminalProfile(host: "a.ts.net", username: "duh", authentication: .password)

        func offered(_ profile: SSHTerminalProfile?, secure: Bool = true, history: Bool = false, connected: Bool = true) -> Bool {
            SSHTerminalPasswordFill.isOffered(profile: profile, secureEntry: secure, inHistory: history, connected: connected)
        }
        #expect(offered(password))
        #expect(offered(sudo))
        #expect(!offered(none), "a device-key host with no sudo password has nothing to fill")
        #expect(!offered(unsaved), "a password typed at connect is not kept")
        #expect(!offered(nil))
        #expect(!offered(password, secure: false), "no prompt, no key")
        #expect(!offered(sudo, history: true), "never while reading history")
        #expect(!offered(sudo, connected: false))
    }

    @Test func aPasswordHostFillsItsSignInPasswordAndOnlyAKeyHostKeepsASudoPassword() {
        let key = SSHTerminalProfile(host: "a.ts.net", username: "duh", authentication: .password, savesSudoPassword: true).normalized()
        #expect(!key.savesSudoPassword, "a password host fills its sign-in password, never a second one")
        let device = SSHTerminalProfile(host: "a.ts.net", username: "duh", authentication: .deviceKey, savesPassword: true, savesSudoPassword: true).normalized()
        #expect(!device.savesPassword)
        #expect(device.savesSudoPassword)
        #expect(device.hasPasswordToFill)
    }

    @Test func catalogsSavedBeforeTheSudoPasswordStillDecode() throws {
        let id = UUID()
        let old = Data(#"{"profiles":[{"id":"\#(id.uuidString)","host":"a.ts.net","port":22,"username":"duh","authentication":"deviceKey","savesPassword":false}]}"#.utf8)
        let catalog = try JSONDecoder().decode(SSHTerminalCatalog.self, from: old)
        #expect(catalog.profiles.first?.savesSudoPassword == false)
        #expect(catalog.profiles.first?.id == id)
    }

    // MARK: Keychain

    @Test func sudoPasswordIsBoundToTheHostAndLeavesWithIt() async throws {
        let name = "SSHTerminalPasswordFillTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = FakeKeychain()
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let profile = SSHTerminalProfile(host: "a.ts.net", username: "duh", authentication: .deviceKey, savesSudoPassword: true)
        let other = SSHTerminalProfile(host: "a.ts.net", username: "duh", authentication: .deviceKey, savesSudoPassword: true, startupCommand: "herdr")

        try store.save(profile, sudoPassword: "sudo-fixture")
        try store.save(other, sudoPassword: "other-fixture")
        let account = SSHTerminalProfileStore.sudoPasswordAccount(for: profile.id)
        #expect(account.contains(profile.id.uuidString))
        #expect(account != SSHTerminalProfileStore.sudoPasswordAccount(for: other.id))
        #expect(account != SSHTerminalProfileStore.passwordAccount(for: profile.id))
        #expect(keychain.presence[account] == true, "kept behind the device-owner check like a saved sign-in password")
        let catalog = try #require(defaults.data(forKey: SSHTerminalProfileStore.catalogKey))
        #expect(!String(decoding: catalog, as: UTF8.self).contains("sudo-fixture"))

        let approve: @Sendable (LAContext, String) async throws -> Void = { _, _ in }
        #expect(try await store.passwordToFill(for: profile, reason: "r", evaluate: approve) == Data("sudo-fixture".utf8))
        #expect(try await store.passwordToFill(for: other, reason: "r", evaluate: approve) == Data("other-fixture".utf8))

        // A secret copied onto another host's item does not read there.
        keychain.items[SSHTerminalProfileStore.sudoPasswordAccount(for: other.id)] = keychain.items[account]
        await #expect(throws: SSHKeychainError.passwordRequired) {
            _ = try await store.passwordToFill(for: other, reason: "r", evaluate: approve)
        }

        try store.delete(id: profile.id)
        #expect(keychain.items[account] == nil)
        #expect(keychain.items[SSHTerminalProfileStore.sudoPasswordAccount(for: other.id)] != nil)
    }

    @Test func changingTheHostOrTurningItOffDropsTheSudoPassword() throws {
        let name = "SSHTerminalPasswordFillTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = FakeKeychain()
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let profile = SSHTerminalProfile(host: "a.ts.net", username: "duh", authentication: .deviceKey, savesSudoPassword: true)
        let account = SSHTerminalProfileStore.sudoPasswordAccount(for: profile.id)
        try store.save(profile, sudoPassword: "sudo-fixture")

        // Unchanged: saving again keeps it without a new password.
        try store.save(profile)
        #expect(keychain.items[account] != nil)
        #expect(store.profile(id: profile.id)?.savesSudoPassword == true)

        let changes: [(inout SSHTerminalProfile) -> Void] = [
            { $0.host = "b.ts.net" }, { $0.port = 2222 }, { $0.username = "root" },
        ]
        for change in changes {
            try store.save(profile, sudoPassword: "sudo-fixture")
            var moved = profile
            change(&moved)
            try store.save(moved)
            #expect(keychain.items[account] == nil)
            #expect(store.profile(id: profile.id)?.savesSudoPassword == false)
        }

        try store.save(profile, sudoPassword: "sudo-fixture")
        var off = profile
        off.savesSudoPassword = false
        try store.save(off)
        #expect(keychain.items[account] == nil)
    }

    @Test func aPasswordHostFillsItsSavedSignInPassword() async throws {
        let name = "SSHTerminalPasswordFillTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: FakeKeychain())
        let profile = SSHTerminalProfile(host: "a.ts.net", username: "duh", authentication: .password, savesPassword: true)
        try store.save(profile, password: "sign-in-fixture")
        let bytes = try await store.passwordToFill(for: profile, reason: "r") { _, _ in }
        #expect(bytes == Data("sign-in-fixture".utf8))
    }

    // MARK: Fill

    @Test @MainActor func everyFillAsksNamingTheHostAndSendsThePasswordExactly() async throws {
        let fixture = try Fixture(password: "p@ss wörd!\u{1F511}")
        for _ in 0..<2 {
            let outcome = await SSHTerminalPasswordFill.fill(
                profile: fixture.profile, store: fixture.store, evaluate: fixture.evaluate,
                stillOffered: { true }, send: { fixture.sent.append($0); return true }
            )
            #expect(outcome == .filled)
        }
        let reasons = await fixture.asked.reasons
        #expect(reasons == ["Fill the password for duh@mac-studio", "Fill the password for duh@mac-studio"],
                "the person is asked each time; a recent approval is not reused")
        let expected = Data("p@ss wörd!\u{1F511}".utf8)
        #expect(fixture.sent == [expected, expected])
        for bytes in fixture.sent {
            #expect(!bytes.contains(0x0D) && !bytes.contains(0x0A), "Return is the person's to press")
            #expect(!bytes.starts(with: Data("\u{1B}[200~".utf8)), "no bracketed paste")
        }
    }

    @Test @MainActor func aCancelledOrFailedCheckSendsNothingAndReadsNothing() async throws {
        for failure in [SSHKeychainError.status(errSecUserCanceled), .status(errSecAuthFailed)] {
            let fixture = try Fixture(password: "secret", evaluateFails: failure)
            let outcome = await SSHTerminalPasswordFill.fill(
                profile: fixture.profile, store: fixture.store, evaluate: fixture.evaluate,
                stillOffered: { true }, send: { fixture.sent.append($0); return true }
            )
            #expect(fixture.sent.isEmpty)
            #expect(fixture.keychain.loads == 0, "the Keychain is not read without approval")
            if failure == .status(errSecUserCanceled) {
                #expect(outcome == .cancelled)
            } else {
                guard case .failed = outcome else { Issue.record("expected a failure, got \(outcome)"); continue }
            }
        }
    }

    @Test @MainActor func nothingIsSentWhenThePromptEndedWhileTheCheckWasUp() async throws {
        let fixture = try Fixture(password: "secret")
        let outcome = await SSHTerminalPasswordFill.fill(
            profile: fixture.profile, store: fixture.store, evaluate: fixture.evaluate,
            stillOffered: { false }, send: { fixture.sent.append($0); return true }
        )
        #expect(outcome == .cancelled)
        #expect(fixture.sent.isEmpty, "a password typed at a shell prompt would show on screen")
    }

    @Test @MainActor func aProfileEditedAfterTheOfferCannotFillTheOldSecret() async throws {
        let fixture = try Fixture(password: "secret")
        var moved = fixture.profile
        moved.host = "elsewhere.ts.net"
        let outcome = await SSHTerminalPasswordFill.fill(
            profile: moved, store: fixture.store, evaluate: fixture.evaluate,
            stillOffered: { true }, send: { fixture.sent.append($0); return true }
        )
        guard case .failed = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(fixture.sent.isEmpty)
    }

    @Test @MainActor func thePasswordReachesThePTYAsPlainBytesWithoutReturn() async throws {
        let fixture = try Fixture(password: "sudo pw")
        let channel = try SSHTerminalChannel()
        let connection = RecordingConnection()
        channel.opened(connection)
        let outcome = await SSHTerminalPasswordFill.fill(
            profile: fixture.profile, store: fixture.store, evaluate: fixture.evaluate,
            stillOffered: { true }, send: { channel.send($0) }
        )
        #expect(outcome == .filled)
        var received = Data()
        for await chunk in connection.chunks {
            received.append(chunk)
            if received.count >= 7 { break }
        }
        #expect(received == Data("sudo pw".utf8))
    }
}

// MARK: - Fixtures

@MainActor
private final class Fixture {
    let profile: SSHTerminalProfile
    let store: SSHTerminalProfileStore
    let keychain: FakeKeychain
    let asked = AskedReasons()
    let evaluate: @Sendable (LAContext, String) async throws -> Void
    var sent: [Data] = []

    init(password: String, evaluateFails: SSHKeychainError? = nil) throws {
        let name = "SSHTerminalPasswordFillTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let keychain = FakeKeychain()
        let store = SSHTerminalProfileStore(defaults: defaults, keychain: keychain)
        let profile = SSHTerminalProfile(host: "mac-studio", username: "duh", authentication: .deviceKey, savesSudoPassword: true)
        try store.save(profile, sudoPassword: password)
        keychain.loads = 0
        let asked = asked
        self.profile = profile
        self.store = store
        self.keychain = keychain
        evaluate = { _, reason in
            await asked.record(reason)
            if let evaluateFails { throw evaluateFails }
        }
    }
}

private actor AskedReasons {
    private(set) var reasons: [String] = []
    func record(_ reason: String) { reasons.append(reason) }
}

private final class FakeKeychain: SSHCredentialStoring, @unchecked Sendable {
    var items: [String: Data] = [:]
    var presence: [String: Bool] = [:]
    var loads = 0

    func load(account: String, requirePresence: Bool, authenticationContext: LAContext?) throws -> Data? {
        loads += 1
        return items[account]
    }

    func save(_ data: Data, account: String, requirePresence: Bool) throws {
        items[account] = data
        presence[account] = requirePresence
    }

    func delete(account: String) throws {
        items.removeValue(forKey: account)
        presence.removeValue(forKey: account)
    }
}

private actor RecordingConnection: SSHTerminalConnection {
    nonisolated let chunks: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation

    init() { (chunks, sink) = AsyncStream.makeStream() }

    func send(_ bytes: Data) async throws { sink.yield(bytes) }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        SSHExecResult(output: Data(), errorOutput: Data(), exitStatus: 0)
    }
    func checkAlive() async throws {}
    nonisolated func close() {}
    func cancel() async { sink.finish() }
}
