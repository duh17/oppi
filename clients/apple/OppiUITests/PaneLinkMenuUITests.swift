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
        let newPane = app.buttons["pane.open.newPane"]
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
        let newPane = app.buttons["pane.open.newPane"]
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

    private func openChat() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Panes need a wide window; the iPad mini is the wide simulator")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: [:], ready: nil)
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

    /// The screen's capture: in landscape `app.screenshot()` draws the iPad
    /// sideways into a portrait canvas.
    private func attachScreenCapture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
