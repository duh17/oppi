import XCTest

/// N7c on the production shell over the chat-routes fixtures
/// (`SCREENSHOT_SCREEN=pane-restore`): a sidebar row's long press offers Open
/// in New Pane, which opens that place beside the main pane with Undo, and a
/// sidebar row tapped while a side pane has focus changes the main pane and
/// leaves the side pane alone (the owner's answer for N7c: the sidebar always
/// targets the main pane). The iPad mini is the window: landscape shows the
/// split view's sidebar, portrait the drawer over the panes.
@MainActor
final class SidebarPaneMenuUITests: XCTestCase, PreviewUITestCase {
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

    /// A sidebar row's menu is the new panes: its tap is Open Here, and a place
    /// is no file another pane takes in place of what it shows. Choosing Right
    /// opens Terminal beside the main pane with focus, the sidebar row tapped
    /// next changes the main pane and leaves it as it was, and Undo takes the
    /// new pane back.
    func testASidebarRowsMenuOpensItsPlaceBesideAndATapChangesTheMainPane() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Panes need a wide window; the iPad mini is the wide simulator")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: [:], colorScheme: "dark", ready: nil)
        let window = app.windows.firstMatch
        XCTAssertTrue(waitFor(window.frame.width > window.frame.height), "The window turned")
        let terminal = app.buttons["workspace.terminal.open"]
        XCTAssertTrue(terminal.waitUntilExists(timeout: 10), "The sidebar lists Terminal")

        terminal.press(forDuration: 1.2)
        let right = app.buttons["pane.open.newPane.right"]
        XCTAssertTrue(right.waitUntilExists(timeout: 5), "The row's menu offers Open in New Pane to the Right")
        XCTAssertTrue(app.buttons["pane.open.newPane.below"].exists, "and Below")
        XCTAssertFalse(app.buttons["pane.open.here"].exists, "The row's tap is its Open Here")
        XCTAssertFalse(app.buttons["pane.open.inPane"].exists, "No other pane takes a place in place of what it shows")
        hold()
        attachScreenCapture("sidebar-row-menu")
        right.tap()

        XCTAssertTrue(waitFor(grips.count == 2), "Open in New Pane made a second pane")
        let terminalPane = grips.matching(NSPredicate(format: "label ENDSWITH '2 of 2'")).firstMatch
        XCTAssertTrue(terminalPane.waitUntilExists(timeout: 5), "The new pane is the second one")
        XCTAssertTrue(waitFor(terminalPane.label.contains("Terminal")), "The new pane shows Terminal: \(terminalPane.label)")
        XCTAssertEqual(terminalPane.value as? String, "Focused", "The new pane has focus")
        XCTAssertTrue(app.buttons["sshTerminal.host.add"].waitUntilExists(timeout: 10),
                      "Terminal's host list opened beside the main pane")
        XCTAssertTrue(terminal.isSelected == false, "The sidebar highlights the main pane's place, not the new pane")
        hold()
        attachScreenCapture("sidebar-new-pane")

        // The sidebar targets the main pane whatever has focus: the Terminal pane
        // keeps its screen and its focus, and the highlight moves to the place
        // the tap put in the main pane.
        let workspace = app.buttons["workspace.open.routes-workspace"]
        XCTAssertTrue(workspace.waitUntilExists(timeout: 5), "The sidebar lists the workspace")
        workspace.tap()
        XCTAssertTrue(app.descendants(matching: .any)[sessionRow].waitUntilExists(timeout: 10),
                      "The main pane shows the workspace's sessions")
        XCTAssertTrue(waitFor(workspace.isSelected), "The sidebar highlights the main pane's place")
        XCTAssertEqual(grips.count, 2, "The tap neither added nor closed a pane")
        XCTAssertEqual(terminalPane.value as? String, "Focused", "The Terminal pane kept its focus")
        XCTAssertTrue(app.buttons["sshTerminal.host.add"].exists, "and its screen")
        hold()
        attachScreenCapture("sidebar-main-pane-changed")

        let undo = app.buttons["pane.undo"]
        XCTAssertTrue(undo.waitUntilExists(timeout: 5), "The toast offers Undo")
        XCTAssertEqual(undo.label, "Undo Open in New Pane")
        undo.tap()
        XCTAssertTrue(waitFor(grips.count == 0), "Undo closed the new pane")
        XCTAssertTrue(app.descendants(matching: .any)[sessionRow].exists, "and left the main pane as the tap left it")
    }

    /// Portrait on the iPad mini: the drawer opens over two panes (its button
    /// sits in the main pane's bar, which focuses that pane as any touch there
    /// does), and a row tapped there opens in the main pane while the file pane
    /// keeps its screen and takes no focus.
    func testInPortraitTheDrawersRowsOpenInTheMainPaneAndLeaveTheSidePane() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The drawer covers splittable panes on the iPad mini in portrait")
        }
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: [:], colorScheme: "dark", ready: nil)
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].waitUntilExists(timeout: 10), "The chat opened")

        // A file pane below the chat, the pane Open in New Pane leaves focused.
        let link = app.links["Route.md"]
        XCTAssertTrue(link.waitUntilExists(timeout: 10), "The reply links Route.md")
        link.press(forDuration: 1.2)
        let below = app.buttons["pane.open.newPane.below"]
        XCTAssertTrue(below.waitUntilExists(timeout: 5), "The link's menu offers Open in New Pane Below")
        below.tap()
        XCTAssertTrue(waitFor(grips.count == 2), "Below made a second pane")
        let filePane = grips.matching(NSPredicate(format: "label CONTAINS 'Route.md'")).firstMatch
        XCTAssertTrue(filePane.waitUntilExists(timeout: 5), "The file pane shows Route.md")
        XCTAssertEqual(filePane.value as? String, "Focused", "The file pane has focus")

        let open = app.buttons["workspace.sidebar.open"]
        XCTAssertTrue(open.waitUntilExists(timeout: 5), "Portrait shows the drawer's button")
        open.tap()
        let sidebar = app.descendants(matching: .any)["workspace.sidebar.scroll"]
        XCTAssertTrue(waitFor(sidebar.exists && sidebar.isHittable), "The drawer opened")
        hold()
        attachScreenCapture("portrait-drawer")

        let place = app.buttons["workspace.terminal.open"]
        XCTAssertTrue(place.waitUntilExists(timeout: 5), "The drawer lists Terminal")
        place.tap()
        XCTAssertTrue(app.buttons["sshTerminal.host.add"].waitUntilExists(timeout: 10), "Terminal opened in the main pane")
        XCTAssertTrue(waitFor(!sidebar.isHittable), "The drawer closed over the open it made")
        XCTAssertEqual(grips.count, 2, "The tap neither added nor closed a pane")
        XCTAssertTrue(filePane.label.contains("Route.md"), "The file pane kept its screen: \(filePane.label)")
        XCTAssertNotEqual(filePane.value as? String, "Focused", "The row tap put no focus in the side pane")
        hold()
        attachScreenCapture("portrait-main-changed")
    }

    /// The screen's capture: in landscape `app.screenshot()` draws the iPad
    /// sideways into a portrait canvas.
    private func attachScreenCapture(_ name: String) {
        let attachment = XCTAttachment(uprightScreenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
