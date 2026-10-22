import Foundation
import GhosttyVt
import LocalAuthentication
import Synchronization
import Testing
import UIKit
@testable import Oppi

private final class QuietConnection: SSHTerminalConnection {
    func close() {}
    func send(_ bytes: Data) async throws {}
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func run(_ command: String, input: Data) async throws -> SSHExecResult { throw SSHConnectionError.commandRequestRejected }
    func checkAlive() async throws {}
    func cancel() async {}
}

/// Saved hosts and passwords for a test: its own defaults suite and an
/// in-memory keychain, so nothing reaches the app's real store.
private struct IsolatedProfiles {
    private final class MemoryKeychain: SSHCredentialStoring {
        private let items = Mutex<[String: Data]>([:])
        func load(account: String, requirePresence: Bool, authenticationContext: LAContext?) throws -> Data? {
            items.withLock { $0[account] }
        }
        func save(_ data: Data, account: String, requirePresence: Bool) throws {
            items.withLock { $0[account] = data }
        }
        func delete(account: String) throws { items.withLock { $0[account] = nil } }
    }

    /// UserDefaults is not Sendable, so the closure reopens the same named suite.
    private let suite = "SSHTerminalSwitcherTests.profiles.\(UUID().uuidString)"
    private let keychain = MemoryKeychain()

    var make: @Sendable () -> SSHTerminalProfileStore {
        { [suite, keychain] in
            SSHTerminalProfileStore(defaults: UserDefaults(suiteName: suite)!, keychain: keychain)
        }
    }
}

