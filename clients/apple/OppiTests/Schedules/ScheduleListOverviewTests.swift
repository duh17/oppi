import Foundation
import Testing
@testable import Oppi

/// What the list says of each schedule from the calendar's answer in
/// `protocol/schedule-calendar.json` (now Wed Nov 11 2026, 8:42 AM Pacific): its next run, its
/// latest run, and the group it sits in.
@Suite("Schedule list overview")
struct ScheduleListOverviewTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        return calendar
    }

    private static func response() throws -> ScheduleCalendarResponse {
        struct Fixture: Decodable { let body: ScheduleCalendarResponse }
        return try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("schedule-calendar.json")).body
    }

    @Test("the next run is the first still to come; the last is the latest at or before now")
    func nextAndLast() throws {
        let response = try Self.response()
        let overview = ScheduleListOverview(agenda: ScheduleCalendarAgenda(response: response), now: response.now)
        let nanny = try #require(overview.facts["nanny917"])
        let upcoming = ScheduleCalendarAgenda(response: response).items.filter { $0.scheduleId == "nanny917" && $0.outcome == .upcoming }
        #expect(nanny.next == upcoming.first?.at)
        #expect(nanny.last?.outcome == .starting, "The Run Now still starting is its latest run")
        let digest = try #require(overview.facts["digest07"])
        #expect(digest.last?.outcome == .failed)
        #expect(digest.last?.cost == 1.65)
        #expect(digest.next == nil, "Nothing of the digest's is still to come in the range")
    }

    @Test(arguments: [
        (0.25, ScheduleListOverview.Group.today),
        (15.0, .today),
        (16.5, .tomorrow),
        (24 * 2.0, .thisWeek),
        (24 * 7.5, .later),
    ])
    func groupsByDayOfNextRun(hoursAhead: Double, expected: ScheduleListOverview.Group) throws {
        let now = try Self.response().now
        #expect(ScheduleListOverview.group(next: now.addingTimeInterval(hoursAhead * 3_600), now: now, calendar: Self.calendar) == expected)
    }

    @Test("groups run in order, each by next run, then by name; no next run is Not Scheduled")
    func ordering() throws {
        let response = try Self.response()
        let now = response.now
        let overview = ScheduleListOverview(agenda: ScheduleCalendarAgenda(response: response), now: now)
        let ids = response.schedules.map { (id: $0.id, name: $0.name) }
        let grouped = overview.grouped(ids, now: now, calendar: Self.calendar)
        #expect(grouped.map(\.0) == grouped.map(\.0).sorted())
        let notScheduled = grouped.first { $0.0 == .notScheduled }?.1 ?? []
        #expect(notScheduled.contains("digest07"))
        for (_, members) in grouped where members.count > 1 {
            let nexts = members.compactMap { overview.facts[$0]?.next }
            #expect(nexts == nexts.sorted())
        }
    }
}
