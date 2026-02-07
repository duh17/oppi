import Testing
import Foundation
@testable import PiRemote

/// Tests confirming bugs found in the behavioral audit, and verifying fixes.
///
/// Bug 1: reconnectIfNeeded clobbers live streaming timeline
/// Bug 2: reconnectIfNeeded loses tool call history (uses REST not trace)
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
        _ = conn.streamSession(sessionId)
        return conn
    }

    // MARK: - Bug 3: permissionCancelled leaves stale card in timeline

    @MainActor
    @Test func permissionCancelledResolvesInTimeline() {
        let conn = makeConnection()
        let perm = makePerm()

        // Route permission request
        conn.handleServerMessage(.permissionRequest(perm), sessionId: "s1")
        conn.flushAndSuspend()

        // Verify permission card is in timeline
        let permItems = conn.reducer.items.filter {
            if case .permission = $0 { return true }
            return false
        }
        #expect(permItems.count == 1)

        // Route permission cancelled
        conn.handleServerMessage(.permissionCancelled(id: "p1"), sessionId: "s1")

        // After fix: permission card should be replaced with resolved badge
        let activePerms = conn.reducer.items.filter {
            if case .permission = $0 { return true }
            return false
        }
        #expect(activePerms.count == 0, "Cancelled permission should not remain as active card")

        let resolved = conn.reducer.items.filter {
            if case .permissionResolved = $0 { return true }
            return false
        }
        #expect(resolved.count == 1, "Should have a resolved badge")
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

        let expiredIds = store.sweepExpired()

        #expect(store.count == 0)
        #expect(expiredIds == ["p1"])
    }

    @MainActor
    @Test func sweepExpiredKeepsFreshPermissions() {
        let store = PermissionStore()
        let fresh = makePerm(id: "p1", timeoutOffset: 120) // 2 min from now
        store.add(fresh)

        let expiredIds = store.sweepExpired()

        #expect(store.count == 1, "Fresh permission should survive sweep")
        #expect(expiredIds.isEmpty)
    }

    @MainActor
    @Test func sweepExpiredMixedBatch() {
        let store = PermissionStore()
        store.add(makePerm(id: "old", timeoutOffset: -60))
        store.add(makePerm(id: "fresh", timeoutOffset: 120))

        let expiredIds = store.sweepExpired()

        #expect(store.count == 1)
        #expect(expiredIds == ["old"])
        #expect(store.pending[0].id == "fresh")
    }

    @MainActor
    @Test func sweepExpiredEmptyStoreIsNoOp() {
        let store = PermissionStore()
        let expiredIds = store.sweepExpired()
        #expect(expiredIds.isEmpty)
    }

    @MainActor
    @Test func sweepExpiredResolvesInTimeline() {
        let conn = makeConnection()
        let expiredPerm = makePerm(id: "p1", timeoutOffset: -30) // Already expired

        // Add permission to store and timeline
        conn.handleServerMessage(.permissionRequest(expiredPerm), sessionId: "s1")
        conn.flushAndSuspend()

        #expect(conn.permissionStore.count == 1)
        let permCards = conn.reducer.items.filter {
            if case .permission = $0 { return true }
            return false
        }
        #expect(permCards.count == 1)

        // Sweep expired (as reconnectIfNeeded would)
        let expiredIds = conn.permissionStore.sweepExpired()
        for id in expiredIds {
            conn.reducer.resolvePermission(id: id, action: .deny)
        }

        // Permission should be gone from store
        #expect(conn.permissionStore.count == 0)

        // Timeline should show resolved badge, not active card
        let activePerms = conn.reducer.items.filter {
            if case .permission = $0 { return true }
            return false
        }
        #expect(activePerms.count == 0)

        let resolved = conn.reducer.items.filter {
            if case .permissionResolved = $0 { return true }
            return false
        }
        #expect(resolved.count == 1)
    }

    // MARK: - Bug 5: Optimistic user message not retracted on failed send

    @MainActor
    @Test func appendUserMessageReturnsId() {
        let reducer = TimelineReducer()
        let id = reducer.appendUserMessage("Hello")

        #expect(!id.isEmpty)
        #expect(reducer.items.count == 1)
        guard case .userMessage(let itemId, let text, _) = reducer.items[0] else {
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
        guard case .userMessage(_, let text, _) = reducer.items[0] else {
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

    // MARK: - Bug 1: reconnectIfNeeded clobbers live streaming timeline
    //
    // Full integration test would need a mock APIClient. Instead, we verify
    // the building blocks: loadFromREST wipes items, loadFromTrace preserves
    // tool calls, and the reconnect logic checks stream status.

    @MainActor
    @Test func loadFromRESTWipesToolCalls() {
        // This confirms the bug EXISTS when loadFromREST is used:
        // tool call rows vanish because REST only has user/assistant/system.
        let reducer = TimelineReducer()

        // Simulate a session with tool calls from trace
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": "ls"]))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: "t1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Here are the files"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let toolsBefore = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(toolsBefore.count == 1)

        // loadFromREST only has the text message — tool calls are lost
        let messages = [
            decodeMessage("""
            {"id":"m1","sessionId":"s1","role":"assistant","content":"Here are the files","timestamp":1700000000000}
            """)
        ]
        reducer.loadFromREST(messages)

        let toolsAfter = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(toolsAfter.count == 0, "loadFromREST loses tool call history — bug #2 confirms this")
        #expect(reducer.items.count == 1) // Only the assistant message remains
    }

    @MainActor
    @Test func loadFromTracePreservesToolCalls() {
        // This confirms the fix: loadFromTrace keeps tool call rows.
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

        reducer.loadFromTrace(trace)

        let tools = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(tools.count == 1, "loadFromTrace preserves tool call rows")
        #expect(reducer.items.count == 2) // tool + assistant
    }

    // MARK: - Helpers

    private func decodeMessage(_ json: String) -> SessionMessage {
        try! JSONDecoder().decode(SessionMessage.self, from: json.data(using: .utf8)!)
    }

    private func decodeTrace(_ json: String) -> TraceEvent {
        try! JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
    }
}
