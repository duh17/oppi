import XCTest

/// How wide a file reads beside a list or a chat. On the iPad mini a file
/// opens at its reading width, 34 em of the reader's body plus its margins
/// (634 pt at the default text size), and the chat or the list keeps the
/// rest; where the two do not fit at their minimums (portrait, or landscape
/// with the sidebar showing) the file covers its neighbour. The chat runs in
/// the production shell over the chat-routes fixtures
/// (`SCREENSHOT_SCREEN=pane-restore`, its reply linking the garden notebook);
/// the File Browser in its column preview (`file-browser-column`).
@MainActor
final class ReadingWidthUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    /// The reading width at the default text size: 34 em of the 17 pt body
    /// (578 pt) and 28 pt of margin on each side.
    private let readingWidth = 634
    private let sessionRow = "session.nav.chat-routes-session"

    private var divider: XCUIElement { app.descendants(matching: .any)["pane.divider.0"] }
    private var readerClose: XCUIElement { app.buttons["fullScreen.code.close"] }

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Reading width tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// A file the chat's text links to opens beside the chat at its reading
    /// width with the sidebar hidden; with the sidebar showing, and in
    /// portrait, there is no room for both, so it covers the chat.
    func testAChatFileLinkOpensBesideTheChatAtItsReadingWidth() throws {
        try requirePad()
        openChat(.landscapeLeft)
        setSidebar(shown: false)
        attachScreenCapture("chat-landscape-sidebar-hidden")

        tapLink("garden.org")
        XCTAssertTrue(readerClose.waitUntilExists(timeout: 10), "The link opened the notebook beside the chat")
        XCTAssertTrue(waitFor(self.dividerWidth.map { abs($0 - self.readingWidth) <= 2 } ?? false),
                      "The file reads at its reading width: \(divider.value ?? "nil")")
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].isHittable, "The chat keeps the rest")
        hold()
        attachScreenCapture("chat-reader-landscape-sidebar-hidden")

        setSidebar(shown: true)
        XCTAssertTrue(waitFor(self.dividerValue == "Full window"),
                      "Beside the sidebar there is no room for both; the file covers the chat: \(dividerValue)")
        hold()
        attachScreenCapture("chat-reader-landscape-sidebar-shown")

        XCUIDevice.shared.orientation = .portrait
        let window = app.windows.firstMatch
        XCTAssertTrue(waitFor(window.frame.height > window.frame.width), "The window turned to portrait")
        XCTAssertTrue(waitFor(self.dividerValue == "Full window"), "In portrait the file covers the chat: \(dividerValue)")
        hold()
        attachScreenCapture("chat-reader-portrait")
    }

    /// A width the person drags the reader to is remembered for the chat and
    /// its reader across a relaunch; a double-tap on the divider gives the
    /// reader its reading width back.
    func testADraggedReaderWidthOutlivesARelaunchAndADoubleTapResetsIt() throws {
        try requirePad()
        openChat(.landscapeLeft)
        setSidebar(shown: false)
        tapLink("garden.org")
        XCTAssertTrue(readerClose.waitUntilExists(timeout: 10), "The link opened the notebook beside the chat")
        XCTAssertTrue(waitFor(self.dividerWidth.map { abs($0 - self.readingWidth) <= 2 } ?? false), "at its reading width")

        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 150, dy: 0)))
        XCTAssertTrue(waitFor((self.dividerWidth ?? 0) < self.readingWidth - 100), "The drag narrowed the reader: \(dividerValue)")
        let dragged = try XCTUnwrap(dividerWidth)
        // Past the 500 ms settle, so the window's panes are written before the process dies.
        hold(for: 1.5)
        attachScreenCapture("drag-before-relaunch")

        launchPreview(screen: "pane-restore", environment: ["CHAT_ROUTES_NOTEBOOK_LINK": "1"], colorScheme: "dark", ready: nil)
        let composer = app.descendants(matching: .any)["chat.input"]
        if !composer.waitUntilExists(timeout: 10) {
            app.descendants(matching: .any)[sessionRow].tap()
            XCTAssertTrue(composer.waitUntilExists(timeout: 10), "The chat opened after the relaunch")
        }
        setSidebar(shown: false)
        tapLink("garden.org")
        XCTAssertTrue(readerClose.waitUntilExists(timeout: 10), "The notebook opened again")
        XCTAssertTrue(waitFor(self.dividerWidth.map { abs($0 - dragged) <= 2 } ?? false),
                      "at the width it was dragged to (\(dragged) pt): \(dividerValue)")
        hold()
        attachScreenCapture("relaunch-remembered")

        divider.doubleTap()
        XCTAssertTrue(waitFor(self.dividerWidth.map { abs($0 - self.readingWidth) <= 2 } ?? false),
                      "A double-tap gave the reader its reading width back: \(dividerValue)")
        hold()
        attachScreenCapture("double-tap-reset")
    }

    /// The File Browser's open file reads at its reading width beside the
    /// list in landscape, and covers the list in portrait.
    func testTheFileBrowserOpensAFileAtItsReadingWidth() throws {
        try requirePad()
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "file-browser-column", colorScheme: "dark", readyTimeout: 20)
        XCTAssertTrue(app.descendants(matching: .any)["full-screen.org-mode.body"].waitUntilExists(timeout: 20),
                      "The Org file opened")
        XCTAssertTrue(waitFor(self.dividerWidth.map { abs($0 - self.readingWidth) <= 2 } ?? false),
                      "The file reads at its reading width: \(dividerValue)")
        XCTAssertGreaterThanOrEqual(app.buttons["fileBrowser.row.projects/garden.org"].frame.width, 374,
                                    "The list keeps the rest, at least an iPhone's width")
        hold()
        attachScreenCapture("files-reader-landscape")

        XCUIDevice.shared.orientation = .portrait
        let window = app.windows.firstMatch
        XCTAssertTrue(waitFor(window.frame.height > window.frame.width), "The window turned to portrait")
        XCTAssertTrue(waitFor(self.dividerValue == "Full window"), "In portrait the file covers the list: \(dividerValue)")
        hold()
        attachScreenCapture("files-reader-portrait")
    }

    /// The phone has one column: a linked file opens over the chat, as before.
    func testOnAPhoneAChatFileLinkOpensOverTheChat() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Compact width is the phone's")
        }
        openChat(.portrait)
        tapLink("garden.org")
        XCTAssertTrue(app.descendants(matching: .any)["full-screen.org-mode.body"].waitUntilExists(timeout: 10),
                      "The notebook opened")
        XCTAssertFalse(divider.exists, "with no pane beside the chat")
        XCTAssertFalse(app.descendants(matching: .any)["chat.input"].isHittable, "over the chat")
        hold()
        attachScreenCapture("chat-reader-phone")
    }

    // MARK: Helpers

    private func requirePad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Panes sit side by side on the iPad mini only")
        }
    }

    private var dividerValue: String { (divider.value as? String) ?? "" }

    /// The companion's width the divider reports, in points.
    private var dividerWidth: Int? {
        dividerValue.split(separator: " ").first.flatMap { Int($0) }
    }

    private func openChat(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: ["CHAT_ROUTES_NOTEBOOK_LINK": "1"], colorScheme: "dark", ready: nil)
        let window = app.windows.firstMatch
        XCTAssertTrue(waitFor((window.frame.width > window.frame.height) == !orientation.isPortrait), "The window turned")
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].waitUntilExists(timeout: 10), "The chat opened")
    }

    /// Shows or hides the shell's sidebar with its toggle.
    private func setSidebar(shown: Bool) {
        let sidebar = app.descendants(matching: .any)["workspace.sidebar.scroll"]
        var sidebarShows: Bool { sidebar.exists && sidebar.isHittable }
        guard sidebarShows != shown else { return }
        let toggle = app.buttons["workspace.split.sidebarToggle"].firstMatch
        XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "The sidebar toggle is in the bar")
        toggle.tap()
        XCTAssertTrue(waitFor(sidebarShows == shown), "The sidebar \(shown ? "shows" : "hid")")
        hold()
    }

    /// A link in the chat's replies, scrolled into reach.
    private func tapLink(_ label: String) {
        let link = app.links[label]
        let timeline = app.collectionViews["chat.timeline"]
        for _ in 0..<4 where !(link.exists && link.isHittable) {
            timeline.swipeUp()
        }
        XCTAssertTrue(link.waitUntilExists(timeout: 10) && link.isHittable, "The reply links \(label)")
        link.tap()
    }

    /// The screen's capture: in landscape `app.screenshot()` draws the iPad
    /// sideways into a portrait canvas.
    private func attachScreenCapture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
