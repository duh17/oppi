import Foundation
import LocalAuthentication
import Synchronization
import Testing
import UIKit
@testable import Oppi

/// Saved hosts and passwords for a test: its own defaults suite and an
/// in-memory keychain, so nothing reaches the app's real store.
private struct IsolatedHosts {
    private let suite = "SSHTerminalRexListTests.\(UUID().uuidString)"
    private let keychain = MemoryKeychain()

    var store: @Sendable () -> SSHTerminalProfileStore {
        { [suite, keychain] in SSHTerminalProfileStore(defaults: UserDefaults(suiteName: suite)!, keychain: keychain) }
    }

    func save(_ profiles: [SSHTerminalProfile]) throws {
        for profile in profiles { try store().save(profile) }
    }
}

private final class QuietConnection: SSHTerminalConnection {
    func close() {}
    func send(_ bytes: Data) async throws {}
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream { throw SSHConnectionError.notConnected }
    func run(_ command: String, input: Data) async throws -> SSHExecResult { throw SSHConnectionError.commandRequestRejected }
    func checkAlive() async throws {}
    func cancel() async {}
}

/// What the Terminal tab's Rex section draws for a host, from the rows a
/// host's state produces.
@Suite("Terminal tab Rex rows")
struct SSHTerminalRexListRowTests {
    private func pane(_ block: String, _ records: [SSHTerminalPaneRecord] = []) -> RexSnapshot.Pane {
        RexSnapshot.Pane(blockID: block, label: "shell", title: nil, pwd: nil, records: records)
    }

    private let working = SSHTerminalPaneRecord(id: "", state: .working, app: "pi")
    private let blocked = SSHTerminalPaneRecord(id: "bash", state: .blocked, kind: .permission, message: "Run it?")

    private func session(_ id: String, _ label: String?, _ windows: [[RexSnapshot.Pane]], focused: String? = nil) -> RexSnapshot.Session {
        RexSnapshot.Session(
            sessionID: id, label: label, activeWindowID: "w0",
            windows: windows.enumerated().map { index, panes in
                RexSnapshot.Window(windowID: "w\(index)", label: nil, focusedBlockID: index == 0 ? focused : nil, panes: panes)
            }
        )
    }

    private func rows(_ state: SSHTerminalRexListState) -> [SSHTerminalRexListRow] {
        SSHTerminalRexListRow.rows(hostName: "chen@studio", state: state)
    }

    @Test func aSessionShowsItsNamePaneCountAndWhoWaitsOnYou() throws {
        let snapshot = RexSnapshot(sessions: [
            session("s:oppi", "oppi", [[pane("a", [working]), pane("b", [blocked])], [pane("c")]]),
            session("s:dots", nil, [[pane("d", [SSHTerminalPaneRecord(id: "", state: .idle, app: "codex")])]]),
            session("s:plain", "plain", [[pane("e")]]),
        ])
        let listed = rows(.init(snapshot: snapshot, needsYou: snapshot.needsAttention))

        #expect(listed.first?.kind == .header(name: "chen@studio", needsYou: 1))
        let sessions: [SSHTerminalRexListSession] = listed.compactMap {
            if case .session(let session) = $0.kind { session } else { nil }
        }
        #expect(sessions.map(\.title) == ["oppi", "Session", "plain"])
        #expect(sessions.map(\.paneCount) == [3, 1, 1])
        #expect(sessions.map(\.needsYou) == [1, 0, 0])
        // A blocked pane leads a working one; a pane that never reported has no status.
        #expect(sessions.map(\.status) == [.known(.needsApproval), .known(.idle), .none])
        #expect(sessions[0].summary == "2 windows \u{00B7} 3 panes \u{00B7} 1 needs you")
        #expect(sessions[1].summary == "1 pane")
        #expect(sessions[0].accessibilityLabel == "oppi, 2 windows \u{00B7} 3 panes \u{00B7} 1 needs you")
        #expect(listed.map(\.id) == ["header", "session|s:oppi", "session|s:dots", "session|s:plain"])
    }

    // MARK: Panes under a session

    private func expandedRows(_ sessions: [RexSnapshot.Session], expanding ids: Set<String>) -> [SSHTerminalRexListRow] {
        rows(.init(snapshot: RexSnapshot(sessions: sessions), expanded: ids))
    }

    /// A pane's icon is the bar's pane switcher's, by its one rule: a monogram
    /// of the title's first character while the pane's program reports
    /// status, else of the app its status names, else of Rex's label; the
    /// terminal glyph for a shell that never reported.
    @Test func expandedPanesDrawTheBarsIconsAndNameTheirFolder() throws {
        let agents = [
            RexSnapshot.Pane(blockID: "pi", label: "shell", title: "\u{03C0} - oppi", pwd: "file://studio/Users/chen/workspace/oppi", records: [working]),
            RexSnapshot.Pane(blockID: "claude", label: "shell", title: "\u{2733} Fixing", pwd: "/Users/chen/server/", records: [blocked]),
            RexSnapshot.Pane(blockID: "bare", label: "shell", title: nil, pwd: nil, records: [working]),
            RexSnapshot.Pane(blockID: "sh", label: "shell", title: "zsh", pwd: "file://studio/", records: []),
        ]
        let listed = expandedRows([session("s", "s", [agents], focused: "claude")], expanding: ["s"])
        let panes: [SSHTerminalRexListPane] = listed.compactMap { if case .pane(let pane) = $0.kind { pane } else { nil } }
        #expect(listed.map(\.id) == ["header", "session|s", "pane|s|pi", "pane|s|claude", "pane|s|bare", "pane|s|sh"], "one window: no window rows")
        #expect(panes.map(\.icon) == [.monogram("\u{03C0}"), .monogram("\u{2733}"), .monogram("P"), .terminal])
        // The same icon the bar draws for the same pane.
        for (pane, source) in zip(panes, agents) {
            #expect(pane.icon == SSHTerminalPaneIcon(program: RexSessionState.program(title: source.title, records: source.records, label: source.label)))
        }
        // The title when it says more than the name, then the folder's last component.
        #expect(panes.map(\.detail) == ["\u{03C0} - oppi \u{00B7} oppi", "server", nil, "/"])
        #expect(panes.map(\.isFocused) == [false, true, false, false])
        #expect(panes.map(\.needsYou) == [false, true, false, false])
        #expect(panes[1].accessibilityLabel == "\u{2733} Fixing, server, needs you")
    }

    @Test func aSessionWithSeveralWindowsGroupsItsPanesUnderEachWindow() {
        let two = RexSnapshot.Session(
            sessionID: "s", label: "s", activeWindowID: "w0",
            windows: [
                RexSnapshot.Window(windowID: "w0", label: "agents", focusedBlockID: "a", panes: [pane("a"), pane("b")]),
                RexSnapshot.Window(windowID: "w1", label: nil, focusedBlockID: nil, panes: [pane("c")]),
            ]
        )
        let listed = expandedRows([two], expanding: ["s"])
        #expect(listed.map(\.id) == ["header", "session|s", "window|s|w0", "pane|s|a", "pane|s|b", "window|s|w1", "pane|s|c"])
        #expect(listed.filter { if case .window = $0.kind { true } else { false } }.map(\.kind) == [.window(id: "w0", name: "agents"), .window(id: "w1", name: "Window 2")])
        let named: [String?] = listed.compactMap { if case .pane(let pane) = $0.kind { pane.windowName } else { nil } }
        #expect(named == ["agents", "agents", "Window 2"])
    }

    @Test func aCollapsedSessionListsNoPanesAndOnlyTheExpandedOneDoes() {
        let sessions = [session("a", "a", [[pane("a1")]]), session("b", "b", [[pane("b1")]])]
        #expect(expandedRows(sessions, expanding: []).map(\.id) == ["header", "session|a", "session|b"])
        let listed = expandedRows(sessions, expanding: ["b"])
        #expect(listed.map(\.id) == ["header", "session|a", "session|b", "pane|b|b1"])
        let flags: [Bool] = listed.compactMap { if case .session(let session) = $0.kind { session.isExpanded } else { nil } }
        #expect(flags == [false, true])
        // A session with no panes has nothing to show, whatever was asked.
        let empty = expandedRows([session("e", "e", [])], expanding: ["e"])
        #expect(empty.map(\.id) == ["header", "session|e"])
    }

