import XCTest

/// An open thread in the real All Sessions list over fixture sessions (`SCREENSHOT_SCREEN=router-modal-sites`,
/// site `inbox-threads`): live members list first, and stopped members fold behind one "N Stopped" row.
@MainActor
final class SessionThreadListUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Session thread list tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    private func launch(environment: [String: String] = [:]) {
        launchPreview(
            screen: "router-modal-sites",
            environment: [
                "SCREENSHOT_MODAL_SITE": "inbox-threads",
                "SCREENSHOT_COLOR_SCHEME": "dark",
            ].merging(environment) { _, new in new },
            ready: nil
        )
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// A row near the bottom sits under the Message bar, which takes the tap; scroll it clear.
    private func scrollClearOfBottomBar(_ element: XCUIElement) {
        let list = app.collectionViews["workspace.sessionList"]
        for _ in 0..<6 where !element.exists || element.frame.maxY > list.frame.maxY - 150 {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    /// Lets an open or close animation finish before a frame is read.
    private func settle(_ seconds: TimeInterval = 0.8) {
        let rest = XCTestExpectation(description: "rest")
        rest.isInverted = true
        wait(for: [rest], timeout: seconds)
    }

    /// The tapped row is still on screen: the person can see the rows it opened or closed, instead of having to
    /// scroll back down to find them.
    private func assertStillOnScreen(_ row: XCUIElement, _ reason: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(row.exists, reason)
        XCTAssertGreaterThan(row.frame.midY, window.frame.minY, reason)
        XCTAssertLessThan(row.frame.midY, window.frame.maxY, reason)
    }

    /// Tapping a thread's strip opens or closes the rows under it, and the strip stays where it was on screen:
    /// the rows open and close below it, and the list does not jump to its top. Reported on device for a thread
    /// that sat below the first screen.
    ///
    /// The thread link (`SCREENSHOT_THREAD_FOCUS`) opens the thread and scrolls its root into view, so the list
    /// is deep in its 25 sessions and the fold happens away from the top, the way the person had scrolled to the
    /// thread on the device.
    func testAThreadStripOpensAndClosesInPlace() {
        launch(environment: [
            "SCREENSHOT_THREAD_FOCUS": "thread-root",
            "SCREENSHOT_LIST_FILLER": "25",
            "SCREENSHOT_THREAD_STOPPED_COUNT": "3",
        ])

        let strip = app.buttons["thread.nav.thread-root"]
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "The thread link should list the strip")
        XCTAssertEqual(strip.value as? String, "Expanded", "The link should open the thread")
        XCTAssertLessThan(strip.frame.maxY, app.windows.firstMatch.frame.maxY, "The strip should be on screen")

        // Closing the thread takes rows away, so a list resting at the end of its content may have to scroll to
        // show what is left. The strip stays on screen instead of the list landing at its top.
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Collapsed"))
        settle()
        assertStillOnScreen(strip, "Closing the thread lost its strip off screen")

        // Opening it again is the reported tap: the rows come back under the strip, which stays where it was.
        let closed = strip.frame.minY
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Expanded"))
        settle()
        XCTAssertLessThan(
            abs(strip.frame.minY - closed), 2,
            "Opening the thread moved its strip from \(closed) to \(strip.frame.minY)"
        )
    }

    /// The two claims the paired-server E2E
    /// (`SessionThreadsE2ETests.testThreadStripExpandsLiveMembersFirstAndFoldsStoppedOnesBehindOneRow`)
    /// cannot make: the real list's own order puts Your Turn before Working, and closing the
    /// fold keeps the live members. The E2E walks the rest of the journey (live members first,
    /// the stopped ones folded and indented behind one row) against a live server.
    func testOpenThreadListsYourTurnBeforeWorkingAndClosingTheFoldKeepsLiveMembers() {
        launch()
        let strip = app.buttons["thread.nav.thread-root"]
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "Thread strip missing")
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Expanded"))

        let working = app.buttons["session.nav.child-working"]
        let idle = app.buttons["session.nav.child-kypu"]
        XCTAssertTrue(working.waitForExistence(timeout: 10), "The working member should list")
        XCTAssertTrue(idle.exists, "The idle member should list")
        XCTAssertLessThan(idle.frame.minY, working.frame.minY, "Your Turn lists before Working, as the list does")

        let fold = app.buttons["thread.stopped.thread-root"]
        scrollClearOfBottomBar(fold)
        fold.tap()
        XCTAssertTrue(waitForValue(fold, "Expanded"))
        let stopped = app.buttons["session.nav.child-done"]
        XCTAssertTrue(stopped.waitForExistence(timeout: 5), "Opening the fold should list the stopped member")

        scrollClearOfBottomBar(fold)
        fold.tap()
        XCTAssertTrue(waitForValue(fold, "Collapsed"))
        XCTAssertTrue(stopped.waitForNonExistence(timeout: 5), "Closing the fold hides the stopped members")
        XCTAssertTrue(working.exists, "Closing the fold keeps the live members")
    }

    /// A thread link (the handoff `oppi://thread/<id>` leaves for All Sessions) opens the thread in place
    /// and scrolls its root into view in a list that has 25 other sessions above it.
    func testThreadLinkOpensTheThreadInPlaceAndScrollsToItsRoot() {
        launch(environment: ["SCREENSHOT_THREAD_FOCUS": "thread-root", "SCREENSHOT_LIST_FILLER": "25"])
        let strip = app.buttons["thread.nav.thread-root"]
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "Thread strip missing")
        XCTAssertTrue(waitForValue(strip, "Expanded"), "The link should open the thread in place")

        let root = app.buttons["session.nav.thread-root"]
        let window = app.windows.firstMatch
        XCTAssertTrue(root.exists && window.frame.contains(root.frame), "The root row should be on screen")
        // The thread is the last thing in the list, so the list stops where the thread ends; it has
        // scrolled past the sessions above it.
        XCTAssertFalse(app.buttons["session.nav.filler-24"].exists, "The list should have scrolled to the thread")
        XCTAssertTrue(app.buttons["session.nav.child-working"].exists, "The thread's live members list under the root")
        XCTAssertTrue(app.buttons["thread.stopped.thread-root"].exists, "Stopped members are folded behind one row")
    }

    /// The control for the scroll: without a link the same list leaves the thread root below the filler.
    func testWithoutAThreadLinkTheRootStaysBelowTheOtherSessions() {
        launch(environment: ["SCREENSHOT_LIST_FILLER": "25"])
        XCTAssertTrue(app.buttons["session.nav.filler-24"].waitForExistence(timeout: 15), "Filler sessions missing")
        XCTAssertFalse(app.buttons["session.nav.thread-root"].exists, "The root should be below the first screen")
    }

    /// The reported case: 100 day-old stopped workers no longer push the live members off the first screen.
    func testBigThreadKeepsItsLiveMembersOnTheFirstScreen() {
        launch(environment: ["SCREENSHOT_THREAD_STOPPED_COUNT": "100"])
        let strip = app.buttons["thread.nav.thread-root"]
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "Thread strip missing")
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Expanded"))

        let working = app.buttons["session.nav.child-working"]
        let fold = app.buttons["thread.stopped.thread-root"]
        XCTAssertTrue(working.waitForExistence(timeout: 10), "The working member should list")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(working.frame), "The live member is on the first screen")
        XCTAssertTrue(fold.exists, "The fold row follows the live members on the first screen")
        XCTAssertEqual(fold.label, "102 Stopped")
        XCTAssertFalse(app.buttons["session.nav.old-worker-0"].exists, "Stopped workers stay folded")
    }
}
