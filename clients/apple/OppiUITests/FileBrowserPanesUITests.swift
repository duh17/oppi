import XCTest

/// The File Browser as two panes on the workspace route
/// (`SCREENSHOT_SCREEN=file-browser-column`, opened on a long Org file): the
/// folder list and the open file each have a pane and a bar of their own, with
/// the pane divider between them. On the iPad mini in landscape the two sit
/// side by side; the list collapses to the strip at the leading edge (a drag
/// or ⇧⌘L) and comes back by a tap on that strip. In portrait one shows at a
/// time: the file covers the list, and its Close goes back to the list.
@MainActor
final class FileBrowserPanesUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    /// Review captures, also attached to the result bundle.
    private static let screenshotDirectory = "/tmp/oppi-pane-3b2"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var treeRow: XCUIElement { app.buttons["fileBrowser.row.projects/garden.org"] }
    private var body: XCUIElement { app.descendants(matching: .any)["full-screen.org-mode.body"].firstMatch }
    private var close: XCUIElement { app.buttons["fileBrowser.reader.close"] }
    private var divider: XCUIElement { app.descendants(matching: .any)["pane.divider.0"] }
    private var window: XCUIElement { app.windows.firstMatch }

    private func launch(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "file-browser-column", colorScheme: "dark", readyTimeout: 20)
        XCTAssertTrue(body.waitUntilExists(timeout: 20), "the Org file opens")
    }

    /// Landscape: the list and the file side by side, each with its own bar
    /// (View Options on the list's, Close on the file's).
    /// Dragging the divider to the leading edge collapses the list to its
    /// strip; a tap on the strip brings it back; ⇧⌘L does the same; Close
    /// gives the list the window.
    func testTheListAndTheOpenFileArePanesThatCollapseAndRestore() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Panes sit side by side on the iPad mini")
        launch(.landscapeLeft)
        XCTAssertTrue(treeRow.waitUntilExists(timeout: 10), "the list shows the open file's folder")
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "the file's pane has its own Close")
        XCTAssertTrue(app.buttons["fileBrowser.viewOptions"].exists, "View Options is on the list's bar")
        let width = window.frame.width
        XCTAssertTrue(waitFor(self.body.frame.minX > self.treeRow.frame.maxX - 1), "the file sits beside the list")
        XCTAssertGreaterThanOrEqual(treeRow.frame.width, 374, "the list keeps an iPhone's width")
        save("ipad-landscape-two-panes")

        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)))
        XCTAssertTrue(waitFor(abs(self.body.frame.width - (width - 20)) < 4),
                      "dragged to the edge, the list collapses to its strip (\(body.frame))")
        XCTAssertFalse(treeRow.isHittable, "the collapsed list is out of reach")
        save("ipad-landscape-list-collapsed")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 8, dy: 0)).tap()
        XCTAssertTrue(waitFor(self.body.frame.minX > self.treeRow.frame.maxX - 1 && self.treeRow.isHittable),
                      "a tap on the strip brings the list back")

        hold()
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(abs(self.body.frame.width - (width - 20)) < 4), "⇧⌘L collapses the list")
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(self.treeRow.isHittable), "and brings it back")

        close.tap()
        XCTAssertTrue(body.waitUntilGone(timeout: 5), "Close closes the file's pane")
        XCTAssertTrue(waitFor(self.treeRow.frame.maxX > width - 80), "the list has the window again (\(treeRow.frame))")
        save("ipad-landscape-file-closed")
    }

    /// Portrait on the iPad mini has no room for both: the file opens full
    /// over the list, and Close goes back to the list.
    func testPortraitShowsOnePaneAtATime() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The file opens as a pane on the iPad mini")
        launch(.portrait)
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "the file's pane has its own Close")
        XCTAssertTrue(waitFor(self.body.frame.minX < 30), "the file covers the list (\(body.frame))")
        XCTAssertFalse(treeRow.isHittable, "the list is behind the file")
        save("ipad-portrait-file")
        close.tap()
        XCTAssertTrue(body.waitUntilGone(timeout: 5), "Close closes the file")
        XCTAssertTrue(treeRow.waitUntilExists(timeout: 5) && treeRow.isHittable, "the list shows")
        save("ipad-portrait-list")
    }

    /// Compact width keeps the push stack: a file kept open from a wide
    /// window shows as a sheet over the list, with no divider.
    func testCompactWidthShowsTheOpenFileAsASheet() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Compact width is the phone's")
        launch(.portrait)
        XCTAssertEqual(body.frame.width, window.frame.width, accuracy: 2, "the file takes the width")
        XCTAssertFalse(divider.exists, "there is no pane divider on a phone")
        XCTAssertTrue(close.exists, "the sheet closes with the file's Close")
        save("iphone-portrait-file")
    }

    /// The screen's capture, upright in landscape too: `app.screenshot()`
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