    @Test func aSessionNamesTheFolderItsFocusedPaneIsIn() {
        let snapshot = session("s", "s", [[
            RexSnapshot.Pane(blockID: "a", label: nil, title: nil, pwd: "file://studio/Users/chen/dotfiles", records: []),
            RexSnapshot.Pane(blockID: "b", label: nil, title: nil, pwd: "file://studio/Users/chen/oppi", records: []),
        ]], focused: "b")
        let row = SSHTerminalRexListSession(snapshot)
        #expect(row.folder == "oppi")
        #expect(row.detail == "oppi \u{00B7} 2 panes")
        #expect(row.accessibilityLabel == "s, in oppi, 2 panes")
    }

    @Test func aTapOpensTheFocusedPaneElseTheFirst() {
        let focused = session("s", "s", [[pane("a"), pane("b")], [pane("c")]], focused: "b")
        #expect(focused.openingPane?.blockID == "b")
        let none = session("s", "s", [[pane("a"), pane("b")]])
        #expect(none.openingPane?.blockID == "a")
        #expect(session("s", "s", []).openingPane == nil)
    }

    @Test func aHostNotReadYetShowsLoadingAndAnEmptyRexSaysSo() {
        #expect(rows(.init()).map(\.kind) == [.header(name: "chen@studio", needsYou: 0), .placeholder("Loading\u{2026}")])
        let empty = rows(.init(snapshot: RexSnapshot(sessions: [])))
        #expect(empty.last?.kind == .placeholder("No Rex sessions."))
    }

    @Test func connectingAndOpeningReadAsWhatIsHappening() {
        #expect(rows(.init(connecting: true)).map(\.kind).last == .placeholder("Connecting\u{2026}"))
        #expect(rows(.init(connecting: true, opening: true)).map(\.kind).last == .placeholder("Opening\u{2026}"))
        // Opening a pane keeps the sessions on screen under it.
        let snapshot = RexSnapshot(sessions: [session("s", "s", [[pane("a")]])])
        let listed = rows(.init(connecting: true, opening: true, snapshot: snapshot))
        #expect(listed.map(\.id) == ["header", "connecting", "session|s"])
    }

    @Test func aHostThatWouldAskShowsTapToConnectNotLoading() {
        let listed = rows(.init(needsTap: true))
        #expect(listed.map(\.kind) == [.header(name: "chen@studio", needsYou: 0), .tapToConnect])
        let failed = rows(.init(connectFailure: "Connection refused", needsTap: true))
        #expect(failed.map(\.kind) == [.header(name: "chen@studio", needsYou: 0), .failure("Connection refused"), .tapToConnect])
    }

    @Test func rexThatCannotBeReadShowsItsAdviceAndStopsThere() {
        for absence in [RexAbsence.noNc, .notInstalled] {
            let listed = rows(.init(snapshot: RexSnapshot(sessions: [session("s", "s", [[pane("a")]])]), absence: absence))
            #expect(listed.map(\.kind) == [.header(name: "chen@studio", needsYou: 0), .failure(absence.advice)], "a host that gave up lists nothing")
        }
        // Not running may be started: the advice shows and the list fills in later.
        let notRunning = rows(.init(absence: .notRunning))
        #expect(notRunning.map(\.kind) == [.header(name: "chen@studio", needsYou: 0), .failure(RexAbsence.notRunning.advice)])
    }

    @Test func aFailedStreamKeepsTheLastSessionsUnderTheReason() {
        let snapshot = RexSnapshot(sessions: [session("s", "s", [[pane("a")]])])
        let listed = rows(.init(snapshot: snapshot, failure: "The connection to Rex closed."))
        #expect(listed.map(\.id) == ["header", "reason", "session|s"])
        #expect(listed[1].kind == .failure("The connection to Rex closed."))
    }
}

/// A host whose Rex bridge command exits with `status` as soon as it opens: 4,
/// Rex is installed and not running; 5, not installed; 126, no usable `nc`.
@MainActor
private final class ExitingStreamHost: RexStreamHost {
    let status: Int
    private(set) var opened = 0
    var isConnected: Bool { true }

    init(status: Int) { self.status = status }

    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        opened += 1
        let host = RexFakeHost { _ in .hold }
        let stream = host.open(sink: sink)
        // A bridge with no Rex there exits without answering anything on the
        // stream (the shell never gets to `exec nc`): its status and close
        // reach the sink here, before the socket can write its upgrade, so
        // `RexPipeSocket.open` reports the absence. Ending it from a Task,
        // after the stream was returned, left that order to the scheduler: an
        // upgrade that answered first was then read as a stream that dropped,
        // which the monitor asks again over a second stream.
        host.end(status: status)
        return stream
    }

    /// No Rex CLI to ask either (`RexBridge.statusCommand`).
    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        throw SSHConnectionError.commandRequestRejected
    }
}

/// Which hosts Rex was seen on: what is remembered, for whom, and what a
/// monitor's findings change.
@Suite("Rex host memory", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalRexHostMemoryTests {
    private let hosts = IsolatedHosts()
    private let studio = SSHTerminalProfile(host: "mac-studio", port: 22, username: "chen", authentication: .deviceKey)

    /// A mark is for the account it was seen as: a host edited to another
    /// machine, port, or user is not one Rex was seen on, and deleting the host
    /// removes its mark.
    @Test func aMarkNamesTheAccountAndGoesWithTheHost() throws {
        try hosts.save([studio])
        let seen = hosts.store().rexHosts
        #expect(!seen.hasSeenRex(on: studio))
        seen.markSeen(studio)
        #expect(seen.hasSeenRex(on: studio))
        #expect(hosts.store().rexHosts.hasSeenRex(on: studio), "it is kept, not held in memory")

        var respelled = studio
        respelled.host = " Mac-Studio. "
        #expect(seen.hasSeenRex(on: respelled), "the same endpoint in another spelling")
        var moved = studio
        moved.host = "mac-mini"
        var otherPort = studio
        otherPort.port = 2222
        var otherUser = studio
        otherUser.username = "root"
        #expect([moved, otherPort, otherUser].allSatisfy { !seen.hasSeenRex(on: $0) })

        try hosts.store().delete(id: studio.id)
        #expect(!hosts.store().rexHosts.hasSeenRex(on: studio), "deleted with the host")
    }

    @Test func aFindingRemembersForgetsOrKeeps() {
        let seen = hosts.store().rexHosts
        seen.record(.reached, on: studio)
        #expect(seen.hasSeenRex(on: studio))
        seen.record(.absent(.notRunning), on: studio)
        seen.record(.absent(.noNc), on: studio)
        #expect(seen.hasSeenRex(on: studio), "not running, or no nc, says nothing about Rex being on the host")
        seen.record(.absent(.notInstalled), on: studio)
        #expect(!seen.hasSeenRex(on: studio), "no rex on the host: forgotten")
    }

    /// What the monitor tells whoever remembers: Rex read once, or why it could not be.
    @Test func aMonitorReportsReachingRexAndWhyItCouldNot() async throws {
        let monitor = RexMonitor(publishDelay: .milliseconds(20), retryDelay: { _, _ in .seconds(30) })
        var found: [RexMonitor.Finding] = []
        monitor.onFinding = { found.append($0) }
        let task = Task { await monitor.run(over: RexPreviewStreamHost()) }
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { !found.isEmpty })
        task.cancel()
        await task.value
        #expect(found == [.reached])

        for (status, absence) in [(126, RexAbsence.noNc), (5, .notInstalled), (4, .notRunning)] {
            let monitor = RexMonitor(publishDelay: .milliseconds(20), retryDelay: { _, _ in .seconds(30) })
            var found: [RexMonitor.Finding] = []
            monitor.onFinding = { found.append($0) }
            let task = Task { await monitor.run(over: ExitingStreamHost(status: status)) }
            try #require(await waitForMainActorCondition(timeout: .seconds(5)) { !found.isEmpty }, "exit \(status)")
            task.cancel()
            await task.value
            #expect(found == [.absent(absence)], "exit \(status) is \(absence)")
        }
    }
}

