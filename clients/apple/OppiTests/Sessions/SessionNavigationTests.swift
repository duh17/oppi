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

    /// Mirrors WorkspaceDetailView stopped root filtering + search logic.
    private func visibleStoppedRootIds(
        in sessions: [Session],
        query: String? = nil
    ) -> [String] {
        let normalizedQuery = query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let hasQuery = !normalizedQuery.isEmpty

        func matches(_ session: Session) -> Bool {
            guard hasQuery else { return true }
            return FuzzyMatch.match(query: normalizedQuery, candidate: session.displayTitle) != nil
        }

        let allIds = Set(sessions.map(\.id))
        let stopped = sessions.filter { $0.status == .stopped }
        let roots = stopped.filter { session in
            guard let parentId = session.parentSessionId else { return true }
            return !allIds.contains(parentId)
        }

        let filtered = hasQuery
            ? roots.filter { root in
                if matches(root) { return true }
                return SessionTreeHelper.allDescendants(of: root.id, in: stopped)
                    .contains { matches($0) }
            }
            : roots

        return filtered.map(\.id).sorted()
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: 1 — Root session filtering
    // ──────────────────────────────────────────────────────────────

    @Test func roots_standaloneSessionsAreRoots() {
        let sessions = [
            makeSession(id: "a"),
            makeSession(id: "b"),
            makeSession(id: "c"),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 3)
    }

    @Test func roots_childWithExistingParentIsNotRoot() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child", parentId: "parent"),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 1)
        #expect(roots[0].id == "parent")
    }

    @Test func roots_orphanedChildBecomesRoot() {
        let sessions = [
            makeSession(id: "orphan", parentId: "deleted-parent"),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 1)
        #expect(roots[0].id == "orphan")
    }

    @Test func roots_mixedStandaloneParentChildOrphaned() {
        let sessions = [
            makeSession(id: "standalone", createdAt: baseTime),
            makeSession(id: "parent", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "child", parentId: "parent", createdAt: baseTime.addingTimeInterval(20)),
            makeSession(id: "orphan", parentId: "gone", createdAt: baseTime.addingTimeInterval(30)),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        let rootIds = Set(roots.map(\.id))
        #expect(rootIds.contains("standalone"))
        #expect(rootIds.contains("parent"))
        #expect(rootIds.contains("orphan"))
        #expect(!rootIds.contains("child"))
        #expect(roots.count == 3)
    }

    @Test func roots_detachedSessionsAlongsideChildren() {
        let sessions = [
            makeSession(id: "detached1", createdAt: baseTime),
            makeSession(id: "detached2", createdAt: baseTime.addingTimeInterval(5)),
            makeSession(id: "parent", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "child1", parentId: "parent", createdAt: baseTime.addingTimeInterval(20)),
            makeSession(id: "child2", parentId: "parent", createdAt: baseTime.addingTimeInterval(30)),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        let rootIds = Set(roots.map(\.id))
        #expect(roots.count == 3)
        #expect(rootIds.contains("detached1"))
        #expect(rootIds.contains("detached2"))
        #expect(rootIds.contains("parent"))
    }

    @Test func roots_emptyListReturnsEmpty() {
        let roots = SessionTreeHelper.rootSessions(from: [], allSessions: [])
        #expect(roots.isEmpty)
    }

    @Test func roots_multipleOrphanedChildrenAllBecomeRoots() {
        let sessions = [
            makeSession(id: "orphan1", parentId: "gone-a", createdAt: baseTime),
            makeSession(id: "orphan2", parentId: "gone-b", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "orphan3", parentId: "gone-c", createdAt: baseTime.addingTimeInterval(20)),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 3)
    }

    @Test func stoppedRoots_activeParentStoppedChildHidden() {
        // Stopped child with active parent should NOT appear as stopped root
        let sessions = [
            makeSession(id: "parent", status: .busy, name: "Active Parent"),
            makeSession(id: "child", parentId: "parent", status: .stopped, name: "Stopped Child"),
        ]
        #expect(visibleStoppedRootIds(in: sessions) == [])
    }

    @Test func stoppedRoots_searchSurfacesStoppedParentWhenChildMatches() {
        let sessions = [
            makeSession(id: "parent", status: .stopped, name: "Parent Session"),
            makeSession(id: "child", parentId: "parent", status: .stopped, name: "Compile regression fix"),
        ]
        #expect(visibleStoppedRootIds(in: sessions, query: "compile") == ["parent"])
    }

    @Test func stoppedRoots_bothStoppedParentShownChildHidden() {
        // Both stopped: only parent shows in stopped list
        let sessions = [
            makeSession(id: "parent", status: .stopped),
            makeSession(id: "child", parentId: "parent", status: .stopped),
        ]
        #expect(visibleStoppedRootIds(in: sessions) == ["parent"])
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
        let sorted = SessionTreeHelper.sortedChildSessions(of: "parent", in: sessions)
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

    @Test func children_selfReferentialEdgeCase() {
        let sessions = [
            makeSession(id: "self-ref", parentId: "self-ref"),
            makeSession(id: "normal"),
        ]
        // Raw child lookup includes self-ref (parentSessionId == id)
        let children = SessionTreeHelper.childSessions(of: "self-ref", in: sessions)
        #expect(children.count == 1)
        #expect(children[0].id == "self-ref")
        // allDescendants handles this safely (pre-visits parentId)
        let desc = SessionTreeHelper.allDescendants(of: "self-ref", in: sessions)
        #expect(desc.isEmpty)
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
        #expect(agg == 12)
    }

    @Test func permissions_grandchildNotIncluded() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let pending = ["root": 0, "child": 1, "grandchild": 5]
        let agg = aggregatePendingCount(sessionId: "root", sessions: sessions, pendingCounts: pending)
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
        let counts = SessionTreeHelper.descendantStatusCounts(of: "parent", in: sessions)
        #expect(counts.working == 3)
        #expect(counts.ready == 0)
        #expect(counts.stopped == 0)
        #expect(counts.error == 0)
        #expect(counts.total == 3)
    }

    @Test func statusCounts_allChildrenStopped() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .stopped),
            makeSession(id: "c2", parentId: "parent", status: .stopped),
        ]
        let counts = SessionTreeHelper.descendantStatusCounts(of: "parent", in: sessions)
        #expect(counts.working == 0)
        #expect(counts.stopped == 2)
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
        let counts = SessionTreeHelper.descendantStatusCounts(of: "parent", in: sessions)
        #expect(counts.working == 1)
        #expect(counts.stopped == 1)
        #expect(counts.error == 2)
        #expect(counts.total == 4)
    }

    @Test func statusCounts_singleChild() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "only-child", parentId: "parent", status: .starting),
        ]
        let counts = SessionTreeHelper.descendantStatusCounts(of: "parent", in: sessions)
        #expect(counts.working == 1)
        #expect(counts.ready == 0)
        #expect(counts.stopped == 0)
        #expect(counts.total == 1)
    }

    @Test func statusCounts_stoppingCountsAsWorking() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .stopping),
        ]
        let counts = SessionTreeHelper.descendantStatusCounts(of: "parent", in: sessions)
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
        #expect(total == 6.00)
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
        #expect(unnamedParent.displayTitle == "Session p2")
    }

    @Test func navigation_breadcrumbDisplayTitleFromFirstMessage() {
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

    @Test func navigation_descendantsPreserveParentChain() {
        // Navigating parent → child → grandchild traceable via parentSessionId
        let sessions = [
            makeSession(id: "root", createdAt: baseTime),
            makeSession(id: "agent-1", parentId: "root", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "agent-2", parentId: "root", createdAt: baseTime.addingTimeInterval(20)),
            makeSession(id: "sub-agent", parentId: "agent-1", createdAt: baseTime.addingTimeInterval(30)),
        ]
        let roots = SessionTreeHelper.rootSessions(from: sessions, allSessions: sessions)
        #expect(roots.count == 1)
        #expect(roots[0].id == "root")

        let rootChildren = SessionTreeHelper.sortedChildSessions(of: "root", in: sessions)
        #expect(rootChildren.map(\.id) == ["agent-1", "agent-2"])

        let agent1Children = SessionTreeHelper.sortedChildSessions(of: "agent-1", in: sessions)
        #expect(agent1Children.count == 1)
        #expect(agent1Children[0].id == "sub-agent")

        // Trace back: sub-agent → agent-1 → root
        let subAgent = agent1Children[0]
        #expect(subAgent.parentSessionId == "agent-1")
        let agent1 = sessions.first { $0.id == subAgent.parentSessionId }
        #expect(agent1?.parentSessionId == "root")
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: 7 — Render window gate consistency
    // ──────────────────────────────────────────────────────────────

    @Test func renderWindow_hiddenCountZeroWhenSessionMismatch() {
        let parentItems = 233
        let childSessionId = "child-session"
        let reducerActiveSessionId = "parent-session"
        let renderWindow = TimelineRenderWindowPolicy.standardWindow

        let gateMatches = reducerActiveSessionId == childSessionId
        let visibleCount = gateMatches ? min(parentItems, renderWindow) : 0
        let hiddenCount = gateMatches ? max(0, parentItems - visibleCount) : 0

        #expect(visibleCount == 0)
        #expect(hiddenCount == 0, "hiddenCount must be 0 when session ID doesn't match")
    }

    @Test func renderWindow_normalCountsWhenSessionMatches() {
        let totalItems = 233
        let sessionId = "current-session"
        let reducerActiveSessionId = "current-session"
        let renderWindow = TimelineRenderWindowPolicy.standardWindow

        let gateMatches = reducerActiveSessionId == sessionId
        let visibleCount = gateMatches ? min(totalItems, renderWindow) : 0
        let hiddenCount = gateMatches ? max(0, totalItems - visibleCount) : 0

        #expect(visibleCount == 80)
        #expect(hiddenCount == 153)
    }

    @Test func renderWindow_syncedWindowNeverExceedsTotalItems() {
        let totalItems = 50
        let currentWindow = 80

        let synced = TimelineRenderWindowPolicy.syncedWindow(
            currentWindow: currentWindow,
            totalItems: totalItems
        )

        #expect(synced <= totalItems)
        #expect(synced == 50)
    }
}
