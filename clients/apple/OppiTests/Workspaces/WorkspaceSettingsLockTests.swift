import Testing
import UIKit
@testable import Oppi

/// A scoped lock that engages while Workspace Settings is open (leave and
/// return with App Lock off) must leave nothing of the workspace usable: not
/// its Delete confirmation, not its Oppi bar, and no action that runs after
/// one of them.
@MainActor
@Suite("Workspace Settings lock", .serialized)
struct WorkspaceSettingsLockTests {
    private static let serverId = "srv"
    private static let scope = ScopedLockScope.workspace(serverId: serverId, workspaceId: "w1")

    private struct Screen {
        let controller: WorkspaceSettingsViewController
        let model: WorkspaceSettingsModel
        let locks: ScopedLockService
        let leaves: Leaves
        let window: UIWindow
    }

    @MainActor
    private final class Leaves {
        var count = 0
    }

    private func makeLocks() throws -> ScopedLockService {
        let defaults = try #require(UserDefaults(suiteName: "WorkspaceSettingsLockTests-\(UUID().uuidString)"))
        let appLock = AppLockService(
            defaults: defaults,
            availability: { .available },
            method: { .faceID },
            authenticator: { _ in .success },
            didTurnOn: {},
            isProtectedDataAvailable: { true }
        )
        return ScopedLockService(
            defaults: defaults, appLock: appLock, didLock: { _ in }, isProtectedDataAvailable: { true }
        )
    }