/// The Rex follower and the Terminal tab built on it.
@Suite("Terminal tab Rex section", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalRexSectionTests {
    private let hosts = IsolatedHosts()
    private let rexHost = SSHTerminalProfile(host: "mac-studio", username: "chen", authentication: .deviceKey, opensRexSessions: true)
    private let plainHost = SSHTerminalProfile(host: "devbox", username: "dev", startupCommand: "herdr")

    /// The session ids and blocks `RexFakeHost.preview()` serves.
    private let oppiSession = "session:01a18a26-6620-76be-b529-4d9ad2b36c63"
    private let claudeBlock = "block:01a18a26-6620-78ba-80d4-4e8caa018b37"

    private func makeFollower(
        _ profile: SSHTerminalProfile, stream: RexPreviewStreamHost = RexPreviewStreamHost(), registry: SSHTerminalRegistry = SSHTerminalRegistry()
    ) -> SSHTerminalRexFollower {
        SSHTerminalRexFollower(
            profile: profile, promptsAutomatically: false,
            session: SSHTerminalConnectSession(registry: registry, profileStore: hosts.store),
            monitor: RexMonitor(publishDelay: .milliseconds(20), retryDelay: { _, _ in .milliseconds(10) }),
            standIn: stream
        )
    }

    private func sessions(of follower: SSHTerminalRexFollower) -> [SSHTerminalRexListSession] {
        SSHTerminalRexListRow.rows(hostName: "h", state: follower.listState).compactMap {
            if case .session(let session) = $0.kind { session } else { nil }
        }
    }

    // MARK: The follower

    /// The monitor reads Rex only while the screen is active, one stream per
    /// host, and stops with it: nothing polls while the tab is covered, and a
    /// return reads Rex again over a new stream.
    @Test func theMonitorFollowsRexWhileActiveAndStopsWhenCovered() async throws {
        let stream = RexPreviewStreamHost()
        let follower = makeFollower(rexHost, stream: stream)
        defer { follower.close() }

        follower.sync(active: false)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(100)) { stream.hosts.isEmpty }, "an inactive screen opens no stream")

        follower.sync(active: true)
        follower.sync(active: true)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { follower.monitor.available })
        #expect(stream.hosts.count == 1, "one stream per host, however often the screen syncs")
        #expect(sessions(of: follower).map(\.title) == ["oppi", "dotfiles"])
        #expect(sessions(of: follower).map(\.paneCount) == [3, 1])
        #expect(sessions(of: follower).map(\.needsYou) == [1, 0])
        #expect(follower.monitor.needsAttention == 1)

        follower.stopReading()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { stream.hosts.first?.isClosed == true }, "covering the tab closes the stream")

        follower.sync(active: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { stream.hosts.count == 2 }, "coming back reads Rex over a new stream")
    }

    @Test func backgroundingStopsTheStreamAndTheScreenReadsAgainOnReturn() async throws {
        let stream = RexPreviewStreamHost()
        let follower = makeFollower(rexHost, stream: stream)
        defer { follower.close() }
        follower.sync(active: true)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { follower.monitor.available })

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { stream.hosts.first?.isClosed == true })

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(follower.needsListConnection, "it signs in again once the screen shows")
        follower.sync(active: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { stream.hosts.count == 2 })
    }

    /// A tap opens the session on its focused pane, and a terminal the
    /// registry already holds for that session is shown instead of a second
    /// connection.
    @Test func aTappedSessionShowsTheTerminalAlreadyOpenForIt() async throws {
        let registry = SSHTerminalRegistry(backgroundTasks: FakeBackgroundTasks(), sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        defer { registry.closeAll(reason: "done") }
        let follower = makeFollower(rexHost, registry: registry)
        defer { follower.close() }
        follower.session.connectedProfile = rexHost
        let open = try SSHTerminalChannel(answersTerminalQueries: false)
        open.opened(QuietConnection())
        let pane = RexPaneTarget(sessionID: oppiSession, blockID: "block:01a18a7e-911a-721b-a50b-14dfc0cc62ca", label: "pi")
        registry.adopt(open, profile: rexHost, rexPane: pane, queue: SSHTerminalEventQueue())

        #expect(!follower.open(session: oppiSession), "nothing is listed before Rex is read")
        follower.sync(active: true)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { follower.monitor.available })

        var opened: [RexPaneTarget] = []
        let openPane = follower.monitor.openPane
        follower.monitor.openPane = { opened.append($0); openPane?($0) }
        #expect(follower.open(session: oppiSession))
        #expect(opened.map(\.blockID) == [claudeBlock], "on the session's focused pane")
        #expect(follower.session.channel === open && follower.session.showsTerminal, "the open terminal is shown")
        #expect(registry.openTerminals().count == 1 && !follower.session.connecting, "no second connection")
        #expect(!follower.open(session: "session:gone"), "a session Rex no longer lists does nothing")
    }

    // MARK: Never prompting on its own

    @Test func aHostThatWouldAskNeedsATapAndOneApprovedAndTrustedDoesNot() throws {
        let key = SSHHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZbA0Hd5UkWHXHAQsrp7ZCdVjLOZsb9eJwvcdU6UT5q")
        let keychain = SSHKeychain(service: "SSHTerminalRexListTests.\(UUID().uuidString)")
        let known = SSHKnownHosts(keychain: keychain)
        let now = Mutex(0.0)
        let approvals = SSHApprovalCache(window: 300, now: { now.withLock { $0 } })
        func connects(_ profile: SSHTerminalProfile, locked: Bool = false) -> Bool {
            profile.connectsWithoutPrompt(approvals: approvals, knownHosts: known, store: hosts.store(), appLockRequiresUnlock: locked)
        }
        defer {
            approvals.invalidateAll()
            try? known.forget(host: rexHost.host, port: rexHost.port)
        }

        // An unknown host key asks for trust first, whatever the sign-in.
        #expect(!connects(rexHost))
        try known.trust(key, host: rexHost.host, port: rexHost.port)
        // A device key needs its approval (Face ID); within the reuse window it needs none.
        #expect(!connects(rexHost))
        approvals.store(LAContext(), for: .deviceKeySigning)
        #expect(connects(rexHost))
        #expect(!connects(rexHost, locked: true), "a lock that is due ends every approval, so the connect would ask")
        now.withLock { $0 = 301 }
        #expect(!connects(rexHost), "an approval older than the window is a prompt again")

        // A password that is not saved is typed: it needs the person.
        var password = SSHTerminalProfile(host: rexHost.host, username: "chen", opensRexSessions: true)
        #expect(!connects(password))
        password.savesPassword = true
        try hosts.store().save(password, password: "secret")
        #expect(!connects(password), "a saved password is behind Face ID until it is approved")
        approvals.store(LAContext(), for: .savedPassword(account: SSHTerminalProfileStore.passwordAccount(for: password.id)))
        #expect(connects(password))
    }

    @Test func aTabFollowerDoesNotSignInOnItsOwnAndSaysTapToConnect() {
        let host = SSHTerminalProfile(host: "127.0.0.1", port: 1, username: "chen", authentication: .deviceKey, opensRexSessions: true)
        let follower = SSHTerminalRexFollower(
            profile: host, promptsAutomatically: false,
            session: SSHTerminalConnectSession(registry: SSHTerminalRegistry(), profileStore: hosts.store),
            signsInSilently: { _ in false }
        )
        defer { follower.close() }
        #expect(follower.needsTap)
        follower.sync(active: true)
        #expect(!follower.session.connecting && !follower.session.passwordPrompt && follower.session.hostFailure == nil)
        #expect(follower.needsListConnection, "it waits for the tap")
        #expect(SSHTerminalRexListRow.rows(hostName: "h", state: follower.listState).map(\.kind).last == .tapToConnect)

        // The tap is the go-ahead: it signs in over the normal chrome.
        follower.connect()
        #expect(follower.session.connecting || follower.session.passwordPrompt)
        follower.session.cancel()
    }

    // MARK: The tab

    /// What the tab's follower factory made, by host.
    private final class Built {
        var followers: [UUID: SSHTerminalRexFollower] = [:]
        var streams: [UUID: RexPreviewStreamHost] = [:]
    }

    @MainActor private struct Rig {
        let list: SSHTerminalHostListViewController
        let window: UIWindow
        let navigation: UINavigationController
        let built: Built

        func tearDown() {
            built.followers.values.forEach { $0.close() }
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// A tab whose hosts follow a fake Rex (`RexPreviewStreamHost`): nothing signs in.
    /// `standIn` makes a host's Rex when it is not the preview's.
    private func mountTab(
        _ profiles: [SSHTerminalProfile], registry: SSHTerminalRegistry = SSHTerminalRegistry(),
        standIn: (@MainActor (SSHTerminalProfile) -> any RexStreamHost)? = nil
    ) throws -> Rig {
        let built = Built()
        let store = hosts.store
        return try mount(profiles, built: built) { profile in
            let stream = RexPreviewStreamHost()
            let follower = SSHTerminalRexFollower(
                profile: profile, promptsAutomatically: false,
                session: SSHTerminalConnectSession(registry: registry, profileStore: store),
                monitor: RexMonitor(publishDelay: .milliseconds(20), retryDelay: { _, _ in .milliseconds(10) }),
                standIn: standIn?(profile) ?? stream
            )
            built.followers[profile.id] = follower
            built.streams[profile.id] = stream
            return follower
        }
    }

    /// Whether a sign-in would ask for nothing, for a tab whose followers sign
    /// in for real (to a loopback port nothing listens on).
    @MainActor private final class Silent {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    /// A tab whose hosts sign in on their own whenever `silent` says nothing would ask.
    private func mountDialingTab(_ profiles: [SSHTerminalProfile], silent: Silent) throws -> Rig {
        let built = Built()
        let store = hosts.store
        return try mount(profiles, built: built) { profile in
            let follower = SSHTerminalRexFollower(
                profile: profile, promptsAutomatically: false,
                session: SSHTerminalConnectSession(registry: SSHTerminalRegistry(), profileStore: store),
                // One quiet sign-in per host: once a try has been made, nothing is quiet.
                signsInSilently: { _ in silent.value && (built.followers[profile.id]?.session.attemptedPort ?? 22) == 22 }
            )
            built.followers[profile.id] = follower
            return follower
        }
    }

    private func mount(
        _ profiles: [SSHTerminalProfile], built: Built,
        makeFollower: @escaping @MainActor (SSHTerminalProfile) -> SSHTerminalRexFollower
    ) throws -> Rig {
        try hosts.save(profiles)
        // Off the tailnet whatever machine runs the test, with nothing saved:
        // these tests are about the saved hosts' Rex sections alone.
        let tailnetRex = RexTailnetSection(
            // A suite of its own, never the app's: another test reads that.
            store: RexDirectStore(
                defaults: try #require(UserDefaults(suiteName: "rex-list-tests-tailnet-\(UUID().uuidString)"))
            ),
            discovery: RexTailnetDiscovery { _ in .unreachable },
            reach: { .none }
        )
        let list = SSHTerminalHostListViewController(
            profileStore: hosts.store, makeFollower: makeFollower, tailnetRex: tailnetRex, startsTailnet: {}
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.traitOverrides.appRootEnvironment = makeTestAppRoot()
        let navigation = RouterNavigationController(rootViewController: list)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        list.view.layoutIfNeeded()
        return Rig(list: list, window: window, navigation: navigation, built: built)
    }

    private func actionCells(in rig: Rig) -> [SSHTerminalRexListActionCell] {
        rig.list.view.layoutIfNeeded()
        return collectionCells(rig.list).compactMap { $0 as? SSHTerminalRexListActionCell }
    }

    /// A session row is a container of two elements: the row, then its disclosure.
    private func sessionCells(in rig: Rig) -> [SSHTerminalRexListSessionCell] {
        rig.list.view.layoutIfNeeded()
        let cells = collectionCells(rig.list).compactMap { $0 as? SSHTerminalRexListSessionCell }
        return cells.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func rowElement(_ cell: SSHTerminalRexListSessionCell) -> UIView? { cell.rowElement }
    private func disclosure(_ cell: SSHTerminalRexListSessionCell) -> UIView? { cell.disclosureElement }

    private func collectionView(_ list: UIViewController) -> UICollectionView? {
        func find(_ view: UIView) -> UICollectionView? {
            if let collection = view as? UICollectionView { return collection }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(list.view)
    }

    private func collectionCells(_ list: UIViewController) -> [UICollectionViewCell] {
        collectionView(list)?.visibleCells ?? []
    }

    /// A touch on the row: the collection view selects it.
    private func tap(_ cell: UICollectionViewCell, in rig: Rig) throws {
        let collection = try #require(collectionView(rig.list))
        let indexPath = try #require(collection.indexPath(for: cell))
        rig.list.collectionView(collection, didSelectItemAt: indexPath)
    }

    private func headers(in rig: Rig) -> [String] {
        collectionCells(rig.list).compactMap(\.accessibilityIdentifier).filter { $0.hasSuffix(".header") }.sorted()
    }

    // MARK: Hosts Rex was seen on

    private let seenHost = SSHTerminalProfile(host: "mac-studio", username: "chen", authentication: .deviceKey)

    /// A host saved with no Multiplexer that Oppi has seen Rex on leads with the
    /// section too; one it has never seen Rex on gets no follower, so nothing
    /// dials it from the tab.
    @Test func aHostRexWasSeenOnGetsTheSectionAndAHostNeverSeenIsNotDialed() async throws {
        let seen = seenHost
        try hosts.save([seen, plainHost])
        hosts.store().rexHosts.markSeen(seen)

        let rig = try mountTab([seen, plainHost])
        defer { rig.tearDown() }
        #expect(Array(rig.built.followers.keys) == [seen.id], "a follower for the host Rex was seen on, none for the other")
        #expect(headers(in: rig) == ["sshTerminal.rexList.\(seen.id.uuidString).header"])
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { !self.sessionCells(in: rig).isEmpty })
        #expect(sessionCells(in: rig).compactMap { self.rowElement($0)?.accessibilityLabel } == [
            "oppi, in oppi, 2 windows \u{00B7} 3 panes \u{00B7} 1 needs you", "dotfiles, in dotfiles, 1 pane",
        ])
        #expect(rig.built.streams[plainHost.id] == nil)
    }

    /// What a seen host does not get is a prompt: the tab dials it only when
    /// nothing would ask, and otherwise says Tap to connect.
    @Test func aHostRexWasSeenOnIsNeverSignedInWhenItWouldAsk() async throws {
        let seen = SSHTerminalProfile(host: "127.0.0.1", port: 1, username: "chen", authentication: .deviceKey)
        try hosts.save([seen])
        hosts.store().rexHosts.markSeen(seen)
        let rig = try mountDialingTab([seen], silent: Silent(false))
        defer { rig.tearDown() }
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { !self.actionCells(in: rig).isEmpty })
        #expect(actionCells(in: rig).first?.accessibilityIdentifier == "sshTerminal.rexList.\(seen.id.uuidString).connect")
        let session = try #require(rig.built.followers[seen.id]).session
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) {
            !session.connecting && !session.passwordPrompt && session.hostFailure == nil
        })
    }

    /// A tab follower that reads Rex on a host saved with Multiplexer: Rex
    /// remembers it too, so the memory survives the form's choice changing.
    @Test func readingRexOnAHostRemembersIt() async throws {
        let rig = try mountTab([rexHost])
        defer { rig.tearDown() }
        let follower = try #require(rig.built.followers[rexHost.id])
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { follower.monitor.available })
        #expect(hosts.store().rexHosts.hasSeenRex(on: rexHost))
    }

    /// Rex reported not installed (exit 5) on a host that was in the section
    /// only because Rex had been seen there: the memory is dropped and the
    /// section goes. The host stays saved.
    @Test func rexNotInstalledOnASeenHostForgetsItAndLeavesTheSection() async throws {
        let seen = seenHost
        try hosts.save([seen])
        hosts.store().rexHosts.markSeen(seen)
        let exiting = ExitingStreamHost(status: 5)
        let rig = try mountTab([seen], standIn: { _ in exiting })
        defer { rig.tearDown() }

        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { !self.hosts.store().rexHosts.hasSeenRex(on: seen) })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.list.view.layoutIfNeeded()
            return self.headers(in: rig).isEmpty
        }, "the section is gone")
        #expect(hosts.store().load().map(\.id) == [seen.id], "the host is still saved")
        #expect(exiting.opened == 1, "and asked once, not again")
    }

    /// Not installed on a host saved with Multiplexer: Rex keeps its section,
    /// with the advice, since the person chose Rex for it.
    @Test func rexNotInstalledOnAHostSavedWithRexKeepsItsSectionAndSaysSo() async throws {
        let rig = try mountTab([rexHost], standIn: { _ in ExitingStreamHost(status: 5) })
        defer { rig.tearDown() }
        let reason = "sshTerminal.rexList.\(rexHost.id.uuidString).reason"
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.list.view.layoutIfNeeded()
            return self.collectionCells(rig.list).contains { $0.accessibilityIdentifier == reason }
        })
        #expect(headers(in: rig) == ["sshTerminal.rexList.\(rexHost.id.uuidString).header"])
    }

    /// Rex installed and not running (exit 4): the host keeps its section and
    /// its memory, and the section says Rex is not running; it fills in when
    /// Rex starts.
    @Test func rexNotRunningOnASeenHostKeepsItAndShowsThatState() async throws {
        let seen = seenHost
        try hosts.save([seen])
        hosts.store().rexHosts.markSeen(seen)
        let rig = try mountTab([seen], standIn: { _ in ExitingStreamHost(status: 4) })
        defer { rig.tearDown() }
        let reason = "sshTerminal.rexList.\(seen.id.uuidString).reason"
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.list.view.layoutIfNeeded()
            return self.collectionCells(rig.list).contains { $0.accessibilityIdentifier == reason }
        })
        #expect(rig.built.followers[seen.id]?.monitor.absence == .notRunning)
        #expect(hosts.store().rexHosts.hasSeenRex(on: seen))
        #expect(headers(in: rig) == ["sshTerminal.rexList.\(seen.id.uuidString).header"])
    }

    @Test func theSectionAppearsOnlyForSavedRexHosts() async throws {
        let withoutRex = try mountTab([plainHost])
        defer { withoutRex.tearDown() }
        #expect(headers(in: withoutRex).isEmpty && actionCells(in: withoutRex).isEmpty)
        #expect(withoutRex.built.followers.isEmpty, "no Rex host, no monitor")

        let withRex = try mountTab([plainHost, rexHost])
        defer { withRex.tearDown() }
        #expect(Array(withRex.built.followers.keys) == [rexHost.id], "one monitor, for the Rex host only")
        #expect(headers(in: withRex) == ["sshTerminal.rexList.\(rexHost.id.uuidString).header"])
    }

    /// The rows follow a fake Rex: an element per session carrying a stable
    /// identifier, a label with the session, its panes, and who waits, and the
    /// status as its value; Rex changing redraws them.
    @Test func theRowsFollowRexAndAreElementsWithStableIdentifiers() async throws {
        let rig = try mountTab([rexHost])
        defer { rig.tearDown() }
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.list.view.layoutIfNeeded()
            return !self.sessionCells(in: rig).isEmpty
        })
        // Nothing is read until the tab is on screen and active: a window shows it, so it is.
        let prefix = "sshTerminal.rexList.\(rexHost.id.uuidString)."
        let found = sessionCells(in: rig).compactMap { rowElement($0) }
        #expect(found.map(\.accessibilityIdentifier) == [prefix + oppiSession, prefix + "session:01a18a26-6620-76be-b529-4d9ad2b36c64"])
        #expect(found.map(\.accessibilityLabel) == [
            "oppi, in oppi, 2 windows \u{00B7} 3 panes \u{00B7} 1 needs you", "dotfiles, in dotfiles, 1 pane",
        ])
        #expect(found.map { $0.accessibilityValue } == ["Needs approval", "Idle"])
        #expect(found.allSatisfy { $0 is UIButton }, "real buttons: the UI test finds them as buttons")

    }

    /// A touch and VoiceOver's activation open the session the same way, on the
    /// tab's follower, so it shows the terminal already open for it.
    @Test func tappingASessionOpensItsTerminalAndActivationDoesTheSame() async throws {
        let registry = SSHTerminalRegistry(backgroundTasks: FakeBackgroundTasks(), sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        defer { registry.closeAll(reason: "done") }
        let rig = try mountTab([rexHost], registry: registry)
        defer { rig.tearDown() }
        let open = try SSHTerminalChannel(answersTerminalQueries: false)
        open.opened(QuietConnection())
        registry.adopt(
            open, profile: rexHost,
            rexPane: RexPaneTarget(sessionID: oppiSession, blockID: "block:01a18a7e-911a-721b-a50b-14dfc0cc62ca", label: "pi"),
            queue: SSHTerminalEventQueue()
        )
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { !self.sessionCells(in: rig).isEmpty })
        let follower = try #require(rig.built.followers[rexHost.id])
        follower.session.connectedProfile = rexHost

        var opened: [RexPaneTarget] = []
        let openPane = follower.monitor.openPane
        follower.monitor.openPane = { opened.append($0); openPane?($0) }
        let cell = try #require(sessionCells(in: rig).first { self.rowElement($0)?.accessibilityIdentifier?.hasSuffix(oppiSession) == true })
        // The row's button and a touch on the cell run the same owner action.
        try #require(rowElement(cell) as? UIButton).sendActions(for: .touchUpInside)
        try tap(cell, in: rig)
        #expect(opened.map(\.blockID) == [claudeBlock, claudeBlock], "activation and a touch run the same action")
        #expect(follower.session.channel === open && follower.session.showsTerminal)
        #expect(registry.openTerminals().count == 1, "no second connection")
        // The chrome pushes the terminal over the tab, which then stops reading.
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.navigation.viewControllers.count == 2 })
        rig.navigation.popViewController(animated: false)
        follower.session.showsTerminal = false
    }

    /// The cell's ids, in the order the collection shows them.
    private func rexIDs(in rig: Rig, prefix: String) -> [String] {
        rig.list.view.layoutIfNeeded()
        return collectionCells(rig.list)
            .sorted { $0.frame.minY < $1.frame.minY }
            .compactMap { cell -> String? in
                let id = (cell as? SSHTerminalRexListSessionCell).flatMap { self.rowElement($0)?.accessibilityIdentifier } ?? cell.accessibilityIdentifier
                return id?.hasPrefix(prefix) == true ? String(id!.dropFirst(prefix.count)) : nil
            }
    }

    private func pass(_ rig: Rig) {
        rig.list.setNeedsUpdateProperties()
        rig.list.updatePropertiesIfNeeded()
        rig.list.view.layoutIfNeeded()
    }

    private let piBlock = "block:01a18a7e-911a-721b-a50b-14dfc0cc62ca"
    private let logsBlock = "block:01a18a7e-911a-721b-a50b-14dfc0cc62cb"
    private let dotfilesSession = "session:01a18a26-6620-76be-b529-4d9ad2b36c64"

    /// The disclosure shows a session's panes, grouped by window when it has
    /// more than one, and hides them again; only that session changes, and the
    /// choice outlasts a screen pushed over the tab.
    @Test func theDisclosureShowsAndHidesASessionsPanes() async throws {
        let rig = try mountTab([rexHost])
        defer { rig.tearDown() }
        let prefix = "sshTerminal.rexList.\(rexHost.id.uuidString)."
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { self.sessionCells(in: rig).count == 2 })
        #expect(rexIDs(in: rig, prefix: prefix) == ["header", oppiSession, dotfilesSession, "new"], "collapsed at first")

        let oppi = try #require(sessionCells(in: rig).first)
        let button = try #require(disclosure(oppi) as? UIButton)
        #expect(button.accessibilityIdentifier == prefix + oppiSession + ".disclosure")
        #expect(button.accessibilityValue == "Collapsed")
        button.sendActions(for: .touchUpInside)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            self.pass(rig)
            return self.rexIDs(in: rig, prefix: prefix).count > 4
        })
        // Two windows: each is named over its panes.
        let ids = rexIDs(in: rig, prefix: prefix)
        #expect(ids == ["header", oppiSession, "window:01a18a26-6645-713c-97f1-2f1058c8c82f", claudeBlock, piBlock,
                        "window:01a18a26-6645-713c-97f1-2f1058c8c830", logsBlock, dotfilesSession, "new"])
        let first = try #require(sessionCells(in: rig).first)
        let expandedButton = try #require(disclosure(first) as? UIButton)
        #expect(expandedButton.accessibilityValue == "Expanded")
        let actions = try #require(rowElement(first)?.accessibilityCustomActions)
        #expect(actions.map(\.name) == ["Rename", "Close Session", "Hide Panes"], "VoiceOver reaches the disclosure through the row too")

        // A pane row reads as the pane, with its folder and who waits.
        let pane = try #require(actionCells(in: rig).first { $0.accessibilityIdentifier == prefix + claudeBlock })
        #expect(pane.accessibilityLabel == "claude, in window agents, Fixing the build \u{00B7} oppi, needs you")
        #expect(pane.accessibilityValue == "Needs approval")

        // It outlasts a screen over the tab, and another session is unaffected.
        rig.navigation.pushViewController(UIViewController(), animated: false)
        rig.navigation.popViewController(animated: false)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            self.pass(rig)
            return self.rexIDs(in: rig, prefix: prefix).count == 9
        })

        // Hide them again.
        let firstAgain = try #require(sessionCells(in: rig).first)
        let again = try #require(disclosure(firstAgain) as? UIButton)
        again.sendActions(for: .touchUpInside)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            self.pass(rig)
            return self.rexIDs(in: rig, prefix: prefix) == ["header", self.oppiSession, self.dotfilesSession, "new"]
        })
    }

    /// A tap on a pane opens its session on that pane, a tap on the session
    /// row opens it on the focused one as before, and VoiceOver's activation
    /// of a pane does what its touch does.
    @Test func tappingAPaneOpensItsSessionOnThatPane() async throws {
        let rig = try mountTab([rexHost])
        defer { rig.tearDown() }
        let prefix = "sshTerminal.rexList.\(rexHost.id.uuidString)."
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { !self.sessionCells(in: rig).isEmpty })
        let follower = try #require(rig.built.followers[rexHost.id])
        follower.session.connectedProfile = rexHost
        var opened: [RexPaneTarget] = []
        follower.monitor.openPane = { opened.append($0) }

        follower.toggleExpanded(session: oppiSession)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            self.pass(rig)
            return self.actionCells(in: rig).contains { $0.accessibilityIdentifier == prefix + self.piBlock }
        })
        let pi = try #require(actionCells(in: rig).first { $0.accessibilityIdentifier == prefix + piBlock })
        try tap(pi, in: rig)
        #expect(opened == [RexPaneTarget(sessionID: oppiSession, blockID: piBlock, label: "pi")], "the tapped pane, not the focused one")
        #expect(pi.accessibilityActivate())
        #expect(opened.count == 2 && opened[1].blockID == piBlock)

        // The session row still opens the focused pane.
        let row = try #require(sessionCells(in: rig).first)
        try tap(row, in: rig)
        #expect(opened.last?.blockID == claudeBlock)
    }

    // MARK: Changing Rex

    private func json(_ request: RexFakeHost.Request) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? NSDictionary)
    }

    /// A follower reading a fake Rex that keeps its state (`RexFakeWorld`), ready to change it.
    private func managedFollower(_ world: RexFakeWorld) async throws -> SSHTerminalRexFollower {
        let follower = makeFollower(rexHost, stream: RexPreviewStreamHost(world: world))
        follower.sync(active: true)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { follower.canManage })
        return follower
    }

    private func titles(_ follower: SSHTerminalRexFollower) -> [String] { sessions(of: follower).map(\.title) }

    /// New Rex Session asks Rex for a session with one window holding a shell,
    /// opens that shell's pane, hands the claim on it back, and the list gains
    /// the session from Rex's own event.
    @Test func creatingASessionAsksForAShellWindowOpensItAndTheListFollowsRex() async throws {
        let world = RexFakeWorld.preview()
        let follower = try await managedFollower(world)
        defer { follower.close() }
        var opened: [RexPaneTarget] = []
        follower.monitor.openPane = { opened.append($0) }

        await follower.createSession()
        let create = try #require(world.requests("session.create").first)
        let shell: NSDictionary = ["initial_windows": [["layout": ["block": ["flavor": "com.superlogical.terminal.shell"]]]]]
        #expect(try json(create) == shell, "no name: Rex chooses one")
        #expect(opened == [RexPaneTarget(sessionID: "session:new-1", blockID: "block:new-1-1", label: "Shell")])
        let disown = try #require(world.requests("session.disown_block").first)
        #expect(try json(disown) == ["session_id": "session:new-1", "block_ids": ["block:new-1-1"]] as NSDictionary)
        #expect(follower.manageFailure == nil && follower.canManage)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { self.titles(follower) == ["oppi", "dotfiles", "new-session-1"] }, "the list follows the event")
    }

    @Test func renamingSendsTheTrimmedNameAnEmptyOneRestoresRexsAndTheListFollows() async throws {
        let world = RexFakeWorld.preview()
        let follower = try await managedFollower(world)
        defer { follower.close() }

        await follower.rename(session: oppiSession, to: "  work  ")
        #expect(try json(try #require(world.requests("session.set_label").last)) == ["session_id": oppiSession, "label": "work"] as NSDictionary)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { self.titles(follower) == ["work", "dotfiles"] })

        await follower.rename(session: oppiSession, to: "   ")
        #expect(try json(try #require(world.requests("session.set_label").last)) == ["session_id": oppiSession, "label": ""] as NSDictionary)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { self.titles(follower) == ["oppi", "dotfiles"] }, "Rex gave the session its own name back")
    }

    @Test func closingDestroysTheSessionAndItLeavesTheList() async throws {
        let world = RexFakeWorld.preview()
        let follower = try await managedFollower(world)
        defer { follower.close() }
        await follower.close(session: dotfilesSession)
        #expect(try json(try #require(world.requests("session.destroy").first)) == ["session_id": dotfilesSession] as NSDictionary)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { self.titles(follower) == ["oppi"] })
        #expect(follower.manageFailure == nil)
    }

    /// A refusal shows under the heading as Rex said it, the list stays as it
    /// was, and the next change that works clears it.
    @Test func aRefusalShowsInlineAndTheNextSuccessClearsIt() async throws {
        let world = RexFakeWorld.preview()
        let follower = try await managedFollower(world)
        defer { follower.close() }
        var opened = 0
        follower.monitor.openPane = { _ in opened += 1 }

        world.refuse("session.create", code: "conflict", message: "the server has as many sessions as it allows")
        await follower.createSession()
        #expect(follower.manageFailure == "Could not create a session. Rex refused: the server has as many sessions as it allows")
        #expect(opened == 0 && titles(follower) == ["oppi", "dotfiles"])
        let listed = SSHTerminalRexListRow.rows(hostName: "h", state: follower.listState)
        #expect(listed.contains { $0.id == "action" && $0.kind == .failure(follower.manageFailure ?? "") })

        world.refuse("session.destroy", code: "session_not_found", message: "no such session")
        await follower.close(session: "session:gone")
        #expect(follower.manageFailure == "Could not close the session. Rex refused: no such session")

        world.refuse("session.create", code: nil)
        await follower.createSession()
        #expect(follower.manageFailure == nil && opened == 1)
    }

    @Test func withNoStreamNothingCanBeChangedAndTheCallSaysSo() async throws {
        let follower = makeFollower(rexHost, stream: RexPreviewStreamHost(world: RexFakeWorld.preview()))
        defer { follower.close() }
        #expect(!follower.canManage)
        await follower.close(session: oppiSession)
        #expect(follower.manageFailure == "Could not close the session. The connection to Rex closed.")
    }

    /// Calls a UIAlertAction's handler, as a tap on its button would.
    private func press(_ title: String, in alert: UIAlertController) throws {
        let action = try #require(alert.actions.first { $0.title == title }, "no \(title) button")
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let block = try #require(action.value(forKey: "handler") as AnyObject?)
        unsafeBitCast(block, to: Handler.self)(action)
    }

    private func customAction(_ name: String, of cell: SSHTerminalRexListSessionCell) throws -> UIAccessibilityCustomAction {
        try #require(rowElement(cell)?.accessibilityCustomActions?.first { $0.name == name }, "no \(name) action")
    }

    /// Close is asked about first, and nothing is sent until it is confirmed;
    /// Rename takes a name in an alert. Both are on the row as custom actions,
    /// beside the swipe.
    @Test func closingNeedsAConfirmationAndRenamingTakesAName() async throws {
        let world = RexFakeWorld.preview()
        let rig = try mountTab([rexHost], standIn: { _ in RexPreviewStreamHost(world: world) })
        defer { rig.tearDown() }
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            self.pass(rig)
            return self.sessionCells(in: rig).count == 2 && self.rowElement(self.sessionCells(in: rig)[0])?.accessibilityCustomActions?.isEmpty == false
        })
        let dotfilesCell = try #require(sessionCells(in: rig).last)
        #expect(rowElement(dotfilesCell)?.accessibilityCustomActions?.map(\.name) == ["Rename", "Close Session", "Show Panes"])

        // Close: an alert names the session and says what ends; Cancel sends nothing.
        _ = try customAction("Close Session", of: dotfilesCell).actionHandler?(try customAction("Close Session", of: dotfilesCell))
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.list.presentedViewController is UIAlertController })
        var alert = try #require(rig.list.presentedViewController as? UIAlertController)
        #expect(alert.title == "Close session \u{201C}dotfiles\u{201D}?" && alert.message == "Every pane's program ends.")
        #expect(alert.actions.map(\.style) == [.destructive, .cancel])
        #expect(world.requests("session.destroy").isEmpty, "asking is not closing")
        try press("Cancel", in: alert)
        await rig.list.dismiss(animated: false)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.list.presentedViewController == nil })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) { world.requests("session.destroy").isEmpty })

        // Rename: the field starts with the name; the new one goes to Rex.
        _ = try customAction("Rename", of: dotfilesCell).actionHandler?(try customAction("Rename", of: dotfilesCell))
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.list.presentedViewController is UIAlertController })
        alert = try #require(rig.list.presentedViewController as? UIAlertController)
        #expect(alert.title == "Rename Session" && alert.textFields?.first?.text == "dotfiles")
        alert.textFields?.first?.text = "config"
        try press("Rename", in: alert)
        await rig.list.dismiss(animated: false)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.list.presentedViewController == nil })
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { world.requests("session.set_label").count == 1 })
        #expect(try json(world.requests("session.set_label")[0]) == ["session_id": dotfilesSession, "label": "config"] as NSDictionary)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            self.pass(rig)
            return self.sessionCells(in: rig).compactMap { self.rowElement($0)?.accessibilityLabel }.contains { $0.hasPrefix("config,") }
        })

        // Confirmed, close sends the call and the row goes.
        let renamed = try #require(sessionCells(in: rig).last)
        _ = try customAction("Close Session", of: renamed).actionHandler?(try customAction("Close Session", of: renamed))
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.list.presentedViewController is UIAlertController })
        alert = try #require(rig.list.presentedViewController as? UIAlertController)
        #expect(alert.title == "Close session \u{201C}config\u{201D}?")
        try press("Close Session", in: alert)
        await rig.list.dismiss(animated: false)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.list.presentedViewController == nil })
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { world.requests("session.destroy").count == 1 })
        #expect(try json(world.requests("session.destroy")[0]) == ["session_id": dotfilesSession] as NSDictionary)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            self.pass(rig)
            return self.sessionCells(in: rig).count == 1
        })
    }

    /// The row after the sessions makes one and opens it.
    @Test func theNewSessionRowCreatesAndOpensTheShell() async throws {
        let world = RexFakeWorld.preview()
        let rig = try mountTab([rexHost], standIn: { _ in RexPreviewStreamHost(world: world) })
        defer { rig.tearDown() }
        let follower = try #require(rig.built.followers[rexHost.id])
        var opened: [RexPaneTarget] = []
        follower.monitor.openPane = { opened.append($0) }
        let id = "sshTerminal.rexList.\(rexHost.id.uuidString).new"
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            self.pass(rig)
            return self.actionCells(in: rig).contains { $0.accessibilityIdentifier == id }
        })
        let row = try #require(actionCells(in: rig).first { $0.accessibilityIdentifier == id })
        #expect(row.accessibilityLabel == "New Rex Session")
        try tap(row, in: rig)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { opened.count == 1 })
        #expect(opened[0].sessionID == "session:new-1")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            self.pass(rig)
            return self.sessionCells(in: rig).count == 3
        })
    }

    @Test func theTabStopsReadingWhenItDisappearsAndReadsAgainOnReturn() async throws {
        let rig = try mountTab([rexHost])
        defer { rig.tearDown() }
        let stream = try #require(rig.built.streams[rexHost.id])
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { stream.hosts.count == 1 })

        let covering = UIViewController()
        rig.navigation.pushViewController(covering, animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { stream.hosts.first?.isClosed == true }, "a screen over the tab stops its monitor")
        rig.navigation.popViewController(animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { stream.hosts.count == 2 }, "the tab reads Rex again on return")
    }

    /// A host that would ask is not dialed by the tab, and the tap is what runs
    /// the connect.
    @Test func aRexHostThatNeedsAPromptShowsTapToConnectAndNeverDialsOnItsOwn() async throws {
        let host = SSHTerminalProfile(host: "127.0.0.1", port: 1, username: "chen", authentication: .deviceKey, opensRexSessions: true)
        let rig = try mountDialingTab([host], silent: Silent(false))
        defer { rig.tearDown() }
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { !self.actionCells(in: rig).isEmpty })
        let connect = try #require(actionCells(in: rig).first)
        #expect(connect.accessibilityIdentifier == "sshTerminal.rexList.\(host.id.uuidString).connect")
        #expect(connect.accessibilityLabel == "Tap to connect")
        let session = try #require(rig.built.followers[host.id]).session
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) {
            !session.connecting && !session.passwordPrompt && session.hostFailure == nil && rig.list.presentedViewController == nil
        }, "the tab dialed nothing and showed no sheet by itself")

        try tap(connect, in: rig)
        #expect(session.connecting || session.failure != nil, "the tap runs the normal connect")
        session.cancel()
    }

    /// What an automatic sign-in can run into although the host looked quiet:
    /// a key that changed or is not trusted, or a password that is not there.
    enum Hit: CaseIterable {
        case changedKey, unknownKey, missingPassword
    }

    /// The tab started the sign-in itself, so it must not present what it ran
    /// into: the row says so and offers Tap to connect, and the tap is what
    /// shows the trust decision or the password sheet.
    @Test(arguments: Hit.allCases)
    func anAutomaticSignInThatHitsAPromptPresentsNothingUntilTheTap(_ hit: Hit) async throws {
        let host = SSHTerminalProfile(host: "127.0.0.1", port: 1, username: "chen", authentication: .deviceKey, opensRexSessions: true)
        let silent = Silent(true)
        let rig = try mountDialingTab([host], silent: silent)
        defer { rig.tearDown() }
        let follower = try #require(rig.built.followers[host.id])
        let session = follower.session
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { follower.automaticAttempt }, "the tab signs in by itself when nothing would ask")
        session.cancel()
        silent.value = false

        let keyA = SSHHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZbA0Hd5UkWHXHAQsrp7ZCdVjLOZsb9eJwvcdU6UT5q")
        let keyB = SSHHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKeyOtherKe")
        session.failure = nil
        switch hit {
        case .changedKey: session.hostFailure = .hostKeyMismatch(saved: keyA, presented: keyB)
        case .unknownKey: session.hostFailure = .unknownHostKey(keyB)
        case .missingPassword: session.passwordPrompt = true
        }
        func pass() {
            rig.list.setNeedsUpdateProperties()
            rig.list.updatePropertiesIfNeeded()
            rig.list.view.layoutIfNeeded()
        }
        pass()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            pass()
            return rig.list.presentedViewController == nil
        }, "nothing is presented for what an automatic sign-in hit")
        #expect(follower.needsTap)
        let ids = collectionCells(rig.list).compactMap(\.accessibilityIdentifier)
        let prefix = "sshTerminal.rexList.\(host.id.uuidString)."
        #expect(ids.contains(prefix + "connect") && ids.contains(prefix + "failure"), "a failure line and Tap to connect")

        let connect = try #require(actionCells(in: rig).first)
        try tap(connect, in: rig)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            pass()
            return rig.list.presentedViewController != nil
        }, "the tap presents it")
        session.passwordPrompt = false
        session.hostFailure = nil
    }

    /// The hold is for the list's own sign-in. A pane opened from a row (or a
    /// pane terminal's Reconnect) runs on the same session and chrome with
    /// `listsRexSessions` off: its password prompt is the person's own action.
    @Test func aPanesPromptAfterAnAutomaticSignInIsPresented() async throws {
        let host = SSHTerminalProfile(host: "127.0.0.1", port: 1, username: "chen", authentication: .deviceKey, opensRexSessions: true)
        let rig = try mountDialingTab([host], silent: Silent(true))
        defer { rig.tearDown() }
        let follower = try #require(rig.built.followers[host.id])
        let session = follower.session
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { follower.automaticAttempt })
        session.cancel()

        // The sign-in held its prompt; a pane open then asks for a password.
        session.listsRexSessions = false
        session.passwordPrompt = true
        #expect(!follower.holdsPrompts)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.list.setNeedsUpdateProperties()
            rig.list.updatePropertiesIfNeeded()
            return rig.list.presentedViewController != nil
        }, "the pane's prompt is presented")
        session.passwordPrompt = false
    }

    /// A host saved with other credentials is a new host: the old one's
    /// trust failure must neither show nor be reopened by a tap.
    @Test func aHostSavedWithOtherCredentialsDropsWhatTheOldOneRanInto() async throws {
        let host = SSHTerminalProfile(host: "127.0.0.1", port: 1, username: "chen", authentication: .deviceKey, opensRexSessions: true)
        let follower = SSHTerminalRexFollower(
            profile: host, promptsAutomatically: false,
            session: SSHTerminalConnectSession(registry: SSHTerminalRegistry(), profileStore: hosts.store),
            signsInSilently: { _ in true }
        )
        defer { follower.close() }
        follower.sync(active: true)
        try #require(follower.automaticAttempt)
        follower.session.cancel()
        follower.session.failure = nil
        follower.session.hostFailure = .hostKeyMismatch(
            saved: SSHHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZbA0Hd5UkWHXHAQsrp7ZCdVjLOZsb9eJwvcdU6UT5q"),
            presented: SSHHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKeyOtherKe")
        )
        #expect(follower.promptNote != nil && follower.needsTap)

        var edited = host
        edited.port = 2
        follower.update(profile: edited)
        #expect(follower.promptNote == nil && follower.session.hostFailure == nil && !follower.automaticAttempt)
        #expect(!follower.holdsPrompts)
    }

    /// A host edited or deleted while the tab was covered is signed in, and
    /// saved, from the saved copy, never from the one the tab held before.
    @Test func aHostEditedWhileTheTabWasCoveredIsSignedInFromTheSavedCopy() async throws {
        let host = SSHTerminalProfile(host: "127.0.0.1", port: 1, username: "chen", authentication: .deviceKey, opensRexSessions: true)
        let silent = Silent(false)
        let rig = try mountDialingTab([host], silent: silent)
        defer { rig.tearDown() }
        let follower = try #require(rig.built.followers[host.id])
        rig.navigation.pushViewController(UIViewController(), animated: false)

        // The form saved a new port; meanwhile an approval makes the host quiet.
        var edited = host
        edited.port = 2
        try hosts.store().save(edited)
        silent.value = true
        rig.navigation.popViewController(animated: false)

        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { follower.session.attemptedPort != 22 })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) {
            follower.session.attemptedPort == 2 && self.hosts.store().profile(id: host.id)?.port == 2
        }, "it signs in with the saved copy and the edit is not saved over")
        follower.session.cancel()
    }

    @Test func aHostDeletedWhileTheTabWasCoveredIsNeitherSignedInNorSavedBack() async throws {
        let host = SSHTerminalProfile(host: "127.0.0.1", port: 1, username: "chen", authentication: .deviceKey, opensRexSessions: true)
        let silent = Silent(false)
        let rig = try mountDialingTab([host], silent: silent)
        defer { rig.tearDown() }
        let follower = try #require(rig.built.followers[host.id])
        rig.navigation.pushViewController(UIViewController(), animated: false)
        try hosts.store().delete(id: host.id)
        silent.value = true
        rig.navigation.popViewController(animated: false)

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) {
            !follower.session.connecting && follower.session.failure == nil && self.hosts.store().load().isEmpty
        }, "nothing dials the deleted host and the list stays empty")
    }

    /// The Keychain is asked once per visit, not on every pass of the screen.
    @Test func whetherASignInWouldAskIsNotReadOnEveryPass() {
        var asked = 0
        let follower = SSHTerminalRexFollower(
            profile: rexHost, promptsAutomatically: false,
            session: SSHTerminalConnectSession(registry: SSHTerminalRegistry(), profileStore: hosts.store),
            signsInSilently: { _ in asked += 1; return false }
        )
        defer { follower.close() }
        for _ in 0..<5 {
            _ = follower.needsTap
            follower.sync(active: true)
        }
        #expect(asked == 1)
        follower.appeared()
        _ = follower.needsTap
        #expect(asked == 2, "returning to the screen asks again")
    }
}

