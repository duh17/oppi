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

    /// The app's live copy of session `id`, as the session store holds it.
    private static func live(_ id: String, _ status: SessionStatus, _ programStatus: ProgramStatus, cost: Double) -> Session {
        Session(
            id: id, status: status, createdAt: programStatus.since, lastActivity: programStatus.since,
            programStatus: programStatus, messageCount: 4, tokens: TokenUsage(input: 0, output: 0), cost: cost
        )
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
            case .event(let event, _): event.id
            }
        }
        #expect(labels == ["run-mirror", "run-digest", "run-jobs", "run-nanny-manual", "now", "hawaii01", "nanny917", "nanny917"])

        let tomorrow = try #require(Self.calendar.date(byAdding: .day, value: 1, to: response.now))
        let (night, later) = agenda.rows(on: tomorrow, now: response.now, calendar: Self.calendar)
        #expect(!(night + later).contains(.now(response.now)), "Another day has no now line")
    }

    @Test("a run sent into an existing session reads Sent with no cost, whatever that session does now")
    func existingSessionSend() throws {
        var response = try Self.response()
        let sentAt = Self.date("2026-11-10T17:00:00Z")
        // Yesterday's send into the session that today's one-shot also sends into. The
        // session is busy now and has cost $40 over its life.
        let session = ScheduleCalendarSession(
            id: "sess-hawaii", status: .busy,
            programStatus: ProgramStatus(state: .working, since: response.now), cost: 40
        )
        response.entries.append(ScheduleCalendarEntry(
            scheduleId: "hawaii01", slotKey: "manual:yesterday", at: sentAt,
            run: ScheduleCalendarRun(
                id: "run-hawaii", kind: .manual, status: .completed, createdAt: sentAt,
                promptDispatch: "delivered", session: session
            )
        ))
        let live = Self.live(
            "sess-hawaii", .ready, ProgramStatus(state: .blocked, kind: .question, since: response.now), cost: 41
        )
        let agenda = ScheduleCalendarAgenda(response: response, live: ["sess-hawaii": live])
        let sent = try #require(agenda.items.first { $0.runId == "run-hawaii" })
        #expect(sent.outcome == .sent)
        #expect(sent.cost == nil)
        #expect(sent.duration(now: response.now) == nil)
        #expect(sent.sessionId == "sess-hawaii", "It still opens that session")
        let summary = agenda.summary(on: sentAt, calendar: Self.calendar)
        #expect(summary.done == 1 && summary.running == 0 && summary.needsYou == 0)
        #expect(summary.cost == 0, "The session's lifetime cost is not this day's")

        // Until its dispatch finishes it is starting; a failed dispatch never sent.
        for (status, outcome) in [(AgentScheduleRunStatus.pending, ScheduleCalendarOutcome.starting), (.failed, .didNotStart)] {
            #expect(ScheduleCalendarOutcome.resolve(
                run: ScheduleCalendarRun(id: "r", kind: .due, status: status, createdAt: sentAt, session: session),
                session: nil, sendsIntoExistingSession: true
            ) == outcome)
        }
    }

    @Test("a run status this version does not know decodes and draws neutral")
    func unknownRunStatus() throws {
        let json = Data("""
        {"scheduleId":"nanny917","slotKey":"cron:1","at":1794416400000,
         "run":{"id":"run-skipped","kind":"due","status":"skipped","createdAt":1794416400000}}
        """.utf8)
        var response = try Self.response()
        response.entries = [try JSONDecoder().decode(ScheduleCalendarEntry.self, from: json)]
        let agenda = ScheduleCalendarAgenda(response: response)
        let item = try #require(agenda.items.first)
        #expect(item.outcome == .other)
        #expect(!item.outcome.isFailure && !item.outcome.isClean)
        #expect(agenda.summary(on: item.at, calendar: Self.calendar).isEmpty, "It counts as nothing the app can name")
    }

    @Test("a day with nothing run yet has only what is upcoming to say")
    func upcomingOnlyDay() throws {
        var response = try Self.response()
        response.entries.removeAll { $0.run != nil }
        let summary = ScheduleCalendarAgenda(response: response).summary(on: response.now, calendar: Self.calendar)
        #expect(summary.upcoming == 3)
        #expect(!summary.hasRuns && !summary.isEmpty)
    }

    @Test("every occurrence at the next due minute is next")
    func nextUpcomingTime() throws {
        let response = try Self.response()
        let agenda = ScheduleCalendarAgenda(response: response)
        let next = try #require(agenda.nextUpcomingTime(after: response.now))
        #expect(next == Self.date("2026-11-11T17:00:00Z"))
        #expect(agenda.items.filter { $0.outcome == .upcoming && $0.at == next }.map(\.scheduleId) == ["hawaii01", "nanny917"])
    }

    @Test("a schedule whose later runs the server left out says so from its last listed day on")
    func truncatedSchedules() throws {
        var response = try Self.response()
        // Nanny's occurrences were cut after today's 5 PM.
        let index = try #require(response.schedules.firstIndex { $0.id == "nanny917" })
        response.schedules[index].upcomingTruncated = true
        response.schedules.removeAll { $0.id == "pulse015" }
        let agenda = ScheduleCalendarAgenda(response: response)
        let calendar = Self.calendar
        let day = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: response.now) ?? response.now }
        #expect(agenda.truncatedSchedules(on: day(0), now: response.now, calendar: calendar) == [response.schedules[index].name])
        #expect(agenda.truncatedSchedules(on: day(1), now: response.now, calendar: calendar).count == 1)
        #expect(agenda.truncatedSchedules(on: day(-1), now: response.now, calendar: calendar).isEmpty, "A past day is whole")
    }

    @Test("the day sums each outcome and each run's cost, its subagents' included")
    func summary() throws {
        let response = try Self.response()
        let agenda = ScheduleCalendarAgenda(response: response)
        let summary = agenda.summary(on: response.now, calendar: Self.calendar)
        #expect(summary.done == 1)
        #expect(summary.running == 2, "Running and starting")
        #expect(summary.failed == 2, "Failed and didn't start")
        #expect(summary.needsYou == 1)
        #expect(summary.upcoming == 3, "The two at 9:00 and Nanny's 5 PM, which is tomorrow in UTC but today here")
        // The night run's $4.88 plus its child's $3.10 and grandchild's $0.74.
        #expect(abs(summary.cost - (0.42 + 4.88 + 3.10 + 0.74 + 1.65 + 0.58)) < 0.001)

        let health = agenda.health(on: response.now, calendar: Self.calendar)
        #expect(health.hasFailure && health.needsYou && health.ran && health.hasUpcoming)
    }

    @Test("the app's live session overrides the answer's outcome and cost")
    func liveSessionWins() throws {
        let response = try Self.response()
        let blocked = Self.live(
            "sess-night", .ready, ProgramStatus(state: .blocked, kind: .permission, since: response.now), cost: 5.10
        )
        let agenda = ScheduleCalendarAgenda(response: response, live: ["sess-night": blocked])
        let night = try #require(agenda.items.first { $0.runId == "run-night" })
        #expect(night.outcome == .needsYou(.needsApproval))
        #expect(abs((night.cost ?? 0) - (5.10 + 3.10 + 0.74)) < 0.001)
    }

    @Test("a run costs its session plus every subagent under it, and the live copy patches a subagent too")
    func runCostsItsSubagents() throws {
        let response = try Self.response()
        let night = try #require(ScheduleCalendarAgenda(response: response).items.first { $0.runId == "run-night" })
        #expect(night.subagents.sessions.map(\.id) == ["sess-night-worker", "sess-night-scout"], "Child and grandchild")
        #expect(abs((night.cost ?? 0) - (4.88 + 3.10 + 0.74)) < 0.001)
        #expect(abs(night.subagents.cost - (3.10 + 0.74)) < 0.001)
        #expect(ScheduleCalendarAgenda(response: response).items.first { $0.runId == "run-kypu" }?.subagents.isEmpty == true)

        // The scout settles and spends more before the next fetch.
        let settled = Self.live("sess-night-scout", .stopped, ProgramStatus(state: .done, since: response.now), cost: 1.20)
        let live = try #require(ScheduleCalendarAgenda(response: response, live: ["sess-night-scout": settled])
            .items.first { $0.runId == "run-night" })
        #expect(abs((live.cost ?? 0) - (4.88 + 3.10 + 1.20)) < 0.001)
        #expect(live.subagents.sessions.last?.status == .stopped)
        let strip = SessionThreadStripSummary(descendants: live.subagents.sessions) { SessionListPresentation.classify($0) }
        #expect(!strip.isActive, "No subagent works any more, so the strip draws no dots")
        #expect(strip.text == "2 stopped")
    }

    @Test("a night cluster adds its runs' subagents; a send into an existing session gets none")
    func clusterAndSendsCountSubagentsOnce() throws {
        var response = try Self.response()
        let journal = Self.date("2026-11-11T08:15:00Z")
        let child = try #require(response.entries.first { $0.run?.id == "run-night" }?.run?.session?.descendants.first)
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
                    programStatus: ProgramStatus(state: .done, since: journal.addingTimeInterval(120)), cost: 0.3,
                    descendants: [child]
                )
            )
        ))
        // Yesterday's send into a session whose children the server would not list; one the
        // app decoded anyway still costs the send nothing.
        let sentAt = Self.date("2026-11-10T17:00:00Z")
        response.entries.append(ScheduleCalendarEntry(
            scheduleId: "hawaii01", slotKey: "manual:yesterday", at: sentAt,
            run: ScheduleCalendarRun(
                id: "run-hawaii", kind: .manual, status: .completed, createdAt: sentAt, promptDispatch: "delivered",
                session: ScheduleCalendarSession(id: "sess-hawaii", status: .busy, cost: 40, descendants: [child])
            )
        ))
        let agenda = ScheduleCalendarAgenda(response: response)

        guard case .cluster(let cluster) = agenda.rows(on: response.now, now: response.now, calendar: Self.calendar).night.first else {
            Issue.record("The night opens with its cluster")
            return
        }
        #expect(abs(cluster.totalCost - (0.42 + 0.3 + 3.10)) < 0.001)
        let sent = try #require(agenda.items.first { $0.runId == "run-hawaii" })
        #expect(sent.cost == nil && sent.subagents.isEmpty)
        #expect(agenda.summary(on: sentAt, calendar: Self.calendar).cost == 0)
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
