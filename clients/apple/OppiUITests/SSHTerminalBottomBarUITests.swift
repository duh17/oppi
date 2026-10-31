import XCTest

/// The SSH terminal's bottom bar, customized from Settings and used in the
/// terminal (`SCREENSHOT_SCREEN=ssh-terminal`: the real terminal over an
/// in-memory host, which echoes every byte it receives into the readout
/// `sshTerminal.preview.sent`). Bottom Bar is one list; a custom key made there
/// is a button on the bar, and a tap on it writes its bytes to the host.
///
/// With `OPPI_BAR_SHOTS` set (pass `TEST_RUNNER_OPPI_BAR_SHOTS=<dir>` to
/// xcodebuild), each screenshot is also written there as a PNG.
@MainActor
final class SSHTerminalBottomBarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("SSH terminal bar tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    private func launch(screen: String) {
        app = OppiTestLaunch.makeApp()
        app.launchArguments += ["--screenshot-preview"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = "dark"
        app.launch()
        XCTAssertEqual(app.wait(for: .runningForeground, timeout: 10), true)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func attachScreenshot(_ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["OPPI_BAR_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// Swipes up, a bounded number of times, until `found` says the row is loaded:
    /// a list only has the cells near its visible part.
    private func scroll(until found: () -> Bool) {
        var swipes = 0
        while !found(), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
    }

    private func reveal(_ element: XCUIElement) {
        scroll { element.exists && element.isHittable }
    }

    private var customButtons: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshTerminal.bar.custom."))
    }

    private func openBottomBarSettings() {
        let more = app.buttons["sshTerminal.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "The terminal's … button did not appear")
        more.tap()
        let customize = app.buttons["sshTerminal.menu.customize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5), "The … menu did not open")
        customize.tap()
        XCTAssertTrue(element("settings.sshTerminal.bar.list").waitForExistence(timeout: 5), "Bottom Bar did not open")
    }

    /// Adds ⌃D named EOF for every program, from the list's Add Custom Key….
    private func addEOFKey() {
        let add = app.buttons["settings.sshTerminal.bar.addKey"]
        reveal(add)
        XCTAssertTrue(add.exists, "Add Custom Key… is not in the list")
        add.tap()
        let name = app.textFields["settings.sshTerminal.bar.key.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "The add screen did not open")
        let save = app.buttons["settings.sshTerminal.bar.key.save"]
        XCTAssertFalse(save.isEnabled, "Save waits for a key the terminal can send")
        name.tap()
        name.typeText("EOF")
        let control = app.buttons["settings.sshTerminal.bar.key.control"]
        control.tap()
        let key = app.textFields["settings.sshTerminal.bar.key.key"]
        key.tap()
        key.typeText("d")
        let preview = element("settings.sshTerminal.bar.key.preview")
        XCTAssertTrue(
            waitFor(preview.label.contains("\u{2303}D")),
            "The preview must show the combination: \(preview.label)"
        )
        XCTAssertTrue(save.isEnabled, "A valid combination enables Save")
        attachScreenshot("add-key")
        save.tap()
    }

    func testACustomKeyMadeInBottomBarSettingsIsOnTheBarAndSendsItsKey() {
        launch(screen: "ssh-terminal")
        XCTAssertTrue(app.buttons["sshTerminal.more"].waitForExistence(timeout: 10))
        attachScreenshot("bar-few-buttons")
        openBottomBarSettings()

        // One ordered list: no Middle and Right sections, one row per button,
        // Program Shortcuts among them.
        XCTAssertFalse(app.staticTexts["Middle"].exists)
        XCTAssertFalse(app.staticTexts["Right"].exists)
        for id in ["keyboard", "chatBar", "escape", "programShortcuts", "paste", "browseFiles", "herdr"] {
            let row = element("settings.sshTerminal.bar.row.\(id)")
            scroll { row.exists }
            XCTAssertTrue(row.exists, "The list has no \(id) row")
        }
        // Back to the top for the screenshot.
        for _ in 0..<4 { app.swipeDown() }
        attachScreenshot("settings-list")

        addEOFKey()
        let row = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.sshTerminal.bar.row.key."))
        scroll { row.count == 1 }
        XCTAssertTrue(waitFor(row.count == 1), "The new key must be a row in the list")
        XCTAssertTrue(row.element(boundBy: 0).label.contains("EOF"))
        XCTAssertTrue(row.element(boundBy: 0).label.contains("\u{2303}D"))
        attachScreenshot("settings-list-with-key")

        // Back in the terminal the key is on the bar, drawn as its short name.
        app.buttons["BackButton"].tap()
        XCTAssertTrue(waitFor(customButtons.count == 1), "The custom key must be on the bar")
        let eof = customButtons.element(boundBy: 0)
        XCTAssertEqual(eof.label, "EOF", "VoiceOver says the name")
        let sent = app.staticTexts["sshTerminal.preview.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        XCTAssertEqual(sent.label, "none", "Nothing has been sent yet")
        attachScreenshot("bar-with-custom-key")

        eof.tap()
        XCTAssertTrue(waitFor(sent.label == "04"), "Tapping EOF must send ^D (0x04): \(sent.label)")
        eof.tap()
        XCTAssertTrue(waitFor(sent.label == "04 04"), "Each tap sends once: \(sent.label)")
        assertRunning()
    }

    /// Turning on more of the list fills the pill from its centre, and what no
    /// longer fits goes to the … menu.
    func testManyButtonsFitTheWidthAndTheRestMoveIntoTheMenu() {
        launch(screen: "ssh-terminal")
        openBottomBarSettings()
        addEOFKey()
        // The list is scrolled to its end after adding; the switches are above.
        for _ in 0..<5 { app.swipeDown() }
        for id in ["escape", "interrupt", "tab", "up", "down", "enter", "programShortcuts", "paste"] {
            let toggle = app.switches["settings.sshTerminal.bar.\(id)"]
            reveal(toggle)
            XCTAssertTrue(toggle.exists, "No switch for \(id)")
            if (toggle.value as? String) != "1" { toggle.tap() }
        }
        app.buttons["BackButton"].tap()
        let more = app.buttons["sshTerminal.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sshTerminal.bar.keyboard"].waitForExistence(timeout: 5))
        attachScreenshot("bar-many-buttons")

        // Everything drawn sits between Back and the right edge, and the pill is not wider than that room.
        let back = app.buttons["sshTerminal.back"].frame
        XCTAssertGreaterThan(app.buttons["sshTerminal.bar.keyboard"].frame.minX, back.maxX, "The pill must not cover Back")
        XCTAssertLessThanOrEqual(more.frame.maxX, app.frame.maxX)
        more.tap()
        XCTAssertTrue(app.buttons["sshTerminal.menu.customize"].waitForExistence(timeout: 5))
        attachScreenshot("more-menu-overflow")
        assertRunning()
    }

    /// A Rex session with more than one pane keeps its pane switcher in a pill
    /// of its own at the bottom right; the bar's pill sits between Back and it.
    func testRexPaneSwitcherHasItsOwnPillAtTheTrailingCorner() {
        launch(screen: "ssh-terminal-rex-panes")
        let switcher = app.buttons["sshTerminal.bar.rexPanes"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "The pane switcher did not appear")
        let more = app.buttons["sshTerminal.more"]
        XCTAssertTrue(more.exists)
        XCTAssertGreaterThan(switcher.frame.minX, more.frame.maxX, "The switcher is past the bar's pill")
        XCTAssertGreaterThan(switcher.frame.minX, app.frame.width * 0.75, "The switcher sits at the trailing corner")
        XCTAssertGreaterThan(more.frame.minX, app.buttons["sshTerminal.back"].frame.maxX, "The pill clears Back")
        attachScreenshot("bar-rex-panes")

        // The icon says what the pane's program is doing: blocked (the second
        // pane), then resting (the third). The panel names this pane's status.
        let grid = element("sshTerminal.grid")
        grid.swipeLeft()
        XCTAssertTrue(waitFor((switcher.value as? String)?.hasPrefix("tail -f server.log, 2 of 3, Needs approval") == true), "The blocked pane speaks its status: \(switcher.value as? String ?? "nil")")
        attachScreenshot("rex-pill-blocked")
        switcher.tap()
        XCTAssertTrue(element("sshTerminal.rexPanel.thisPane").waitForExistence(timeout: 5))
        XCTAssertFalse(app.cells.staticTexts["No program status reported."].exists, "This pane lists the blocked program's status")
        attachScreenshot("rex-panel-blocked")
        app.buttons["Done"].firstMatch.tap()
        grid.swipeLeft()
        XCTAssertTrue(waitFor((switcher.value as? String)?.hasPrefix("\u{2733} Fixing the build, 3 of 3") == true))
        attachScreenshot("rex-pill-idle")
        assertRunning()
    }

    /// A Rex pane's one Rex control: a tap opens the panel (this pane's status,
    /// the session's panes, the other sessions); a pane picked there is shown,
    /// and another session's pane is opened. The preview has no host to dial,
    /// so `sshTerminal.preview.opened` reads which pane the panel asked for.
    func testRexPanelSwitchesPaneAndOpensAnotherSession() {
        launch(screen: "ssh-terminal-rex-panes")
        let switcher = app.buttons["sshTerminal.bar.rexPanes"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "The pane switcher did not appear")
        XCTAssertFalse(app.buttons["sshTerminal.programStatus"].exists, "A Rex pane has no separate status symbol")
        XCTAssertFalse(app.buttons["sshTerminal.rex"].exists, "A Rex pane has no separate Rex Sessions button")
        let pane = "\u{03C0} - oppi, 1 of 3"
        XCTAssertTrue(
            waitFor((switcher.value as? String).map { $0.hasPrefix(pane + ", ") } == true),
            "The icon speaks the program's status after the pane: \(switcher.value as? String ?? "nil")"
        )
        attachScreenshot("rex-pill-working")

        switcher.tap()
        XCTAssertTrue(element("sshTerminal.rexPanel.thisPane").waitForExistence(timeout: 5), "A tap must open the Rex panel")
        XCTAssertTrue(element("sshTerminal.rexPanel.panes").exists)
        attachScreenshot("rex-panel")
        // The sheet opens half height: the rest of the list is below its fold.
        scroll { element("sshTerminal.rexPanel.newPane").exists && element("sshTerminal.rexPanel.otherSessions").exists }
        XCTAssertTrue(element("sshTerminal.rexPanel.otherSessions").exists)
        XCTAssertTrue(element("sshTerminal.rexPanel.newPane").exists)
        // The host's other sessions arrive after the panel opens.
        let others = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshTerminal.rexPanel.session."))
        scroll { others.count == 2 }
        XCTAssertTrue(waitFor(others.count == 2, timeout: 10), "The panel must list the host's two other sessions")
        attachScreenshot("rex-panel-sessions")

        // A pane of this session is shown from the panel, and the panel closes.
        let logs = element("sshTerminal.rexPanel.pane.block:preview-logs")
        XCTAssertTrue(logs.waitForExistence(timeout: 5))
        logs.tap()
        XCTAssertTrue(
            waitFor((switcher.value as? String)?.hasPrefix("tail -f server.log, 2 of 3") == true),
            "The panel must show the pane it was asked for: \(switcher.value as? String ?? "nil")"
        )
        XCTAssertFalse(element("sshTerminal.rexPanel.panes").exists, "Picking a pane closes the panel")

        // Another session's pane opens through the panel.
        switcher.tap()
        XCTAssertTrue(element("sshTerminal.rexPanel.thisPane").waitForExistence(timeout: 5))
        scroll { others.count == 2 }
        XCTAssertTrue(waitFor(others.count == 2, timeout: 10))
        let dotfiles = others.containing(NSPredicate(format: "label CONTAINS %@", "dotfiles")).element(boundBy: 0)
        XCTAssertTrue(dotfiles.exists, "The dotfiles session is not in the panel")
        dotfiles.tap()
        let opened = app.staticTexts["sshTerminal.preview.opened"]
        XCTAssertTrue(waitFor(opened.label == "block:01a18a7e-911a-721b-a50b-14dfc0cc62cc"), "Opening a session opens the pane Rex types into there: \(opened.label)")
        assertRunning()
    }

    /// Bottom Bar settings, opened from a Rex pane, choose the panel's sections;
    /// a section turned off is gone from the panel.
    func testRexPanelSectionsFollowBottomBarSettings() {
        launch(screen: "ssh-terminal-rex-panes")
        openBottomBarSettings()
        let others = app.switches["settings.sshTerminal.bar.rexPanel.otherSessions"]
        reveal(others)
        XCTAssertTrue(others.exists, "No Rex panel choices in Bottom Bar")
        attachScreenshot("rex-settings")
        others.tap()
        app.buttons["BackButton"].tap()
        let switcher = app.buttons["sshTerminal.bar.rexPanes"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        switcher.tap()
        XCTAssertTrue(element("sshTerminal.rexPanel.panes").waitForExistence(timeout: 5))
        scroll { element("sshTerminal.rexPanel.newPane").exists }
        XCTAssertFalse(element("sshTerminal.rexPanel.otherSessions").exists, "Other Sessions was turned off")
        assertRunning()
    }

    private func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "The app must still be running", file: file, line: line)
    }
}
