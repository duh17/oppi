import Testing
import Foundation
@testable import PiRemote

@Suite("TimelineReducer")
struct TimelineReducerTests {

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
        guard case .thinking(_, let preview, _) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(preview.contains("I need to think"))
    }

    @MainActor
    @Test func toolCallSequence() {
        let reducer = TimelineReducer()
        let toolId = "tool-1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: ["command": "ls"]))
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: toolId, output: "file1.txt\nfile2.txt", isError: false))
        reducer.process(.toolEnd(sessionId: "s1", toolEventId: toolId))
        reducer.process(.agentEnd(sessionId: "s1"))

        let toolItems = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }
        #expect(toolItems.count == 1)

        guard case .toolCall(_, let tool, _, let preview, let bytes, let isError, let isDone) = toolItems[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tool == "bash")
        #expect(preview.contains("file1.txt"))
        #expect(bytes > 0)
        #expect(!isError)
        #expect(isDone)
    }

    @MainActor
    @Test func permissionInTimeline() {
        let reducer = TimelineReducer()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: ["command": "rm -rf /"],
            displaySummary: "bash: rm -rf /",
            risk: .critical, reason: "Destructive",
            timeoutAt: Date().addingTimeInterval(120)
        )

        reducer.process(.permissionRequest(perm))
        #expect(reducer.items.count == 1)
        guard case .permission(let req) = reducer.items[0] else {
            Issue.record("Expected permission")
            return
        }
        #expect(req.id == "p1")

        // Resolve
        reducer.resolvePermission(id: "p1", action: .deny)
        guard case .permissionResolved(_, let action) = reducer.items[0] else {
            Issue.record("Expected permissionResolved")
            return
        }
        #expect(action == .deny)
    }

    @MainActor
    @Test func retryErrorRendersAsSystemEvent() {
        let reducer = TimelineReducer()
        reducer.process(.error(sessionId: "s1", message: "Retrying (1/3): rate limit"))

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let msg) = reducer.items[0] else {
            Issue.record("Expected systemEvent for retry, got \(reducer.items[0])")
            return
        }
        #expect(msg.contains("Retrying"))
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

    @MainActor
    @Test func loadFromREST() {
        let reducer = TimelineReducer()
        let messages = [
            SessionMessage.stub(
                id: "m1", sessionId: "s1", role: .user,
                content: "Hello", timestamp: Date()
            ),
            SessionMessage.stub(
                id: "m2", sessionId: "s1", role: .assistant,
                content: "Hi there!", timestamp: Date()
            ),
        ]

        reducer.loadFromREST(messages)
        #expect(reducer.items.count == 2)
        guard case .userMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(text == "Hello")
    }
}

// MARK: - SessionMessage factory for tests

extension SessionMessage {
    static func stub(
        id: String, sessionId: String, role: MessageRole,
        content: String, timestamp: Date
    ) -> SessionMessage {
        // Encode → decode round-trip to satisfy the Codable init with let properties
        let tsMs = timestamp.timeIntervalSince1970 * 1000
        let json = """
        {"id":"\(id)","sessionId":"\(sessionId)","role":"\(role.rawValue)","content":"\(content)","timestamp":\(tsMs)}
        """
        return try! JSONDecoder().decode(SessionMessage.self, from: json.data(using: .utf8)!)
    }
}
