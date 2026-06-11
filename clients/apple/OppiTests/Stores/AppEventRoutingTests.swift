import Foundation
import Testing
@testable import Oppi

@Suite("App event routing")
@MainActor
struct AppEventRoutingTests {
    @Test func extensionRequestAndSettledUpdateNonFocusedAttentionWithoutTimelineRouting() {
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("focused")
        connection.sessionStore.upsert(makeTestSession(id: "s2", workspaceId: "w1", status: .busy))

        let request = ExtensionUIRequest(
            id: "ask-1",
            sessionId: "s2",
            method: "ask",
            askQuestions: [
                AskQuestion(
                    id: "q1",
                    question: "Approve?",
                    options: [AskOption(value: "yes", label: "Yes")],
                    multiSelect: false
                )
            ],
            allowCustom: false
        )

        connection.handleAppEvent(
            .extensionUIRequest(request: request, workspaceId: "w1", emittedAt: 1)
        )

        let pending = connection.askRequestStore.pending(for: "s2")
        #expect(pending?.id == "ask-1")
        #expect(pending?.workspaceId == "w1")
        #expect(appEventBadgeCount(connection, sessionId: "s2") == 1)

        connection.handleAppEvent(
            .extensionUISettled(id: "ask-1", sessionId: "s2", workspaceId: "w1", emittedAt: 2)
        )

        #expect(connection.askRequestStore.pending(for: "s2") == nil)
        #expect(appEventBadgeCount(connection, sessionId: "s2") == 0)
    }

    @Test func followingSummaryWithPendingAskCountZeroClearsListBadge() {
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("focused")
        var initial = SessionSummary(from: makeTestSession(id: "s2", workspaceId: "w1", status: .busy))
        initial.pendingAskCount = 2
        connection.sessionStore.upsertManySummaries([initial])
        #expect(appEventBadgeCount(connection, sessionId: "s2") == 2)

        var clearing = SessionSummary(from: makeTestSession(id: "s2", workspaceId: "w1", status: .busy))
        clearing.pendingAskCount = 0
        connection.handleAppEvent(
            .sessionSummary(sessionId: "s2", workspaceId: "w1", emittedAt: 3, summary: clearing)
        )

        #expect(connection.sessionStore.listPendingAskCount(for: "s2") == 0)
        #expect(appEventBadgeCount(connection, sessionId: "s2") == 0)
    }

    @Test func sessionSummaryRoutesToSessionStoreWithoutFocusedContinuation() {
        let connection = ServerConnection()
        connection._setActiveSessionIdForTesting("focused")
        let summary = SessionSummary(from: makeTestSession(
            id: "s2",
            workspaceId: "w1",
            status: .ready,
            firstMessage: "Background work"
        ))

        connection.handleAppEvent(
            .sessionSummary(sessionId: "s2", workspaceId: "w1", emittedAt: 4, summary: summary)
        )

        #expect(connection.sessionStore.session(id: "s2")?.firstMessage == "Background work")
        #expect(connection.sessionEventContinuations["s2"] == nil)
    }
}

@MainActor
private func appEventBadgeCount(_ connection: ServerConnection, sessionId: String) -> Int {
    SessionListAttentionMerger.askCount(
        listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
        hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
        hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
    )
}
