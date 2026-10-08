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
            workspaceContext: session.control == nil ? nil : "Pi Control"
        )

        #expect(session.workspaceId == nil)
        #expect(session.control?.domain == .workspaces)
        #expect(summary.control == session.control)
        #expect(summary.session.control == session.control)
        #expect(SessionInboxSessionRouting.routeScope(for: session) == .control)
        #expect(SessionRouteScope.control.composerDraftScopeID == "__oppi_control__")
        #expect(SessionInboxSessionRouting.allSessionsContext(for: session, workspaceName: nil) == "Pi Control")
        #expect(presentation.workspaceContext == "Pi Control")

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

    @Test func controlConversationDecodesRoleAndUsesControlRoute() throws {
        let full = Data(#"{"id":"cc-1","name":"Oppi Control","status":"ready","createdAt":1000,"lastActivity":2000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"serverDurable":{"conversationId":7,"role":"control"}}"#.utf8)
        let summaryJSON = Data(#"{"id":"cc-1","name":"Oppi Control","status":"ready","createdAt":1000,"lastActivity":3000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"engine":"durable","serverDurable":{"role":"control"}}"#.utf8)
        let session = try JSONDecoder().decode(Session.self, from: full)
        let summary = try JSONDecoder().decode(SessionSummary.self, from: summaryJSON)

        #expect(session.engine == .durable)
        #expect(session.serverDurableRole == "control")
        #expect(session.isControlConversation)
        #expect(session.control == nil)
        #expect(session.workspaceId == nil)
        #expect(SessionInboxSessionRouting.routeScope(for: session) == .control)
        #expect(summary.engine == .durable)
        #expect(summary.serverDurableRole == "control")
        #expect(summary.session.isControlConversation)
        #expect(SessionInboxSessionRouting.routeScope(for: summary.session) == .control)
        #expect(SessionInboxSessionRouting.allSessionsContext(for: session, workspaceName: "Elsewhere") == "Oppi Control")

        let durable = try JSONDecoder().decode(
            Session.self,
            from: Data(#"{"id":"d1","status":"ready","createdAt":1000,"lastActivity":2000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"workspaceId":"ws-1","serverDurable":{"conversationId":3}}"#.utf8)
        )
        #expect(durable.engine == .durable)
        #expect(durable.serverDurableRole == nil)
        #expect(!durable.isControlConversation)
        #expect(SessionInboxSessionRouting.routeScope(for: durable) == .workspace("ws-1"))

        let roundTrip = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        #expect(roundTrip == session)
        #expect(roundTrip.serverDurableRole == "control")
        #expect(roundTrip.engine == .durable)
    }

    @Test func controlConversationRoleThrowsWhenPresentAndNonString() throws {
        let absentRole = Data(#"{"id":"d1","status":"ready","createdAt":1000,"lastActivity":2000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"workspaceId":"ws-1","serverDurable":{"conversationId":3}}"#.utf8)
        let session = try JSONDecoder().decode(Session.self, from: absentRole)
        let summary = try JSONDecoder().decode(SessionSummary.self, from: absentRole)
        #expect(session.serverDurableRole == nil)
        #expect(session.engine == .durable)
        #expect(!session.isControlConversation)
        #expect(summary.serverDurableRole == nil)
        #expect(summary.engine == .durable)

        let malformed = Data(#"{"id":"u1","status":"ready","createdAt":1000,"lastActivity":2000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"workspaceId":"ws-1","serverDurable":{"conversationId":7,"role":42}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Session.self, from: malformed)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SessionSummary.self, from: malformed)
        }
    }

    @MainActor
    @Test func globalRecentProjectionRetainsControlConversationOutsideWorkspaceCatalogs() throws {
        let conversation = try JSONDecoder().decode(
            SessionSummary.self,
            from: Data(#"{"id":"cc-1","name":"Oppi Control","status":"ready","createdAt":1000,"lastActivity":3000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"engine":"durable","serverDurable":{"role":"control"}}"#.utf8)
        )
        let workspace = try JSONDecoder().decode(
            SessionSummary.self,
            from: Data(#"{"id":"ws-row","status":"ready","createdAt":1000,"lastActivity":2000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"workspaceId":"workspace-1"}"#.utf8)
        )
        let declared = try JSONDecoder().decode(
            SessionSummary.self,
            from: Data(#"{"id":"control-1","status":"ready","createdAt":1000,"lastActivity":1000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"create"}}"#.utf8)
        )
        let store = SessionStore()
        store.switchServer(to: "server-1")
        store.applyRecentWorkspaceSummaryProjection(
            workspaceIds: Set(["workspace-1"]),
            summaries: [conversation, workspace, declared]
        )

        #expect(store.listProjectionSessions.map(\.id) == ["cc-1", "ws-row", "control-1"])
        #expect(store.session(id: "cc-1")?.workspaceId == nil)
        #expect(store.session(id: "cc-1")?.isControlConversation == true)
        #expect(store.routeScope(for: "cc-1") == .control)
        #expect(store.routeScope(for: "control-1") == .control)
        #expect(store.routeScope(for: "ws-row") == .workspace("workspace-1"))
        #expect(store.listProjectionSessions(workspaceId: "workspace-1").map(\.id).contains("ws-row"))
        #expect(!store.listProjectionSessions(workspaceId: "workspace-1").map(\.id).contains("cc-1"))
        #expect(!DurableSessionsPlayground.isListed(conversation.session))
        #expect(!DurableSessionsPlayground.isListed(declared.session))
    }

    @Test func modelSummaryUsesCatalogDisplayNameWhenPresent() {
        let session = makeSession(
            id: "mlx",
            model: "mlx-serve/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
        )
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            catalogModels: [
                ModelInfo(
                    id: "mlx-serve/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit",
                    name: "Qwen 3.8 Flash Next",
                    provider: "mlx-serve",
                    contextWindow: 200_000
                ),
            ]
        )

        #expect(presentation.modelSummaries.first?.label == "Qwen 3.8 Flash Next")
        #expect(presentation.modelSummaries.first?.provider == "mlx-serve")
    }

    @Test func modelSummaryUsesLastPathComponentWithoutCatalog() {
        let session = makeSession(
            id: "mlx",
            model: "mlx-serve/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
        )
        let presentation = SessionRowPresentationBuilder.make(session: session)

        #expect(presentation.modelSummaries.first?.label == "Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit")
    }
}
