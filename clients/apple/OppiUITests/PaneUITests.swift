import XCTest

/// The pane host on a regular-width window: a chat's attached leaf opens
/// beside it, the divider resizes, expands and closes it, a narrowing window
/// turns it into its sheet, and popping the chat hands the whole window back
/// to the screen under it. Compact width keeps the sheets
/// (`ChatRoutesUITests`), so every test here skips there.
///
/// `panes` is the chat above a session-list stand-in in one stack;
/// `chat-routes` is the chat alone with its fixture controls.
@MainActor
final class PaneUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Pane tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    // MARK: - Popping the owner

    /// The list fills the window once the chat (and its open companion) is
    /// gone, after a Back tap.
    func testBackButtonPopFillsTheList() throws {
        try launchPanes()
        openGitPanel()
        app.buttons["chat.toolbar.back"].tap()
        assertSessionListFillsWindow("Back button", screenshot: "pop-after-back")
    }

    /// Dragging from the left edge all the way across: the interactive pop
    /// completes, same destination as the back button.
    func testEdgeSwipePopFillsTheList() throws {
        try launchPanes()
        openGitPanel()
        attachScreenshot("pop-before")
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        assertSessionListFillsWindow("A completed edge swipe", screenshot: "pop-after-swipe")
    }

    /// Starting the edge swipe but releasing a few points in: the gesture
    /// cancels, the chat stays on screen, and its companion must still be
    /// there (not torn down and never rebuilt). Leaving afterwards with Back
    /// must still hand the whole window to the list.
    func testCancelledEdgeSwipeKeepsTheCompanionOpen() throws {
        try launchPanes()
        openGitPanel()
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "The Git panel did not open beside the chat")
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let short = window.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.3)
        attachScreenshot("pop-cancelled-swipe")
        XCTAssertTrue(app.navigationBars["Git"].waitUntilExists(timeout: 5), "A cancelled swipe must keep the Git panel open")
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "A cancelled swipe must keep the divider")
        app.buttons["chat.toolbar.back"].tap()
        assertSessionListFillsWindow("Back after a cancelled swipe", screenshot: "pop-after-cancelled-then-back")
    }

    // MARK: - Divider

    /// A moderate drag resizes within the companion's own range, a decisive
    /// drag the rest of the way to the chat's edge commits to the full
    /// window, the chat covered but a grab edge, dragging the grab edge back
    /// returns to the remembered width, and a decisive drag the other way
    /// closes the panel like its own Done control. The divider speaks its
    /// width, which follows the drag (A1).
    func testDividerDragsResizesExpandsAndCloses() throws {
        try launchChatRoutes()
        app.buttons["chat.toolbar.files"].tap()
        let files = app.navigationBars["Files"]
        XCTAssertTrue(files.waitUntilExists(timeout: 5), "Files panel did not open")
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "The divider did not appear")
        // Proportional to the window, not a fixed point count, so the same
        // drags cross the same commit thresholds whatever the window's width.
        let windowWidth = app.windows.firstMatch.frame.width
        let openWidth = files.frame.width
        let openValue = divider.value as? String
        XCTAssertEqual(openValue, "\(Int(openWidth.rounded())) points", "The divider speaks the companion's width")
        attachScreenshot("divider-before-drag")

        drag(divider, by: -(windowWidth * 0.15))
        XCTAssertTrue(waitFor(files.frame.width > openWidth + 100), "Dragging the divider did not widen the panel")
        let resizedWidth = files.frame.width
        XCTAssertNotEqual(divider.value as? String, openValue, "The divider's value follows the drag")
        attachScreenshot("divider-after-drag")

        drag(divider, by: -(windowWidth + 100))
        XCTAssertTrue(waitFor(files.frame.width > windowWidth - 80), "Dragging past the threshold did not expand to the full window")
        XCTAssertEqual(divider.value as? String, "Full window")
        attachScreenshot("divider-full-window")

        drag(divider, by: windowWidth - resizedWidth)
        XCTAssertTrue(
            waitFor(abs(files.frame.width - resizedWidth) < 60),
            "Dragging back did not return to the remembered width: \(files.frame.width) vs \(resizedWidth)"
        )
        attachScreenshot("divider-restored")

        drag(divider, by: resizedWidth + 100)
        XCTAssertTrue(files.waitUntilGone(timeout: 5), "A decisive drag toward the far edge did not close the panel")
        assertRunning()
    }

    // MARK: - Opening beside the chat

    /// Share opens in the same companion as every other panel, the divider
    /// included, instead of a full-screen cover: the chat stays beside it.
    func testShareOpensBesideTheChat() throws {
        try launchChatRoutes()
        openShareSheet()
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "Share must open beside the chat, not a full-screen cover")
        assertChatBesideCompanion("share")
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Share Session"].waitUntilGone(timeout: 5))
        assertRunning()
    }

    /// An extension surface opens in its panel pane from the pill's menu: Oppi's bar with the
    /// surface's title and Close, the line naming where it comes from, and the chat beside it.
    /// While the pane shows it, the pill focuses the pane instead of opening the drawer.
    func testExtensionSurfaceOpensInItsPanelPane() throws {
        try launchChatRoutes(environment: ["CHAT_ROUTES_SURFACE": "jobs"])
        let pill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-surface-background_2djobs"]
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "The jobs surface shows its pill")
        pill.press(forDuration: 1.0)
        let open = app.buttons["Open in Pane"]
        XCTAssertTrue(open.waitUntilExists(timeout: 5), "The pill's menu offers Open in Pane")
        open.tap()

        let bar = app.navigationBars["Background jobs"]
        XCTAssertTrue(bar.waitUntilExists(timeout: 5), "The panel pane did not open")
        XCTAssertTrue(divider.waitUntilExists(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["extensionPanel.source"].exists, "The pane names its source")
        let stop = app.scrollViews["extension.surfaceReader.scroll.surface-background_2djobs"]
            .buttons["extension.surface.background_2djobs.jobs.stop_3abash_2d72"]
        XCTAssertTrue(stop.waitUntilExists(timeout: 5), "The pane draws the surface's cards with their actions")
        assertChatBesideCompanion("extension-panel")

        pill.tap()
        let drawer = app.descendants(matching: .any)["extension-strip-aboveEditor-drawer-surface-background_2djobs"]
        XCTAssertFalse(drawer.waitUntilExists(timeout: 1), "The pane shows the surface; its pill must not open the drawer too")

        app.buttons["extensionPanel.close"].tap()
        XCTAssertTrue(bar.waitUntilGone(timeout: 5), "Close closes the pane")
        assertRunning()
    }

    /// I5: a second link replaces the open companion, and a window that
    /// narrows to compact (Split View) presents it as the sheet it is there,
    /// not dropping it.
    func testCompanionIsReplacedAndMovesToASheetWhenTheWindowNarrows() throws {
        try launchChatRoutes()
        let commit = app.navigationBars["Commit"]
        app.buttons["chatRoutes.openCommitViewer"].tap()
        XCTAssertTrue(commit.waitUntilExists(timeout: 5), "The commit link did not open a pane")
        assertChatBesideCompanion("commit")

        app.buttons["chatRoutes.openFileViewer"].tap()
        XCTAssertTrue(commit.waitUntilGone(timeout: 5), "A second link must replace the open pane")
        XCTAssertTrue(app.buttons["fullScreen.code.close"].waitUntilExists(timeout: 10), "The file link did not open a pane")

        app.buttons["chatRoutes.openCommitViewer"].tap()
        XCTAssertTrue(commit.waitUntilExists(timeout: 5), "The next link must replace the file pane")
        app.buttons["chatRoutes.narrowWindow"].tap()
        let dismiss = app.buttons["chat.commit-detail.dismiss"]
        XCTAssertTrue(
            waitFor(dismiss.exists && dismiss.label == "Done"),
            "Narrowing must present the open commit as its sheet, not drop it"
        )
        XCTAssertFalse(divider.exists, "A compact window has no divider")
        assertRunning()
    }

    /// W1: dragging the window's corner (Stage Manager) under 640 pt makes the
    /// window compact, where the panel has no room beside the chat and the
    /// divider goes; dragged back to full size, the panel is beside the chat
    /// again. The window is restored even when a step fails: SpringBoard
    /// would open every later run in the small window.
    func testDraggingTheWindowCornerNarrowsThePanesAndFullSizeRestoresThem() throws {
        try launchPanes()
        openGitPanel()
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "The Git panel did not open beside the chat")
        let full = app.windows.firstMatch.frame
        addTeardownBlock { @MainActor [app] in
            guard let app, app.windows.firstMatch.frame.size != full.size else { return }
            app.dragWindowCorner(to: CGPoint(x: full.maxX, y: full.maxY))
        }
        attachScreenCapture("window-full")

        app.dragWindowCorner(to: CGPoint(x: full.minX + 600, y: full.maxY - 160))
        let window = app.windows.firstMatch
        XCTAssertTrue(
            waitFor(window.frame.width < 640 && window.horizontalSizeClass == .compact),
            "The corner drag did not make the window compact: \(window.frame)"
        )
        XCTAssertTrue(divider.waitUntilGone(timeout: 5), "A compact window has no divider")
        attachScreenCapture("window-compact")
        assertRunning()

        app.dragWindowCorner(to: CGPoint(x: full.maxX, y: full.maxY))
        XCTAssertTrue(
            waitFor(window.frame.size == full.size && window.horizontalSizeClass == .regular),
            "The window did not return to full size: \(window.frame)"
        )
        XCTAssertTrue(app.navigationBars["Git"].waitUntilExists(timeout: 5), "The Git panel must be back")
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "Full size puts the panel beside the chat again")
        attachScreenCapture("window-restored")
        assertRunning()
    }

    /// K3: typing (or dictating) in the composer while a link opens beside
    /// the chat keeps the composer first responder: opening a pane never
    /// takes the keyboard.
    func testComposerKeepsTheKeyboardWhileALinkOpensBeside() throws {
        try launchChatRoutes()
        let input = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(input.waitUntilExists(timeout: 10), "Composer input missing")
        input.tap()
        input.typeText("keep ")
        app.buttons["chatRoutes.openFileViewer"].tap()
        XCTAssertTrue(app.buttons["fullScreen.code.close"].waitUntilExists(timeout: 10), "The file link did not open a pane")
        // `typeText` fails unless the element still has keyboard focus.
        input.typeText("typing")
        XCTAssertTrue(
            waitFor(((input.value as? String) ?? "").contains("keep typing")),
            "The composer must keep its text and focus: \(input.value ?? "nil")"
        )
        attachScreenshot("composer-kept-focus")
        assertRunning()
    }

    /// L1: a 200-character title in the chat beside a companion truncates in
    /// the chat's own bar and never runs under the companion; its full text
    /// stays in the title's accessibility value.
    func testLongTitleTruncatesInsideItsPane() throws {
        let title = String(repeating: "A long session title that keeps going ", count: 6).prefix(200)
        try launchChatRoutes(environment: ["CHAT_ROUTES_SESSION_TITLE": String(title)])
        app.buttons["chat.toolbar.files"].tap()
        XCTAssertTrue(app.navigationBars["Files"].waitUntilExists(timeout: 5), "Files panel did not open")
        XCTAssertTrue(divider.waitUntilExists(timeout: 5))
        let titleButton = app.buttons.matching(NSPredicate(format: "label == %@", "Rename session")).firstMatch
        XCTAssertTrue(titleButton.waitUntilExists(timeout: 5), "The chat's title is missing")
        XCTAssertEqual(titleButton.value as? String, String(title), "The title's value carries the whole title")
        XCTAssertLessThanOrEqual(
            titleButton.frame.maxX, divider.frame.midX,
            "The title must stay in the chat's pane, left of the divider"
        )
        attachScreenshot("long-title-beside-files")
        assertRunning()
    }

    // MARK: - Steps

    /// The screen's capture: in landscape `app.screenshot()` draws the iPad's
    /// interface sideways into a clipped portrait canvas.
    private func attachScreenCapture(_ name: String) {
        let attachment = XCTAttachment(uprightScreenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var divider: XCUIElement {
        app.descendants(matching: .any)["pane.divider.0"]
    }

    private var sessionListContent: XCUIElement {
        app.descendants(matching: .any)["panes.sessionList.content"]
    }

    /// Compact width presents the panels as sheets; only regular width has
    /// a companion.
    private func skipUnlessWide() throws {
        try XCTSkipIf(
            app.windows.firstMatch.horizontalSizeClass != .regular,
            "Panes beside the chat are regular-width only"
        )
    }

    /// A chat's panel is at least an iPhone wide, so the iPad mini holds it
    /// beside the chat only in landscape; in portrait it opens full.
    private func turnLandscape() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
    }

    private func launchPanes() throws {
        turnLandscape()
        launchPreview(screen: "panes")
        try skipUnlessWide()
    }

    /// The chat-routes bar is complete once Outline is on it (see
    /// `ChatRoutesUITests.launch`).
    private func launchChatRoutes(environment: [String: String] = [:]) throws {
        turnLandscape()
        launchPreview(screen: "chat-routes", environment: environment, ready: nil)
        XCTAssertTrue(app.buttons["chat.toolbar.context"].waitUntilExists(timeout: 15), "Chat routes harness did not appear")
        XCTAssertTrue(app.buttons["chat.toolbar.outline"].waitUntilExists(timeout: 10), "The fixture timeline did not load")
        try skipUnlessWide()
    }

    private func openGitPanel() {
        let git = app.buttons["chat.toolbar.git"]
        XCTAssertTrue(git.waitUntilExists(timeout: 10), "The Git button is on the default bar")
        git.tap()
        XCTAssertTrue(app.navigationBars["Git"].waitUntilExists(timeout: 5), "The Git panel did not open")
    }

    /// Share is in the title's context menu.
    private func openShareSheet() {
        let title = app.buttons["Rename session"]
        XCTAssertTrue(title.waitUntilExists(timeout: 10))
        title.press(forDuration: 1.0)
        let share = app.buttons["Share Session"]
        XCTAssertTrue(share.waitUntilExists(timeout: 5), "Share Session missing from the title menu")
        share.tap()
        XCTAssertTrue(app.navigationBars["Share Session"].waitUntilExists(timeout: 5), "Share sheet did not open")
    }

    /// The chat's timeline keeps its minimum width and stays beside the
    /// companion, not under it.
    private func assertChatBesideCompanion(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        attachScreenshot("\(name)-beside-chat")
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(timeline.exists, "The chat's timeline must stay on screen beside the \(name)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(timeline.frame.width, 375, "The chat keeps its minimum width", file: file, line: line)
        XCTAssertLessThan(
            timeline.frame.width, app.windows.firstMatch.frame.width,
            "The \(name) must share the window with the chat, not cover it", file: file, line: line
        )
    }

    /// The list fills the window once the chat is gone: a companion width
    /// left behind would leave a gap instead.
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
            "\(reason): the session list must fill the window, not only the part beside where the companion was",
            file: file, line: line
        )
    }

    /// Drags `element` horizontally by `dx` points: negative widens the
    /// companion (toward the chat), positive narrows or closes it. The finger
    /// starts and stops 30 pt inside the window (a full-window companion's
    /// divider reaches its leading edge): a touch at or past the window's
    /// edge can start an iPadOS window gesture instead.
    private func drag(_ element: XCUIElement, by dx: CGFloat) {
        let window = app.windows.firstMatch.frame
        let inside = { (x: CGFloat) in min(max(x, window.minX + 30), window.maxX - 30) }
        let frame = element.frame
        let startX = min(max(frame.midX, inside(frame.minX)), frame.maxX - 2)
        let endX = inside(startX + dx)
        let start = element.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: startX - frame.minX, dy: frame.height / 2))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: endX - startX, dy: 0)))
    }
}