    /// The screen over a fixture model and a connection (with an API client unless
    /// asked not to), in
    /// a window tall enough to realize every row.
    private func mount(locked: Bool, withAPIClient: Bool = true) throws -> Screen {
        let workspace = Workspace(
            id: "w1", name: "oppi-dev", description: nil,
            hostMount: "~/workspace/oppi", createdAt: Date(), updatedAt: Date()
        )
        let connection = ServerConnection()
        connection.setPreviewServerId(Self.serverId)
        connection.workspaceStore.setActiveServer(Self.serverId)
        connection.workspaceStore.workspacesByServer[Self.serverId] = [workspace]
        if withAPIClient {
            connection.setPreviewAPIClient(APIClient(
                baseURL: try #require(URL(string: "https://preview.invalid")), token: "sk_test"
            ))
        }
        let model = WorkspaceSettingsModel.screenshotFixture(
            workspace: workspace, skills: [], extensions: [], projectTrust: nil, sandboxMcpServers: []
        )
        model.attach(connection: connection, workspace: workspace)
        let locks = try makeLocks()
        if locked { locks.lock(Self.scope) }
        let root = makeTestAppRoot()
        let controller = WorkspaceSettingsViewController(
            workspace: workspace, model: model, connection: connection, root: root, locks: locks
        )
        let leaves = Leaves()
        controller.onLeave = { leaves.count += 1 }

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 2400)
        window.traitOverrides.appRootEnvironment = root
        window.rootViewController = RouterNavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return Screen(controller: controller, model: model, locks: locks, leaves: leaves, window: window)
    }

    private func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews { if let hit = find(identifier, in: child) { return hit } }
        return nil
    }

    private func tap(_ identifier: String, on screen: Screen) async throws {
        var control: UIControl?
        for _ in 0..<50 {
            screen.window.layoutIfNeeded()
            control = find(identifier, in: screen.controller.view) as? UIControl
            if control != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(control, "\(identifier) was not on screen").sendActions(for: .touchUpInside)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<80 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func close(_ screen: Screen) {
        screen.window.isHidden = true
        screen.window.rootViewController = nil
    }

    // MARK: Guards

    @Test func aLockedWorkspaceRefusesDelete() async throws {
        let screen = try mount(locked: true, withAPIClient: false)
        defer { close(screen) }

        await screen.controller.deleteWorkspace()

        #expect(screen.model.error == nil, "a locked workspace must not reach the delete request")
        #expect(!screen.model.isDeleting)
        #expect(screen.leaves.count == 0)
    }

    /// Assumes the test host has App Lock off: `deleteWorkspace` still asks
    /// `AppLockService.shared` to authorize before the request.
    @Test func anUnlockedWorkspaceReachesTheDeleteRequest() async throws {
        let screen = try mount(locked: false, withAPIClient: false)
        defer { close(screen) }

        await screen.controller.deleteWorkspace()

        // The connection has no API client: the request fails offline,
        // which proves the guard lets an unlocked workspace through.
        #expect(screen.model.error == "Server is offline")
    }

    @Test func aLockedWorkspaceDoesNotOpenAPreparedSession() throws {
        let screen = try mount(locked: true)
        defer { close(screen) }

        screen.controller.openEditSession(
            WorkspaceSessionNavTarget(serverId: Self.serverId, sessionId: "s1", routeScope: .control)
        )

        #expect(screen.leaves.count == 0, "a locked workspace must stay put and open nothing")
    }

    @Test func anUnlockedWorkspaceLeavesToTheSession() throws {
        let screen = try mount(locked: false)
        defer { close(screen) }

        screen.controller.openEditSession(
            WorkspaceSessionNavTarget(serverId: Self.serverId, sessionId: "s1", routeScope: .control)
        )

        #expect(screen.leaves.count == 1)
    }

    // MARK: Relock

    /// Whether `view` is on screen: it and every ancestor are visible.
    private func isShown(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let view = current {
            if view.isHidden { return false }
            current = view.superview
        }
        return true
    }

    @Test func theOppiBarShowsOnAnUnlockedWorkspaceAndRelockHidesIt() async throws {
        let screen = try mount(locked: false)
        defer { close(screen) }
        screen.window.layoutIfNeeded()
        let input = try #require(find("chat.input", in: screen.controller.view), "the bar did not appear")
        #expect(isShown(input))
        #expect(find("workspace.edit.editWithOppi", in: screen.controller.view) == nil)

        screen.locks.lock(Self.scope)
        try await waitUntil { !isShown(input) }

        #expect(!isShown(input), "a relock must take the bar off screen")
    }

    @Test func aLockedWorkspaceNeverShowsTheOppiBar() throws {
        let screen = try mount(locked: true)
        defer { close(screen) }
        screen.window.layoutIfNeeded()

        let input = find("chat.input", in: screen.controller.view)
        #expect(input.map(isShown) != true, "the lock cover must not share the screen with the bar")
    }

    @Test func theOppiBarNeedsAnAPIClient() throws {
        let screen = try mount(locked: false, withAPIClient: false)
        defer { close(screen) }
        screen.window.layoutIfNeeded()

        let input = find("chat.input", in: screen.controller.view)
        #expect(input.map(isShown) != true, "an offline server has nothing to start a session on")
    }

    @Test func relockingClosesTheDeleteConfirmation() async throws {
        let screen = try mount(locked: false)
        defer { close(screen) }
        try await tap("workspace.edit.delete", on: screen)
        try await waitUntil { screen.controller.presentedViewController != nil }
        #expect(screen.controller.presentedViewController is UIAlertController, "Delete did not ask first")

        screen.locks.lock(Self.scope)
        try await waitUntil { screen.controller.presentedViewController == nil }

        #expect(screen.controller.presentedViewController == nil, "a relock must close the delete confirmation")
    }

    // MARK: The lock is the page's load

    private static let activeServerId = "sha256:workspace-settings-active"

    /// A server switch held inside its first `await`, so a test can end a load
    /// the coordinator is still working on.
    @MainActor
    private final class SwitchGate {
        private var started: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        private var hasStarted = false

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { started = $0 }
        }

        func suspend() async {
            hasStarted = true
            started?.resume()
            started = nil
            await withCheckedContinuation { release = $0 }
        }

        func open() {
            release?.resume()
            release = nil
        }
    }

    private struct Live {
        let screen: WorkspaceSettingsViewController
        let window: UIWindow
        /// The app's own refreshes once a server is connected: answered as an
        /// empty document, so a page that loads writes nothing the test must expect.
        let routes: TestURLProtocol.RouteScope
    }

    /// The app's own refreshes once a server is connected are not what these
    /// tests are about; this scope answers them as an empty document, and
    /// nothing is left for it to report. Install it before the root that asks.
    private func appRoutes() -> TestURLProtocol.RouteScope {
        TestURLProtocol.routeScope { request in
            try mockJSONResponse(json: "{}", for: request)
        }
    }

    /// The screen's own init: the workspace's server is switched to when the
    /// page loads, which is what the lock now drives. The window is tall enough
    /// to realize every row.
    private func mountLive(
        root: AppRootEnvironment,
        routes: TestURLProtocol.RouteScope,
        locks: ScopedLockService,
        workspace: Workspace,
        locked: Bool
    ) throws -> Live {
        if locked { locks.lock(Self.scope) }
        let controller = WorkspaceSettingsViewController(
            serverId: Self.serverId, workspace: workspace, root: root, locks: locks
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 2400)
        window.traitOverrides.appRootEnvironment = root
        window.rootViewController = RouterNavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return Live(screen: controller, window: window, routes: routes)
    }

    /// Waits for what the switch set going, then takes the window and the scope
    /// down: a request that outlived its handler would be nobody's answer.
    private func close(_ live: Live) async {
        // The page's load is the switch, and the work it starts hangs off it: the Pi
        // resources it reads for the server it switched to, and the bar's setup, which
        // refreshes the model catalog. Await both while this test's handler still
        // answers them, because `settle` only sees requests that reached URLSession: a
        // load still waiting its turn when the scope ends asks afterwards, and the double
        // records an issue that belongs to no test.
        _ = await waitForMainActorCondition(timeout: .seconds(5)) { !live.screen.isLoading }
        if let bar = live.screen.children.compactMap({ $0 as? GuidedControlComposerController }).first {
            await bar.model.appear()?.value
        }
        #expect(await live.routes.settle(), "a request outlived the test that answered it")
        hideWindow(live)
        live.routes.end()
    }

    private func hideWindow(_ live: Live) {
        live.window.isHidden = true
        live.window.rootViewController = nil
    }

    /// A locked workspace has nothing to list and no server of its own yet;
    /// unlocking it is what makes the switch and puts its rows on screen.
    @Test func unlockingSwitchesToTheWorkspacesServerAndShowsTheList() async throws {
        let locks = try makeLocks()
        let routes = appRoutes()
        let root = try await makeTestTwoServerRoot(firstId: Self.activeServerId, otherId: Self.serverId)
        let workspace = makeTestWorkspace(id: "w1", name: "oppi-dev")
        let locked = try mountLive(root: root, routes: routes, locks: locks, workspace: workspace, locked: true)
        defer { hideWindow(locked) }
        locked.window.layoutIfNeeded()

        #expect(locked.screen.shownItems.isEmpty, "a locked workspace lists nothing")
        #expect(
            locked.screen.children.contains { $0 is ScopedLockCoverViewController },
            "a locked workspace shows its cover"
        )
        // A switch that should not have started would land after the first pass,
        // not before it, so let everything the mount set going come back.
        #expect(await routes.settle(quiet: .milliseconds(200)), "a request outlived the mount")
        #expect(root.coordinator.activeServerId == Self.activeServerId, "nothing switched while locked")

        let unlocked = await locks.removeLock(Self.scope)
        #expect(unlocked)
        try await waitUntil { !locked.screen.shownItems.isEmpty }

        #expect(root.coordinator.activeServerId == Self.serverId, "unlocking must make the workspace's server active")
        #expect(locked.screen.shownItems.contains(.delete), "the list is there once the switch answers")
        #expect(!locked.screen.children.contains { $0 is ScopedLockCoverViewController }, "the cover goes with the lock")
        await close(locked)
    }

    /// A relock while the switch runs ends the page's load: it is not a failure,
    /// and the workspace stays behind its cover instead of a half-made server.
    @Test func relockingCancelsASwitchInFlight() async throws {
        let locks = try makeLocks()
        let routes = appRoutes()
        let pending = try #require(PairedServer(
            from: makeTestCredentials(host: "pending.test", fingerprint: Self.serverId), sortOrder: 1
        ))
        let active = try #require(PairedServer(
            from: makeTestCredentials(host: "active.test", fingerprint: Self.activeServerId), sortOrder: 0
        ))
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview([active, pending])
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        await coordinator.ensureTestConnectionReady(for: active).setAPIClientForTesting(
            makeTestURLProtocolClient(host: "active.test")
        )
        #expect(coordinator.restoreActiveServer(active.id))
        let root = makeTestAppRoot(coordinator: coordinator)
        let gate = SwitchGate()
        coordinator._initialLANEndpointForTesting = { _ in
            await gate.suspend()
            return nil
        }
        let workspace = makeTestWorkspace(id: "w1", name: "oppi-dev")
        let live = try mountLive(root: root, routes: routes, locks: locks, workspace: workspace, locked: false)
        defer { hideWindow(live) }

        // The page's server has no connection yet, so its load is a switch the
        // gate holds open.
        await gate.waitUntilStarted()
        #expect(live.screen.isLoading, "the switch is the page's load")
        #expect(live.screen.shownItems.isEmpty, "a switch in flight has no rows yet")

        locks.lock(Self.scope)
        try await waitUntil { !live.screen.isLoading }

        #expect(live.screen.loadFailure == nil, "a load the lock ended is not a failure")
        #expect(live.screen.shownItems.isEmpty, "a locked workspace lists nothing")
        #expect(live.screen.collectionView.isHidden, "the cover stands in place of the list")

        // The switch the lock ended is the coordinator's to finish: it must not
        // make the page's server the active one behind the cover.
        gate.open()
        try await Task.sleep(for: .milliseconds(400))
        #expect(
            root.coordinator.activeServerId == Self.activeServerId,
            "a switch the lock ended must not make its server active"
        )
        await close(live)
    }

    /// The page's load is the server switch, not a read: a pull would switch again
    /// and show a spinner that does nothing, so the page offers none.
    @Test func theWorkspaceSettingsListOffersNoPullToRefresh() async throws {
        let locks = try makeLocks()
        let routes = appRoutes()
        let root = try await makeTestTwoServerRoot(firstId: Self.activeServerId, otherId: Self.serverId)
        let workspace = makeTestWorkspace(id: "w1", name: "oppi-dev")
        let live = try mountLive(root: root, routes: routes, locks: locks, workspace: workspace, locked: false)
        defer { hideWindow(live) }

        #expect(
            live.screen.collectionView.refreshControl == nil,
            "a page whose load is a server switch offers no pull to refresh"
        )
        await close(live)
    }
}
