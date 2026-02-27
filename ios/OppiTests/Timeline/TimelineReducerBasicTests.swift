import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer — Basic")
struct TimelineReducerBasicTests {

    @MainActor
    @Test func basicAgentTurn() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Hello "))
        reducer.process(.textDelta(sessionId: "s1", delta: "world!"))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.items.count == 1)
        guard case .assistantMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(text == "Hello world!")
    }

    @MainActor
    @Test func thinkingThenText() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "I need to "))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "think..."))
        reducer.process(.textDelta(sessionId: "s1", delta: "The answer is 42."))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.items.count == 2) // thinking + assistant
        guard case .thinking(_, let preview, _, _) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(preview.contains("I need to think"))
    }

    @MainActor
    @Test func thinkingStreamingShowsPreviewBeforeFinalization() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "Let me "))
        reducer.process(.thinkingDelta(sessionId: "s1", delta: "analyze this"))

        // Mid-stream: thinking item exists with isDone == false and preview text
        #expect(reducer.items.count == 1)
        guard case .thinking(_, let preview, _, let isDone) = reducer.items[0] else {
            Issue.record("Expected thinking item during streaming")
            return
        }
        #expect(preview.contains("Let me analyze"))
        #expect(!isDone) // Still streaming

        // Finalize
        reducer.process(.textDelta(sessionId: "s1", delta: "Answer."))
        reducer.process(.agentEnd(sessionId: "s1"))

        // After finalization: thinking isDone, then assistant message
        #expect(reducer.items.count == 2)
        guard case .thinking(_, _, _, let finalDone) = reducer.items[0] else {
            Issue.record("Expected thinking item after finalization")
            return
        }
        #expect(finalDone)
    }

    @MainActor
    @Test func multipleAgentTurns() {
        let reducer = TimelineReducer()

        // Turn 1
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "First"))
        reducer.process(.agentEnd(sessionId: "s1"))

        // Turn 2
        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Second"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let assistants = reducer.items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }
        #expect(assistants.count == 2)

        guard case .assistantMessage(_, let t1, _) = assistants[0],
              case .assistantMessage(_, let t2, _) = assistants[1] else {
            Issue.record("Expected two assistant messages")
            return
        }
        #expect(t1 == "First")
        #expect(t2 == "Second")
    }

    @MainActor
    @Test func agentEndWithoutContentProducesNoItems() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.agentEnd(sessionId: "s1"))

        // No text deltas → no assistant message or thinking item
        #expect(reducer.items.isEmpty)
    }

    @MainActor
    @Test func appendUserMessage() {
        let reducer = TimelineReducer()
        reducer.appendUserMessage("Hello from user")

        #expect(reducer.items.count == 1)
        guard case .userMessage(_, let text, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(text == "Hello from user")
    }

    @MainActor
    @Test func appendSystemEvent() {
        let reducer = TimelineReducer()

        reducer.appendSystemEvent("Session force-stopped")

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent")
            return
        }
        #expect(msg == "Session force-stopped")
    }

    @MainActor
    @Test func retryStartRendersAsSystemEvent() {
        let reducer = TimelineReducer()
        reducer.process(.retryStart(sessionId: "s1", attempt: 1, maxAttempts: 3, delayMs: 2000, errorMessage: "rate limit"))

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent for retry, got \(reducer.items[0])")
            return
        }
        #expect(msg.contains("Retrying"))
        #expect(msg.contains("1/3"))
    }

    @MainActor
    @Test func realErrorRendersAsError() {
        let reducer = TimelineReducer()
        reducer.process(.error(sessionId: "s1", message: "Something went wrong"))

        guard case .error(_, let msg) = reducer.items[0] else {
            Issue.record("Expected error")
            return
        }
        #expect(msg == "Something went wrong")
    }
}
