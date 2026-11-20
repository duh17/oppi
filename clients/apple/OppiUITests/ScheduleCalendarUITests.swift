import XCTest

/// Schedules in the real workspace shell over a fixture server's five weeks of runs
/// (`SCREENSHOT_SCREEN=schedules-calendar`, clock posed at 8:42 AM): it opens on the
/// Day, the List is one tap away and says each schedule's timing, next and last run, a
/// past run opens its session, an upcoming run's menu offers only what the server can do,
/// a swipe pages days, Month marks the month's exceptions and pages by swipe, and the iPad's Week grid shows
/// the week's runs.
///
/// The chosen view outlives a test in a reused launch, so each test picks the view it
/// starts from.
@MainActor
final class ScheduleCalendarUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Schedule calendar tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testOpensOnCalendarSwitchesToListAndOpensARunsSession() {
        launch()
        openSchedules()

        let mode = app.segmentedControls["schedules.mode"]
        XCTAssertTrue(mode.waitUntilExists(timeout: 10), "Schedules shows its view switch")
        mode.buttons[dayTitle].tap()
        let summary = app.descendants(matching: .any)["schedules.calendar.summary"]
        XCTAssertTrue(summary.waitUntilExists(timeout: 10), "The calendar shows today's summary")
        XCTAssertTrue(summary.label.contains("1 failed"), "Today's summary counts the failed digest: \(summary.label)")
        XCTAssertTrue(app.buttons["schedules.calendar.today"].exists, "Calendar's bar offers Today")
        attachScreenshot("calendar")

        mode.buttons["List"].tap()
        XCTAssertTrue(
            app.buttons["schedules.row.u1C2kXLz"].waitUntilExists(timeout: 10),
            "The List shows the schedules' cards"
        )
        XCTAssertTrue(app.buttons["schedules.filter"].exists, "The List keeps its status filter")
        capture("list")

