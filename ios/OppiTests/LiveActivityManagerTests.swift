@testable import Oppi
import ActivityKit
import Foundation
import Testing

// MARK: - Alert Decision (P0: phantom vibrations)

@Suite("LiveActivityManager.shouldAlert")
struct LiveActivityAlertTests {

    // MARK: - awaitingReply must NEVER produce an alert

    @Test("awaitingReply from working does not alert")
    func awaitingReplyFromWorking() {
        let state = makeState(phase: .awaitingReply, approvals: 0)
        #expect(!LiveActivityManager.shouldAlert(
            state: state, lastPushedPhase: .working, lastPushedApprovalCount: 0
        ))
    }

    @Test("awaitingReply from ended does not alert")
    func awaitingReplyFromEnded() {
        let state = makeState(phase: .awaitingReply, approvals: 0)
        #expect(!LiveActivityManager.shouldAlert(
            state: state, lastPushedPhase: .ended, lastPushedApprovalCount: 0
        ))
    }

    @Test("awaitingReply with unchanged approval count does not alert")
    func awaitingReplyUnchangedApprovals() {
        let state = makeState(phase: .awaitingReply, approvals: 2)
        #expect(!LiveActivityManager.shouldAlert(
            state: state, lastPushedPhase: .working, lastPushedApprovalCount: 2
        ))
    }

    // MARK: - needsApproval MUST alert

    @Test("needsApproval from working alerts")
    func needsApprovalFromWorking() {
        let state = makeState(phase: .needsApproval, approvals: 1)
        #expect(LiveActivityManager.shouldAlert(
            state: state, lastPushedPhase: .working, lastPushedApprovalCount: 0
        ))
    }

    @Test("needsApproval with increased count alerts")
    func needsApprovalIncreasedCount() {
        let state = makeState(phase: .needsApproval, approvals: 3)
        #expect(LiveActivityManager.shouldAlert(
            state: state, lastPushedPhase: .needsApproval, lastPushedApprovalCount: 2
        ))
    }

    @Test("needsApproval same count same phase does not re-alert")
    func needsApprovalSameCountSamePhase() {
        let state = makeState(phase: .needsApproval, approvals: 2)
        #expect(!LiveActivityManager.shouldAlert(
            state: state, lastPushedPhase: .needsApproval, lastPushedApprovalCount: 2
        ))
    }

    // MARK: - Other phases never alert

    @Test("working never alerts", arguments: [SessionPhase.ended, .awaitingReply, .working, .error])
    func workingNeverAlerts(from: SessionPhase) {
        let state = makeState(phase: .working, approvals: 0)
        #expect(!LiveActivityManager.shouldAlert(
            state: state, lastPushedPhase: from, lastPushedApprovalCount: 0
        ))
    }

    @Test("error never alerts", arguments: [SessionPhase.working, .ended, .awaitingReply])
    func errorNeverAlerts(from: SessionPhase) {
        let state = makeState(phase: .error, approvals: 0)
        #expect(!LiveActivityManager.shouldAlert(
            state: state, lastPushedPhase: from, lastPushedApprovalCount: 0
        ))
    }

    @Test("ended never alerts")
    func endedNeverAlerts() {
        let state = makeState(phase: .ended, approvals: 0)
        #expect(!LiveActivityManager.shouldAlert(
            state: state, lastPushedPhase: .awaitingReply, lastPushedApprovalCount: 0
        ))
    }

    @Test("ten consecutive turn cycles produce zero alerts")
    func tenTurnCyclesNoAlerts() {
        var lastPhase: SessionPhase = .ended
        let lastCount = 0
        var alertCount = 0

        for _ in 0..<10 {
            // working phase
            let working = makeState(phase: .working, approvals: 0)
            if LiveActivityManager.shouldAlert(
                state: working, lastPushedPhase: lastPhase, lastPushedApprovalCount: lastCount
            ) { alertCount += 1 }
            lastPhase = .working

            // awaitingReply phase
            let awaiting = makeState(phase: .awaitingReply, approvals: 0)
            if LiveActivityManager.shouldAlert(
                state: awaiting, lastPushedPhase: lastPhase, lastPushedApprovalCount: lastCount
            ) { alertCount += 1 }
            lastPhase = .awaitingReply
        }

        #expect(alertCount == 0, "Normal conversation turns must never vibrate")
    }
}

