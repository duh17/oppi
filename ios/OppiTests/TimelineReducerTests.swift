// swiftlint:disable file_length type_body_length
import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer")
struct TimelineReducerTests {

    @MainActor
    @Test func basicAgentTurn() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Hello "))
        reducer.process(.textDelta(sessionId: "s1", delta: "world!"))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.items.count == 1)
        guard case .assistantMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(text == "Hello world!")
    }

    @MainActor
    @Test func thinkingThenText() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "I need to "))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "think..."))
        reducer.process(.textDelta(sessionId: "s1", delta: "The answer is 42."))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.items.count == 2) // thinking + assistant
        guard case .thinking(_, let preview, _, _) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(preview.contains("I need to think"))
    }

    @MainActor
    @Test func toolCallSequence() {
        let reducer = TimelineReducer()
        let toolId = "tool-1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: ["command": "ls"]))
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: toolId, output: "file1.txt\nfile2.txt", isError: false))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: toolId))
        reducer.process(.agentEnd(sessionId: "s1"))

        let toolItems = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(toolItems.count == 1)

        guard case .toolCall(_, let tool, _, let preview, let bytes, let isError, let isDone) = toolItems[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tool == "bash")
        #expect(preview.contains("file1.txt"))
        #expect(bytes > 0)
        #expect(!isError)
        #expect(isDone)
    }

    @MainActor
    @Test func duplicateToolStartDoesNotCreateDuplicateRows() {
        let reducer = TimelineReducer()
        let toolId = "call_1|fc_1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: ["command": "ls"]))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: ["command": "ls"]))

        let toolItems = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }

        #expect(toolItems.count == 1)
        guard case .toolCall(let id, _, _, _, _, _, let isDone) = toolItems[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(id == toolId)
        #expect(!isDone)
    }

    @MainActor
    @Test func messageEndDoesNotDuplicateTraceAssistantAfterReload() {
        let reducer = TimelineReducer()

        reducer.loadSession([
            TraceEvent(
                id: "a1",
                type: .assistant,
                timestamp: "2025-01-01T00:00:01.000Z",
                text: "Love you, man. Wrapped clean.",
                tool: nil,
                args: nil,
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            ),
        ])

        // Reconnect/history reload race can deliver message_end after trace already
        // contains the final assistant message.
        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "Love you, man. Wrapped clean."
        ))

        let assistantItems = reducer.items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }

        #expect(assistantItems.count == 1)
        guard case .assistantMessage(let id, let text, _) = assistantItems[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(id == "a1")
        #expect(text == "Love you, man. Wrapped clean.")
    }

    @MainActor
    @Test func duplicateLiveToolStartUpdatesHistoryRowInPlace() {
        let reducer = TimelineReducer()
        let toolId = "call_2|fc_2"

        reducer.loadSession([
            TraceEvent(
                id: toolId,
                type: .toolCall,
                timestamp: "2025-01-01T00:00:00.000Z",
                text: nil,
                tool: "bash",
                args: ["command": .string("pwd")],
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            ),
        ])

        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: ["command": "pwd"]))

        #expect(reducer.items.count == 1)
        guard case .toolCall(_, _, _, _, _, _, let isDone) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(!isDone)
    }

    @MainActor
    @Test func assistantTextIsSplitAroundToolCall() {
        let reducer = TimelineReducer()
        let toolId = "tool-1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "before"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: ["command": "pwd"]))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: toolId))
        reducer.process(.textDelta(sessionId: "s1", delta: "after"))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.items.count == 3)

        guard case .assistantMessage(_, let before, _) = reducer.items[0] else {
            Issue.record("Expected first assistant message")
            return
        }
        #expect(before == "before")

        guard case .toolCall = reducer.items[1] else {
            Issue.record("Expected tool call between assistant chunks")
            return
        }

        guard case .assistantMessage(_, let after, _) = reducer.items[2] else {
            Issue.record("Expected second assistant message")
            return
        }
        #expect(after == "after")
    }

    @MainActor
    @Test func whitespaceOnlyTextBeforeToolDiscarded() {
        let reducer = TimelineReducer()

        // Pattern: API emits "\n\n" text delta before a tool call.
        // The finalizeAssistantMessage (triggered by toolStart) should
        // discard the whitespace-only buffer instead of creating an empty bubble.
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "\n\n"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: "t1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Done!"))
        reducer.process(.agentEnd(sessionId: "s1"))

        // Should be: toolCall, assistant("Done!") — no empty bubble for "\n\n"
        #expect(reducer.items.count == 2)
        guard case .toolCall = reducer.items[0] else {
            Issue.record("Expected toolCall at [0], got \(reducer.items[0])")
            return
        }
        guard case .assistantMessage(_, let text, _) = reducer.items[1] else {
            Issue.record("Expected assistantMessage at [1], got \(reducer.items[1])")
            return
        }
        #expect(text == "Done!")
    }

    @MainActor
    @Test func permissionRequestSkipsTimeline() {
        let reducer = TimelineReducer()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: ["command": "rm -rf /"],
            displaySummary: "bash: rm -rf /",
            risk: .critical, reason: "Destructive",
            timeoutAt: Date().addingTimeInterval(120)
        )

        // New flow: permissionRequest does NOT add to timeline
        reducer.process(.permissionRequest(perm))
        #expect(reducer.items.count == 0, "Pending permissions should not appear in timeline")

        // Resolve appends a marker since the permission was never inline
        reducer.resolvePermission(id: "p1", outcome: .denied, tool: "bash", summary: "bash: rm -rf /")
        #expect(reducer.items.count == 1)
        guard case .permissionResolved(_, let outcome, let tool, _) = reducer.items[0] else {
            Issue.record("Expected permissionResolved")
            return
        }
        #expect(outcome == .denied)
        #expect(tool == "bash")
    }

    @MainActor
    @Test func retryStartRendersAsSystemEvent() {
        let reducer = TimelineReducer()
        reducer.process(.retryStart(sessionId: "s1", attempt: 1, maxAttempts: 3, delayMs: 2000, errorMessage: "rate limit"))

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent for retry, got \(reducer.items[0])")
            return
        }
        #expect(msg.contains("Retrying"))
        #expect(msg.contains("1/3"))
    }

    @MainActor
    @Test func realErrorRendersAsError() {
        let reducer = TimelineReducer()
        reducer.process(.error(sessionId: "s1", message: "Something went wrong"))

        guard case .error(_, let msg) = reducer.items[0] else {
            Issue.record("Expected error")
            return
        }
        #expect(msg == "Something went wrong")
    }

    // loadFromREST removed — trace is the only history path.

    // MARK: - Edge Cases

    @MainActor
    @Test func doubleAgentStartPreservesFirstTurnItems() {
        let reducer = TimelineReducer()

        // First turn starts, text is upserted into items
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "partial "))

        // Second agentStart without agentEnd (reconnect mid-stream).
        // The reducer clears its internal buffers but preserves already-appended
        // items — removing visible content would lose data.
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "fresh response"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let assistantItems = reducer.items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }
        // Both items exist: the partial from the first turn and the full second turn
        #expect(assistantItems.count == 2)
        guard case .assistantMessage(_, let first, _) = assistantItems[0],
              case .assistantMessage(_, let second, _) = assistantItems[1] else {
            Issue.record("Expected two assistant messages")
            return
        }
        #expect(first == "partial ")
        #expect(second == "fresh response")
    }

    @MainActor
    @Test func resetThenReconnectProducesCleanTimeline() {
        let reducer = TimelineReducer()

        // Simulate normal reconnect: reset + fresh load
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "stale data"))

        // App calls reset() on session switch (as ChatView.connectToSession does)
        reducer.reset()

        reducer.process(.agentStart(sessionId: "s2"))
        reducer.process(.textDelta(sessionId: "s2", delta: "fresh"))
        reducer.process(.agentEnd(sessionId: "s2"))

        #expect(reducer.items.count == 1)
        guard case .assistantMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected single assistant message")
            return
        }
        #expect(text == "fresh")
    }

    @MainActor
    @Test func agentEndWithoutContentProducesNoItems() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.agentEnd(sessionId: "s1"))

        // No text deltas → no assistant message or thinking item
        #expect(reducer.items.isEmpty)
    }

    @MainActor
    @Test func toolEndForUnknownIdIsIgnored() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        // toolEnd with no matching toolStart — should not crash
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: "nonexistent"))
        reducer.process(.agentEnd(sessionId: "s1"))

        // No items created (the toolEnd just finds no matching index)
        #expect(reducer.items.isEmpty)
    }

    @MainActor
    @Test func toolOutputForUnknownIdIsStoredButNoItemCreated() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        // toolOutput with no matching toolStart — output is stored but no item update
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: "orphan", output: "data", isError: false))
        reducer.process(.agentEnd(sessionId: "s1"))

        // The output was stored in toolOutputStore but no toolCall item exists
        let toolItems = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(toolItems.isEmpty)
        // Output is still in the store (no crash, no data loss)
        #expect(reducer.toolOutputStore.fullOutput(for: "orphan") == "data")
    }

    @MainActor
    @Test func eventsAfterSessionEndedStillAppend() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "hello"))
        reducer.process(.sessionEnded(sessionId: "s1", reason: "stopped"))

        // sessionEnded finalizes assistant message + appends system event
        #expect(reducer.items.count == 2)

        // Additional events after session ended should still be processed
        // (the reducer doesn't gate on session state)
        reducer.process(.error(sessionId: "s1", message: "late error"))
        #expect(reducer.items.count == 3)
    }

    @MainActor
    @Test func resetClearsEverything() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "hello"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: "t1", output: "result", isError: false))
        reducer.process(.agentEnd(sessionId: "s1"))

        let preResetVersion = reducer.renderVersion
        reducer.reset()

        #expect(reducer.items.isEmpty)
        #expect(reducer.streamingAssistantID == nil)
        #expect(reducer.toolOutputStore.totalBytes == 0)
        #expect(reducer.renderVersion > preResetVersion)
    }

    @MainActor
    @Test func memoryWarningClearsTransientStores() {
        let reducer = TimelineReducer()
        let toolID = "tool-1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolID, tool: "bash", args: ["command": "ls"]))
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: toolID, output: "file1\nfile2", isError: false))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: toolID))
        reducer.process(.agentEnd(sessionId: "s1"))

        reducer.expandedItemIDs.insert(toolID)
        let versionBefore = reducer.renderVersion

        let stats = reducer.handleMemoryWarning()

        #expect(stats.toolOutputBytesCleared > 0)
        #expect(stats.expandedItemsCollapsed == 1)
        #expect(reducer.toolOutputStore.totalBytes == 0)
        #expect(reducer.expandedItemIDs.isEmpty)
        #expect(reducer.renderVersion > versionBefore)
        #expect(!reducer.items.isEmpty)
    }

    @MainActor
    @Test func memoryWarningStripsImageAttachments() {
        let reducer = TimelineReducer()

        let images = [ImageAttachment(data: String(repeating: "A", count: 10_000), mimeType: "image/png")]
        reducer.appendUserMessage("check this image", images: images)
        reducer.appendUserMessage("no images here")

        let stats = reducer.handleMemoryWarning()

        #expect(stats.imagesStripped == 1)

        // User message text preserved, images cleared
        if case .userMessage(_, let text, let imgs, _) = reducer.items.first {
            #expect(text == "check this image")
            #expect(imgs.isEmpty)
        } else {
            Issue.record("Expected userMessage as first item")
        }
    }

    @MainActor
    @Test func markdownSegmentCacheSkipsOversizedEntries() {
        let cache = MarkdownSegmentCache.shared
        cache.clearAll()
        defer { cache.clearAll() }

        let oversized = String(repeating: "x", count: 50_000)
        cache.set(oversized, segments: [.text(AttributedString("oversized"))])

        #expect(cache.get(oversized) == nil)
        let stats = cache.snapshot()
        #expect(stats.entries == 0)
        #expect(stats.totalSourceBytes == 0)
    }

    @MainActor
    @Test func markdownSegmentCacheEvictsToBudget() {
        let cache = MarkdownSegmentCache.shared
        cache.clearAll()
        defer { cache.clearAll() }

        let segment = FlatSegment.text(AttributedString("cached"))
        for idx in 0..<300 {
            let text = "entry-\(idx)-" + String(repeating: "y", count: 2_000)
            cache.set(text, segments: [segment])
        }

        let stats = cache.snapshot()
        #expect(stats.entries <= 128)
        #expect(stats.totalSourceBytes <= 1024 * 1024)
    }

    @MainActor
    @Test func markdownSegmentCacheSeparatesEntriesByTheme() {
        let cache = MarkdownSegmentCache.shared
        cache.clearAll()
        defer { cache.clearAll() }

        let content = "same-content"
        cache.set(content, themeID: .tokyoNight, segments: [.text(AttributedString("night"))])
        cache.set(content, themeID: .tokyoNightDay, segments: [.text(AttributedString("day"))])

        #expect(cache.get(content, themeID: .tokyoNight) != nil)
        #expect(cache.get(content, themeID: .tokyoNightDay) != nil)

        let stats = cache.snapshot()
        #expect(stats.entries == 2)
    }

    @MainActor
    @Test func processBatchMixedEvents() {
        let reducer = TimelineReducer()

        // Batch with interleaved delta and non-delta events
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .thinkingDelta(sessionId: "s1", delta: "hmm "),
            .thinkingDelta(sessionId: "s1", delta: "ok"),
            .textDelta(sessionId: "s1", delta: "Answer: "),
            .textDelta(sessionId: "s1", delta: "42"),
            .toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": "echo hi"]),
            .toolOutput(sessionId: "s1", toolEventId: "t1", output: "hi\n", isError: false),
            .toolEnd(sessionId: "s1", toolEventId: "t1"),
            .textDelta(sessionId: "s1", delta: "Done."),
            .agentEnd(sessionId: "s1"),
        ])

        // Expected: thinking, assistant("Answer: 42"), toolCall, assistant("Done.")
        #expect(reducer.items.count == 4)

        guard case .thinking(_, let preview, _, _) = reducer.items[0] else {
            Issue.record("Expected thinking, got \(reducer.items[0])")
            return
        }
        #expect(preview.contains("hmm ok"))

        guard case .assistantMessage(_, let text1, _) = reducer.items[1] else {
            Issue.record("Expected assistant message before tool")
            return
        }
        #expect(text1 == "Answer: 42")

        guard case .toolCall(_, let tool, _, _, _, _, let isDone) = reducer.items[2] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tool == "bash")
        #expect(isDone)

        guard case .assistantMessage(_, let text2, _) = reducer.items[3] else {
            Issue.record("Expected assistant message after tool")
            return
        }
        #expect(text2 == "Done.")
    }

    @MainActor
    @Test func orphanedToolIsClosedOnAgentEnd() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "read", args: [:]))
        // No toolEnd before agentEnd
        reducer.process(.agentEnd(sessionId: "s1"))

        guard case .toolCall(_, _, _, _, _, _, let isDone) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(isDone, "Orphaned tool should be marked done on agentEnd")
    }

    @MainActor
    @Test func appendSystemEvent() {
        let reducer = TimelineReducer()

        reducer.appendSystemEvent("Session force-stopped")

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent")
            return
        }
        #expect(msg == "Session force-stopped")
    }

    @MainActor
    @Test func multipleAgentTurns() {
        let reducer = TimelineReducer()

        // Turn 1
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "First"))
        reducer.process(.agentEnd(sessionId: "s1"))

        // Turn 2
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Second"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let assistants = reducer.items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }
        #expect(assistants.count == 2)

        guard case .assistantMessage(_, let t1, _) = assistants[0],
              case .assistantMessage(_, let t2, _) = assistants[1] else {
            Issue.record("Expected two assistant messages")
            return
        }
        #expect(t1 == "First")
        #expect(t2 == "Second")
    }

    @MainActor
    @Test func permissionExpiredIsNoOpInReducer() {
        // In new flow, permissionExpired is handled by ServerConnection
        // (via PermissionStore.take + resolvePermission), not by the reducer's
        // process() method. The reducer ignores both permission events.
        let reducer = TimelineReducer()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: ls",
            risk: .low, reason: "Read",
            timeoutAt: Date().addingTimeInterval(60)
        )

        reducer.process(.permissionRequest(perm))
        reducer.process(.permissionExpired(id: "p1"))

        // Neither event should add to the timeline
        #expect(reducer.items.count == 0, "Reducer should ignore permission events (handled by ServerConnection)")
    }

    // MARK: - loadSession

    @MainActor
    @Test func loadSessionUserAndAssistant() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi there!", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 2)
        guard case .userMessage(_, let userText, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(userText == "Hello")

        guard case .assistantMessage(_, let assistantText, _) = reducer.items[1] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(assistantText == "Hi there!")
    }

    @MainActor
    @Test func loadSessionUnchangedTraceUsesIncrementalNoOp() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi there!", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting)
        let baselineVersion = reducer.renderVersion
        let baselineItems = reducer.items

        reducer.loadSession(events)

        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.renderVersion == baselineVersion)
        #expect(reducer.items == baselineItems)
    }

    @MainActor
    @Test func loadSessionAppendedTraceUsesIncrementalAppend() {
        let reducer = TimelineReducer()
        let base = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi there!", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(base)
        let baselineVersion = reducer.renderVersion

        let extended = base + [
            TraceEvent(id: "e3", type: .assistant, timestamp: "2025-01-01T00:00:02.000Z",
                       text: "Incremental tail", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(extended)

        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.renderVersion == baselineVersion + 1)
        #expect(reducer.items.count == 3)
        guard case .assistantMessage(_, let tailText, _) = reducer.items[2] else {
            Issue.record("Expected incremental assistant tail")
            return
        }
        #expect(tailText == "Incremental tail")
    }

    @MainActor
    @Test func loadSessionForcesFullRebuildAfterOutOfBandMutation() {
        let reducer = TimelineReducer()
        let base = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(base)
        reducer.appendSystemEvent("Local marker")

        let extended = base + [
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Server canonical", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(extended)

        #expect(!reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.count == 2)
        guard case .userMessage = reducer.items[0] else {
            Issue.record("Expected canonical user message at index 0")
            return
        }
        guard case .assistantMessage(_, let text, _) = reducer.items[1] else {
            Issue.record("Expected canonical assistant message at index 1")
            return
        }
        #expect(text == "Server canonical")
    }

    @MainActor
    @Test func loadSessionToolCallAndResult() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: "bash", args: ["command": .string("ls -la")],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "tr1", type: .toolResult, timestamp: "2025-01-01T00:00:01.000Z",
                       text: nil, tool: nil, args: nil, output: "file1.txt\nfile2.txt",
                       toolCallId: "tc1", toolName: "bash", isError: false, thinking: nil),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 1)
        guard case .toolCall(_, let tool, _, let preview, let bytes, let isError, let isDone) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tool == "bash")
        #expect(preview.contains("file1.txt"))
        #expect(bytes > 0)
        #expect(!isError)
        #expect(isDone)
        // Full output stored in toolOutputStore
        #expect(reducer.toolOutputStore.fullOutput(for: "tc1") == "file1.txt\nfile2.txt")
    }

    @MainActor
    @Test func loadSessionThinking() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "t1", type: .thinking, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil,
                       thinking: "Let me think about this carefully"),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 1)
        guard case .thinking(_, let preview, let hasMore, let isDone) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(preview.contains("Let me think"))
        #expect(!hasMore) // Short text, no truncation
        #expect(isDone)   // Historical always done
    }

    @MainActor
    @Test func loadSessionLongThinkingStoresFullText() {
        let reducer = TimelineReducer()
        let longThinking = String(repeating: "x", count: 600) // > maxPreviewLength
        let events = [
            TraceEvent(id: "t1", type: .thinking, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil,
                       thinking: longThinking),
        ]
        reducer.loadSession(events)

        guard case .thinking(_, _, let hasMore, _) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(hasMore)
        #expect(reducer.toolOutputStore.fullOutput(for: "t1") == longThinking)
    }

    @MainActor
    @Test func loadSessionSystemAndCompaction() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "s1", type: .system, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Session started", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "c1", type: .compaction, timestamp: "2025-01-01T00:00:01.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 2)
        guard case .systemEvent(_, let msg1) = reducer.items[0] else {
            Issue.record("Expected systemEvent for system type")
            return
        }
        #expect(msg1 == "Session started")

        guard case .systemEvent(_, let msg2) = reducer.items[1] else {
            Issue.record("Expected systemEvent for compaction type")
            return
        }
        #expect(msg2 == "Context compacted")
    }

    @MainActor
    @Test func loadSessionCompactionPrefersTraceSummaryText() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "c1", type: .compaction, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Context compacted (12,345 tokens): ## Goal\n1. Keep calm",
                       tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let message) = reducer.items[0] else {
            Issue.record("Expected systemEvent for compaction type")
            return
        }
        #expect(message == "Context compacted (12,345 tokens): ## Goal\n1. Keep calm")
    }

    @MainActor
    @Test func streamingCompactionEndRetainsFullSummaryAndTokenCount() {
        let reducer = TimelineReducer()
        let summary = "## Goal\n1. Continue UIKit-native timeline migration\n2. Keep it calm"

        reducer.process(
            .compactionEnd(
                sessionId: "s1",
                aborted: false,
                willRetry: false,
                summary: summary,
                tokensBefore: 123_456
            )
        )

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let message) = reducer.items[0] else {
            Issue.record("Expected systemEvent for compaction_end")
            return
        }
        #expect(message == "Context compacted (123,456 tokens): \(summary)")
    }

    @MainActor
    @Test func loadSessionToolResultErrorFlag() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: "bash", args: [:],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "tr1", type: .toolResult, timestamp: "2025-01-01T00:00:01.000Z",
                       text: nil, tool: nil, args: nil, output: "error: command failed",
                       toolCallId: "tc1", toolName: "bash", isError: true, thinking: nil),
        ]
        reducer.loadSession(events)

        guard case .toolCall(_, _, _, _, _, let isError, _) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(isError)
    }

    @MainActor
    @Test func loadSessionToolArgsStored() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: "read", args: ["path": .string("/etc/hosts")],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(events)

        let args = reducer.toolArgsStore.args(for: "tc1")
        #expect(args?["path"] == .string("/etc/hosts"))
    }

    // MARK: - appendUserMessage

    @MainActor
    @Test func appendUserMessage() {
        let reducer = TimelineReducer()
        reducer.appendUserMessage("Hello from user")

        #expect(reducer.items.count == 1)
        guard case .userMessage(_, let text, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(text == "Hello from user")
    }

    // MARK: - processBatch tool output coalescing

    @MainActor
    @Test func processBatchCoalescesMultipleToolOutputs() {
        let reducer = TimelineReducer()

        // Start a tool, then send multiple outputs in a batch
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))

        reducer.processBatch([
            .toolOutput(sessionId: "s1", toolEventId: "t1", output: "line1\n", isError: false),
            .toolOutput(sessionId: "s1", toolEventId: "t1", output: "line2\n", isError: false),
            .toolOutput(sessionId: "s1", toolEventId: "t1", output: "line3\n", isError: false),
        ])

        let fullOutput = reducer.toolOutputStore.fullOutput(for: "t1")
        #expect(fullOutput == "line1\nline2\nline3\n")
    }

    @MainActor
    @Test func processBatchToolOutputWithError() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))

        reducer.processBatch([
            .toolOutput(sessionId: "s1", toolEventId: "t1", output: "ok\n", isError: false),
            .toolOutput(sessionId: "s1", toolEventId: "t1", output: "err\n", isError: true),
        ])

        guard case .toolCall(_, _, _, _, _, let isError, _) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(isError, "Error flag should propagate when any chunk is error")
    }

    // MARK: - Thinking finalization stores full text

    @MainActor
    @Test func longThinkingStoresFullTextOnAgentEnd() {
        let reducer = TimelineReducer()
        let longThinking = String(repeating: "y", count: 600) // > maxPreviewLength

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: longThinking))
        reducer.process(.agentEnd(sessionId: "s1"))

        guard case .thinking(let id, _, let hasMore, let isDone) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(hasMore)
        #expect(isDone)
        #expect(reducer.toolOutputStore.fullOutput(for: id) == longThinking)
    }

    @MainActor
    @Test func thinkingOverflowSkipsNoOpRerenders() {
        let reducer = TimelineReducer()

        let firstChunk = String(repeating: "a", count: ChatItem.maxPreviewLength + 50)
        let tailChunk = String(repeating: "b", count: 120)

        reducer.process(.agentStart(sessionId: "s1"))
        let baseline = reducer.renderVersion

        reducer.processBatch([
            .thinkingDelta(sessionId: "s1", delta: firstChunk),
        ])

        guard let firstItem = reducer.items.first,
              case .thinking(let id, let previewAfterFirst, let hasMore, _) = firstItem else {
            Issue.record("Expected thinking row after first chunk")
            return
        }
        #expect(hasMore)
        let afterFirst = reducer.renderVersion
        #expect(afterFirst > baseline)

        reducer.processBatch([
            .thinkingDelta(sessionId: "s1", delta: tailChunk),
        ])

        guard let secondItem = reducer.items.first,
              case .thinking(_, let previewAfterSecond, let hasMoreAfterSecond, _) = secondItem else {
            Issue.record("Expected thinking row after second chunk")
            return
        }
        #expect(hasMoreAfterSecond)
        #expect(previewAfterSecond == previewAfterFirst)
        #expect(reducer.renderVersion == afterFirst)

        let fullThinking = reducer.toolOutputStore.fullOutput(for: id)
        #expect(fullThinking.count == firstChunk.count + tailChunk.count)
    }

    // MARK: - Tool args stored on toolStart

    @MainActor
    @Test func toolStartStoresArgs() {
        let reducer = TimelineReducer()
        let args: [String: JSONValue] = ["command": .string("echo hello")]

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: args))

        let stored = reducer.toolArgsStore.args(for: "t1")
        #expect(stored?["command"] == .string("echo hello"))
    }

    @MainActor
    @Test func toolStartEmptyArgsNotStored() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))

        let stored = reducer.toolArgsStore.args(for: "t1")
        #expect(stored == nil, "Empty args should not be stored")
    }

    // loadFromREST system messages test removed — REST path eliminated.

    // MARK: - ChatItem preview truncation

    @MainActor
    @Test func previewTruncatesLongText() {
        let long = String(repeating: "x", count: 600)
        let preview = ChatItem.preview(long)
        #expect(preview.count == ChatItem.maxPreviewLength)
        #expect(preview.hasSuffix("…"))
    }

    @MainActor
    @Test func previewKeepsShortText() {
        let short = "hello"
        #expect(ChatItem.preview(short) == "hello")
    }

    // MARK: - ChatItem timestamps

    @MainActor
    @Test func chatItemTimestamps() {
        let now = Date()
        let user = ChatItem.userMessage(id: "1", text: "hi", timestamp: now)
        #expect(user.timestamp == now)

        let assistant = ChatItem.assistantMessage(id: "2", text: "hi", timestamp: now)
        #expect(assistant.timestamp == now)

        // Non-message items have no timestamp
        let tool = ChatItem.toolCall(id: "3", tool: "bash", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true)
        #expect(tool.timestamp == nil)

        let thinking = ChatItem.thinking(id: "4", preview: "", hasMore: false)
        #expect(thinking.timestamp == nil)

        let perm = ChatItem.permission(PermissionRequest(
            id: "5", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "x",
            risk: .low, reason: "r",
            timeoutAt: Date()
        ))
        #expect(perm.timestamp == nil)

        let resolved = ChatItem.permissionResolved(id: "6", outcome: .allowed, tool: "bash", summary: "test")
        #expect(resolved.timestamp == nil)

        let system = ChatItem.systemEvent(id: "7", message: "x")
        #expect(system.timestamp == nil)

        let error = ChatItem.error(id: "8", message: "x")
        #expect(error.timestamp == nil)
    }

    // MARK: - ToolArgsStore

    @MainActor
    @Test func toolArgsStoreClearAll() {
        let store = ToolArgsStore()
        store.set(["key": .string("val")], for: "t1")
        #expect(store.args(for: "t1") != nil)

        store.clearAll()
        #expect(store.args(for: "t1") == nil)
    }

    // MARK: - Incremental loadSession: timelineMatchesTrace correctness

    /// Every mutation path must set `timelineMatchesTrace = false` so the next
    /// `loadSession` does a full canonical rebuild instead of an incremental
    /// no-op/append. If any path forgets, stale or duplicate items appear.

    @MainActor
    @Test func processBatchBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        // Live event via processBatch
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "live"),
            .agentEnd(sessionId: "s1"),
        ])

        // Next loadSession must do full rebuild (not incremental)
        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "processBatch should break incremental mode")
    }

    @MainActor
    @Test func processSingleEventBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        reducer.process(.error(sessionId: "s1", message: "oops"))

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "process() should break incremental mode")
    }

    @MainActor
    @Test func appendUserMessageBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        reducer.appendUserMessage("optimistic send")

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "appendUserMessage should break incremental mode")
    }

    @MainActor
    @Test func removeItemBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        // Append then remove (retract optimistic message)
        let id = reducer.appendUserMessage("will retract")
        reducer.removeItem(id: id)

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "removeItem should break incremental mode")
    }

    @MainActor
    @Test func appendAudioClipBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        reducer.appendAudioClip(title: "test", fileURL: URL(filePath: "/tmp/test.wav"))

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "appendAudioClip should break incremental mode")
    }

    @MainActor
    @Test func resolvePermissionBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        reducer.resolvePermission(id: "p1", outcome: .allowed, tool: "bash", summary: "ls")

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "resolvePermission should break incremental mode")
    }

    // MARK: - Incremental loadSession: edge cases

    @MainActor
    @Test func resetClearsIncrementalTrackingState() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        // Verify incremental works before reset
        reducer.loadSession(events)
        #expect(reducer._lastLoadWasIncrementalForTesting)

        reducer.reset()

        // After reset, same events should trigger full rebuild
        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "reset should clear incremental tracking state")
    }

    @MainActor
    @Test func tracePrefixDivergenceForcesFullRebuild() {
        let reducer = TimelineReducer()
        let original = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(original)

        // Compaction rewrote history — same count but different ID at position 1
        let rewritten = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2-rewritten", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Compacted response", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(rewritten)

        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "Divergent prefix should force full rebuild")
        #expect(reducer.items.count == 2)
        guard case .assistantMessage(_, let text, _) = reducer.items[1] else {
            Issue.record("Expected rewritten assistant message")
            return
        }
        #expect(text == "Compacted response")
    }

    @MainActor
    @Test func shorterTraceForcesFullRebuild() {
        let reducer = TimelineReducer()
        let full = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(full)
        #expect(reducer.items.count == 2)

        // Server returns shorter trace (e.g., fork from earlier point)
        let shorter = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(shorter)

        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "Shorter trace should force full rebuild")
        #expect(reducer.items.count == 1)
    }

    @MainActor
    @Test func incrementalAppendWithToolCallAndResult() {
        let reducer = TimelineReducer()
        let base = makeBaseTrace()
        reducer.loadSession(base)
        let baselineVersion = reducer.renderVersion

        let extended = base + [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:02.000Z",
                       text: nil, tool: "bash", args: ["command": .string("echo hi")],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "tr1", type: .toolResult, timestamp: "2025-01-01T00:00:03.000Z",
                       text: nil, tool: nil, args: nil, output: "hi",
                       toolCallId: "tc1", toolName: "bash", isError: false, thinking: nil),
        ]
        reducer.loadSession(extended)

        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.renderVersion == baselineVersion + 1)
        #expect(reducer.items.count == 3) // user + assistant + toolCall

        guard case .toolCall(_, let tool, _, let preview, _, _, _) = reducer.items[2] else {
            Issue.record("Expected incremental tool call at index 2")
            return
        }
        #expect(tool == "bash")
        #expect(preview.contains("hi"))
        #expect(reducer.toolOutputStore.fullOutput(for: "tc1") == "hi")
        #expect(reducer.toolArgsStore.args(for: "tc1")?["command"] == .string("echo hi"))
    }

    @MainActor
    @Test func incrementalAppendWithThinkingEvent() {
        let reducer = TimelineReducer()
        let base = makeBaseTrace()
        reducer.loadSession(base)

        let longThinking = String(repeating: "z", count: 600)
        let extended = base + [
            TraceEvent(id: "th1", type: .thinking, timestamp: "2025-01-01T00:00:02.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: longThinking),
        ]
        reducer.loadSession(extended)

        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.count == 3)
        guard case .thinking(_, _, let hasMore, let isDone) = reducer.items[2] else {
            Issue.record("Expected incremental thinking at index 2")
            return
        }
        #expect(hasMore)
        #expect(isDone)
        #expect(reducer.toolOutputStore.fullOutput(for: "th1") == longThinking)
    }

    @MainActor
    @Test func consecutiveIncrementalAppendsAccumulate() {
        let reducer = TimelineReducer()
        let base = makeBaseTrace()
        reducer.loadSession(base)

        let ext1 = base + [
            TraceEvent(id: "e3", type: .assistant, timestamp: "2025-01-01T00:00:02.000Z",
                       text: "Third", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(ext1)
        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.count == 3)

        let ext2 = ext1 + [
            TraceEvent(id: "e4", type: .assistant, timestamp: "2025-01-01T00:00:03.000Z",
                       text: "Fourth", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(ext2)
        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.count == 4)

        guard case .assistantMessage(_, let text, _) = reducer.items[3] else {
            Issue.record("Expected fourth assistant message")
            return
        }
        #expect(text == "Fourth")
    }

    @MainActor
    @Test func messageEndFinalizesAssistantText() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Partial"))
        reducer.process(.messageEnd(sessionId: "s1", content: "Final answer"))

        #expect(reducer.items.count == 1)
        guard case .assistantMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected assistant message")
            return
        }
        #expect(text == "Final answer")
    }

    @MainActor
    @Test func messageEndWithoutDeltaCreatesAssistantMessage() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.messageEnd(sessionId: "s1", content: "Recovered final text"))

        #expect(reducer.items.count == 1)
        guard case .assistantMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected assistant message")
            return
        }
        #expect(text == "Recovered final text")
    }

    // MARK: - Helpers

    private func makeBaseTrace() -> [TraceEvent] {
        [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi there!", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
    }
}


