import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session trace projection")
struct MacSessionTraceStoreProjectionTests {
    @Test func ignoresConnectedMessagesForOtherSessions() {
        let store = MacSessionTraceStore()
        let target = makeTarget(sessionId: "selected-session", status: .ready)
        store.select(target)

        store.applyServerMessageForTesting(
            .connected(session: makeSession(id: "other-session", status: .busy)),
            target: target
        )

        #expect(store.session?.id == "selected-session")
        #expect(store.session?.status == .ready)
    }

    @Test func appliesConnectedMessagesForSelectedSession() {
        let store = MacSessionTraceStore()
        let target = makeTarget(sessionId: "selected-session", status: .ready)
        store.select(target)

        store.applyServerMessageForTesting(
            .connected(session: makeSession(id: "selected-session", status: .busy)),
            target: target
        )

        #expect(store.session?.id == "selected-session")
        #expect(store.session?.status == .busy)
    }

    private func makeTarget(sessionId: String, status: SessionStatus) -> MacSelectedSessionTarget {
        let session = makeSession(id: sessionId, status: status)
        return MacSelectedSessionTarget(
            workspaceId: "workspace-projection",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }

    private func makeSession(id: String, status: SessionStatus) -> Session {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return Session(
            id: id,
            workspaceId: "workspace-projection",
            workspaceName: "Workspace",
            status: status,
            createdAt: now,
            lastActivity: now,
            model: "provider/model",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            firstMessage: "Hello"
        )
    }
}
