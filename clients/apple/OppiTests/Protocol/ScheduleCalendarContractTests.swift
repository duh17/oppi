import Foundation
import Testing
@testable import Oppi

/// `protocol/schedule-calendar.json`: one `GET /schedules/calendar` answer. Server
/// `schedule-calendar-fixtures.test.ts` holds the committed bytes to the protocol type;
/// this side decodes every entry shape from the same bytes.
@Suite("Schedule calendar contract")
struct ScheduleCalendarContractTests {
    private struct Fixture: Decodable { let body: ScheduleCalendarResponse }

    private static func body() throws -> ScheduleCalendarResponse {
        try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("schedule-calendar.json")).body
    }

    @Test func decodesTheRangeSchedulesAndEntries() throws {
        let body = try Self.body()
        #expect(body.to.timeIntervalSince(body.from) == 86_400)
        #expect(body.schedules.count == 8)
        #expect(body.entries.count == 9)
        #expect(Set(body.entries.map(\.key)).count == body.entries.count, "One entry per schedule and slot")
    }

    @Test func readsAScheduleAsDispatchWouldRunIt() throws {
        let night = try #require(try Self.body().schedules.first { $0.id == "night330" })
        #expect(night.action.agentId == "night-agent")
        #expect(night.model == "anthropic/claude-opus-5-5")
        #expect(night.upcomingTruncated == false)
        let pulse = try #require(try Self.body().schedules.first { $0.id == "pulse015" })
        #expect(pulse.upcomingTruncated)
        #expect(pulse.trigger == .every(intervalMs: 300_000, timeZone: "America/Los_Angeles"))
        let hawaii = try #require(try Self.body().schedules.first { $0.id == "hawaii01" })
        #expect(hawaii.action.type == .existingSession)
        #expect(hawaii.action.sessionId == "sess-hawaii")
    }

    @Test func readsARunAndItsSession() throws {
        let entries = try Self.body().entries
        let jobs = try #require(entries.first { $0.run?.id == "run-jobs" }?.run)
        #expect(jobs.kind == .due)
        #expect(jobs.status == .completed)
        #expect(jobs.promptDispatch == "delivered")
        let session = try #require(jobs.session)
        #expect(session.status == .ready)
        #expect(session.programStatus?.state == .blocked)
        #expect(session.programStatus?.kind == .question)
        #expect(session.cost == 0.58)
        #expect(session.settledAt == nil)

        let failed = try #require(entries.first { $0.run?.id == "run-mirror" }?.run)
        #expect(failed.status == .failed)
        #expect(failed.error == "approval_required_noninteractive: bash git push")
        #expect(failed.session == nil)

        let manual = try #require(entries.first { $0.run?.id == "run-nanny-manual" })
        #expect(manual.slotKey == "manual:req-7f3a")
        #expect(manual.run?.kind == .manual)
        #expect(manual.run?.startedAt == nil)
    }

    @Test func anUpcomingOccurrenceHasNoRun() throws {
        let upcoming = try Self.body().entries.filter { $0.run == nil }
        #expect(upcoming.map(\.scheduleId) == ["hawaii01", "nanny917", "nanny917"])
        #expect(upcoming.first?.slotKey.hasPrefix("at:") == true)
    }
}
