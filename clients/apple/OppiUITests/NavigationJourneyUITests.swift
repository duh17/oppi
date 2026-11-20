import XCTest

/// Getting home through the sidebar's places, in the real workspace shell over
/// fixture services (`SCREENSHOT_SCREEN=workspace-shell`). All Sessions is the
/// first sidebar row and is selected while it is the window's place; picking it
/// makes All Sessions the main pane's root again. A workspace's list has no
/// control of its own back to All Sessions.
@MainActor
final class NavigationJourneyUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!
    static var reusesLaunch: Bool { true }

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Navigation journeys are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// iPad mini in landscape, the split view: Agents → All Sessions by the
    /// sidebar row; a workspace's list shows no chevron to All Sessions; from a
    /// chat opened there, the sidebar button and the row lead home.
    func testSplitSidebarAllSessionsRowGoesHomeFromAPlaceAndAChat() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The split view needs the iPad mini in landscape")
        launchShell(orientation: .landscapeLeft)
        let allSessions = app.buttons["workspace.allSessions.open"]
        let agents = app.buttons["workspace.agents.open"]
        XCTAssertTrue(allSessions.waitUntilExists(timeout: 5), "The sidebar has no All Sessions row")
        assertFirstPlace(allSessions)
        XCTAssertTrue(allSessions.isSelected, "All Sessions must be selected while it shows")
        attachScreenshot("sidebar-ipad-landscape")

        agents.tap()
        let agentsBar = app.navigationBars["Agents"]
        XCTAssertTrue(agentsBar.waitUntilExists(timeout: 5), "Agents did not open")
        XCTAssertTrue(waitFor(agents.isSelected && !allSessions.isSelected), "The selection must move to Agents")

        allSessions.tap()
        XCTAssertTrue(agentsBar.waitUntilGone(timeout: 5), "All Sessions must replace Agents")
        XCTAssertTrue(app.searchFields["Search sessions"].waitUntilExists(timeout: 5), "All Sessions did not show")
        XCTAssertTrue(waitFor(allSessions.isSelected && !agents.isSelected), "The selection must move back to All Sessions")
        assertRunning()

        app.buttons["workspace.open.oppi"].tap()
        let session = app.buttons["session.nav.rail-2"]
        XCTAssertTrue(session.waitUntilExists(timeout: 10), "The workspace's sessions did not show")
        XCTAssertFalse(allSessions.isSelected, "The workspace, not All Sessions, is the place")
        XCTAssertFalse(showWorkspacesControl.exists, "A workspace's list must not offer its own way back to All Sessions")
        attachScreenshot("sidebar-ipad-landscape-workspace")

        session.tap()
        XCTAssertTrue(app.buttons["chat.toolbar.back"].waitUntilExists(timeout: 10), "The chat did not open")
        let toggle = app.buttons["workspace.split.sidebarToggle"].firstMatch
        XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "The chat has no sidebar button")
        XCTAssertTrue(waitFor(!isShowing(allSessions)), "The sidebar hides beside a chat")
        toggle.tap()
        XCTAssertTrue(waitFor(isShowing(allSessions)), "The sidebar button did not show the sidebar")
        allSessions.tap()
        XCTAssertTrue(app.buttons["chat.toolbar.back"].waitUntilGone(timeout: 5), "All Sessions must replace the chat")
        XCTAssertTrue(app.searchFields["Search sessions"].waitUntilExists(timeout: 5), "All Sessions did not show")
        XCTAssertTrue(waitFor(allSessions.isSelected), "All Sessions must be selected again")
        assertRunning()
    }

    /// The compact shell (iPhone, and the iPad mini in portrait): the drawer
    /// starts with All Sessions, selected at the stack's root; after a place
    /// opened from the drawer, its row brings All Sessions back as the root.
    func testDrawerAllSessionsRowIsHome() {
        launchShell(orientation: .portrait)
        let drawerButton = app.buttons["workspace.sidebar.open"]
        let allSessions = app.buttons["workspace.allSessions.open"]
        XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "The compact shell has no drawer button")
        drawerButton.tap()
        XCTAssertTrue(waitFor(isShowing(allSessions)), "The drawer has no All Sessions row")
        assertFirstPlace(allSessions)
        XCTAssertTrue(allSessions.isSelected, "All Sessions must be selected at the stack's root")
        attachScreenshot("drawer-compact")

        app.buttons["workspace.agents.open"].tap()
        let agentsBar = app.navigationBars["Agents"]
        XCTAssertTrue(agentsBar.waitUntilExists(timeout: 5), "Agents did not open from the drawer")
        // The sidebar button belongs to the main pane: on iPad on every screen
        // of it, on iPhone at its root alone.
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "Agents pushed on the iPad keeps the sidebar button")
        } else {
            XCTAssertTrue(drawerButton.waitUntilGone(timeout: 5), "Agents pushed on a phone has Back alone")
        }
        hold()
        attachScreenshot("drawer-compact-pushed")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "Back must return to All Sessions")

        drawerButton.tap()
        XCTAssertTrue(waitFor(isShowing(allSessions)), "The drawer did not open again")
        allSessions.tap()
        XCTAssertTrue(waitFor(!isShowing(allSessions)), "Picking All Sessions must close the drawer")
        XCTAssertTrue(drawerButton.isHittable, "All Sessions must be the stack's root")
        XCTAssertTrue(app.searchFields["Search sessions"].exists, "All Sessions did not show")
        assertRunning()
    }

    /// iPad mini in landscape: the sidebar hidden from the Rex list, a pane's
    /// terminal pushed over it; the sidebar button beside the terminal's Back
    /// shows the sidebar, and All Sessions replaces the terminal.
    func testSplitSidebarButtonOnARexTerminalGoesHome() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The split view needs the iPad mini in landscape")
        launchRex(orientation: .landscapeLeft)
        let allSessions = app.buttons["workspace.allSessions.open"]
        let toggle = app.buttons["workspace.split.sidebarToggle"].firstMatch
        app.buttons["workspace.rex.open"].tap()
        let session = app.buttons[Self.rexRow]
        XCTAssertTrue(session.waitUntilExists(timeout: 15), "The Rex list shows the host's sessions")
        XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "The Rex list has the sidebar button")
        toggle.tap()
        XCTAssertTrue(waitFor(!isShowing(allSessions)), "The sidebar button hid the sidebar")

        session.tap()
        let grid = app.descendants(matching: .any)["sshTerminal.grid"]
        XCTAssertTrue(grid.waitUntilExists(timeout: 15), "The session's terminal opened")
        let back = app.buttons["sshTerminal.back"]
        XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "The terminal has the sidebar button")
        XCTAssertGreaterThan(toggle.frame.minX, back.frame.maxX - 1, "It follows the terminal's Back")
        XCTAssertEqual(toggle.frame.midY, back.frame.midY, accuracy: 2, "It sits in Back's row")
        hold()
        attachScreenshot("rex-terminal-ipad-landscape")

        toggle.tap()
        XCTAssertTrue(waitFor(isShowing(allSessions)), "The sidebar button showed the sidebar over the terminal's stack")
        XCTAssertTrue(grid.exists, "Showing the sidebar keeps the terminal")
        hold()
        attachScreenshot("rex-terminal-ipad-landscape-sidebar")
        allSessions.tap()
        XCTAssertTrue(grid.waitUntilGone(timeout: 5), "All Sessions replaced the terminal")
        XCTAssertTrue(app.searchFields["Search sessions"].waitUntilExists(timeout: 5), "All Sessions did not show")
        XCTAssertTrue(waitFor(allSessions.isSelected), "All Sessions is the place again")
        assertRunning()
    }

    /// iPad mini in portrait: the drawer opens from the terminal pushed over the
    /// Rex list, and its All Sessions row goes home.
    func testDrawerOpensFromARexTerminalOnTheIPadInPortrait() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Every screen has the button on the iPad mini")
        launchRex(orientation: .portrait)
        let drawerButton = app.buttons["workspace.sidebar.open"].firstMatch
        let allSessions = app.buttons["workspace.allSessions.open"]
        XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "All Sessions has the drawer button")
        drawerButton.tap()
        XCTAssertTrue(waitFor(isShowing(allSessions)), "The drawer opened")
        app.buttons["workspace.rex.open"].tap()
        let session = app.buttons[Self.rexRow]
        XCTAssertTrue(session.waitUntilExists(timeout: 15), "The Rex list shows the host's sessions")
        XCTAssertTrue(waitFor(!isShowing(allSessions)), "Picking Rex closed the drawer")
        hold()

        session.tap()
        let grid = app.descendants(matching: .any)["sshTerminal.grid"]
        XCTAssertTrue(grid.waitUntilExists(timeout: 15), "The session's terminal opened")
        XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "The terminal has the drawer button")
        XCTAssertGreaterThan(drawerButton.frame.minX, app.buttons["sshTerminal.back"].frame.maxX - 1, "It follows the terminal's Back")
        hold()
        attachScreenshot("rex-terminal-ipad-portrait")

        drawerButton.tap()
        XCTAssertTrue(waitFor(isShowing(allSessions)), "The drawer opened over the terminal")
        hold()
        attachScreenshot("rex-terminal-ipad-portrait-drawer")
        allSessions.tap()
        XCTAssertTrue(grid.waitUntilGone(timeout: 5), "All Sessions replaced the terminal")
        XCTAssertTrue(waitFor(!isShowing(allSessions)), "Picking All Sessions closed the drawer")
        XCTAssertTrue(app.searchFields["Search sessions"].waitUntilExists(timeout: 5), "All Sessions did not show")
        hold()
        assertRunning()
    }

    private static let rexRow = "sshTerminal.rexList.5E5E5E5E-0000-4000-8000-000000000001.session:01a18a26-6620-76be-b529-4d9ad2b36c63"

    /// The production shell over the chat-routes fixtures with a fake Rex in
    /// process (`RexPaneUITests`), so the Rex list and its terminal are real.
    private func launchRex(orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(
            screen: "pane-restore",
            environment: ["PANE_RESTORE_REX": "1"],
            colorScheme: "dark",
            ready: nil
        )
        if orientation.isLandscape {
            XCTAssertTrue(app.buttons["workspace.rex.open"].waitUntilExists(timeout: 10), "The sidebar offers Rex")
        }
    }

    /// A beat for a recording to show each step.
    private func hold() {
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func isShowing(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable
    }

    /// The workspace list's former chevron, by its label. The compact shell's
    /// drawer button shares the label; the split view has no drawer.
    private var showWorkspacesControl: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Show workspaces")).firstMatch
    }

    /// `row` is above every other place row in the sidebar.
    private func assertFirstPlace(_ row: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for other in ["workspace.agents.open", "workspace.schedules.open", "workspace.extensions.open"] {
            let element = app.buttons[other]
            guard element.exists else { continue }
            XCTAssertLessThan(row.frame.minY, element.frame.minY, "All Sessions must come before \(other)", file: file, line: line)
        }
    }

    private func launchShell(orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        launchPreview(
            screen: "workspace-shell",
            colorScheme: "dark",
            ready: nil
        )
        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitUntilExists(timeout: 10),
            "The workspace shell did not appear"
        )
    }
}
