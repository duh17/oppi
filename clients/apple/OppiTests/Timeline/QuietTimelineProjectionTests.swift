import Foundation
import Testing
@testable import Oppi

@Suite("QuietTimelineProjection")
struct QuietTimelineProjectionTests {
    private let timestamp = Date(timeIntervalSince1970: 0)

    @Test func finishedTurnFoldsSuccessfulWorkAndKeepsActionableRows() throws {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Inspect", timestamp: timestamp),
            .thinking(id: "think-1", preview: "private reasoning", hasMore: false, isDone: true),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "ok", outputByteCount: 2, isError: false, isDone: true),
            .toolCall(id: "tool-error", tool: "bash", argsSummary: "bad", outputPreview: "failed", outputByteCount: 6, isError: true, isDone: true),
            .toolCall(id: "ask-1", tool: "ask", argsSummary: "question", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .error(id: "error-1", message: "Session error"),
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
        #expect(projection.rows.map(\.id) == [
            "u1", "quiet-work-line:think-1", "ask-1", "error-1",
            "cache-1", "system-1", "audio-1", "a1",
        ])
        let workLine = try #require(workLines(in: projection).first)
        #expect(workLine.sourceItemIDs == ["think-1", "tool-1", "tool-error"])
        #expect(workLine.buckets == [.init(kind: .tooling, count: 2)])
        #expect(workLine.wordsSummary(now: timestamp) == "run 2 tools")
    }

    @Test func failedToolStaysInOneStripBetweenAssistantMessages() throws {
        let items: [ChatItem] = [
            .assistantMessage(id: "a0", text: "Starting", timestamp: timestamp),
            .toolCall(id: "bash-ok", tool: "bash", argsSummary: "true", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .toolCall(id: "bash-failed", tool: "bash", argsSummary: "false", outputPreview: "exit 1", outputByteCount: 6, isError: true, isDone: true),
            .toolCall(id: "grep-1", tool: "grep", argsSummary: "needle", outputPreview: "match", outputByteCount: 5, isError: false, isDone: true),
            .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
        ]

        let collapsed = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: []
        )
        let expanded = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: ["bash-ok"]
        )

        #expect(collapsed.rows.map(\.id) == ["a0", "quiet-work-line:bash-ok", "a1"])
        let workLine = try #require(workLines(in: collapsed).first)
        #expect(workLine.sourceItemIDs == ["bash-ok", "bash-failed", "grep-1"])
        #expect(workLine.buckets == [
            .init(kind: .tooling, count: 3),
        ])
        #expect(!collapsed.rows.contains { $0.id == "bash-failed" })
        #expect(collapsed.renderedRowID(forSourceItemID: "bash-failed") == "quiet-work-line:bash-ok")
        #expect(expanded.rows.map(\.id) == [
            "a0", "quiet-work-line:bash-ok", "bash-ok", "bash-failed", "grep-1", "a1",
        ])
    }

    @Test func liveThinkingOnlyGroupShowsThinkingStatus() throws {
        let projection = QuietTimelineProjection.make(
            items: [
                .assistantMessage(id: "a0", text: "Earlier", timestamp: Date(timeIntervalSince1970: 1_000)),
                .thinking(id: "think-live", preview: "hidden", hasMore: true, isDone: false),
            ],
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: []
        )

        #expect(projection.rows.map(\.id) == ["a0", "quiet-work-line:think-live"])
        let line = try #require(workLines(in: projection).last)
        #expect(line.isThinkingOnly)
        #expect(line.isLive)
        #expect(line.wordsSummary(now: Date(timeIntervalSince1970: 1_007)) == "Thinking… · 7s")
    }

    @Test func historicalThinkingOnlyGroupsKeepAFinishedThought() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_012)
        let projection = QuietTimelineProjection.make(
            items: [
                .userMessage(id: "u1", text: "Think", timestamp: start),
                .thinking(id: "think-1", preview: "hidden", hasMore: false, isDone: true),
                .assistantMessage(id: "a1", text: "Done", timestamp: end),
            ],
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: []
        )

        #expect(projection.rows.map(\.id) == ["u1", "quiet-work-line:think-1", "a1"])
        let line = try #require(workLines(in: projection).first)
        #expect(line.isThinkingOnly)
        #expect(!line.isLive)
        #expect(line.liveStartedAt == start)
        #expect(line.intervalEndedAt == end)
        #expect(line.wordsSummary(now: Date(timeIntervalSince1970: 9_999)) == "Thought · 12s")
    }

    @Test func bucketSummaryGroupsBashAndOtherTools() throws {
        let projection = QuietTimelineProjection.make(
            items: [
                .toolCall(id: "read-1", tool: "functions.read", argsSummary: "one", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
                .toolCall(id: "read-2", tool: "read", argsSummary: "two", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
                .toolCall(id: "bash-1", tool: "bash", argsSummary: "one", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
                .toolCall(id: "grep-1", tool: "grep", argsSummary: "one", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
                .toolCall(id: "mermaid-1", tool: "extensions/mermaid", argsSummary: "one", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            ],
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: []
        )

        let line = try #require(workLines(in: projection).first)
        #expect(line.buckets == [
            .init(kind: .read, count: 2),
            .init(kind: .tooling, count: 3),
        ])
        #expect(line.wordsSummary(now: timestamp) == "read 2 files  run 3 tools")
    }

    @Test func editSummaryUsesStoredStatsWhenEveryEditHasArgs() throws {
        let argsByID: [String: [String: JSONValue]] = [
            "edit-1": editArgs(old: "old\nline", new: "new\nline\nextra"),
            "edit-2": editArgs(old: "remove", new: "replace"),
        ]
        let projection = QuietTimelineProjection.make(
            items: [
                .toolCall(id: "edit-1", tool: "edit", argsSummary: "one", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
                .toolCall(id: "edit-2", tool: "edit", argsSummary: "two", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            ],
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: [],
            toolArgs: { argsByID[$0] }
        )

        let line = try #require(workLines(in: projection).first)
        #expect(line.buckets == [
            .init(kind: .edit, count: 2, editStats: .init(added: 3, removed: 2)),
        ])
        #expect(line.wordsSummary(now: timestamp) == "edit +3 −2")
    }

    @Test func editSummaryFallsBackToFileCountWhenAnyStatsAreMissing() throws {
        let projection = QuietTimelineProjection.make(
            items: [
                .toolCall(id: "edit-1", tool: "edit", argsSummary: "one", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
                .toolCall(id: "edit-2", tool: "edit", argsSummary: "two", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            ],
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: [],
            toolArgs: { id in id == "edit-1" ? editArgs(old: "a", new: "b") : nil }
        )

        let line = try #require(workLines(in: projection).first)
        #expect(line.buckets == [.init(kind: .edit, count: 2)])
        #expect(line.wordsSummary(now: timestamp) == "edit 2")
    }

    @Test func eachAssistantBoundaryKeepsHistoricalStripsBetweenReplies() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
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
            "u1", "quiet-work-line:tool-1", "a1", "quiet-work-line:think-2", "a2",
        ])
        #expect(workLines(in: projection).allSatisfy { !$0.isLive })
    }

    @Test func visibleInterruptionsSplitGroupsAndKeepThinkingOnlySide() throws {
        let projection = QuietTimelineProjection.make(
            items: [
                .userMessage(id: "u1", text: "Run", timestamp: timestamp),
                .thinking(id: "think-1", preview: "one", hasMore: false, isDone: true),
                .systemEvent(id: "system-1", message: "Model changed"),
                .toolCall(id: "tool-1", tool: "bash", argsSummary: "ls", outputPreview: "ok", outputByteCount: 2, isError: false, isDone: true),
                .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
            ],
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: []
        )

        #expect(projection.rows.map(\.id) == [
            "u1", "quiet-work-line:think-1", "system-1", "quiet-work-line:tool-1", "a1",
        ])
        #expect(try #require(workLines(in: projection).first).sourceItemIDs == ["think-1"])
        #expect(try #require(workLines(in: projection).last).sourceItemIDs == ["tool-1"])
    }

    @Test func expansionRestoresThinkingAndToolsForTheSelectedStrip() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: timestamp),
            .thinking(id: "think-1", preview: "one", hasMore: false, isDone: true),
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "one", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
        ]

        let collapsed = QuietTimelineProjection.make(items: items, isQuiet: true, isBusy: false, expandedTurnIDs: [])
        let expanded = QuietTimelineProjection.make(items: items, isQuiet: true, isBusy: false, expandedTurnIDs: ["think-1"])

        #expect(collapsed.rows.map(\.id) == ["u1", "quiet-work-line:think-1", "a1"])
        #expect(expanded.rows.map(\.id) == ["u1", "quiet-work-line:think-1", "think-1", "tool-1", "a1"])
    }

    @Test func expandedStripRetainsIdentityWhenOlderPageStartsInsideItsGroup() throws {
        let currentPage: [ChatItem] = [
            .toolCall(id: "tool-5", tool: "bash", argsSummary: "five", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .thinking(id: "think-6", preview: "six", hasMore: false, isDone: true),
            .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
        ]
        let before = QuietTimelineProjection.make(
            items: currentPage,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: ["tool-5"]
        )
        let after = QuietTimelineProjection.make(
            items: [
                .assistantMessage(id: "a0", text: "Earlier", timestamp: timestamp),
                .thinking(id: "think-1", preview: "one", hasMore: false, isDone: true),
                .toolCall(id: "tool-2", tool: "read", argsSummary: "two", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            ] + currentPage,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: ["tool-5"]
        )

        let beforeLine = try #require(workLines(in: before).first)
        let afterLine = try #require(workLines(in: after).first)
        #expect(afterLine.id == beforeLine.id)
        #expect(afterLine.turnID == "tool-5")
        #expect(afterLine.sourceItemIDs == ["think-1", "tool-2", "tool-5", "think-6"])
    }

    @Test func liveClockUsesPrecedingAssistantTimestamp() throws {
        let projection = QuietTimelineProjection.make(
            items: [
                .assistantMessage(id: "a0", text: "Earlier", timestamp: Date(timeIntervalSince1970: 1_000)),
                .thinking(id: "think-1", preview: "hidden", hasMore: false, isDone: false),
                .toolCall(id: "bash-1", tool: "bash", argsSummary: "run", outputPreview: "", outputByteCount: 0, isError: false, isDone: false),
            ],
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: []
        )

        let line = try #require(workLines(in: projection).last)
        #expect(line.isLive)
        #expect(line.liveStartedAt == Date(timeIntervalSince1970: 1_000))
        #expect(line.wordsSummary(now: Date(timeIntervalSince1970: 1_007)) == "run 1 tool · 7s")
        #expect(line.wordsSummary(now: Date(timeIntervalSince1970: 1_075)) == "run 1 tool · 1m 15s")
        #expect(line.wordsSummary(now: Date(timeIntervalSince1970: 4_723)) == "run 1 tool · 1h 2m 3s")
    }

    @Test func historicalStripFreezesDurationBetweenAssistantTimestamps() throws {
        let projection = QuietTimelineProjection.make(
            items: [
                .assistantMessage(id: "a0", text: "Earlier", timestamp: Date(timeIntervalSince1970: 1_000)),
                .toolCall(id: "bash-1", tool: "bash", argsSummary: "run", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
                .assistantMessage(id: "a1", text: "Later", timestamp: Date(timeIntervalSince1970: 1_037)),
            ],
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: []
        )

        let line = try #require(workLines(in: projection).first)
        #expect(!line.isLive)
        #expect(line.liveStartedAt == Date(timeIntervalSince1970: 1_000))
        #expect(line.intervalEndedAt == Date(timeIntervalSince1970: 1_037))
        #expect(line.wordsSummary(now: Date(timeIntervalSince1970: 9_999)) == "run 1 tool · 37s")
    }

    @Test func trailingSettledStripFreezesDurationWithoutFollowingRow() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let settledAt = Date(timeIntervalSince1970: 1_012)
        let projection = QuietTimelineProjection.make(
            items: [
                .userMessage(id: "u1", text: "Run", timestamp: start),
                .thinking(id: "think-1", preview: "hidden", hasMore: false, isDone: true),
            ],
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: [],
            now: settledAt
        )

        let line = try #require(workLines(in: projection).first)
        #expect(line.isThinkingOnly)
        #expect(!line.isLive)
        #expect(line.liveStartedAt == start)
        #expect(line.intervalEndedAt == settledAt)
        #expect(line.wordsSummary(now: Date(timeIntervalSince1970: 9_999)) == "Thought · 12s")
    }

    @Test func trailingSettledStripKeepsFrozenEndAcrossRemakes() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "Run", timestamp: start),
            .thinking(id: "think-1", preview: "hidden", hasMore: false, isDone: true),
        ]
        let first = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: [],
            now: Date(timeIntervalSince1970: 1_012)
        )
        let firstLine = try #require(workLines(in: first).first)
        let firstEnd = try #require(firstLine.intervalEndedAt)

        let remade = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: [],
            now: Date(timeIntervalSince1970: 9_999),
            settledEnds: first.settledEnds
        )
        let remadeLine = try #require(workLines(in: remade).first)
        #expect(remadeLine.intervalEndedAt == firstEnd)
        #expect(remadeLine.wordsSummary(now: Date(timeIntervalSince1970: 9_999)) == "Thought · 12s")
    }

    @Test func liveClockUsesPrecedingUserTimestampWhenNoAssistant() throws {
        let projection = QuietTimelineProjection.make(
            items: [
                .userMessage(id: "u1", text: "First", timestamp: Date(timeIntervalSince1970: 2_003)),
                .toolCall(id: "bash-1", tool: "bash", argsSummary: "run", outputPreview: "", outputByteCount: 0, isError: false, isDone: false),
            ],
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: []
        )

        let line = try #require(workLines(in: projection).last)
        #expect(line.isLive)
        #expect(line.liveStartedAt == Date(timeIntervalSince1970: 2_003))
        #expect(line.wordsSummary(now: Date(timeIntervalSince1970: 2_007)) == "run 1 tool · 4s")
    }

    @Test func busyVisibleInterruptionDoesNotRelightPreviousStrip() throws {
        let projection = QuietTimelineProjection.make(
            items: [
                .userMessage(id: "u1", text: "One", timestamp: timestamp),
                .toolCall(id: "tool-1", tool: "bash", argsSummary: "one", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
                .assistantMessage(id: "a1", text: "First", timestamp: timestamp),
                .userMessage(id: "u2", text: "Two", timestamp: timestamp),
            ],
            isQuiet: true,
            isBusy: true,
            expandedTurnIDs: []
        )

        let line = try #require(workLines(in: projection).first)
        #expect(!line.isLive)
        #expect(line.liveStartedAt == timestamp)
    }

    @Test func styleIsPartOfWorkLinePresentationPayload() throws {
        let items: [ChatItem] = [
            .toolCall(id: "tool-1", tool: "bash", argsSummary: "run", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
        ]
        let icons = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: [],
            displayStyle: .icons
        )
        let words = QuietTimelineProjection.make(
            items: items,
            isQuiet: true,
            isBusy: false,
            expandedTurnIDs: [],
            displayStyle: .words
        )

        #expect(try #require(workLines(in: icons).first).displayStyle == .icons)
        #expect(try #require(workLines(in: words).first).displayStyle == .words)
        #expect(icons != words)
    }

    @Test func renderWindowCoordinatesRemainSourceItemIDs() {
        let items: [ChatItem] = [
            .userMessage(id: "u1", text: "One", timestamp: timestamp),
            .thinking(id: "think-1", preview: "thinking", hasMore: false, isDone: true),
            .toolCall(id: "tool-1", tool: "read", argsSummary: "file", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .assistantMessage(id: "a1", text: "Done", timestamp: timestamp),
        ]
        let projection = QuietTimelineProjection.make(items: items, isQuiet: true, isBusy: false, expandedTurnIDs: [])

        #expect(projection.rows(forRenderedItemIDs: ["think-1"]).map(\.id) == ["quiet-work-line:think-1"])
        #expect(projection.fullTimelineItemIDs == ["u1", "think-1", "tool-1", "a1"])
        #expect(projection.renderedRowID(forSourceItemID: "tool-1") == "quiet-work-line:think-1")
    }

    private func workLines(in projection: QuietTimelineProjection) -> [QuietTimelineWorkLine] {
        projection.rows.compactMap { row in
            guard case .quietWork(let line) = row else { return nil }
            return line
        }
    }

    private func editArgs(old: String, new: String) -> [String: JSONValue] {
        [
            "edits": .array([
                .object([
                    "oldText": .string(old),
                    "newText": .string(new),
                ]),
            ]),
        ]
    }
}
