import Foundation
import Testing
@testable import Oppi

@Suite("Workspace stopped session expansion policy")
struct WorkspaceStoppedSessionExpansionPolicyTests {
    @Test("Only the current calendar day expands by default")
    func currentDayOnly() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))

        let now = try #require(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 7,
                day: 14,
                hour: 13,
                minute: 30
            ))
        )
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = try #require(
            calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfToday)
        )
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: startOfToday))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: startOfToday))

        #expect(
            WorkspaceStoppedSessionExpansionPolicy.isDayExpandedByDefault(
                startOfToday,
                now: now,
                calendar: calendar
            )
        )
        #expect(
            WorkspaceStoppedSessionExpansionPolicy.isDayExpandedByDefault(
                endOfToday,
                now: now,
                calendar: calendar
            )
        )
        #expect(
            !WorkspaceStoppedSessionExpansionPolicy.isDayExpandedByDefault(
                yesterday,
                now: now,
                calendar: calendar
            )
        )
        #expect(
            !WorkspaceStoppedSessionExpansionPolicy.isDayExpandedByDefault(
                tomorrow,
                now: now,
                calendar: calendar
            )
        )
    }

    @Test("Spring-forward activity stays in today's expanded bucket")
    func springForwardDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))

        let noonAfterSpringForward = try #require(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 3,
                day: 8,
                hour: 12
            ))
        )
        let bucket = WorkspaceStoppedSessionExpansionPolicy.dayBucket(
            for: noonAfterSpringForward,
            calendar: calendar
        )

        #expect(calendar.component(.hour, from: bucket) == 0)
        #expect(
            WorkspaceStoppedSessionExpansionPolicy.isDayExpandedByDefault(
                bucket,
                now: noonAfterSpringForward,
                calendar: calendar
            )
        )
    }
}
