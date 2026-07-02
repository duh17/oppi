import Foundation
import Testing
@testable import Oppi

@Suite("Mac session command pending changes")
struct MacSessionCommandPendingChangeTests {

    @Test func modelRollbackRestoresOnlyMatchingOptimisticValue() {
        var session: Session? = makeSession(model: "openai/new", thinkingLevel: "medium")
        let change = MacSessionCommandPendingChange.model(previous: "openai/old", optimistic: "openai/new")

        #expect(change.rollbackIfStillOptimistic(session: &session))
        #expect(session?.model == "openai/old")
    }

    @Test func modelRollbackDoesNotClobberNewerState() {
        var session: Session? = makeSession(model: "anthropic/latest", thinkingLevel: "medium")
        let change = MacSessionCommandPendingChange.model(previous: "openai/old", optimistic: "openai/new")

        #expect(!change.rollbackIfStillOptimistic(session: &session))
        #expect(session?.model == "anthropic/latest")
    }

    @Test func thinkingRollbackRestoresOnlyMatchingOptimisticValue() {
        var session: Session? = makeSession(model: "openai/gpt", thinkingLevel: "high")
        let change = MacSessionCommandPendingChange.thinking(previous: "medium", optimistic: "high")

        #expect(change.rollbackIfStillOptimistic(session: &session))
        #expect(session?.thinkingLevel == "medium")
    }

    private func makeSession(model: String?, thinkingLevel: String?) -> Session {
        Session(
            id: "session-1",
            workspaceId: "ws-1",
            workspaceName: "Oppi",
            name: "Test",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 2),
            model: model,
            messageCount: 1,
            tokens: TokenUsage(input: 1, output: 1),
            cost: 0,
            firstMessage: "hello",
            thinkingLevel: thinkingLevel
        )
    }
}