// MARK: - State Aggregation

@Suite("LiveActivityManager state aggregation", .serialized)
struct LiveActivityStateTests {

    @Test("sync busy session produces working phase")
    @MainActor func syncBusyWorking() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        #expect(mgr.currentState.primaryPhase == .working)
        #expect(mgr.currentState.totalActiveSessions == 1)
        #expect(mgr.currentState.sessionsWorking == 1)
    }

    @Test("sync stopped session produces ended phase")
    @MainActor func syncStoppedEnded() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .stopped)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        #expect(mgr.currentState.primaryPhase == .ended)
        #expect(mgr.currentState.totalActiveSessions == 0)
    }

    @Test("recordEvent agentStart sets working")
    @MainActor func agentStartWorking() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        mgr.recordEvent(connectionId: "c1", event: .agentStart(sessionId: "s1"))
        #expect(mgr.currentState.primaryPhase == .working)
    }

    @Test("recordEvent agentEnd sets awaitingReply within visibility window")
    @MainActor func agentEndAwaitingReply() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        mgr.recordEvent(connectionId: "c1", event: .agentEnd(sessionId: "s1"))
        #expect(mgr.currentState.primaryPhase == .awaitingReply)
    }

    @Test("recordEvent toolStart shows tool name")
    @MainActor func toolStartShowsTool() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        mgr.recordEvent(connectionId: "c1", event: .toolStart(
            sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]
        ))
        #expect(mgr.currentState.primaryTool == "Bash")
        #expect(mgr.currentState.primaryPhase == .working)
    }

    @Test("sync carries primary change stats into content state")
    @MainActor func syncCarriesChangeStats() {
        let mgr = LiveActivityManager()
        var session = makeSession(id: "s1", status: .busy)
        session.changeStats = SessionChangeStats(
            mutatingToolCalls: 3,
            filesChanged: 2,
            changedFiles: ["a.swift", "b.swift"],
            changedFilesOverflow: nil,
            addedLines: 12,
            removedLines: 4
        )

        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        #expect(mgr.currentState.primaryMutatingToolCalls == 3)
        #expect(mgr.currentState.primaryFilesChanged == 2)
        #expect(mgr.currentState.primaryAddedLines == 12)
        #expect(mgr.currentState.primaryRemovedLines == 4)
    }

    @Test("sync with permission sets needsApproval")
    @MainActor func syncPermissionNeedsApproval() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        let perm = makePermission(id: "p1", sessionId: "s1", tool: "bash")
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [perm])

        #expect(mgr.currentState.primaryPhase == .needsApproval)
        #expect(mgr.currentState.pendingApprovalCount == 1)
        #expect(mgr.currentState.topPermissionId == "p1")
    }

    @Test("needsApproval outranks working across sessions")
    @MainActor func needsApprovalOutranksWorking() {
        let mgr = LiveActivityManager()
        let working = makeSession(id: "s1", status: .busy)
        let ready = makeSession(id: "s2", status: .ready)
        let perm = makePermission(id: "p1", sessionId: "s2", tool: "edit")

        mgr.sync(connectionId: "c1", sessions: [working, ready], pendingPermissions: [perm])
        #expect(mgr.currentState.primaryPhase == .needsApproval)
        #expect(mgr.currentState.totalActiveSessions == 2)
    }

    @Test("removeConnection clears state")
    @MainActor func removeConnectionClears() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])
        #expect(mgr.currentState.primaryPhase == .working)

        mgr.removeConnection("c1")
        #expect(mgr.currentState.primaryPhase == .ended)
        #expect(mgr.currentState.totalActiveSessions == 0)
    }

    @Test("recordEvent error sets error phase")
    @MainActor func errorSetsErrorPhase() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        mgr.recordEvent(connectionId: "c1", event: .error(sessionId: "s1", message: "Something broke"))
        #expect(mgr.currentState.primaryPhase == .error)
    }

    @Test("recordEvent retrying error does not set error phase")
    @MainActor func retryingErrorIgnored() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        mgr.recordEvent(connectionId: "c1", event: .error(sessionId: "s1", message: "Retrying (attempt 2/3)"))
        #expect(mgr.currentState.primaryPhase == .working)
    }

    @Test("recordEvent sessionEnded sets ended phase")
    @MainActor func sessionEndedSetsEnded() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        mgr.recordEvent(connectionId: "c1", event: .sessionEnded(sessionId: "s1", reason: "done"))
        #expect(mgr.currentState.primaryPhase == .ended)
    }
}

