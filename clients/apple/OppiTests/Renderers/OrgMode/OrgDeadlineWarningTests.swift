import Testing
@testable import Oppi

/// A deadline's warning period (`-2d`) turns the badge to the warning tone from
/// the day the period opens until the deadline passes.
@Suite("Org deadline warning")
struct OrgDeadlineWarningTests {
    /// Friday 2026-11-06 12:00 UTC.
    private let clock = OrgNotebookCompatibilityTests.clock

    private func deadline(_ timestamp: String, headingIsDone: Bool = false) -> MarkdownBadge {
        OrgBadges.planning(
            OrgPlanningEntry(kind: .deadline, timestamp: OrgTimestamp(isActive: true, text: timestamp)),
            headingIsDone: headingIsDone,
            clock: clock
        )
    }

    @Test func warnsOnTheFirstDayOfTheWindow() {
        // Today, 11-06, is exactly two days before 11-08.
        let badge = deadline("2026-11-08 Sun -2d")
        #expect(badge.tone == .warning)
        #expect(badge.label.hasSuffix("due soon"))
    }

    @Test func staysQuietTheDayBeforeTheWindowOpens() {
        #expect(deadline("2026-11-09 Mon -2d").tone == .neutral)
    }

    @Test func warnsUntilTheDeadlineThenGoesOverdue() {
        #expect(deadline("2026-11-06 Fri -2d").tone == .warning)
        let passed = deadline("2026-11-05 Thu -2d")
        #expect(passed.tone == .danger)
        #expect(!passed.label.contains("due soon"))
    }

    @Test func warningPeriodUnitsAndAllRepeatsForm() {
        #expect(deadline("2026-11-20 Fri --2w").tone == .warning)
        #expect(deadline("2026-11-21 Sat -2w").tone == .neutral)
        #expect(deadline("2026-12-06 Sun +1w -1m").tone == .warning)
    }

    @Test func aDeadlineWithoutAWarningPeriodDoesNotWarn() {
        #expect(deadline("2026-11-07 Sat").tone == .neutral)
    }

    @Test func aFinishedTaskDoesNotWarn() {
        #expect(deadline("2026-11-08 Sun -2d", headingIsDone: true).tone == .neutral)
    }
}
