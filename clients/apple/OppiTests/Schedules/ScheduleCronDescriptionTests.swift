import Foundation
import Testing
@testable import Oppi

/// Every cron the server accepts reads as days and times, never as its syntax.
@Suite("Schedule cron description")
struct ScheduleCronDescriptionTests {
    private func describe(_ expression: String, locale: String = "en_US") -> ScheduleCronDescription? {
        ScheduleCronDescription(
            expression: expression,
            timeZone: TimeZone(identifier: "America/Los_Angeles") ?? .gmt,
            locale: Locale(identifier: locale)
        )
    }

    private func text(_ expression: String, locale: String = "en_US") -> String? {
        describe(expression, locale: locale)?.text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test(arguments: [
        ("30 8 * * 1-5", "Weekdays · 8:30 AM"),
        ("0 10 * * 0,6", "Weekends · 10:00 AM"),
        ("0 10 * * 6,7", "Weekends · 10:00 AM"),
        ("0 9,17 * * *", "Every day · 9:00 AM & 5:00 PM"),
        ("0 8 * * 0", "Sundays · 8:00 AM"),
        ("0 9 * * 1,3,5", "Mon, Wed, Fri · 9:00 AM"),
        ("0 8 1 * *", "Monthly on the 1st · 8:00 AM"),
        ("0 8 1,15 * *", "Monthly on the 1st & 15th · 8:00 AM"),
        ("0 9 25 12 *", "Yearly on Dec 25 · 9:00 AM"),
        ("0 9 1 1,7 *", "Monthly on the 1st in Jan, Jul · 9:00 AM"),
        ("0 6 * * * ", "Every day · 6:00 AM"),
        ("0 0 6 * * *", "Every day · 6:00 AM"),
        ("*/15 * * * *", "Every day · every 15 minutes"),
        ("15 * * * *", "Every day · every hour at :15"),
        ("0 */2 * * *", "Every day · every 2 hours, 12:00 AM – 10:00 PM"),
        ("0 9-17 * * 1-5", "Weekdays · every hour, 9:00 AM – 5:00 PM"),
        ("*/30 9-17 * * *", "Every day · every 30 minutes, 9:00 AM – 5:00 PM"),
        ("0 0 */2 * *", "Every other day · 12:00 AM"),
        ("0 8 1 * 1", "Monthly on the 1st or Mondays · 8:00 AM"),
        ("* * * * *", "Every day · every minute"),
        ("0,30 9 * * *", "Every day · 9:00 AM & 9:30 AM"),
    ])
    func describesWhatTheServerAccepts(expression: String, expected: String) {
        #expect(text(expression) == expected)
    }

    @Test("an expression the server would refuse has no description", arguments: [
        "", "0 8 * *", "60 8 * * *", "0 24 * * *", "0 8 0 * *", "0 8 * 13 *", "0 8 * * 8", "a b c d e", "0 9-5 * * *", "*/0 * * * *",
    ])
    func refusesWhatTheServerRefuses(expression: String) {
        #expect(describe(expression) == nil)
    }

    @Test("a 24-hour locale keeps its own clock")
    func followsTheLocaleClock() {
        #expect(text("30 17 * * 1-5", locale: "en_GB") == "Weekdays · 17:30")
    }

    @Test("only a run on at least five days a week is a routine")
    func routines() {
        #expect(describe("0 9 * * *")?.runsMostDays == true)
        #expect(describe("30 8 * * 1-5")?.runsMostDays == true)
        #expect(describe("*/15 * * * *")?.runsMostDays == true)
        #expect(describe("0 8 * * 0")?.runsMostDays == false)
        #expect(describe("0 8 1 * *")?.runsMostDays == false)
        #expect(describe("0 0 */2 * *")?.runsMostDays == false)
        #expect(describe("0 9 * 12 *")?.runsMostDays == false)
    }
}
