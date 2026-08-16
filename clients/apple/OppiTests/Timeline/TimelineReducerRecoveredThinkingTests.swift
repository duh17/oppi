import Testing
import Foundation
@testable import Oppi

/// Regression suite for duplicate assistant bubbles when the server
/// synthesizes `thinking_delta` at `message_end` (thinking did not stream
/// live) and then reconciles the authoritative structural content.
///
/// Reported symptom: live assistant text → late/recovered thinking →
/// the same assistant text again → tool row. Only one assistant text row
/// may remain; thinking/tool ordering and content must match the
/// authoritative projection.
@Suite("TimelineReducer — Recovered thinking")
@MainActor
struct TimelineReducerRecoveredThinkingTests {

    private func structuralProjection(_ items: [ChatItem]) -> [String] {
        items.map { item in
            switch item {
            case .assistantMessage(_, let text, _):
                return "assistant:\(text)"
            case .thinking(_, let preview, _, _):
                return "thinking:\(preview)"
            case .toolCall(_, let tool, _, _, _, _, _):
                return "tool:\(tool)"
            default:
                return "other"
            }
        }
    }

    private func assistantTextCount(_ items: [ChatItem]) -> Int {
        items.reduce(into: 0) { count, item in
            if case .assistantMessage = item { count += 1 }
        }
    }

