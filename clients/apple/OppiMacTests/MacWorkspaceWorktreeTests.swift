import Foundation
import Testing
@testable import Oppi

@Suite("Mac workspace worktree switching")
struct MacWorkspaceWorktreeTests {
    @Test func inboxRowsKeepWorktreeMetadataOutsideTheNarrowScanPath() throws {
        let inbox = try source(named: "OppiMac/Views/MacSessionInboxRow.swift")
        let presentation = try source(named: "OppiMac/Views/MacSessionInboxPresentation.swift")

        #expect(inbox.contains("MacSessionInboxRowPaint.secondaryAccessibilityValue"))
        #expect(inbox.contains(".accessibilityValue(secondaryMetadata)"))
        #expect(inbox.contains(".help(secondaryMetadata)"))
        #expect(presentation.contains("SessionWorktreeIndicatorPresentation"))
        #expect(presentation.contains("parts.append(\"Worktree"))
        #expect(!inbox.contains("worktreeIndicatorView"))
        #expect(!inbox.contains("listWorkspaceWorktrees"))
    }

    @Test func visibleWorktreesFallBackToMainWhenTheServerListIsEmpty() {
        let visible = MacWorkspaceWorktreePresentation.visibleWorktrees(
            fetched: [],
            hostMount: "/tmp/oppi"
        )

        #expect(visible.map(\.id) == [WorkspaceWorktree.mainId])
        #expect(visible.first?.isMain == true)
        #expect(visible.first?.path == "/tmp/oppi")
        #expect(visible.first?.displayName == "Main")
        #expect(
            !MacWorkspaceWorktreePresentation.canSwitch(
                visibleWorktrees: visible,
                isLoading: false
            )
        )
    }

    @Test func switcherAppearsOnlyWhenMultipleCheckoutsAreLoaded() {
        let main = makeWorktree(id: WorkspaceWorktree.mainId, isMain: true, branch: "main", sessionCount: 4)
        let feature = makeWorktree(id: "wt_feature", isMain: false, branch: "feat/mac-app", sessionCount: 2)

        #expect(
            !MacWorkspaceWorktreePresentation.canSwitch(
                visibleWorktrees: [main],
                isLoading: false
            )
        )
        #expect(
            MacWorkspaceWorktreePresentation.canSwitch(
                visibleWorktrees: [main, feature],
                isLoading: false
            )
        )
        #expect(
            !MacWorkspaceWorktreePresentation.canSwitch(
                visibleWorktrees: [main, feature],
                isLoading: true
            )
        )
    }

    @Test func missingSelectedCheckoutFallsBackToTheFirstFetchedWorktree() {
        let feature = makeWorktree(id: "wt_feature", isMain: false, branch: "feat/mac-app", sessionCount: nil)

        #expect(
            MacWorkspaceWorktreePresentation.resolvedSelectedId(
                "wt_gone",
                in: [feature]
            ) == "wt_feature"
        )
        #expect(
            MacWorkspaceWorktreePresentation.resolvedSelectedId(
                "wt_feature",
                in: [feature]
            ) == "wt_feature"
        )
        #expect(
            MacWorkspaceWorktreePresentation.resolvedSelectedId(
                "wt_feature",
                in: []
            ) == WorkspaceWorktree.mainId
        )
    }

    @Test func sessionListFilterMatchesIosMissingWorktreeIdAsMain() {
        let main = makeSummary(id: "main-session", worktreeId: nil)
        let explicitMain = makeSummary(id: "explicit-main", worktreeId: WorkspaceWorktree.mainId)
        let feature = makeSummary(id: "feature-session", worktreeId: "wt_feature")

        #expect(
            MacWorkspaceWorktreePresentation.filterSessions(
                [main, explicitMain, feature],
                selectedId: WorkspaceWorktree.mainId
            ).map(\.id) == ["main-session", "explicit-main"]
        )
        #expect(
            MacWorkspaceWorktreePresentation.filterSessions(
                [main, explicitMain, feature],
                selectedId: "wt_feature"
            ).map(\.id) == ["feature-session"]
        )
    }

    @Test func menuTitleUsesSharedFormatting() {
        let main = makeWorktree(id: WorkspaceWorktree.mainId, isMain: true, branch: "main", sessionCount: 7)
        let feature = makeWorktree(
            id: "wt_feature",
            isMain: false,
            branch: "feat/mac-app",
            sessionCount: 1_452
        )
        let unknown = makeWorktree(id: "wt_unknown", isMain: false, branch: "feat/unknown", sessionCount: nil)

        #expect(MacWorkspaceWorktreePresentation.menuTitle(for: main) == "Main · 7")
        #expect(MacWorkspaceWorktreePresentation.menuTitle(for: feature) == "feat/mac-app · 1.5k")
        #expect(MacWorkspaceWorktreePresentation.menuTitle(for: unknown) == "feat/unknown")
        #expect(WorkspaceWorktreeMenuFormatting.accessibilityLabel(for: main) == "Main, 7 sessions")
    }

    @Test func listWorkspaceWorktreesUsesOwnerSocketAndSharedModel() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {
                  "workspaceId": "ws-1",
                  "worktrees": [
                    {
                      "id": "main",
                      "name": "oppi",
                      "path": "/tmp/oppi",
                      "branch": "main",
                      "headSha": "abc1234",
                      "isMain": true,
                      "isGitRepo": true,
                      "sessionCount": 4
                    },
                    {
                      "id": "wt_feature",
                      "name": "feat-mac-app",
                      "path": "/tmp/oppi-feature",
                      "branch": "feat/mac-app",
                      "headSha": "def5678",
                      "isMain": false,
                      "isGitRepo": true,
                      "managedByOppi": true,
                      "sessionCount": 2
                    }
                  ]
                }
                """#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let worktrees = try await client.listWorkspaceWorktrees(workspaceId: "ws-1")

        #expect(worktrees.map(\.id) == ["main", "wt_feature"])
        #expect(worktrees.first?.displayName == "Main")
        #expect(worktrees.last?.displayName == "feat/mac-app")
        #expect(worktrees.last?.sessionCount == 2)
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/workspaces/ws-1/worktrees")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("/worktrees/open"))
    }

    @Test func createWorkspaceSessionEncodesSelectedWorktreeId() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"session":{"id":"session-new","workspaceId":"ws-1","worktreeId":"wt_feature","name":"New","status":"busy","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0},"prompted":true}
                """#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let response = try await client.createWorkspaceSession(
            workspaceId: "ws-1",
            prompt: "Ship the Mac switcher",
            worktreeId: "wt_feature"
        )

        #expect(response.session.id == "session-new")
        #expect(response.session.worktreeId == "wt_feature")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/workspaces/ws-1/sessions")
        let body = try JSONDecoder().decode(
            CreateWorkspaceSessionBody.self,
            from: try #require(request.body)
        )
        #expect(body.prompt == "Ship the Mac switcher")
        #expect(body.worktreeId == "wt_feature")
    }

    @MainActor
    @Test func snapshotStoreCreatesSessionsInTheSelectedWorktree() async throws {
        let transport = SnapshotSequencedLocalHTTPTransport(responses: [
            MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"session":{"id":"session-new","workspaceId":"ws-1","worktreeId":"wt_feature","name":"New","status":"busy","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0},"prompted":true}
                """#.utf8)
            ),
            MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"workspaceId":"ws-1","serverNow":1760000003000,"active":[],"stopped":[]}
                """#.utf8)
            ),
        ])
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacWorkspaceSnapshotStore()

        let target = await store.createSession(
            workspaceId: "ws-1",
            prompt: "Work in the feature checkout",
            worktreeId: "wt_feature",
            client: client
        )

        #expect(target?.sessionId == "session-new")
        #expect(target?.summary.worktreeId == "wt_feature")
        #expect(store.createSessionError == nil)
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["POST", "GET"])
        #expect(requests[0].path == "/workspaces/ws-1/sessions")
        let body = try JSONDecoder().decode(
            CreateWorkspaceSessionBody.self,
            from: try #require(requests[0].body)
        )
        #expect(body.worktreeId == "wt_feature")
        #expect(queryValue("worktreeId", in: requests[1].path) == "wt_feature")
    }

    @Test func getWorkspaceSessionsSendsSelectedWorktreeId() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: sessionListJSON(sessionId: "feature-session", worktreeId: "wt_feature")
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let list = try await client.getWorkspaceSessions(
            workspaceId: "ws-1",
            since: Date(timeIntervalSince1970: 1_760_000_000),
            until: Date(timeIntervalSince1970: 1_760_000_300),
            worktreeId: "wt_feature"
        )

        #expect(list.active.map(\.id) == ["feature-session"])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path.hasPrefix("/workspaces/ws-1/sessions?"))
        #expect(queryValue("worktreeId", in: request.path) == "wt_feature")
        #expect(queryValue("status", in: request.path) == "active,stopped")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
    }

    @Test func getWorkspaceSessionsOmitsWorktreeQueryWhenUnscoped() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: sessionListJSON(sessionId: "main-session", worktreeId: "main")
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        _ = try await client.getWorkspaceSessions(
            workspaceId: "ws-1",
            since: Date(timeIntervalSince1970: 1_760_000_000),
            until: Date(timeIntervalSince1970: 1_760_000_300)
        )

        let request = try #require(await transport.requests.first)
        #expect(queryValue("worktreeId", in: request.path) == nil)
    }

    @MainActor
    @Test func switchingWorktreeReloadsSessionsForThatCheckout() async throws {
        let transport = SnapshotSequencedLocalHTTPTransport(responses: [
            MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: sessionListJSON(sessionId: "main-session", worktreeId: "main")
            ),
            MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: sessionListJSON(sessionId: "feature-session", worktreeId: "wt_feature")
            ),
        ])
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacWorkspaceSnapshotStore()
        let mainScope = MacWorkspaceWorktreePresentation.sessionScope(
            workspaceId: "ws-1",
            selectedWorktreeId: WorkspaceWorktree.mainId
        )
        let featureScope = MacWorkspaceWorktreePresentation.sessionScope(
            workspaceId: "ws-1",
            selectedWorktreeId: "wt_feature"
        )

        #expect(mainScope != featureScope)
        #expect(featureScope.worktreeId == "wt_feature")

        await store.loadSessions(
            workspaceId: mainScope.workspaceId,
            worktreeId: mainScope.worktreeId,
            client: client
        )
        #expect(store.sessions(for: "ws-1")?.active.map(\.id) == ["main-session"])

        await store.loadSessions(
            workspaceId: featureScope.workspaceId,
            worktreeId: featureScope.worktreeId,
            client: client
        )
        #expect(store.sessions(for: "ws-1")?.active.map(\.id) == ["feature-session"])

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "GET"])
        #expect(queryValue("worktreeId", in: requests[0].path) == "main")
        #expect(queryValue("worktreeId", in: requests[1].path) == "wt_feature")
        #expect(requests[0].path.hasPrefix("/workspaces/ws-1/sessions?"))
        #expect(requests[1].path.hasPrefix("/workspaces/ws-1/sessions?"))
    }

    @MainActor
    @Test func importLocalSessionPostsSelectedWorktreeId() async throws {
        let local = LocalSession(
            path: "/tmp/pi-session.jsonl",
            piSessionId: "pi-1",
            cwd: "/tmp",
            name: "Import me",
            firstMessage: "hello",
            model: "anthropic/claude-sonnet-4-5",
            messageCount: 3,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            lastModified: Date(timeIntervalSince1970: 1_760_000_002.5)
        )
        let transport = SnapshotSequencedLocalHTTPTransport(responses: [
            MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"session":{"id":"session-imported","workspaceId":"ws-1","worktreeId":"wt_feature","name":"Import me","status":"busy","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":3,"tokens":{"input":0,"output":0},"cost":0},"prompted":false}
                """#.utf8)
            ),
            MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: sessionListJSON(sessionId: "session-imported", worktreeId: "wt_feature")
            ),
        ])
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacWorkspaceSnapshotStore()

        let target = await store.importLocalSession(
            workspaceId: "ws-1",
            local: local,
            worktreeId: "wt_feature",
            client: client
        )

        #expect(target?.sessionId == "session-imported")
        #expect(target?.summary.worktreeId == "wt_feature")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["POST", "GET"])
        let body = try JSONDecoder().decode(
            ImportLocalSessionBody.self,
            from: try #require(requests[0].body)
        )
        #expect(body.piSessionFile == local.path)
        #expect(body.worktreeId == "wt_feature")
        #expect(queryValue("worktreeId", in: requests[1].path) == "wt_feature")
    }

    @Test func workspaceShellListsSwitchesFiltersAndCreatesInTheSelectedWorktree() throws {
        let shell = try source(named: "OppiMac/Views/MacWorkspaceShellViews.swift")
        let client = try source(named: "OppiMac/Networking/MacWorkspaceClient.swift")
        let store = try source(named: "OppiMac/Stores/MacWorkspaceSnapshotStore.swift")
        let mainWindow = try source(named: "OppiMac/Views/MainWindowView.swift")
        let presentation = try source(named: "OppiMac/Views/MacWorkspaceWorktreePresentation.swift")

        #expect(shell.contains("listWorkspaceWorktrees"))
        #expect(shell.contains("workspace.worktree.menu"))
        #expect(shell.contains("MacWorkspaceWorktreePresentation.filterSessions"))
        #expect(shell.contains("selectedWorktreeId"))
        #expect(shell.contains("createSession(prompt, selectedWorktreeId)"))
        #expect(shell.contains("refreshSessions(selectedWorktreeId)"))
        #expect(shell.contains("MacWorkspaceWorktreePresentation.sessionScope"))
        #expect(shell.contains("worktreeId: selectedWorktreeId"))
        #expect(shell.contains("MacWorkspaceFileBrowserView("))
        #expect(shell.contains("MacWorkspaceGitStatusView("))
        #expect(shell.contains("worktreeId: selectedWorktreeId"))
        #expect(!shell.contains("WorkspaceDetailView"))
        #expect(!shell.contains("worktrees/open"))
        #expect(!shell.contains("Create Worktree"))
        #expect(!shell.contains("WindowGroup"))

        #expect(client.contains("func listWorkspaceWorktrees"))
        #expect(client.contains("/workspaces/\\(workspaceId)/worktrees"))
        #expect(client.contains("let worktreeId: String?"))
        #expect(!client.contains("worktrees/open"))

        #expect(store.contains("worktreeId: worktreeId"))
        #expect(mainWindow.contains("worktreeId: worktreeId"))
        #expect(presentation.contains("WorkspaceWorktree"))
        #expect(!presentation.contains("import SwiftUI"))
        #expect(!presentation.contains("import AppKit"))
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sessionListJSON(sessionId: String, worktreeId: String) -> Data {
        Data(#"""
        {"workspaceId":"ws-1","serverNow":1760000003000,"active":[{"id":"\#(sessionId)","workspaceId":"ws-1","worktreeId":"\#(worktreeId)","name":"\#(sessionId)","status":"ready","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0}],"stopped":[]}
        """#.utf8)
    }

    private func queryValue(_ name: String, in path: String) -> String? {
        guard let query = path.split(separator: "?", maxSplits: 1).dropFirst().first else {
            return nil
        }
        return URLComponents(string: "http://local?\(query)")?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private func makeWorktree(
        id: String,
        isMain: Bool,
        branch: String?,
        sessionCount: Int?
    ) -> WorkspaceWorktree {
        WorkspaceWorktree(
            id: id,
            name: isMain ? "Main checkout" : "feature-name",
            path: "/tmp/\(id)",
            branch: branch,
            headSha: nil,
            isMain: isMain,
            isGitRepo: true,
            sessionCount: sessionCount
        )
    }

    private func makeSummary(id: String, worktreeId: String?) -> SessionSummary {
        SessionSummary(from: Session(
            id: id,
            workspaceId: "ws-1",
            workspaceName: "Oppi",
            worktreeId: worktreeId,
            name: id,
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_700_000_000),
            model: "test/model",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            firstMessage: "Hello from \(id)"
        ))
    }
}

private struct CreateWorkspaceSessionBody: Decodable {
    let prompt: String?
    let worktreeId: String?
}

private struct ImportLocalSessionBody: Decodable {
    let piSessionFile: String
    let worktreeId: String?
}