@Suite("SSH terminal switcher", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalSwitcherTests {
    private let studio = SSHTerminalProfile(host: "mac-studio", username: "chen")
    private let mini = SSHTerminalProfile(host: "mac-mini", username: "chen", startupCommand: "herdr")

    private func makeRegistry() -> SSHTerminalRegistry {
        SSHTerminalRegistry(
            backgroundTasks: FakeBackgroundTasks(), sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
    }

    private func closeEverything(_ registry: SSHTerminalRegistry) {
        // Every entry, not only the connected ones: a dropped terminal's tasks
        // must not outlive the test.
        registry.closeAll(reason: "done")
    }

    @discardableResult
    private func open(
        _ registry: SSHTerminalRegistry, _ profile: SSHTerminalProfile, folder: String? = nil, command: String? = nil
    ) throws -> SSHTerminalChannel {
        let channel = try SSHTerminalChannel()
        channel.opened(QuietConnection())
        registry.adopt(channel, profile: profile, folder: folder, folderCommand: command, queue: SSHTerminalEventQueue())
        return channel
    }

    // MARK: What the menu lists

    @Test func theMenuListsEveryOpenTerminalWithTheCurrentOneChecked() throws {
        let registry = makeRegistry()
        let folder = try open(registry, studio, folder: "~/workspace/oppi")
        let plain = try open(registry, studio)
        let other = try open(registry, mini)
        // A terminal that is not connected is not open.
        let dead = try open(registry, SSHTerminalProfile(host: "gone", username: "chen"))
        dead.close(reason: "done")

        let terminals = registry.openTerminals()
        #expect(terminals.map { ObjectIdentifier($0.channel) } == [other, plain, folder].map(ObjectIdentifier.init))

        let items = SSHTerminalSwitcher.items(terminals: terminals, current: plain)
        #expect(items.map(\.title) == ["chen@mac-mini", "chen@mac-studio", "chen@mac-studio"])
        #expect(items.map(\.subtitle) == ["herdr", "Login shell", "oppi"])
        #expect(items.map(\.isCurrent) == [false, true, false])
        #expect(items.allSatisfy { $0.state == .connected })
    }

    @Test func aBlockedProgramShowsInItsRowAndOnlyThere() throws {
        let registry = makeRegistry()
        let quiet = try open(registry, studio)
        let waiting = try open(registry, mini)
        waiting.programStatus.apply(.init(
            state: GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, kind: GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION
        ))
        let items = SSHTerminalSwitcher.items(terminals: registry.openTerminals(), current: quiet)
        #expect(items[0].state == .blocked(.needsApproval))
        #expect(items[0].subtitle == "herdr \u{00B7} \(SessionStatusKind.needsApproval.label)")
        #expect(items[1].state == .connected)
    }

    @Test func aFolderShowsItsLastComponent() {
        #expect(SSHTerminalSwitcher.folderName("~/workspace/oppi") == "oppi")
        #expect(SSHTerminalSwitcher.folderName("/Users/me/work/") == "work")
        #expect(SSHTerminalSwitcher.folderName("~") == "~")
        #expect(SSHTerminalSwitcher.folderName("/") == "/")
    }

    @Test func menuRowsCarryStableIdentifiersAndTheCheckmarkAndReportTheirIndex() throws {
        let registry = makeRegistry()
        let first = try open(registry, studio)
        try open(registry, mini)
        let items = SSHTerminalSwitcher.items(terminals: registry.openTerminals(), current: first)
        var chosen = [Int]()
        let elements = SSHTerminalSwitcher.menuElements(items: items, themeID: .dark) { chosen.append($0) }
        let actions = elements.compactMap { $0 as? UIAction }
        #expect(actions.map(\.accessibilityIdentifier) == ["sshTerminal.switcher.0", "sshTerminal.switcher.1"])
        #expect(actions.map(\.state) == [.off, .on]) // mini sorts first; studio is current
        actions[0].performWithSender(nil, target: nil)
        #expect(chosen == [0])
    }

    // MARK: Swapping

    @Test func showingATerminalSwapsTheSessionToItsLiveChannelWithoutConnecting() throws {
        let registry = makeRegistry()
        let session = SSHTerminalConnectSession(registry: registry)
        let plain = try open(registry, studio)
        let tmux = try open(registry, studio, folder: "~/workspace/oppi", command: "tmux new -A -s oppi")
        let plainTerminal = try #require(registry.terminal(for: studio.id))
        let folderTerminal = try #require(registry.terminal(for: studio.id, folder: "~/workspace/oppi"))

        session.show(plainTerminal)
        #expect(session.channel === plain)
        #expect(session.folder == nil)

        session.show(folderTerminal)
        #expect(session.channel === tmux)
        #expect(session.folder == "~/workspace/oppi")
        // What Reconnect needs for that terminal, not the one left.
        #expect(session.folderTerminalCommand == "tmux new -A -s oppi")
        #expect(session.connectedProfile == studio)
        #expect(session.showsTerminal)
        #expect(!session.connecting)
        // Nothing closed or replaced: both are the registry's live channels.
        #expect(plain.connected && tmux.connected)
        #expect(registry.openTerminals().count == 2)
        #expect(registry.terminal(for: studio.id)?.channel === plain)
    }

    @Test func aTerminalThatEndedMeanwhileIsNotShown() throws {
        let registry = makeRegistry()
        let session = SSHTerminalConnectSession(registry: registry)
        let kept = try open(registry, studio)
        let ending = try open(registry, mini)
        let stale = try #require(registry.terminal(for: mini.id))
        session.show(try #require(registry.terminal(for: studio.id)))
        ending.close(reason: "Closed by you.")

        session.show(stale)
        #expect(session.channel === kept)
        #expect(session.connectedProfile == studio)
    }

    // MARK: The screen

    /// `appRoot` publishes the app's services above the screen, as the app does;
    /// presenting a sheet from it (the password prompt) needs them.
    private func mount(_ screen: UIViewController, appRoot: AppRootEnvironment? = nil) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if let appRoot { window.traitOverrides.appRootEnvironment = appRoot }
        window.rootViewController = RouterNavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews { if let hit = find(identifier, in: child) { return hit } }
        return nil
    }

    @Test func reconnectAfterASwitchAsksForTheShownHostsPasswordAndDialsThatHost() async throws {
        let registry = makeRegistry()
        let session = SSHTerminalConnectSession(registry: registry, profileStore: IsolatedProfiles().make)
        // Two password hosts with nothing saved: any reconnect asks.
        let hostA = SSHTerminalProfile(host: "reconnect-a.invalid", username: "alice")
        let hostB = SSHTerminalProfile(host: "reconnect-b.invalid", username: "bob")
        try open(registry, hostA)
        let channelB = try open(registry, hostB, folder: "~/proj", command: "tmux new -A -s proj")
        session.show(try #require(registry.terminal(for: hostA.id)))

        // The screen that opened this session is host A's.
        var openingScreenSubmitted = [String]()
        var openingScreenProfile = hostA
        let opening = UIViewController()
        let window = try mount(opening, appRoot: makeTestAppRoot())
        defer {
            window.isHidden = true
            window.rootViewController = nil
            closeEverything(registry)
        }
        let chrome = SSHTerminalConnectChrome(
            host: opening, session: session,
            profile: { openingScreenProfile },
            setProfile: { openingScreenProfile = $0 },
            editHost: {},
            submitPassword: { openingScreenSubmitted.append($0) },
            onSaved: { _ in }
        )
        chrome.sync() // pushes the terminal over it, as the app does
        try await Task.sleep(for: .milliseconds(100))

        session.show(try #require(registry.terminal(for: hostB.id, folder: "~/proj")))
        channelB.close(reason: "The connection dropped.")
        session.reconnect()
        #expect(session.passwordPrompt)
        chrome.sync()
        try await Task.sleep(for: .milliseconds(100))

        let sheet = try #require(
            (opening.presentedViewController as? UINavigationController)?.viewControllers.first
                as? SSHTerminalPasswordViewController
        )
        #expect(sheet.endpointLabel == hostB.endpointLabel, "the sheet names the host being reconnected")

        sheet.submit("password-for-b")
        #expect(openingScreenSubmitted.isEmpty, "the opening screen's own connect, bound to host A, is never used")
        #expect(openingScreenProfile == hostA)
        #expect(session.connecting)
        #expect(session.attemptedHost == hostB.host, "the dial is for host B")
        #expect(session.connectedProfile == hostB)
        #expect(session.folder == "~/proj")
        #expect(session.folderTerminalCommand == "tmux new -A -s proj")
        session.cancel()
    }

    @Test func aFormTurningOnSavePasswordAfterAnotherHostsReconnectAsksForItsOwnHost() async throws {
        let registry = makeRegistry()
        let profiles = IsolatedProfiles()
        let session = SSHTerminalConnectSession(registry: registry, profileStore: profiles.make)
        let hostA = SSHTerminalProfile(host: "form-a.invalid", username: "alice")
        let hostB = SSHTerminalProfile(host: "form-b.invalid", username: "bob")
        let channelA = try open(registry, hostA)
        let channelB = try open(registry, hostB, folder: "~/proj", command: "tmux new -A -s proj")

        // A's form turns Save Password on, with no password typed.
        var editedA = hostA
        editedA.savesPassword = true
        var submittedByForm = [String]()
        let opening = UIViewController()
        let window = try mount(opening, appRoot: makeTestAppRoot())
        defer {
            window.isHidden = true
            window.rootViewController = nil
            closeEverything(registry)
        }
        let chrome = SSHTerminalConnectChrome(
            host: opening, session: session,
            profile: { editedA },
            setProfile: { _ in },
            editHost: {},
            submitPassword: { password in
                submittedByForm.append(password)
                session.connect(profile: editedA, suppliedPassword: password)
            },
            onSaved: { _ in }
        )

        // Switch to B and reconnect it: the prompt target is now B's.
        session.show(try #require(registry.terminal(for: hostB.id, folder: "~/proj")))
        channelB.close(reason: "The connection dropped.")
        session.reconnect()
        #expect(session.promptTarget?.profile.id == hostB.id)
        session.cancel()
        session.passwordPrompt = false

        // Back on A, Connect from its form.
        session.show(try #require(registry.terminal(for: hostA.id)))
        chrome.sync() // pushes the terminal over the form, as the app does
        try await Task.sleep(for: .milliseconds(100))
        session.connect(profile: editedA)
        #expect(session.passwordPrompt)
        #expect(session.promptTarget?.profile.id == hostA.id, "the sheet is about the form's host, not B")
        #expect(session.promptTarget?.isReconnect == false)
        chrome.sync()
        // A loaded simulator can take longer than a frame to present the sheet.
        for _ in 0..<100 where !((opening.presentedViewController as? UINavigationController)?
            .viewControllers.first is SSHTerminalPasswordViewController) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try #require(
            (opening.presentedViewController as? UINavigationController)?.viewControllers.first
                as? SSHTerminalPasswordViewController
        )
        #expect(sheet.endpointLabel == hostA.endpointLabel)

        // Submitting goes to A's own form, which saves A's password and attaches.
        sheet.submit("password-for-a")
        #expect(submittedByForm == ["password-for-a"])
        for _ in 0..<100 where profiles.make().profile(id: hostA.id)?.savesPassword != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(profiles.make().profile(id: hostA.id)?.savesPassword == true)
        #expect(profiles.make().profile(id: hostB.id) == nil, "B was never saved or dialed")
        #expect(session.attemptedHost != hostB.host)
        #expect(session.channel === channelA, "attached to A's live terminal; nothing was dialed")
        #expect(channelA.connected)
    }

    @Test func theSavePasswordSwitchOfAReconnectEditsTheReconnectedProfile() throws {
        let registry = makeRegistry()
        let session = SSHTerminalConnectSession(registry: registry, profileStore: IsolatedProfiles().make)
        let channel = try open(registry, mini)
        session.show(try #require(registry.terminal(for: mini.id)))
        channel.close(reason: "dropped")
        session.reconnect()
        #expect(session.promptTarget?.profile.id == mini.id)
        #expect(session.promptTarget?.isReconnect == true)
        #expect(session.promptTarget?.profile.savesPassword == false)
        session.setPromptSavesPassword(true)
        #expect(session.promptTarget?.profile.savesPassword == true)
        #expect(session.connectedProfile?.savesPassword == false, "the shown terminal's profile is unchanged until it is saved")
    }

    /// Reconnects the terminal the session shows, on a form for `formHost`, and
    /// answers the password sheet. Returns what the form was told was saved.
    private func reconnectFromAForm(
        formHost: SSHTerminalProfile, shown: SSHTerminalProfile, profiles: IsolatedProfiles, savePassword: Bool
    ) async throws -> (saved: [SSHTerminalProfile], store: SSHTerminalProfileStore) {
        let registry = makeRegistry()
        let session = SSHTerminalConnectSession(registry: registry, profileStore: profiles.make)
        let channel = try open(registry, shown)
        session.show(try #require(registry.terminal(for: shown.id)))
        var saved = [SSHTerminalProfile]()
        let opening = UIViewController()
        let window = try mount(opening, appRoot: makeTestAppRoot())
        defer {
            window.isHidden = true
            window.rootViewController = nil
            closeEverything(registry)
        }
        let chrome = SSHTerminalConnectChrome(
            host: opening, session: session,
            profile: { formHost }, setProfile: { _ in }, editHost: {},
            submitPassword: { _ in },
            onSaved: { saved.append($0) }
        )
        chrome.sync()
        try await Task.sleep(for: .milliseconds(100))
        channel.close(reason: "The connection dropped.")
        session.reconnect()
        chrome.sync()
        try await Task.sleep(for: .milliseconds(100))
        let sheet = try #require(
            (opening.presentedViewController as? UINavigationController)?.viewControllers.first
                as? SSHTerminalPasswordViewController
        )
        if savePassword { session.setPromptSavesPassword(true) }
        sheet.submit("the-password")
        // The attempt saves the host, tells the form, then dials; wait for the save.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while profiles.make().profile(id: shown.id) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        session.cancel()
        return (saved, profiles.make())
    }

    @Test func aSameHostReconnectTellsItsFormThatSavePasswordWasTurnedOn() async throws {
        let host = SSHTerminalProfile(host: "form-same.invalid", username: "alice")
        let result = try await reconnectFromAForm(
            formHost: host, shown: host, profiles: IsolatedProfiles(), savePassword: true
        )
        #expect(result.saved.count == 1)
        #expect(result.saved.first?.id == host.id)
        #expect(result.saved.first?.savesPassword == true, "the form must not later save over the stored password")
        #expect(result.store.profile(id: host.id)?.savesPassword == true)
    }

    @Test func aReconnectOfAnotherHostLeavesTheFormOnItsOwnHost() async throws {
        let formHost = SSHTerminalProfile(host: "form-a.invalid", username: "alice")
        let shown = SSHTerminalProfile(host: "form-b.invalid", username: "bob")
        let result = try await reconnectFromAForm(
            formHost: formHost, shown: shown, profiles: IsolatedProfiles(), savePassword: true
        )
        #expect(result.store.profile(id: shown.id)?.savesPassword == true, "the shown host was saved")
        #expect(result.store.profile(id: formHost.id) == nil, "the form's host was not")
        #expect(result.saved.isEmpty, "the form for host A is not turned into host B's")
    }

    @Test func aSwapKeepsWhatWasDictatedAndEndsTheTake() throws {
        let host = SSHTerminalComposerHost(
            channel: try SSHTerminalChannel(), connection: nil, draftStore: nil, themeID: .dark, showRawKeyboard: {}
        )
        // A take is on: the text holds what was typed, then what was heard.
        host.setTextBeforeRecording("deploy ")
        host.setText("deploy to staging")
        let draft = host.draftEndingDictation()
        #expect(draft.text == "deploy to staging", "the words heard so far are not lost")
        #expect(host.content.textBeforeRecording == nil, "the take is over")
        // The draft restores into the next bar for that terminal.
        let next = SSHTerminalComposerHost(
            channel: try SSHTerminalChannel(), connection: nil, draftStore: nil, themeID: .dark, showRawKeyboard: {}
        )
        next.restore(draft)
        #expect(next.text == "deploy to staging")
        #expect(!draft.isEmpty)
    }

    @Test func theChatBarDraftOfEachTerminalSurvivesASwapAndBack() async throws {
        let registry = makeRegistry()
        let session = SSHTerminalConnectSession(registry: registry)
        let first = try open(registry, studio)
        let second = try open(registry, mini)
        session.show(try #require(registry.terminal(for: studio.id)))
        let terminal = SSHTerminalViewController(
            channel: first, reconnect: {}, editHost: {}, hostLabel: "chen@mac-studio", session: session
        )
        let window = try mount(terminal)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            closeEverything(registry)
        }
        func settle() async throws {
            for _ in 0..<4 {
                await Task.yield()
                terminal.view.setNeedsLayout()
                terminal.updatePropertiesIfNeeded()
                terminal.view.layoutIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(200))
            terminal.view.layoutIfNeeded()
        }
        func chatField() throws -> PastableUITextView {
            func search(_ view: UIView) -> PastableUITextView? {
                if let field = view as? PastableUITextView { return field }
                for child in view.subviews { if let hit = search(child) { return hit } }
                return nil
            }
            return try #require(search(terminal.view))
        }
        func type(_ text: String) throws {
            let field = try chatField()
            field.text = text
            field.delegate?.textViewDidChange?(field)
        }
        let agent = Data("\u{1b}]7501;state=idle:app=pi\u{1b}\\".utf8)
        first.event(.data(agent))
        second.event(.data(agent))
        try await settle()
        try type("draft for studio")

        session.show(try #require(registry.terminal(for: mini.id)))
        try await settle()
        #expect(terminal.channel === second)
        #expect(try chatField().text.isEmpty, "the other terminal starts with its own, empty bar")
        try type("draft for mini")

        session.show(try #require(registry.terminal(for: studio.id)))
        try await settle()
        #expect(terminal.channel === first)
        #expect(try chatField().text == "draft for studio")

        session.show(try #require(registry.terminal(for: mini.id)))
        try await settle()
        #expect(try chatField().text == "draft for mini")
    }

    @Test func theBarOffersTheSwitcherOnlyWithMoreThanOneTerminalAndSwapsTheScreen() throws {
        let registry = makeRegistry()
        let session = SSHTerminalConnectSession(registry: registry)
        let first = try open(registry, studio)
        session.show(try #require(registry.terminal(for: studio.id)))
        let terminal = SSHTerminalViewController(
            channel: first, reconnect: {}, editHost: {}, hostLabel: "chen@mac-studio", session: session
        )
        let window = try mount(terminal)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            closeEverything(registry)
        }
        let switcher = try #require(find("sshTerminal.switcher", in: terminal.view))
        #expect(switcher.isHidden, "one terminal open: nothing to switch to")

        let second = try open(registry, mini)
        terminal.view.setNeedsLayout()
        terminal.updatePropertiesIfNeeded()
        window.layoutIfNeeded()
        #expect(!switcher.isHidden)
        #expect(switcher.accessibilityValue == "2 open")
        #expect(switcher.superview != nil)

        session.show(try #require(registry.terminal(for: mini.id)))
        terminal.view.setNeedsLayout()
        terminal.updatePropertiesIfNeeded()
        window.layoutIfNeeded()
        #expect(terminal.channel === second)
        // The terminal left is still open, and is no longer the one in front.
        #expect(first.connected)
        #expect(!first.isViewed)
        #expect(registry.openTerminals().count == 2)

        // Closing one leaves a single terminal: the button goes away again.
        first.close(reason: "Closed by you.")
        terminal.view.setNeedsLayout()
        terminal.updatePropertiesIfNeeded()
        window.layoutIfNeeded()
        #expect(switcher.isHidden)
    }
}
