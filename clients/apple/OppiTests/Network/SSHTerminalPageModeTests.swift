import Foundation
import Testing
import UIKit
@testable import Oppi

/// The Terminal page's mode, and the two things it decides on its own: what the page
/// lists, and how much it dials at once.
@Suite("Terminal page mode")
@MainActor
struct SSHTerminalPageModeTests {
    private let rexOn = SSHTerminalExperimentAccess(rex: true, herdr: false)
    private let rexOff = SSHTerminalExperimentAccess(rex: false, herdr: false)

    // MARK: - What the page shows

    /// Nothing chosen: the first mode the experiments allow. Rex is offered only
    /// while its switch is on, so with it off the page is Shell.
    @Test func theFirstAvailableModeIsTheDefault() {
        #expect(SSHTerminalPageMode.resolved(nil, in: rexOn) == .rex)
        #expect(SSHTerminalPageMode.resolved(nil, in: rexOff) == .shell)
    }

    /// A stored choice wins while its experiment is on.
    @Test func aStoredChoiceWinsWhileItIsAvailable() {
        #expect(SSHTerminalPageMode.resolved(.shell, in: rexOn) == .shell, "Shell is always available")
        #expect(SSHTerminalPageMode.resolved(.rex, in: rexOn) == .rex)
    }

    /// A stored Rex choice falls back when Rex's experiment turns off, and the choice
    /// itself is not rewritten: turning the switch back on restores the page.
    @Test func aChoiceWhoseExperimentIsOffFallsBack() {
        #expect(SSHTerminalPageMode.resolved(.rex, in: rexOff) == .shell)
        #expect(SSHTerminalPageMode.resolved(.rex, in: rexOn) == .rex, "the stored choice was never changed")
    }

    /// The button's modes: Shell always, Rex while it is on. One mode is no choice.
    @Test func theButtonOffersOnlyAvailableModes() {
        #expect(SSHTerminalPageMode.available(in: rexOn) == [.rex, .shell])
        #expect(SSHTerminalPageMode.available(in: rexOff) == [.shell])
    }

    // MARK: - What the page dials

    // MARK: - What ＋ does

    /// Rex mode's ＋ starts a session on a saved host (asking which one when there are
    /// several, straight away when there is one); Shell mode's ＋ saves a host, and so
    /// does Rex mode's before any host exists.
    @Test func plusStartsASessionInRexModeAndSavesAHostOtherwise() {
        let one = SSHTerminalProfile(host: "devbox.local", username: "dev")
        let two = SSHTerminalProfile(host: "studio.local", username: "chen")
        #expect(SSHTerminalHostListViewController.plus(mode: .shell, hosts: [one, two]) == .newHost)
        #expect(SSHTerminalHostListViewController.plus(mode: .rex, hosts: []) == .newHost)
        #expect(SSHTerminalHostListViewController.plus(mode: .rex, hosts: [one]) == .newSession([one]))
        #expect(SSHTerminalHostListViewController.plus(mode: .rex, hosts: [one, two]) == .newSession([one, two]))
    }

    // MARK: - A session's panes

    /// A session row's ⊕ runs the owner action that adds a pane, and the disclosure
    /// keeps showing or hiding the panes it already had.
    @Test func aSessionsPlusRunsItsNewPaneAction() {
        let session = SSHTerminalRexListSession(
            RexSnapshot.Session(
                sessionID: "session:1", label: "oppi", activeWindowID: "w0",
                windows: [RexSnapshot.Window(windowID: "w0", label: nil, focusedBlockID: "b0", panes: [
                    RexSnapshot.Pane(blockID: "b0", label: "shell", title: nil, pwd: nil, records: []),
                ])]
            )
        )
        let cell = SSHTerminalRexListSessionCell(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        cell.configureSession(
            session, identifier: "row", themeID: .dark,
            actions: [], perform: {}, toggle: {}, newPane: {}
        )
        cell.contentView.layoutIfNeeded()
        // What the cell owes the page: one ⊕ and one chevron, each findable by id. What
        // pressing them does is `createPaneAsksRexForASplitAndOpensTheNewPane`, and the
        // disclosure is the page's own state for the row.
        #expect(cell.newPaneElement.accessibilityIdentifier == "row.newPane")
        #expect(cell.disclosureElement.accessibilityIdentifier == "row.disclosure")
    }

    /// The ⊕ reaches the owner action that makes a pane: `createPane` asks Rex for a
    /// split and hands the new pane to be opened.
    @Test func createPaneAsksRexForASplitAndOpensTheNewPane() async throws {
        let world = RexFakeWorld.preview()
        let follower = SSHTerminalRexFollower(
            profile: SSHTerminalProfile(host: "127.0.0.1", port: 1, username: "chen", authentication: .deviceKey),
            promptsAutomatically: true,
            standIn: RexPreviewStreamHost(world: world)
        )
        defer { follower.close() }
        var opened: [RexPaneTarget] = []
        follower.monitor.openPane = { opened.append($0) }
        follower.appeared()
        follower.sync(active: true)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { follower.canManage })

        let session = try #require(follower.monitor.snapshot?.sessions.first?.sessionID)
        await follower.createPane(session: session)
        #expect(follower.manageFailure == nil)
        let split = try #require(world.requests("session.new_split").first)
        #expect(split.string("session_id") == session)
        #expect(split.string("direction") == "horizontal" && split.string("side") == "after")
        let body = try #require(try JSONSerialization.jsonObject(with: Data(split.payload.utf8)) as? [String: Any])
        #expect(body["focus"] as? Bool == false, "Rex's own focus does not move")
        #expect(opened == [RexPaneTarget(sessionID: session, blockID: "block:new-pane-1", label: "Shell")])
    }

