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
    @Test func ask_isHighestUrgency() {
        let score = quickSessionUrgencyScore(status: .ready, hasAsk: true)
        #expect(score == 20)
    }

    @Test func error_scoresAboveBusy() {
        let score = quickSessionUrgencyScore(status: .error, hasAsk: false)
        #expect(score == 15)
    }

    @Test func busy_scoresTen() {
        let score = quickSessionUrgencyScore(status: .busy, hasAsk: false)
        #expect(score == 10)
    }

    @Test func starting_sameAsBusy() {
        let score = quickSessionUrgencyScore(status: .starting, hasAsk: false)
        #expect(score == 10)
    }

    @Test func stopping_sameAsBusy() {
        let score = quickSessionUrgencyScore(status: .stopping, hasAsk: false)
        #expect(score == 10)
    }

    @Test func ready_scoresAboveStopped() {
        let score = quickSessionUrgencyScore(status: .ready, hasAsk: false)
        #expect(score == 5)
    }

    @Test func stopped_isLowestUrgency() {
        let score = quickSessionUrgencyScore(status: .stopped, hasAsk: false)
        #expect(score == 0)
    }

    @Test func ask_overridesErrorStatus() {
        let score = quickSessionUrgencyScore(status: .error, hasAsk: true)
        #expect(score == 20, "Ask should rank above error")
    }

    @Test func fullTierOrdering_asksAboveErrorsAboveBusyAboveReadyAboveStopped() {
        let askScore = quickSessionUrgencyScore(status: .ready, hasAsk: true)
        let errorScore = quickSessionUrgencyScore(status: .error, hasAsk: false)
        let busyScore = quickSessionUrgencyScore(status: .busy, hasAsk: false)
        let readyScore = quickSessionUrgencyScore(status: .ready, hasAsk: false)
        let stoppedScore = quickSessionUrgencyScore(status: .stopped, hasAsk: false)

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

    @Test func sort_askBeforeErrorBeforeBusy() {
        let sessions = [
            makeSession(id: "busy", status: .busy),
            makeSession(id: "ask", status: .ready),
            makeSession(id: "error", status: .error),
        ]
        let sorted = quickSessionSorted(
            sessions,
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
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasAsk: { $0 == "ask" }
        )
        #expect(sorted.map(\.id) == ["ask", "error", "busy", "ready", "stopped"])
    }

    @Test func sort_sameUrgency_moreRecentActivityFirst() {
        let older = makeSession(id: "older", status: .busy, lastActivity: baseTime)
        let newer = makeSession(id: "newer", status: .busy, lastActivity: baseTime.addingTimeInterval(60))
        let sorted = quickSessionSorted(
            [older, newer],
            hasAsk: { _ in false }
        )
        #expect(sorted.map(\.id) == ["newer", "older"])
    }

    @Test func sort_tiebreaker_withinAskTier() {
        let sessions = [
            makeSession(id: "old-ask", status: .ready, lastActivity: baseTime),
            makeSession(id: "new-ask", status: .ready, lastActivity: baseTime.addingTimeInterval(120)),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasAsk: { _ in true }
        )
        #expect(sorted.map(\.id) == ["new-ask", "old-ask"])
    }

    @Test func sort_emptyList() {
        let sorted = quickSessionSorted(
            [],
            hasAsk: { _ in false }
        )
        #expect(sorted.isEmpty)
    }

    @Test func sort_singleSession() {
        let sessions = [makeSession(id: "solo", status: .error)]
        let sorted = quickSessionSorted(
            sessions,
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
            hasAsk: { _ in false }
        )
        #expect(sorted.map(\.id) == ["s4", "s3", "s2", "s1", "s0"])
    }

    @Test func sort_startingAndStoppingGroupWithBusy() {
        let sessions = [
            makeSession(id: "starting", status: .starting, lastActivity: baseTime),
            makeSession(id: "stopping", status: .stopping, lastActivity: baseTime.addingTimeInterval(10)),
            makeSession(id: "busy", status: .busy, lastActivity: baseTime.addingTimeInterval(20)),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasAsk: { _ in false }
        )
        #expect(sorted.map(\.id) == ["busy", "stopping", "starting"])
    }

    @Test func sort_askElevatesBusyAboveError() {
        let sessions = [
            makeSession(id: "error-plain", status: .error),
            makeSession(id: "busy-ask", status: .busy),
        ]
        let sorted = quickSessionSorted(
            sessions,
            hasAsk: { $0 == "busy-ask" }
        )
        #expect(sorted.map(\.id) == ["busy-ask", "error-plain"],
                "Ask on busy session should outrank a plain error")
    }
}

