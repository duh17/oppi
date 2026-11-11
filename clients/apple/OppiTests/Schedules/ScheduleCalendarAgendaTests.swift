import Foundation
import Testing
@testable import Oppi

/// The calendar's day, from the server's answer in `protocol/schedule-calendar.json`
/// (Wed Nov 11 2026, now 8:42 AM Pacific): what each entry's outcome is, how the night
/// folds, where now sits, what the day sums to, and the words for time.
@Suite("Schedule calendar agenda")
struct ScheduleCalendarAgendaTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private static func response() throws -> ScheduleCalendarResponse {
        struct Fixture: Decodable { let body: ScheduleCalendarResponse }
        return try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("schedule-calendar.json")).body
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    @Test("every entry shape in the contract reads as its outcome")
    func outcomesFromTheContract() throws {
        let response = try Self.response()
        #expect(response.now == Self.date("2026-11-11T16:42:00Z"))
        let agenda = ScheduleCalendarAgenda(response: response)
        let outcomes = Dictionary(uniqueKeysWithValues: agenda.items.map { ($0.runId ?? $0.id, $0.outcome) })
        #expect(outcomes["run-kypu"] == .done)
        #expect(outcomes["run-night"] == .running)
        #expect(outcomes["run-mirror"] == .didNotStart)
        #expect(outcomes["run-digest"] == .failed)
        #expect(outcomes["run-jobs"] == .needsYou(.question))
        #expect(outcomes["run-nanny-manual"] == .starting)
        #expect(agenda.items.filter { $0.outcome == .upcoming }.count == 3)

        let digest = try #require(agenda.items.first { $0.runId == "run-digest" })
        #expect(digest.cost == 1.65)
        #expect(digest.workspaceId == "chaosdonkey")
        #expect(digest.model == "anthropic/claude-opus-5-5")
        // Milliseconds decoded as Double: compare to the millisecond.
        #expect(abs((digest.duration(now: response.now) ?? 0) - (5 * 60 + 8)) < 0.001)
        let hawaii = try #require(agenda.items.first { $0.scheduleId == "hawaii01" })
        #expect(hawaii.sendsIntoExistingSession)

        // A failed run carries the session's error, a waiting one its question; a run that
        // is fine carries neither.
        #expect(digest.sessionMessage == "Provider returned 529")
        #expect(agenda.items.first { $0.runId == "run-jobs" }?.sessionMessage == "Apply to these three?")
        #expect(agenda.items.first { $0.runId == "run-kypu" }?.sessionMessage == nil)
        #expect(agenda.items.first { $0.runId == "run-mirror" }?.runError == "approval_required_noninteractive: bash git push")
    }

    @Test("the night folds two or more clean runs; problems and running runs break out")
    func nightBand() throws {
        var response = try Self.response()
        // A second clean night run, so the night has something to fold.
        let journal = Self.date("2026-11-11T08:15:00Z")
        response.schedules.append(ScheduleCalendarSchedule(
            id: "journal1", name: "Daily life journal", status: .active,
            trigger: .cron(expression: "15 0 * * *", timeZone: "America/Los_Angeles"),
            action: AgentScheduleActionSummary(type: .newSession, workspaceId: "notes", promptChars: 10),
            upcomingTruncated: false
        ))
        response.entries.append(ScheduleCalendarEntry(
            scheduleId: "journal1", slotKey: "cron:x", at: journal,
            run: ScheduleCalendarRun(
                id: "run-journal", kind: .due, status: .completed, createdAt: journal,
                session: ScheduleCalendarSession(
                    id: "sess-journal", status: .stopped,
                    programStatus: ProgramStatus(state: .done, since: journal.addingTimeInterval(120)), cost: 0.3
                )
            )
        ))
        let agenda = ScheduleCalendarAgenda(response: response)
        let now = response.now

        let (night, _) = agenda.rows(on: now, now: now, calendar: Self.calendar)
        guard case .cluster(let cluster) = night.first else {
            Issue.record("The night opens with its cluster: \(night)")
            return
        }
        #expect(cluster.id == "cluster.2026-11-11")
        #expect(cluster.items.map(\.runId) == ["run-kypu", "run-journal"])
        #expect(abs(cluster.totalCost - 0.72) < 0.001)
        #expect(night.dropFirst().map(Self.runId) == ["run-night"], "Running breaks out at its time")

        let (expanded, _) = agenda.rows(on: now, now: now, calendar: Self.calendar, expandedClusters: [cluster.id])
        #expect(expanded.map(Self.runId) == [nil, "run-kypu", "run-journal", "run-night"], "Expanded, the runs follow their cluster")

        // One clean run alone is a quiet row, not a cluster of one.
        let single = ScheduleCalendarAgenda(response: try Self.response())
        #expect(single.rows(on: now, now: now, calendar: Self.calendar).night.map(Self.runId) == ["run-kypu", "run-night"])
    }

    @Test("now sits before the first row still to come, on today only")
    func nowLine() throws {
        let response = try Self.response()
        let agenda = ScheduleCalendarAgenda(response: response)
        let (_, day) = agenda.rows(on: response.now, now: response.now, calendar: Self.calendar)
        let labels = day.map { row -> String in
            switch row {
            case .now: "now"
            case .entry(let item): item.runId ?? item.scheduleId
            case .cluster: "cluster"
            }
        }
        #expect(labels == ["run-mirror", "run-digest", "run-jobs", "run-nanny-manual", "now", "hawaii01", "nanny917", "nanny917"])

        let tomorrow = try #require(Self.calendar.date(byAdding: .day, value: 1, to: response.now))
        let (night, later) = agenda.rows(on: tomorrow, now: response.now, calendar: Self.calendar)
        #expect(!(night + later).contains(.now(response.now)), "Another day has no now line")
    }

    @Test("the day sums each outcome and each session's cost once")
    func summary() throws {
        let response = try Self.response()
        let agenda = ScheduleCalendarAgenda(response: response)
        let summary = agenda.summary(on: response.now, calendar: Self.calendar)
        #expect(summary.done == 1)
        #expect(summary.running == 2, "Running and starting")
        #expect(summary.failed == 2, "Failed and didn't start")
        #expect(summary.needsYou == 1)
        #expect(summary.upcoming == 3, "The two at 9:00 and Nanny's 5 PM, which is tomorrow in UTC but today here")
        #expect(abs(summary.cost - (0.42 + 4.88 + 1.65 + 0.58)) < 0.001)

        let health = agenda.health(on: response.now, calendar: Self.calendar)
        #expect(health.hasFailure && health.needsYou && health.ran && health.hasUpcoming)
    }

    @Test("the app's live session overrides the answer's outcome and cost")
    func liveSessionWins() throws {
        let response = try Self.response()
        let blocked = ScheduleCalendarAgenda.SessionFacts(
            status: .ready,
            programStatus: ProgramStatus(state: .blocked, kind: .permission, since: response.now),
            cost: 5.10
        )
        let agenda = ScheduleCalendarAgenda(response: response, live: ["sess-night": blocked])
        let night = try #require(agenda.items.first { $0.runId == "run-night" })
        #expect(night.outcome == .needsYou(.needsApproval))
        #expect(night.cost == 5.10)
    }

    @Test("countdowns and durations in their written and spoken forms")
    func words() {
        let calendar = Self.calendar
        let now = Self.date("2026-11-11T16:42:00Z")
        let locale = Locale(identifier: "en_US")
        #expect(ScheduleCalendarText.countdown(to: now.addingTimeInterval(18 * 60), now: now, calendar: calendar, locale: locale) == "in 18m")
        #expect(ScheduleCalendarText.countdown(to: now.addingTimeInterval(125 * 60), now: now, calendar: calendar, locale: locale) == "in 2h 05m")
        let thursday = ScheduleCalendarText.countdown(to: Self.date("2026-11-12T23:00:00Z"), now: now, calendar: calendar, locale: locale)
        #expect(thursday.hasPrefix("Thu") && thursday.contains("3:00"))
        #expect(ScheduleCalendarText.spokenCountdown(to: now.addingTimeInterval(18 * 60), now: now, calendar: calendar, locale: locale) == "in 18 minutes")
        #expect(ScheduleCalendarText.duration(30) == "<1m")
        #expect(ScheduleCalendarText.duration(5 * 3_600 + 12 * 60) == "5h 12m")
        #expect(ScheduleCalendarText.spokenDuration(5 * 3_600 + 12 * 60, calendar: calendar, locale: locale) == "5 hours, 12 minutes")
        let parts = ScheduleCalendarText.timeParts(Self.date("2026-11-11T08:05:00Z"), calendar: calendar, locale: locale)
        #expect(parts.time == "12:05")
        #expect(parts.period == "AM")
    }

    private static func runId(_ row: ScheduleCalendarAgenda.Row) -> String? {
        if case .entry(let item) = row { return item.runId }
        return nil
    }
}