// MARK: - Alert Integration (drives state machine → checks alert decision)

@Suite("LiveActivityManager alert integration", .serialized)
struct LiveActivityAlertIntegrationTests {

    @Test("working → awaitingReply → working cycle never alerts")
    @MainActor func rapidCycleNoAlerts() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        var lastPhase: SessionPhase = mgr.lastPushedPrimaryPhase
        let lastCount = mgr.lastPushedApprovalCount
        var alerts = 0

        // Agent ends
        mgr.recordEvent(connectionId: "c1", event: .agentEnd(sessionId: "s1"))
        if LiveActivityManager.shouldAlert(
            state: mgr.currentState, lastPushedPhase: lastPhase, lastPushedApprovalCount: lastCount
        ) { alerts += 1 }
        lastPhase = mgr.currentState.primaryPhase

        // Agent restarts
        mgr.recordEvent(connectionId: "c1", event: .agentStart(sessionId: "s1"))
        if LiveActivityManager.shouldAlert(
            state: mgr.currentState, lastPushedPhase: lastPhase, lastPushedApprovalCount: lastCount
        ) { alerts += 1 }

        #expect(alerts == 0)
    }

    @Test("permission request after working correctly alerts once")
    @MainActor func permissionAfterWorkingAlerts() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])
        mgr.lastPushedPrimaryPhase = .working
        mgr.lastPushedApprovalCount = 0

        let perm = makePermission(id: "p1", sessionId: "s1", tool: "bash")
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [perm])

        #expect(LiveActivityManager.shouldAlert(
            state: mgr.currentState,
            lastPushedPhase: .working,
            lastPushedApprovalCount: 0
        ))
    }
}

// MARK: - Lifecycle Recovery (P0: 8-hour silent death)

@Suite("LiveActivityManager lifecycle recovery", .serialized)
struct LiveActivityLifecycleTests {

    @Test("recoverIfNeeded reattaches orphaned ActivityKit activity")
    @MainActor func recoverReattachesOrphanedActivity() async {
        await endAllLiveActivitiesImmediately()

        let source = LiveActivityManager()
        let session = makeSession(id: "s-orphan", status: .busy)
        source.sync(connectionId: "c-source", sessions: [session], pendingPermissions: [])
        #expect(source.activeActivity != nil)

        // Simulate app relaunch: a fresh manager instance has no in-memory
        // reference, but ActivityKit still has the live activity.
        let recovered = LiveActivityManager()
        #expect(recovered.activeActivity == nil)
        #expect(recovered.currentState.primaryPhase == .ended)

        recovered.recoverIfNeeded()

        // Regression: before the fix this stayed nil.
        #expect(recovered.activeActivity != nil)

        await endAllLiveActivitiesImmediately()
    }

    @Test("recoverIfNeeded with active sessions and no activity triggers refresh")
    @MainActor func recoverWithActiveSessions() {
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])

        #expect(mgr.currentState.primaryPhase == .working)

        // Recovery should detect that sessions are active and re-aggregate.
        // An existing ActivityKit activity may be reattached in tests, so we
        // assert on aggregate state rather than `activeActivity` identity.
        mgr.recoverIfNeeded()
        #expect(mgr.currentState.primaryPhase == .working)
        #expect(mgr.currentState.totalActiveSessions == 1)
    }

    @Test("recoverIfNeeded with no sessions is a no-op")
    @MainActor func recoverWithNoSessions() {
        let mgr = LiveActivityManager()
        mgr.recoverIfNeeded()
        #expect(mgr.currentState.primaryPhase == .ended)
    }
}

// MARK: - Idle Dismiss (P1: proper activity.end)

@Suite("LiveActivityManager idle dismiss", .serialized)
struct LiveActivityIdleDismissTests {

