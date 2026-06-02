import Testing
import Foundation
@testable import Oppi

// swiftlint:disable force_try force_unwrapping

/// Tests confirming bugs found in the behavioral audit, and verifying fixes.
///
/// Bug 5: Optimistic user message not retracted on failed send
@Suite("Bug Bash")
@MainActor
struct BugBashTests {

    // MARK: - Bug 5: Optimistic user message not retracted on failed send

    @Test func appendUserMessageReturnsId() {
        let reducer = TimelineReducer()
        let id = reducer.appendUserMessage("Hello")

        #expect(!id.isEmpty)
        #expect(reducer.items.count == 1)
        guard case .userMessage(let itemId, let text, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(itemId == id)
        #expect(text == "Hello")
    }

    @Test func removeItemRetractsMessage() {
        let reducer = TimelineReducer()
        let id = reducer.appendUserMessage("oops")

        #expect(reducer.items.count == 1)

        reducer.removeItem(id: id)

        #expect(reducer.items.isEmpty, "Message should be retracted after removeItem")
    }

    @Test func removeItemOnlyRemovesTarget() {
        let reducer = TimelineReducer()
        let id1 = reducer.appendUserMessage("first")
        _ = reducer.appendUserMessage("second")

        #expect(reducer.items.count == 2)

        reducer.removeItem(id: id1)

        #expect(reducer.items.count == 1)
        guard case .userMessage(_, let text, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(text == "second")
    }

    @Test func removeNonexistentItemIsNoOp() {
        let reducer = TimelineReducer()
        _ = reducer.appendUserMessage("keep")

        reducer.removeItem(id: "nonexistent")

        #expect(reducer.items.count == 1, "Should not affect existing items")
    }

    @Test func removeItemBumpsRenderVersion() {
        let reducer = TimelineReducer()
        let id = reducer.appendUserMessage("test")
        let versionBefore = reducer.renderVersion

        reducer.removeItem(id: id)

        #expect(reducer.renderVersion > versionBefore)
    }

    // Bug 1 (reconnectIfNeeded clobbers timeline) fixed:
    // loadFromREST removed entirely — trace is the only history path.
    // Trace preserves tool calls, thinking, and structured output.

    @Test func loadSessionPreservesToolCalls() {
        let reducer = TimelineReducer()

        let trace = [
            decodeTrace("""
            {"id":"e1","type":"toolCall","timestamp":"2025-01-01T00:00:00Z","tool":"bash","args":{"command":{"type":"string","value":"ls"}}}
            """),
            decodeTrace("""
            {"id":"e2","type":"toolResult","timestamp":"2025-01-01T00:00:01Z","toolCallId":"e1","output":"file.txt"}
            """),
            decodeTrace("""
            {"id":"e3","type":"assistant","timestamp":"2025-01-01T00:00:02Z","text":"Here are the files"}
            """),
        ]

        reducer.loadSession(trace)

        let tools = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(tools.count == 1, "loadSession preserves tool call rows")
        #expect(reducer.items.count == 2) // tool + assistant
    }

    // MARK: - Helpers

    private func decodeTrace(_ json: String) -> TraceEvent {
        try! JSONDecoder().decode(TraceEvent.self, from: json.data(using: .utf8)!)
    }
}
