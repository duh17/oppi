import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer — Streaming")
struct TimelineReducerStreamingTests {

    @MainActor
    @Test func processBatchMixedEvents() {
        let reducer = TimelineReducer()

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
    @Test func processBatchCoalescesMultipleToolOutputs() {
        let reducer = TimelineReducer()

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

    @MainActor
    @Test func toolOutputOverflowNoOpSkipsRenderVersionBump() {
        let reducer = TimelineReducer()
        let toolID = "t-overflow"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolID, tool: "read", args: [:]))

        let firstChunk = String(repeating: "x", count: ToolOutputStore.perItemCap + 1_024)
        reducer.processBatch([
            .toolOutput(sessionId: "s1", toolEventId: toolID, output: firstChunk, isError: false),
        ])

        let versionAfterFirstChunk = reducer.renderVersion
        let outputAfterFirstChunk = reducer.toolOutputStore.fullOutput(for: toolID)

        #expect(!outputAfterFirstChunk.isEmpty)
        #expect(outputAfterFirstChunk.hasSuffix(ToolOutputStore.truncationMarker))

        reducer.processBatch([
            .toolOutput(sessionId: "s1", toolEventId: toolID, output: "ignored-after-cap", isError: false),
        ])

        #expect(
            reducer.renderVersion == versionAfterFirstChunk,
            "No-op tool output after per-item cap should not bump renderVersion"
        )
        #expect(reducer.toolOutputStore.fullOutput(for: toolID) == outputAfterFirstChunk)
    }

    @MainActor
    @Test func longThinkingStaysInThinkingPreviewOnAgentEnd() {
        let reducer = TimelineReducer()
        let longThinking = String(repeating: "y", count: 600) // > maxPreviewLength

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: longThinking))
        reducer.process(.agentEnd(sessionId: "s1"))

        guard case .thinking(_, let preview, let hasMore, let isDone) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(hasMore)
        #expect(isDone)
        #expect(preview == longThinking)
    }

    @MainActor
    @Test func thinkingOverflowContinuesUpdatingPreview() {
        let reducer = TimelineReducer()

        let firstChunk = String(repeating: "a", count: ChatItem.maxPreviewLength + 50)
        let tailChunk = String(repeating: "b", count: 120)

        reducer.process(.agentStart(sessionId: "s1"))
        let baseline = reducer.renderVersion

        reducer.processBatch([
            .thinkingDelta(sessionId: "s1", delta: firstChunk),
        ])

        guard let firstItem = reducer.items.first,
              case .thinking(_, let previewAfterFirst, let hasMore, _) = firstItem else {
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
        #expect(previewAfterSecond == firstChunk + tailChunk)
        #expect(previewAfterSecond.count > previewAfterFirst.count)
        #expect(reducer.renderVersion > afterFirst)
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
}