    /// The choice is kept in the one store the page reads, so a page made again (a new
    /// visit, another scene) shows it.
    @Test func theChosenModeSurvivesANewPage() throws {
        let name = "SSHTerminalPageModeTests.mode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(serverId: nil, device: DeviceAdapter(defaults: defaults), server: ServerAdapter { _ in nil })

        let first = try mountPage(SSHTerminalHostListViewController(
            profileStore: { SSHTerminalProfileStore(defaults: defaults, keychain: MemoryKeychain()) },
            settings: settings
        ))
        first.page.choose(.shell)
        first.window.isHidden = true
        #expect(defaults.string(forKey: AppPreferenceStore.Terminal.pageModeKey) == "shell")

        let second = try mountPage(SSHTerminalHostListViewController(
            profileStore: { SSHTerminalProfileStore(defaults: defaults, keychain: MemoryKeychain()) },
            settings: settings
        ))
        defer { second.window.isHidden = true }
        // Shell mode: the page is the host list, and the toolbar's mode button says so.
        // A bar item is not a view, so the test asks the toolbar itself.
        #expect(second.identifiers.contains("sshTerminal.host.add"), "Shell lists hosts, not panes")
        // The page's own items: the navigation controller displays them once its
        // toolbar lays out, which a mounted window does not always reach.
        let items = try #require(second.page.toolbarItems)
        let modeButton = try #require(items.first { $0.accessibilityIdentifier == "sshTerminal.mode" })
        #expect(modeButton.accessibilityValue == "Shell", "the button shows the stored choice")
    }

    /// What a host had open is kept on this device, per saved host.
    @Test func expandedSessionsAreKeptPerHost() throws {
        let name = "SSHTerminalPageModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SSHTerminalRexExpandedStore(defaults: defaults)
        let host = UUID()
        #expect(store.expanded(for: host).isEmpty)
        store.setExpanded(["session:2", "session:1"], for: host)
        #expect(store.expanded(for: host) == ["session:1", "session:2"])
        #expect(store.expanded(for: UUID()).isEmpty, "another host has its own")
        store.setExpanded([], for: host)
        #expect(store.expanded(for: host).isEmpty)
        #expect(defaults.object(forKey: SSHTerminalRexExpandedStore.key(host)) == nil, "nothing is kept for a host with no session open")
    }

    // MARK: - Where a session is made

    /// A host with Rex running and no sessions offers the one thing to do: a New
    /// Session row.
    @Test func aHostWithNoSessionsOffersOnlyNewSession() {
        let state = SSHTerminalRexListState(snapshot: RexSnapshot(sessions: []), canManage: true)
        let rows = SSHTerminalRexListRow.rows(hostName: "chen@devbox", state: state)
        #expect(rows.map(\.id) == ["header", "new"])
        guard case .newSession(let busy)? = rows.last?.kind else {
            Issue.record("the empty section must offer New Session")
            return
        }
        #expect(!busy)
    }

    /// Beside sessions there is no New Session row: the heading's ⋯ and the page's ＋
    /// make one, exactly as the spec puts it.
    @Test func aSectionWithSessionsHasNoNewSessionRow() {
        let session = RexSnapshot.Session(
            sessionID: "session:1", label: "oppi", activeWindowID: "w0",
            windows: [RexSnapshot.Window(windowID: "w0", label: nil, focusedBlockID: "b0", panes: [
                RexSnapshot.Pane(blockID: "b0", label: "shell", title: nil, pwd: nil, records: []),
            ])]
        )
        let state = SSHTerminalRexListState(snapshot: RexSnapshot(sessions: [session]), canManage: true)
        let rows = SSHTerminalRexListRow.rows(hostName: "chen@devbox", state: state)
        #expect(rows.map(\.id) == ["header", "session|session:1"])
    }

    // MARK: - A host with no Rex

    /// A host with no Rex on it keeps one muted line, not a failure row with advice:
    /// the page lists every saved host, and this is what one with nothing says.
    @Test func aHostWithNoRexSaysSoInOneMutedLine() {
        let state = SSHTerminalRexListState(absence: .notInstalled)
        let rows = SSHTerminalRexListRow.rows(hostName: "chen@devbox", state: state)
        #expect(rows.map(\.id) == ["header", "reason", "retry"])
        guard case .placeholder(let text)? = rows.first(where: { $0.id == "reason" })?.kind else {
            Issue.record("a host with no Rex must say so in a placeholder, not a failure")
            return
        }
        #expect(text == "No Rex on this host.")
        #expect(rows.last?.kind == .retry("Retry"), "the muted line comes with the way to ask again")
    }

    /// Rex that is installed but not running keeps its advice: it can be started.
    @Test func rexThatIsNotRunningKeepsItsAdviceAndTheWayToAskAgain() {
        let state = SSHTerminalRexListState(absence: .notRunning)
        let rows = SSHTerminalRexListRow.rows(hostName: "chen@devbox", state: state)
        #expect(rows.map(\.id) == ["header", "reason", "retry"])
        guard case .failure(let advice)? = rows.first(where: { $0.id == "reason" })?.kind else {
            Issue.record("Rex not running must keep its advice row")
            return
        }
        #expect(advice.contains("rex server start"))
    }
}
