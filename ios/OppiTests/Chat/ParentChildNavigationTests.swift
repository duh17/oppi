import Foundation
import Testing
@testable import Oppi

/// Tests for parent↔child session navigation with a shared TimelineReducer.
///
/// The reducer is injected via environment (shared across ChatViews in the nav stack).
/// When navigating parent→child→parent, the same reducer is reset and reloaded.
/// These tests verify the reducer state is correct at each step.
@Suite("Parent-Child Navigation")
struct ParentChildNavigationTests {

    // MARK: - Shared reducer reset on session switch

    /// Verify that connecting to a different session resets the reducer
    /// (switchingSessions = true triggers reducer.reset()).
    @MainActor
    @Test func switchingSessionsResetsReducer() async {
        let parentId = "parent-\(UUID().uuidString)"
        let childId = "child-\(UUID().uuidString)"

        let parentManager = ChatSessionManager(sessionId: parentId)
        let childManager = ChatSessionManager(sessionId: childId)
        let parentStreams = ScriptedStreamFactory()
        let childStreams = ScriptedStreamFactory()

        parentManager._streamSessionForTesting = { _ in parentStreams.makeStream() }
        childManager._streamSessionForTesting = { _ in childStreams.makeStream() }
        parentManager._loadHistoryForTesting = { _, _ in nil }
        childManager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let reducer = connection.reducer
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: parentId, workspaceId: "w1", status: .busy))
        var childSession = makeTestSession(id: childId, workspaceId: "w1", status: .busy)
        childSession.parentSessionId = parentId
        sessionStore.upsert(childSession)

        // Step 1: Connect parent
        let parentTask = Task { @MainActor in
            await parentManager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await parentStreams.waitForCreated(1))
        parentStreams.yield(index: 0, message: .connected(session: makeTestSession(id: parentId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { parentManager.entryState == .streaming }
        })

        // Parent sends some events
        parentStreams.yield(index: 0, message: .agentStart)
        parentStreams.yield(index: 0, message: .textDelta(delta: "Parent response"))
        parentStreams.yield(index: 0, message: .messageEnd(role: "assistant", content: ""))
        parentStreams.yield(index: 0, message: .agentEnd)
        try? await Task.sleep(for: .milliseconds(100))

        let parentItemCount = reducer.items.count
        #expect(parentItemCount > 0, "Reducer should have parent items")
        #expect(sessionStore.activeSessionId == parentId)

        // Step 2: Disconnect parent (simulates onDisappear)
        parentStreams.finish(index: 0)
        await parentTask.value

        // Step 3: Connect child (simulates child ChatView appearing)
        let childTask = Task { @MainActor in
            await childManager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await childStreams.waitForCreated(1))

        // Reducer should be reset because switchingSessions = true
        #expect(sessionStore.activeSessionId == childId)

        childStreams.yield(index: 0, message: .connected(session: makeTestSession(id: childId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { childManager.entryState == .streaming }
        })

        // Child events
        childStreams.yield(index: 0, message: .agentStart)
        childStreams.yield(index: 0, message: .textDelta(delta: "Child response"))
        childStreams.yield(index: 0, message: .messageEnd(role: "assistant", content: ""))
        childStreams.yield(index: 0, message: .agentEnd)
        try? await Task.sleep(for: .milliseconds(100))

        // Reducer should now have only child items, not parent items
        let hasChildContent = reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("Child response")
            }
            return false
        }
        #expect(hasChildContent, "Reducer should have child content after session switch")

        let hasParentContent = reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("Parent response")
            }
            return false
        }
        #expect(!hasParentContent, "Reducer should NOT have parent content after reset")

        // Step 4: Disconnect child
        childStreams.finish(index: 0)
        await childTask.value
    }

    // MARK: - Parent re-entry rebuilds from trace

    /// After navigating parent→child→parent, the parent's timeline should
    /// be fully restored from the trace (not show child content or stale cache).
    @MainActor
    @Test func parentReentryRebuildsFromTrace() async {
        let parentId = "parent-reentry-\(UUID().uuidString)"
        let childId = "child-reentry-\(UUID().uuidString)"

        let parentManager = ChatSessionManager(sessionId: parentId)
        let childManager = ChatSessionManager(sessionId: childId)
        let parentStreams = ScriptedStreamFactory()
        let childStreams = ScriptedStreamFactory()

        parentManager._streamSessionForTesting = { _ in parentStreams.makeStream() }
        childManager._streamSessionForTesting = { _ in childStreams.makeStream() }
        childManager._loadHistoryForTesting = { _, _ in nil }

        // Parent's trace fetch returns full history
        parentManager._fetchSessionTraceForTesting = { _, _ in
            (
                makeTestSession(id: parentId, workspaceId: "w1", status: .busy),
                [
                    makeTraceEvent(id: "p1", type: .user, text: "Build the feature"),
                    makeTraceEvent(id: "p2", text: "PARENT_TRACE_CONTENT"),
                ]
            )
        }

        var parentInboundMeta: [WebSocketClient.InboundMeta?] = [
            .init(seq: nil, currentSeq: 5),
            .init(seq: nil, currentSeq: 5), // second connect (re-entry)
        ]
        parentManager._consumeInboundMetaForTesting = {
            guard !parentInboundMeta.isEmpty else { return nil }
            return parentInboundMeta.removeFirst()
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let reducer = connection.reducer
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: parentId, workspaceId: "w1", status: .busy))
        var childSession2 = makeTestSession(id: childId, workspaceId: "w1", status: .busy)
        childSession2.parentSessionId = parentId
        sessionStore.upsert(childSession2)

        // Step 1: Parent connects
        let parentTask1 = Task { @MainActor in
            await parentManager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await parentStreams.waitForCreated(1))
        parentStreams.yield(index: 0, message: .connected(session: makeTestSession(id: parentId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { parentManager.entryState == .streaming }
        })
        try? await Task.sleep(for: .milliseconds(200)) // let trace fetch complete

        // Step 2: Navigate to child (parent stream ends)
        parentStreams.finish(index: 0)
        await parentTask1.value

        // Step 3: Child connects
        let childTask = Task { @MainActor in
            await childManager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await childStreams.waitForCreated(1))
        childStreams.yield(index: 0, message: .connected(session: makeTestSession(id: childId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { childManager.entryState == .streaming }
        })

        childStreams.yield(index: 0, message: .agentStart)
        childStreams.yield(index: 0, message: .textDelta(delta: "CHILD_CONTENT"))
        childStreams.yield(index: 0, message: .messageEnd(role: "assistant", content: ""))
        childStreams.yield(index: 0, message: .agentEnd)
        try? await Task.sleep(for: .milliseconds(100))

        // Verify child content is in reducer
        let hasChildBefore = reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("CHILD_CONTENT")
            }
            return false
        }
        #expect(hasChildBefore, "Child content should be in reducer")

        // Step 4: Navigate back to parent (child stream ends)
        childStreams.finish(index: 0)
        await childTask.value

        // Step 5: Parent re-connects (simulates markAppeared → generation bump)
        parentManager.reconnect()
        let parentTask2 = Task { @MainActor in
            await parentManager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await parentStreams.waitForCreated(2))
        parentStreams.yield(index: 1, message: .connected(session: makeTestSession(id: parentId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { parentManager.entryState == .streaming }
        })

        // Wait for trace fetch to complete
        try? await Task.sleep(for: .milliseconds(300))

        // Parent content should be restored from trace
        let hasParentContent = reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("PARENT_TRACE_CONTENT")
            }
            return false
        }
        #expect(hasParentContent, "Parent content should be restored from trace after re-entry")

        // Child content should NOT be present
        let hasChildAfter = reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("CHILD_CONTENT")
            }
            return false
        }
        #expect(!hasChildAfter, "Child content should NOT remain in reducer after parent re-entry")

        parentStreams.finish(index: 1)
        await parentTask2.value
    }

    // MARK: - Re-entry loads cache for instant display

    /// Verify that on re-entry (parent→child→parent), cached content IS loaded
    /// immediately for instant display. Showing slightly stale data is better
    /// than an empty timeline while the trace fetch runs.
    @MainActor
    @Test func reentryLoadsCacheForInstantDisplay() async {
        let parentId = "parent-nocache-\(UUID().uuidString)"
        let childId = "child-nocache-\(UUID().uuidString)"

        let parentManager = ChatSessionManager(sessionId: parentId)
        let childManager = ChatSessionManager(sessionId: childId)
        let parentStreams = ScriptedStreamFactory()
        let childStreams = ScriptedStreamFactory()

        parentManager._streamSessionForTesting = { _ in parentStreams.makeStream() }
        childManager._streamSessionForTesting = { _ in childStreams.makeStream() }
        childManager._loadHistoryForTesting = { _, _ in nil }
        parentManager._loadHistoryForTesting = { _, _ in nil }

        // Cache for parent — should load on both first connect AND re-entry
        await TimelineCache.shared.saveTrace(parentId, events: [
            makeTraceEvent(id: "cached-1", text: "CACHED_CONTENT"),
        ])

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let reducer = connection.reducer
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: parentId, workspaceId: "w1", status: .busy))
        var childSession = makeTestSession(id: childId, workspaceId: "w1", status: .busy)
        childSession.parentSessionId = parentId
        sessionStore.upsert(childSession)

        // Step 1: Parent connects for the first time
        let parentTask1 = Task { @MainActor in
            await parentManager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await parentStreams.waitForCreated(1))
        parentStreams.yield(index: 0, message: .connected(session: makeTestSession(id: parentId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { parentManager.entryState == .streaming }
        })

        // First connect: cache IS loaded normally
        let hasCacheOnFirst = reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("CACHED_CONTENT")
            }
            return false
        }
        #expect(hasCacheOnFirst, "First connect should load cache normally")

        // Step 2: Navigate to child (parent stream ends)
        parentStreams.finish(index: 0)
        await parentTask1.value

        // Step 3: Child connects (sets activeSessionId to child)
        let childTask = Task { @MainActor in
            await childManager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await childStreams.waitForCreated(1))
        childStreams.yield(index: 0, message: .connected(session: makeTestSession(id: childId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { childManager.entryState == .streaming }
        })

        // Step 4: Navigate back to parent (child stream ends)
        childStreams.finish(index: 0)
        await childTask.value

        // Step 5: Parent re-connects
        parentManager.reconnect()
        let parentTask2 = Task { @MainActor in
            await parentManager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await parentStreams.waitForCreated(2))
        parentStreams.yield(index: 1, message: .connected(session: makeTestSession(id: parentId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { parentManager.entryState == .streaming }
        })

        // Let any pending tasks drain
        try? await Task.sleep(for: .milliseconds(100))

        // KEY: Cached content SHOULD be in the reducer on re-entry for instant display.
        // The background trace fetch will update it with fresh data when it completes.
        let hasCachedContentOnReentry = reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("CACHED_CONTENT")
            }
            return false
        }
        #expect(hasCachedContentOnReentry, "Re-entry should load cache for instant display — no empty timeline")

        // Reducer should NOT be empty
        #expect(!reducer.items.isEmpty, "Reducer should have cached content on re-entry")

        parentStreams.finish(index: 1)
        await parentTask2.value
        await TimelineCache.shared.removeTrace(parentId)
    }

    // MARK: - Session affinity gates stale items

    /// Verify that reducer.activeSessionId prevents a child view from rendering
    /// parent items. The shared reducer has parent items when the child ChatView
    /// is pushed — visibleItems should return empty because activeSessionId
    /// doesn't match the child's sessionId.
    @MainActor
    @Test func activeSessionIdGatesStaleParentItems() async {
        let parentId = "parent-gate-\(UUID().uuidString)"
        let childId = "child-gate-\(UUID().uuidString)"

        let parentManager = ChatSessionManager(sessionId: parentId)
        let parentStreams = ScriptedStreamFactory()

        parentManager._streamSessionForTesting = { _ in parentStreams.makeStream() }
        parentManager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let reducer = connection.reducer
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: parentId, workspaceId: "w1", status: .busy))
        var childSession = makeTestSession(id: childId, workspaceId: "w1", status: .busy)
        childSession.parentSessionId = parentId
        sessionStore.upsert(childSession)

        // Step 1: Parent connects and produces items
        let parentTask = Task { @MainActor in
            await parentManager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await parentStreams.waitForCreated(1))
        parentStreams.yield(index: 0, message: .connected(session: makeTestSession(id: parentId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { parentManager.entryState == .streaming }
        })

        parentStreams.yield(index: 0, message: .agentStart)
        parentStreams.yield(index: 0, message: .textDelta(delta: "PARENT_VISIBLE"))
        parentStreams.yield(index: 0, message: .messageEnd(role: "assistant", content: ""))
        parentStreams.yield(index: 0, message: .agentEnd)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(!reducer.items.isEmpty, "Reducer should have parent items")
        #expect(reducer.activeSessionId == parentId, "activeSessionId should be parent")

        // Step 2: Simulate what ChatTimelineView sees when child is pushed.
        // Before child's connect() runs, the reducer still has parent items
        // and activeSessionId is the parent. The child view's gate should
        // return empty because activeSessionId (parentId) != childId.
        let childVisibleItems = reducer.activeSessionId == childId
            ? reducer.items.suffix(80)
            : ArraySlice<ChatItem>()
        #expect(childVisibleItems.isEmpty, "Child view should NOT see parent items — activeSessionId gate must block")

        // Parent view should still see items (activeSessionId == parentId)
        let parentVisibleItems = reducer.activeSessionId == parentId
            ? reducer.items.suffix(80)
            : ArraySlice<ChatItem>()
        #expect(!parentVisibleItems.isEmpty, "Parent view should still see its own items during animation")

        // Step 3: Disconnect parent, connect child — verify gate lifts
        parentStreams.finish(index: 0)
        await parentTask.value

        let childManager = ChatSessionManager(sessionId: childId)
        let childStreams = ScriptedStreamFactory()
        childManager._streamSessionForTesting = { _ in childStreams.makeStream() }
        childManager._loadHistoryForTesting = { _, _ in nil }

        let childTask = Task { @MainActor in
            await childManager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await childStreams.waitForCreated(1))
        childStreams.yield(index: 0, message: .connected(session: makeTestSession(id: childId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { childManager.entryState == .streaming }
        })

        // After child's connect(), activeSessionId should be childId
        #expect(reducer.activeSessionId == childId, "activeSessionId should be child after connect()")

        // Child items should now be gated correctly
        childStreams.yield(index: 0, message: .agentStart)
        childStreams.yield(index: 0, message: .textDelta(delta: "CHILD_VISIBLE"))
        childStreams.yield(index: 0, message: .messageEnd(role: "assistant", content: ""))
        childStreams.yield(index: 0, message: .agentEnd)
        try? await Task.sleep(for: .milliseconds(100))

        let childAfterConnect = reducer.activeSessionId == childId
            ? reducer.items.suffix(80)
            : ArraySlice<ChatItem>()
        #expect(!childAfterConnect.isEmpty, "Child items should be visible after connect()")

        let hasChildContent = childAfterConnect.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("CHILD_VISIBLE")
            }
            return false
        }
        #expect(hasChildContent, "Gate should now pass and show child content")

        let hasParentContent = childAfterConnect.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("PARENT_VISIBLE")
            }
            return false
        }
        #expect(!hasParentContent, "Parent content should be gone after child connect reset")

        childStreams.finish(index: 0)
        await childTask.value
    }

    /// Verify that auto-reconnect doesn't hide items (activeSessionId stays stable).
    @MainActor
    @Test func autoReconnectPreservesActiveSessionId() async {
        let sessionId = "reconnect-\(UUID().uuidString)"

        let manager = ChatSessionManager(sessionId: sessionId)
        let streams = ScriptedStreamFactory()

        manager._streamSessionForTesting = { _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let reducer = connection.reducer
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1", status: .busy))

        let task = Task { @MainActor in
            await manager.connect(connection: connection, reducer: reducer, sessionStore: sessionStore)
        }

        #expect(await streams.waitForCreated(1))
        streams.yield(index: 0, message: .connected(session: makeTestSession(id: sessionId, workspaceId: "w1")))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { manager.entryState == .streaming }
        })

        streams.yield(index: 0, message: .agentStart)
        streams.yield(index: 0, message: .textDelta(delta: "Some content"))
        streams.yield(index: 0, message: .messageEnd(role: "assistant", content: ""))
        streams.yield(index: 0, message: .agentEnd)
        try? await Task.sleep(for: .milliseconds(100))

        // activeSessionId should be set and items visible
        #expect(reducer.activeSessionId == sessionId)
        #expect(!reducer.items.isEmpty)

        // Simulate WS drop → reconnect (stream ends, manager auto-reconnects)
        streams.finish(index: 0)
        await task.value

        // After stream ends, activeSessionId should still be this session
        // (not cleared). This ensures the view doesn't flash empty during reconnect.
        #expect(reducer.activeSessionId == sessionId, "activeSessionId should survive stream end for reconnect")
    }

    // MARK: - Helpers

    private func makeTraceEvent(
        id: String,
        type: TraceEventType = .assistant,
        text: String = "test content"
    ) -> TraceEvent {
        TraceEvent(
            id: id,
            type: type,
            timestamp: "2026-03-19T00:00:00Z",
            text: text,
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        )
    }
}
