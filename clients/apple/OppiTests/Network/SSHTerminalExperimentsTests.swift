import Foundation
import LocalAuthentication
import Testing
import UIKit
@testable import Oppi

/// Rex and Herdr are experiments (Settings → Experiments). The test bundle runs
/// with both on (`OppiTestExperiments.swift`); these check the off side, which
/// states the switches itself and reads or writes no stored value.
@Suite("Terminal experiments")
@MainActor
struct SSHTerminalExperimentTests {
    private let off = SSHTerminalExperimentAccess(rex: false, herdr: false)
    private let herdrOnly = SSHTerminalExperimentAccess(rex: false, herdr: true)

    /// Nothing answers on this port: an attempt fails as a dial, and a device key
    /// never stops at a password prompt.
    private func rexHost() -> SSHTerminalProfile {
        SSHTerminalProfile(host: "127.0.0.1", port: 1, username: "chen", authentication: .deviceKey, opensRexSessions: true)
    }

    private func herdrHost() -> SSHTerminalProfile {
        SSHTerminalProfile(host: "mac-studio.local", username: "chen", startupCommand: "herdr")
    }

    @Test("A host saved with Rex opens its plain shell while Rex is off, and its sessions while it is on")
    func rexHostOpensPlainWhileOff() {
        let host = rexHost()
        #expect(!host.listsRexSessions(off))
        #expect(host.multiplexerChoice.available(in: off) == .none)
        #expect(host.startupLabel(off) == "Login shell")
        // The saved setting is kept, so turning Rex on restores the screen.
        #expect(host.opensRexSessions && host.multiplexerChoice == .rex)

        let on = SSHTerminalExperimentAccess(rex: true, herdr: false)
        #expect(host.listsRexSessions(on))
        #expect(host.multiplexerChoice.available(in: on) == .rex)
        #expect(host.startupLabel(on) == "Rex sessions")
    }

    @Test("A host that runs herdr runs its plain shell while Herdr is off, keeping its command")
    func herdrHostRunsPlainWhileOff() {
        let host = herdrHost()
        #expect(host.commandOnConnect(off) == nil)
        #expect(host.multiplexerChoice.available(in: off) == .none)
        #expect(host.startupLabel(off) == "Login shell")
        #expect(host.startupCommand == "herdr")

        #expect(host.commandOnConnect(herdrOnly) == "herdr")
        #expect(host.multiplexerChoice.available(in: herdrOnly) == .herdr)
        #expect(herdrHost().startupLabel(herdrOnly) == "herdr")
    }

    @Test("Another program's command runs as saved")
    func otherCommandsAreLeftAlone() {
        #expect(SSHTerminalProfile(startupCommand: "tmux new -A -s main").commandOnConnect(off) == "tmux new -A -s main")
        #expect(SSHTerminalProfile(startupCommand: "htop").commandOnConnect(off) == "htop")
        #expect(SSHTerminalProfile(startupCommand: nil).commandOnConnect(off) == nil)
    }

    @Test("The host form offers only the multiplexers whose experiment is on")
    func formOffersEnabledChoices() {
        #expect(SSHTerminalMultiplexerChoice.offered(in: off) == [.none, .tmux])
        #expect(SSHTerminalMultiplexerChoice.offered(in: herdrOnly) == [.none, .herdr, .tmux])
        #expect(SSHTerminalMultiplexerChoice.rex.available(in: off) == .none)
        #expect(SSHTerminalMultiplexerChoice.herdr.available(in: off) == .none)
        #expect(SSHTerminalMultiplexerChoice.tmux.available(in: off) == .tmux)
    }

    @Test("A terminal's bar leaves Rex and Herdr out, and reads neither, while they are off")
    func barHidesAndStopsPollingWhileOff() {
        let plain = SSHTerminalBarContext.plain
        #expect(plain.hidden(off) == [.rex, .herdr])
        #expect(!plain.polls(.rex, off) && !plain.polls(.herdr, off))
        #expect(plain.hidden(herdrOnly) == [.rex])
        #expect(plain.polls(.rex, .all) && plain.polls(.herdr, .all))
        // A Rex pane still rules Herdr out, and its one control holds Rex Sessions.
        #expect(SSHTerminalBarContext.rex.hidden(.all) == [.herdr, .rex])
    }

    @Test("A Rex pane's reconnect, a Rex screen, and a Rex on your tailnet say Rex is off instead of dialing it")
    func rexConnectWhileOffSaysSo() {
        let profile = SSHTerminalProfile(host: "mac-studio.local", username: "chen", rexTailnet: URL(string: "https://rex.tail.ts.net"))
        let pane = RexPaneTarget(sessionID: "session:1", blockID: "block:1", label: "shell")
        for ask in ["pane", "list", "tailnet"] {
            let session = SSHTerminalConnectSession(registry: SSHTerminalRegistry(), access: { self.off })
            switch ask {
            case "pane": session.rexPane = pane
            case "list": session.listsRexSessions = true
            default: break
            }
            session.connect(profile: profile)
            #expect(session.failure == "Rex is off in Settings → Experiments.", "\(ask)")
            #expect(!session.connecting, "\(ask) must not dial")
            #expect(session.channel == nil && session.rexSessions == nil, "\(ask)")
            #expect(SSHTerminalRegistry.shared.terminal(for: profile.id, folder: nil, rexPane: pane) == nil, "\(ask)")
        }
    }

