import Foundation
import Testing
@testable import Oppi

/// Red test for: returning to parent session from child shows an empty timeline.
///
/// Reproduces the bug: when navigating parent→child→parent, the parent's
/// timeline is empty because `isReentry = true` skips the cache load.
/// The background trace fetch eventually fills it, but there's a visible
/// gap where the user sees nothing — or worse, if the fetch is slow/fails,
/// the timeline stays empty permanently.
///
/// The fix: on re-entry, load from cache immediately for instant display,
/// then update with fresh trace data when the fetch completes. Showing
/// slightly stale data is strictly better than showing nothing.
@Suite("Parent re-entry empty timeline")
@MainActor
struct ParentReentryEmptyTimelineTests {

    /// Core bug: parent→child→parent leaves timeline empty until trace fetch
    /// completes. The cache is skipped because `isReentry = true`.
    ///
    /// This test gates the trace fetch behind a continuation so we can
    /// check timeline state BEFORE the fetch completes. The current code
    /// will fail because the cache is skipped on re-entry.
    @Test func parentReentryShowsCachedContentImmediately() async throws {
        let parentId = "parent-empty-\(UUID().uuidString)"
        let childId = "child-empty-\(UUID().uuidString)"
        let workspaceId = "w1"

        let parentManager = ChatSessionManager(sessionId: parentId)
        let childManager = ChatSessionManager(sessionId: childId)
        let parentStreams = ScriptedStreamFactory()
        let childStreams = ScriptedStreamFactory()

        parentManager._streamSessionForTesting = { _ in parentStreams.makeStream() }
        childManager._streamSessionForTesting = { _ in childStreams.makeStream() }
        childManager._loadHistoryForTesting = { _, _ in nil }

        // Parent cache: realistic content the user previously saw
        await TimelineCache.shared.saveTrace(parentId, events: [
            makeTraceEvent(id: "p-u1", type: .user, text: "i want you check out the spawn agent code"),
            makeTraceEvent(id: "p-a1", text: "I'll look at the spawn agent implementation."),
            makeTraceEvent(id: "p-u2", type: .user, text: "looks good, go ahead"),
            makeTraceEvent(id: "p-a2", text: "PARENT_CACHED_CONTENT"),
        ])

        // Gate for the re-entry trace fetch. First connect uses a separate path.
        let reentryTraceFetchGate = AsyncGate()

        var traceFetchCount = 0
        parentManager._fetchSessionTraceForTesting = { _, _ in
            traceFetchCount += 1
            if traceFetchCount > 1 {
                // Re-entry trace fetch: block until gate opens
                await reentryTraceFetchGate.wait()
            }
            return (
                makeTestSession(id: parentId, workspaceId: workspaceId, status: .ready),
                [
                    makeTraceEvent(id: "p-u1", type: .user, text: "i want you check out the spawn agent code"),
                    makeTraceEvent(id: "p-a1", text: "I'll look at the spawn agent implementation."),
                    makeTraceEvent(id: "p-u2", type: .user, text: "looks good, go ahead"),
                    makeTraceEvent(id: "p-a2", text: "PARENT_FRESH_CONTENT"),
                ]
            )
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: parentId, workspaceId: workspaceId, status: .ready))
        var childSession = makeTestSession(id: childId, workspaceId: workspaceId, status: .busy)
        childSession.parentSessionId = parentId
        sessionStore.upsert(childSession)

        // --- Step 1: Parent connects (first time) ---
        let parentTask1 = Task { @MainActor in
            await parentManager.connect(
                connection: connection, sessionStore: sessionStore
            )
        }

