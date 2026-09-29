import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer — Streaming")
@MainActor
struct TimelineReducerStreamingTests {

    @Test func processBatchMixedEvents() {
        let reducer = TimelineReducer()

        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .thinkingDelta(sessionId: "s1", delta: "hmm "),
            .thinkingDelta(sessionId: "s1", delta: "ok"),
            .textDelta(sessionId: "s1", delta: "Answer: "),
            .textDelta(sessionId: "s1", delta: "42"),
            .toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": "echo hi"]),
            .toolOutput(.init(sessionId: "s1", toolEventId: "t1", output: "hi\n", isError: false)),
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

    @Test func indexedThinkingDeltasCreateSeparateThinkingRowsAroundTools() {
        let reducer = TimelineReducer()

        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .thinkingDelta(sessionId: "s1", delta: "first thought", contentIndex: 0),
            .textDelta(sessionId: "s1", delta: "Searching."),
            .toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": "echo hi"]),
            .toolEnd(sessionId: "s1", toolEventId: "t1"),
            .thinkingDelta(sessionId: "s1", delta: "second thought", contentIndex: 2),
            .textDelta(sessionId: "s1", delta: "Done."),
            .agentEnd(sessionId: "s1"),
        ])

        #expect(reducer.items.count == 5)
        guard case .thinking(_, let firstThinking, _, let firstDone) = reducer.items[0] else {
            Issue.record("Expected first thinking row")
            return
        }
        guard case .assistantMessage(_, let firstText, _) = reducer.items[1] else {
            Issue.record("Expected assistant text before tool")
            return
        }
        guard case .toolCall(_, let tool, _, _, _, _, _) = reducer.items[2] else {
            Issue.record("Expected tool row")
            return
        }
        guard case .thinking(_, let secondThinking, _, let secondDone) = reducer.items[3] else {
            Issue.record("Expected second thinking row")
            return
        }
        guard case .assistantMessage(_, let secondText, _) = reducer.items[4] else {
            Issue.record("Expected assistant text after tool")
            return
        }

