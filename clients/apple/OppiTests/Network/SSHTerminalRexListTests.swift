import Foundation
import LocalAuthentication
import Synchronization
import Testing
import UIKit
@testable import Oppi

/// Saved hosts and passwords for a test: its own defaults suite and an
/// in-memory keychain, so nothing reaches the app's real store.
private struct IsolatedHosts {
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
        #expect(sessions[0].summary == "3 panes \u{00B7} 1 needs you")
        #expect(sessions[1].summary == "1 pane")
        #expect(sessions[0].accessibilityLabel == "oppi, 3 panes \u{00B7} 1 needs you")
        #expect(listed.map(\.id) == ["header", "session|s:oppi", "session|s:dots", "session|s:plain"])
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
        func connects(_ profile: SSHTerminalProfile) -> Bool {
            profile.connectsWithoutPrompt(approvals: approvals, knownHosts: known, store: hosts.store())
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
        // A device-key host whose key was never trusted: signing in would show the trust sheet.
        let follower = SSHTerminalRexFollower(
            profile: SSHTerminalProfile(host: "never-trusted-\(UUID().uuidString).example", username: "chen", authentication: .deviceKey, opensRexSessions: true),
            promptsAutomatically: false,
            session: SSHTerminalConnectSession(registry: SSHTerminalRegistry(), profileStore: hosts.store)
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

    private func mountTab(_ profiles: [SSHTerminalProfile], registry: SSHTerminalRegistry = SSHTerminalRegistry()) throws -> Rig {
        try hosts.save(profiles)
        let list = SSHTerminalHostListViewController()
        list.profileStore = hosts.store
        let built = Built()
        let store = hosts.store
        list.makeFollower = { profile in
            let stream = RexPreviewStreamHost()
            let follower = SSHTerminalRexFollower(
                profile: profile, promptsAutomatically: false,
                session: SSHTerminalConnectSession(registry: registry, profileStore: store),
                monitor: RexMonitor(publishDelay: .milliseconds(20), retryDelay: { _, _ in .milliseconds(10) }),
                standIn: stream
            )
            built.followers[profile.id] = follower
            built.streams[profile.id] = stream
            return follower
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
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
            return !self.actionCells(in: rig).isEmpty
        })
        // Nothing is read until the tab is on screen and active: a window shows it, so it is.
        let prefix = "sshTerminal.rexList.\(rexHost.id.uuidString)."
        let found = actionCells(in: rig)
        #expect(found.map(\.accessibilityIdentifier) == [prefix + oppiSession, prefix + "session:01a18a26-6620-76be-b529-4d9ad2b36c64"])
        #expect(found.map(\.accessibilityLabel) == ["oppi, 3 panes \u{00B7} 1 needs you", "dotfiles, 1 pane"])
        #expect(found.map { $0.accessibilityValue } == ["Needs approval", "Idle"])
        #expect(found.allSatisfy { $0.accessibilityTraits.contains(.button) })
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
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { !self.actionCells(in: rig).isEmpty })
        let follower = try #require(rig.built.followers[rexHost.id])
        follower.session.connectedProfile = rexHost

        var opened: [RexPaneTarget] = []
        let openPane = follower.monitor.openPane
        follower.monitor.openPane = { opened.append($0); openPane?($0) }
        let cell = try #require(actionCells(in: rig).first { $0.accessibilityIdentifier?.hasSuffix(oppiSession) == true })
        #expect(cell.accessibilityActivate())
        try tap(cell, in: rig)
        #expect(opened.map(\.blockID) == [claudeBlock, claudeBlock], "activation and a touch run the same action")
        #expect(follower.session.channel === open && follower.session.showsTerminal)
        #expect(registry.openTerminals().count == 1, "no second connection")
        // The chrome pushes the terminal over the tab, which then stops reading.
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.navigation.viewControllers.count == 2 })
        rig.navigation.popViewController(animated: false)
        follower.session.showsTerminal = false
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

    @Test func aRexHostThatNeedsAPromptShowsTapToConnectAndNeverAsksOnItsOwn() async throws {
        // This host's key was never trusted, so signing in would ask.
        let untrusted = SSHTerminalProfile(
            host: "never-trusted-\(UUID().uuidString).example", username: "chen", authentication: .deviceKey, opensRexSessions: true
        )
        try hosts.save([untrusted])
        let list = SSHTerminalHostListViewController()
        list.profileStore = hosts.store
        let store = hosts.store
        var sessions: [SSHTerminalConnectSession] = []
        list.makeFollower = { profile in
            let session = SSHTerminalConnectSession(registry: SSHTerminalRegistry(), profileStore: store)
            sessions.append(session)
            return SSHTerminalRexFollower(profile: profile, promptsAutomatically: false, session: session)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = RouterNavigationController(rootViewController: list)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        list.view.layoutIfNeeded()

        let rig = Rig(list: list, window: window, navigation: try #require(list.navigationController), built: Built())
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { !self.actionCells(in: rig).isEmpty })
        let connect = try #require(actionCells(in: rig).first)
        #expect(connect.accessibilityIdentifier == "sshTerminal.rexList.\(untrusted.id.uuidString).connect")
        #expect(connect.accessibilityLabel == "Tap to connect")
        let session = try #require(sessions.first)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) {
            !session.connecting && !session.passwordPrompt && session.hostFailure == nil && list.presentedViewController == nil
        }, "the tab dialed nothing and showed no sheet by itself")

        try tap(connect, in: rig)
        #expect(session.connecting || session.failure != nil || session.hostFailure != nil, "the tap runs the normal connect")
        session.cancel()
    }
}
