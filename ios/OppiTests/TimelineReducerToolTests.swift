import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer — Tools")
struct TimelineReducerToolTests {

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

    @MainActor
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

    @MainActor
    @Test func toolArgsStoreClearAll() {
        let store = ToolArgsStore()
        store.set(["key": .string("val")], for: "t1")
        #expect(store.args(for: "t1") != nil)

        store.clearAll()
        #expect(store.args(for: "t1") == nil)
    }

    @MainActor
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

    @MainActor
    @Test func toolEndForUnknownIdIsIgnored() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: "nonexistent"))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.items.isEmpty)
    }
}