// MARK: - Workspace Session List Sections

@Suite("Shared Session List Active Sections")
struct SharedSessionListActiveSectionTests {
    @Test func askRoutesReadySessionToYourTurn() {
        let session = makeSession(id: "ask", status: .ready)
        let section = SessionListPresentation.activeSectionKind(
            for: session,
            attention: SessionListAttentionCounts(askCount: 1)
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

    @Test func attentionMergerKeepsSummaryCountsWhenLivePayloadsAreMissing() {
        #expect(
            SessionListAttentionMerger.askCount(
                listCount: 1,
                hasPendingAsk: false,
                hasPendingExtensionDialog: false
            ) == 1
        )
    }

    @Test func attentionMergerDoesNotTreatExtensionDialogAsQuestion() {
        #expect(
            SessionListAttentionMerger.askCount(
                listCount: 0,
                hasPendingAsk: false,
                hasPendingExtensionDialog: true
            ) == 0
        )
    }
}

// MARK: - Recent stopped sessions

@Suite("Session Inbox Recent Stopped Days")
struct SessionInboxRecentStoppedDayTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }

    @Test func visibleRangeCoversTodayAndTwoPriorCalendarDays() throws {
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 10,
            hour: 12
        )))
        let expected = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8
        )))

        #expect(SessionInboxStoppedDayPolicy.visibleDayCount == 3)
        #expect(
            SessionInboxStoppedDayPolicy.visibleRangeStart(now: now, calendar: calendar) == expected
        )
    }

    @Test func groupingOmitsSessionsOutsideThreeCalendarDays() throws {
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 10,
            hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: today))
        let sessions = [
            makeSession(id: "today", status: .stopped, lastActivity: now),
            makeSession(id: "yesterday", status: .stopped, lastActivity: yesterday),
            makeSession(id: "two-days", status: .stopped, lastActivity: twoDaysAgo),
            makeSession(id: "too-old", status: .stopped, lastActivity: threeDaysAgo),
        ]

        let groups = SessionInboxStoppedDayPolicy.groups(
            sessions,
            now: now,
            calendar: calendar,
            activityDate: { $0.lastActivity }
        )

        #expect(groups.map(\.day) == [today, yesterday, twoDaysAgo])
        #expect(groups.flatMap(\.items).map(\.id) == ["today", "yesterday", "two-days"])
    }

    @Test func stoppedIncognitoSessionsAreNotVisible() {
        var incognito = makeSession(id: "incognito", status: .stopped)
        incognito.ephemeral = true
        let regular = makeSession(id: "regular", status: .stopped)

        #expect(!SessionInboxStoppedDayPolicy.includesStoppedSession(incognito))
        #expect(SessionInboxStoppedDayPolicy.includesStoppedSession(regular))
    }

    @Test func onlyTodayIsExpandedByDefault() throws {
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 10,
            hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))

        #expect(
            SessionInboxStoppedDayPolicy.isExpandedByDefault(
                day: today,
                now: now,
                calendar: calendar
            )
        )
        #expect(
            !SessionInboxStoppedDayPolicy.isExpandedByDefault(
                day: yesterday,
                now: now,
                calendar: calendar
            )
        )
    }

    @Test func titlesUseRelativeLabelsForTodayAndYesterday() throws {
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 10,
            hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))

        #expect(SessionInboxStoppedDayPolicy.title(for: today, now: now, calendar: calendar) == "Today")
        #expect(SessionInboxStoppedDayPolicy.title(for: yesterday, now: now, calendar: calendar) == "Yesterday")
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
        #expect(nav.autoSendAttachments == nil)
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
        #expect(nav.autoSendAttachments == nil)
    }
}
