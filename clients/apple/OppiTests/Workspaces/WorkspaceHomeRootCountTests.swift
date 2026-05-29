import Testing
import Foundation
import SwiftUI
import UIKit
@testable import Oppi

/// Tests that WorkspaceHomeView's active/stopped counts
/// only include root sessions, not spawn_agent children.
///
/// The logic under test lives in WorkspaceHomeView's private helpers,
/// so we replicate the same filtering algorithm here and verify it
/// matches expectations.
@Suite("Workspace Home Root Session Counting")
@MainActor
struct WorkspaceHomeRootCountTests {

    // MARK: - Helpers (mirror WorkspaceHomeView logic)

    /// Reimplements WorkspaceHomeView.rootSessionsFor filtering.
    private func rootSessions(from sessions: [Session]) -> [Session] {
        let allIds = Set(sessions.map(\.id))
        return sessions.filter { session in
            guard let parentId = session.parentSessionId else { return true }
            return !allIds.contains(parentId)
        }
    }

    private func activeCount(from sessions: [Session]) -> Int {
        rootSessions(from: sessions).filter { $0.status != .stopped }.count
    }

    private func stoppedCount(from sessions: [Session]) -> Int {
        rootSessions(from: sessions).filter { $0.status == .stopped }.count
    }

    // MARK: - Tests

    @Test func allRootSessionsCounted() {
        let sessions = [
            makeTestSession(id: "r1", status: .ready),
            makeTestSession(id: "r2", status: .busy),
            makeTestSession(id: "r3", status: .stopped),
        ]

        #expect(activeCount(from: sessions) == 2)
        #expect(stoppedCount(from: sessions) == 1)
    }

    @Test func childSessionsExcludedFromCount() {
        var child1 = makeTestSession(id: "c1", status: .busy)
        child1.parentSessionId = "r1"
        var child2 = makeTestSession(id: "c2", status: .ready)
        child2.parentSessionId = "r1"

        let sessions = [
            makeTestSession(id: "r1", status: .ready),
            child1,
            child2,
        ]

        // Only the root counts, not the 2 children
        #expect(activeCount(from: sessions) == 1)
        #expect(stoppedCount(from: sessions) == 0)
    }

    @Test func stoppedChildrenExcludedFromStoppedCount() {
        var child = makeTestSession(id: "c1", status: .stopped)
        child.parentSessionId = "r1"

        let sessions = [
            makeTestSession(id: "r1", status: .stopped),
            child,
        ]

        // Only 1 stopped root, not 2
        #expect(activeCount(from: sessions) == 0)
        #expect(stoppedCount(from: sessions) == 1)
    }

    @Test func mixedRootsAndChildrenReflectsRealScenario() {
        // Scenario from the bug: 2 active roots + 4 active children = 6 total
        // Home view should show 2 active, not 6
        var c1 = makeTestSession(id: "c1", status: .busy)
        c1.parentSessionId = "r1"
        var c2 = makeTestSession(id: "c2", status: .busy)
        c2.parentSessionId = "r1"
        var c3 = makeTestSession(id: "c3", status: .ready)
        c3.parentSessionId = "r2"
        var c4 = makeTestSession(id: "c4", status: .ready)
        c4.parentSessionId = "r2"

        let sessions = [
            makeTestSession(id: "r1", status: .ready),
            makeTestSession(id: "r2", status: .ready),
            c1, c2, c3, c4,
        ]

        #expect(activeCount(from: sessions) == 2)
        #expect(stoppedCount(from: sessions) == 0)
    }

    @Test func orphanedChildBecomesRoot() {
        // Child whose parent is NOT in the session list (deleted or different workspace)
        var orphan = makeTestSession(id: "c1", status: .busy)
        orphan.parentSessionId = "deleted-parent"

        let sessions = [
            makeTestSession(id: "r1", status: .ready),
            orphan,
        ]

        // Orphan counts as a root since its parent isn't present
        #expect(activeCount(from: sessions) == 2)
    }

