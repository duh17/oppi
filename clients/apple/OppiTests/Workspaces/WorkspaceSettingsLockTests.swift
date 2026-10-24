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
}
