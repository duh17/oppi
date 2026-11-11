import XCTest

/// The File Browser's tree toggle on the workspace route
/// (`SCREENSHOT_SCREEN=file-browser-column`): in regular width it tucks the
/// folder tree away so the open file takes the whole width, and brings it back.
@MainActor
final class FileBrowserTreeToggleUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    private static let screenshotDirectory = "/tmp/oppi-files-collapse"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private var toggle: XCUIElement { app.buttons["fileBrowser.treeToggle"] }
    private var treeRow: XCUIElement { app.buttons["fileBrowser.row.projects/garden.org"] }
    private var body: XCUIElement { app.descendants(matching: .any)["full-screen.org-mode.body"].firstMatch }
    private var window: XCUIElement { app.windows.firstMatch }

    private func launch(colorScheme: String = "dark", arguments: [String] = []) {
        launchPreview(screen: "file-browser-column", colorScheme: colorScheme, arguments: arguments, readyTimeout: 20)
        XCTAssertTrue(body.waitUntilExists(timeout: 20), "the Org file opens")
    }

    /// The button hides the tree and the file takes the window's width; again,
    /// the tree comes back beside it. The choice outlives a relaunch, and
    /// Command-Shift-L runs the same toggle.
    func testTheToggleGivesTheOpenFileTheWholeWidthAndBack() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The tree shows beside the file in regular width")
        XCUIDevice.shared.orientation = .portrait
        launch()
        XCTAssertTrue(toggle.waitUntilExists(timeout: 10), "the bar offers the tree toggle")
        XCTAssertTrue(treeRow.waitUntilExists(timeout: 10), "the tree lists the open file")
        let width = window.frame.width
        XCTAssertLessThan(body.frame.width, width * 0.6, "the file shares the width with the tree")
        XCTAssertGreaterThan(body.frame.minX, 250, "the file sits beside the tree")

        toggle.tap()
        XCTAssertTrue(waitFor(abs(self.body.frame.width - width) < 2), "hidden tree: the file takes the whole width (\(body.frame))")
        XCTAssertEqual(body.frame.minX, 0, accuracy: 2)
        XCTAssertTrue(treeRow.waitUntilGone(timeout: 5), "the tucked tree is out of reach")
        XCTAssertTrue(toggle.exists, "the toggle stays to bring it back")

        launch()
        XCTAssertTrue(waitFor(abs(self.body.frame.width - width) < 2), "the hidden tree stays hidden after a relaunch")

        toggle.tap()
        XCTAssertTrue(treeRow.waitUntilExists(timeout: 5), "the tree comes back")
        XCTAssertTrue(waitFor(self.body.frame.width < width * 0.6), "and the file makes room for it (\(body.frame))")

        hold()
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(abs(self.body.frame.width - width) < 2), "Command-Shift-L hides the tree")
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(self.body.frame.width < width * 0.6), "and shows it again")
    }

    /// Compact width has no tree beside the file, so there is nothing to toggle.
    func testCompactWidthOffersNoToggle() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Compact width is the phone's")
        XCUIDevice.shared.orientation = .portrait
        launch()
        XCTAssertFalse(toggle.exists, "compact width has no tree toggle")
        XCTAssertEqual(body.frame.width, window.frame.width, accuracy: 2, "the file takes the width as before")
        save("iphone-portrait-dark-compact")
    }

    /// The captures for review: portrait and landscape, light and dark, the
    /// default and the largest text size, with the tree shown and hidden, each
    /// at the top of the file and at its last lines.
    func testCapturesTheTreeShownAndHidden() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The tree shows beside the file in regular width")
        let sizes = [("default", "UICTContentSizeCategoryL"), ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")]
        for scheme in ["light", "dark"] {
            for (sizeName, category) in sizes {
                XCUIDevice.shared.orientation = .portrait
                launch(colorScheme: scheme, arguments: ["-UIPreferredContentSizeCategoryName", category])
                XCTAssertTrue(toggle.waitUntilExists(timeout: 10))
                for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                    XCUIDevice.shared.orientation = orientation
                    hold()
                    let name = orientation == .portrait ? "portrait" : "landscape"
                    let tag = "ipad-\(name)-\(scheme)-\(sizeName)"
                    XCTAssertTrue(treeRow.waitUntilExists(timeout: 5))
                    save("\(tag)-expanded")
                    toggle.tap()
                    XCTAssertTrue(treeRow.waitUntilGone(timeout: 5))
                    hold(for: 0.5)
                    save("\(tag)-collapsed")
                    if sizeName == "default" {
                        scrollToEnd()
                        save("\(tag)-collapsed-end")
                    }
                    toggle.tap()
                    XCTAssertTrue(treeRow.waitUntilExists(timeout: 5))
                    hold(for: 0.5)
                    if sizeName == "default" {
                        save("\(tag)-expanded-end")
                        body.swipeDown(velocity: .fast)
                        body.swipeDown(velocity: .fast)
                    }
                }
            }
        }
    }

    private func scrollToEnd() {
        for _ in 0..<25 { body.swipeUp(velocity: .fast) }
        hold()
    }

    /// The screen's capture, not the app's: in landscape `app.screenshot()`
    /// draws the iPad's interface sideways into a clipped canvas.
    private func save(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? FileManager.default.createDirectory(atPath: Self.screenshotDirectory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(
            to: URL(fileURLWithPath: "\(Self.screenshotDirectory)/\(name).png"),
            options: .atomic
        )
    }
}