        #expect(await parentStreams.waitForCreated(1))
        parentStreams.yield(index: 0, message: .connected(
            session: makeTestSession(id: parentId, workspaceId: workspaceId)
        ))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { parentManager.entryState == .streaming }
        })

        // First connect loads cache normally (isReentry = false)
        let hasContentOnFirst = parentManager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("PARENT_CACHED_CONTENT")
            }
            return false
        }
        #expect(hasContentOnFirst, "First connect should show cached content")

        // Let first trace fetch complete
        try await Task.sleep(for: .milliseconds(200))

        // --- Step 2: Navigate to child (parent stream ends) ---
        parentStreams.finish(index: 0)
        await parentTask1.value

        // --- Step 3: Child connects ---
        let childTask = Task { @MainActor in
            await childManager.connect(
                connection: connection, sessionStore: sessionStore
            )
        }

        #expect(await childStreams.waitForCreated(1))
        childStreams.yield(index: 0, message: .connected(
            session: makeTestSession(id: childId, workspaceId: workspaceId, status: .stopped)
        ))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { childManager.entryState == .streaming }
        })

        // Child emits some content
        childStreams.yield(index: 0, message: .agentStart)
        childStreams.yield(index: 0, message: .textDelta(delta: "CHILD_CONTENT"))
        childStreams.yield(index: 0, message: .messageEnd(role: "assistant", content: ""))
        childStreams.yield(index: 0, message: .agentEnd)
        try await Task.sleep(for: .milliseconds(50))

        // --- Step 4: Navigate back to parent (child stream ends) ---
        childStreams.finish(index: 0)
        await childTask.value

        // --- Step 5: Parent re-connects (simulates markAppeared + generation bump) ---
        parentManager.reconnect()
        let parentTask2 = Task { @MainActor in
            await parentManager.connect(
                connection: connection, sessionStore: sessionStore
            )
        }

        #expect(await parentStreams.waitForCreated(2))
        parentStreams.yield(index: 1, message: .connected(
            session: makeTestSession(id: parentId, workspaceId: workspaceId)
        ))

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { parentManager.entryState == .streaming }
        })

        // Let the state settle (but re-entry trace fetch is still gated)
        try await Task.sleep(for: .milliseconds(100))

        // --- KEY ASSERTION ---
        // BUG: The timeline is EMPTY here because isReentry=true skips the cache.
        // The trace fetch hasn't completed yet (gated), so the user sees nothing.
        //
        // EXPECTED: The cached content should be loaded immediately for instant
        // display, providing a seamless experience when navigating back.
        let hasContentBeforeTraceFetch = !parentManager.reducer.items.isEmpty
        #expect(
            hasContentBeforeTraceFetch,
            "Parent timeline must NOT be empty on re-entry — cache should provide instant display"
        )

        // Additional: verify it's actually parent content (not child leftovers).
        // The cache was updated with fresh trace data during the first connect,
        // so it now contains "PARENT_FRESH_CONTENT" (from the first trace fetch).
        let hasParentContent = parentManager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("PARENT_FRESH_CONTENT") || text.contains("PARENT_CACHED_CONTENT")
            }
            return false
        }
        #expect(
            hasParentContent,
            "Re-entry should show parent's cached content, not child content or nothing"
        )

        // No child content should leak through
        let hasChildContent = parentManager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("CHILD_CONTENT")
            }
            return false
        }
        #expect(!hasChildContent, "Child content must not remain in timeline after returning to parent")

        // --- Now let the trace fetch complete ---
        await reentryTraceFetchGate.open()
        try await Task.sleep(for: .milliseconds(200))

        // After trace fetch, content should be updated to fresh version
        let hasFreshContent = parentManager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("PARENT_FRESH_CONTENT")
            }
            return false
        }
        #expect(
            hasFreshContent,
            "After trace fetch completes, timeline should update to fresh content"
        )

        parentStreams.finish(index: 1)
        await parentTask2.value
        await TimelineCache.shared.removeTrace(parentId)
    }

    /// Variant: when the trace fetch fails on re-entry, cached content
    /// should still be shown. Currently, the cache is skipped AND the
    /// fetch fails = permanently empty timeline.
    @Test func parentReentryWithFailedTraceFetchShowsCache() async throws {
        let parentId = "parent-fail-\(UUID().uuidString)"
        let childId = "child-fail-\(UUID().uuidString)"
        let workspaceId = "w1"

        let parentManager = ChatSessionManager(sessionId: parentId)
        let childManager = ChatSessionManager(sessionId: childId)
        let parentStreams = ScriptedStreamFactory()
        let childStreams = ScriptedStreamFactory()

        parentManager._streamSessionForTesting = { _ in parentStreams.makeStream() }
        childManager._streamSessionForTesting = { _ in childStreams.makeStream() }
        childManager._loadHistoryForTesting = { _, _ in nil }

        // Cache with parent content
        await TimelineCache.shared.saveTrace(parentId, events: [
            makeTraceEvent(id: "pf-u1", type: .user, text: "help me debug this"),
            makeTraceEvent(id: "pf-a1", text: "PARENT_CONTENT_SURVIVES_FAILURE"),
        ])

        var traceFetchCount = 0
        parentManager._fetchSessionTraceForTesting = { _, _ in
            traceFetchCount += 1
            if traceFetchCount > 1 {
                // Re-entry trace fetch fails (network error, server down, etc.)
                throw URLError(.notConnectedToInternet)
            }
            return (
                makeTestSession(id: parentId, workspaceId: workspaceId, status: .ready),
                [
                    makeTraceEvent(id: "pf-u1", type: .user, text: "help me debug this"),
                    makeTraceEvent(id: "pf-a1", text: "PARENT_CONTENT_SURVIVES_FAILURE"),
                ]
            )
        }

        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        let sessionStore = SessionStore()
        sessionStore.upsert(makeTestSession(id: parentId, workspaceId: workspaceId, status: .ready))
        var childSession = makeTestSession(id: childId, workspaceId: workspaceId, status: .busy)
        childSession.parentSessionId = parentId
        sessionStore.upsert(childSession)

        // --- Step 1: Parent connects first time ---
        let parentTask1 = Task { @MainActor in
            await parentManager.connect(
                connection: connection, sessionStore: sessionStore
            )
        }

        #expect(await parentStreams.waitForCreated(1))
        parentStreams.yield(index: 0, message: .connected(
            session: makeTestSession(id: parentId, workspaceId: workspaceId)
        ))
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { parentManager.entryState == .streaming }
        })
        try await Task.sleep(for: .milliseconds(200))

        // --- Step 2: Navigate to child ---
        parentStreams.finish(index: 0)
        await parentTask1.value

        let childTask = Task { @MainActor in
            await childManager.connect(
                connection: connection, sessionStore: sessionStore
            )
        }
        #expect(await childStreams.waitForCreated(1))
        childStreams.yield(index: 0, message: .connected(
            session: makeTestSession(id: childId, workspaceId: workspaceId)
        ))
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { childManager.entryState == .streaming }
        })

        // --- Step 3: Navigate back to parent ---
        childStreams.finish(index: 0)
        await childTask.value

        parentManager.reconnect()
        let parentTask2 = Task { @MainActor in
            await parentManager.connect(
                connection: connection, sessionStore: sessionStore
            )
        }

        #expect(await parentStreams.waitForCreated(2))
        parentStreams.yield(index: 1, message: .connected(
            session: makeTestSession(id: parentId, workspaceId: workspaceId)
        ))
        #expect(await waitForTestCondition(timeoutMs: 500) {
            await MainActor.run { parentManager.entryState == .streaming }
        })

        // Wait for the failed trace fetch to complete
        try await Task.sleep(for: .milliseconds(300))

        // --- KEY ASSERTION ---
        // With the current code: cache skipped (isReentry) + trace fetch failed
        // = permanently empty timeline. The user is stuck.
        //
        // Expected: cache should have been loaded on re-entry as a fallback.
        let hasContent = !parentManager.reducer.items.isEmpty
        #expect(
            hasContent,
            "Re-entry with failed trace fetch must show cached content — not a blank timeline"
        )

        let hasParentContent = parentManager.reducer.items.contains { item in
            if case .assistantMessage(_, let text, _) = item {
                return text.contains("PARENT_CONTENT_SURVIVES_FAILURE")
            }
            return false
        }
        #expect(
            hasParentContent,
            "Cached parent content should survive a trace fetch failure on re-entry"
        )

        parentStreams.finish(index: 1)
        await parentTask2.value
        await TimelineCache.shared.removeTrace(parentId)
    }

    // MARK: - Helpers

    private func makeTraceEvent(
        id: String,
        type: TraceEventType = .assistant,
        text: String = "test content",
        timestamp: String = "2026-03-23T00:00:00Z"
    ) -> TraceEvent {
        TraceEvent(
            id: id,
            type: type,
            timestamp: timestamp,
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
