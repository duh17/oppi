import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac workspace snapshot store")
struct MacWorkspaceSnapshotStoreTests {

    @Test func exposesWorkspaceSessionTargetsNewestFirst() {
        let store = MacWorkspaceSnapshotStore()
        let workspace = makeWorkspace(id: "ws-1", name: "Oppi")
        let older = makeSummary(id: "older", workspaceId: "ws-1", status: .stopped, lastActivity: 1_000)
        let newer = makeSummary(id: "newer", workspaceId: "ws-1", status: .ready, lastActivity: 2_000)
        store._setCatalogForTesting(
            workspaces: [workspace],
            recentSessionTargets: [
                MacSelectedSessionTarget(workspaceId: "ws-1", sessionId: older.id, summary: older),
                MacSelectedSessionTarget(workspaceId: "ws-1", sessionId: newer.id, summary: newer),
            ]
        )

        #expect(store.sessionTargets.map(\.sessionId) == ["newer", "older"])
        #expect(store.target(for: "newer")?.workspaceId == "ws-1")
    }

    @Test func homeLoaderIssuesOneRecentSessionsRequest() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"sessions":[
                  {"id":"busy","workspaceId":"ws-1","status":"busy","createdAt":0,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0},
                  {"id":"ready","workspaceId":"ws-2","workspaceName":"Other","status":"ready","createdAt":0,"lastActivity":2000,"messageCount":2,"tokens":{"input":0,"output":0},"cost":0},
                  {"id":"orphaned","status":"stopped","createdAt":0,"lastActivity":3000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0}
                ]}
                """#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacWorkspaceSnapshotStore()
        store._setCatalogForTesting(workspaces: [
            makeWorkspace(id: "ws-1", name: "Oppi"),
            makeWorkspace(id: "ws-2", name: "Other"),
        ])

        await store.loadRecentSessions(client: client)

        #expect(store.sessionTargets.map(\.sessionId) == ["busy", "ready"])
        #expect(store.sessionTargets.map(\.workspaceId) == ["ws-1", "ws-2"])
        #expect(store.target(for: "orphaned") == nil)
        #expect(store.sessions(for: "ws-1") == nil)
        #expect(store.sessions(for: "ws-2") == nil)

        let requests = await transport.requests
        #expect(requests.map(\.path) == ["/sessions/recent?recentDays=3"])
        #expect(requests.allSatisfy { !$0.path.contains("/workspaces/") })
        #expect(!requests.contains { $0.path.contains("/sessions") && $0.path.contains("/workspaces/") })
    }

    @Test func recentSnapshotStartsDisplaySleepPreventionForRunningSessions() async {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"sessions":[
                  {"id":"already-busy-1","workspaceId":"ws-1","status":"busy","createdAt":0,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0},
                  {"id":"already-busy-2","workspaceId":"ws-2","status":"stopping","createdAt":0,"lastActivity":2000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0}
                ]}
                """#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        var updates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { nil },
            activitySetter: { updates.append($0) }
        )
        let store = MacWorkspaceSnapshotStore()
        store.screenAwakeController = controller

        await store.loadRecentSessions(client: client)

        #expect(controller.isPreventingSleep)
        #expect(updates == [true])

        _ = store.applyAppEvent(
            .sessionEnded(sessionId: "already-busy-1", workspaceId: "ws-1", emittedAt: 3_000, reason: "done")
        )
        #expect(controller.isPreventingSleep)
        #expect(updates == [true])

        _ = store.applyAppEvent(
            .sessionEnded(sessionId: "already-busy-2", workspaceId: "ws-2", emittedAt: 4_000, reason: "done")
        )
        #expect(!controller.isPreventingSleep)
        #expect(updates == [true, false])
    }

    @Test func recentSnapshotClearsMissedEndedSessionActivity() async {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"sessions":[
                  {"id":"ended-while-disconnected","workspaceId":"ws-1","status":"stopped","createdAt":0,"lastActivity":2000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0}
                ]}
                """#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        var updates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { nil },
            activitySetter: { updates.append($0) }
        )
        controller.setSessionActivity(true, sessionId: "ended-while-disconnected")
        let store = MacWorkspaceSnapshotStore()
        store.screenAwakeController = controller

        #expect(store.applyAppEvent(.connected(serverTime: 2_000, snapshotRequired: true)))
        await store.loadRecentSessions(client: client)

        #expect(!controller.isPreventingSleep)
        #expect(updates == [true, false])
    }

    @Test func overlappingRecentSessionLoadsKeepNewerRowsAndAwakeReasons() async {
        let transport = SnapshotPendingLocalHTTPTransport()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        var updates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { nil },
            activitySetter: { updates.append($0) }
        )
        let store = MacWorkspaceSnapshotStore()
        store.screenAwakeController = controller

        let olderRows = Task { await store.loadRecentSessions(client: client) }
        await transport.waitUntilStarted(1)
        let olderFailure = Task { await store.loadRecentSessions(client: client) }
        await transport.waitUntilStarted(2)
        let newer = Task { await store.loadRecentSessions(client: client) }
        await transport.waitUntilStarted(3)

        await transport.complete(
            at: 2,
            response: recentSessionsResponse(sessionId: "newer-running", status: "busy")
        )
        await newer.value
        #expect(store.sessionTargets.map(\.sessionId) == ["newer-running"])
        #expect(controller.isPreventingSleep)
        #expect(updates == [true])

        await transport.complete(
            at: 0,
            response: recentSessionsResponse(sessionId: "older-stopped", status: "stopped")
        )
        await olderRows.value
        await transport.complete(
            at: 0,
            response: MacLocalHTTPResponse(
                statusCode: 500,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":"stale failure"}"#.utf8)
            )
        )
        await olderFailure.value

        #expect(store.sessionTargets.map(\.sessionId) == ["newer-running"])
        #expect(controller.isPreventingSleep)
        #expect(updates == [true])
        #expect(store.recentSessionsError == nil)
        #expect(!store.isLoadingRecentSessions)
    }

    @Test func staleRecentSessionCompletionKeepsNewerLoadingState() async {
        let transport = SnapshotPendingLocalHTTPTransport()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacWorkspaceSnapshotStore()

        let older = Task { await store.loadRecentSessions(client: client) }
        await transport.waitUntilStarted(1)
        let newer = Task { await store.loadRecentSessions(client: client) }
        await transport.waitUntilStarted(2)

        await transport.complete(
            at: 0,
            response: recentSessionsResponse(sessionId: "stale", status: "ready")
        )
        await older.value

        #expect(store.isLoadingRecentSessions)
        #expect(store.recentSessionsError == nil)
        #expect(store.sessionTargets.isEmpty)

        await transport.complete(
            at: 0,
            response: MacLocalHTTPResponse(
                statusCode: 500,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":"newer failed"}"#.utf8)
            )
        )
        await newer.value

        #expect(!store.isLoadingRecentSessions)
        #expect(store.recentSessionsError?.contains("newer failed") == true)
        #expect(store.sessionTargets.isEmpty)
    }

    @Test func failedRecentSnapshotPreservesExistingAwakeReasons() async {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 500,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":"snapshot failed"}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        var updates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { nil },
            activitySetter: { updates.append($0) }
        )
        controller.setSessionActivity(true, sessionId: "still-running")
        let store = MacWorkspaceSnapshotStore()
        store.screenAwakeController = controller

        await store.loadRecentSessions(client: client)

        #expect(controller.isPreventingSleep)
        #expect(updates == [true])
        #expect(store.recentSessionsError?.contains("snapshot failed") == true)
    }

    @Test func overlappingWorktreeSessionLoadsKeepTheNewerList() async throws {
        let transport = SnapshotPendingLocalHTTPTransport()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacWorkspaceSnapshotStore()

        let older = Task {
            await store.loadSessions(workspaceId: "ws-1", worktreeId: "wt-old", client: client)
        }
        await transport.waitUntilStarted(1)

        let newer = Task {
            await store.loadSessions(workspaceId: "ws-1", worktreeId: "wt-new", client: client)
        }
        await transport.waitUntilStarted(2)
        #expect(store.isLoadingSessions(for: "ws-1"))

        await transport.completeFirst(
            containing: "worktreeId=wt-new",
            response: sessionListResponse(sessionId: "session-new", worktreeId: "wt-new")
        )
        await newer.value
        #expect(store.sessions(for: "ws-1")?.active.map(\.id) == ["session-new"])
        #expect(!store.isLoadingSessions(for: "ws-1"))
        #expect(store.sessionError(for: "ws-1") == nil)

        await transport.completeFirst(
            containing: "worktreeId=wt-old",
            response: sessionListResponse(sessionId: "session-old", worktreeId: "wt-old")
        )
        await older.value

        #expect(store.sessions(for: "ws-1")?.active.map(\.id) == ["session-new"])
        #expect(store.sessionError(for: "ws-1") == nil)
        #expect(!store.isLoadingSessions(for: "ws-1"))
        let requests = await transport.requests
        #expect(requests.filter { $0.path.contains("/workspaces/ws-1/sessions") }.count == 2)
        #expect(requests.contains { $0.path.contains("worktreeId=wt-old") })
        #expect(requests.contains { $0.path.contains("worktreeId=wt-new") })
    }

    @Test func overlappingSessionLoadCancellationDoesNotClobberNewerLoadOrShowError() async throws {
        let transport = SnapshotPendingLocalHTTPTransport()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacWorkspaceSnapshotStore()

        let older = Task {
            await store.loadSessions(workspaceId: "ws-1", worktreeId: "wt-old", client: client)
        }
        await transport.waitUntilStarted(1)

        let newer = Task {
            await store.loadSessions(workspaceId: "ws-1", worktreeId: "wt-new", client: client)
        }
        await transport.waitUntilStarted(2)
        #expect(store.isLoadingSessions(for: "ws-1"))

        older.cancel()
        await older.value
        #expect(store.sessionError(for: "ws-1") == nil)
        #expect(store.isLoadingSessions(for: "ws-1"))
        #expect(store.sessions(for: "ws-1") == nil)

        await transport.completeFirst(
            containing: "worktreeId=wt-new",
            response: sessionListResponse(sessionId: "session-new", worktreeId: "wt-new")
        )
        await newer.value

        #expect(store.sessions(for: "ws-1")?.active.map(\.id) == ["session-new"])
        #expect(store.sessionError(for: "ws-1") == nil)
        #expect(!store.isLoadingSessions(for: "ws-1"))
    }

    @Test func currentSessionLoadCancellationIsNotAVisibleError() async throws {
        let transport = SnapshotPendingLocalHTTPTransport()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacWorkspaceSnapshotStore()

        let load = Task {
            await store.loadSessions(workspaceId: "ws-1", worktreeId: "wt-1", client: client)
        }
        await transport.waitUntilStarted(1)
        #expect(store.isLoadingSessions(for: "ws-1"))

        load.cancel()
        await load.value

        #expect(store.sessionError(for: "ws-1") == nil)
        #expect(!store.isLoadingSessions(for: "ws-1"))
        #expect(store.sessions(for: "ws-1") == nil)
    }

    @Test func homeTargetsKeepControlSessionsWithoutWorkspaceId() {
        var controlSession = Session(
            id: "control-1",
            workspaceId: nil,
            name: "Create Agent",
            status: .busy,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 4),
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        controlSession.control = ControlSessionMetadata(
            domain: .agents,
            intent: .create,
            targetId: nil,
            targetName: nil
        )
        let control = SessionSummary(from: controlSession)
        let orphaned = SessionSummary(from: Session(
            id: "orphaned",
            workspaceId: nil,
            name: "Orphan",
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 3),
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        ))

        let targets = MacWorkspaceSnapshotStore.homeTargets(from: [control, orphaned])

        #expect(targets.map(\.sessionId) == ["control-1"])
        #expect(targets.first?.routeScope == .control)
        #expect(targets.first?.summary.control?.domain == .agents)
    }

    @Test func appEventSummaryUpsertsRecentTargetWithoutHTTPS() {
        let store = MacWorkspaceSnapshotStore()
        let created = makeSummary(id: "live", workspaceId: "ws-1", status: .busy, lastActivity: 3_000)

        let needsSnapshot = store.applyAppEvent(
            .sessionSummary(
                sessionId: created.id,
                workspaceId: "ws-1",
                emittedAt: 3_000,
                summary: created
            )
        )

        #expect(needsSnapshot == false)
        #expect(store.sessionTargets.map(\.sessionId) == ["live"])
        #expect(store.target(for: "live")?.summary.status == .busy)
    }

    @Test func appEventConnectedRequestsSnapshotRepair() {
        let store = MacWorkspaceSnapshotStore()
        #expect(store.applyAppEvent(.connected(serverTime: 1, snapshotRequired: true)))
        #expect(!store.applyAppEvent(.connected(serverTime: 1, snapshotRequired: false)))
    }

    @Test func appEventAskPostsAttentionBannerWhenAppIsNotKey() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = false
        service.activeSessionId = "s1"

        let store = MacWorkspaceSnapshotStore()
        let request = ExtensionUIRequest(
            id: "ask-live",
            sessionId: "s2",
            method: "ask",
            workspaceId: "ws-1",
            askQuestions: [
                AskQuestion(id: "q1", question: "Ship it?", options: [], multiSelect: false),
            ],
            allowCustom: true
        )

        _ = store.applyAppEvent(
            .extensionUIRequest(request: request, workspaceId: "ws-1", emittedAt: 4_000)
        )

        #expect(service._lastScheduledPayloadForTesting?.identifier == "ask-s2")
        #expect(service._lastScheduledPayloadForTesting?.body == "Ship it?")
        #expect(
            service._lastScheduledPayloadForTesting?.categoryIdentifier
                == AttentionNotificationPolicy.askCategoryId
        )
    }

    @Test func appEventAskDoesNotBannerKeyActiveSession() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = true
        service.activeSessionId = "s1"

        let store = MacWorkspaceSnapshotStore()
        let request = ExtensionUIRequest(
            id: "ask-visible",
            sessionId: "s1",
            method: "ask",
            workspaceId: "ws-1",
            askQuestions: [
                AskQuestion(id: "q1", question: "Visible?", options: [], multiSelect: false),
            ]
        )

        _ = store.applyAppEvent(
            .extensionUIRequest(request: request, workspaceId: "ws-1", emittedAt: 4_000)
        )

        #expect(service._lastScheduledPayloadForTesting == nil)
    }

    @Test func appEventSettledCancelsAskBanner() {
        let service = MacAttentionNotificationService.shared
        service.resetForTesting()
        service._isAppActiveForTesting = false

        let store = MacWorkspaceSnapshotStore()
        _ = store.applyAppEvent(
            .extensionUISettled(id: "ask-live", sessionId: "s2", workspaceId: "ws-1", emittedAt: 5_000)
        )

        #expect(service._cancelledSessionIdsForTesting.contains("s2"))
    }

    @Test func appEventDeleteRemovesRecentTarget() {
        let store = MacWorkspaceSnapshotStore()
        let summary = makeSummary(id: "gone", workspaceId: "ws-1", status: .ready, lastActivity: 1_000)
        store._setCatalogForTesting(
            workspaces: [],
            recentSessionTargets: [
                MacSelectedSessionTarget(workspaceId: "ws-1", sessionId: summary.id, summary: summary),
            ]
        )

        _ = store.applyAppEvent(.sessionDeleted(sessionId: "gone", workspaceId: "ws-1", emittedAt: 2_000))
        #expect(store.sessionTargets.isEmpty)
    }

    @Test func busyAppEventPreventsDisplaySleepAndEndedReleasesWhenOff() {
        var updates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { nil },
            activitySetter: { updates.append($0) }
        )
        let store = MacWorkspaceSnapshotStore()
        store.screenAwakeController = controller
        let busy = makeSummary(id: "live", workspaceId: "ws-1", status: .busy, lastActivity: 3_000)

        _ = store.applyAppEvent(
            .sessionSummary(
                sessionId: busy.id,
                workspaceId: "ws-1",
                emittedAt: 3_000,
                summary: busy
            )
        )
        #expect(controller.isPreventingSleep)
        #expect(updates == [true])

        _ = store.applyAppEvent(
            .sessionEnded(sessionId: "live", workspaceId: "ws-1", emittedAt: 4_000, reason: "stopped")
        )
        #expect(!controller.isPreventingSleep)
        #expect(updates == [true, false])
    }

    @Test func deletingSessionClearsDisplaySleepPrevention() {
        var updates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { nil },
            activitySetter: { updates.append($0) }
        )
        let store = MacWorkspaceSnapshotStore()
        store.screenAwakeController = controller
        let busy = makeSummary(id: "gone", workspaceId: "ws-1", status: .busy, lastActivity: 1_000)
        store._setCatalogForTesting(
            workspaces: [],
            recentSessionTargets: [
                MacSelectedSessionTarget(workspaceId: "ws-1", sessionId: busy.id, summary: busy),
            ]
        )
        controller.setSessionActivity(true, sessionId: busy.id)
        #expect(updates == [true])

        _ = store.applyAppEvent(.sessionDeleted(sessionId: "gone", workspaceId: "ws-1", emittedAt: 2_000))
        #expect(!controller.isPreventingSleep)
        #expect(updates == [true, false])
    }

    @Test func busySessionTargetsSortAheadOfNewerIdleSessions() {
        let store = MacWorkspaceSnapshotStore()
        let busy = makeSummary(id: "busy", workspaceId: "ws-1", status: .busy, lastActivity: 1_000)
        let ready = makeSummary(id: "ready", workspaceId: "ws-1", status: .ready, lastActivity: 2_000)
        store._setCatalogForTesting(
            workspaces: [],
            recentSessionTargets: [
                MacSelectedSessionTarget(workspaceId: "ws-1", sessionId: busy.id, summary: busy),
                MacSelectedSessionTarget(workspaceId: "ws-1", sessionId: ready.id, summary: ready),
            ]
        )

        #expect(store.sessionTargets.map(\.sessionId) == ["busy", "ready"])
    }

    @Test func importLocalSessionPostsPiFileAndRemovesImportableRow() async throws {
        let local = makeLocalSession()
        let transport = SnapshotSequencedLocalHTTPTransport(responses: [
            MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"session":{"id":"session-imported","workspaceId":"ws-1","name":"Import me","status":"busy","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":3,"tokens":{"input":0,"output":0},"cost":0},"prompted":false}
                """#.utf8)
            ),
            MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"workspaceId":"ws-1","serverNow":1760000003000,"active":[{"id":"session-imported","workspaceId":"ws-1","name":"Import me","status":"busy","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":3,"tokens":{"input":0,"output":0},"cost":0}],"stopped":[]}
                """#.utf8)
            ),
        ])
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacWorkspaceSnapshotStore()
        store._setCatalogForTesting(
            workspaces: [makeWorkspace(id: "ws-1", name: "Oppi")],
            sessionsByWorkspace: [
                "ws-1": MacWorkspaceClient.WorkspaceSessionList(
                    workspaceId: "ws-1",
                    serverNow: 1_760_000_003_000,
                    active: [],
                    stopped: [],
                    importableSessions: [local]
                )
            ]
        )

        let target = await store.importLocalSession(
            workspaceId: "ws-1",
            local: local,
            client: client
        )

        #expect(target?.sessionId == "session-imported")
        #expect(store.sessions(for: "ws-1")?.importableSessions.isEmpty == true)
        #expect(store.sessions(for: "ws-1")?.active.map(\.id) == ["session-imported"])
        #expect(store.sessionTargets.map(\.sessionId) == ["session-imported"])
        #expect(store.importLocalSessionError == nil)
        #expect(!store.isImportingLocalSession)

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["POST", "GET"])
        #expect(requests.first?.path == "/workspaces/ws-1/sessions")
        #expect(requests.first?.headers["Authorization"] == "Bearer sk_owner")
        let body = try JSONDecoder().decode(
            SnapshotImportLocalSessionBody.self,
            from: try #require(requests.first?.body)
        )
        #expect(body.piSessionFile == local.path)
        #expect(requests[1].path.hasPrefix("/workspaces/ws-1/sessions?"))
    }

    @Test func importLocalSessionFailureKeepsImportableRow() async {
        let local = makeLocalSession()
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 500,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":"import failed"}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )
        let store = MacWorkspaceSnapshotStore()
        store._setCatalogForTesting(
            workspaces: [makeWorkspace(id: "ws-1", name: "Oppi")],
            sessionsByWorkspace: [
                "ws-1": MacWorkspaceClient.WorkspaceSessionList(
                    workspaceId: "ws-1",
                    serverNow: 1_760_000_003_000,
                    active: [],
                    stopped: [],
                    importableSessions: [local]
                )
            ]
        )

        let target = await store.importLocalSession(
            workspaceId: "ws-1",
            local: local,
            client: client
        )

        #expect(target == nil)
        #expect(store.sessions(for: "ws-1")?.importableSessions.map(\.path) == [local.path])
        #expect(store.importLocalSessionError?.contains("Import failed") == true)
        #expect(!store.isImportingLocalSession)
    }

    @Test func presentationExposesImportChromeWithoutSearch() {
        let named = makeLocalSession()
        let untitled = LocalSession(
            path: "/tmp/other.jsonl",
            piSessionId: "pi-2",
            cwd: "/tmp",
            name: nil,
            firstMessage: nil,
            model: nil,
            messageCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            lastModified: Date(timeIntervalSince1970: 1_760_000_002.5)
        )
        let empty = MacWorkspaceClient.WorkspaceSessionList(
            workspaceId: "ws-1",
            serverNow: 1,
            active: [],
            stopped: [],
            importableSessions: []
        )
        let importableOnly = MacWorkspaceClient.WorkspaceSessionList(
            workspaceId: "ws-1",
            serverNow: 1,
            active: [],
            stopped: [],
            importableSessions: [named]
        )

        #expect(named.displayTitle == "Import me")
        #expect(untitled.displayTitle.hasPrefix("Session "))
        #expect(MacWorkspaceLocalSessionPresentation.badgeTitle == "Terminal")
        #expect(
            MacWorkspaceLocalSessionPresentation.accessibilityIdentifier(for: named)
                == "localSession.nav.pi-1"
        )
        #expect(MacWorkspaceLocalSessionPresentation.messageCountLabel(for: named) == "3 msgs")
        #expect(MacWorkspaceLocalSessionPresentation.messageCountLabel(for: untitled) == nil)
        #expect(!MacWorkspaceLocalSessionPresentation.showsList(empty))
        #expect(MacWorkspaceLocalSessionPresentation.showsList(importableOnly))
        #expect(empty.allSummaries.isEmpty)
        #expect(importableOnly.hasVisibleSessions)
    }

    @Test func workspaceShellHostsImportableLocalSessionsWithoutSearchOrReview() throws {
        let shell = try source(named: "OppiMac/Views/MacWorkspaceShellViews.swift")
        let store = try source(named: "OppiMac/Stores/MacWorkspaceSnapshotStore.swift")
        let client = try source(named: "OppiMac/Networking/MacWorkspaceClient.swift")
        let mainWindow = try source(named: "OppiMac/Views/MainWindowView.swift")

        #expect(shell.contains("importableSessions"))
        #expect(shell.contains("createWorkspaceSessionFromLocal"))
        #expect(shell.contains("MacLocalSessionRow"))
        #expect(shell.contains("localSession.nav"))
        #expect(shell.contains("MacWorkspaceGitStatusView("))
        #expect(shell.contains("openPlan"))
        #expect(!shell.contains("SessionSearchStore"))
        #expect(!shell.contains("ReviewComment"))
        #expect(!shell.contains("Leave a comment"))
        #expect(!shell.contains("ChatView"))
        #expect(!shell.contains("ChatActionHandler"))

        #expect(store.contains("importLocalSession"))
        #expect(store.contains("createWorkspaceSessionFromLocal"))
        #expect(store.contains("removeImportableSession"))
        #expect(!store.contains("SessionSearchStore"))

        #expect(client.contains("createWorkspaceSessionFromLocal"))
        #expect(client.contains("piSessionFile"))

        #expect(!mainWindow.contains("importLocalSession"))
        #expect(!mainWindow.contains("ChatView"))
    }

    @Test func workspaceChromeLaunchesGuidedControlSessionsFromAskOppiAndEditWithOppi() throws {
        let shell = try source(named: "OppiMac/Views/MacWorkspaceShellViews.swift")
        let mainWindow = try source(named: "OppiMac/Views/MainWindowView.swift")
        let catalogStore = try source(named: "OppiMac/Views/MacCatalogStore.swift")
        let presentation = try source(named: "OppiMac/Views/MacCatalogPresentation.swift")
        let catalogViews = try source(named: "OppiMac/Views/MacCatalogViews.swift")

        #expect(shell.contains("Label(\"Ask Oppi\""))
        #expect(shell.contains("mac.workspace.askOppi"))
        #expect(shell.contains("beginCreateControlSession"))
        #expect(shell.contains("Label(\"Edit with Oppi\""))
        #expect(shell.contains("mac.workspace.editWithOppi"))
        #expect(shell.contains("beginReviseControlSession"))
        #expect(shell.contains("MacWorkspaceCreateSheet"))
        #expect(!shell.contains("createControlSession"))
        #expect(!shell.contains("GuidedControlSessionComposer"))
        #expect(!shell.contains("WindowGroup"))

        #expect(mainWindow.contains("beginCreateWorkspaceControlSession"))
        #expect(mainWindow.contains("beginReviseWorkspaceControlSession"))
        #expect(mainWindow.contains("MacControlSessionLaunchSheet"))
        #expect(mainWindow.contains("noteOpenedSession(target)"))
        #expect(mainWindow.contains("selectSessionTarget(target)"))
        #expect(mainWindow.contains("selectedSection = .sessionHome"))
        #expect(!mainWindow.contains("GuidedControlSessionComposer"))
        #expect(!mainWindow.contains("WindowGroup"))

        #expect(catalogStore.contains("beginCreateWorkspaceControlSession"))
        #expect(catalogStore.contains("beginReviseWorkspaceControlSession"))
        #expect(presentation.contains("createWorkspace(workspace:"))
        #expect(presentation.contains("reviseWorkspace("))
        #expect(catalogViews.contains("mac.guided.send"))
        #expect(catalogViews.contains(".keyboardShortcut(.return, modifiers: .command)"))
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeLocalSession() -> LocalSession {
        LocalSession(
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
    }

    private func makeWorkspace(id: String, name: String) -> Workspace {
        Workspace(
            id: id,
            name: name,
            description: nil,
            icon: .symbol("folder"),
            systemPrompt: nil,
            hostMount: "/Users/chenda/workspace/\(id)",
            tools: nil,
            gitStatusEnabled: nil,
            runtime: .host,
            sandboxConfig: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
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

    private func recentSessionsResponse(sessionId: String, status: String) -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data("""
            {"sessions":[{"id":"\(sessionId)","workspaceId":"ws-1","status":"\(status)","createdAt":0,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0}]}
            """.utf8)
        )
    }

    private func sessionListResponse(sessionId: String, worktreeId: String) -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data("""
            {"workspaceId":"ws-1","serverNow":1760000003000,"active":[{"id":"\(sessionId)","workspaceId":"ws-1","name":"\(sessionId)","status":"busy","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"worktreeId":"\(worktreeId)"}],"stopped":[]}
            """.utf8)
        )
    }
}

actor SnapshotPendingLocalHTTPTransport: MacLocalHTTPPerforming {
    private struct Pending {
        let path: String
        let continuation: CheckedContinuation<MacLocalHTTPResponse, Error>
    }

    private var pending: [Pending] = []
    private var startedWaiters: [CheckedContinuation<Int, Never>] = []
    private(set) var startedCount = 0
    private(set) var requests: [MacLocalHTTPRequest] = []

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending.append(Pending(path: request.path, continuation: continuation))
                startedCount += 1
                let waiters = startedWaiters
                startedWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume(returning: startedCount)
                }
            }
        } onCancel: {
            Task { await self.failFirst(containing: request.path, error: CancellationError()) }
        }
    }

    func waitUntilStarted(_ count: Int) async {
        while startedCount < count {
            let current: Int = await withCheckedContinuation { continuation in
                if startedCount >= count {
                    continuation.resume(returning: startedCount)
                } else {
                    startedWaiters.append(continuation)
                }
            }
            if current >= count { return }
        }
    }

    func complete(at index: Int, response: MacLocalHTTPResponse) {
        guard pending.indices.contains(index) else { return }
        let item = pending.remove(at: index)
        item.continuation.resume(returning: response)
    }

    func completeFirst(containing needle: String, response: MacLocalHTTPResponse) {
        guard let index = pending.firstIndex(where: { $0.path.contains(needle) }) else { return }
        let item = pending.remove(at: index)
        item.continuation.resume(returning: response)
    }

    func failFirst(containing needle: String, error: Error) {
        guard let index = pending.firstIndex(where: { $0.path.contains(needle) }) else { return }
        let item = pending.remove(at: index)
        item.continuation.resume(throwing: error)
    }
}

actor SnapshotSequencedLocalHTTPTransport: MacLocalHTTPPerforming {
    private var responses: [MacLocalHTTPResponse]
    private(set) var requests: [MacLocalHTTPRequest] = []

    init(responses: [MacLocalHTTPResponse]) {
        self.responses = responses
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        if responses.isEmpty {
            return MacLocalHTTPResponse(
                statusCode: 500,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":"no sequenced response"}"#.utf8)
            )
        }
        return responses.removeFirst()
    }
}

private struct SnapshotImportLocalSessionBody: Decodable {
    let piSessionFile: String
}
