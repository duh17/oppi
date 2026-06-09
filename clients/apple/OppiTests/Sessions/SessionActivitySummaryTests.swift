import Foundation
import Testing
@testable import Oppi

@Suite("SessionActivitySummary")
struct SessionActivitySummaryTests {

    // MARK: - Test helpers

    private func makeSession(
        id: String = "s1",
        status: SessionStatus = .busy,
        messageCount: Int = 5,
        firstMessage: String? = "hello",
        changeStats: SessionChangeStats? = nil
    ) -> Session {
        Session(
            id: id,
            workspaceId: "ws1",
            workspaceName: "Test",
            name: "Test Session",
            status: status,
            createdAt: Date(),
            lastActivity: Date(),
            model: "test/model",
            messageCount: messageCount,
            tokens: TokenUsage(input: 100, output: 50),
            cost: 1.50,
            changeStats: changeStats,
            contextTokens: nil,
            contextWindow: nil,
            firstMessage: firstMessage,
            lastMessage: nil,
            thinkingLevel: nil
        )
    }

    // MARK: - Working sessions

    @Test func working_showsToolActivity() {
        let session = makeSession(status: .busy)
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: "server/src/types.ts")
        let result = SessionActivitySummary.text(
            session: session,
            activity: activity
        )
        #expect(result == "reading src/types.ts")
    }

    @Test func working_noActivity_returnsNil() {
        let session = makeSession(status: .busy)
        let result = SessionActivitySummary.text(
            session: session,
            activity: nil
        )
        #expect(result == nil)
    }

    @Test func starting_showsToolActivity() {
        let session = makeSession(status: .starting)
        let activity = SessionActivityStore.Activity(toolName: "Write", keyArg: "output.txt")
        let result = SessionActivitySummary.text(
            session: session,
            activity: activity
        )
        #expect(result == "writing output.txt")
    }

    // MARK: - Idle sessions

    @Test func idle_showsTurnEnded() {
        let session = makeSession(status: .ready)
        let result = SessionActivitySummary.text(
            session: session,
            activity: nil
        )
        #expect(result == nil)
    }

    @Test func blankDraftReady_returnsNil() {
        let session = makeSession(status: .ready, messageCount: 0, firstMessage: nil)
        let result = SessionActivitySummary.text(
            session: session,
            activity: nil
        )
        #expect(result == nil)
    }

    // MARK: - Stopped sessions

    @Test func stopped_omitsFileCountFromActivitySummary() {
        let stats = SessionChangeStats(
            mutatingToolCalls: 5,
            filesChanged: 3,
            changedFiles: ["a.swift", "b.swift", "c.swift"],
            addedLines: 50,
            removedLines: 10
        )
        let session = makeSession(status: .stopped, changeStats: stats)
        let result = SessionActivitySummary.text(
            session: session,
            activity: nil
        )
        #expect(result == nil)
    }

    @Test func stopped_noChanges_returnsNil() {
        let session = makeSession(status: .stopped)
        let result = SessionActivitySummary.text(
            session: session,
            activity: nil
        )
        #expect(result == nil)
    }

    // MARK: - Error sessions

    @Test func error_showsAgentError() {
        let session = makeSession(status: .error)
        let result = SessionActivitySummary.text(
            session: session,
            activity: nil
        )
        #expect(result == "agent error")
    }

    // MARK: - formatToolActivity

    @Test func formatToolActivity_readVerb() {
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: "a/b/c/file.swift")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "reading c/file.swift")
    }

    @Test func formatToolActivity_editVerb() {
        let activity = SessionActivityStore.Activity(toolName: "Edit", keyArg: "src/main.swift")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "editing src/main.swift")
    }

    @Test func formatToolActivity_bashVerb() {
        let activity = SessionActivityStore.Activity(toolName: "Bash", keyArg: "npm test")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "running npm test")
    }

    @Test func formatToolActivity_noKeyArg() {
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: nil)
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "reading")
    }

    @Test func formatToolActivity_unknownTool() {
        let activity = SessionActivityStore.Activity(toolName: "custom_tool", keyArg: "worker-1")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "custom_tool worker-1")
    }

    @Test func formatToolActivity_shortPathNotTruncated() {
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: "file.swift")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "reading file.swift")
    }

    @Test func formatToolActivity_twoComponentPathKept() {
        let activity = SessionActivityStore.Activity(toolName: "Write", keyArg: "src/file.swift")
        let result = SessionActivitySummary.formatToolActivity(activity)
        #expect(result == "writing src/file.swift")
    }

    // MARK: - Pending ask questions

    @Test func pendingAsk_showsFirstQuestion() {
        let session = makeSession(status: .busy)
        let ask = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "What prefix do you want?", options: [
                AskOption(value: "a", label: "Option A"),
            ], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        let result = SessionActivitySummary.text(
            session: session,
            pendingAsk: ask,
            activity: nil
        )
        #expect(result == "question: What prefix do you want?")
    }

    @Test func pendingAsk_truncatesLongQuestion() {
        let session = makeSession(status: .busy)
        let longQuestion = String(repeating: "x", count: 60)
        let ask = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: longQuestion, options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        let result = SessionActivitySummary.text(
            session: session,
            pendingAsk: ask,
            activity: nil
        )
        #expect(result != nil)
        #expect(result!.hasPrefix("question:"))
        #expect(result!.hasSuffix("..."))
    }

    @Test func pendingAsk_overridesToolActivity() {
        let session = makeSession(status: .busy)
        let ask = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Which approach?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: "file.swift")
        let result = SessionActivitySummary.text(
            session: session,
            pendingAsk: ask,
            activity: activity
        )
        #expect(result?.hasPrefix("question:") == true)
    }

    @Test func nilAsk_fallsBackToNormalBehavior() {
        let session = makeSession(status: .busy)
        let activity = SessionActivityStore.Activity(toolName: "Read", keyArg: "server/src/types.ts")
        let result = SessionActivitySummary.text(
            session: session,
            pendingAsk: nil,
            activity: activity
        )
        #expect(result == "reading src/types.ts")
    }
}
