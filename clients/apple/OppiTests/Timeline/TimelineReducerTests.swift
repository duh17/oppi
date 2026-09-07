import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer")
@MainActor
struct TimelineReducerTests {

    @Test func cacheMissRendersAsWarningTimelineItem() {
        let reducer = TimelineReducer()
        let expectedID = "cache-miss:1:anthropic/claude-sonnet"
        reducer.process(.cacheMiss(
            sessionId: "s1",
            id: expectedID,
            message: "Cache miss after 5m idle: 69k tokens re-billed (~$0.79)"
        ))

        #expect(reducer.items.count == 1)
        guard case .cacheMiss(let id, let message) = reducer.items[0] else {
            Issue.record("Expected typed cache miss notice")
            return
        }
        #expect(id == "cache-miss:1:anthropic/claude-sonnet")
        #expect(message == "Cache miss after 5m idle: 69k tokens re-billed (~$0.79)")
    }

    @Test func retryStartReusesPreviousErrorRow() {
        let reducer = TimelineReducer()

        reducer.process(.error(sessionId: "s1", message: "rate limit"))
        reducer.process(.retryStart(sessionId: "s1", attempt: 1, maxAttempts: 3, delayMs: 2000, errorMessage: "rate limit"))

        #expect(reducer.items.count == 1)
        guard case .error(_, let msg) = reducer.items[0] else {
            Issue.record("Expected merged retry error row, got \(reducer.items[0])")
            return
        }
        #expect(msg == "Retrying (1/3): rate limit")
    }

    @Test func retryStartNormalizesStructuredProviderErrors() {
        let reducer = TimelineReducer()
        let raw = #"Codex error: {"type":"error","error":{"type":"service_unavailable_error","code":"server_is_overloaded","message":"Our servers are currently overloaded. Please try again later."}}"#

        reducer.process(.retryStart(sessionId: "s1", attempt: 1, maxAttempts: 3, delayMs: 2000, errorMessage: raw))

        guard case .error(_, let msg) = reducer.items[0] else {
            Issue.record("Expected normalized retry error")
            return
        }
        #expect(msg == "Retrying (1/3): Our servers are currently overloaded. Please try again later.")
    }

    @Test func realErrorNormalizesStructuredProviderErrors() {
        let reducer = TimelineReducer()
        let raw = #"{"type":"error","error":{"type":"service_unavailable_error","code":"server_is_overloaded","message":"Our servers are currently overloaded. Please try again later.","param":null},"sequence_number":2}"#

        reducer.process(.error(sessionId: "s1", message: raw))

        guard case .error(_, let msg) = reducer.items[0] else {
            Issue.record("Expected normalized error")
            return
        }
        #expect(msg == "Our servers are currently overloaded. Please try again later.")
    }

    // loadFromREST removed — trace is the only history path.