    @Test func deeplyNestedChildrenExcluded() {
        // Grandchild: r1 -> c1 -> gc1
        var child = makeTestSession(id: "c1", status: .busy)
        child.parentSessionId = "r1"
        var grandchild = makeTestSession(id: "gc1", status: .busy)
        grandchild.parentSessionId = "c1"

        let sessions = [
            makeTestSession(id: "r1", status: .ready),
            child,
            grandchild,
        ]

        // Only the root counts
        #expect(activeCount(from: sessions) == 1)
    }

    @Test func emptySessionList() {
        #expect(activeCount(from: []) == 0)
        #expect(stoppedCount(from: []) == 0)
    }

    @Test func allChildrenNoRoots() {
        // Edge case: all sessions are children of parents not in the list
        var c1 = makeTestSession(id: "c1", status: .busy)
        c1.parentSessionId = "external1"
        var c2 = makeTestSession(id: "c2", status: .ready)
        c2.parentSessionId = "external2"

        let sessions = [c1, c2]

        // Both are orphans (parents not in list), so they become roots
        #expect(activeCount(from: sessions) == 2)
    }

    // MARK: - Attention

    /// Reimplements the ask/permission portion of WorkspaceHomeView.hasAttention.
    /// Any root or child session with pending user input should flag the workspace.
    private func hasPendingInputAttention(
        from sessions: [Session],
        pendingSessionIds: Set<String>
    ) -> Bool {
        sessions.contains { pendingSessionIds.contains($0.id) }
    }

    /// Reimplements WorkspaceHomeView.hasAttention error-status check.
    /// Only root sessions with .error status trigger attention.
    private func hasErrorAttention(from sessions: [Session]) -> Bool {
        rootSessions(from: sessions).contains { $0.status == .error }
    }

    @Test func askRootTriggersAttention() {
        let sessions = [
            makeTestSession(id: "r1", status: .ready),
        ]
        #expect(hasPendingInputAttention(from: sessions, pendingSessionIds: ["r1"]) == true)
    }

    @Test func askChildTriggersAttention() {
        var child = makeTestSession(id: "c1", status: .ready)
        child.parentSessionId = "parent"

        let sessions = [
            makeTestSession(id: "parent", status: .ready),
            child,
        ]

        #expect(hasPendingInputAttention(from: sessions, pendingSessionIds: ["c1"]) == true)
    }

    @Test func errorRootTriggersAttention() {
        let sessions = [
            makeTestSession(id: "r1", status: .error),
        ]
        #expect(hasErrorAttention(from: sessions) == true)
    }

    @Test func errorChildOfStoppedParentDoesNotTriggerAttention() {
        // The exact bug: 4 error children of a stopped parent
        // were showing the attention "!" indicator on the workspace row
        var c1 = makeTestSession(id: "c1", status: .error)
        c1.parentSessionId = "parent"

        let sessions = [
            makeTestSession(id: "parent", status: .stopped),
            makeTestSession(id: "r1", status: .ready),
            c1,
        ]

        // The stopped parent is excluded from roots (it IS a root but stopped)
        // The error child is excluded because its parent is in the list
        #expect(hasErrorAttention(from: sessions) == false)
    }

    @Test func errorChildOfActiveParentDoesNotTriggerAttention() {
        var c1 = makeTestSession(id: "c1", status: .error)
        c1.parentSessionId = "parent"

        let sessions = [
            makeTestSession(id: "parent", status: .busy),
            c1,
        ]

        // Parent is active (busy), child is filtered out — only root checked
        #expect(hasErrorAttention(from: sessions) == false)
    }
}

@Suite("Workspace Home Preview Planner")
struct WorkspaceHomePreviewPlannerTests {
    @Test func fillsRemainingSlotsWithActiveYourTurnBeforeStoppedRows() {
        let rows = WorkspaceHomePreviewPlanner.activeRows(
            yourTurn: ["y1", "y2", "y3", "y4", "y5"],
            working: []
        )

        #expect(rows == ["y1", "y2", "y3", "y4", "y5"])
    }

