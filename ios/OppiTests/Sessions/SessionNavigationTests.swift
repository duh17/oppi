import Foundation
import Testing
@testable import Oppi

// MARK: - Navigation helpers (tested below)

/// Compute aggregate pending permission count for a session and all its direct children.
/// Grandchild permissions are NOT included — only one level deep.
private func aggregatePendingCount(
    sessionId: String,
    sessions: [Session],
    pendingCounts: [String: Int]
) -> Int {
    let own = pendingCounts[sessionId] ?? 0
    let childIds = sessions.filter { $0.parentSessionId == sessionId }.map(\.id)
    let childPending = childIds.reduce(0) { $0 + (pendingCounts[$1] ?? 0) }
    return own + childPending
}

/// Compute aggregate cost for a session and ALL descendants (recursive).
private func aggregateCost(
    sessionId: String,
    sessions: [Session]
) -> Double {
    guard let session = sessions.first(where: { $0.id == sessionId }) else { return 0.0 }
    let childCosts = sessions
        .filter { $0.parentSessionId == sessionId }
        .reduce(0.0) { $0 + aggregateCost(sessionId: $1.id, sessions: sessions) }
    return session.cost + childCosts
}

@Suite("Session Navigation")
struct SessionNavigationTests {

    // MARK: - Test helpers

    private func makeSession(
        id: String,
        parentId: String? = nil,
        status: SessionStatus = .busy,
        name: String? = nil,
        cost: Double = 0.0,
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

    private var baseTime: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    // ──────────────────────────────────────────────────────────────
    // MARK: 1 — Root session filtering
    // ──────────────────────────────────────────────────────────────

    @Test func roots_standaloneSessionsAreRoots() {
        let sessions = [
            makeSession(id: "a"),
            makeSession(id: "b"),
            makeSession(id: "c"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 3)
        #expect(tree.allSatisfy { $0.depth == 0 })
    }

    @Test func roots_childWithExistingParentIsNotRoot() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child", parentId: "parent"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 1)
        #expect(tree[0].session.id == "parent")
    }

    @Test func roots_orphanedChildBecomesRoot() {
        let sessions = [
            makeSession(id: "orphan", parentId: "deleted-parent"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 1)
        #expect(tree[0].session.id == "orphan")
        #expect(tree[0].depth == 0)
    }

    @Test func roots_mixedStandaloneParentChildOrphaned() {
        let sessions = [
            makeSession(id: "standalone", createdAt: baseTime),
            makeSession(id: "parent", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "child", parentId: "parent", createdAt: baseTime.addingTimeInterval(20)),
            makeSession(id: "orphan", parentId: "gone", createdAt: baseTime.addingTimeInterval(30)),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let rootIds = tree.map(\.session.id)
        #expect(rootIds.contains("standalone"))
        #expect(rootIds.contains("parent"))
        #expect(rootIds.contains("orphan"))
        #expect(!rootIds.contains("child"))
        #expect(tree.count == 3)
    }

    @Test func roots_detachedSessionsAlongsideChildren() {
        // "Detached" = no parentSessionId, exists in same list as parent-child pairs
        let sessions = [
            makeSession(id: "detached1", createdAt: baseTime),
            makeSession(id: "detached2", createdAt: baseTime.addingTimeInterval(5)),
            makeSession(id: "parent", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "child1", parentId: "parent", createdAt: baseTime.addingTimeInterval(20)),
            makeSession(id: "child2", parentId: "parent", createdAt: baseTime.addingTimeInterval(30)),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let rootIds = tree.map(\.session.id)
        #expect(tree.count == 3)
        #expect(rootIds.contains("detached1"))
        #expect(rootIds.contains("detached2"))
        #expect(rootIds.contains("parent"))
    }

    @Test func roots_emptyListReturnsEmpty() {
        let tree = SessionTreeHelper.buildTree(from: [])
        #expect(tree.isEmpty)
    }

    @Test func roots_multipleOrphanedChildrenAllBecomeRoots() {
        let sessions = [
            makeSession(id: "orphan1", parentId: "gone-a", createdAt: baseTime),
            makeSession(id: "orphan2", parentId: "gone-b", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "orphan3", parentId: "gone-c", createdAt: baseTime.addingTimeInterval(20)),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 3)
        #expect(tree.allSatisfy { $0.children.isEmpty })
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: 2 — Child session lookup
    // ──────────────────────────────────────────────────────────────

    @Test func children_findsAllDirectChildren() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child1", parentId: "parent"),
            makeSession(id: "child2", parentId: "parent"),
            makeSession(id: "child3", parentId: "parent"),
            makeSession(id: "unrelated"),
        ]
        let children = SessionTreeHelper.childSessions(of: "parent", in: sessions)
        #expect(children.count == 3)
        #expect(children.allSatisfy { $0.parentSessionId == "parent" })
    }

    @Test func children_sortedByCreatedAtAscending() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "third", parentId: "parent", createdAt: baseTime.addingTimeInterval(30)),
            makeSession(id: "first", parentId: "parent", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "second", parentId: "parent", createdAt: baseTime.addingTimeInterval(20)),
        ]
        // ChatView pattern: filter + sort
        let sorted = sessions
            .filter { $0.parentSessionId == "parent" }
            .sorted { $0.createdAt < $1.createdAt }
        #expect(sorted.map(\.id) == ["first", "second", "third"])
    }