        mode.buttons[dayTitle].tap()
        let digest = pastRun(named: "Daily personalized HN + X digest")
        XCTAssertTrue(digest.waitUntilExists(timeout: 10), "Today's failed digest is on the calendar")
        XCTAssertTrue(digest.label.contains("Failed"), "The run says how it ended: \(digest.label)")
        XCTAssertTrue(digest.label.contains("Provider returned 529"), "The run says why it failed: \(digest.label)")
        let jobs = pastRun(named: "Weekday job hunt")
        XCTAssertTrue(
            jobs.label.contains("Apply to these three?"),
            "A run waiting on you says what it asks: \(jobs.label)"
        )
        digest.tap()
        XCTAssertTrue(
            app.buttons["chat.toolbar.back"].waitUntilExists(timeout: 10),
            "Tapping a past run opens its session"
        )
        assertRunning()
    }

    func testUpcomingRunMenuOffersOnlyWhatTheServerCanDo() {
        launch()
        openSchedules()
        app.segmentedControls["schedules.mode"].buttons[dayTitle].tap()
        let nanny = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.entry.9Bq6VFNy.' AND label CONTAINS '9:00' AND label CONTAINS ' minutes'")).firstMatch
        // The minute it counts down from follows the posed clock's seconds: 17 or 18.
        XCTAssertTrue(nanny.waitUntilExists(timeout: 10), "The 9:00 Nanny run counts down")
        nanny.press(forDuration: 1.0)
        for title in ["Run Now", "Pause Schedule", "Show Schedule", "Last Run's Session"] {
            XCTAssertTrue(menuButton(title).waitUntilExists(timeout: 5), "The menu offers \(title)")
        }
        XCTAssertFalse(menuButton("Skip").exists, "No Skip: the server has no way to skip a run")
        attachScreenshot("menu")
    }

    /// A Night shift's subagents: a strip under the run counts them with live dots while some
    /// work, folds into the overnight row's total once the night is done, and opens the run's
    /// thread in All Sessions.
    func testRunSubagentsStripCountsThemAndOpensTheRunsThread() {
        launch()
        openSchedules()
        app.segmentedControls["schedules.mode"].buttons[dayTitle].tap()

        // Today opens at now; tonight's running Night shift is above it.
        let list = app.collectionViews["schedules.calendar.list"]
        let tonight = subagentsStrip(of: "u1C2kXLz")
        for _ in 0..<4 where !(tonight.exists && tonight.isHittable) { list.swipeDown() }
        XCTAssertTrue(waitFor(tonight.exists && tonight.isHittable, timeout: 10), "The running Night shift has its subagents strip")
        XCTAssertTrue(tonight.label.hasPrefix("14 subagents"), "The strip counts the run's subagents: \(tonight.label)")
        XCTAssertTrue(tonight.label.contains("2 working"), "The strip says how many still work: \(tonight.label)")
        attachScreenshot("today-night")

        // Yesterday's night is done: its four runs fold into one row, and opening it shows
        // the Night shift with all 26 of its subagents. A swipe reaches yesterday on any
        // weekday; on the week's first day it is in last week's strip.
        showDay(offset: -1)
        let cluster = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.cluster.'")).firstMatch
        XCTAssertTrue(cluster.waitUntilExists(timeout: 10), "Yesterday's clean night folds into one row")
        XCTAssertTrue(cluster.label.contains("4 runs, all done"), "The night's four runs fold: \(cluster.label)")
        cluster.tap()
        let lastNight = subagentsStrip(of: "u1C2kXLz")
        XCTAssertTrue(lastNight.waitUntilExists(timeout: 10), "The opened night shows the Night shift's subagents")
        XCTAssertTrue(lastNight.label.hasPrefix("26 subagents, 26 stopped"), "A finished night's subagents are all stopped: \(lastNight.label)")
        attachScreenshot("yesterday-overnight")

        lastNight.tap()
        let thread = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'thread.nav.sess-u1C2kXLz-'")).firstMatch
        XCTAssertTrue(thread.waitUntilExists(timeout: 10), "The strip opens the run's thread in All Sessions")
        attachScreenshot("thread")
        assertRunning()
    }

    /// A card says when the schedule runs in words, when it runs next, how its latest run
    /// went and cost, and who runs it on which model; active cards group by next run.
    func testListCardsSayTimingNextAndLastRun() {
        launch()
        openSchedules()
        let listSegment = app.segmentedControls["schedules.mode"].buttons["List"]
        listSegment.tap()
        XCTAssertTrue(waitFor(listSegment.isSelected, timeout: 5), "The switch shows the List")

        // Nanny runs at 9:00 and 5:00: next at 9:00 today, the top group.
        let nanny = app.buttons["schedules.row.9Bq6VFNy"]
        XCTAssertTrue(nanny.waitUntilExists(timeout: 10), "Nanny has its card")
        XCTAssertTrue(nanny.label.contains("Every day · 9:00"), "Nanny's timing: \(nanny.label)")
        XCTAssertTrue(nanny.label.contains("next in 1"), "Nanny's next run counts down: \(nanny.label)")
        XCTAssertTrue(nanny.label.contains("nanny workspace"), "A schedule with no Agent names its workspace: \(nanny.label)")
        let today = app.staticTexts["Today"]
        let tomorrow = app.staticTexts["Tomorrow"]
        XCTAssertTrue(today.exists && tomorrow.exists, "Cards group by when they run next")
        XCTAssertLessThan(today.frame.minY, nanny.frame.minY, "Nanny sits under Today")
        XCTAssertLessThan(nanny.frame.minY, tomorrow.frame.minY, "Today comes before Tomorrow")
        capture("list")

        // Night shift's latest run is the one still going.
        let night = app.buttons["schedules.row.u1C2kXLz"]
        scrollList(to: night)
        XCTAssertTrue(night.label.contains("last run Running"), "Night shift is still running: \(night.label)")

        let jobs = app.buttons["schedules.row.6xbwGEM4"]
        scrollList(to: jobs)
        XCTAssertTrue(jobs.label.contains("Weekdays · 8:30"), "A weekday cron reads as words: \(jobs.label)")
        XCTAssertTrue(jobs.label.contains("last run Needs you"), "The card says how its latest run went: \(jobs.label)")
        XCTAssertTrue(jobs.label.contains("$0.58"), "The card says what its latest run cost: \(jobs.label)")
        XCTAssertTrue(jobs.label.contains("Job scout Agent"), "The card names the saved Agent that runs it: \(jobs.label)")
        capture("list-scrolled")
        app.segmentedControls["schedules.mode"].buttons[dayTitle].tap()
    }

    /// A horizontal swipe across the day pages to the next day and back, and the week strip
    /// follows the selection.
    func testSwipingTheDayPagesDays() {
        launch()
        openSchedules()
        app.segmentedControls["schedules.mode"].buttons[dayTitle].tap()
        let list = app.collectionViews["schedules.calendar.list"]
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "The Day agenda shows")
        let today = dayButton(offset: 0)
        let tomorrow = dayButton(offset: 1)
        XCTAssertTrue(waitFor(today.isSelected, timeout: 10), "The Day opens on today")
        // The test and the app share the simulator's calendar, so they agree on the week.
        let calendar = Calendar.current
        let now = Date()
        let sameWeek = calendar.isDate(
            calendar.date(byAdding: .day, value: 1, to: now) ?? now, equalTo: now, toGranularity: .weekOfYear
        )

        list.swipeLeft()
        XCTAssertTrue(waitFor(tomorrow.isSelected, timeout: 5), "A swipe left shows tomorrow in the strip")
        if sameWeek {
            XCTAssertTrue(today.exists && !today.isSelected, "Today stays in the strip, no longer selected")
        } else {
            XCTAssertFalse(today.exists, "On the week's last day the strip turns to next week")
        }
        let upcoming = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.entry.9Bq6VFNy.'")).firstMatch
        XCTAssertTrue(upcoming.waitUntilExists(timeout: 5), "Tomorrow's runs show")
        capture("day-swiped")

        list.swipeRight()
        XCTAssertTrue(waitFor(today.isSelected, timeout: 5), "A swipe right comes back to today")
        XCTAssertTrue(pastRun(named: "Weekday job hunt").waitUntilExists(timeout: 5), "Today's runs are back")

        // Tapping a neighbour in this week's strip selects it.
        let neighbour = dayButton(offset: sameWeek ? 1 : -1)
        neighbour.tap()
        XCTAssertTrue(waitFor(neighbour.isSelected, timeout: 5), "Tapping a day in the strip selects it")
    }

    /// Month marks only the exceptions. On iPad it shows the selected day's agenda, whose
    /// title opens the Day; on a phone the Day's month title opens it and a date opens that day.
    func testMonthShowsTheSelectedDaysAgenda() {
        launch()
        openSchedules()
        let mode = app.segmentedControls["schedules.mode"]
        mode.buttons[dayTitle].tap()
        if isPad {
            mode.buttons["Month"].tap()
        } else {
            let title = app.buttons["schedules.calendar.monthTitle"]
            XCTAssertTrue(title.waitUntilExists(timeout: 10), "The Day's month title is a button")
            title.tap()
        }
        let grid = app.descendants(matching: .any)["schedules.calendar.monthGrid"]
        XCTAssertTrue(grid.waitUntilExists(timeout: 10), "Month shows the month")
        // Another day of this month: yesterday, or tomorrow on the month's first day.
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let otherOffset = calendar.isDate(yesterday, equalTo: Date(), toGranularity: .month) ? -1 : 1
        let otherDay = calendar.date(byAdding: .day, value: otherOffset, to: Date()) ?? Date()
        let otherCell = app.buttons["schedules.calendar.monthDay.\(dayKey(offset: otherOffset))"]
        // The grid spans the screen's width, with no month arrows of its own.
        XCTAssertGreaterThan(grid.frame.width, app.frame.width * 0.75, "The month fills the width: \(grid.frame) in \(app.frame)")
        let days = grid.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.monthDay.'"))
        XCTAssertEqual(grid.buttons.count, days.count, "Every control in the grid is a date: only the bar pages months")
        // A swipe pages the month, and Today comes back.
        let today = app.buttons["schedules.calendar.monthDay.\(dayKey(offset: 0))"]
        XCTAssertTrue(today.waitUntilExists(timeout: 5), "Today is in the month")
        grid.swipeLeft()
        XCTAssertTrue(today.waitUntilGone(timeout: 5), "A swipe left shows next month")
        app.buttons["schedules.calendar.today"].tap()
        XCTAssertTrue(today.waitUntilExists(timeout: 5), "Today returns to this month")
        guard isPad else {
            capture("month")
            XCTAssertTrue(otherCell.waitUntilExists(timeout: 5), "\(otherDay) is in the month")
            otherCell.tap()
            XCTAssertTrue(waitFor(self.dayButton(offset: otherOffset).isSelected, timeout: 5), "A date opens its day in the Day")
            mode.buttons[dayTitle].tap()
            return
        }
        let summary = app.descendants(matching: .any)["schedules.calendar.summary"]
        XCTAssertTrue(summary.waitUntilExists(timeout: 10), "Month shows the selected day's summary")
        XCTAssertTrue(summary.label.contains("1 failed"), "Today's agenda under the month: \(summary.label)")
        capture("month")

        // Another day: its agenda follows.
        XCTAssertTrue(otherCell.waitUntilExists(timeout: 5), "\(otherDay) is in the month")
        otherCell.tap()
        XCTAssertTrue(waitFor(!summary.label.contains("Today"), timeout: 5), "Selecting a day shows its agenda: \(summary.label)")

        let dayTitleButton = app.buttons["schedules.calendar.dayTitle"]
        XCTAssertTrue(dayTitleButton.waitUntilExists(timeout: 5), "Month's day title is a button")
        dayTitleButton.tap()
        XCTAssertTrue(app.collectionViews["schedules.calendar.list"].waitUntilExists(timeout: 5), "The day title opens the Day")
        XCTAssertTrue(mode.buttons["Day"].isSelected)
    }

    /// The iPad's Week grid: a column per day with the morning's failure and the run waiting
    /// on you, a day header that opens the Day, and the same in landscape.
    func testWeekGridShowsTheWeekOnIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Week is for wide widths")
        launch()
        openSchedules()
        let mode = app.segmentedControls["schedules.mode"]
        XCTAssertTrue(mode.buttons["Week"].waitUntilExists(timeout: 10), "A wide switch offers Week")
        mode.buttons["Week"].tap()
        let grid = app.scrollViews["schedules.calendar.weekGrid"]
        XCTAssertTrue(grid.waitUntilExists(timeout: 10), "Week shows its grid")
        let digest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.entry.pSo7hh0o.' AND label CONTAINS 'Failed'")).firstMatch
        XCTAssertTrue(digest.waitUntilExists(timeout: 10), "Today's failed digest is in the grid")
        let jobs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.entry.6xbwGEM4.' AND label CONTAINS 'Needs you'")).firstMatch
        XCTAssertTrue(jobs.exists, "The run waiting on you is in the grid")
        let summary = app.descendants(matching: .any)["schedules.calendar.weekSummary"]
        XCTAssertTrue(summary.label.contains("failed"), "The week's summary counts failures: \(summary.label)")
        capture("week")

        // Today's folded night lists its runs in a popover.
        let night = app.buttons["schedules.calendar.cluster.\(dayKey(offset: 0))"]
        XCTAssertTrue(night.waitUntilExists(timeout: 5), "Today's clean night folds into one block")
        night.tap()
        let listed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.popover.'"))
        XCTAssertTrue(listed.firstMatch.waitUntilExists(timeout: 5), "The folded night lists its runs")
        XCTAssertEqual(listed.count, 3, "Kypu, the journal, and the dream ran clean tonight")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        capture("week-night-popover")
        app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        XCTAssertTrue(listed.firstMatch.waitUntilGone(timeout: 5), "The popover closes")

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(waitFor(self.app.frame.width > self.app.frame.height, timeout: 10), "The app turned to landscape")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        capture("week-landscape")
        XCTAssertTrue(waitFor(digest.exists && digest.isHittable, timeout: 10), "The digest stays in view in landscape")
        mode.buttons["Month"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["schedules.calendar.monthGrid"].waitUntilExists(timeout: 10))
        capture("month-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitFor(self.app.frame.width < self.app.frame.height, timeout: 10), "Back to portrait")

        mode.buttons["Week"].tap()
        let todayHeader = app.buttons["schedules.calendar.weekDay.\(dayKey(offset: 0))"]
        XCTAssertTrue(todayHeader.waitUntilExists(timeout: 5), "Today's column has its header")
        todayHeader.tap()
        XCTAssertTrue(app.collectionViews["schedules.calendar.list"].waitUntilExists(timeout: 5), "A day's header opens the Day")
        XCTAssertTrue(mode.buttons["Day"].isSelected)
    }

    /// The iPad mini turned to landscape keeps the day's summary and runs in view.
    func testCalendarFollowsTheIPadIntoLandscape() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Landscape is the iPad mini's")
        launch()
        openSchedules()
        app.segmentedControls["schedules.mode"].buttons[dayTitle].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(waitFor(self.app.frame.width > self.app.frame.height, timeout: 10), "The app turned to landscape")
        let summary = app.descendants(matching: .any)["schedules.calendar.summary"]
        XCTAssertTrue(waitFor(summary.exists && summary.isHittable, timeout: 10), "The summary shows in landscape")
        XCTAssertTrue(pastRun(named: "Weekday job hunt").waitUntilExists(timeout: 5), "The morning's runs show in landscape")
        // The whole screen: an app screenshot of a landscape iPad comes out on a portrait
        // canvas, half of it black.
        let attachment = XCTAttachment(uprightScreenshot: XCUIScreen.main.screenshot())
        attachment.name = "landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// In landscape a past run's session pushes over Schedules: the sidebar slides away and
    /// the chat takes the whole window, with no empty column left where the sidebar was.
    /// Back returns to Schedules with the sidebar beside it again.
    func testARunsSessionFillsTheWindowOverSchedulesInLandscapeAndBackBringsTheSidebar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The sidebar sits beside Schedules only on the iPad mini in landscape")
        launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(waitFor(self.app.frame.width > self.app.frame.height, timeout: 10), "The app turned to landscape")
        openSchedules()
        let schedulesRow = app.buttons["workspace.schedules.open"]
        XCTAssertTrue(schedulesRow.isHittable, "The sidebar shows beside Schedules")
        app.segmentedControls["schedules.mode"].buttons[dayTitle].tap()
        let digest = pastRun(named: "Daily personalized HN + X digest")
        XCTAssertTrue(digest.waitUntilExists(timeout: 10), "Today's digest run is on the calendar")
        hold()

        digest.tap()
        let back = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(back.waitUntilExists(timeout: 10), "The run's session opened over Schedules")
        XCTAssertTrue(waitFor(!schedulesRow.isHittable), "The sidebar went away")
        let window = app.windows.firstMatch
        // The chat's bar starts at the window's leading edge once it fills the window; left in
        // its old frame, it starts where the sidebar was, past an empty column.
        XCTAssertTrue(
            waitFor(back.frame.minX - window.frame.minX < 60),
            "The chat fills the window: Back at \(back.frame), window \(window.frame)"
        )
        let chatToggle = app.buttons["workspace.split.sidebarToggle"].firstMatch
        XCTAssertTrue(chatToggle.waitUntilExists(timeout: 5), "The run's chat, pushed over Schedules, has the sidebar button")
        XCTAssertGreaterThan(chatToggle.frame.minX, back.frame.maxX - 1, "It follows the chat's Back")
        hold()
        capture("landscape-run-session")

        back.tap()
        XCTAssertTrue(waitFor(schedulesRow.isHittable), "Back to Schedules brings the sidebar back")
        hold()
        capture("landscape-back-to-schedules")

        // The person's own toggle holds over what Schedules would show.
        let toggle = app.buttons["workspace.split.sidebarToggle"]
        XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "Schedules carries the sidebar toggle")
        toggle.tap()
        XCTAssertTrue(waitFor(!schedulesRow.isHittable), "The toggle hides the sidebar beside Schedules")
        hold()
        capture("landscape-schedules-sidebar-hidden")
    }

    /// Calendar Events: the day's meetings sit between the runs, an all-day event above them,
    /// and touching and holding one offers Schedule Agent…, which opens a one-time schedule
    /// at the meeting's offset (30 minutes before it, until the device clock passes that)
    /// with its details in the prompt.
    func testCalendarEventsShowBesideRunsAndScheduleAnAgent() {
        // The fixture's meeting is today at 10:00 by the device clock, the day the app launches.
        let meeting = Calendar.autoupdatingCurrent.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        launch(calendarEvents: "1")
        openSchedules()
        app.segmentedControls["schedules.mode"].buttons[dayTitle].tap()
        let review = app.cells["schedules.calendar.event.design-review"]
        let list = app.collectionViews["schedules.calendar.list"]
        XCTAssertTrue(review.waitUntilExists(timeout: 10), "Today's design review is in the Day")
        XCTAssertTrue(review.label.contains("calendar event"), "An event says it is one: \(review.label)")
        let nanny = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.entry.9Bq6VFNy.'")).firstMatch
        XCTAssertTrue(nanny.exists)
        XCTAssertLessThan(nanny.frame.minY, review.frame.minY, "The 9:00 run comes before the 10:00 meeting")
        capture("day-events")

        for _ in 0..<4 where !review.isHittable { list.swipeUp(velocity: .slow) }
        review.press(forDuration: 1.0)
        let scheduleAgent = menuButton("Schedule Agent…")
        XCTAssertTrue(scheduleAgent.waitUntilExists(timeout: 5), "An event's menu offers Schedule Agent…")
        XCTAssertFalse(menuButton("Run Now").exists, "An event has no run actions")
        capture("event-menu")
        let offsetBeforeTap = Self.initialOffsetTitle(meetingAt: meeting, now: Date())
        scheduleAgent.tap()

        let when = app.buttons["schedule.nativeEdit.eventOffset"]
        XCTAssertTrue(when.waitUntilExists(timeout: 10), "Schedule Agent opens the schedule editor")
        let offset = when.value as? String ?? ""
        // The editor reads the clock between these two samples; they differ only when the
        // tap straddles one of the rule's boundaries.
        let offsetAfterOpen = Self.initialOffsetTitle(meetingAt: meeting, now: Date())
        XCTAssertTrue(
            [offsetBeforeTap, offsetAfterOpen].contains(offset),
            "It starts at the meeting's offset for this time of day (\(offsetBeforeTap)): \(offset)"
        )
        XCTAssertFalse(app.buttons["schedule.nativeEdit.cadence"].exists, "An event's schedule runs once")
        let prompt = app.textViews["schedule.nativeEdit.prompt"]
        XCTAssertTrue(prompt.waitUntilExists(timeout: 5))
        let text = prompt.value as? String ?? ""
        XCTAssertTrue(text.contains("Title: Design review: Schedules calendar"), "The prompt carries the event: \(text)")
        XCTAssertTrue(text.contains("not instructions"), "The prompt says the event is calendar text: \(text)")
        capture("schedule-agent")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(when.waitUntilGone(timeout: 5))

        // Tomorrow's holiday is an all-day row above the day's runs.
        showDay(offset: 1)
        let holiday = app.cells["schedules.calendar.event.holiday"]
        XCTAssertTrue(holiday.waitUntilExists(timeout: 5), "Tomorrow's all-day event shows")
        let firstRun = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.entry.'")).firstMatch
        if firstRun.exists { XCTAssertLessThan(holiday.frame.minY, firstRun.frame.minY, "All-day events come first") }

        app.buttons["schedules.calendar.today"].tap()
        if isPad {
            app.segmentedControls["schedules.mode"].buttons["Week"].tap()
            let block = app.buttons["schedules.calendar.event.design-review"]
            XCTAssertTrue(block.waitUntilExists(timeout: 10), "The Week grid draws the meeting")
            capture("week-events")
            app.segmentedControls["schedules.mode"].buttons["Month"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["schedules.calendar.monthGrid"].waitUntilExists(timeout: 10))
            XCTAssertTrue(app.cells["schedules.calendar.event.design-review"].waitUntilExists(timeout: 10), "Month's agenda lists the day's meetings")
            capture("month-events")
            app.segmentedControls["schedules.mode"].buttons[dayTitle].tap()
        } else {
            app.buttons["schedules.calendar.monthTitle"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["schedules.calendar.monthGrid"].waitUntilExists(timeout: 10))
            capture("month-events")
            app.segmentedControls["schedules.mode"].buttons[dayTitle].tap()
        }
    }

    /// Calendar Events on without calendar access: the Day says why it shows no events.
    func testCalendarEventsWithoutAccessSaysWhy() {
        launch(calendarEvents: "denied")
        openSchedules()
        app.segmentedControls["schedules.mode"].buttons[dayTitle].tap()
        let row = app.cells["schedules.calendar.calendarAccess"]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The Day says it can't read the calendar")
        XCTAssertTrue(row.label.contains("Allow access in Settings"), row.label)
        XCTAssertFalse(app.cells["schedules.calendar.event.design-review"].exists, "No events without access")
        capture("day-denied")
    }

    // MARK: - Helpers


    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The Day's segment: "Day" in the wide switch, "Calendar" in the phone's.
    private var dayTitle: String { isPad ? "Day" : "Calendar" }

    private func dayKey(offset: Int) -> String {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Swipes the list up until `row` is on screen: the list loads only the cards near it.
    private func scrollList(to row: XCUIElement) {
        let list = app.collectionViews["schedules.list"]
        for _ in 0..<8 where !(row.exists && row.isHittable) { list.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.exists && row.isHittable, "\(row) scrolls into view")
    }

    /// The week strip's button for a day. The strip shows the selected day's week, so only
    /// today's and the selected day's buttons are certain to be there.
    private func dayButton(offset: Int) -> XCUIElement {
        app.descendants(matching: .any)["schedules.calendar.day.\(dayKey(offset: offset))"]
    }

    /// Pages the Day one day from today, to tomorrow (`1`) or yesterday (`-1`), by swiping as a
    /// person does, so it works on every weekday: a strip tap reaches only this week's days.
    private func showDay(offset: Int) {
        precondition(abs(offset) == 1, "showDay pages one day")
        let list = app.collectionViews["schedules.calendar.list"]
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "The Day agenda shows")
        if offset > 0 { list.swipeLeft() } else { list.swipeRight() }
        XCTAssertTrue(waitFor(self.dayButton(offset: offset).isSelected, timeout: 5), "The Day pages to \(dayKey(offset: offset))")
    }

    /// The whole screen, so a landscape iPad comes out the right way up (an app screenshot
    /// of a landscape iPad lands on a portrait canvas).
    private func capture(_ name: String) {
        let attachment = XCTAttachment(uprightScreenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// `calendarEvents` is the preview's `SCREENSHOT_CALENDAR_EVENTS`: `1` for a week of
    /// meetings, `denied` for the experiment on without calendar access.
    private func launch(calendarEvents: String? = nil) {
        XCUIDevice.shared.orientation = .portrait
        let scheme = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] ?? "dark"
        let arguments = ["-dev.chenda.Oppi.theme.mode", "manual", "-dev.chenda.Oppi.theme.id", scheme]
        launchPreview(
            screen: "schedules-calendar",
            environment: calendarEvents.map { ["SCREENSHOT_CALENDAR_EVENTS": $0] } ?? [:],
            colorScheme: scheme,
            arguments: arguments,
            ready: nil
        )
    }

    /// From the sidebar, as a person does: the drawer on a phone, the split's sidebar on iPad.
    private func openSchedules() {
        let drawer = app.buttons["workspace.sidebar.open"]
        let schedules = app.buttons["workspace.schedules.open"]
        let usesDrawer = drawer.waitUntilExists(timeout: 5)
        if usesDrawer {
            drawer.tap()
        } else {
            let toggle = app.buttons["workspace.split.sidebarToggle"]
            if toggle.exists, toggle.label.localizedCaseInsensitiveContains("show") { toggle.tap() }
        }
        XCTAssertTrue(schedules.waitUntilExists(timeout: 10), "The sidebar offers Schedules")
        schedules.tap()
        // A tap while the drawer still slides away lands on nothing: wait until it is
        // gone and the switch can take a tap.
        if usesDrawer {
            XCTAssertTrue(schedules.waitUntilGone(timeout: 5), "The drawer closes on Schedules")
        }
        let list = app.segmentedControls["schedules.mode"].buttons["List"]
        XCTAssertTrue(waitFor(list.exists && list.isHittable, timeout: 10), "The view switch can take a tap")
        // The screen has drawn what it opened on, so the push is over and a tap on the
        // switch lands.
        let shown = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["schedules.calendar.list", "schedules.calendar.summary", "schedules.calendar.weekGrid", "schedules.calendar.monthGrid", "schedules.list"]
        )).firstMatch
        XCTAssertTrue(shown.waitUntilExists(timeout: 10), "Schedules shows its view")
        // The drawer's close and the push still animate the bar after XCTest reads the app
        // idle; a tap on the switch during that animation is dropped (seen in recordings).
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func pastRun(named name: String) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.entry.' AND label BEGINSWITH %@", name)).firstMatch
    }

    private func subagentsStrip(of scheduleId: String) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "schedules.calendar.subagents.\(scheduleId).")).firstMatch
    }

    /// The When a new schedule for the fixture's 45-minute meeting at `meeting` starts with
    /// at `now`, by the app's rule (`ScheduleEventOffset.initialDate`, which this target cannot
    /// import): 30 minutes before while that is to come, else its start, else its end, else
    /// a time no offset matches.
    private static func initialOffsetTitle(meetingAt meeting: Date, now: Date) -> String {
        if meeting.addingTimeInterval(-30 * 60) > now { return "30 Minutes Before" }
        if meeting > now { return "At Start" }
        if meeting.addingTimeInterval(45 * 60) > now { return "At End" }
        return "Custom"
    }

    /// A popover menu's actions are buttons whose whole label is the title.
    private func menuButton(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }
}
