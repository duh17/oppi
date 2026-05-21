import Foundation
import Testing
@testable import Oppi

// MARK: - Helpers

/// Build a session with minimal fields relevant to urgency sorting.
private func makeSession(
    id: String,
    status: SessionStatus = .busy,
    lastActivity: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> Session {
    Session(
        id: id,
        workspaceId: "ws1",
        workspaceName: "Test",
        name: "Session \(id)",
        status: status,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastActivity: lastActivity,
        model: "test/model",
        messageCount: 0,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0
    )
}

// MARK: - Score tests

@Suite("Quick Session Urgency Score")
struct QuickSessionUrgencyScoreTests {

    // ── Individual tier values ──

    @Test func permission_isHighestUrgency() {
        let score = quickSessionUrgencyScore(status: .ready, hasPermission: true, hasAsk: false)
        #expect(score == 30)
    }

    @Test func ask_isSecondHighestUrgency() {
        let score = quickSessionUrgencyScore(status: .ready, hasPermission: false, hasAsk: true)
        #expect(score == 20)
    }

    @Test func error_scoresAboveBusy() {
        let score = quickSessionUrgencyScore(status: .error, hasPermission: false, hasAsk: false)
        #expect(score == 15)
    }

    @Test func busy_scoresTen() {
        let score = quickSessionUrgencyScore(status: .busy, hasPermission: false, hasAsk: false)
        #expect(score == 10)
    }

    @Test func starting_sameAsBusy() {
        let score = quickSessionUrgencyScore(status: .starting, hasPermission: false, hasAsk: false)
        #expect(score == 10)
    }

    @Test func stopping_sameAsBusy() {
        let score = quickSessionUrgencyScore(status: .stopping, hasPermission: false, hasAsk: false)
        #expect(score == 10)
    }

    @Test func ready_scoresAboveStopped() {
        let score = quickSessionUrgencyScore(status: .ready, hasPermission: false, hasAsk: false)
        #expect(score == 5)
    }

    @Test func stopped_isLowestUrgency() {
        let score = quickSessionUrgencyScore(status: .stopped, hasPermission: false, hasAsk: false)
        #expect(score == 0)
    }

    // ── Precedence: permission wins over ask ──

    @Test func permission_takePrecedenceOverAsk() {
        let score = quickSessionUrgencyScore(status: .error, hasPermission: true, hasAsk: true)
        #expect(score == 30, "Permission should dominate even when ask is also present")
    }

    // ── Precedence: permission wins over status ──

    @Test func permission_overridesStoppedStatus() {
        let score = quickSessionUrgencyScore(status: .stopped, hasPermission: true, hasAsk: false)
        #expect(score == 30, "Permission elevates even a stopped session to top urgency")
    }

    // ── Precedence: ask wins over status ──

    @Test func ask_overridesErrorStatus() {
        let score = quickSessionUrgencyScore(status: .error, hasPermission: false, hasAsk: true)
        #expect(score == 20, "Ask should rank above error when no permission")
    }

    // ── Full tier ordering ──

    @Test func fullTierOrdering_permissionsAboveAsksAboveErrorsAboveBusyAboveReadyAboveStopped() {
        let permScore = quickSessionUrgencyScore(status: .ready, hasPermission: true, hasAsk: false)
        let askScore = quickSessionUrgencyScore(status: .ready, hasPermission: false, hasAsk: true)
        let errorScore = quickSessionUrgencyScore(status: .error, hasPermission: false, hasAsk: false)
        let busyScore = quickSessionUrgencyScore(status: .busy, hasPermission: false, hasAsk: false)
        let readyScore = quickSessionUrgencyScore(status: .ready, hasPermission: false, hasAsk: false)
        let stoppedScore = quickSessionUrgencyScore(status: .stopped, hasPermission: false, hasAsk: false)

        #expect(permScore > askScore)
        #expect(askScore > errorScore)
        #expect(errorScore > busyScore)
        #expect(busyScore > readyScore)
        #expect(readyScore > stoppedScore)
    }
}

// MARK: - Sort tests

@Suite("Quick Session Sort Order")
struct QuickSessionSortTests {

    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    // ── Basic urgency ordering ──

    @Test func sort_permissionSessionComesFirst() {
        let sessions = [
            makeSession(id: "ready", status: .ready),
            makeSession(id: "perm", status: .ready),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasPermission: { $0 == "perm" },
            hasAsk: { _ in false }
        )
        #expect(sorted.map(\.id) == ["perm", "ready"])
    }

    @Test func sort_askBeforeErrorBeforeBusy() {
        let sessions = [
            makeSession(id: "busy", status: .busy),
            makeSession(id: "ask", status: .ready),
            makeSession(id: "error", status: .error),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasPermission: { _ in false },
            hasAsk: { $0 == "ask" }
        )
        #expect(sorted.map(\.id) == ["ask", "error", "busy"])
    }

    @Test func sort_fullPriorityChain() {
        let sessions = [
            makeSession(id: "stopped", status: .stopped),
            makeSession(id: "ready", status: .ready),
            makeSession(id: "busy", status: .busy),
            makeSession(id: "error", status: .error),
            makeSession(id: "ask", status: .ready),
            makeSession(id: "perm", status: .ready),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasPermission: { $0 == "perm" },
            hasAsk: { $0 == "ask" }
        )
        #expect(sorted.map(\.id) == ["perm", "ask", "error", "busy", "ready", "stopped"])
    }

    // ── Tiebreaker: last activity ──

    @Test func sort_sameUrgency_moreRecentActivityFirst() {
        let older = makeSession(id: "older", status: .busy, lastActivity: baseTime)
        let newer = makeSession(id: "newer", status: .busy, lastActivity: baseTime.addingTimeInterval(60))
        let sorted = quickSessionSorted(
            [older, newer],
            hasPermission: { _ in false },
            hasAsk: { _ in false }
        )
        #expect(sorted.map(\.id) == ["newer", "older"])
    }

    @Test func sort_tiebreaker_withinPermissionTier() {
        let sessions = [
            makeSession(id: "old-perm", status: .ready, lastActivity: baseTime),
            makeSession(id: "new-perm", status: .ready, lastActivity: baseTime.addingTimeInterval(120)),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasPermission: { _ in true },
            hasAsk: { _ in false }
        )
        #expect(sorted.map(\.id) == ["new-perm", "old-perm"])
    }

    // ── Edge cases ──

    @Test func sort_emptyList() {
        let sorted = quickSessionSorted(
            [],
            hasPermission: { _ in false },
            hasAsk: { _ in false }
        )
        #expect(sorted.isEmpty)
    }

    @Test func sort_singleSession() {
        let sessions = [makeSession(id: "solo", status: .error)]
        let sorted = quickSessionSorted(
            sessions,
            hasPermission: { _ in false },
            hasAsk: { _ in false }
        )
        #expect(sorted.count == 1)
        #expect(sorted[0].id == "solo")
    }

    @Test func sort_allSameUrgency_preservesActivityOrder() {
        let sessions = (0..<5).map { i in
            makeSession(
                id: "s\(i)",
                status: .busy,
                lastActivity: baseTime.addingTimeInterval(Double(i) * 10)
            )
        }
        let sorted = quickSessionSorted(
            sessions,
            hasPermission: { _ in false },
            hasAsk: { _ in false }
        )
        // Most recent activity first
        #expect(sorted.map(\.id) == ["s4", "s3", "s2", "s1", "s0"])
    }

    @Test func sort_multiplePermissions_orderedByActivity() {
        let sessions = [
            makeSession(id: "p1", status: .busy, lastActivity: baseTime),
            makeSession(id: "p2", status: .ready, lastActivity: baseTime.addingTimeInterval(30)),
            makeSession(id: "p3", status: .error, lastActivity: baseTime.addingTimeInterval(60)),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasPermission: { _ in true },
            hasAsk: { _ in false }
        )
        // All at score 30, so ordered by activity descending
        #expect(sorted.map(\.id) == ["p3", "p2", "p1"])
    }

    @Test func sort_startingAndStoppingGroupWithBusy() {
        let sessions = [
            makeSession(id: "starting", status: .starting, lastActivity: baseTime),
            makeSession(id: "stopping", status: .stopping, lastActivity: baseTime.addingTimeInterval(10)),
            makeSession(id: "busy", status: .busy, lastActivity: baseTime.addingTimeInterval(20)),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasPermission: { _ in false },
            hasAsk: { _ in false }
        )
        // All score 10, ordered by activity
        #expect(sorted.map(\.id) == ["busy", "stopping", "starting"])
    }

    @Test func sort_permissionElevatesStoppedAboveError() {
        let sessions = [
            makeSession(id: "error-plain", status: .error),
            makeSession(id: "stopped-perm", status: .stopped),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasPermission: { $0 == "stopped-perm" },
            hasAsk: { _ in false }
        )
        #expect(sorted.map(\.id) == ["stopped-perm", "error-plain"],
                "Permission on stopped session should outrank a plain error")
    }

    @Test func sort_askElevatesBusyAboveError() {
        let sessions = [
            makeSession(id: "error-plain", status: .error),
            makeSession(id: "busy-ask", status: .busy),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasPermission: { _ in false },
            hasAsk: { $0 == "busy-ask" }
        )
        #expect(sorted.map(\.id) == ["busy-ask", "error-plain"],
                "Ask on busy session should outrank a plain error")
    }
}

