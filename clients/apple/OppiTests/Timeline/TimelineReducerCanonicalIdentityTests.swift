import Foundation
import Testing
@testable import Oppi

@Suite("TimelineReducer — Canonical identity")
@MainActor
struct TimelineReducerCanonicalIdentityTests {

    private func structuralProjection(_ items: [ChatItem]) -> [String] {
        items.map { item in
            switch item {
            case .assistantMessage(let id, let text, _):
                return "assistant:\(id):\(text)"
            case .thinking(let id, let preview, _, _):
                return "thinking:\(id):\(preview)"
            case .toolCall(let id, let tool, _, _, _, _, _):
                return "tool:\(id):\(tool)"
            case .cacheMiss(let id, let message):
                return "cacheMiss:\(id):\(message)"
            default:
                return "other"
            }
        }
    }

    @Test func traceMPlusReplayMNKeepsOneMAndPreservesN() {
        let reducer = TimelineReducer()
        let replayID = UUID()
        reducer.beginHistoryReplayBuffer(id: replayID)
        reducer.processBatch([
            .messageEnd(
                sessionId: "s1",
                content: "persisted M",
                assistantContent: [
                    AssistantMessageContentPart(
                        kind: "text",
                        content: "persisted M",
                        contentIndex: 0,
                        id: "entry-m-text-0"
                    ),
                ]
            ),
            .messageEnd(
                sessionId: "s1",
                content: "newer N",
                assistantContent: [
                    AssistantMessageContentPart(
                        kind: "text",
                        content: "newer N",
                        contentIndex: 0,
                        id: "entry-n-text-0"
                    ),
                ]
            ),
        ])

        reducer.applyTraceWithLiveReplay([
            TraceEvent(
                id: "entry-m-text-0",
                type: .assistant,
                timestamp: "2026-01-01T00:00:00Z",
                text: "persisted M"
            ),
        ], replayID: replayID)

        #expect(structuralProjection(reducer.items) == [
            "assistant:entry-m-text-0:persisted M",
            "assistant:entry-n-text-0:newer N",
        ])
    }

    @Test func replayedCacheMissesStayBesidePayingAssistant() {
        let reducer = TimelineReducer()
        let replayID = UUID()
        reducer.beginHistoryReplayBuffer(id: replayID)
        reducer.processBatch([
            .messageEnd(
                sessionId: "s1",
                content: "persisted M",
                assistantContent: [
                    AssistantMessageContentPart(
                        kind: "text",
                        content: "persisted M",
                        contentIndex: 0,
                        id: "entry-m-text-0"
                    ),
                ]
            ),
            .cacheMiss(
                sessionId: "s1",
                id: "cache-miss:m",
                message: "Cache miss: 25k tokens re-billed (~$0.04)"
            ),
            .messageEnd(
                sessionId: "s1",
                content: "newer N",
                assistantContent: [
                    AssistantMessageContentPart(
                        kind: "text",
                        content: "newer N",
                        contentIndex: 0,
                        id: "entry-n-text-0"
                    ),
                ]
            ),
            .cacheMiss(
                sessionId: "s1",
                id: "cache-miss:n",
                message: "Cache miss: 36k tokens re-billed (~$0.05)"
            ),
        ])

        reducer.applyTraceWithLiveReplay([
            TraceEvent(
                id: "entry-m-text-0",
                type: .assistant,
                timestamp: "2026-01-01T00:00:00Z",
                text: "persisted M"
            ),
            TraceEvent(
                id: "entry-n-text-0",
                type: .assistant,
                timestamp: "2026-01-01T00:00:01Z",
                text: "newer N"
            ),
        ], replayID: replayID)

        #expect(structuralProjection(reducer.items) == [
            "assistant:entry-m-text-0:persisted M",
            "cacheMiss:cache-miss:m:Cache miss: 25k tokens re-billed (~$0.04)",
            "assistant:entry-n-text-0:newer N",
            "cacheMiss:cache-miss:n:Cache miss: 36k tokens re-billed (~$0.05)",
        ])
    }

    @Test func liveCacheMissesStayBesidePayingAssistant() {
        let reducer = TimelineReducer()
        reducer.processBatch([
            .messageEnd(
                sessionId: "s1",
                content: "persisted M",
                assistantContent: [
                    AssistantMessageContentPart(
                        kind: "text",
                        content: "persisted M",
                        contentIndex: 0,
                        id: "entry-m-text-0"
                    ),
                ]
            ),
            .cacheMiss(
                sessionId: "s1",
                id: "cache-miss:m",
                message: "Cache miss: 25k tokens re-billed (~$0.04)"
            ),
            .messageEnd(
                sessionId: "s1",
                content: "newer N",
                assistantContent: [
                    AssistantMessageContentPart(
                        kind: "text",
                        content: "newer N",
                        contentIndex: 0,
                        id: "entry-n-text-0"
                    ),
                ]
            ),
            .cacheMiss(
                sessionId: "s1",
                id: "cache-miss:n",
                message: "Cache miss: 36k tokens re-billed (~$0.05)"
            ),
        ])

        #expect(structuralProjection(reducer.items) == [
            "assistant:entry-m-text-0:persisted M",
            "cacheMiss:cache-miss:m:Cache miss: 25k tokens re-billed (~$0.04)",
            "assistant:entry-n-text-0:newer N",
            "cacheMiss:cache-miss:n:Cache miss: 36k tokens re-billed (~$0.05)",
        ])
    }

    @Test func postApplyCanonicalFlushDoesNotIncreaseItemCount() {
        let reducer = TimelineReducer()
        reducer.loadSession([
            TraceEvent(
                id: "entry-m-text-0",
                type: .assistant,
                timestamp: "2026-01-01T00:00:00Z",
                text: "persisted M"
            ),
        ])
        let before = reducer.items.count
        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "persisted M",
            assistantContent: [
                AssistantMessageContentPart(
                    kind: "text",
                    content: "persisted M",
                    contentIndex: 0,
                    id: "entry-m-text-0"
                ),
            ]
        ))
        #expect(reducer.items.count == before)
        #expect(structuralProjection(reducer.items) == [
            "assistant:entry-m-text-0:persisted M",
        ])
    }

    @Test func canonicalMessageEndRecoversUnstreamedThinkingBeforeText() {
        let reducer = TimelineReducer()
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "Here's the answer"),
        ])

        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "Here's the answer",
            assistantContent: [
                AssistantMessageContentPart(
                    kind: "thinking",
                    content: "hmm",
                    contentIndex: 0,
                    id: "entry-1-think-0"
                ),
                AssistantMessageContentPart(
                    kind: "text",
                    content: "Here's the answer",
                    contentIndex: 1,
                    id: "entry-1-text-1"
                ),
            ]
        ))

        #expect(structuralProjection(reducer.items) == [
            "thinking:entry-1-think-0:hmm",
            "assistant:entry-1-text-1:Here's the answer",
        ])
    }

    @Test func provisionalRowsRekeyToCanonicalIDs() {
        let reducer = TimelineReducer()
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "streaming"),
            .thinkingDelta(sessionId: "s1", delta: "hmm"),
        ])
        reducer.expandedItemIDs.insert(reducer.items.first { item in
            if case .thinking = item { return true }
            return false
        }!.id)

        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "streaming",
            assistantContent: [
                AssistantMessageContentPart(
                    kind: "thinking",
                    content: "hmm",
                    contentIndex: 0,
                    id: "entry-1-think-0"
                ),
                AssistantMessageContentPart(
                    kind: "text",
                    content: "streaming",
                    contentIndex: 1,
                    id: "entry-1-text-1"
                ),
            ]
        ))

        #expect(structuralProjection(reducer.items) == [
            "thinking:entry-1-think-0:hmm",
            "assistant:entry-1-text-1:streaming",
        ])
        #expect(reducer.expandedItemIDs == ["entry-1-think-0"])
        #expect(reducer.items.allSatisfy { UUID(uuidString: $0.id) == nil })
    }

    @Test func unregisteredLiveRowsRekeyWithoutAgentStart() {
        let reducer = TimelineReducer()
        reducer.processBatch([
            .textDelta(sessionId: "s1", delta: "streaming"),
            .thinkingDelta(sessionId: "s1", delta: "hmm"),
        ])
        reducer.expandedItemIDs.insert(reducer.items.first { item in
            if case .thinking = item { return true }
            return false
        }!.id)

        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "streaming",
            assistantContent: [
                AssistantMessageContentPart(
                    kind: "thinking",
                    content: "hmm",
                    contentIndex: 0,
                    id: "entry-1-think-0"
                ),
                AssistantMessageContentPart(
                    kind: "text",
                    content: "streaming",
                    contentIndex: 1,
                    id: "entry-1-text-1"
                ),
            ]
        ))

        #expect(structuralProjection(reducer.items) == [
            "thinking:entry-1-think-0:hmm",
            "assistant:entry-1-text-1:streaming",
        ])
        #expect(reducer.expandedItemIDs == ["entry-1-think-0"])
        #expect(reducer.items.allSatisfy { UUID(uuidString: $0.id) == nil })
    }

    @Test func canonicalMessageEndRecoversThreeThinkingBlocksBeforeText() {
        let reducer = TimelineReducer()
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "## Verdict"),
        ])

        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "## Verdict",
            assistantContent: [
                AssistantMessageContentPart(
                    kind: "thinking",
                    content: "Using existing AST ranges",
                    contentIndex: 0,
                    id: "entry-1-think-0"
                ),
                AssistantMessageContentPart(
                    kind: "thinking",
                    content: "Selecting proof fields",
                    contentIndex: 1,
                    id: "entry-1-think-1"
                ),
                AssistantMessageContentPart(
                    kind: "thinking",
                    content: "Reducing iOS scan wrappers",
                    contentIndex: 2,
                    id: "entry-1-think-2"
                ),
                AssistantMessageContentPart(
                    kind: "text",
                    content: "## Verdict",
                    contentIndex: 3,
                    id: "entry-1-text-3"
                ),
            ]
        ))

        #expect(structuralProjection(reducer.items) == [
            "thinking:entry-1-think-0:Using existing AST ranges",
            "thinking:entry-1-think-1:Selecting proof fields",
            "thinking:entry-1-think-2:Reducing iOS scan wrappers",
            "assistant:entry-1-text-3:## Verdict",
        ])
    }

    @Test func canonicalRebuildPreservesTimestampsAndExpandedIDs() {
        let reducer = TimelineReducer()
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "streaming"),
        ])
        guard case .assistantMessage(let liveTextID, _, let liveTimestamp) = reducer.items[0] else {
            Issue.record("Expected a live assistant row before message_end")
            return
        }
        reducer.expandedItemIDs.insert(liveTextID)

        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "streaming",
            assistantContent: [
                AssistantMessageContentPart(
                    kind: "thinking",
                    content: "hmm",
                    contentIndex: 0,
                    id: "entry-1-think-0"
                ),
                AssistantMessageContentPart(
                    kind: "text",
                    content: "streaming",
                    contentIndex: 1,
                    id: "entry-1-text-1"
                ),
            ]
        ))

        #expect(structuralProjection(reducer.items) == [
            "thinking:entry-1-think-0:hmm",
            "assistant:entry-1-text-1:streaming",
        ])
        guard case .assistantMessage(_, _, let preservedTimestamp) = reducer.items[1] else {
            Issue.record("Expected the rekeyed assistant row")
            return
        }
        #expect(preservedTimestamp == liveTimestamp)
        #expect(reducer.expandedItemIDs == ["entry-1-text-1"])
    }

    @Test func canonicalRebuildReordersToolsAndMultipleTextRuns() {
        let reducer = TimelineReducer()
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "Before", contentIndex: 0),
            .textDelta(sessionId: "s1", delta: "After", contentIndex: 2),
            .toolStart(sessionId: "s1", toolEventId: "call-1", tool: "bash", args: [:]),
            .toolEnd(sessionId: "s1", toolEventId: "call-1"),
        ])

        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "Before\n\nAfter",
            assistantContent: [
                AssistantMessageContentPart(
                    kind: "text",
                    content: "Before",
                    contentIndex: 0,
                    id: "e1-text-0"
                ),
                AssistantMessageContentPart(kind: "tool", contentIndex: 1, toolCallId: "call-1", id: "call-1"),
                AssistantMessageContentPart(
                    kind: "text",
                    content: "After",
                    contentIndex: 2,
                    id: "e1-text-2"
                ),
            ]
        ))

        #expect(structuralProjection(reducer.items) == [
            "assistant:e1-text-0:Before",
            "tool:call-1:bash",
            "assistant:e1-text-2:After",
        ])
    }

    @Test func canonicalRebuildKeepsHistoricalRowsAndUserPromptBeforeMessage() {
        let reducer = TimelineReducer()
        reducer.loadSession([
            TraceEvent(
                id: "u1",
                type: .user,
                timestamp: "2026-01-01T00:00:00Z",
                text: "old"
            ),
            TraceEvent(
                id: "a1",
                type: .assistant,
                timestamp: "2026-01-01T00:00:01Z",
                text: "Historical"
            ),
        ])
        _ = reducer.appendUserMessage("new prompt")
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "Answer"),
        ])

        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "Answer",
            assistantContent: [
                AssistantMessageContentPart(
                    kind: "thinking",
                    content: "hmm",
                    contentIndex: 0,
                    id: "entry-2-think-0"
                ),
                AssistantMessageContentPart(
                    kind: "text",
                    content: "Answer",
                    contentIndex: 1,
                    id: "entry-2-text-1"
                ),
            ]
        ))

        #expect(reducer.items.count == 5)
        guard case .userMessage(let historicalUserID, let historicalUserText, _, _) = reducer.items[0] else {
            Issue.record("Expected historical user row to stay first")
            return
        }
        #expect(historicalUserID == "u1")
        #expect(historicalUserText == "old")
        guard case .assistantMessage(let historicalAssistantID, let historicalAssistantText, _) = reducer.items[1] else {
            Issue.record("Expected historical assistant row to stay second")
            return
        }
        #expect(historicalAssistantID == "a1")
        #expect(historicalAssistantText == "Historical")
        guard case .userMessage(_, let prompt, _, _) = reducer.items[2] else {
            Issue.record("Expected the new user prompt to stay before reconstructed thinking")
            return
        }
        #expect(prompt == "new prompt")
        #expect(structuralProjection(Array(reducer.items.suffix(2))) == [
            "thinking:entry-2-think-0:hmm",
            "assistant:entry-2-text-1:Answer",
        ])
    }

    @Test func mixedCanonicalPartsPreserveOrderAndToolIdentity() {
        let reducer = TimelineReducer()
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "Before", contentIndex: 0),
            .toolStart(sessionId: "s1", toolEventId: "call-1", tool: "bash", args: [:]),
            .toolEnd(sessionId: "s1", toolEventId: "call-1"),
            .textDelta(sessionId: "s1", delta: "After", contentIndex: 2),
        ])

        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "Before\n\nAfter",
            assistantContent: [
                AssistantMessageContentPart(
                    kind: "text",
                    content: "Before",
                    contentIndex: 0,
                    id: "e1-text-0"
                ),
                AssistantMessageContentPart(kind: "tool", contentIndex: 1, toolCallId: "call-1", id: "call-1"),
                AssistantMessageContentPart(
                    kind: "text",
                    content: "After",
                    contentIndex: 2,
                    id: "e1-text-2"
                ),
            ]
        ))

        #expect(structuralProjection(reducer.items) == [
            "assistant:e1-text-0:Before",
            "tool:call-1:bash",
            "assistant:e1-text-2:After",
        ])
    }

    @Test func repeatedIdenticalTextWithDifferentEntryIDsStaysTwoRows() {
        let reducer = TimelineReducer()
        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "same",
            assistantContent: [
                AssistantMessageContentPart(kind: "text", content: "same", contentIndex: 0, id: "a-text-0"),
            ]
        ))
        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "same",
            assistantContent: [
                AssistantMessageContentPart(kind: "text", content: "same", contentIndex: 0, id: "b-text-0"),
            ]
        ))

        #expect(structuralProjection(reducer.items) == [
            "assistant:a-text-0:same",
            "assistant:b-text-0:same",
        ])
    }

    @Test func missingIDsStillUseCompatibilityAdoption() {
        let reducer = TimelineReducer()
        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "Here's the answer"),
        ])
        let beforeIDs = Set(reducer.items.map(\.id))
        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "Here's the answer",
            assistantContent: [
                AssistantMessageContentPart(kind: "text", content: "Here's the answer", contentIndex: 0),
            ]
        ))
        #expect(reducer.items.count == 1)
        #expect(Set(reducer.items.map(\.id)) == beforeIDs)
    }
}
