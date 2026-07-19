import Foundation
import Testing
@testable import Oppi

@Suite("SessionRowPresentationBuilder")
struct SessionRowPresentationBuilderTests {
    private func makeSession(
        id: String,
        status: SessionStatus = .stopped,
        model: String? = "openai/gpt-5.5",
        cost: Double = 1,
        filesChanged: Int = 0,
        compactions: Int = 0
    ) -> Session {
        let stats = SessionChangeStats(
            mutatingToolCalls: filesChanged,
            compactionCount: compactions,
            filesChanged: filesChanged,
            changedFiles: (0..<filesChanged).map { "file-\($0).swift" },
            addedLines: 0,
            removedLines: 0
        )
        return Session(
            id: id,
            workspaceId: "ws1",
            workspaceName: "Workspace",
            name: "Session \(id)",
            status: status,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 2),
            model: model,
            messageCount: 1,
            tokens: TokenUsage(input: 10, output: 5),
            cost: cost,
            changeStats: stats,
            contextTokens: nil,
            contextWindow: nil,
            firstMessage: "hello",
            lastMessage: nil,
            thinkingLevel: nil
        )
    }

    @Test func stoppedPresentationDoesNotRenderAttentionText() {
        let session = makeSession(id: "root", filesChanged: 3)
        let presentation = SessionRowPresentationBuilder.make(session: session)

        #expect(presentation.attentionText == nil)
        #expect(presentation.session.changeStats?.filesChanged == 3)
    }

    @Test func pendingAskPresentationShowsFirstQuestion() {
        let session = makeSession(id: "root", status: .busy)
        let ask = AskRequest(
            id: "ask-1",
            sessionId: session.id,
            questions: [AskQuestion(id: "q1", question: "Which branch should I use?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        let presentation = SessionRowPresentationBuilder.make(session: session, pendingAsk: ask)

        #expect(presentation.attentionText == "question: Which branch should I use?")
    }

    @Test func unreadCompletionDateIsCarriedToRowPresentation() {
        let session = makeSession(id: "root", status: .ready)
        let completedAt = Date(timeIntervalSince1970: 7)
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            unreadCompletionAt: completedAt
        )

        #expect(presentation.unreadCompletionAt == completedAt)
    }

    @Test func workspaceContextIsTrimmedAndCarriedToRowPresentation() {
        let session = makeSession(id: "root", status: .ready)
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            workspaceContext: "  dotfiles  "
        )

        #expect(presentation.workspaceContext == "dotfiles")
    }

    @Test func attentionCountsUseSessionPendingCount() {
        let counts = SessionRowPresentationBuilder.attentionCounts(
            sessionId: "session-1",
            pendingAskCountForSession: { $0 == "session-1" ? 1 : 0 }
        )

        #expect(counts.askCount == 1)
    }

    @Test func controlSessionUsesOppiControlContextWithoutWorkspace() throws {
        let data = Data(#"{"id":"control-1","status":"ready","createdAt":1000,"lastActivity":2000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"workspaces","intent":"create"}}"#.utf8)
        let session = try JSONDecoder().decode(Session.self, from: data)
        let summary = try JSONDecoder().decode(SessionSummary.self, from: data)
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            workspaceContext: session.control == nil ? nil : "Oppi Control"
        )

        #expect(session.workspaceId == nil)
        #expect(session.control?.domain == .workspaces)
        #expect(summary.control == session.control)
        #expect(summary.session.control == session.control)
        #expect(SessionInboxSessionRouting.routeScope(for: session) == .control)
        #expect(SessionRouteScope.control.composerDraftScopeID == "__oppi_control__")
        #expect(SessionInboxSessionRouting.allSessionsContext(for: session, workspaceName: nil) == "Oppi Control")
        #expect(presentation.workspaceContext == "Oppi Control")

        let roundTrip = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        #expect(roundTrip == session)
    }

    @MainActor
    @Test func globalRecentProjectionRetainsDeclaredControlSession() throws {
        let data = Data(#"{"id":"control-1","status":"ready","createdAt":1000,"lastActivity":2000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"create"}}"#.utf8)
        let session = try JSONDecoder().decode(Session.self, from: data)
        let store = SessionStore()
        store.switchServer(to: "server-1")

        store.applyRecentWorkspaceSummaryProjection(
            workspaceIds: Set(["workspace-1"]),
            summaries: [SessionSummary(from: session)]
        )

        #expect(store.listProjectionSessions.map(\.id) == ["control-1"])
        #expect(store.routeScope(for: "control-1") == .control)
    }
}
