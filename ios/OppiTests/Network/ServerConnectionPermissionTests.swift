import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Permissions")
struct ServerConnectionPermissionTests {

    @MainActor
    @Test func routePermissionRequest() {
        let conn = makeTestConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: ["command": .string("rm -rf /")],
            displaySummary: "bash: rm -rf /",
            reason: "Destructive",
            timeoutAt: Date().addingTimeInterval(120)
        )

        conn.handleServerMessage(.permissionRequest(perm), sessionId: "s1")

        #expect(conn.permissionStore.count == 1)
        #expect(conn.permissionStore.pending[0].id == "p1")
    }

    @MainActor
    @Test func routePermissionRequestUsesActiveSessionForNotificationDecision() {
        let conn = makeTestConnection(sessionId: "stream-s1")
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

        conn.handleServerMessage(.permissionRequest(perm), sessionId: "stream-s1")

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

    @MainActor
    @Test func routePermissionExpired() {
        let conn = makeTestConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: test",
            reason: "Test",
            timeoutAt: Date().addingTimeInterval(120)
        )
        conn.permissionStore.add(perm)

        conn.handleServerMessage(.permissionExpired(id: "p1", reason: "timeout"), sessionId: "s1")

        #expect(conn.permissionStore.pending.isEmpty)
    }

    @MainActor
    @Test func routePermissionCancelled() {
        let conn = makeTestConnection()
        let perm = PermissionRequest(
            id: "p1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "bash: test",
            reason: "Test",
            timeoutAt: Date().addingTimeInterval(120)
        )
        conn.permissionStore.add(perm)

        conn.handleServerMessage(.permissionCancelled(id: "p1"), sessionId: "s1")

        #expect(conn.permissionStore.pending.isEmpty)
    }

    @MainActor
    @Test func crossSessionPermissionAddedToStore() {
        let conn = makeTestConnection()
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

    @MainActor
    @Test func respondToCrossSessionPermissionDoesNotPolluteActiveTimeline() async throws {
        let conn = makeTestConnection()
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

        let hasMarker = conn.reducer.items.contains {
            if case .permissionResolved(let id, _, _, _) = $0 { return id == "xp1" }
            return false
        }
        #expect(!hasMarker,
                "Cross-session permission approval should not inject marker into active session timeline")

        #expect(conn.permissionStore.pending.isEmpty,
                "Permission should be consumed from store after response")
    }

    @MainActor
    @Test func respondToSameSessionPermissionInjectsMarker() async throws {
        let conn = makeTestConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }

        let perm = PermissionRequest(
            id: "sp1", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "same-session cmd", reason: "",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )
        conn.permissionStore.add(perm)

        try await conn.respondToPermission(id: "sp1", action: .allow)

        let hasMarker = conn.reducer.items.contains {
            if case .permissionResolved(let id, _, _, _) = $0 { return id == "sp1" }
            return false
        }
        #expect(hasMarker,
                "Same-session permission approval should inject marker into active timeline")
    }
}
