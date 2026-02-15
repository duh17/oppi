import Testing
import Foundation
@testable import Oppi

/// Tests confirming bugs found in the behavioral audit, and verifying fixes.
///
/// Bug 3: permissionCancelled leaves stale card in timeline
/// Bug 4: No client-side permission timeout sweep
/// Bug 5: Optimistic user message not retracted on failed send
@Suite("Bug Bash")
struct BugBashTests {

    // MARK: - Helpers

    private func makePerm(
        id: String = "p1",
        sessionId: String = "s1",
        timeoutOffset: TimeInterval = 120
    ) -> PermissionRequest {
        PermissionRequest(
            id: id, sessionId: sessionId, tool: "bash",
            input: [:], displaySummary: "bash: test",
            risk: .high, reason: "Test",
            timeoutAt: Date().addingTimeInterval(timeoutOffset)
        )
    }

    @MainActor
    private func makeConnection(sessionId: String = "s1") -> ServerConnection {
        let conn = ServerConnection()
        conn.configure(credentials: ServerCredentials(
            host: "localhost", port: 7749, token: "sk_test", name: "Test"
        ))
        // Avoid opening a real WebSocket in unit tests.
        conn._setActiveSessionIdForTesting(sessionId)
        return conn
    }

    // MARK: - Bug 3: permissionCancelled

    @MainActor
    @Test func permissionCancelledResolvesInTimeline() {
        let conn = makeConnection()
        let perm = makePerm()

        // Route permission request — goes to store, NOT timeline
        conn.handleServerMessage(.permissionRequest(perm), sessionId: "s1")
        conn.flushAndSuspend()

        // Permission should be in store, not in timeline
        #expect(conn.permissionStore.count == 1)
        let inlinePerms = conn.reducer.items.filter {
            if case .permission = $0 { return true }
            return false
        }
        #expect(inlinePerms.count == 0, "Pending permissions should not appear in timeline")

        // Route permission cancelled
        conn.handleServerMessage(.permissionCancelled(id: "p1"), sessionId: "s1")

        // Store should be empty
        #expect(conn.permissionStore.count == 0)

        // Timeline should have a resolved marker
        let resolved = conn.reducer.items.filter {
            if case .permissionResolved = $0 { return true }
            return false
        }
        #expect(resolved.count == 1, "Should have a resolved marker")

        // Verify it's marked as cancelled with tool info
        if case .permissionResolved(_, let outcome, let tool, _) = resolved.first {
            #expect(outcome == .cancelled)
            #expect(tool == "bash")
        } else {
            Issue.record("Expected permissionResolved")
        }
    }

    @MainActor
    @Test func permissionCancelledClearsFromStore() {
        let conn = makeConnection()
        let perm = makePerm()

        conn.handleServerMessage(.permissionRequest(perm), sessionId: "s1")
        #expect(conn.permissionStore.count == 1)

        conn.handleServerMessage(.permissionCancelled(id: "p1"), sessionId: "s1")
        #expect(conn.permissionStore.count == 0)
    }

    @MainActor
    @Test func permissionCancelledForUnknownIdIsNoOp() {
        let conn = makeConnection()

        // Cancel a permission that was never added
        conn.handleServerMessage(.permissionCancelled(id: "nonexistent"), sessionId: "s1")

        #expect(conn.permissionStore.count == 0)
        #expect(conn.reducer.items.isEmpty)
    }

    // MARK: - Bug 4: No client-side permission timeout sweep

    @MainActor
    @Test func sweepExpiredRemovesStalePermissions() {
        let store = PermissionStore()
        let expired = makePerm(id: "p1", timeoutOffset: -60) // 1 min ago
        store.add(expired)
        #expect(store.count == 1)

        let expiredRequests = store.sweepExpired()

        #expect(store.count == 0)
        #expect(expiredRequests.count == 1)
        #expect(expiredRequests[0].id == "p1")
    }

    @MainActor
    @Test func sweepExpiredKeepsFreshPermissions() {
        let store = PermissionStore()
        let fresh = makePerm(id: "p1", timeoutOffset: 120) // 2 min from now
        store.add(fresh)

        let expiredRequests = store.sweepExpired()

        #expect(store.count == 1, "Fresh permission should survive sweep")
        #expect(expiredRequests.isEmpty)
    }

    @MainActor
    @Test func sweepExpiredMixedBatch() {
        let store = PermissionStore()
        store.add(makePerm(id: "old", timeoutOffset: -60))
        store.add(makePerm(id: "fresh", timeoutOffset: 120))

        let expiredRequests = store.sweepExpired()

        #expect(store.count == 1)
        #expect(expiredRequests.count == 1)
        #expect(expiredRequests[0].id == "old")
        #expect(store.pending[0].id == "fresh")
    }

    @MainActor
    @Test func sweepExpiredEmptyStoreIsNoOp() {
        let store = PermissionStore()
        let expiredRequests = store.sweepExpired()
        #expect(expiredRequests.isEmpty)
    }

    @MainActor
    @Test func sweepExpiredResolvesInTimeline() {
        let conn = makeConnection()
        let expiredPerm = makePerm(id: "p1", timeoutOffset: -30) // Already expired

        // Add permission to store (not timeline in new flow)
        conn.handleServerMessage(.permissionRequest(expiredPerm), sessionId: "s1")
        conn.flushAndSuspend()

        #expect(conn.permissionStore.count == 1)

        // Sweep expired (as reconnectIfNeeded would)
        let expiredRequests = conn.permissionStore.sweepExpired()
        for request in expiredRequests {
            conn.reducer.resolvePermission(
                id: request.id, outcome: .expired,
                tool: request.tool, summary: request.displaySummary
            )
        }

        // Permission should be gone from store
        #expect(conn.permissionStore.count == 0)

        // Timeline should show resolved marker
        let resolved = conn.reducer.items.filter {
            if case .permissionResolved = $0 { return true }
            return false
        }
        #expect(resolved.count == 1)

        if case .permissionResolved(_, let outcome, _, _) = resolved.first {
            #expect(outcome == .expired)
        }
    }

