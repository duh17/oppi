import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac workspace snapshot store")
struct MacWorkspaceSnapshotStoreTests {

    @Test func exposesWorkspaceSessionTargetsNewestFirst() {
        let store = MacWorkspaceSnapshotStore()
        let workspace = Workspace(
            id: "ws-1",
            name: "Oppi",
            description: nil,
            icon: "folder",
            systemPrompt: nil,
            hostMount: "/Users/chenda/workspace/oppi",
            defaultModel: nil,
            tools: nil,
            gitStatusEnabled: nil,
            runtime: .host,
            sandboxConfig: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let older = makeSummary(id: "older", workspaceId: "ws-1", status: .stopped, lastActivity: 1_000)
        let newer = makeSummary(id: "newer", workspaceId: "ws-1", status: .ready, lastActivity: 2_000)
        store._setCatalogForTesting(
            workspaces: [workspace],
            sessionsByWorkspace: [
                "ws-1": MacWorkspaceClient.WorkspaceSessionList(
                    workspaceId: "ws-1",
                    serverNow: 2_100,
                    active: [newer],
                    stopped: [older],
                    importableSessions: []
                )
            ]
        )

        #expect(store.sessionTargets.map(\.sessionId) == ["newer", "older"])
        #expect(store.target(for: "newer")?.workspaceId == "ws-1")
    }

    @Test func busySessionTargetsSortAheadOfNewerIdleSessions() {
        let store = MacWorkspaceSnapshotStore()
        let busy = makeSummary(id: "busy", workspaceId: "ws-1", status: .busy, lastActivity: 1_000)
        let ready = makeSummary(id: "ready", workspaceId: "ws-1", status: .ready, lastActivity: 2_000)
        store._setCatalogForTesting(
            workspaces: [],
            sessionsByWorkspace: [
                "ws-1": MacWorkspaceClient.WorkspaceSessionList(
                    workspaceId: "ws-1",
                    serverNow: 2_100,
                    active: [busy, ready],
                    stopped: [],
                    importableSessions: []
                )
            ]
        )

        #expect(store.sessionTargets.map(\.sessionId) == ["busy", "ready"])
    }

    private func makeSummary(
        id: String,
        workspaceId: String,
        status: SessionStatus,
        lastActivity: TimeInterval
    ) -> SessionSummary {
        SessionSummary(from: Session(
            id: id,
            workspaceId: workspaceId,
            workspaceName: "Oppi",
            name: id.capitalized,
            status: status,
            createdAt: Date(timeIntervalSince1970: 900),
            lastActivity: Date(timeIntervalSince1970: lastActivity),
            model: "openai/gpt-5.5",
            messageCount: 1,
            tokens: TokenUsage(input: 1, output: 2),
            cost: 0.01,
            firstMessage: "Hello from \(id)"
        ))
    }
}
