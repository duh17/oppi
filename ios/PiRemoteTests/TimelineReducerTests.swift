import Testing
import Foundation
@testable import PiRemote

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
    @Test func permissionInTimeline() {
        let reducer = TimelineReducer()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: ["command": "rm -rf /"],
            displaySummary: "bash: rm -rf /",
            risk: .critical, reason: "Destructive",
            timeoutAt: Date().addingTimeInterval(120)
        )

        reducer.process(.permissionRequest(perm))
        #expect(reducer.items.count == 1)
        guard case .permission(let req) = reducer.items[0] else {
            Issue.record("Expected permission")
            return
        }
        #expect(req.id == "p1")

        // Resolve
        reducer.resolvePermission(id: "p1", action: .deny)
        guard case .permissionResolved(_, let action) = reducer.items[0] else {
            Issue.record("Expected permissionResolved")
            return
        }
        #expect(action == .deny)
    }

    @MainActor
    @Test func retryErrorRendersAsSystemEvent() {
        let reducer = TimelineReducer()
        reducer.process(.error(sessionId: "s1", message: "Retrying (1/3): rate limit"))

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent for retry, got \(reducer.items[0])")
            return
        }
        #expect(msg.contains("Retrying"))
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

    @MainActor
    @Test func loadFromREST() {
        let reducer = TimelineReducer()
        let messages = [
            SessionMessage.stub(
                id: "m1", sessionId: "s1", role: .user,
                content: "Hello", timestamp: Date()
            ),
            SessionMessage.stub(
                id: "m2", sessionId: "s1", role: .assistant,
                content: "Hi there!", timestamp: Date()
            ),
        ]

        reducer.loadFromREST(messages)
        #expect(reducer.items.count == 2)
        guard case .userMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(text == "Hello")
    }

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
    @Test func permissionExpiredRendersAsDenied() {
        let reducer = TimelineReducer()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: ls",
            risk: .low, reason: "Read",
            timeoutAt: Date().addingTimeInterval(60)
        )

        reducer.process(.permissionRequest(perm))
        reducer.process(.permissionExpired(id: "p1"))

        guard case .permissionResolved(_, let action) = reducer.items[0] else {
            Issue.record("Expected permissionResolved after expiry")
            return
        }
        #expect(action == .deny)
    }

    // MARK: - loadFromTrace

    @MainActor
    @Test func loadFromTraceUserAndAssistant() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi there!", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadFromTrace(events)

        #expect(reducer.items.count == 2)
        guard case .userMessage(_, let userText, _) = reducer.items[0] else {
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
    @Test func loadFromTraceToolCallAndResult() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: "bash", args: ["command": .string("ls -la")],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "tr1", type: .toolResult, timestamp: "2025-01-01T00:00:01.000Z",
                       text: nil, tool: nil, args: nil, output: "file1.txt\nfile2.txt",
                       toolCallId: "tc1", toolName: "bash", isError: false, thinking: nil),
        ]
        reducer.loadFromTrace(events)

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
    @Test func loadFromTraceThinking() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "t1", type: .thinking, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil,
                       thinking: "Let me think about this carefully"),
        ]
        reducer.loadFromTrace(events)

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
    @Test func loadFromTraceLongThinkingStoresFullText() {
        let reducer = TimelineReducer()
        let longThinking = String(repeating: "x", count: 600) // > maxPreviewLength
        let events = [
            TraceEvent(id: "t1", type: .thinking, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil,
                       thinking: longThinking),
        ]
        reducer.loadFromTrace(events)

        guard case .thinking(_, _, let hasMore, _) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(hasMore)
        #expect(reducer.toolOutputStore.fullOutput(for: "t1") == longThinking)
    }

    @MainActor
    @Test func loadFromTraceSystemAndCompaction() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "s1", type: .system, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Session started", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "c1", type: .compaction, timestamp: "2025-01-01T00:00:01.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadFromTrace(events)

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
    @Test func loadFromTraceToolResultErrorFlag() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: "bash", args: [:],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "tr1", type: .toolResult, timestamp: "2025-01-01T00:00:01.000Z",
                       text: nil, tool: nil, args: nil, output: "error: command failed",
                       toolCallId: "tc1", toolName: "bash", isError: true, thinking: nil),
        ]
        reducer.loadFromTrace(events)

        guard case .toolCall(_, _, _, _, _, let isError, _) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(isError)
    }

    @MainActor
    @Test func loadFromTraceToolArgsStored() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: "read", args: ["path": .string("/etc/hosts")],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadFromTrace(events)

        let args = reducer.toolArgsStore.args(for: "tc1")
        #expect(args?["path"] == .string("/etc/hosts"))
    }

    // MARK: - appendUserMessage

    @MainActor
    @Test func appendUserMessage() {
        let reducer = TimelineReducer()
        reducer.appendUserMessage("Hello from user")

        #expect(reducer.items.count == 1)
        guard case .userMessage(_, let text, _) = reducer.items[0] else {
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

    // MARK: - loadFromREST system messages

    @MainActor
    @Test func loadFromRESTSystemMessages() {
        let reducer = TimelineReducer()
        let messages = [
            SessionMessage.stub(id: "m1", sessionId: "s1", role: .system,
                                content: "System initialized", timestamp: Date()),
        ]
        reducer.loadFromREST(messages)

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent for system role")
            return
        }
        #expect(msg == "System initialized")
    }

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

        let resolved = ChatItem.permissionResolved(id: "6", action: .allow)
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
}

// MARK: - SessionMessage factory for tests

extension SessionMessage {
    static func stub(
        id: String, sessionId: String, role: MessageRole,
        content: String, timestamp: Date
    ) -> SessionMessage {
        // Encode → decode round-trip to satisfy the Codable init with let properties
        let tsMs = timestamp.timeIntervalSince1970 * 1000
        let json = """
        {"id":"\(id)","sessionId":"\(sessionId)","role":"\(role.rawValue)","content":"\(content)","timestamp":\(tsMs)}
        """
        return try! JSONDecoder().decode(SessionMessage.self, from: json.data(using: .utf8)!)
    }
}