    @Test func children_excludesGrandchildren() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let children = SessionTreeHelper.childSessions(of: "root", in: sessions)
        #expect(children.count == 1)
        #expect(children[0].id == "child")
        // grandchild belongs to "child", not "root"
        let grandchildren = SessionTreeHelper.childSessions(of: "child", in: sessions)
        #expect(grandchildren.count == 1)
        #expect(grandchildren[0].id == "grandchild")
    }

    @Test func children_parentWithNoChildrenReturnsEmpty() {
        let sessions = [
            makeSession(id: "lonely"),
            makeSession(id: "other"),
        ]
        let children = SessionTreeHelper.childSessions(of: "lonely", in: sessions)
        #expect(children.isEmpty)
    }

    @Test func children_multipleParentsNoCrossContamination() {
        let sessions = [
            makeSession(id: "parent-a"),
            makeSession(id: "parent-b"),
            makeSession(id: "child-a1", parentId: "parent-a"),
            makeSession(id: "child-a2", parentId: "parent-a"),
            makeSession(id: "child-b1", parentId: "parent-b"),
        ]
        let childrenA = SessionTreeHelper.childSessions(of: "parent-a", in: sessions)
        let childrenB = SessionTreeHelper.childSessions(of: "parent-b", in: sessions)
        #expect(childrenA.count == 2)
        #expect(childrenB.count == 1)
        #expect(childrenA.allSatisfy { $0.parentSessionId == "parent-a" })
        #expect(childrenB.allSatisfy { $0.parentSessionId == "parent-b" })
    }

    @Test func children_selfReferentialNotOwnChild() {
        let sessions = [
            makeSession(id: "self-ref", parentId: "self-ref"),
            makeSession(id: "normal"),
        ]
        // The filter pattern returns self-ref as its own child because parentSessionId == id.
        // This is a known data integrity edge case.
        let children = SessionTreeHelper.childSessions(of: "self-ref", in: sessions)
        // self-ref's parentSessionId is "self-ref", so filter includes it.
        // buildTree handles this safely (filters it out), but raw lookup does not.
        #expect(children.count == 1)
        #expect(children[0].id == "self-ref")
        // buildTree is the safe path — self-referential session is silently dropped
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let normalNode = tree.first { $0.session.id == "normal" }
        #expect(normalNode != nil)
        // self-ref should not appear as a root or as anyone's child in the tree
        #expect(tree.count == 1)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: 3 — Permission aggregation
    // ──────────────────────────────────────────────────────────────

    @Test func permissions_parentZeroChildTwo() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child", parentId: "parent"),
        ]
        let pending = ["parent": 0, "child": 2]
        let agg = aggregatePendingCount(sessionId: "parent", sessions: sessions, pendingCounts: pending)
        #expect(agg == 2)
    }

    @Test func permissions_parentOneChildTwo() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child", parentId: "parent"),
        ]
        let pending = ["parent": 1, "child": 2]
        let agg = aggregatePendingCount(sessionId: "parent", sessions: sessions, pendingCounts: pending)
        #expect(agg == 3)
    }

    @Test func permissions_parentThreeNoChildren() {
        let sessions = [
            makeSession(id: "parent"),
        ]
        let pending = ["parent": 3]
        let agg = aggregatePendingCount(sessionId: "parent", sessions: sessions, pendingCounts: pending)
        #expect(agg == 3)
    }

    @Test func permissions_multipleChildrenVaryingCounts() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent"),
            makeSession(id: "c2", parentId: "parent"),
            makeSession(id: "c3", parentId: "parent"),
        ]
        let pending = ["parent": 1, "c1": 4, "c2": 0, "c3": 7]
        let agg = aggregatePendingCount(sessionId: "parent", sessions: sessions, pendingCounts: pending)
        #expect(agg == 12) // 1 + 4 + 0 + 7
    }

    @Test func permissions_grandchildNotIncluded() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let pending = ["root": 0, "child": 1, "grandchild": 5]
        let agg = aggregatePendingCount(sessionId: "root", sessions: sessions, pendingCounts: pending)
        // Only root(0) + child(1) = 1. Grandchild is excluded.
        #expect(agg == 1)
    }

    @Test func permissions_noPendingForAnyone() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child", parentId: "parent"),
        ]
        let pending: [String: Int] = [:]
        let agg = aggregatePendingCount(sessionId: "parent", sessions: sessions, pendingCounts: pending)
        #expect(agg == 0)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: 4 — Child status aggregation
    // ──────────────────────────────────────────────────────────────

    @Test func statusCounts_allChildrenBusy() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .busy),
            makeSession(id: "c2", parentId: "parent", status: .busy),
            makeSession(id: "c3", parentId: "parent", status: .busy),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let counts = SessionTreeHelper.childStatusCounts(tree[0])
        #expect(counts.working == 3)
        #expect(counts.done == 0)
        #expect(counts.error == 0)
        #expect(counts.total == 3)
    }

    @Test func statusCounts_allChildrenStopped() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .stopped),
            makeSession(id: "c2", parentId: "parent", status: .stopped),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let counts = SessionTreeHelper.childStatusCounts(tree[0])
        #expect(counts.working == 0)
        #expect(counts.done == 2)
        #expect(counts.error == 0)
        #expect(counts.total == 2)
    }

    @Test func statusCounts_mixedWithErrors() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .busy),
            makeSession(id: "c2", parentId: "parent", status: .error),
            makeSession(id: "c3", parentId: "parent", status: .stopped),
            makeSession(id: "c4", parentId: "parent", status: .error),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let counts = SessionTreeHelper.childStatusCounts(tree[0])
        #expect(counts.working == 1)
        #expect(counts.done == 1)
        #expect(counts.error == 2)
        #expect(counts.total == 4)
    }

    @Test func statusCounts_singleChild() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "only-child", parentId: "parent", status: .starting),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let counts = SessionTreeHelper.childStatusCounts(tree[0])
        #expect(counts.working == 1)
        #expect(counts.done == 0)
        #expect(counts.total == 1)
    }

    @Test func statusCounts_stoppingCountsAsWorking() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .stopping),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let counts = SessionTreeHelper.childStatusCounts(tree[0])
        #expect(counts.working == 1)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: 5 — Cost aggregation
    // ──────────────────────────────────────────────────────────────

    @Test func cost_parentPlusAllChildren() {
        let sessions = [
            makeSession(id: "parent", cost: 1.50),
            makeSession(id: "c1", parentId: "parent", cost: 0.25),
            makeSession(id: "c2", parentId: "parent", cost: 0.75),
        ]
        let total = aggregateCost(sessionId: "parent", sessions: sessions)
        #expect(total == 2.50)
    }

    @Test func cost_childrenWithZeroCost() {
        let sessions = [
            makeSession(id: "parent", cost: 3.00),
            makeSession(id: "c1", parentId: "parent", cost: 0.0),
            makeSession(id: "c2", parentId: "parent", cost: 0.0),
        ]
        let total = aggregateCost(sessionId: "parent", sessions: sessions)
        #expect(total == 3.00)
    }

    @Test func cost_recursiveIncludesGrandchildren() {
        let sessions = [
            makeSession(id: "root", cost: 1.00),
            makeSession(id: "child", parentId: "root", cost: 2.00),
            makeSession(id: "grandchild", parentId: "child", cost: 3.00),
        ]
        let total = aggregateCost(sessionId: "root", sessions: sessions)
        #expect(total == 6.00) // 1 + 2 + 3
    }

    @Test func cost_sessionWithNoCostAndNoChildren() {
        let sessions = [
            makeSession(id: "bare", cost: 0.0),
        ]
        let total = aggregateCost(sessionId: "bare", sessions: sessions)
        #expect(total == 0.0)
    }

    @Test func cost_missingSessionReturnsZero() {
        let sessions = [
            makeSession(id: "exists", cost: 5.00),
        ]
        let total = aggregateCost(sessionId: "no-such-id", sessions: sessions)
        #expect(total == 0.0)
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: 6 — Navigation data integrity
    // ──────────────────────────────────────────────────────────────

    @Test func navigation_childSessionRouteConstruction() {
        // ChildSessionRoute in ChatView is just { id: String }.
        // Verify a child session's id is sufficient to construct the route.
        let child = makeSession(id: "child-abc", parentId: "parent-xyz")
        let routeId = child.id
        #expect(routeId == "child-abc")
        #expect(!routeId.isEmpty)
    }

    @Test func navigation_parentLookupFromChild() {
        let sessions = [
            makeSession(id: "parent-1"),
            makeSession(id: "parent-2"),
            makeSession(id: "child", parentId: "parent-1"),
        ]
        let child = sessions.first { $0.id == "child" }!
        let parent = sessions.first { $0.id == child.parentSessionId }
        #expect(parent != nil)
        #expect(parent?.id == "parent-1")
    }

    @Test func navigation_parentLookupReturnsNilForOrphan() {
        let sessions = [
            makeSession(id: "orphan", parentId: "deleted"),
        ]
        let orphan = sessions.first { $0.id == "orphan" }!
        let parent = sessions.first { $0.id == orphan.parentSessionId }
        #expect(parent == nil)
    }

    @Test func navigation_breadcrumbDisplayTitle() {
        let parent = makeSession(id: "p1", name: "Refactor auth module")
        #expect(parent.displayTitle == "Refactor auth module")

        let unnamedParent = makeSession(id: "p2", name: nil)
        // No name, no firstMessage → falls back to "Session <prefix>"
        #expect(unnamedParent.displayTitle == "Session p2")
    }

    @Test func navigation_breadcrumbDisplayTitleFromFirstMessage() {
        // Session with no explicit name but a firstMessage
        // Must construct directly to avoid makeSession's default name
        var session = Session(
            id: "fm1",
            workspaceId: "ws1",
            workspaceName: "Test",
            name: nil,
            status: .busy,
            createdAt: Date(),
            lastActivity: Date(),
            model: "test/model",
            messageCount: 5,
            tokens: TokenUsage(input: 100, output: 50),
            cost: 0.0
        )
        session.firstMessage = "Help me fix the login bug"
        #expect(session.displayTitle == "Help me fix the login bug")
    }

    @Test func navigation_treePreservesParentChildRelationshipForNavigation() {
        // After buildTree, navigating parent → child → grandchild should be traceable
        let sessions = [
            makeSession(id: "root", createdAt: baseTime),
            makeSession(id: "agent-1", parentId: "root", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "agent-2", parentId: "root", createdAt: baseTime.addingTimeInterval(20)),
            makeSession(id: "sub-agent", parentId: "agent-1", createdAt: baseTime.addingTimeInterval(30)),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 1)

        // Root → agent-1, agent-2
        let root = tree[0]
        #expect(root.children.count == 2)
        #expect(root.children[0].session.id == "agent-1")
        #expect(root.children[1].session.id == "agent-2")

        // agent-1 → sub-agent
        let agent1 = root.children[0]
        #expect(agent1.children.count == 1)
        #expect(agent1.children[0].session.id == "sub-agent")

        // Verify we can trace back: sub-agent's parentSessionId → agent-1
        let subAgent = agent1.children[0]
        #expect(subAgent.session.parentSessionId == "agent-1")
        // And agent-1's parentSessionId → root
        #expect(agent1.session.parentSessionId == "root")
    }
}