// MARK: - Sessions Home Sections

@Suite("Shared Session List Active Sections")
struct SessionsHomeActiveSectionTests {

    @Test func permissionRoutesBusySessionToYourTurn() {
        let session = makeSession(id: "perm", status: .busy)
        let section = SessionListPresentation.activeSectionKind(
            for: session,
            attention: SessionListAttentionCounts(permissionCount: 1, askCount: 0)
        )
        #expect(section == .yourTurn)
    }

    @Test func askRoutesReadySessionToYourTurn() {
        let session = makeSession(id: "ask", status: .ready)
        let section = SessionListPresentation.activeSectionKind(
            for: session,
            attention: SessionListAttentionCounts(permissionCount: 0, askCount: 1)
        )
        #expect(section == .yourTurn)
    }

    @Test func busyWithoutAttentionRoutesToWorking() {
        let session = makeSession(id: "busy", status: .busy)
        let section = SessionListPresentation.activeSectionKind(for: session)
        #expect(section == .working)
    }

    @Test func readyWithoutAttentionRoutesToYourTurn() {
        let session = makeSession(id: "ready", status: .ready)
        let section = SessionListPresentation.activeSectionKind(for: session)
        #expect(section == .yourTurn)
    }

    @Test func stoppedSessionHasNoActiveSection() {
        let session = makeSession(id: "stopped", status: .stopped)
        let section = SessionListPresentation.activeSectionKind(for: session)
        #expect(section == nil)
    }
}

// MARK: - QuickSessionNav

@Suite("Quick Session Nav")
struct QuickSessionNavTests {

    @Test func init_minimalFields() {
        let ws = makeTestWorkspace(id: "w1", name: "Dev")
        let target = WorkspaceNavTarget(serverId: "srv1", workspace: ws)
        let nav = QuickSessionNav(target: target, sessionId: "abc")

        #expect(nav.sessionId == "abc")
        #expect(nav.target.serverId == "srv1")
        #expect(nav.target.workspace.id == "w1")
        #expect(nav.autoSendMessage == nil)
        #expect(nav.autoSendImages == nil)
    }

    @Test func init_withAutoSend() {
        let ws = makeTestWorkspace(id: "w1", name: "Dev")
        let target = WorkspaceNavTarget(serverId: "srv1", workspace: ws)
        let nav = QuickSessionNav(
            target: target,
            sessionId: "abc",
            autoSendMessage: "Fix the bug"
        )

        #expect(nav.autoSendMessage == "Fix the bug")
        #expect(nav.autoSendImages == nil)
    }
}
