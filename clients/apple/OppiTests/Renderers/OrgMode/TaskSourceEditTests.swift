import Foundation
import Testing
@testable import Oppi

/// The reader's task edits rewrite only the lines they own. Each case compares
/// the whole document, so a changed byte anywhere else fails it.
@Suite("Task source edits")
struct TaskSourceEditTests {
    private typealias Edit = TaskSourceEdit

    /// Friday 6 November 2026, 14:00 in Los Angeles.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        return calendar
    }

    private static var now: Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 0)) ?? Date()
    }

    private func lines(_ lines: String...) -> String { lines.joined(separator: "\n") }

    // MARK: Checkbox

    @Test func orgToggleWritesCapitalXAndBack() {
        let source = lines("* Plan", "- [ ] one", "- [X] two", "- [-] three")
        #expect(Edit.toggleCheckbox(in: source, line: 2, dialect: .org) == lines("* Plan", "- [X] one", "- [X] two", "- [-] three"))
        #expect(Edit.toggleCheckbox(in: source, line: 3, dialect: .org) == lines("* Plan", "- [ ] one", "- [ ] two", "- [-] three"))
        #expect(Edit.toggleCheckbox(in: source, line: 4, dialect: .org) == lines("* Plan", "- [ ] one", "- [X] two", "- [X] three"))
    }

    @Test func markdownToggleWritesLowercaseX() {
        let source = lines("- [ ] one", "* [x] two", "1. [ ] three", "  - [X] four")
        #expect(Edit.toggleCheckbox(in: source, line: 1, dialect: .markdown) == lines("- [x] one", "* [x] two", "1. [ ] three", "  - [X] four"))
        #expect(Edit.toggleCheckbox(in: source, line: 2, dialect: .markdown) == lines("- [ ] one", "* [ ] two", "1. [ ] three", "  - [X] four"))
        #expect(Edit.toggleCheckbox(in: source, line: 3, dialect: .markdown) == lines("- [ ] one", "* [x] two", "1. [x] three", "  - [X] four"))
        #expect(Edit.toggleCheckbox(in: source, line: 4, dialect: .markdown) == lines("- [ ] one", "* [x] two", "1. [ ] three", "  - [ ] four"))
    }

    @Test func markdownToggleFindsTheBoxInsideABlockQuote() {
        #expect(Edit.toggleCheckbox(in: "> - [ ] quoted\n", line: 1, dialect: .markdown) == "> - [x] quoted\n")
    }

    @Test func toggleLeavesEveryOtherByteAlone() {
        // CRLF lines, odd spacing, a trailing newline and a final line without one.
        let source = "# T  \r\n\r\n-   [ ]   spaced \t\r\n- [x] done\r\n\r\ntail"
        let toggled = Edit.toggleCheckbox(in: source, line: 3, dialect: .markdown)
        #expect(toggled == "# T  \r\n\r\n-   [x]   spaced \t\r\n- [x] done\r\n\r\ntail")
    }

    @Test func toggleRefusesALineThatIsNotATask() {
        let source = lines("* Heading", "- plain item", "text [ ] here", "- [ ]no space after box")
        for line in 1...4 { #expect(Edit.toggleCheckbox(in: source, line: line, dialect: .org) == nil) }
        #expect(Edit.toggleCheckbox(in: source, line: 9, dialect: .org) == nil)
        #expect(Edit.toggleCheckbox(in: source, line: 0, dialect: .org) == nil)
    }

    @Test func tasksInsideCodeAreNotCountedByACookie() {
        let source = lines(
            "## Plan [0/1]",
            "- [ ] real",
            "```",
            "- [x] sample",
            "- [x] sample",
            "```"
        )
        #expect(Edit.toggleCheckbox(in: source, line: 2, dialect: .markdown)?.hasPrefix("## Plan [1/1]\n- [x] real\n```") == true)
    }

    // MARK: Cookies

    @Test func parentItemCookieCountsItsDirectChildren() {
        let source = lines(
            "* Plan",
            "- [ ] parent [1/3]",
            "  - [X] a",
            "  - [ ] b",
            "    - [ ] nested",
            "  - [ ] c",
            "- [ ] sibling [0/0]"
        )
        // `b` is checked: 2 of 3 direct children; its own nested item is not counted.
        #expect(Edit.toggleCheckbox(in: source, line: 4, dialect: .org) == lines(
            "* Plan",
            "- [ ] parent [2/3]",
            "  - [X] a",
            "  - [X] b",
            "    - [ ] nested",
            "  - [ ] c",
            "- [ ] sibling [0/0]"
        ))
        // The nested item belongs to `b`, which has no cookie: nothing else moves.
        #expect(Edit.toggleCheckbox(in: source, line: 5, dialect: .org) == lines(
            "* Plan",
            "- [ ] parent [1/3]",
            "  - [X] a",
            "  - [ ] b",
            "    - [X] nested",
            "  - [ ] c",
            "- [ ] sibling [0/0]"
        ))
    }

    /// Whole percent, rounded down, as Org counts it.
    @Test func percentCookieIsRecountedAsAPercent() {
        let source = lines("* Plan [%]", "- [X] a", "- [ ] b", "- [ ] c")
        #expect(Edit.toggleCheckbox(in: source, line: 3, dialect: .org) == lines("* Plan [66%]", "- [X] a", "- [X] b", "- [ ] c"))
        let full = lines("* Plan [40%]", "- [X] a", "- [ ] b")
        #expect(Edit.toggleCheckbox(in: full, line: 3, dialect: .org) == lines("* Plan [100%]", "- [X] a", "- [X] b"))
    }

    @Test func headingCookieCountsItsTopLevelCheckboxesUpToTheNextHeading() {
        let source = lines(
            "* A [0/2]",
            "- [ ] one",
            "- [ ] two",
            "  - [ ] sub",
            "* B [0/1]",
            "- [ ] other"
        )
        #expect(Edit.toggleCheckbox(in: source, line: 2, dialect: .org) == lines(
            "* A [1/2]",
            "- [X] one",
            "- [ ] two",
            "  - [ ] sub",
            "* B [0/1]",
            "- [ ] other"
        ))
    }

    @Test func aHeadingCookieThatCountsTodoChildrenIsLeftAlone() {
        let source = lines("#+TODO: TODO | DONE", "* TODO Project [0/1]", "- [ ] note", "** TODO Task", "- [ ] item")
        let toggled = Edit.toggleCheckbox(in: source, line: 3, dialect: .org)
        #expect(toggled == lines("#+TODO: TODO | DONE", "* TODO Project [0/1]", "- [X] note", "** TODO Task", "- [ ] item"))
    }

    @Test func markdownHeadingAndItemCookiesUpdateToo() {
        let source = lines("## Plan [0/2]", "- [ ] a", "- [ ] b")
        #expect(Edit.toggleCheckbox(in: source, line: 2, dialect: .markdown) == lines("## Plan [1/2]", "- [x] a", "- [ ] b"))
    }

    @Test func cookieShapedTextThatIsNotACookieIsLeftAlone() {
        let source = lines("* Notes =[0/9]= [text](u) [[1/2]] [0/2]", "- [ ] a", "- [ ] b")
        // The first real cookie is the last one: code, a link label and an Org link do not count.
        #expect(Edit.toggleCheckbox(in: source, line: 2, dialect: .org) == lines("* Notes =[0/9]= [text](u) [[1/2]] [1/2]", "- [X] a", "- [ ] b"))
    }

    // MARK: State

    private let keywords = OrgTodoKeywords(active: ["TODO", "NEXT", "WAIT"], done: ["DONE", "CANCELLED"])

    private func setState(_ source: String, line: Int = 1, to keyword: String?) -> String? {
        Edit.setState(in: source, headingLine: line, to: keyword, keywords: keywords, now: Self.now, calendar: Self.calendar)
    }

    @Test func changingBetweenOpenStatesTouchesOnlyTheHeading() {
        #expect(setState("* TODO [#A] Ship it :oppi:\nbody", to: "NEXT") == "* NEXT [#A] Ship it :oppi:\nbody")
        #expect(setState("** NEXT Ship", to: "WAIT") == "** WAIT Ship")
    }

    @Test func noStateRemovesTheKeywordAndAddingOneInsertsItBeforeThePriority() {
        #expect(setState("* TODO [#A] Ship it", to: nil) == "* [#A] Ship it")
        #expect(setState("* [#A] Ship it", to: "NEXT") == "* NEXT [#A] Ship it")
        #expect(setState("* Plain title", to: "TODO") == "* TODO Plain title")
        #expect(setState("* TODO", to: "NEXT") == "* NEXT")
    }

    @Test func movingIntoDoneWritesClosedOnANewPlanningLine() {
        let source = "* TODO Ship\nbody\n* Next"
        #expect(setState(source, to: "DONE") == "* DONE Ship\nCLOSED: [2026-11-06 Fri 14:00]\nbody\n* Next")
    }

    @Test func movingIntoDoneKeepsTheRestOfTheExistingPlanningLine() {
        let source = "* NEXT Ship\nSCHEDULED: <2026-11-11 Wed +1w> DEADLINE: <2026-11-13 Fri>\nbody"
        #expect(setState(source, to: "DONE") == "* DONE Ship\nCLOSED: [2026-11-06 Fri 14:00] SCHEDULED: <2026-11-11 Wed +1w> DEADLINE: <2026-11-13 Fri>\nbody")
    }

    @Test func movingOutOfDoneRemovesClosedAndKeepsTheRest() {
        let source = "* DONE Ship\nCLOSED: [2026-11-06 Fri 14:00] SCHEDULED: <2026-11-11 Wed +1w>\nbody"
        #expect(setState(source, to: "TODO") == "* TODO Ship\nSCHEDULED: <2026-11-11 Wed +1w>\nbody")
        // A line that held only the CLOSED entry goes away with it.
        let alone = "* DONE Ship\nCLOSED: [2026-11-06 Fri 14:00]\nbody"
        #expect(setState(alone, to: nil) == "* Ship\nbody")
        // CLOSED in the middle or at the end closes up the gap.
        let middle = "* DONE Ship\nSCHEDULED: <2026-11-11 Wed> CLOSED: [2026-11-06 Fri 14:00] DEADLINE: <2026-11-13 Fri>"
        #expect(setState(middle, to: "TODO") == "* TODO Ship\nSCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-13 Fri>")
        let last = "* DONE Ship\nSCHEDULED: <2026-11-11 Wed> CLOSED: [2026-11-06 Fri 14:00]"
        #expect(setState(last, to: "TODO") == "* TODO Ship\nSCHEDULED: <2026-11-11 Wed>")
    }

    @Test func movingBetweenDoneStatesKeepsTheOriginalClosedStamp() {
        let source = "* DONE Ship\nCLOSED: [2026-11-01 Sun 09:00]"
        #expect(setState(source, to: "CANCELLED") == "* CANCELLED Ship\nCLOSED: [2026-11-01 Sun 09:00]")
    }

    @Test func aPlanningLookalikeIsNotAPlanningLine() {
        // Prose that starts like a planning line stays prose, so CLOSED gets its own line above it.
        let source = "* TODO Ship\nCLOSED: yesterday, I think"
        #expect(setState(source, to: "DONE") == "* DONE Ship\nCLOSED: [2026-11-06 Fri 14:00]\nCLOSED: yesterday, I think")
    }

    @Test func stateEditsKeepCarriageReturns() {
        let source = "* TODO Ship\r\nbody\r\n"
        #expect(setState(source, to: "DONE") == "* DONE Ship\r\nCLOSED: [2026-11-06 Fri 14:00]\r\nbody\r\n")
    }

    @Test func stateReadsAndRefusesNonHeadings() {
        let source = "* NEXT Ship\n- [ ] task"
        #expect(Edit.state(in: source, headingLine: 1, keywords: keywords) == "NEXT")
        #expect(Edit.state(in: source, headingLine: 2, keywords: keywords) == nil)
        #expect(setState(source, line: 2, to: "DONE") == nil)
        #expect(setState(source, to: "TO DO") == nil)
    }

    // MARK: Dates

    private func date(_ year: Int, _ month: Int, _ day: Int, _ time: (Int, Int)? = nil) -> Edit.OrgDateValue {
        Edit.OrgDateValue(year: year, month: month, day: day, time: time.map { ($0.0, $0.1) })
    }

    @Test func weekdaysAreWrittenInEnglishForAnyDate() {
        #expect(date(2026, 11, 11).orgText == "2026-11-11 Wed")
        #expect(date(2026, 1, 1).orgText == "2026-01-01 Thu")
        #expect(date(2024, 2, 29).orgText == "2024-02-29 Thu")
        #expect(date(2000, 3, 1).orgText == "2000-03-01 Wed")
        #expect(date(2026, 11, 8, (9, 5)).orgText == "2026-11-08 Sun 09:05")
    }

    @Test func settingADateOnAHeadingWithoutAPlanningLineCreatesOne() {
        let source = "* TODO Ship\nbody"
        #expect(Edit.setPlanningDate(in: source, headingLine: 1, kind: .scheduled, to: date(2026, 11, 11)) == "* TODO Ship\nSCHEDULED: <2026-11-11 Wed>\nbody")
        #expect(Edit.setPlanningDate(in: source, headingLine: 1, kind: .deadline, to: date(2026, 11, 13, (17, 30))) == "* TODO Ship\nDEADLINE: <2026-11-13 Fri 17:30>\nbody")
    }

    @Test func aSecondDateJoinsTheExistingPlanningLine() {
        let source = "* TODO Ship\nSCHEDULED: <2026-11-11 Wed>\nbody"
        #expect(Edit.setPlanningDate(in: source, headingLine: 1, kind: .deadline, to: date(2026, 11, 13)) == "* TODO Ship\nSCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-13 Fri>\nbody")
    }

    @Test func changingADateKeepsTheRepeaterAndWarning() {
        let source = "* TODO Ship\nSCHEDULED: <2026-11-11 Wed 09:00 +1w -2d> DEADLINE: <2026-11-13 Fri>"
        #expect(Edit.setPlanningDate(in: source, headingLine: 1, kind: .scheduled, to: date(2026, 11, 18, (10, 15))) == "* TODO Ship\nSCHEDULED: <2026-11-18 Wed 10:15 +1w -2d> DEADLINE: <2026-11-13 Fri>")
        // Dropping the time keeps the repeater too.
        #expect(Edit.setPlanningDate(in: source, headingLine: 1, kind: .scheduled, to: date(2026, 11, 18)) == "* TODO Ship\nSCHEDULED: <2026-11-18 Wed +1w -2d> DEADLINE: <2026-11-13 Fri>")
        // Adding a time to a date that had none.
        let dateOnly = "* TODO Ship\nDEADLINE: <2026-11-13 Fri .+1d>"
        #expect(Edit.setPlanningDate(in: dateOnly, headingLine: 1, kind: .deadline, to: date(2026, 11, 13, (8, 0))) == "* TODO Ship\nDEADLINE: <2026-11-13 Fri 08:00 .+1d>")
    }

    @Test func clearingADateRemovesOnlyThatEntry() {
        let source = "* TODO Ship\nSCHEDULED: <2026-11-11 Wed +1w> DEADLINE: <2026-11-13 Fri>\nbody"
        #expect(Edit.setPlanningDate(in: source, headingLine: 1, kind: .scheduled, to: nil) == "* TODO Ship\nDEADLINE: <2026-11-13 Fri>\nbody")
        #expect(Edit.setPlanningDate(in: source, headingLine: 1, kind: .deadline, to: nil) == "* TODO Ship\nSCHEDULED: <2026-11-11 Wed +1w>\nbody")
        // The last entry takes its line with it.
        let alone = "* TODO Ship\nDEADLINE: <2026-11-13 Fri>\nbody"
        #expect(Edit.setPlanningDate(in: alone, headingLine: 1, kind: .deadline, to: nil) == "* TODO Ship\nbody")
        // Clearing a date the heading does not have changes nothing.
        #expect(Edit.setPlanningDate(in: "* TODO Ship\nbody", headingLine: 1, kind: .deadline, to: nil) == "* TODO Ship\nbody")
    }

    @Test func clearingADateKeepsAClosedStamp() {
        let source = "* DONE Ship\nCLOSED: [2026-11-06 Fri 14:00] SCHEDULED: <2026-11-11 Wed>"
        #expect(Edit.setPlanningDate(in: source, headingLine: 1, kind: .scheduled, to: nil) == "* DONE Ship\nCLOSED: [2026-11-06 Fri 14:00]")
    }

    @Test func dateEditsRefuseNonHeadingsAndClosed() {
        #expect(Edit.setPlanningDate(in: "- [ ] task", headingLine: 1, kind: .scheduled, to: date(2026, 11, 11)) == nil)
        #expect(Edit.setPlanningDate(in: "* Ship", headingLine: 1, kind: .closed, to: date(2026, 11, 11)) == nil)
    }

    @Test func planningDateReadsTheStampsDateAndTime() {
        let source = "* TODO Ship\nSCHEDULED: <2026-11-11 Wed 09:30 +1w> DEADLINE: <2026-11-13 Fri>"
        #expect(Edit.planningDate(in: source, headingLine: 1, kind: .scheduled) == date(2026, 11, 11, (9, 30)))
        #expect(Edit.planningDate(in: source, headingLine: 1, kind: .deadline) == date(2026, 11, 13))
        #expect(Edit.planningDate(in: "* TODO Ship", headingLine: 1, kind: .deadline) == nil)
    }
}
