import XCTest

/// An open thread in the real All Sessions list over fixture sessions (`SCREENSHOT_SCREEN=router-modal-sites`,
/// site `inbox-threads`): live members list first, and stopped members fold behind one "N Stopped" row.
@MainActor
final class SessionThreadListUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Session thread list tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    private func launch(environment: [String: String] = [:]) {
        app = OppiTestLaunch.makeApp()
        app.launchArguments += ["--screenshot-preview"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "router-modal-sites"
        app.launchEnvironment["SCREENSHOT_MODAL_SITE"] = "inbox-threads"
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = "dark"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        XCTAssertEqual(app.wait(for: .runningForeground, timeout: 10), true)
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

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Live members (an idle child from another workspace, then a working child) list in the list's
    /// own order before the fold; the finished child and its own child sit behind it until it is opened, indented
    /// under their listed parent.
    func testOpenThreadListsLiveMembersFirstAndFoldsStoppedOnesBehindOneRow() {
        launch()
        let strip = app.buttons["thread.nav.thread-root"]
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "Thread strip missing")
        strip.tap()
        XCTAssertTrue(waitForValue(strip, "Expanded"))

        let working = app.buttons["session.nav.child-working"]
        let idle = app.buttons["session.nav.child-kypu"]
        let fold = app.buttons["thread.stopped.thread-root"]
        XCTAssertTrue(working.waitForExistence(timeout: 10), "The working member should list")
        XCTAssertTrue(idle.exists, "The idle member should list")
        XCTAssertTrue(fold.exists, "The stopped members should fold behind one row")
        XCTAssertEqual(fold.label, "2 Stopped")
        XCTAssertEqual(fold.value as? String, "Collapsed")
        XCTAssertLessThan(idle.frame.minY, working.frame.minY, "Your Turn lists before Working, as the list does")
        XCTAssertLessThan(working.frame.minY, fold.frame.minY, "The fold row ends the thread")
        XCTAssertFalse(app.buttons["session.nav.child-done"].exists, "A stopped member stays folded")

        scrollClearOfBottomBar(fold)
        fold.tap()
        XCTAssertTrue(waitForValue(fold, "Expanded"))
        let stopped = app.buttons["session.nav.child-done"]
        let grandchild = app.buttons["session.nav.grandchild"]
        XCTAssertTrue(stopped.waitForExistence(timeout: 5), "Opening the fold should list the stopped member")
        scrollClearOfBottomBar(grandchild)
        XCTAssertTrue(grandchild.exists && stopped.exists && fold.exists, "The fold's members list right under it")
        XCTAssertGreaterThan(stopped.frame.minY, fold.frame.minY)
        XCTAssertGreaterThan(grandchild.frame.minY, stopped.frame.minY, "A child lists under its parent")
        XCTAssertGreaterThan(grandchild.frame.minX, stopped.frame.minX + 8, "A child is indented under its parent")

        XCTAssertTrue(fold.exists)
        scrollClearOfBottomBar(fold)
        fold.tap()
        XCTAssertTrue(waitForValue(fold, "Collapsed"))
        XCTAssertTrue(waitForNonExistence(stopped), "Closing the fold hides the stopped members")
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

    /// The strip says how many members are in each state, in the list's words and the strip's order,
    /// with the root left out and zero counts omitted; "Stopped" replaces the old "finished".
    func testStripCountsMembersInTheListsWords() {
        launch()
        let small = app.buttons["thread.nav.thread-root"]
        XCTAssertTrue(small.waitForExistence(timeout: 15), "Thread strip missing")
        XCTAssertTrue(small.label.contains("Thread with 4 child sessions, 1 working \u{00B7} 1 idle \u{00B7} 2 stopped"), small.label)
        XCTAssertFalse(small.label.contains("finished"), small.label)
        app.terminate()

        launch(environment: [
            "SCREENSHOT_THREAD_STOPPED_COUNT": "100",
            "SCREENSHOT_THREAD_WORKING_COUNT": "14",
            "SCREENSHOT_THREAD_BLOCKED_COUNT": "2",
        ])
        let big = app.buttons["thread.nav.thread-root"]
        XCTAssertTrue(big.waitForExistence(timeout: 15), "Thread strip missing")
        XCTAssertTrue(
            big.label.contains("Thread with 120 child sessions, 15 working \u{00B7} 2 need you \u{00B7} 1 idle \u{00B7} 102 stopped"),
            big.label
        )
        XCTAssertEqual(big.value as? String, "Collapsed")
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
