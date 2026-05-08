import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Permissions")
@MainActor
struct ServerConnectionPermissionTests {

    @Test func routePermissionRequest() {
        let (conn, pipe) = makeTestConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: ["command": .string("rm -rf /")],
            displaySummary: "bash: rm -rf /",
            reason: "Destructive",
            timeoutAt: Date().addingTimeInterval(120)
        )

        pipe.handle(.permissionRequest(perm), sessionId: "s1")

        #expect(conn.permissionStore.count == 1)
        #expect(conn.permissionStore.pending[0].id == "p1")
    }

    @Test func routePermissionRequestUsesActiveSessionForNotificationDecision() {
        let (conn, pipe) = makeTestConnection(sessionId: "stream-s1")
        conn.sessionStore.activeSessionId = "active-s1"

        let notificationService = PermissionNotificationService.shared
        let previousAppState = notificationService._applicationStateForTesting
        let previousDecisionHook = notificationService._onNotifyDecisionForTesting
        let previousSkipScheduling = notificationService._skipSchedulingForTesting

        notificationService._applicationStateForTesting = .active
        notificationService._skipSchedulingForTesting = true

        defer {
            notificationService._applicationStateForTesting = previousAppState
            notificationService._onNotifyDecisionForTesting = previousDecisionHook
            notificationService._skipSchedulingForTesting = previousSkipScheduling
        }

        var capturedRequestSessionId: String?
        var capturedActiveSessionId: String?
        var capturedShouldNotify: Bool?
        notificationService._onNotifyDecisionForTesting = { request, activeSessionId, shouldNotify in
            capturedRequestSessionId = request.sessionId
            capturedActiveSessionId = activeSessionId
            capturedShouldNotify = shouldNotify
        }

        let perm = PermissionRequest(
            id: "p2", sessionId: "other-s2", tool: "bash",
            input: ["command": .string("git push")],
            displaySummary: "bash: git push",
            reason: "Git push",
            timeoutAt: Date().addingTimeInterval(120)
        )

        pipe.handle(.permissionRequest(perm), sessionId: "stream-s1")

        if ReleaseFeatures.pushNotificationsEnabled {
            #expect(capturedRequestSessionId == "other-s2")
            #expect(capturedActiveSessionId == "active-s1")
            #expect(capturedShouldNotify == true)
        } else {
            #expect(capturedRequestSessionId == nil)
            #expect(capturedActiveSessionId == nil)
            #expect(capturedShouldNotify == nil)
        }
    }

    @Test func routePermissionExpired() {
        let (conn, pipe) = makeTestConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: test",
            reason: "Test",
            timeoutAt: Date().addingTimeInterval(120)
        )
        conn.permissionStore.add(perm)

        pipe.handle(.permissionExpired(id: "p1", reason: "timeout"), sessionId: "s1")

        #expect(conn.permissionStore.pending.isEmpty)
    }

    @Test func routePermissionCancelled() {
        let (conn, pipe) = makeTestConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: test",
            reason: "Test",
            timeoutAt: Date().addingTimeInterval(120)
        )
        conn.permissionStore.add(perm)

        pipe.handle(.permissionCancelled(id: "p1"), sessionId: "s1")

        #expect(conn.permissionStore.pending.isEmpty)
    }

    @Test func crossSessionPermissionAddedToStore() {
        let (conn, pipe) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")

        let permRequest = PermissionRequest(
            id: "p2", sessionId: "s2", tool: "bash",
            input: [:], displaySummary: "cross-session", reason: "",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        let streamMsg = StreamMessage(
            sessionId: "s2",
            streamSeq: 2,
            seq: nil,
            currentSeq: nil,
            message: .permissionRequest(permRequest)
        )
        conn.routeStreamMessage(streamMsg)

        #expect(conn.permissionStore.pending.count == 1,
                "Cross-session permission should be added to store")
        #expect(conn.permissionStore.pending.first?.id == "p2")
    }

    @Test func respondToCrossSessionPermissionDoesNotPolluteActiveTimeline() async throws {
        let (conn, pipe) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }

        let crossPerm = PermissionRequest(
            id: "xp1", sessionId: "s2", tool: "bash",
            input: [:], displaySummary: "cross-session cmd", reason: "",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        conn.permissionStore.add(crossPerm)

        try await conn.respondToPermission(id: "xp1", action: .allow)

        let hasMarker = pipe.reducer.items.contains {
            if case .permissionResolved(let id, _, _, _) = $0 { return id == "xp1" }
            return false
        }
        #expect(!hasMarker,
                "Cross-session permission approval should not inject marker into active session timeline")

        #expect(conn.permissionStore.pending.isEmpty,
                "Permission should be consumed from store after response")
    }

    @Test func respondToPermissionFallsBackToRESTWhenStreamIsDisconnected() async throws {
        let (conn, _) = makeTestConnection()
        conn.wsClient?._setStatusForTesting(.disconnected)

        let perm = PermissionRequest(
            id: "rest-p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "rest fallback", reason: "",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        conn.permissionStore.add(perm)

        var captured: CapturedPermissionRESTResponse?
        conn._respondToPermissionRESTForTesting = { id, action, scope, expiresInMs in
            captured = CapturedPermissionRESTResponse(
                id: id,
                action: action,
                scope: scope,
                expiresInMs: expiresInMs
            )
        }

        try await conn.respondToPermission(id: "rest-p1", action: .allow, scope: .once)

        #expect(captured?.id == "rest-p1")
        #expect(captured?.action == .allow)
        #expect(captured?.scope == .once)
        #expect(captured?.expiresInMs == nil)
        #expect(conn.permissionStore.pending.isEmpty)
    }

    @Test func respondToSameSessionPermissionInjectsMarker() async throws {
        let (conn, pipe) = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }

        // Wire the permission callback to the test-compat reducer
        conn.onPermissionResolved = { id, outcome, tool, summary in
            pipe.reducer.resolvePermission(id: id, outcome: outcome, tool: tool, summary: summary)
        }

        let perm = PermissionRequest(
            id: "sp1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "same-session cmd", reason: "",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        conn.permissionStore.add(perm)

        try await conn.respondToPermission(id: "sp1", action: .allow)

        let hasMarker = pipe.reducer.items.contains {
            if case .permissionResolved(let id, _, _, _) = $0 { return id == "sp1" }
            return false
        }
        #expect(hasMarker,
                "Same-session permission approval should inject marker into active timeline")
    }

    @Test func workspaceStreamPermissionCancellationReachesVisibleInactiveSessionTimeline() async {
        let parentId = "parent-perm"
        let focusedId = "focused-perm"
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        connection.sessionStore.upsert(makeTestSession(id: parentId, workspaceId: "w1", status: .busy))
        connection.sessionStore.upsert(makeTestSession(id: focusedId, workspaceId: "w1", status: .busy))
        connection.focusSession(focusedId)
        connection._setWorkspaceStreamWorkspaceIdForTesting("w1")

        var parentContinuation: AsyncStream<SessionStreamEvent>.Continuation?
        let parentStream = AsyncStream<SessionStreamEvent> { continuation in
            parentContinuation = continuation
            connection.sessionEventContinuations[parentId] = continuation
        }

        let parentManager = ChatSessionManager(sessionId: parentId)
        parentManager._loadHistoryForTesting = { _, _ in nil }
        parentManager._streamEventsForTesting = { sessionId in
            sessionId == parentId ? parentStream : nil
        }

        let parentTask = Task { @MainActor in
            await parentManager.connect(connection: connection, sessionStore: connection.sessionStore)
        }

        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { parentContinuation != nil }
        })
        parentContinuation?.yield(SessionStreamEvent(
            sessionId: parentId,
            message: .connected(session: makeTestSession(id: parentId, workspaceId: "w1", status: .busy)),
            meta: InboundStreamMeta(seq: nil, currentSeq: 0),
            source: .live
        ))
        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run { parentManager.entryState == .streaming }
        })
        connection.focusSession(focusedId)

        let permission = PermissionRequest(
            id: "parent-perm-1",
            sessionId: parentId,
            tool: "bash",
            input: [:],
            displaySummary: "parent command",
            reason: "Test",
            timeoutAt: Date().addingTimeInterval(60)
        )
        connection._routeWorkspaceStreamMessageForTesting(StreamFrameEvent(
            sessionId: parentId,
            message: .permissionRequest(permission),
            meta: InboundStreamMeta(seq: 1, currentSeq: 2)
        ))

        #expect(await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                connection.permissionStore.pending.contains { $0.id == permission.id }
            }
        })

        connection._routeWorkspaceStreamMessageForTesting(StreamFrameEvent(
            sessionId: parentId,
            message: .permissionCancelled(id: permission.id),
            meta: InboundStreamMeta(seq: 2, currentSeq: 2)
        ))

        let resolved = await waitForTestCondition(timeoutMs: 1_000) {
            await MainActor.run {
                parentManager.reducer.items.contains {
                    if case .permissionResolved(let id, let outcome, let tool, _) = $0 {
                        return id == permission.id && outcome == .cancelled && tool == "bash"
                    }
                    return false
                }
            }
        }
        #expect(resolved,
                "Workspace-stream permission cancellation should reach a visible inactive session timeline")

        parentTask.cancel()
        parentContinuation?.finish()
        connection.sessionEventContinuations.removeValue(forKey: parentId)
        await parentTask.value
        connection.disconnectStream()
    }
}

private struct CapturedPermissionRESTResponse {
    let id: String
    let action: PermissionAction
    let scope: PermissionScope
    let expiresInMs: Int?
}