    @Test func recoveredThinkingAfterLiveTextDoesNotDuplicateAssistantText() {
        // Reproduces: textDelta streams live → tool row appears → recovered
        // thinkingDelta arrives (server synthesizes it at message_end when
        // thinking never streamed) → messageEnd reconciles authoritative
        // [thinking, text, tool] content. Exactly one text bubble remains.
        let reducer = TimelineReducer()

        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "Here's the answer", contentIndex: 1),
            .toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": "pwd"]),
            .toolEnd(sessionId: "s1", toolEventId: "t1"),
            .thinkingDelta(sessionId: "s1", delta: "Let me think...", contentIndex: 0),
            .messageEnd(
                sessionId: "s1",
                content: "Here's the answer",
                assistantContent: [
                    AssistantMessageContentPart(kind: "thinking", content: "Let me think...", contentIndex: 0),
                    AssistantMessageContentPart(kind: "text", content: "Here's the answer", contentIndex: 1),
                    AssistantMessageContentPart(kind: "tool", contentIndex: 2, toolCallId: "t1"),
                ]
            ),
            .agentEnd(sessionId: "s1"),
        ])

        #expect(assistantTextCount(reducer.items) == 1)
        #expect(structuralProjection(reducer.items) == [
            "thinking:Let me think...",
            "assistant:Here's the answer",
            "tool:bash",
        ])
    }

    @Test func recoveredThinkingAcrossCoalescerBatchesDoesNotDuplicateAssistantText() {
        // Mirrors the production coalescer delivery: agentStart and tool
        // events flush immediately, deltas are buffered and flushed before
        // messageEnd is delivered.
        let reducer = TimelineReducer()

        reducer.processBatch([.agentStart(sessionId: "s1")])
        reducer.processBatch([.textDelta(sessionId: "s1", delta: "Here's the answer", contentIndex: 1)])
        reducer.processBatch([.toolUpdate(sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": "pwd"])])
        reducer.processBatch([.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": "pwd"])])
        reducer.processBatch([.toolEnd(sessionId: "s1", toolEventId: "t1")])
        reducer.processBatch([.thinkingDelta(sessionId: "s1", delta: "Let me think...", contentIndex: 0)])
        reducer.processBatch([
            .messageEnd(
                sessionId: "s1",
                content: "Here's the answer",
                assistantContent: [
                    AssistantMessageContentPart(kind: "thinking", content: "Let me think...", contentIndex: 0),
                    AssistantMessageContentPart(kind: "text", content: "Here's the answer", contentIndex: 1),
                    AssistantMessageContentPart(kind: "tool", contentIndex: 2, toolCallId: "t1"),
                ]
            ),
        ])
        reducer.processBatch([.agentEnd(sessionId: "s1")])

        #expect(assistantTextCount(reducer.items) == 1)
        #expect(structuralProjection(reducer.items) == [
            "thinking:Let me think...",
            "assistant:Here's the answer",
            "tool:bash",
        ])
    }

    @Test func textDeltaDeliveredBeforeAgentStartDoesNotDuplicateAssistantText() {
        // Boundary variant: a text delta flush lands while no agent run is
        // active (previous turn settled, late flush, or busy re-entry),
        // then the new turn's agentStart, recovered thinkingDelta, and
        // messageEnd arrive. The message_end reconciliation must still
        // reuse the already-finalized text row instead of drawing it again.
        let reducer = TimelineReducer()

        reducer.processBatch([.textDelta(sessionId: "s1", delta: "Here's the answer", contentIndex: 1)])
        reducer.processBatch([.agentStart(sessionId: "s1")])
        reducer.processBatch([.thinkingDelta(sessionId: "s1", delta: "Let me think...", contentIndex: 0)])
        reducer.processBatch([
            .messageEnd(
                sessionId: "s1",
                content: "Here's the answer",
                assistantContent: [
                    AssistantMessageContentPart(kind: "thinking", content: "Let me think...", contentIndex: 0),
                    AssistantMessageContentPart(kind: "text", content: "Here's the answer", contentIndex: 1),
                ]
            ),
        ])
        reducer.processBatch([.agentEnd(sessionId: "s1")])

        #expect(assistantTextCount(reducer.items) == 1)
        #expect(structuralProjection(reducer.items) == [
            "thinking:Let me think...",
            "assistant:Here's the answer",
        ])
    }

    @Test func busyReEntryWithoutAgentStartDoesNotDuplicateAssistantText() {
        // Production trigger: the client attaches to a busy session after the
        // agent run started, so live deltas (textDelta, recovered
        // thinkingDelta, tool rows) arrive without agentStart. The trace
        // provides the historical rows; message_end reconciliation must
        // absorb the live rows without duplicating the text or thinking.
        let reducer = TimelineReducer()

        reducer.loadSession([
            TraceEvent(
                id: "u1",
                type: .user,
                timestamp: "2026-01-01T00:00:00Z",
                text: "run pwd"
            ),
        ])

        reducer.processBatch([.textDelta(sessionId: "s1", delta: "Here's the answer", contentIndex: 1)])
        reducer.processBatch([.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: ["command": "pwd"])])
        reducer.processBatch([.toolEnd(sessionId: "s1", toolEventId: "t1")])
        reducer.processBatch([.thinkingDelta(sessionId: "s1", delta: "Let me think...", contentIndex: 0)])
        reducer.processBatch([
            .messageEnd(
                sessionId: "s1",
                content: "Here's the answer",
                assistantContent: [
                    AssistantMessageContentPart(kind: "thinking", content: "Let me think...", contentIndex: 0),
                    AssistantMessageContentPart(kind: "text", content: "Here's the answer", contentIndex: 1),
                    AssistantMessageContentPart(kind: "tool", contentIndex: 2, toolCallId: "t1"),
                ]
            ),
        ])
        reducer.processBatch([.agentEnd(sessionId: "s1")])

        #expect(assistantTextCount(reducer.items) == 1)
        let thinkingCount = reducer.items.reduce(into: 0) { count, item in
            if case .thinking = item { count += 1 }
        }
        #expect(thinkingCount == 1)
        #expect(structuralProjection(reducer.items) == [
            "other",
            "thinking:Let me think...",
            "assistant:Here's the answer",
            "tool:bash",
        ])
    }

    @Test func historicalRowRemovalBelowRegionKeepsAdoptionBoundaryAligned() {
        // Boundary-maintenance guard: removeItem() can delete a historical
        // row below messageRegionStart. Indices below the boundary shift left,
        // so the boundary must shift with them — otherwise the first live row
        // falls outside the adoption region and message_end duplicates it.
        let reducer = TimelineReducer()

        reducer.loadSession([
            TraceEvent(id: "u1", type: .user, timestamp: "2026-01-01T00:00:00Z", text: "hi"),
            TraceEvent(id: "a1", type: .assistant, timestamp: "2026-01-01T00:00:01Z", text: "Historical one"),
            TraceEvent(id: "sys1", type: .system, timestamp: "2026-01-01T00:00:02Z", text: "System note"),
        ])

        reducer.removeItem(id: "a1")

        // Live deltas without agentStart (busy re-entry), then the
        // authoritative message_end. The text row is appended at index 2
        // (items.last is a system row, not an assistant row to resume).
        reducer.processBatch([.textDelta(sessionId: "s1", delta: "Here's the answer", contentIndex: 1)])
        reducer.processBatch([.thinkingDelta(sessionId: "s1", delta: "Let me think...", contentIndex: 0)])
        reducer.processBatch([
            .messageEnd(
                sessionId: "s1",
                content: "Here's the answer",
                assistantContent: [
                    AssistantMessageContentPart(kind: "thinking", content: "Let me think...", contentIndex: 0),
                    AssistantMessageContentPart(kind: "text", content: "Here's the answer", contentIndex: 1),
                ]
            ),
        ])
        reducer.processBatch([.agentEnd(sessionId: "s1")])

        #expect(assistantTextCount(reducer.items) == 1)
        let thinkingCount = reducer.items.reduce(into: 0) { count, item in
            if case .thinking = item { count += 1 }
        }
        #expect(thinkingCount == 1)
        #expect(structuralProjection(reducer.items) == [
            "other",
            "other",
            "thinking:Let me think...",
            "assistant:Here's the answer",
        ])
    }

    @Test func liveRegionRowRemovalKeepsAdoptionBoundaryAligned() {
        // A row removed inside the live region (optimistic user message
        // retracted on send failure) must not shift the adoption region.
        let reducer = TimelineReducer()

        reducer.loadSession([
            TraceEvent(id: "u1", type: .user, timestamp: "2026-01-01T00:00:00Z", text: "hi"),
        ])
        let optimisticID = reducer.appendUserMessage("optimistic")
        reducer.removeItem(id: optimisticID)

        reducer.processBatch([.textDelta(sessionId: "s1", delta: "Here's the answer", contentIndex: 1)])
        reducer.processBatch([.thinkingDelta(sessionId: "s1", delta: "Let me think...", contentIndex: 0)])
        reducer.processBatch([
            .messageEnd(
                sessionId: "s1",
                content: "Here's the answer",
                assistantContent: [
                    AssistantMessageContentPart(kind: "thinking", content: "Let me think...", contentIndex: 0),
                    AssistantMessageContentPart(kind: "text", content: "Here's the answer", contentIndex: 1),
                ]
            ),
        ])
        reducer.processBatch([.agentEnd(sessionId: "s1")])

        #expect(assistantTextCount(reducer.items) == 1)
        let thinkingCount = reducer.items.reduce(into: 0) { count, item in
            if case .thinking = item { count += 1 }
        }
        #expect(thinkingCount == 1)
        #expect(structuralProjection(reducer.items) == [
            "other",
            "thinking:Let me think...",
            "assistant:Here's the answer",
        ])
    }

    @Test func adoptionNeverStealsHistoricalRowsWithIdenticalText() {
        // Safety bound: a previous turn's identical assistant text must never
        // be adopted by a later message_end whose own live text was missed.
        let reducer = TimelineReducer()

        reducer.loadSession([
            TraceEvent(id: "u1", type: .user, timestamp: "2026-01-01T00:00:00Z", text: "hi"),
            TraceEvent(id: "a1", type: .assistant, timestamp: "2026-01-01T00:00:01Z", text: "Hello!"),
            TraceEvent(id: "u2", type: .user, timestamp: "2026-01-01T00:00:02Z", text: "again"),
        ])

        // Only the recovered thinking arrives for the new message — its text
        // never streamed to this client.
        reducer.processBatch([.thinkingDelta(sessionId: "s1", delta: "Second thought", contentIndex: 0)])
        reducer.processBatch([
            .messageEnd(
                sessionId: "s1",
                content: "Hello!",
                assistantContent: [
                    AssistantMessageContentPart(kind: "thinking", content: "Second thought", contentIndex: 0),
                    AssistantMessageContentPart(kind: "text", content: "Hello!", contentIndex: 1),
                ]
            ),
        ])
        reducer.processBatch([.agentEnd(sessionId: "s1")])

        // The historical "Hello!" row keeps its ID and position; the current
        // message gets its own text row. Both survive.
        let texts = reducer.items.compactMap { item -> String? in
            if case .assistantMessage(_, let text, _) = item { return text }
            return nil
        }
        #expect(texts == ["Hello!", "Hello!"])
        guard case .assistantMessage(let firstID, _, _)? = reducer.items.first(where: { item in
            if case .assistantMessage = item { return true }
            return false
        }) else {
            Issue.record("Expected a historical assistant row")
            return
        }
        #expect(firstID == "a1", "Historical row must not be adopted or moved")
        let thinkingCount = reducer.items.reduce(into: 0) { count, item in
            if case .thinking = item { count += 1 }
        }
        #expect(thinkingCount == 1)
    }

    @Test func recoveredThinkingWithoutToolMatchesColdStructuralOrder() {
        // The live sequence must converge to the same structural order as a
        // cold trace load of the authoritative projection.
        let live = TimelineReducer()
        live.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "Here's the answer", contentIndex: 1),
            .thinkingDelta(sessionId: "s1", delta: "Let me think...", contentIndex: 0),
            .messageEnd(
                sessionId: "s1",
                content: "Here's the answer",
                assistantContent: [
                    AssistantMessageContentPart(kind: "thinking", content: "Let me think...", contentIndex: 0),
                    AssistantMessageContentPart(kind: "text", content: "Here's the answer", contentIndex: 1),
                ]
            ),
            .agentEnd(sessionId: "s1"),
        ])

        let cold = TimelineReducer()
        cold.loadSession([
            TraceEvent(id: "think-0", type: .thinking, timestamp: "2026-01-01T00:00:00Z", thinking: "Let me think..."),
            TraceEvent(id: "a-1", type: .assistant, timestamp: "2026-01-01T00:00:01Z", text: "Here's the answer"),
        ])

        #expect(structuralProjection(live.items) == structuralProjection(cold.items))
        #expect(assistantTextCount(live.items) == 1)
    }
}