    @Test func keepsWorkingRowsVisibleBeforeOverflowYourTurnRows() {
        let rows = WorkspaceHomePreviewPlanner.activeRows(
            yourTurn: ["y1", "y2", "y3", "y4", "y5"],
            working: ["w1", "w2"]
        )

        #expect(rows == ["y1", "y2", "y3", "w1", "w2"])
    }

    @Test func backfillsExtraYourTurnAfterWorkingRowsWhenSpaceRemains() {
        let rows = WorkspaceHomePreviewPlanner.activeRows(
            yourTurn: ["y1", "y2", "y3", "y4", "y5"],
            working: ["w1"]
        )

        #expect(rows == ["y1", "y2", "y3", "w1", "y4"])
    }
}

@Suite("Workspace Home Refresh", .serialized)
@MainActor
struct WorkspaceHomeRefreshTests {
    @Test func returningToWorkspaceTabRefreshesHome() async {
        let (coordinator, serverStore) = makeCoordinator()
        let navigation = AppNavigation()
        let counter = MessageCounter()
        coordinator._onRefreshAllServersForTesting = {
            Task { await counter.increment() }
        }

        let host = makeHost(
            coordinator: coordinator,
            serverStore: serverStore,
            navigation: navigation
        )
        defer { host.teardown() }

        let initialRefresh = await waitForTestCondition(timeoutMs: 500) {
            await counter.count() == 1
        }
        #expect(initialRefresh)

        navigation.selectedTab = .server
        host.pump()
        await Task.yield()

        navigation.selectedTab = .workspaces
        host.pump()

        let refreshedOnReturn = await waitForTestCondition(timeoutMs: 500) {
            await counter.count() == 2
        }
        #expect(refreshedOnReturn, "Expected WorkspaceHomeView to refresh when the Workspaces tab becomes active again")
    }

    @Test func poppingBackToWorkspaceHomeRefreshes() async {
        let (coordinator, serverStore) = makeCoordinator()
        let navigation = AppNavigation()
        navigation.selectedTab = .workspaces
        let counter = MessageCounter()
        coordinator._onRefreshAllServersForTesting = {
            Task { await counter.increment() }
        }

        let host = makeHost(
            coordinator: coordinator,
            serverStore: serverStore,
            navigation: navigation
        )
        defer { host.teardown() }

        let initialRefresh = await waitForTestCondition(timeoutMs: 500) {
            await counter.count() == 1
        }
        #expect(initialRefresh)

        navigation.workspacePath.append(
            WorkspaceNavTarget(
                serverId: "sha256:test-server",
                workspace: makeTestWorkspace(id: "workspace-1")
            )
        )
        host.pump()
        await Task.yield()

        navigation.workspacePath = NavigationPath()
        host.pump()

        let refreshedOnPop = await waitForTestCondition(timeoutMs: 500) {
            await counter.count() == 2
        }
        #expect(refreshedOnPop, "Expected WorkspaceHomeView to refresh when navigation returns to the home list")
    }

    private func makeCoordinator() -> (ConnectionCoordinator, ServerStore) {
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.pairedServerIdsKey)
        UserDefaults.standard.removeObject(forKey: SharedConstants.pairedServerIdsKey)
        KeychainService.deleteAllServers()

        let store = ServerStore()
        let coordinator = ConnectionCoordinator(serverStore: store)
        return (coordinator, store)
    }

    private func makeHost(
        coordinator: ConnectionCoordinator,
        serverStore: ServerStore,
        navigation: AppNavigation
    ) -> WorkspaceHomeHostHarness {
        let root = AnyView(
            NavigationStack {
                WorkspaceHomeView()
            }
            .environment(coordinator)
            .environment(serverStore)
            .environment(navigation)
        )

        let controller = UIHostingController(rootView: root)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return WorkspaceHomeHostHarness(controller: controller, window: window)
    }
}

@MainActor
private struct WorkspaceHomeHostHarness {
    let controller: UIHostingController<AnyView>
    let window: UIWindow

    func pump() {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    func teardown() {
        controller.rootView = AnyView(EmptyView())
        pump()
        window.isHidden = true
        window.rootViewController = nil
    }
}