    @Test("Turning Rex off ends its terminal and its follower and hides the tab's card; on starts them again")
    func rexOffEndsWhatItRan() async throws {
        let defaults = try #require(UserDefaults(suiteName: "SSHTerminalExperimentTests-\(UUID().uuidString)"))
        let host = rexHost()

        // The registry: the same call the switch's side effect makes ends a Rex terminal.
        let registry = SSHTerminalRegistry()
        let channel = try SSHTerminalChannel()
        let pane = RexPaneTarget(sessionID: "session:1", blockID: "block:1", label: "shell")
        #expect(registry.adopt(channel, profile: host, rexPane: pane, queue: SSHTerminalEventQueue()))
        registry.closeRexTerminals(reason: "Rex off")
        #expect(registry.terminal(for: host.id, folder: nil, rexPane: pane) == nil)
        #expect(!channel.connected, "the Rex terminal's channel ended")

        // One follower, through the switch. A sign-in that started is what the
        // switch must end: `connecting` is the attempt, `needsListConnection` the
        // owner's own note that it still owes one.
        let access = Toggle(.all)
        let center = NotificationCenter()
        let suiteName = "SSHTerminalExperimentTests-\(UUID().uuidString)"
        let session = SSHTerminalConnectSession(
            registry: SSHTerminalRegistry(),
            // The store is made inside the closure: a `UserDefaults` is not `Sendable`.
            profileStore: {
                SSHTerminalProfileStore(defaults: UserDefaults(suiteName: suiteName) ?? .standard, keychain: MemoryKeychain())
            },
            access: { access.value }
        )
        let follower = SSHTerminalRexFollower(
            profile: host, promptsAutomatically: false, session: session,
            signsInSilently: { _ in true }, access: { access.value }, center: center
        )
        follower.appeared()
        follower.sync(active: true)
        #expect(session.connecting, "Rex on: the follower starts its sign-in")

        access.value = off
        center.post(name: AppPreferences.Experiments.didChangeNotification, object: nil)
        #expect(!session.connecting, "Rex off: the attempt ended")
        #expect(follower.needsListConnection, "and the follower owes a sign-in again")

        follower.sync(active: true)
        #expect(!session.connecting, "Rex off: syncing starts nothing")

        access.value = .all
        follower.sync(active: true)
        #expect(session.connecting, "Rex back on: the same follower signs in again")
        #expect(!follower.needsListConnection)

        // The tab's card: gone while off, and back on when the nodes can be read again.
        let node = try #require(RexTailnetHost(dnsName: "rex.tail0000.ts.net"))
        let section = RexTailnetSection(
            store: RexDirectStore(defaults: defaults), reach: { .peers }, access: { access.value }
        )
        section.add(node)
        section.update(peers: [], selfDNSName: nil, sshRexHosts: [], active: false)
        #expect(section.isShown)
        section.clear()
        #expect(!section.isShown && section.listedFollowers.isEmpty, "no card while Rex is off")
        // And a pull to refresh asks the tailnet nothing.
        await section.refresh()
        #expect(!section.isShown && section.entries.isEmpty, "nothing is discovered while Rex is off")

        // On again, the same owner lists the node again and the bar offers both
        // buttons. The follower's own start with Rex on is covered by
        // `SSHTerminalRexSectionTests` and `RexTailnetTests`, which mount the tab
        // with the switch on in this same run.
        access.value = .all
        section.update(peers: [], selfDNSName: nil, sshRexHosts: [], active: false)
        #expect(section.isShown, "Rex back on: the card is listed again")
        #expect(SSHTerminalExperimentAccess.current == .all)
        #expect(SSHTerminalBarContext.plain.hidden().isEmpty)
    }
}

/// A keychain in name only: the follower's sign-in never reaches one.
private final class MemoryKeychain: SSHCredentialStoring, @unchecked Sendable {
    func load(account: String, requirePresence: Bool, authenticationContext: LAContext?) throws -> Data? { nil }
    func save(_ data: Data, account: String, requirePresence: Bool) throws {}
    func delete(account: String) throws {}
}

/// A switch the test holds: the owners read it the way the app reads its own.
@MainActor
private final class Toggle {
    var value: SSHTerminalExperimentAccess

    init(_ value: SSHTerminalExperimentAccess) { self.value = value }
}
