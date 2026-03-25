import Foundation
import Testing
@testable import Oppi

@Suite("SessionTreeHelper")
struct SessionTreeHelperTests {

    // MARK: - Test helpers

    private func makeSession(
        id: String,
        parentId: String? = nil,
        status: SessionStatus = .busy,
        name: String? = nil,
        cost: Double = 0.10,
        createdAt: Date = Date()
    ) -> Session {
        Session(
            id: id,
            workspaceId: "ws1",
            workspaceName: "Test",
            name: name ?? "Session \(id)",
            status: status,
            createdAt: createdAt,
            lastActivity: Date(),
            model: "test/model",
            messageCount: 5,
            tokens: TokenUsage(input: 100, output: 50),
            cost: cost,
            parentSessionId: parentId
        )
    }

    // MARK: - rootSessions

    @Test func rootSessions_standaloneSessionsAreRoots() {
        let sessions = [
            makeSession(id: "a"),
            makeSession(id: "b"),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 2)
    }

    @Test func rootSessions_childWithExistingParentExcluded() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child", parentId: "parent"),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 1)
        #expect(roots[0].id == "parent")
    }

    @Test func rootSessions_orphanedChildIsRoot() {
        let sessions = [
            makeSession(id: "child", parentId: "missing-parent"),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 1)
        #expect(roots[0].id == "child")
    }

    @Test func rootSessions_mixedStandaloneAndTree() {
        let sessions = [
            makeSession(id: "standalone"),
            makeSession(id: "parent"),
            makeSession(id: "child", parentId: "parent"),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 2)
        let rootIds = Set(roots.map(\.id))
        #expect(rootIds.contains("standalone"))
        #expect(rootIds.contains("parent"))
        #expect(!rootIds.contains("child"))
    }

    @Test func rootSessions_stoppedChildWithActiveParent() {
        let all = [
            makeSession(id: "parent", status: .busy),
            makeSession(id: "child", parentId: "parent", status: .stopped),
            makeSession(id: "standalone", status: .stopped),
        ]
        let stopped = all.filter { $0.status == .stopped }
        let roots = SessionTreeHelper.rootSessions(from: stopped, allSessions: all)
        #expect(roots.count == 1)
        #expect(roots[0].id == "standalone")
    }

    @Test func rootSessions_selfReferentialExcluded() {
        let sessions = [
            makeSession(id: "self-ref", parentId: "self-ref"),
            makeSession(id: "normal"),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 1)
        #expect(roots[0].id == "normal")
    }

    @Test func rootSessions_circularReferencesExcluded() {
        let sessions = [
            makeSession(id: "a", parentId: "b"),
            makeSession(id: "b", parentId: "a"),
            makeSession(id: "normal"),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 1)
        #expect(roots[0].id == "normal")
    }

    @Test func rootSessions_multipleOrphansAllRoots() {
        let sessions = [
            makeSession(id: "orphan1", parentId: "gone-a"),
            makeSession(id: "orphan2", parentId: "gone-b"),
            makeSession(id: "orphan3", parentId: "gone-c"),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 3)
    }

    @Test func rootSessions_emptyList() {
        let roots = SessionTreeHelper.rootSessions(from: [], allSessions: [])
        #expect(roots.isEmpty)
    }

    // MARK: - childSessions

    @Test func childSessions_findsDirectChildren() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child1", parentId: "parent"),
            makeSession(id: "child2", parentId: "parent"),
            makeSession(id: "other"),
        ]
        let children = SessionTreeHelper.childSessions(of: "parent", in: sessions)
        #expect(children.count == 2)
        #expect(children.allSatisfy { $0.parentSessionId == "parent" })
    }

    @Test func childSessions_excludesGrandchildren() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child", parentId: "parent"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let children = SessionTreeHelper.childSessions(of: "parent", in: sessions)
        #expect(children.count == 1)
        #expect(children[0].id == "child")
    }

    // MARK: - sortedChildSessions

    @Test func sortedChildSessions_orderedByCreatedAt() {
        let baseTime = Date()
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "third", parentId: "parent", createdAt: baseTime.addingTimeInterval(30)),
            makeSession(id: "first", parentId: "parent", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "second", parentId: "parent", createdAt: baseTime.addingTimeInterval(20)),
        ]
        let sorted = SessionTreeHelper.sortedChildSessions(of: "parent", in: sessions)
        #expect(sorted.map(\.id) == ["first", "second", "third"])
    }

    // MARK: - allDescendants

    @Test func allDescendants_directChildren() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent"),
            makeSession(id: "c2", parentId: "parent"),
            makeSession(id: "other"),
        ]
        let desc = SessionTreeHelper.allDescendants(of: "parent", in: sessions)
        #expect(desc.count == 2)
        #expect(Set(desc.map(\.id)) == ["c1", "c2"])
    }

    @Test func allDescendants_includesGrandchildren() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let desc = SessionTreeHelper.allDescendants(of: "root", in: sessions)
        #expect(desc.count == 2)
        #expect(Set(desc.map(\.id)) == ["child", "grandchild"])
    }

    @Test func allDescendants_noChildren() {
        let sessions = [
            makeSession(id: "lonely"),
            makeSession(id: "other"),
        ]
        let desc = SessionTreeHelper.allDescendants(of: "lonely", in: sessions)
        #expect(desc.isEmpty)
    }

    @Test func allDescendants_circularReferencesSafe() {
        let sessions = [
            makeSession(id: "a", parentId: "b"),
            makeSession(id: "b", parentId: "a"),
        ]
        // Should not hang. "a" is the starting parent, so "b" (child of "a") is found.
        // Then "a" (child of "b") is already visited → stops.
        let desc = SessionTreeHelper.allDescendants(of: "a", in: sessions)
        #expect(desc.count == 1)
        #expect(desc[0].id == "b")
    }

    @Test func allDescendants_selfReferentialSafe() {
        let sessions = [
            makeSession(id: "self-ref", parentId: "self-ref"),
        ]
        // parentId == id, but id is pre-visited → empty
        let desc = SessionTreeHelper.allDescendants(of: "self-ref", in: sessions)
        #expect(desc.isEmpty)
    }

    @Test func allDescendants_multipleIndependentTrees() {
        let sessions = [
            makeSession(id: "root1"),
            makeSession(id: "c1a", parentId: "root1"),
            makeSession(id: "c1b", parentId: "root1"),
            makeSession(id: "root2"),
            makeSession(id: "c2a", parentId: "root2"),
        ]
        let desc1 = SessionTreeHelper.allDescendants(of: "root1", in: sessions)
        let desc2 = SessionTreeHelper.allDescendants(of: "root2", in: sessions)
        #expect(desc1.count == 2)
        #expect(desc2.count == 1)
        // No cross-contamination
        #expect(desc1.allSatisfy { $0.parentSessionId == "root1" })
        #expect(desc2.allSatisfy { $0.parentSessionId == "root2" })
    }

    // MARK: - descendantCount

    @Test func descendantCount_recursive() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        #expect(SessionTreeHelper.descendantCount(of: "root", in: sessions) == 2)
    }

    // MARK: - descendantStatusCounts

    @Test func descendantStatusCounts_mixed() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .busy),
            makeSession(id: "c2", parentId: "parent", status: .stopped),
            makeSession(id: "c3", parentId: "parent", status: .error),
        ]
        let counts = SessionTreeHelper.descendantStatusCounts(of: "parent", in: sessions)
        #expect(counts.working == 1)
        #expect(counts.done == 1)
        #expect(counts.error == 1)
        #expect(counts.total == 3)
    }

    @Test func descendantStatusCounts_includesGrandchildren() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root", status: .busy),
            makeSession(id: "grandchild", parentId: "child", status: .error),
        ]
        let counts = SessionTreeHelper.descendantStatusCounts(of: "root", in: sessions)
        #expect(counts.working == 1)
        #expect(counts.error == 1)
        #expect(counts.total == 2)
    }

    @Test func descendantStatusCounts_readyIsDone() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .ready),
        ]
        let counts = SessionTreeHelper.descendantStatusCounts(of: "parent", in: sessions)
        #expect(counts.done == 1)
    }

    @Test func descendantStatusCounts_startingIsWorking() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .starting),
        ]
        let counts = SessionTreeHelper.descendantStatusCounts(of: "parent", in: sessions)
        #expect(counts.working == 1)
    }

    @Test func descendantStatusCounts_stoppingIsWorking() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .stopping),
        ]
        let counts = SessionTreeHelper.descendantStatusCounts(of: "parent", in: sessions)
        #expect(counts.working == 1)
    }

    // MARK: - descendantCost

    @Test func descendantCost_recursiveSum() {
        let sessions = [
            makeSession(id: "root", cost: 1.00),
            makeSession(id: "child", parentId: "root", cost: 2.00),
            makeSession(id: "grandchild", parentId: "child", cost: 3.00),
        ]
        #expect(SessionTreeHelper.descendantCost(of: "root", in: sessions) == 6.00)
    }

    @Test func descendantCost_noChildren() {
        let sessions = [
            makeSession(id: "lonely", cost: 5.00),
        ]
        #expect(SessionTreeHelper.descendantCost(of: "lonely", in: sessions) == 5.00)
    }

    @Test func descendantCost_missingSession() {
        let sessions = [
            makeSession(id: "exists", cost: 5.00),
        ]
        #expect(SessionTreeHelper.descendantCost(of: "no-such-id", in: sessions) == 0.0)
    }

    // MARK: - aggregatePendingCount

    @Test func aggregatePendingCount_includesDirectChildrenOnly() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let pending: [String: Int] = ["root": 1, "child": 2, "grandchild": 5]
        let count = SessionTreeHelper.aggregatePendingCount(
            of: "root", in: sessions,
            pendingForSession: { pending[$0] ?? 0 }
        )
        // root(1) + child(2) = 3. Grandchild excluded.
        #expect(count == 3)
    }

    @Test func aggregatePendingCount_noChildren() {
        let sessions = [
            makeSession(id: "solo"),
        ]
        let count = SessionTreeHelper.aggregatePendingCount(
            of: "solo", in: sessions,
            pendingForSession: { _ in 3 }
        )
        #expect(count == 3)
    }
}
