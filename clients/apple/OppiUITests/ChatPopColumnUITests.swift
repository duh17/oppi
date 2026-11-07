import XCTest

/// Popping a chat while its trailing column (Git) is open, over a
/// session-list stand-in underneath in one navigation stack
/// (`SCREENSHOT_SCREEN=chat-pop-column`). A plain Back tap, a completed
/// edge-swipe pop, and a cancelled edge swipe must all leave the list
/// filling the window, not narrowed by a trailing inset the column's own
/// teardown left behind.
@MainActor
final class ChatPopColumnUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Chat pop column tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// Compact width presents the Git panel as a sheet; only regular width
    /// has a trailing column to leave behind.
    private func launch() throws {
        launchPreview(screen: "chat-pop-column")
        try XCTSkipIf(app.windows.firstMatch.frame.width < 700, "The trailing column is regular-width only")
    }

    private func openGitPanel() {
        let git = app.buttons["chat.toolbar.git"]
        XCTAssertTrue(git.waitUntilExists(timeout: 10), "The Git button is on the default bar")
        git.tap()
        XCTAssertTrue(app.navigationBars["Git"].waitUntilExists(timeout: 5), "The Git panel did not open")
    }

    private var sessionListContent: XCUIElement {
        app.descendants(matching: .any)["chatPopColumn.sessionList.content"]
    }

    private var resizeHandle: XCUIElement {
        app.descendants(matching: .any)["trailingColumn.resizeHandle"]
    }

    /// The list fills the window once the chat (and its open column) is
    /// gone: a surviving trailing inset from the column leaves a dark gap
    /// instead.
    private func assertSessionListFillsWindow(
        _ reason: String,
        screenshot: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        XCTAssertTrue(
            sessionListContent.waitUntilExists(timeout: 5),
            "\(reason): the session list did not return", file: file, line: line
        )
        attachScreenshot(screenshot)
        XCTAssertEqual(
            sessionListContent.frame.width, window.frame.width, accuracy: 2,
            "\(reason): the session list must fill the window, not only the part beside where the column was",
            file: file, line: line
        )
    }

    /// The chat's own Back control: a plain, non-interactive pop.
    func testBackButtonPopFillsTheList() throws {
        try launch()
        openGitPanel()
        app.buttons["chat.toolbar.back"].tap()
        assertSessionListFillsWindow("Back button", screenshot: "pop-column-after-back")
    }

    /// Dragging from the left edge all the way across: the interactive pop
    /// completes, same destination as the back button.
    func testEdgeSwipePopFillsTheList() throws {
        try launch()
        openGitPanel()
        attachScreenshot("pop-column-before")
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        assertSessionListFillsWindow("A completed edge swipe", screenshot: "pop-column-after-swipe")
    }

    /// Starting the edge swipe but releasing a few points in: the gesture
    /// cancels, the chat stays on screen, and its column must still be there
    /// (not torn down and never rebuilt). Leaving afterwards with Back must
    /// still hand the whole window to the list.
    func testCancelledEdgeSwipeKeepsTheColumnOpen() throws {
        try launch()
        openGitPanel()
        XCTAssertTrue(resizeHandle.waitUntilExists(timeout: 5), "The Git panel's column did not open")
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let short = window.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.3)
        attachScreenshot("pop-column-cancelled-swipe")
        XCTAssertTrue(
            app.navigationBars["Git"].waitUntilExists(timeout: 5),
            "A cancelled swipe must keep the Git panel open"
        )
        XCTAssertTrue(
            resizeHandle.waitUntilExists(timeout: 5),
            "A cancelled swipe must keep the column's divider"
        )
        app.buttons["chat.toolbar.back"].tap()
        assertSessionListFillsWindow("Back after a cancelled swipe", screenshot: "pop-column-after-cancelled-then-back")
    }
}
