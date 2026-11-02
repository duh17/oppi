import XCTest

/// The Terminal page's mode: what it lists, and the button that switches it. Rex is
/// an experiment, so the button only exists while Rex is on; with both off the page
/// is Shell and says nothing about a mode.
///
/// `ssh-hosts-mode` pins no mode, so the page opens on the one its experiments allow
/// and a choice can be made; `ssh-hosts` and `ssh-hosts-rex` pin one for captures.
@MainActor
final class SSHTerminalModeUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Terminal mode tests are simulator-only")
#endif
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(page: String, rex: Bool, herdr: Bool = false) {
        launchPreview(
            screen: "settings-sweep",
            environment: ["SCREENSHOT_SWEEP_PAGE": page],
            colorScheme: "dark",
            arguments: OppiTestLaunch.experimentArguments([.rex: rex, .herdr: herdr])
        )
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// A choice in the mode menu. Scoped to buttons whose whole label is the mode's name,
    /// and to the ones on screen while the menu is open: every row of the list behind it
    /// is named for its host, and its identifiers are scoped (`sshTerminal.…`), so an
    /// unticked check cannot pass by matching a row that happens to read Shell.
    private func menuItem(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND enabled == true", title)).firstMatch
    }

    private var hostRows: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshTerminal.host.row."))
    }

    private var rexHeaders: XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "sshTerminal.rexList.", ".header"))
    }

    /// With Rex on, the page opens on Rex: no host rows, and the mode button offers
    /// Shell. Choosing it lists the saved hosts and takes the Rex sections away.
    func testTheModeButtonSwitchesBetweenRexAndShell() {
        launch(page: "ssh-hosts-mode", rex: true)
        XCTAssertTrue(app.buttons["sshTerminal.mode"].waitUntilExists(timeout: 10), "Rex on: the page has no mode button")
        XCTAssertTrue(element("sshTerminal.mode").waitUntilExists(timeout: 5))
        // Rex first: every saved host's section, and no plain host row to open.
        XCTAssertTrue(waitFor(!rexHeaders.allElementsBoundByIndex.isEmpty), "Rex mode must list the hosts' Rex sections")
        XCTAssertEqual(hostRows.count, 0, "Rex mode lists panes, not host rows")
        attachScreenshot("terminal-page-rex")

        // The button is a glyph, so the menu is where the mode is written out: it
        // ticks the one on screen and leaves the other unticked.
        app.buttons["sshTerminal.mode"].tap()
        let rex = menuItem("Rex")
        let shell = menuItem("Shell")
        XCTAssertTrue(rex.waitUntilExists(timeout: 5), "The mode menu must offer Rex")
        XCTAssertTrue(rex.isHittable, "the menu item is on screen")
        XCTAssertTrue(shell.exists && shell.isHittable, "The mode menu must offer Shell")
        XCTAssertTrue(rex.isSelected, "The menu must tick the mode on screen")
        XCTAssertFalse(shell.isSelected, "Only the mode on screen is ticked")
        attachScreenshot("terminal-page-mode-menu")
        shell.tap()
        XCTAssertTrue(waitFor(hostRows.count == 2), "Shell mode must list the saved hosts: \(hostRows.count)")
        XCTAssertTrue(waitFor(rexHeaders.allElementsBoundByIndex.isEmpty), "Shell mode must drop the Rex sections")
        attachScreenshot("terminal-page-shell")

        // And the tick follows the choice.
        app.buttons["sshTerminal.mode"].tap()
        let shellAgain = menuItem("Shell")
        XCTAssertTrue(shellAgain.waitUntilExists(timeout: 5), "The mode menu must open again")
        XCTAssertTrue(shellAgain.isSelected, "The menu must tick the mode now on screen")
        XCTAssertFalse(menuItem("Rex").isSelected, "The mode left behind is unticked")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        assertRunning()
    }

    /// Rex mode's sections offer what the spec asks of them: a session's ⊕ New Pane,
    /// its collapse chevron, and the host heading's ⋯ with New Session. One session
    /// is left open and the other collapsed, which is what the capture shows.
    func testRexSectionsOfferNewPaneNewSessionAndACollapseChevron() {
        let hostID = "5E5E5E5E-0000-4000-8000-000000000001"
        let oppi = "session:01a18a26-6620-76be-b529-4d9ad2b36c63"
        let dotfiles = "session:01a18a26-6620-76be-b529-4d9ad2b36c64"
        launchPreview(
            screen: "ssh-terminal-rex-list",
            colorScheme: "dark",
            arguments: OppiTestLaunch.experimentArguments([.rex: true])
        )
        let prefix = "sshTerminal.rexList.\(hostID)."
        XCTAssertTrue(app.buttons[prefix + oppi].waitUntilExists(timeout: 15), "The Rex section did not list its sessions")

        // The session's own ⊕ adds a pane to it.
        XCTAssertTrue(app.buttons[prefix + oppi + ".newPane"].exists, "A session has no ⊕ New Pane")
        // The heading is the host in Rex mode, so its ⋯ carries New Session.
        let menu = app.buttons[prefix + "menu"]
        XCTAssertTrue(menu.waitUntilExists(timeout: 5), "The host heading has no ⋯ menu")
        menu.tap()
        // The ＋ in the bar is titled New Session too, so the item is the element with
        // that label that is not the bar button.
        let newSession = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "New Session", "sshTerminal.page.newSession")
        ).firstMatch
        XCTAssertTrue(newSession.waitUntilExists(timeout: 5), "The host heading must offer New Session")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()

        // One session open, the other closed: the chevron says which.
        let openDisclosure = app.buttons[prefix + oppi + ".disclosure"]
        XCTAssertEqual(openDisclosure.value as? String, "Collapsed")
        openDisclosure.tap()
        XCTAssertTrue(waitFor((openDisclosure.value as? String) == "Expanded"), "The chevron must expand the session")
        XCTAssertEqual(app.buttons[prefix + dotfiles + ".disclosure"].value as? String, "Collapsed")
        XCTAssertTrue(app.cells[prefix + "block:01a18a7e-911a-721b-a50b-14dfc0cc62ca"].waitUntilExists(timeout: 5), "The open session lists its panes")
        attachScreenshot("terminal-page-rex-panes")

        // The mode toolbar floats over the list; the last row still has to be reachable
        // rather than kept under it. Scroll to the end first, so the claim is about the
        // bottom of the list and not about wherever it happened to be.
        let disclosures = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", ".disclosure"))
        XCTAssertGreaterThanOrEqual(disclosures.count, 2, "Both hosts' sessions are on the page")
        for _ in 0..<6 { app.swipeUp() }
        let last = try? XCTUnwrap(disclosures.allElementsBoundByIndex.last)
        XCTAssertEqual(last?.isHittable, true, "The last row must scroll clear of the mode toolbar")
        attachScreenshot("terminal-page-rex-bottom")
        assertRunning()
    }

    /// Both experiments off: the page is Shell, with no button to say so.
    func testThereIsNoModeButtonWhenBothExperimentsAreOff() {
        launch(page: "ssh-hosts-mode", rex: false, herdr: false)
        XCTAssertTrue(hostRows.firstMatch.waitUntilExists(timeout: 10), "Shell mode must list the saved hosts")
        XCTAssertFalse(app.buttons["sshTerminal.mode"].exists, "No mode choice: no mode button")
        attachScreenshot("terminal-page-no-mode")
        assertRunning()
    }
}