    // MARK: - Bug 5: Optimistic user message not retracted on failed send

    @MainActor
    @Test func appendUserMessageReturnsId() {
        let reducer = TimelineReducer()
        let id = reducer.appendUserMessage("Hello")

        #expect(!id.isEmpty)
        #expect(reducer.items.count == 1)
        guard case .userMessage(let itemId, let text, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(itemId == id)
        #expect(text == "Hello")
    }

    @MainActor
    @Test func removeItemRetractsMessage() {
        let reducer = TimelineReducer()
        let id = reducer.appendUserMessage("oops")

        #expect(reducer.items.count == 1)

        reducer.removeItem(id: id)

        #expect(reducer.items.isEmpty, "Message should be retracted after removeItem")
    }

    @MainActor
    @Test func removeItemOnlyRemovesTarget() {
        let reducer = TimelineReducer()
        let id1 = reducer.appendUserMessage("first")
        _ = reducer.appendUserMessage("second")

        #expect(reducer.items.count == 2)

        reducer.removeItem(id: id1)

        #expect(reducer.items.count == 1)
        guard case .userMessage(_, let text, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(text == "second")
    }

    @MainActor
    @Test func removeNonexistentItemIsNoOp() {
        let reducer = TimelineReducer()
        _ = reducer.appendUserMessage("keep")

        reducer.removeItem(id: "nonexistent")

        #expect(reducer.items.count == 1, "Should not affect existing items")
    }

    @MainActor
    @Test func removeItemBumpsRenderVersion() {
        let reducer = TimelineReducer()
        let id = reducer.appendUserMessage("test")
        let versionBefore = reducer.renderVersion

        reducer.removeItem(id: id)

        #expect(reducer.renderVersion > versionBefore)
    }

    // Bug 1 (reconnectIfNeeded clobbers timeline) fixed:
    // loadFromREST removed entirely — trace is the only history path.
    // Trace preserves tool calls, thinking, and structured output.

    @MainActor
    @Test func loadSessionPreservesToolCalls() {
        let reducer = TimelineReducer()

        let trace = [
            decodeTrace("""
            {"id":"e1","type":"toolCall","timestamp":"2025-01-01T00:00:00Z","tool":"bash","args":{"command":{"type":"string","value":"ls"}}}
            """),
            decodeTrace("""
            {"id":"e2","type":"toolResult","timestamp":"2025-01-01T00:00:01Z","toolCallId":"e1","output":"file.txt"}
            """),
            decodeTrace("""
            {"id":"e3","type":"assistant","timestamp":"2025-01-01T00:00:02Z","text":"Here are the files"}
            """),
        ]

        reducer.loadSession(trace)

        let tools = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(tools.count == 1, "loadSession preserves tool call rows")
        #expect(reducer.items.count == 2) // tool + assistant
    }

    // MARK: - Permission store: take() API

    @MainActor
    @Test func takeReturnsAndRemovesRequest() {
        let store = PermissionStore()
        let perm = makePerm(id: "p1")
        store.add(perm)
        #expect(store.count == 1)

        let taken = store.take(id: "p1")
        #expect(taken?.id == "p1")
        #expect(taken?.tool == "bash")
        #expect(store.count == 0)
    }

    @MainActor
    @Test func takeReturnsNilForUnknownId() {
        let store = PermissionStore()
        let taken = store.take(id: "nonexistent")
        #expect(taken == nil)
    }

    @MainActor
    @Test func takeDoesNotAffectOtherRequests() {
        let store = PermissionStore()
        store.add(makePerm(id: "p1"))
        store.add(makePerm(id: "p2"))
        #expect(store.count == 2)

        let taken = store.take(id: "p1")
        #expect(taken?.id == "p1")
        #expect(store.count == 1)
        #expect(store.pending[0].id == "p2")
    }

    // MARK: - Permission resolved carries tool info

    @MainActor
    @Test func resolvePermissionAppendsWhenNotInTimeline() {
        let reducer = TimelineReducer()

        // In new flow, permission was never in the timeline
        reducer.resolvePermission(id: "p1", outcome: .allowed, tool: "bash", summary: "git push")

        #expect(reducer.items.count == 1)
        if case .permissionResolved(let id, let outcome, let tool, let summary) = reducer.items[0] {
            #expect(id == "p1")
            #expect(outcome == .allowed)
            #expect(tool == "bash")
            #expect(summary == "git push")
        } else {
            Issue.record("Expected permissionResolved")
        }
    }

    @MainActor
    @Test func resolvePermissionDoesNotDuplicateOnSecondCall() {
        let reducer = TimelineReducer()

        // First resolve appends
        reducer.resolvePermission(id: "p1", outcome: .denied, tool: "bash", summary: "bash: test")
        #expect(reducer.items.count == 1)

        // Second resolve for same id replaces (in-place update)
        reducer.resolvePermission(id: "p1", outcome: .allowed, tool: "bash", summary: "bash: test")
        #expect(reducer.items.count == 1, "Should replace, not duplicate")

        if case .permissionResolved(_, let outcome, _, _) = reducer.items[0] {
            #expect(outcome == .allowed, "Should reflect the latest outcome")
        } else {
            Issue.record("Expected permissionResolved")
        }
    }

    // MARK: - Helpers

    private func decodeTrace(_ json: String) -> TraceEvent {
        try! JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
    }
}
