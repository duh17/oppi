import XCTest

/// Build plan §1.6 rule 4 in the production shell over the chat-routes
/// fixtures (`SCREENSHOT_SCREEN=pane-restore`): a file link's and a file
/// row's long-press menu opens the file in a new pane or in another pane,
/// and Undo takes either back. The iPad mini is the wide window; on the
/// phone the same menu has no pane items.
@MainActor
final class PaneLinkMenuUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    private let sessionRow = "session.nav.chat-routes-session"

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Pane tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    private var grips: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
    }


    /// The owner's ask: a file link in the chat opens in a pane of its own
    /// beside the chat, a second link replaces what that pane shows, and
    /// Undo brings the first file back.
    func testAChatFileLinkOpensInANewPaneAndAnotherLinkReplacesIt() throws {
        try openChat()
        let route = link("Route.md")
        route.press(forDuration: 1.2)
        let newPane = app.buttons["pane.open.newPane.right"]
        XCTAssertTrue(newPane.waitUntilExists(timeout: 5), "The link's menu offers Open in New Pane")
        XCTAssertTrue(app.buttons["pane.open.here"].exists, "and Open Here")
        XCTAssertFalse(app.buttons["pane.open.inPane"].exists, "With one pane there is no other pane to open in")
        attachScreenCapture("link-menu")
        newPane.tap()

        XCTAssertTrue(waitFor(self.grips.count == 2), "Open in New Pane made a second pane")
        let filePane = grips.matching(NSPredicate(format: "label ENDSWITH '2 of 2'")).firstMatch
        XCTAssertTrue(waitFor(filePane.label.contains("Route.md")), "The new pane shows Route.md: \(filePane.label)")
        XCTAssertEqual(filePane.value as? String, "Focused", "The new pane has focus")
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(composer.isHittable, "The chat stays beside it")
        XCTAssertLessThan(composer.frame.maxX, filePane.frame.minX, "The file is to the chat's right")
        hold()
        attachScreenCapture("link-split")

        link("Alpha.txt").press(forDuration: 1.2)
        let inPane = app.buttons["pane.open.inPane"]
        XCTAssertTrue(inPane.waitUntilExists(timeout: 5), "With two panes the menu offers Open in Pane")
        inPane.tap()
        let target = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.open.inPane.' AND label CONTAINS 'Route.md'")).firstMatch
        XCTAssertTrue(target.waitUntilExists(timeout: 5), "Open in Pane lists the file's pane by its title")
        attachScreenCapture("link-in-pane-menu")
        target.tap()
        XCTAssertTrue(waitFor(filePane.label.contains("Alpha.txt")), "The pane now shows Alpha.txt: \(filePane.label)")
        XCTAssertEqual(grips.count, 2, "in place of Route.md, with no new pane")
        attachScreenCapture("link-in-pane")

        let undo = app.buttons["pane.undo"]
        XCTAssertTrue(undo.waitUntilExists(timeout: 5), "The toast offers Undo")
        XCTAssertEqual(undo.label, "Undo Open in Pane")
        undo.tap()
        XCTAssertTrue(waitFor(filePane.label.contains("Route.md")), "Undo brought Route.md back: \(filePane.label)")
    }

    /// The owner's ask: a tapped file, folder and web link each open beside
    /// the chat, with the chat still in reach once the file closes.
    func testTappedLinksOpenBesideTheChatInLandscape() throws {
        try tapLinksOpenBesideTheChat(.landscapeLeft)
    }

    /// In portrait the window's room is below the chat, so a folder or web
    /// link's pane opens there; a file covers the chat until it closes.
    func testTappedLinksOpenBelowTheChatInPortrait() throws {
        try tapLinksOpenBesideTheChat(.portrait)
    }

    /// Touch and hold a link for the explicit places: Open in New Pane to the
    /// Right or Below and Open Here for a file, the two new panes beside Copy
    /// Link and Share for a web page. Open Here keeps the file in the main
    /// pane, over the chat, with no new pane.
    func testALinksMenuOffersRightBelowAndHere() throws {
        let pages = try startPages()
        try openChat(environment: ["CHAT_ROUTES_WEB_LINK": pages.url("one").absoluteString])
        link("Route.md").press(forDuration: 1.2)
        let below = app.buttons["pane.open.newPane.below"]
        XCTAssertTrue(below.waitUntilExists(timeout: 5), "The menu offers Open in New Pane Below")
        XCTAssertTrue(app.buttons["pane.open.newPane.right"].exists, "and to the Right")
        XCTAssertTrue(app.buttons["pane.open.here"].exists, "and Open Here")
        hold()
        attachScreenCapture("file-link-menu")
        below.tap()
        XCTAssertTrue(waitFor(self.grips.count == 2), "Below made a second pane")
        let filePane = grips.matching(NSPredicate(format: "label CONTAINS 'Route.md'")).firstMatch
        XCTAssertTrue(filePane.waitUntilExists(timeout: 5), "showing Route.md")
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertGreaterThanOrEqual(filePane.frame.minY, composer.frame.maxY - 1, "below the chat")
        hold()
        attachScreenCapture("file-link-below")

        let web = app.links["Open the preview"]
        XCTAssertTrue(web.waitUntilExists(timeout: 5))
        web.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["pane.open.newPane.right"].waitUntilExists(timeout: 5), "A web link offers a new pane")
        XCTAssertTrue(app.buttons["pane.open.newPane.below"].exists)
        XCTAssertFalse(app.buttons["pane.open.here"].exists, "its own open stands in for Open Here")
        XCTAssertFalse(app.buttons["pane.open.inPane"].exists, "no other pane takes a page")
        XCTAssertTrue(app.buttons["Copy Link"].exists, "beside Copy Link")
        hold()
        attachScreenCapture("web-link-menu")
        app.buttons["pane.open.newPane.right"].tap()
        XCTAssertTrue(app.webViews.staticTexts["First fixture page"].waitUntilExists(timeout: 15), "The page opened in a pane")
        XCTAssertTrue(waitFor(self.grips.count == 3), "in a third pane")

        let panes = grips.count
        link("Alpha.txt").press(forDuration: 1.2)
        let here = app.buttons["pane.open.here"]
        XCTAssertTrue(here.waitUntilExists(timeout: 5))
        here.tap()
        XCTAssertTrue(waitFor(self.grips.matching(NSPredicate(format: "label CONTAINS 'Alpha.txt'")).firstMatch.exists),
                      "Open Here showed Alpha.txt in the main pane")
        XCTAssertEqual(grips.count, panes, "with no new pane")
        hold()
        attachScreenCapture("file-link-here")
    }

    private func tapLinksOpenBesideTheChat(_ orientation: UIDeviceOrientation) throws {
        let pages = try startPages()
        try openChat(orientation: orientation, environment: ["CHAT_ROUTES_WEB_LINK": pages.url("one").absoluteString])
        let composer = app.descendants(matching: .any)["chat.input"]
        hold()
        attachScreenCapture("tap-\(orientation.isPortrait ? "portrait" : "landscape")-0-chat")

        // A file opens as a file pill does: in the chat's column, at its
        // reading width, or over the chat where the two do not fit.
        tapLink("Route.md")
        let readerClose = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(readerClose.waitUntilExists(timeout: 10), "The file link opened Route.md beside the chat")
        XCTAssertTrue(app.descendants(matching: .any)["pane.divider.0"].exists, "in the chat's column")
        XCTAssertFalse(grips.matching(NSPredicate(format: "label CONTAINS 'Route.md'")).firstMatch.exists,
                       "not in a pane of its own")
        hold()
        attachScreenCapture("tap-\(orientation.isPortrait ? "portrait" : "landscape")-1-file")
        readerClose.tap()
        XCTAssertTrue(readerClose.waitUntilGone(timeout: 5), "Close gives the chat the window back")

        tapLink("Sources")
        let folderRow = app.descendants(matching: .any)["fileBrowser.row.Sources/App.swift"]
        XCTAssertTrue(folderRow.waitUntilExists(timeout: 10), "The folder link opened Files in Sources")
        XCTAssertTrue(composer.isHittable, "The chat stays")
        hold()
        attachScreenCapture("tap-\(orientation.isPortrait ? "portrait" : "landscape")-2-folder")

        tapLink("Open the preview")
        XCTAssertTrue(app.webViews.staticTexts["First fixture page"].waitUntilExists(timeout: 15), "The web link opened its page")
        XCTAssertTrue(app.descendants(matching: .any)["browser.pane"].exists, "in a pane")
        XCTAssertFalse(app.descendants(matching: .any)["inAppBrowser.view"].exists, "not Safari's sheet")
        XCTAssertTrue(composer.isHittable, "The chat stays")
        hold()
        attachScreenCapture("tap-\(orientation.isPortrait ? "portrait" : "landscape")-3-web")
    }

    /// The iPad mini and a page server on the simulator's loopback, which
    /// stops with the test.
    private func startPages() throws -> BrowserFixtureServer {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Panes need a wide window; the iPad mini is the wide simulator")
        }
        let pages = try BrowserFixtureServer()
        addTeardownBlock { @MainActor in pages.stop() }
        return pages
    }

    /// A Files row's menu opens the file in a new pane, and Undo closes it.
    func testAFilesRowOpensInANewPaneAndUndoClosesIt() throws {
        try openChat()
        app.typeKey("d", modifierFlags: .command)
        let files = app.buttons["pane.launcher.files"]
        XCTAssertTrue(files.waitUntilExists(timeout: 5), "⌘D opened the launcher")
        files.tap()
        let row = app.descendants(matching: .any)["fileBrowser.row.Route.md"]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "Files fills the pane")
        XCTAssertEqual(grips.count, 2)

        row.press(forDuration: 1.2)
        let newPane = app.buttons["pane.open.newPane.right"]
        XCTAssertTrue(newPane.waitUntilExists(timeout: 5), "The row's menu offers Open in New Pane")
        XCTAssertTrue(app.buttons["fileBrowser.rowMenu.share"].exists, "beside the row's own Share")
        XCTAssertTrue(app.buttons["fileBrowser.rowMenu.copyPath"].exists, "and Copy Path")
        XCTAssertFalse(app.buttons["fileBrowser.rowMenu.open"].exists, "Open Here stands in for Open")
        attachScreenCapture("row-menu")
        newPane.tap()

        XCTAssertTrue(waitFor(self.grips.count == 3), "Open in New Pane made a third pane")
        let filePane = grips.matching(NSPredicate(format: "label CONTAINS 'Route.md'")).firstMatch
        XCTAssertTrue(filePane.waitUntilExists(timeout: 5), "showing Route.md")
        attachScreenCapture("row-split")

        let undo = app.buttons["pane.undo"]
        XCTAssertTrue(undo.waitUntilExists(timeout: 5), "The toast offers Undo")
        XCTAssertEqual(undo.label, "Undo Open in New Pane")
        undo.tap()
        XCTAssertTrue(waitFor(self.grips.count == 2), "Undo closed the new pane")
        XCTAssertTrue(row.exists, "and Files is as it was")
    }

    /// §1.5: a compact window has one pane, so a file link's menu offers no
    /// pane items.
    func testOnAPhoneAFileLinksMenuHasNoPaneItems() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Compact width is the phone's; the iPad mini is always wide")
        }
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "pane-restore", environment: [:], ready: nil)
        let session = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(session.waitUntilExists(timeout: 10), "The fixture session is listed")
        session.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].waitUntilExists(timeout: 10), "The chat opened")
        link("Route.md").press(forDuration: 1.2)
        hold()
        let paneItems = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.open.'"))
        XCTAssertEqual(paneItems.count, 0, "No pane items on a compact window")
    }

    private func openChat(orientation: UIDeviceOrientation = .landscapeLeft, environment: [String: String] = [:]) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Panes need a wide window; the iPad mini is the wide simulator")
        }
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: environment, colorScheme: "dark", ready: nil)
        let window = app.windows.firstMatch
        XCTAssertTrue(waitFor((window.frame.width > window.frame.height) == !orientation.isPortrait), "The window turned")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The shell came up")
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].waitUntilExists(timeout: 10), "The chat opened")
    }

    /// A file link in the chat's last reply.
    private func link(_ label: String) -> XCUIElement {
        let link = app.links[label]
        XCTAssertTrue(link.waitUntilExists(timeout: 10), "The reply links \(label)")
        return link
    }

    /// Taps a link in the chat's last replies, scrolling them into view when
    /// panes beside the chat left it short.
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
