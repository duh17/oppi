import Foundation
import Testing
@testable import Oppi

@Suite("QuietTimelineProjection")
struct QuietTimelineProjectionTests {
    private let timestamp = Date(timeIntervalSince1970: 0)

    @Test func finishedTurnCollapsesOnlySuccessfulToolsAndThinking() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Inspect", timestamp: timestamp),
            .thinking(id: "think-1", preview: "private reasoning", hasMore: false, isDone: true),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "ok", outputByteCount: 2, isError: false, isDone: true),
            .toolCall(id: "tool-error", tool: "bash", argsSummary: "bad", outputPreview: "failed", outputByteCount: 6, isError: true, isDone: true),
            .toolCall(id: "ask-1", tool: "ask", argsSummary: "question", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .cacheMiss(id: "cache-1", message: "Cached output unavailable"),
            .systemEvent(id: "system-1", message: "Model changed"),
            .audioClip(id: "audio-1", title: "Reply", fileURL: URL(fileURLWithPath: "/tmp/reply.m4a"), timestamp: timestamp),
            .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
        ]

        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: []
        )

        #expect(projection.fullTimelineItemIDs == items.map(\.id))
        #expect(projection.rows.map(\.id) == ["u1", QuietTimelineProjection.syntheticWorkLineID(for: "think-1"), "tool-error", "ask-1", "cache-1", "system-1", "audio-1", "a1"])
        guard case .quietWork(let workLine) = projection.rows[1] else {
            Issue.record("Expected a synthetic work line")
            return
        }
        #expect(workLine.toolCount == 1)
        #expect(workLine.thinkingCount == 1)
        #expect(workLine.sourceItemIDs == ["think-1", "tool-1"])
        #expect(workLine.activityCounts == ["bash": 1, "thinking": 1])
        #expect(workLine.turnID == "think-1")
    }

    @Test func liveTurnUpdatesWorkLineInsteadOfShowingToolRows() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "thinking", hasMore: false, isDone: false),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "", outputByteCount: 0, isError: false, isDone: false),
            .assistantMessage(id: "a1", text: "Working", timestamp: timestamp),
        ]

        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: []
        )

        #expect(projection.rows.map(\.id) == ["u1", "quiet-work-line:think-1", "a1"])
        #expect(projection.rows.contains { $0.id == "think-1" } == false)
        #expect(projection.rows.contains { $0.id == "tool-1" } == false)
        guard case .quietWork(let workLine) = projection.rows[1] else {
            Issue.record("Expected a live work line above the assistant message")
            return
        }
        #expect(workLine.toolCount == 1)
        #expect(workLine.thinkingCount == 1)
        #expect(workLine.isExpanded == false)
        #expect(workLine.isLive == false)
        #expect(workLine.turnID == "think-1")
    }

    @Test func eachAssistantMessageGetsItsOwnWorkStrip() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "one", hasMore: false, isDone: true),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "one", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .assistantMessage(id: "a1", text: "First", timestamp: timestamp),
            .thinking(id: "think-2", preview: "two", hasMore: false, isDone: true),
            .toolCall(id: "tool-2", tool: "read", argsSummary: "two", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .assistantMessage(id: "a2", text: "Second", timestamp: timestamp),
        ]
        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: []
        )
        #expect(projection.rows.map(\.id) == [
            "u1", "quiet-work-line:think-1", "a1", "quiet-work-line:think-2", "a2"
        ])
        guard case .quietWork(let first) = projection.rows[1],
              case .quietWork(let second) = projection.rows[3] else {
            Issue.record("Expected a work strip above each assistant message")
            return
        }
        #expect(first.sourceItemIDs == ["think-1", "tool-1"])
        #expect(second.sourceItemIDs == ["think-2", "tool-2"])
        #expect(first.isLive == false)
        #expect(second.isLive == false)
    }

    @Test func visibleInterruptionsSplitFoldedGroupsWithoutReorderingChronology() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "one", hasMore: false, isDone: true),
            .systemEvent(id: "system-1", message: "Model changed"),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "ok", outputByteCount: 2, isError: false, isDone: true),
            .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
        ]
        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: []
        )
        #expect(projection.rows.map(\.id) == ["u1", "quiet-work-line:think-1", "system-1", "quiet-work-line:tool-1", "a1"])
        guard case .quietWork(let firstWorkLine) = projection.rows[1],
              case .quietWork(let secondWorkLine) = projection.rows[3] else {
            Issue.record("Expected separate work strips around the visible interruption")
            return
        }
        #expect(firstWorkLine.sourceItemIDs == ["think-1"])
        #expect(secondWorkLine.sourceItemIDs == ["tool-1"])
        #expect(firstWorkLine.turnID == "think-1")
        #expect(secondWorkLine.turnID == "tool-1")
    }

    @Test func errorCacheAndAudioBoundariesAlsoSplitFoldedGroups() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "one", hasMore: false, isDone: true),
            .error(id: "error-1", message: "Tool failed"),
            .toolCall(id: "tool-2", tool: "bash", argsSummary: "two", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .cacheMiss(id: "cache-1", message: "Cache unavailable"),
            .thinking(id: "think-3", preview: "three", hasMore: false, isDone: true),
            .audioClip(id: "audio-1", title: "Reply", fileURL: URL(fileURLWithPath: "/tmp/reply.m4a"), timestamp: timestamp),
            .toolCall(id: "tool-4", tool: "read", argsSummary: "four", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .systemEvent(id: "system-1", message: "Model changed"),
            .thinking(id: "think-5", preview: "five", hasMore: false, isDone: true),
        ]

        let projection = QuietTimelineProjection.make(items: items, isQuiet: true, isBusy: false, expandedTurnIDs: [])

        #expect(projection.rows.map(\.id) == [
            "u1", "quiet-work-line:think-1", "error-1",
            "quiet-work-line:tool-2", "cache-1", "quiet-work-line:think-3",
            "audio-1", "quiet-work-line:tool-4", "system-1", "quiet-work-line:think-5",
        ])
    }

    @Test func expandingOneAssistantStripDoesNotRevealEarlierAssistantWork() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "one", hasMore: false, isDone: true),
            .assistantMessage(id: "a1", text: "First", timestamp: timestamp),
            .thinking(id: "think-2", preview: "two", hasMore: false, isDone: true),
            .assistantMessage(id: "a2", text: "Second", timestamp: timestamp),
        ]
        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: ["think-2"]
        )
        #expect(projection.rows.map(\.id) == [
            "u1", "quiet-work-line:think-1", "a1", "quiet-work-line:think-2", "think-2", "a2"
        ])
        #expect(projection.rows.contains { $0.id == "think-1" } == false)
    }

    @Test func expandedStripRetainsIdentityWhenOlderPageStartsInsideItsFoldedGroup() throws {
        let currentPage: [ChatItem] = [
            .toolCall(id: "tool-5", tool: "bash", argsSummary: "five", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .thinking(id: "think-6", preview: "six", hasMore: false, isDone: true),
            .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
        ]
        let beforePrepend = QuietTimelineProjection.make(
            items: currentPage,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: ["tool-5"]
        )
        let afterPrepend = QuietTimelineProjection.make(
            items: [
                .assistantMessage(id: "a0", text: "Earlier", timestamp: timestamp),
                .thinking(id: "think-1", preview: "one", hasMore: false, isDone: true),
                .toolCall(id: "tool-2", tool: "read", argsSummary: "two", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            ] + currentPage,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: ["tool-5"]
        )

        let beforeLine = try #require(beforePrepend.rows.compactMap { row -> QuietTimelineWorkLine? in
            guard case .quietWork(let line) = row else { return nil }
            return line
        }.first)
        let afterLine = try #require(afterPrepend.rows.compactMap { row -> QuietTimelineWorkLine? in
            guard case .quietWork(let line) = row else { return nil }
            return line
        }.first)

        #expect(beforeLine.id == "quiet-work-line:tool-5")
        #expect(afterLine.id == beforeLine.id)
        #expect(afterLine.turnID == "tool-5")
        #expect(afterLine.isExpanded)
        #expect(afterLine.sourceItemIDs == ["think-1", "tool-2", "tool-5", "think-6"])
        #expect(afterPrepend.rows.map(\.id) == [
            "a0", "quiet-work-line:tool-5", "think-1", "tool-2", "tool-5", "think-6", "a1",
        ])
    }

    @Test func liveWorkLineSummaryIncludesDuration() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "thinking", hasMore: false, isDone: false),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "", outputByteCount: 0, isError: false, isDone: false),
        ]
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: [],
            liveStartedAt: startedAt
        )
        guard case .quietWork(let workLine) = projection.rows[1] else {
            Issue.record("Expected a live work line")
            return
        }
        #expect(workLine.liveStartedAt == startedAt)
        #expect(workLine.displaySummary(now: Date(timeIntervalSince1970: 1_012)) == "1 tool, 1 thinking block · 12s")
        #expect(workLine.displaySummary(now: Date(timeIntervalSince1970: 1_075)) == "1 tool, 1 thinking block · 1m 15s")
        #expect(workLine.displaySummary(now: Date(timeIntervalSince1970: 4_723)) == "1 tool, 1 thinking block · 1h 2m 3s")
    }

    @Test func finishedWorkLineSummaryOmitsDuration() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "thinking", hasMore: false, isDone: true),
        ]
        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: [],
            liveStartedAt: Date(timeIntervalSince1970: 1_000)
        )
        guard case .quietWork(let workLine) = projection.rows[1] else {
            Issue.record("Expected a finished work line")
            return
        }
        #expect(workLine.liveStartedAt == nil)
        #expect(workLine.displaySummary(now: Date(timeIntervalSince1970: 1_012)) == "1 thinking block")
    }

    @Test func expansionIsScopedToOneTurnAndSyntheticIDIsStable() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "One", timestamp: timestamp),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "one", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .userMessage(id: "u2", text: "Two", timestamp: timestamp),
            .thinking(id: "think-2", preview: "two", hasMore: false, isDone: true),
        ]

        let collapsed = QuietTimelineProjection.make(items: items, isQuiet: true, isBusy: false, expandedTurnIDs: [])
        let expanded = QuietTimelineProjection.make(items: items, isQuiet: true, isBusy: false, expandedTurnIDs: ["tool-1"])

        #expect(collapsed.rows.map(\.id) == ["u1", "quiet-work-line:tool-1", "u2", "quiet-work-line:think-2"])
        #expect(expanded.rows.map(\.id) == ["u1", "quiet-work-line:tool-1", "tool-1", "u2", "quiet-work-line:think-2"])
        #expect(collapsed.fullTimelineItemIDs == expanded.fullTimelineItemIDs)
        #expect(collapsed.rows.contains { $0.id == "tool-1" } == false)
        #expect(expanded.rows.contains { $0.id == "tool-1" })
        guard case .quietWork(let collapsedWorkLine) = collapsed.rows[1],
              case .quietWork(let expandedWorkLine) = expanded.rows[1] else {
            Issue.record("Expected stable work-line headers in both states")
            return
        }
        #expect(collapsedWorkLine.isExpanded == false)
        #expect(expandedWorkLine.isExpanded)
        #expect(collapsed.rows.contains { $0.id == "quiet-work-line:tool-1" })
    }

    @Test func idleInterruptedToolsFoldWhileAskRowsStayVisible() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Ask", timestamp: timestamp),
            .toolCall(id: "ask-1", tool: "ask", argsSummary: "question", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .userMessage(id: "ask-answer-1", text: "Answer", timestamp: timestamp),
            .thinking(id: "thinking-1", preview: "done", hasMore: false, isDone: true),
            .toolCall(id: "interrupted-1", tool: "bash", argsSummary: "run", outputPreview: "stopped", outputByteCount: 7, isError: true, isDone: true),
        ]

        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: []
        )

        #expect(projection.rows.map(\.id) == [
            "u1", "ask-1", "ask-answer-1", "quiet-work-line:thinking-1", "interrupted-1"
        ])
        #expect(projection.rows.contains { $0.id == "quiet-work-line:thinking-1" })
        #expect(projection.rows.contains { $0.id == "interrupted-1" })
        guard case .quietWork(let workLine) = projection.rows[3] else {
            Issue.record("Expected thinking to fold before the failed tool")
            return
        }
        #expect(workLine.toolCount == 0)
        #expect(workLine.thinkingCount == 1)
    }

    @Test func idleHistoricalToolsCollapseEvenWhenTraceDidNotMarkThemDone() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Inspect", timestamp: timestamp),
            .thinking(id: "think-1", preview: "old reasoning", hasMore: false, isDone: false),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "ok", outputByteCount: 2, isError: false, isDone: false),
            .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
        ]

        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: []
        )

        #expect(projection.rows.map(\.id) == ["u1", "quiet-work-line:think-1", "a1"])
        guard case .quietWork(let workLine) = projection.rows[1] else {
            Issue.record("Expected a synthetic work line for historical tools")
            return
        }
        #expect(workLine.toolCount == 1)
        #expect(workLine.thinkingCount == 1)
    }

    @Test func fullRenderWindowCoordinatesRemainChatItemIDs() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "One", timestamp: timestamp),
            .thinking(id: "think-1", preview: "thinking", hasMore: false, isDone: true),
            .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
        ]
        let projection = QuietTimelineProjection.make(items: items, isQuiet: true, isBusy: false, expandedTurnIDs: [])

        let rows = projection.rows(forRenderedItemIDs: ["think-1"])
        #expect(rows.map(\.id) == ["quiet-work-line:think-1"])
        #expect(projection.fullTimelineItemIDs == ["u1", "think-1", "a1"])
        #expect(projection.renderedRowID(forSourceItemID: "think-1") == "quiet-work-line:think-1")
    }

    @Test func busyTextOnlyFollowUpDoesNotRelightPreviousWorkStrip() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "One", timestamp: timestamp),
            .thinking(id: "think-1", preview: "one", hasMore: false, isDone: true),
            .assistantMessage(id: "a1", text: "First", timestamp: timestamp),
            .userMessage(id: "u2", text: "Two", timestamp: timestamp),
        ]
        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: [],
            liveStartedAt: Date(timeIntervalSince1970: 1_000)
        )
        guard case .quietWork(let workLine) = projection.rows[1] else {
            Issue.record("Expected the finished first-turn strip")
            return
        }
        #expect(workLine.isLive == false)
        #expect(workLine.liveStartedAt == nil)
        #expect(projection.rows.map(\.id) == ["u1", "quiet-work-line:think-1", "a1", "u2"])
    }

    @Test func expandedLiveStripKeepsIdentityWhenAssistantArrives() {
        let liveItems: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "thinking", hasMore: false, isDone: false),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "", outputByteCount: 0, isError: false, isDone: false),
        ]
        let live = QuietTimelineProjection.make(
            items: liveItems,
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: ["think-1"]
        )
        let withAssistant = QuietTimelineProjection.make(
            items: liveItems + [.assistantMessage(id: "a1", text: "Done", timestamp: timestamp)],
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: ["think-1"]
        )
        guard case .quietWork(let liveLine) = live.rows[1],
              case .quietWork(let finishedLine) = withAssistant.rows[1] else {
            Issue.record("Expected a stable work strip before and after the assistant message")
            return
        }
        #expect(liveLine.id == finishedLine.id)
        #expect(liveLine.turnID == "think-1")
        #expect(finishedLine.turnID == "think-1")
        #expect(liveLine.isExpanded)
        #expect(finishedLine.isExpanded)
        #expect(withAssistant.rows.contains { $0.id == "tool-1" })
        #expect(finishedLine.isLive == false)
    }

    @Test func workLineCapturesOrderedActivityKindsCappedToMostRecentSample() {
        var items: [ChatItem] = [.userMessage(id: "u1", text: "Run", timestamp: timestamp)]
        for index in 0..<14 {
            items.append(.toolCall(id: "tool-\(index)", tool: "bash", argsSummary: "ls", outputPreview: "", outputByteCount: 0, isError: false, isDone: true))
        }
        items.append(.thinking(id: "think-late", preview: "late", hasMore: false, isDone: true))
        items.append(.toolCall(id: "tool-ext", tool: "plugins/mermaid", argsSummary: "render", outputPreview: "", outputByteCount: 0, isError: false, isDone: true))
        items.append(.assistantMessage(id: "a1", text: "Done", timestamp: timestamp))

        let projection = QuietTimelineProjection.make(items: items, isQuiet: true, isBusy: false, expandedTurnIDs: [])

        guard case .quietWork(let workLine) = projection.rows[1] else {
            Issue.record("Expected a synthetic work line")
            return
        }
        #expect(workLine.activities.count == QuietTimelineWorkLine.activitySampleLimit)
        #expect(workLine.activities == Array(repeating: "bash", count: 10) + ["thinking", "mermaid"])
        #expect(workLine.activityCounts == ["bash": 14, "thinking": 1, "mermaid": 1])
    }

    @Test func liveReplacementCarriesActivityKindsForward() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "thinking", hasMore: false, isDone: false),
            .toolCall(id: "tool-1", tool: "read", argsSummary: "x", outputPreview: "", outputByteCount: 0, isError: false, isDone: false),
        ]

        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: [],
            liveStartedAt: Date(timeIntervalSince1970: 1_000)
        )

        guard case .quietWork(let workLine) = projection.rows.last else {
            Issue.record("Expected a live work line")
            return
        }
        #expect(workLine.isLive)
        #expect(workLine.activities == ["thinking", "read"])
    }

    @Test func trailingFoldGroupAnchorMatchesLiveStripSelection() {
        func anchor(_ items: [ChatItem]) -> String? {
            QuietTimelineProjection.trailingFoldGroupAnchorID(in: items)
        }

        // Trailing collapsible run anchors on its first item.
        #expect(anchor([
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "t", hasMore: false, isDone: false),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "", outputByteCount: 0, isError: false, isDone: false),
        ]) == "think-1")

        // Assistant messages flush the group.
        #expect(anchor([
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "t", hasMore: false, isDone: true),
            .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
        ]) == nil)

        // Visible interruptions close the preceding group.
        #expect(anchor([
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "t", hasMore: false, isDone: true),
            .systemEvent(id: "system-1", message: "Model changed"),
            .toolCall(id: "ask-1", tool: "ask", argsSummary: "q", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
        ]) == nil)

        // Ask → wait → answer → resume gets a new trailing anchor.
        #expect(anchor([
            .userMessage(id: "u1", text: "Ask", timestamp: timestamp),
            .thinking(id: "think-1", preview: "t", hasMore: false, isDone: true),
            .toolCall(id: "ask-1", tool: "ask", argsSummary: "q", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .userMessage(id: "ask-answer-1", text: "Answer", timestamp: timestamp),
            .thinking(id: "think-2", preview: "t2", hasMore: false, isDone: true),
        ]) == "think-2")

        // Nothing collapsible → no anchor.
        #expect(anchor([.userMessage(id: "u1", text: "Hi", timestamp: timestamp)]) == nil)
        #expect(anchor([]) == nil)
    }

    @Test func onlyTrailingWorkAfterLastAssistantStaysLive() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "one", hasMore: false, isDone: true),
            .assistantMessage(id: "a1", text: "First", timestamp: timestamp),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "", outputByteCount: 0, isError: false, isDone: false),
        ]
        let projection = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: [],
            liveStartedAt: Date(timeIntervalSince1970: 1_000)
        )
        #expect(projection.rows.map(\.id) == [
            "u1", "quiet-work-line:think-1", "a1", "quiet-work-line:tool-1"
        ])
        guard case .quietWork(let settled) = projection.rows[1],
              case .quietWork(let live) = projection.rows[3] else {
            Issue.record("Expected a settled strip and a live trailing strip")
            return
        }
        #expect(settled.isLive == false)
        #expect(settled.liveStartedAt == nil)
        #expect(live.isLive)
        #expect(live.liveStartedAt == Date(timeIntervalSince1970: 1_000))
    }
}
