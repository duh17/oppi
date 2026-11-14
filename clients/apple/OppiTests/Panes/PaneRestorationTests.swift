import Foundation
import Testing
import UIKit
@testable import Oppi

/// A window's panes across a relaunch (build plan §1.8): written per scene,
/// read back into a fresh window against the stores, each entry resolving on
/// its own; what is gone shows its leaf state.
@MainActor
@Suite("Pane restoration", .serialized)
struct PaneRestorationTests: PaneFixtureBuilding {
    private let serverId = "sha256:pane-restore"
    private let workspace = makeTestWorkspace(id: "ws-1", name: "Oppi")

    /// A phone-sized window in the test host's scene.
    private func makeWindow() throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "leaf state tests need the test host's window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        return window
    }

    private func makeStore() throws -> PaneTreeStore {
        let suite = "PaneRestorationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return PaneTreeStore(defaults: defaults)
    }

    /// A paired, connected server holding `sessions` in workspace `ws-1`.
    private func makeRoot(sessions: [Session]) async throws -> AppRootEnvironment {
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: makeTestURLProtocolClient())
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.workspaceStore.upsert(workspace, serverId: serverId)
        for session in sessions { _ = connection.sessionStore.upsert(session) }
        return root
    }

    private func session(_ id: String, ephemeral: Bool = false) -> Session {
        var session = makeTestSession(id: id, workspaceId: "ws-1")
        session.ephemeral = ephemeral ? true : nil
        return session
    }

    private func chatInWorkspace(_ sessionId: String) -> [WorkspaceStackRouteElement] {
        [
            .workspace(WorkspaceNavTarget(serverId: serverId, workspace: workspace)),
            .session(WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId, workspaceId: "ws-1")),
        ]
    }

    /// Writes `navigation`'s tree for `scene` as the app does when it settles.
    private func save(_ panes: ScenePanes, _ navigation: SceneNavigation, scene: String, store: PaneTreeStore) {
        store.save(PaneLayoutArchive(restorable: panes.layout(navigation: navigation, rootServerId: serverId)), scene: scene)
    }

    @Test func aRelaunchRestoresTheChatItsGitPanelWidthAndFocus() async throws {
        let store = try makeStore()
        let before = try await makeRoot(sessions: [session("s-1")])
        before.navigation.restorePrimaryStack(chatInWorkspace("s-1"))
        let panes = before.navigation.panes
        panes.companionDidOpen(PaneStackEntry(serverId: serverId, route: .git(workspace: "ws-1", worktree: nil)))
        panes.setCompanionShare(0.4)
        panes.focusCompanion(true)
        panes.setCompanionZoomed(true)
        save(panes, before.navigation, scene: "scene-a", store: store)

        let after = try await makeRoot(sessions: [session("s-1")])
        after.navigation.panes.connect(scene: "scene-a", store: store)
        after.navigation.panes.restore(navigation: after.navigation, coordinator: after.coordinator)

        #expect(after.navigation.workspaceStackRouteElements == chatInWorkspace("s-1"))
        #expect(after.navigation.panes.takePendingPanel(for: "s-1") == .git(workspace: "ws-1", worktree: nil))
        #expect(abs((after.navigation.panes.companionShare ?? 0) - 0.4) < 1e-9)
        let restored = after.navigation.panes.takeRestoredCompanionState()
        #expect(restored.focused)
        #expect(restored.zoomed)
    }

    /// The host takes the restored companion as it mounts: the saved share of
    /// the window, not the panel's own ideal width, and the focus.
    @Test func aRestoredCompanionMountsAtItsSavedShareWithFocus() async throws {
        let store = try makeStore()
        let before = try await makeRoot(sessions: [session("s-1")])
        before.navigation.restorePrimaryStack(chatInWorkspace("s-1"))
        let saved = before.navigation.panes
        saved.companionDidOpen(PaneStackEntry(serverId: serverId, route: .git(workspace: "ws-1", worktree: nil)))
        saved.setCompanionShare(0.45)
        saved.focusCompanion(true)
        save(saved, before.navigation, scene: "scene-host", store: store)

        let after = try await makeRoot(sessions: [session("s-1")])
        after.navigation.panes.connect(scene: "scene-host", store: store)
        after.navigation.panes.restore(navigation: after.navigation, coordinator: after.coordinator)
        let host = PaneTestHost(width: 1000, scenePanes: after.navigation.panes)
        defer { host.hide() }
        host.showPanel(minWidth: 320, idealWidth: 400, maxWidth: 640)

        #expect(host.companionWidth == 450, "0.45 of the window, not the ideal 400")
        #expect(abs(host.screenWidth - 550) < 0.5)
        #expect(host.panes.focusedLeaf == .companion)
        #expect(!host.panes.primary.view.accessibilityElementsHidden, "both leaves show")
    }

    /// Relaunched while a pane filled the window: it comes back zoomed with
    /// its grip shown, whose menu leads with Restore, and Restore brings the
    /// chat back beside it.
    @Test func aRelaunchWhileZoomedComesBackWithItsGripsRestore() async throws {
        let store = try makeStore()
        let before = try await makeRoot(sessions: [session("s-1")])
        before.navigation.restorePrimaryStack(chatInWorkspace("s-1"))
        let saved = before.navigation.panes
        let files = try #require(saved.split(saved.routedLeafID, axis: .row))
        saved.show(PaneStackEntry(serverId: serverId, route: .files(workspace: "ws-1", path: nil)), in: files)
        saved.zoom(files)
        save(saved, before.navigation, scene: "scene-zoomed", store: store)

        let after = try await makeRoot(sessions: [session("s-1")])
        after.navigation.panes.connect(scene: "scene-zoomed", store: store)
        after.navigation.panes.restore(navigation: after.navigation, coordinator: after.coordinator)
        #expect(after.navigation.panes.zoomedCell == files)
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true, scenePanes: after.navigation.panes)
        defer { host.hide() }
        let leaf = try #require(host.panes.view.subviews.first { $0.accessibilityIdentifier == "pane.leaf.\(files.raw)" })
        #expect(leaf.frame == host.panes.view.bounds, "the pane still fills the window")
        #expect(host.panes.primary.view.isHidden)

        let capsule = try #require(host.panes.view.subviews.lazy.compactMap { $0 as? PaneGripView }.first { $0.leafID == files })
        #expect(!capsule.isHidden)
        #expect(capsule.accessibilityValue == "Zoomed")
        let restore = try #require(capsule.accessibilityCustomActions?.first)
        #expect(restore.name == "Restore")
        host.act { _ = restore.actionHandler?(restore) }
        #expect(after.navigation.panes.zoomedCell == nil)
        #expect(!host.panes.primary.view.isHidden, "the chat is back")
        #expect(leaf.frame.width < 1133)
    }

    /// The routed leaf behind another pane's zoom: the restored stack showing
    /// keeps the restored zoom, and the person opening a session there (a
    /// sidebar tap) brings the routed leaf back, focused.
    @Test func navigatingTheHiddenRoutedLeafRevealsItButTheRestoreDoesNot() async throws {
        let store = try makeStore()
        let before = try await makeRoot(sessions: [session("s-1"), session("s-2")])
        before.navigation.restorePrimaryStack(chatInWorkspace("s-1"))
        let saved = before.navigation.panes
        let files = try #require(saved.split(saved.routedLeafID, axis: .row))
        saved.show(PaneStackEntry(serverId: serverId, route: .files(workspace: "ws-1", path: nil)), in: files)
        saved.zoom(files)
        save(saved, before.navigation, scene: "scene-reveal", store: store)

        let after = try await makeRoot(sessions: [session("s-1"), session("s-2")])
        let panes = after.navigation.panes
        panes.connect(scene: "scene-reveal", store: store)
        panes.restore(navigation: after.navigation, coordinator: after.coordinator)
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true, scenePanes: panes)
        defer { host.hide() }
        host.act { host.panes.routedLeafWillShowScreen() }
        #expect(panes.zoomedCell == files, "the restored stack showing is not navigation")
        #expect(host.panes.primary.view.isHidden)

        after.navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: serverId, sessionId: "s-2", workspaceId: "ws-1")
        )
        host.act { host.panes.routedLeafWillShowScreen() }
        #expect(panes.zoomedCell == nil, "the zoom ends")
        #expect(host.panes.focusedLeaf == .primary)
        #expect(!host.panes.primary.view.isHidden)

        // Collapsed, it expands the same way.
        host.act { host.panes.collapse(panes.routedLeafID) }
        #expect(panes.collapsedCells.contains(panes.routedLeafID))
        after.navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: serverId, sessionId: "s-1", workspaceId: "ws-1")
        )
        host.act { host.panes.routedLeafWillShowScreen() }
        #expect(!panes.collapsedCells.contains(panes.routedLeafID))
    }

    /// The tree is written once it has rested: a burst of changes writes
    /// only its last state, 500 ms after it.
    @Test func aBurstOfChangesIsWrittenOnceItRests() async throws {
        let store = try makeStore()
        let root = try await makeRoot(sessions: [session("s-1"), session("s-2")])
        root.navigation.panes.connect(scene: "scene-burst", store: store)
        root.navigation.panes.restore(navigation: root.navigation, coordinator: root.coordinator)
        root.navigation.restorePrimaryStack(chatInWorkspace("s-1"))
        try await Task.sleep(for: .milliseconds(100))
        root.navigation.restorePrimaryStack(chatInWorkspace("s-2"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.load(scene: "scene-burst") == nil, "nothing is written while the changes keep coming")

        let written = await waitForMainActorCondition(timeout: .seconds(2)) {
            store.load(scene: "scene-burst") != nil
        }
        #expect(written)
        let routes = store.load(scene: "scene-burst")?.layout.leaves.first?.stack.map(\.route)
        #expect(routes == [.sessions(workspace: "ws-1"), .session("s-2")], "the last state, not the first")
    }

    /// O1: relaunched offline, the chat is a leaf state until its server
    /// answers, so its extension panel and reading position wait. A save
    /// meanwhile keeps both, and the next launch still has them.
    @Test func aSaveBeforeTheChatShowsKeepsItsWaitingPanelAndPosition() async throws {
        let store = try makeStore()
        let chat = PaneLeaf(
            id: id("main"), name: nil,
            stack: [
                PaneStackEntry(serverId: serverId, route: .sessions(workspace: nil)),
                PaneStackEntry(serverId: serverId, route: .session("s-offline")),
            ],
            attachedTo: nil, origin: .split
        )
        let panel = PaneStackEntry(serverId: serverId, route: .panel(session: "s-offline", id: "jobs"))
        let side = PaneLeaf(id: id("side"), name: nil, stack: [panel], attachedTo: chat.id, origin: .attached)
        let scroll = PaneChatScroll(sessionId: "s-offline", itemId: "item-9", relativeY: 0.25)
        store.save(PaneLayoutArchive(
            restorable: PaneLayout(
                root: .split(axis: .row, children: [.leaf(chat), .leaf(side)], weights: [0.6, 0.4]),
                focus: chat.id, recency: [chat.id, side.id]
            ),
            chatScroll: [chat.id: scroll],
            companionFraction: 0.4
        ), scene: "scene-offline")

        let root = try await makeRoot(sessions: [])
        root.navigation.panes.connect(scene: "scene-offline", store: store)
        root.navigation.panes.restore(navigation: root.navigation, coordinator: root.coordinator)
        #expect(root.navigation.workspaceStackRouteElements == [.paneEntry(PaneStackEntry(serverId: serverId, route: .session("s-offline")))])
        root.navigation.panes.flush()

        let saved = try #require(store.load(scene: "scene-offline"))
        #expect(saved.layout.leaves.first { $0.attachedTo != nil }?.stack == [panel])
        #expect(saved.chatScroll[chat.id] == scroll)
    }

    /// A panel link whose chat is not on screen stands as "Chat not shown";
    /// Open Chat puts the chat in its place and hands the chat its panel.
    @Test func aPanelWithoutItsChatOpensTheChatWithThePanelBesideIt() async throws {
        let root = try await makeRoot(sessions: [session("s-1")])
        let entry = PaneStackEntry(serverId: serverId, route: .panel(session: "s-1", id: "jobs"))
        root.navigation.pushPaneEntry(entry)
        let screen = PaneLeafStateViewController(entry: entry, root: root)
        let window = try makeWindow()
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        screen.updatePropertiesIfNeeded()
        #expect(screen.shownState == .chatNotShown)
        #expect(screen.view.accessibilityIdentifier == "pane.state.chatNotShown")

        let config = try #require(screen.stateConfigurationForTesting)
        config.buttonProperties.primaryAction?.performWithSender(nil, target: nil)
        #expect(root.navigation.workspaceStackRouteElements == [
            .session(WorkspaceSessionNavTarget(serverId: serverId, sessionId: "s-1", workspaceId: "ws-1")),
        ])
        #expect(root.navigation.panes.pendingPanel(for: "s-1") == entry.route)
    }

    /// X1, X3: each entry resolves on its own. A session the stores do not
    /// hold, or a server no longer paired, comes back as its leaf state.
    @Test func entriesThatCannotOpenComeBackAsTheirLeafStates() async throws {
        let store = try makeStore()
        let removedServer = "sha256:removed"
        let gone = PaneStackEntry(serverId: serverId, route: .session("s-gone"))
        let unpaired = PaneStackEntry(serverId: removedServer, route: .file(.host, path: "/srv/notes.md", line: nil))
        let leaf = PaneLeaf(
            id: id("main"), name: nil,
            stack: [PaneStackEntry(serverId: serverId, route: .sessions(workspace: nil)), gone, unpaired],
            attachedTo: nil, origin: .split
        )
        store.save(PaneLayoutArchive(restorable: PaneLayout(single: leaf)), scene: "scene-b")

        let root = try await makeRoot(sessions: [])
        root.navigation.panes.connect(scene: "scene-b", store: store)
        root.navigation.panes.restore(navigation: root.navigation, coordinator: root.coordinator)

        #expect(root.navigation.workspaceStackRouteElements == [.paneEntry(gone), .paneEntry(unpaired)])
        #expect(PaneEntries.state(of: unpaired, coordinator: root.coordinator) == .missing(.server))
        // The test server has no live transport, so its badge says offline:
        // a session it might still have waits on the server, never "missing".
        #expect(PaneEntries.state(of: gone, coordinator: root.coordinator) == .unreachable(.retry))
        #expect(PaneEntries.state(of: gone, coordinator: root.coordinator, lookedUp: .absent) == .missing(.session))
    }

    /// The leaf state screen of an entry on a removed server shows it as
    /// missing; Close Pane takes the entry and what was above it off the stack.
    @Test func aRemovedServersLeafOffersCloseAndLeavesTheStack() async throws {
        let root = try await makeRoot(sessions: [])
        let entry = PaneStackEntry(serverId: "sha256:removed", route: .session("s-1"))
        root.navigation.pushPaneEntry(entry)
        let screen = PaneLeafStateViewController(entry: entry, root: root)
        let window = try makeWindow()
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        screen.updatePropertiesIfNeeded()
        #expect(screen.shownState == .missing(.server))
        #expect(screen.view.accessibilityIdentifier == "pane.state.missing.server")

        root.navigation.closePaneEntry(entry)
        #expect(root.navigation.workspaceStackRouteElements.isEmpty)
    }

    /// The leaf state turns into the content once the stores hold it (a
    /// session the server reported after a reconnect, X4).
    @Test func anEntryOpensItsContentOnceTheStoresHoldIt() async throws {
        let root = try await makeRoot(sessions: [])
        let entry = PaneStackEntry(serverId: serverId, route: .session("s-late"))
        root.navigation.pushPaneEntry(entry)
        let screen = PaneLeafStateViewController(entry: entry, root: root)
        let window = try makeWindow()
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        screen.updatePropertiesIfNeeded()
        #expect(screen.shownState != .content)

        _ = try #require(root.coordinator.connection(for: serverId)).sessionStore.upsert(session("s-late"))
        screen.updatePropertiesIfNeeded()
        await Task.yield()
        #expect(root.navigation.workspaceStackRouteElements == [
            .session(WorkspaceSessionNavTarget(serverId: serverId, sessionId: "s-late", workspaceId: "ws-1")),
        ])
    }

    /// SD3: an Incognito chat leaves nothing behind; SD1: a deleted session's
    /// leaf state leaves the stack with it.
    @Test func incognitoChatsAreNotSavedAndDeletedSessionsLeaveEveryEntry() async throws {
        let store = try makeStore()
        let root = try await makeRoot(sessions: [session("s-1"), session("s-incognito", ephemeral: true)])
        root.navigation.panes.connect(scene: "scene-c", store: store)
        root.navigation.panes.restore(navigation: root.navigation, coordinator: root.coordinator)
        root.navigation.restorePrimaryStack(chatInWorkspace("s-incognito"))
        // Its extension panel goes with it.
        root.navigation.panes.companionDidOpen(
            PaneStackEntry(serverId: serverId, route: .panel(session: "s-incognito", id: "jobs"))
        )
        root.navigation.panes.flush()
        let saved = try #require(store.load(scene: "scene-c"))
        #expect(saved.layout.leaves.flatMap(\.stack).map(\.route) == [.sessions(workspace: "ws-1")])

        let placeholder = PaneStackEntry(serverId: serverId, route: .session("s-1"))
        root.navigation.restorePrimaryStack([.paneEntry(placeholder)])
        root.navigation.removeSessionRoute(serverId: serverId, sessionId: "s-1")
        #expect(root.navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test func eachSceneKeepsItsOwnTreeAndANewSceneStartsFromTheNewest() throws {
        let store = try makeStore()
        func layout(_ session: String) -> PaneLayoutArchive? {
            PaneLayoutArchive(restorable: PaneLayout(single: PaneLeaf(
                id: id("main"), name: nil,
                stack: [PaneStackEntry(serverId: serverId, route: .session(session))],
                attachedTo: nil, origin: .split
            )))
        }
        store.save(layout("first"), scene: "scene-1")
        store.save(layout("second"), scene: "scene-2")
        #expect(store.load(scene: "scene-1") == layout("first"))

        // A force-quit the system answered by discarding the scene: the next
        // scene has no entry of its own and takes the newest tree.
        store.discard(scenes: ["scene-1", "scene-2"])
        #expect(store.load(scene: "scene-3") == layout("second"))
    }

    /// A restore the app did not survive (the mark is still set at launch)
    /// is not tried again: the window starts on the list, and the trees go.
    @Test func aRestoreTheAppDidNotSurviveIsNotTriedAgain() async throws {
        let store = try makeStore()
        let root = try await makeRoot(sessions: [session("s-1")])
        root.navigation.restorePrimaryStack(chatInWorkspace("s-1"))
        save(root.navigation.panes, root.navigation, scene: "scene-d", store: store)
        store.markRestoring(true, scene: "scene-d")

        let after = try await makeRoot(sessions: [session("s-1")])
        after.navigation.panes.connect(scene: "scene-d", store: store)
        after.navigation.panes.restore(navigation: after.navigation, coordinator: after.coordinator)
        #expect(after.navigation.workspaceStackRouteElements.isEmpty)
        #expect(store.load(scene: "scene-d") == nil)
        #expect(!store.lastRestoreWasInterrupted(scene: "scene-d"))
    }

    /// The crash mark is one window's: a restore that did not survive in one
    /// scene costs another scene nothing, and a discarded scene leaves no mark.
    @Test func aRestoreTheAppDidNotSurviveCostsOnlyItsOwnScene() async throws {
        let store = try makeStore()
        let root = try await makeRoot(sessions: [session("s-1"), session("s-2")])
        root.navigation.restorePrimaryStack(chatInWorkspace("s-1"))
        save(root.navigation.panes, root.navigation, scene: "scene-crashed", store: store)
        root.navigation.restorePrimaryStack(chatInWorkspace("s-2"))
        save(root.navigation.panes, root.navigation, scene: "scene-other", store: store)
        store.markRestoring(true, scene: "scene-crashed")

        let after = try await makeRoot(sessions: [session("s-1"), session("s-2")])
        after.navigation.panes.connect(scene: "scene-other", store: store)
        after.navigation.panes.restore(navigation: after.navigation, coordinator: after.coordinator)
        #expect(after.navigation.workspaceStackRouteElements == chatInWorkspace("s-2"))
        #expect(store.lastRestoreWasInterrupted(scene: "scene-crashed"))

        store.discard(scenes: ["scene-crashed"])
        #expect(!store.lastRestoreWasInterrupted(scene: "scene-crashed"))
    }

    /// B2: under App Lock a restore mounts nothing behind the cover; the saved
    /// screens open once the app unlocks.
    @Test func aRestoreUnderAppLockWaitsForUnlock() async throws {
        let store = try makeStore()
        let before = try await makeRoot(sessions: [session("s-1")])
        before.navigation.restorePrimaryStack(chatInWorkspace("s-1"))
        save(before.navigation.panes, before.navigation, scene: "scene-locked", store: store)

        let lockSuite = "PaneRestorationTests.lock.\(UUID().uuidString)"
        let lockDefaults = try #require(UserDefaults(suiteName: lockSuite))
        defer { lockDefaults.removePersistentDomain(forName: lockSuite) }
        AppLockSettings.setTimeout(.immediately, in: lockDefaults)
        let appLock = AppLockService(
            defaults: lockDefaults,
            availability: { .available },
            method: { .faceID },
            authenticator: { _, _ in .success },
            didTurnOn: {},
            isProtectedDataAvailable: { true }
        )
        #expect(appLock.isLocked, "App Lock on starts locked, as a cold launch does")

        let after = try await makeRoot(sessions: [session("s-1")])
        after.navigation.panes.connect(scene: "scene-locked", store: store)
        after.navigation.panes.restore(navigation: after.navigation, coordinator: after.coordinator, appLock: appLock)
        let mountedWhileLocked = await waitForMainActorCondition(timeout: .milliseconds(300)) {
            !after.navigation.workspaceStackRouteElements.isEmpty
        }
        #expect(!mountedWhileLocked, "nothing mounts behind the cover")

        #expect(await appLock.unlock())
        let restored = await waitForMainActorCondition(timeout: .seconds(3)) {
            after.navigation.workspaceStackRouteElements == chatInWorkspace("s-1")
        }
        #expect(restored, "the saved chat opens once unlocked")
    }

    /// X1 against X4: a session on a second, non-active server is asked of
    /// that server, not the active one, so the active server's "not found"
    /// never calls it missing; it opens once its own server answers.
    @Test func aSessionIsLookedUpOnItsOwnServer() async throws {
        let root = try await makeTestTwoServerRoot(firstId: "sha256:first", otherId: "sha256:other")
        var asked: [String] = []
        root.coordinator._getSessionRecordForTesting = { serverId, id in
            asked.append(serverId)
            guard serverId == "sha256:other" else { throw APIError.server(status: 404, message: "not found") }
            return makeTestSession(id: id, workspaceId: "ws-other")
        }
        let entry = PaneStackEntry(serverId: "sha256:other", route: .session("s-elsewhere"))
        root.navigation.pushPaneEntry(entry)
        let screen = PaneLeafStateViewController(entry: entry, root: root)
        let window = try makeWindow()
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        screen.updatePropertiesIfNeeded()

        let opened = await waitForMainActorCondition(timeout: .seconds(3)) {
            screen.updatePropertiesIfNeeded()
            return root.navigation.workspaceStackRouteElements == [
                .session(WorkspaceSessionNavTarget(serverId: "sha256:other", sessionId: "s-elsewhere", workspaceId: "ws-other")),
            ]
        }
        #expect(opened, "the session on its own server opened; shown: \(String(describing: screen.shownState))")
        #expect(asked == ["sha256:other"], "only the entry's server was asked")
    }

    /// X8: every server a window newly chooses is recorded, for launch and
    /// App Intents; a leaf bringing its own server forward is not a choice.
    @Test func eachServerTheWindowChoosesIsRecorded() async throws {
        let root = try await makeTestTwoServerRoot(firstId: "sha256:first", otherId: "sha256:other")
        var recorded: [String] = []
        root.navigation.app.onServerChosen = { recorded.append($0) }
        #expect(root.navigation.chooseServer("sha256:other", coordinator: root.coordinator))
        #expect(root.navigation.chooseServer("sha256:other", coordinator: root.coordinator))
        #expect(root.coordinator.restoreActiveServer("sha256:first"))
        #expect(recorded == ["sha256:other"])
    }

    /// X8: launch opens the server last made active, as the preference holds
    /// it; once that server is removed, the first paired one.
    @Test func launchPicksTheLastActiveServer() async throws {
        let suite = "PaneRestorationTests.lastActive.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try await makeTestTwoServerRoot(firstId: "sha256:first", otherId: "sha256:other")
        root.navigation.app.onServerChosen = { AppPreferences.LastActiveServer.set($0, in: defaults) }
        #expect(root.navigation.chooseServer("sha256:other", coordinator: root.coordinator))

        let servers = root.coordinator.serverStore.servers
        let lastActive = AppPreferences.LastActiveServer.id(in: defaults)
        #expect(AppLaunchPairingPolicy.launchServer(lastActiveId: lastActive, servers: servers)?.id == "sha256:other")

        let remaining = servers.filter { $0.id != "sha256:other" }
        #expect(AppLaunchPairingPolicy.launchServer(lastActiveId: lastActive, servers: remaining)?.id == "sha256:first")
        #expect(AppLaunchPairingPolicy.launchServer(lastActiveId: lastActive, servers: []) == nil)
    }
}