    @Test func orphanedToolStaysOpenOnAgentEndUntilSettled() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "read", args: [:]))
        // No toolEnd before agentEnd — retries may still follow while busy.
        reducer.process(.agentEnd(sessionId: "s1"))

        guard case .toolCall(_, _, _, _, _, _, let isDoneAfterEnd) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(!isDoneAfterEnd, "agent_end alone must not interrupt open tools")
        #expect(!reducer.isToolInterrupted("t1"))

        reducer.process(.agentSettled(sessionId: "s1"))

        guard case .toolCall(_, _, _, _, _, _, let isDoneAfterSettled) = reducer.items[0] else {
            Issue.record("Expected toolCall after settled")
            return
        }
        #expect(isDoneAfterSettled, "Orphaned tool should be marked done on agentSettled")
        #expect(reducer.isToolInterrupted("t1"))
    }

    @Test func failedCompactionShowsErrorAndCancelStaysCancelled() {
        let failed = TimelineReducer()
        failed.process(
            .compactionEnd(
                sessionId: "s1",
                aborted: false,
                willRetry: false,
                summary: nil,
                tokensBefore: nil,
                errorMessage: "provider overloaded"
            )
        )
        guard case .systemEvent(_, let failedMessage) = failed.items[0] else {
            Issue.record("Expected systemEvent for failed compaction_end")
            return
        }
        #expect(failedMessage == "Compaction failed: provider overloaded")

        let cancelled = TimelineReducer()
        cancelled.process(
            .compactionEnd(
                sessionId: "s1",
                aborted: true,
                willRetry: false,
                summary: nil,
                tokensBefore: nil,
                errorMessage: "provider overloaded"
            )
        )
        guard case .systemEvent(_, let cancelledMessage) = cancelled.items[0] else {
            Issue.record("Expected systemEvent for cancelled compaction_end")
            return
        }
        #expect(cancelledMessage == "Compaction cancelled")
    }

    // MARK: - Compaction Deduplication

    @Test func compactionStartEndCollapsesIntoSingleItem() {
        // A single compaction cycle (start + end) should produce exactly 1 timeline item,
        // not 2 separate items. The end message replaces the start message.
        let reducer = TimelineReducer()

        reducer.process(.compactionStart(sessionId: "s1", reason: "threshold"))
        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let startMsg) = reducer.items[0] else {
            Issue.record("Expected systemEvent for compactionStart")
            return
        }
        #expect(startMsg == "Compacting context...")

        reducer.process(.compactionEnd(
            sessionId: "s1", aborted: false, willRetry: false,
            summary: "## Goal", tokensBefore: 100_000
        ))
        // End should REPLACE start, not append alongside it
        let compactionItems = reducer.items.filter {
            if case .systemEvent(_, let msg) = $0 {
                return msg.contains("Compacting") || msg.contains("compacted") || msg.contains("Context")
            }
            return false
        }
        #expect(compactionItems.count == 1, "Expected 1 compaction item, got \(compactionItems.count)")
        guard case .systemEvent(_, let endMsg) = compactionItems[0] else {
            Issue.record("Expected systemEvent")
            return
        }
        #expect(endMsg.contains("Context compacted"))
        #expect(endMsg.contains("100,000"))
    }

    @Test func traceCompactionThenLiveCompactionDoesNotDuplicate() {
        // Simulates the race condition: loadSession rebuilds from trace (which includes
        // the compaction entry), then buffered live WS events for the SAME compaction
        // arrive. Should NOT create duplicate compaction items.
        let reducer = TimelineReducer()

        // Step 1: loadSession with trace that includes a compaction
        let traceEvents = [
            TraceEvent(id: "u1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "c1", type: .compaction, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Context compacted (50,000 tokens): ## Summary",
                       tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "a1", type: .assistant, timestamp: "2025-01-01T00:00:02.000Z",
                       text: "Here is the answer", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(traceEvents)

        let itemsAfterLoad = reducer.items.count
        let compactionCountAfterLoad = reducer.items.filter {
            if case .systemEvent(_, let msg) = $0 {
                return msg.contains("compacted") || msg.contains("Compacting")
            }
            return false
        }.count
        #expect(compactionCountAfterLoad == 1, "Trace should produce exactly 1 compaction item")

        // Step 2: Simulate buffered live events for the SAME compaction arriving after rebuild
        reducer.process(.compactionStart(sessionId: "s1", reason: "threshold"))
        reducer.process(.compactionEnd(
            sessionId: "s1", aborted: false, willRetry: false,
            summary: "## Summary", tokensBefore: 50_000
        ))

        // The live events should NOT create additional compaction items
        let compactionCountAfterLive = reducer.items.filter {
            if case .systemEvent(_, let msg) = $0 {
                return msg.contains("compacted") || msg.contains("Compacting")
            }
            return false
        }.count
        #expect(compactionCountAfterLive <= 1,
                "Expected at most 1 compaction item after trace + live, got \(compactionCountAfterLive)")
    }

    @Test func multipleCompactionCyclesShowMultipleItems() {
        // Two genuinely different compaction cycles should produce 2 items (one each).
        let reducer = TimelineReducer()

        // First compaction cycle
        reducer.process(.compactionStart(sessionId: "s1", reason: "threshold"))
        reducer.process(.compactionEnd(
            sessionId: "s1", aborted: false, willRetry: false,
            summary: "First summary", tokensBefore: 100_000
        ))

        // Some activity between compactions
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Response"))
        reducer.process(.agentEnd(sessionId: "s1"))

        // Second compaction cycle
        reducer.process(.compactionStart(sessionId: "s1", reason: "threshold"))
        reducer.process(.compactionEnd(
            sessionId: "s1", aborted: false, willRetry: false,
            summary: "Second summary", tokensBefore: 80_000
        ))

        let compactionItems = reducer.items.filter {
            if case .systemEvent(_, let msg) = $0 {
                return msg.contains("compacted")
            }
            return false
        }
        #expect(compactionItems.count == 2, "Two separate compaction cycles should produce 2 items")
    }

    @Test func compactionOverflowReasonShowsCorrectLabel() {
        let reducer = TimelineReducer()

        reducer.process(.compactionStart(sessionId: "s1", reason: "overflow"))
        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent")
            return
        }
        #expect(msg == "Context overflow — compacting...")

        // End replaces start
        reducer.process(.compactionEnd(
            sessionId: "s1", aborted: false, willRetry: false,
            summary: nil, tokensBefore: nil
        ))
        let compactionItems = reducer.items.filter {
            if case .systemEvent(_, let msg) = $0 {
                return msg.contains("compacted") || msg.contains("overflow")
            }
            return false
        }
        #expect(compactionItems.count == 1)
    }
}
