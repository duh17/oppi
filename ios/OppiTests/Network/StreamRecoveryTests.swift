import Testing
import Foundation
@testable import Oppi

/// Tests for stream recovery and lifecycle hardening.
///
/// Fix 1: closeAllOrphanedTools — close ALL open tool rows, not just last
/// Fix 2: agentStart finalizes stale state from previous turn
/// Fix 3: sessionEnded finalizes thinking and tools
/// Fix 4: Ping watchdog triggers reconnect after consecutive failures
/// Fix 5: Silence watchdog detects stuck sessions
@Suite("Stream Recovery")
struct StreamRecoveryTests {

    // MARK: - Fix 1: closeAllOrphanedTools

    @MainActor
    @Test func agentEndClosesAllOpenToolRows() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t2", tool: "read", args: [:]))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t3", tool: "write", args: [:]))
        // No toolEnd events — simulate missed events
        reducer.process(.agentEnd(sessionId: "s1"))

        let tools = reducer.items.compactMap { item -> (String, Bool)? in
            guard case .toolCall(let id, _, _, _, _, _, let isDone) = item else { return nil }
            return (id, isDone)
        }
        #expect(tools.count == 3)
        for (id, isDone) in tools {
            #expect(isDone, "Tool \(id) should be marked done after agentEnd")
        }
    }

    @MainActor
    @Test func agentEndClosesToolsWithMixedState() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: "t1")) // properly closed
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t2", tool: "read", args: [:]))
        // t2 left open
        reducer.process(.agentEnd(sessionId: "s1"))

        let tools = reducer.items.compactMap { item -> (String, Bool)? in
            guard case .toolCall(let id, _, _, _, _, _, let isDone) = item else { return nil }
            return (id, isDone)
        }
        #expect(tools.count == 2)
        #expect(tools.allSatisfy { $0.1 }, "All tools should be done")
    }

    // MARK: - Fix 2: agentStart finalizes stale state

    @MainActor
    @Test func agentStartFinalizesStaleAssistantMessage() {
        let reducer = TimelineReducer()

        // First turn — no agentEnd (simulates missed event)
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "First turn text"))
        // agentEnd missed!

        // Second turn starts
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Second turn text"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let messages = reducer.items.compactMap { item -> String? in
            guard case .assistantMessage(_, let text, _) = item else { return nil }
            return text
        }
        #expect(messages.count == 2, "Both turns should produce messages")
        #expect(messages[0] == "First turn text")
        #expect(messages[1] == "Second turn text")
    }

    @MainActor
    @Test func agentStartClosesStaleToolRows() {
        let reducer = TimelineReducer()

        // Turn 1: tool left open
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))
        // No toolEnd, no agentEnd

        // Turn 2
        reducer.process(.agentStart(sessionId: "s1"))

        let tools = reducer.items.compactMap { item -> (String, Bool)? in
            guard case .toolCall(let id, _, _, _, _, _, let isDone) = item else { return nil }
            return (id, isDone)
        }
        #expect(tools.count == 1)
        #expect(tools[0].1 == true, "Stale tool should be closed by new agentStart")
    }

    @MainActor
    @Test func agentStartFinalizesStaleThinking() {
        let reducer = TimelineReducer()

        // Turn 1: thinking left open
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "Thinking about this..."))
        // No agentEnd

        // Turn 2
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Answer"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let thinking = reducer.items.compactMap { item -> Bool? in
            guard case .thinking(_, _, _, let isDone) = item else { return nil }
            return isDone
        }
        #expect(thinking.count == 1)
        #expect(thinking[0] == true, "Stale thinking should be finalized by new agentStart")
    }

    // MARK: - Fix 3: sessionEnded full cleanup

    @MainActor
    @Test func sessionEndedFinalizesThinking() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "Deep thought..."))
        // Session ends abruptly
        reducer.process(.sessionEnded(sessionId: "s1", reason: "server_shutdown"))

        let thinking = reducer.items.compactMap { item -> Bool? in
            guard case .thinking(_, _, _, let isDone) = item else { return nil }
            return isDone
        }
        #expect(thinking.count == 1)
        #expect(thinking[0] == true, "Thinking should be finalized on sessionEnded")
    }

    @MainActor
    @Test func sessionEndedClosesOrphanedTools() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))
        reducer.process(.sessionEnded(sessionId: "s1", reason: "crash"))

        let tools = reducer.items.compactMap { item -> Bool? in
            guard case .toolCall(_, _, _, _, _, _, let isDone) = item else { return nil }
            return isDone
        }
        #expect(tools.count == 1)
        #expect(tools[0] == true, "Tool should be closed on sessionEnded")
    }

    @MainActor
    @Test func sessionEndedFinalizesAssistantText() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Partial response"))
        reducer.process(.sessionEnded(sessionId: "s1", reason: "timeout"))

        let messages = reducer.items.compactMap { item -> String? in
            guard case .assistantMessage(_, let text, _) = item else { return nil }
            return text
        }
        #expect(messages == ["Partial response"], "Partial text should be saved on sessionEnded")

        let systemEvents = reducer.items.compactMap { item -> String? in
            guard case .systemEvent(_, let msg) = item else { return nil }
            return msg
        }
        #expect(systemEvents.count == 1)
        #expect(systemEvents[0].contains("timeout"))
    }

    @MainActor
    @Test func sessionEndedFullCleanup() {
        // All three: thinking + tool + assistant, all open
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "Hmm"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Starting"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))
        reducer.process(.sessionEnded(sessionId: "s1", reason: "killed"))

        // Check everything is finalized
        for item in reducer.items {
            switch item {
            case .thinking(_, _, _, let isDone):
                #expect(isDone, "Thinking should be done")
            case .toolCall(_, _, _, _, _, _, let isDone):
                #expect(isDone, "Tool should be done")
            case .assistantMessage, .systemEvent:
                break // expected
            default:
                Issue.record("Unexpected item type: \(item)")
            }
        }

        #expect(reducer.streamingAssistantID == nil, "Streaming state should be cleared")
    }

    // MARK: - processBatch invariants

    @MainActor
    @Test func processBatchClosesOrphanedToolsOnAgentEnd() {
        let reducer = TimelineReducer()

        let events: [AgentEvent] = [
            .agentStart(sessionId: "s1"),
            .toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]),
            .toolStart(sessionId: "s1", toolEventId: "t2", tool: "read", args: [:]),
            .agentEnd(sessionId: "s1"),
        ]
        reducer.processBatch(events)

        let tools = reducer.items.compactMap { item -> (String, Bool)? in
            guard case .toolCall(let id, _, _, _, _, _, let isDone) = item else { return nil }
            return (id, isDone)
        }
        #expect(tools.count == 2)
        #expect(tools.allSatisfy { $0.1 })
    }

    @MainActor
    @Test func processBatchAgentStartCleansUpPreviousTurn() {
        let reducer = TimelineReducer()

        // Turn 1 ends without agentEnd
        let turn1: [AgentEvent] = [
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "Partial"),
            .toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]),
        ]
        reducer.processBatch(turn1)

        // Verify in-progress state
        #expect(reducer.streamingAssistantID != nil) // preserved through toolStart during active turn
        let toolsBefore = reducer.items.filter {
            if case .toolCall(_, _, _, _, _, _, let isDone) = $0 { return !isDone }
            return false
        }
        #expect(toolsBefore.count == 1, "Tool should be in-progress")

        // Turn 2 starts
        let turn2: [AgentEvent] = [
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "New turn"),
            .agentEnd(sessionId: "s1"),
        ]
        reducer.processBatch(turn2)

        // All old tools should be closed
        let allTools = reducer.items.compactMap { item -> Bool? in
            guard case .toolCall(_, _, _, _, _, _, let isDone) = item else { return nil }
            return isDone
        }
        #expect(allTools.allSatisfy { $0 }, "All tools closed after new agentStart")
    }

    // MARK: - Ping Watchdog

    @Test func reconnectDelayFirstAttempt() {
        // Just verify the reconnect delay calculation still works
        let delay = WebSocketClient.reconnectDelay(attempt: 1)
        #expect(delay >= 0.75 && delay <= 1.25)
    }

    // MARK: - Edge: rapid agentStart without agentEnd

    @MainActor
    @Test func rapidAgentStartsDoNotDuplicate() {
        let reducer = TimelineReducer()

        // Three rapid agentStarts without agentEnds
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "A"))
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "B"))
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "C"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let messages = reducer.items.compactMap { item -> String? in
            guard case .assistantMessage(_, let text, _) = item else { return nil }
            return text
        }
        #expect(messages == ["A", "B", "C"], "Each agentStart should finalize previous and start fresh")
    }

    // MARK: - Edge: empty buffer finalization

    @MainActor
    @Test func agentStartWithEmptyBuffersIsClean() {
        let reducer = TimelineReducer()

        // agentStart with nothing to finalize
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.items.isEmpty, "Empty turn should produce no items")
    }

    @MainActor
    @Test func whitespaceOnlyBufferDiscardedOnAgentStart() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "\n\n"))
        // New turn — whitespace buffer should be discarded, not saved
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Real content"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let messages = reducer.items.compactMap { item -> String? in
            guard case .assistantMessage(_, let text, _) = item else { return nil }
            return text
        }
        #expect(messages == ["Real content"], "Whitespace-only buffer should be discarded")
    }
}