        #expect(firstThinking == "first thought")
        #expect(firstDone)
        #expect(firstText == "Searching.")
        #expect(tool == "bash")
        #expect(secondThinking == "second thought")
        #expect(secondDone)
        #expect(secondText == "Done.")
    }

    /// GPT often streams a short reasoning summary, then spends a long time on
    /// tool arguments before message_end. The thinking row must stop streaming
    /// as soon as the next content block starts, on both reducer paths.
    @Test(arguments: [false, true])
    func thinkingFinalizesWhenNextBlockStartsBeforeMessageEnd(batched: Bool) {
        let reducer = TimelineReducer()
        let apply: ([AgentEvent]) -> Void = { events in
            if batched { reducer.processBatch(events) } else { events.forEach(reducer.process) }
        }

        apply([
            .agentStart(sessionId: "s1"),
            .thinkingDelta(sessionId: "s1", delta: "**Verifying tree equality**"),
            .toolUpdate(sessionId: "s1", toolEventId: "t1", tool: "edit", args: ["path": .string("a.md")]),
        ])
        guard case .thinking(_, _, _, let doneAtToolPreview) = reducer.items[0] else {
            Issue.record("Expected thinking row, got \(reducer.items)")
            return
        }
        #expect(doneAtToolPreview)

        apply([
            .thinkingDelta(sessionId: "s1", delta: "second"),
            .textDelta(sessionId: "s1", delta: "Answer"),
        ])
        #expect(reducer.items.count == 4)
        guard case .thinking(_, let second, _, let doneAtText) = reducer.items[2] else {
            Issue.record("Expected second thinking row, got \(reducer.items)")
            return
        }
        #expect(second == "second")
        #expect(doneAtText)

        // A later thinking block starts a fresh live row instead of reopening.
        apply([.thinkingDelta(sessionId: "s1", delta: "third")])
        guard case .thinking(_, let third, _, let thirdDone) = reducer.items.last else {
            Issue.record("Expected live third thinking row, got \(reducer.items)")
            return
        }
        #expect(reducer.items.count == 5)
        #expect(third == "third")
        #expect(!thirdDone)

        // Canonical message_end adopts the early-finalized rows in place.
        let thinkingIDs = reducer.items.compactMap { item -> String? in
            if case .thinking(let id, _, _, _) = item { return id }
            return nil
        }
        reducer.expandedItemIDs.insert(thinkingIDs[0])
        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "Answer",
            assistantContent: [
                AssistantMessageContentPart(kind: "thinking", content: "**Verifying tree equality**", contentIndex: 0, id: "e-0"),
                AssistantMessageContentPart(kind: "tool", contentIndex: 1, toolCallId: "t1", id: "t1"),
                AssistantMessageContentPart(kind: "thinking", content: "second", contentIndex: 2, id: "e-2"),
                AssistantMessageContentPart(kind: "text", content: "Answer", contentIndex: 3, id: "e-3"),
                AssistantMessageContentPart(kind: "thinking", content: "third", contentIndex: 4, id: "e-4"),
            ]
        ))
        #expect(reducer.items.map(\.id) == ["e-0", "t1", "e-2", "e-3", "e-4"])
        #expect(reducer.expandedItemIDs.contains("e-0"))
        #expect(reducer.items.allSatisfy { item in
            if case .thinking(_, _, _, let isDone) = item { return isDone }
            return true
        })
    }

    @Test func indexedThinkingDeltasSplitWithinOneCoalescedBatch() {
        let reducer = TimelineReducer()

        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .thinkingDelta(sessionId: "s1", delta: "first", contentIndex: 0),
            .thinkingDelta(sessionId: "s1", delta: "second", contentIndex: 1),
            .agentEnd(sessionId: "s1"),
        ])

        #expect(reducer.items.count == 2)
        guard case .thinking(_, let first, _, let firstDone) = reducer.items[0],
              case .thinking(_, let second, _, let secondDone) = reducer.items[1] else {
            Issue.record("Expected two thinking rows")
            return
        }
        #expect(first == "first")
        #expect(firstDone)
        #expect(second == "second")
        #expect(secondDone)
    }

    @Test func processBatchCoalescesMultipleToolOutputs() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))

        reducer.processBatch([
            .toolOutput(.init(sessionId: "s1", toolEventId: "t1", output: "line1\n", isError: false)),
            .toolOutput(.init(sessionId: "s1", toolEventId: "t1", output: "line2\n", isError: false)),
            .toolOutput(.init(sessionId: "s1", toolEventId: "t1", output: "line3\n", isError: false)),
        ])

        let fullOutput = reducer.toolOutputStore.fullOutput(for: "t1")
        #expect(fullOutput == "line1\nline2\nline3\n")
    }

    @Test func processBatchToolOutputWithError() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))

        reducer.processBatch([
            .toolOutput(.init(sessionId: "s1", toolEventId: "t1", output: "ok\n", isError: false)),
            .toolOutput(.init(sessionId: "s1", toolEventId: "t1", output: "err\n", isError: true)),
        ])

        guard case .toolCall(_, _, _, _, _, let isError, _) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(isError, "Error flag should propagate when any chunk is error")
    }

    @Test func largeToolOutputAppendStoresFullContentAndBumpsRenderVersion() {
        let reducer = TimelineReducer()
        let toolID = "t-overflow"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolID, tool: "read", args: [:]))

        let firstChunk = String(repeating: "x", count: ToolOutputStore.totalCap + 1_024)
        reducer.processBatch([
            .toolOutput(.init(sessionId: "s1", toolEventId: toolID, output: firstChunk, isError: false)),
        ])

        let versionAfterFirstChunk = reducer.renderVersion
        let outputAfterFirstChunk = reducer.toolOutputStore.fullOutput(for: toolID)

        #expect(outputAfterFirstChunk == firstChunk)

        reducer.processBatch([
            .toolOutput(.init(sessionId: "s1", toolEventId: toolID, output: "appended-after-large-output", isError: false)),
        ])

        #expect(
            reducer.renderVersion > versionAfterFirstChunk,
            "Appending after a large output should still bump renderVersion"
        )
        #expect(reducer.toolOutputStore.fullOutput(for: toolID) == firstChunk + "appended-after-large-output")
    }

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
