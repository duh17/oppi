import XCTest

/// Schedules in the real workspace shell over a fixture server's week of runs
/// (`SCREENSHOT_SCREEN=schedules-calendar`, clock posed at 8:42 AM): it opens on the
/// Calendar, the List is one tap away, a past run opens its session, and an upcoming
/// run's menu offers only what the server can do.
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
        XCTAssertTrue(mode.waitUntilExists(timeout: 10), "Schedules shows its List | Calendar switch")
        XCTAssertTrue(mode.buttons["Calendar"].isSelected, "Schedules opens on the Calendar")
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
        attachScreenshot("list")

        mode.buttons["Calendar"].tap()
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

        // Today opens at now; tonight's running Night shift is above it.
        let list = app.collectionViews["schedules.calendar.list"]
        let tonight = subagentsStrip(of: "u1C2kXLz")
        for _ in 0..<4 where !(tonight.exists && tonight.isHittable) { list.swipeDown() }
        XCTAssertTrue(waitFor(tonight.exists && tonight.isHittable, timeout: 10), "The running Night shift has its subagents strip")
        XCTAssertTrue(tonight.label.hasPrefix("14 subagents"), "The strip counts the run's subagents: \(tonight.label)")
        XCTAssertTrue(tonight.label.contains("2 working"), "The strip says how many still work: \(tonight.label)")
        attachScreenshot("today-night")

        // Yesterday's night is done: its four runs fold into one row, and opening it shows
        // the Night shift with all 26 of its subagents.
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let parts = calendar.dateComponents([.year, .month, .day], from: yesterday)
        let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        app.descendants(matching: .any)["schedules.calendar.day.\(key)"].tap()
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

    /// The iPad mini turned to landscape keeps the day's summary and runs in view.
    func testCalendarFollowsTheIPadIntoLandscape() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Landscape is the iPad mini's")
        launch()
        openSchedules()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(waitFor(self.app.frame.width > self.app.frame.height, timeout: 10), "The app turned to landscape")
        let summary = app.descendants(matching: .any)["schedules.calendar.summary"]
        XCTAssertTrue(waitFor(summary.exists && summary.isHittable, timeout: 10), "The summary shows in landscape")
        XCTAssertTrue(pastRun(named: "Weekday job hunt").waitUntilExists(timeout: 5), "The morning's runs show in landscape")
        // The whole screen: an app screenshot of a landscape iPad comes out on a portrait
        // canvas, half of it black.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Helpers

    private func launch() {
        XCUIDevice.shared.orientation = .portrait
        let scheme = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] ?? "light"
        launchPreview(
            screen: "schedules-calendar",
            colorScheme: scheme,
            arguments: ["-dev.chenda.Oppi.theme.mode", "manual", "-dev.chenda.Oppi.theme.id", scheme],
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
        XCTAssertTrue(waitFor(list.exists && list.isHittable, timeout: 10), "The List | Calendar switch can take a tap")
    }

    private func pastRun(named name: String) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'schedules.calendar.entry.' AND label BEGINSWITH %@", name)).firstMatch
    }

    private func subagentsStrip(of scheduleId: String) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "schedules.calendar.subagents.\(scheduleId).")).firstMatch
    }

    /// A popover menu's actions are buttons whose whole label is the title.
    private func menuButton(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }
}
