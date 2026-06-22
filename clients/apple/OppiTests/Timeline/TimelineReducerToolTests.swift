import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer — Tools")
@MainActor
struct TimelineReducerToolTests {

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

    @Test func whitespaceOnlyTextBeforeToolDiscarded() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "\n\n"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: "t1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Done!"))
        reducer.process(.agentEnd(sessionId: "s1"))

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

    @Test func orphanedToolIsClosedAsErrorOnAgentEnd() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "read", args: [:]))
        // No toolEnd before agentEnd
        reducer.process(.agentEnd(sessionId: "s1"))

        guard case .toolCall(_, _, _, let preview, _, let isError, let isDone) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(isDone, "Orphaned tool should be marked done on agentEnd")
        #expect(isError, "Orphaned tool should not render as a green success")
        #expect(preview.contains("stopped before returning"), "Orphaned tool should explain why no output/log is available")
        #expect(reducer.toolOutputStore.fullOutput(for: "t1").contains("stopped before returning"))
    }

    @Test func toolStartStoresArgs() {
        let reducer = TimelineReducer()
        let args: [String: JSONValue] = ["command": .string("echo hello")]

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: args))

        let stored = reducer.toolArgsStore.args(for: "t1")
        #expect(stored?["command"] == .string("echo hello"))
    }

    @Test func toolStartEmptyArgsNotStored() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))

        let stored = reducer.toolArgsStore.args(for: "t1")
        #expect(stored == nil, "Empty args should not be stored")
    }

    @Test func extensionToolsExpandedAppliesToCurrentAndFutureToolRows() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(
            sessionId: "s1",
            toolEventId: "tool-1",
            tool: "bash",
            args: ["command": .string("pwd")]
        ))
        #expect(!reducer.expandedItemIDs.contains("tool-1"))

        reducer.applyExtensionToolsExpanded(true)
        #expect(reducer.expandedItemIDs.contains("tool-1"))

        reducer.process(.toolStart(
            sessionId: "s1",
            toolEventId: "tool-2",
            tool: "bash",
            args: ["command": .string("ls")]
        ))
        #expect(reducer.expandedItemIDs.contains("tool-2"))

        reducer.applyExtensionToolsExpanded(false)
        #expect(!reducer.expandedItemIDs.contains("tool-1"))
        #expect(!reducer.expandedItemIDs.contains("tool-2"))
    }

    @Test func toolEndStoresDetails() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "plot", args: [:]))
        reducer.process(.toolEnd(
            sessionId: "s1",
            toolEventId: "t1",
            details: .object([
                "ui": .array([
                    .object([
                        "id": .string("chart-1"),
                        "kind": .string("chart"),
                        "version": .number(1),
                    ]),
                ]),
            ])
        ))

        let stored = reducer.toolDetailsStore.details(for: "t1")
        #expect(stored?.objectValue?["ui"]?.arrayValue?.count == 1)
    }

    @Test func toolEndWithoutDetailsPreservesToolOutputDetails() {
        let reducer = TimelineReducer()
        let mediaDetails: JSONValue = .object([
            "media": .array([
                .object([
                    "kind": .string("image"),
                    "id": .string("att-image-1"),
                    "mimeType": .string("image/png"),
                ])
            ])
        ])

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "read", args: ["path": .string("plot.png")]))
        reducer.process(.toolOutput(
            sessionId: "s1",
            toolEventId: "t1",
            output: "",
            isError: false,
            details: mediaDetails
        ))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: "t1"))

        #expect(reducer.toolDetailsStore.details(for: "t1") == mediaDetails)
    }

    @Test func toolArgsStoreClearAll() {
        let store = ToolArgsStore()
        store.set(["key": .string("val")], for: "t1")
        #expect(store.args(for: "t1") != nil)

        store.clearAll()
        #expect(store.args(for: "t1") == nil)
    }

    @Test func toolOutputForUnknownIdIsStoredButNoItemCreated() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: "orphan", output: "data", isError: false))
        reducer.process(.agentEnd(sessionId: "s1"))

        let toolItems = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(toolItems.isEmpty)
        #expect(reducer.toolOutputStore.fullOutput(for: "orphan") == "data")
    }

    @Test func toolEndForUnknownIdIsIgnored() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: "nonexistent"))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.items.isEmpty)
    }

    @Test func loadSessionMarksToolCallWithoutResultAsErrorWithDiagnostic() {
        let reducer = TimelineReducer()
        let events = traceWithToolCallWithoutResult()

        reducer.loadSession(events)

        guard case .toolCall(_, _, _, let preview, _, let isError, let isDone) = reducer.items.first else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(isDone, "Loaded orphaned tool should be closed")
        #expect(isError, "Loaded orphaned tool should not render as a green success")
        #expect(preview.contains("stopped before returning"), "Loaded orphaned tool should explain missing output")
    }

    @Test func loadSessionCanKeepToolCallWithoutResultOpenWhileSessionIsRunning() {
        let reducer = TimelineReducer()
        let events = traceWithToolCallWithoutResult()

        reducer.loadSession(events, finalizeOpenTools: false)

        guard case .toolCall(_, _, _, let preview, _, let isError, let isDone) = reducer.items.first else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(!isDone, "Running session history should keep missing-result tools open")
        #expect(!isError, "Running session history should not mark in-flight tools as failed")
        #expect(preview.isEmpty)
        #expect(reducer.needsTraceProjectionRefresh(finalizeOpenTools: true))
    }

    @Test func realTraceResultReplacesSyntheticStoppedDiagnostic() {
        let reducer = TimelineReducer()
        let openTrace = traceWithToolCallWithoutResult()
        let completedTrace = openTrace + [
            TraceEvent(
                id: "result-missing-result", type: .toolResult, timestamp: "2026-01-01T00:00:02Z",
                output: "real output", toolCallId: "missing-result", toolName: "web_search_read",
                isError: false
            ),
        ]

        reducer.loadSession(openTrace)
        #expect(reducer.toolOutputStore.fullOutput(for: "missing-result").contains("stopped before returning"))

        reducer.loadSession(completedTrace)

        #expect(reducer.toolOutputStore.fullOutput(for: "missing-result") == "real output")
        guard case .toolCall(_, _, _, let preview, _, let isError, let isDone) = reducer.items.first else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(isDone)
        #expect(!isError)
        #expect(preview == "real output")
    }

    private func traceWithToolCallWithoutResult() -> [TraceEvent] {
        let toolId = "missing-result"
        return [
            TraceEvent(
                id: toolId, type: .toolCall, timestamp: "2026-01-01T00:00:01Z",
                text: nil, tool: "web_search_read",
                args: ["query": .string("Aristotle practice")],
                output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ),
        ]
    }

    @Test func traceToolResultDetailsPopulatesToolDetailsStore() {
        let reducer = TimelineReducer()
        let toolId = "tc-ext-1"
        let details: JSONValue = .object([
            "expandedText": .string("# My Todo\n\nCreated successfully"),
            "presentationFormat": .string("markdown"),
        ])

        let events: [TraceEvent] = [
            TraceEvent(
                id: "u1", type: .user, timestamp: "2026-01-01T00:00:00Z",
                text: "create a todo", tool: nil, args: nil,
                output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ),
            TraceEvent(
                id: toolId, type: .toolCall, timestamp: "2026-01-01T00:00:01Z",
                text: nil, tool: "todo",
                args: ["action": .string("create"), "title": .string("test")],
                output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ),
            TraceEvent(
                id: "r1", type: .toolResult, timestamp: "2026-01-01T00:00:02Z",
                text: nil, tool: nil, args: nil,
                output: "Todo created", toolCallId: toolId, toolName: "todo",
                isError: false, details: details, thinking: nil
            ),
        ]

        reducer.loadSession(events)

        // Details should be stored keyed by toolCallId (matchId)
        let stored = reducer.toolDetailsStore.details(for: toolId)
        #expect(stored == details)
    }

    // MARK: - Write tool args persistence

    @Test func writeToolArgsContentSurvivesToolUpdateThenToolStart() {
        // The server first sends tool_update while the model is still
        // streaming arguments, then tool_start when execution actually begins.
        // Verify args (especially content) survive that transition.
        let reducer = TimelineReducer()
        let toolId = "write-1"
        let writeArgs: [String: JSONValue] = [
            "path": .string("docs/guide.md"),
            "content": .string("# Guide\n\nSome **bold** text."),
        ]

        reducer.process(.agentStart(sessionId: "s1"))

        reducer.process(.toolUpdate(sessionId: "s1", toolEventId: toolId, tool: "write", args: writeArgs))
        #expect(reducer.toolArgsStore.args(for: toolId)?["content"]?.stringValue == "# Guide\n\nSome **bold** text.")
        #expect(reducer.toolStartTime(for: toolId) == nil)

        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "write", args: writeArgs))
        #expect(reducer.toolArgsStore.args(for: toolId)?["content"]?.stringValue == "# Guide\n\nSome **bold** text.")
        #expect(reducer.toolStartTime(for: toolId) != nil)

        // Tool completes
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: toolId, output: "Wrote 28 bytes", isError: false))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: toolId))

        // Args should still be available after tool completion
        #expect(reducer.toolArgsStore.args(for: toolId)?["content"]?.stringValue == "# Guide\n\nSome **bold** text.")
        #expect(reducer.toolArgsStore.args(for: toolId)?["path"]?.stringValue == "docs/guide.md")
    }

    @Test func streamingToolUpdateCapsLargePreviewArgsUntilExecutionStarts() {
        let reducer = TimelineReducer()
        let toolId = "write-large-preview"
        let largeContent = String(repeating: "x", count: ToolArgsStore.maxPreviewStringBytes + 1_000)
        let args: [String: JSONValue] = [
            "path": .string("docs/large.md"),
            "content": .string(largeContent),
        ]

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolUpdate(sessionId: "s1", toolEventId: toolId, tool: "write", args: args))

        let previewContent = reducer.toolArgsStore.args(for: toolId)?["content"]?.stringValue
        #expect(previewContent?.utf8.count == ToolArgsStore.maxPreviewStringBytes)
        #expect(reducer.toolArgsStore.args(for: toolId)?["path"]?.stringValue == "docs/large.md")

        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "write", args: args))
        #expect(reducer.toolArgsStore.args(for: toolId)?["content"]?.stringValue?.utf8.count == largeContent.utf8.count)
    }

    @Test func editPreviewTitleUsesUpdatedPathBeforeExecutionStart() {
        let reducer = TimelineReducer()
        let toolId = "edit-preview-1"
        let editArgs: [String: JSONValue] = [
            "path": .string("server/src/routes/sessions.ts"),
            "edits": .array([
                .object([
                    "oldText": .string("old line"),
                    "newText": .string("new line"),
                ]),
            ]),
        ]

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolUpdate(sessionId: "s1", toolEventId: toolId, tool: "edit", args: editArgs))

        guard let item = reducer.items.first(where: {
            if case .toolCall(let id, _, _, _, _, _, _) = $0 { return id == toolId }
            return false
        }),
        case .toolCall(_, let tool, let argsSummary, let outputPreview, _, let isError, let isDone) = item else {
            Issue.record("Expected preview toolCall item")
            return
        }

        let config = ToolPresentationBuilder.build(
            itemID: toolId,
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            context: .init(
                args: reducer.toolArgsStore.args(for: toolId),
                expandedItemIDs: [],
                fullOutput: reducer.toolOutputStore.fullOutput(for: toolId),
                isLoadingOutput: false
            )
        )

        #expect(config.title == "server/src/routes/sessions.ts")
        #expect(reducer.toolStartTime(for: toolId) == nil)
    }

    @Test func writeToolArgsContentSurvivesTraceRoundTrip() {
        // When loading a session from trace, the write tool's args (including
        // content) should be available for rendering as markdown.
        let reducer = TimelineReducer()
        let toolId = "write-md"
        let markdownContent = "# Research\n\n## Problem\n\nHeaders too large."
        let events: [TraceEvent] = [
            TraceEvent(
                id: "u1", type: .user, timestamp: "2026-01-01T00:00:00Z",
                text: "write a research doc", tool: nil, args: nil,
                output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ),
            TraceEvent(
                id: toolId, type: .toolCall, timestamp: "2026-01-01T00:00:01Z",
                text: nil, tool: "write",
                args: [
                    "path": .string("research/typography.md"),
                    "content": .string(markdownContent),
                ],
                output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ),
            TraceEvent(
                id: "r1", type: .toolResult, timestamp: "2026-01-01T00:00:02Z",
                text: nil, tool: nil, args: nil,
                output: "Wrote 45 bytes to research/typography.md",
                toolCallId: toolId, toolName: "write",
                isError: false, thinking: nil
            ),
        ]

        reducer.loadSession(events)

        // After loading from trace, args should have content for markdown rendering
        let storedArgs = reducer.toolArgsStore.args(for: toolId)
        #expect(storedArgs?["content"]?.stringValue == markdownContent,
                "Write tool content must survive trace round-trip for markdown rendering")
        #expect(storedArgs?["path"]?.stringValue == "research/typography.md")

        // The tool should be done
        guard case .toolCall(_, let tool, _, _, _, _, let isDone) = reducer.items.first(where: {
            if case .toolCall(let id, _, _, _, _, _, _) = $0 { return id == toolId }
            return false
        }) else {
            Issue.record("Expected toolCall item for write tool")
            return
        }
        #expect(tool == "write")
        #expect(isDone)
    }

    // MARK: - Replace mode (shell preview)

    @Test func toolOutputReplaceModeOverwritesStore() {
        let reducer = TimelineReducer()
        let toolId = "tool-shell"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: ["command": "find /"]))
        // Normal append
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: toolId, output: "line1\nline2\n", isError: false))
        #expect(reducer.toolOutputStore.fullOutput(for: toolId) == "line1\nline2\n")

        // Replace mode (server switched to tail preview)
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: toolId, output: "line99\nline100\n", isError: false, mode: .replace, truncated: true, totalBytes: 50000))
        #expect(reducer.toolOutputStore.fullOutput(for: toolId) == "line99\nline100\n")

        reducer.process(.toolEnd(sessionId: "s1", toolEventId: toolId))
        reducer.process(.agentEnd(sessionId: "s1"))

        let toolItems = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(toolItems.count == 1)

        guard case .toolCall(_, let tool, _, let preview, let outputByteCount, _, let isDone) = toolItems[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tool == "bash")
        #expect(preview.contains("line99") || preview.contains("line100"))
        #expect(outputByteCount == 50000)
        #expect(reducer.toolOutputStore.hasPreviewOnlyOutput(for: toolId))
        #expect(isDone)
    }

    @Test func toolOutputReplaceModeInBatch() {
        let reducer = TimelineReducer()
        let toolId = "tool-batch"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: [:]))

        // Batch with mixed append and replace — replace should win
        reducer.processBatch([
            .toolOutput(sessionId: "s1", toolEventId: toolId, output: "early\n", isError: false),
            .toolOutput(sessionId: "s1", toolEventId: toolId, output: "tail preview\n", isError: false, mode: .replace, truncated: true, totalBytes: 10000),
        ])

        #expect(reducer.toolOutputStore.fullOutput(for: toolId) == "tail preview\n")
        #expect(reducer.toolOutputStore.outputByteCount(for: toolId) == 10000)
        #expect(reducer.toolOutputStore.hasPreviewOnlyOutput(for: toolId))
    }

    @Test func traceToolResultWithoutDetailsLeavesStoreEmpty() {
        let reducer = TimelineReducer()
        let toolId = "tc-bash-1"

        let events: [TraceEvent] = [
            TraceEvent(
                id: "u1", type: .user, timestamp: "2026-01-01T00:00:00Z",
                text: "list files", tool: nil, args: nil,
                output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ),
            TraceEvent(
                id: toolId, type: .toolCall, timestamp: "2026-01-01T00:00:01Z",
                text: nil, tool: "bash", args: ["command": .string("ls")],
                output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ),
            TraceEvent(
                id: "r1", type: .toolResult, timestamp: "2026-01-01T00:00:02Z",
                text: nil, tool: nil, args: nil,
                output: "file1.txt", toolCallId: toolId, toolName: "bash",
                isError: false, thinking: nil
            ),
        ]

        reducer.loadSession(events)

        let stored = reducer.toolDetailsStore.details(for: toolId)
        #expect(stored == nil)
    }
}