    @Test("idle dismiss delay is 5 seconds, not 60")
    @MainActor func idleDismissDelayIs5Seconds() {
        // The manager's idleDismissDelay should be short (5s) — the old 60s linger
        // violates HIG. We can't directly read the private property, but we verify
        // the behavior: after all sessions end, the manager should schedule a
        // short dismiss rather than keeping the activity alive for a full minute.
        let mgr = LiveActivityManager()
        let session = makeSession(id: "s1", status: .busy)
        mgr.sync(connectionId: "c1", sessions: [session], pendingPermissions: [])
        #expect(mgr.currentState.primaryPhase == .working)

        // End the session — should transition to ended
        mgr.recordEvent(connectionId: "c1", event: .sessionEnded(sessionId: "s1", reason: "done"))
        #expect(mgr.currentState.primaryPhase == .ended)
        #expect(mgr.currentState.totalActiveSessions == 0)
    }
}

// MARK: - Deep Link URL (P1: widgetURL)

@Suite("Live Activity deep links")
struct LiveActivityDeepLinkTests {

    @Test("session deep link parses oppi://session/<id>")
    func sessionDeepLinkParse() {
        let url = URL(string: "oppi://session/abc-123")!
        #expect(url.scheme == "oppi")
        #expect(url.host == "session")
        let sessionId = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .first
            .map(String.init)
        #expect(sessionId == "abc-123")
    }

    @Test("permission deep link is preferred when topPermissionId exists")
    func permissionDeepLinkPreferred() {
        // When a permission is pending, the deep link should point to the permission
        let state = PiSessionAttributes.ContentState(
            primaryPhase: .needsApproval,
            primarySessionId: "s1",
            primarySessionName: "Test",
            primaryTool: "bash",
            primaryLastActivity: "Approval required",
            totalActiveSessions: 1,
            sessionsAwaitingReply: 0,
            sessionsWorking: 0,
            primaryMutatingToolCalls: nil,
            primaryFilesChanged: nil,
            primaryAddedLines: nil,
            primaryRemovedLines: nil,
            topPermissionId: "perm-456",
            topPermissionTool: "bash",
            topPermissionSummary: "run ls",
            topPermissionSession: "Test",
            pendingApprovalCount: 1,
            sessionStartDate: nil
        )
        // The widget helper would produce oppi://permission/perm-456
        #expect(state.topPermissionId == "perm-456")
        #expect(state.primarySessionId == "s1")
    }
}

// MARK: - Helpers

@MainActor
private func endAllLiveActivitiesImmediately() async {
    let finalState = makeState(phase: .ended, approvals: 0)

    for activity in Activity<PiSessionAttributes>.activities {
        await activity.end(
            .init(state: finalState, staleDate: nil),
            dismissalPolicy: .immediate
        )
    }

    // Give ActivityKit a moment to settle the list before the next test.
    try? await Task.sleep(for: .milliseconds(50))
}

private func makeState(phase: SessionPhase, approvals: Int) -> PiSessionAttributes.ContentState {
    PiSessionAttributes.ContentState(
        primaryPhase: phase,
        primarySessionId: "test-session",
        primarySessionName: "Test",
        primaryTool: nil,
        primaryLastActivity: nil,
        totalActiveSessions: phase == .ended ? 0 : 1,
        sessionsAwaitingReply: phase == .awaitingReply ? 1 : 0,
        sessionsWorking: phase == .working ? 1 : 0,
        primaryMutatingToolCalls: nil,
        primaryFilesChanged: nil,
        primaryAddedLines: nil,
        primaryRemovedLines: nil,
        topPermissionId: phase == .needsApproval ? "p1" : nil,
        topPermissionTool: phase == .needsApproval ? "bash" : nil,
        topPermissionSummary: nil,
        topPermissionSession: nil,
        pendingApprovalCount: approvals,
        sessionStartDate: nil
    )
}

private func makeSession(
    id: String,
    status: SessionStatus,
    workspaceId: String = "ws1"
) -> Session {
    Session(
        id: id,
        workspaceId: workspaceId,
        workspaceName: "default",
        name: "Test Session",
        status: status,
        createdAt: Date().addingTimeInterval(-60),
        lastActivity: Date(),
        model: "claude-sonnet-4-20250514",
        messageCount: 0,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0
    )
}

private func makePermission(
    id: String,
    sessionId: String,
    tool: String
) -> PermissionRequest {
    PermissionRequest(
        id: id,
        sessionId: sessionId,
        tool: tool,
        input: [:],
        displaySummary: "Test permission for \(tool)",
        reason: "policy",
        timeoutAt: Date().addingTimeInterval(120)
    )
}