/// A terminal's connection whose Rex bridge is a fake host: every stream the
/// terminal opens for `RexBridge.command` is the next one `serve` makes.
private final class RexBridgeConnection: SSHTerminalConnection {
    private let serve: @Sendable (@escaping SSHPTYByteSink) -> SSHExecStream

    init(serve: @escaping @Sendable (@escaping SSHPTYByteSink) -> SSHExecStream) { self.serve = serve }

    func close() {}
    func send(_ bytes: Data) async throws {}
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        guard command == RexBridge.command else { throw SSHConnectionError.notConnected }
        return serve(sink)
    }
    func run(_ command: String, input: Data) async throws -> SSHExecResult { throw SSHConnectionError.commandRequestRejected }
    func checkAlive() async throws {}
    func cancel() async {}
}

/// The terminal's Rex monitor tells the Terminal tab what it found on the
/// host, and it must keep doing that where the bar hides Rex (a terminal whose
/// Run on Connect command is `herdr`): hiding is presentation only.
@Suite("Rex findings from a Herdr terminal", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalRexFindingBarContextTests {
    private let hosts = IsolatedHosts()
    private let mini = SSHTerminalProfile(host: "mac-mini", username: "chen", authentication: .deviceKey, startupCommand: "herdr")

    @Test func aTerminalReadsTheMultiplexersItsBarHidesOnlyWhenTheReadIsUsed() {
        let herdr = SSHTerminalBarContext(isRexPane: false, command: "herdr")
        let rexPane = SSHTerminalBarContext(isRexPane: true, command: nil)
        #expect(herdr == .herdr && rexPane == .rex)
        #expect(herdr.hidden == [.rex], "the Herdr terminal's bar shows no Rex")
        #expect(herdr.polls(.rex) && herdr.polls(.herdr), "but it still reads Rex, whose findings the tab uses")
        #expect(rexPane.polls(.rex) && !rexPane.polls(.herdr), "a Rex pane does not poll the host's Herdr")
        let plain = SSHTerminalBarContext.plain
        #expect(plain.polls(.rex) && plain.polls(.herdr))
    }

    private func mountHerdrTerminal(
        serve: @escaping @Sendable (@escaping SSHPTYByteSink) -> SSHExecStream
    ) throws -> (window: UIWindow, channel: SSHTerminalChannel) {
        try hosts.save([mini])
        let session = SSHTerminalConnectSession(registry: SSHTerminalRegistry(), profileStore: hosts.store)
        session.connectedProfile = mini
        let channel = try SSHTerminalChannel()
        channel.opened(RexBridgeConnection(serve: serve), command: "herdr")
        // The screen leaves when its session stops showing a terminal.
        session.channel = channel
        session.showsTerminal = true
        let controller = SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {}, session: session)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        return (window, channel)
    }

    private func tearDown(_ mounted: (window: UIWindow, channel: SSHTerminalChannel)) {
        mounted.window.isHidden = true
        mounted.window.rootViewController = nil
        mounted.channel.close(reason: "done")
    }

    /// Rex read on the host of a `herdr` terminal is remembered, so the
    /// Terminal tab follows that host.
    @Test func aHerdrTerminalThatReadsRexRemembersTheHost() async throws {
        let world = RexFakeWorld.preview()
        let mounted = try mountHerdrTerminal { world.host().open(sink: $0) }
        defer { tearDown(mounted) }
        #expect(!hosts.store().rexHosts.hasSeenRex(on: mini))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { self.hosts.store().rexHosts.hasSeenRex(on: self.mini) })
        #expect(!world.requests("session.attach_all").isEmpty, "the terminal read Rex though its bar shows no Rex")
    }

    /// No `rex` on the host of a `herdr` terminal: the memory is dropped.
    @Test func aHerdrTerminalOnAHostWithoutRexForgetsTheHost() async throws {
        hosts.store().rexHosts.markSeen(mini)
        let mounted = try mountHerdrTerminal { sink in
            let host = RexFakeHost { _ in .hold }
            let stream = host.open(sink: sink)
            Task { host.end(status: 5) }
            return stream
        }
        defer { tearDown(mounted) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !self.hosts.store().rexHosts.hasSeenRex(on: self.mini) })
    }
}
