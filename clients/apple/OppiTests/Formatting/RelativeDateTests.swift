import Foundation
import Testing
@testable import Oppi

@Suite("Relative or short date")
struct RelativeDateTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-06 UTC

    @Test("within a week it reads as a count of minutes, hours, or days")
    func withinAWeek() {
        let threeDays = now.addingTimeInterval(-3 * 86400)
        #expect(threeDays.relativeOrShortDateString(relativeTo: now, calendar: Self.calendar) == "3d ago")
    }

    @Test("past a week it reads as a short date, with the year only when it is not this one")
    func pastAWeek() {
        let thisYear = now.addingTimeInterval(-24 * 86400)
        let lastYear = now.addingTimeInterval(-400 * 86400)
        #expect(thisYear.relativeOrShortDateString(relativeTo: now, calendar: Self.calendar) == "Oct 13")
        #expect(lastYear.relativeOrShortDateString(relativeTo: now, calendar: Self.calendar) == "Oct 2, 2025")
    }
}
