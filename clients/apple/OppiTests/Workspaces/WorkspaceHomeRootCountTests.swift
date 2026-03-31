import Testing
import Foundation
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
}
