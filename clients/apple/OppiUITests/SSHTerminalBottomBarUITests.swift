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
final class SSHTerminalBottomBarUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!
    static var reusesLaunch: Bool { true }

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("SSH terminal bar tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// Every screen this class drives is Rex or Herdr: both are experiments
    /// (Settings → Experiments), off by default, so the launch asks for both.
    private func launch(screen: String) {
        launchPreview(
            screen: screen,
            colorScheme: "dark",
            arguments: OppiTestLaunch.experimentArguments([.rex: true, .herdr: true]),
            ready: nil
        )
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

    /// Scrolls the Customize sheet back up until `element` shows. Only while it
    /// is not there: a swipe down on a list already at its top closes the sheet.
    private func scrollBack(to element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 6 {
            app.swipeDown()
            swipes += 1
        }
    }

    /// Done closes Customize, a sheet over the terminal.
    private func closeBottomBarSettings() {
        let done = app.buttons["barCustomize.done"]
        XCTAssertTrue(done.waitUntilExists(timeout: 5), "Customize has no Done")
        done.tap()
        XCTAssertTrue(element("settings.sshTerminal.bar.list").waitUntilGone(timeout: 5), "Done did not close Customize")
    }

    private var customButtons: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshTerminal.bar.custom."))
    }

    private func openBottomBarSettings() {
        let more = app.buttons["sshTerminal.more"]
        XCTAssertTrue(more.waitUntilExists(timeout: 10), "The terminal's … button did not appear")
        more.tap()
        let customize = app.buttons["sshTerminal.menu.customize"]
        XCTAssertTrue(customize.waitUntilExists(timeout: 5), "The … menu did not open")
        customize.tap()
        XCTAssertTrue(element("settings.sshTerminal.bar.list").waitUntilExists(timeout: 5), "Bottom Bar did not open")
    }

    /// Adds ⌃D named EOF for every program, from the list's Add Custom Key….
    private func addEOFKey() {
        let add = app.buttons["settings.sshTerminal.bar.addKey"]
        reveal(add)
        XCTAssertTrue(add.exists, "Add Custom Key… is not in the list")
        add.tap()
        let name = app.textFields["settings.sshTerminal.bar.key.name"]
        XCTAssertTrue(name.waitUntilExists(timeout: 5), "The add screen did not open")
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

    /// Dictate over a scripted recogniser (`ssh-terminal-dictation`, a shell
    /// that asked for bracketed paste): stable words reach the host while the
    /// take still listens, the words still changing show above the bar, and
    /// Stop types the rest. Nothing sent is a backspace or a Return.
    ///
    /// With `OPPI_DICTATION_SHOTS` set (pass `TEST_RUNNER_OPPI_DICTATION_SHOTS=<dir>`),
    /// a frame every half second of the take is written there as a PNG.
    func testDictateTypesStableWordsWhileTheTakeListens() {
        launch(screen: "ssh-terminal-dictation")
        let dictate = element("sshTerminal.bar.dictate")
        XCTAssertTrue(dictate.waitUntilExists(timeout: 10))
        let sent = app.staticTexts["sshTerminal.preview.sent"]
        XCTAssertTrue(sent.waitUntilExists(timeout: 5))
        let shots = ProcessInfo.processInfo.environment["OPPI_DICTATION_SHOTS"]
        var frame = 0
        func shoot() {
            guard let shots else { return }
            try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
            let path = URL(fileURLWithPath: shots).appendingPathComponent(String(format: "frame-%03d.png", frame))
            try? app.screenshot().pngRepresentation.write(to: path)
            frame += 1
        }
        shoot()
        dictate.tap()

        let tail = element("sshTerminal.dictationTail")
        XCTAssertTrue(tail.waitUntilExists(timeout: 5), "the words being heard show above the bar")
        let bracketed = "1B 5B 32 30 30 7E"
        var typedWhileListening = false
        let deadline = Date().addingTimeInterval(14)
        while Date() < deadline, !(tail.exists && tail.label.hasSuffix("adding retries")) {
            shoot()
            if sent.label.contains(bracketed), dictate.label == "Stop dictation" { typedWhileListening = true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(typedWhileListening, "stable words reach the shell, bracketed, while the take listens: \(sent.label)")
        XCTAssertTrue(tail.label.hasSuffix("adding retries"), "the last phrase is still a guess: \(tail.label)")
        attachScreenshot("dictation-listening")

        dictate.tap()
        XCTAssertTrue(tail.waitUntilGone(timeout: 5))
        XCTAssertTrue(waitFor(dictate.label == "Dictate"))
        shoot()
        attachScreenshot("dictation-stopped")
        let bytes = sent.label.split(separator: " ")
        XCTAssertFalse(bytes.contains("7F") || bytes.contains("08") || bytes.contains("0D") || bytes.contains("0A"),
                       "no backspace and no Return: \(sent.label)")
        // "with", a guess the recogniser replaced by "without", is never sent as a word of its own.
        let withAlone = "20 77 69 74 68 1B"
        XCTAssertFalse(sent.label.contains(withAlone), "a dropped guess was typed: \(sent.label)")
        assertRunning()
    }

    func testACustomKeyMadeInBottomBarSettingsIsOnTheBarAndSendsItsKey() {
        launch(screen: "ssh-terminal")
        XCTAssertTrue(app.buttons["sshTerminal.more"].waitUntilExists(timeout: 10))
        attachScreenshot("bar-few-buttons")
        openBottomBarSettings()

        // One ordered list: no Middle and Right sections, one row per button,
        // Program Shortcuts among them.
        XCTAssertFalse(app.staticTexts["Middle"].exists)
        XCTAssertFalse(app.staticTexts["Right"].exists)
        for id in ["keyboard", "dictate", "attach", "escape", "programShortcuts", "paste", "browseFiles", "herdr"] {
            let row = element("settings.sshTerminal.bar.row.\(id)")
            scroll { row.exists }
            XCTAssertTrue(row.exists, "The list has no \(id) row")
        }
        // Back to the top for the screenshot.
        scrollBack(to: element("settings.sshTerminal.bar.row.keyboard"))
        attachScreenshot("settings-list")

        addEOFKey()
        let row = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.sshTerminal.bar.row.key."))
        scroll { row.count == 1 }
        XCTAssertTrue(waitFor(row.count == 1), "The new key must be a row in the list")
        XCTAssertTrue(row.element(boundBy: 0).label.contains("EOF"))
        XCTAssertTrue(row.element(boundBy: 0).label.contains("\u{2303}D"))
        attachScreenshot("settings-list-with-key")

        // Back in the terminal the key is on the bar, drawn as its short name.
        closeBottomBarSettings()
        XCTAssertTrue(waitFor(customButtons.count == 1), "The custom key must be on the bar")
        let eof = customButtons.element(boundBy: 0)
        XCTAssertEqual(eof.label, "EOF", "VoiceOver says the name")
        let sent = app.staticTexts["sshTerminal.preview.sent"]
        XCTAssertTrue(sent.waitUntilExists(timeout: 5))
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
        scrollBack(to: app.switches["settings.sshTerminal.bar.escape"])
        for id in ["escape", "interrupt", "tab", "up", "down", "enter", "programShortcuts", "paste"] {
            let toggle = app.switches["settings.sshTerminal.bar.\(id)"]
            reveal(toggle)
            XCTAssertTrue(toggle.exists, "No switch for \(id)")
            if (toggle.value as? String) != "1" { toggle.tap() }
        }
        // A bar that differs from the default offers Reset to Default.
        let reset = app.buttons["settings.sshTerminal.bar.reset"]
        reveal(reset)
        XCTAssertTrue(reset.exists, "A customized bar offers Reset to Default")
        attachScreenshot("customize-sheet")
        closeBottomBarSettings()
        let more = app.buttons["sshTerminal.more"]
        XCTAssertTrue(more.waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["sshTerminal.bar.keyboard"].waitUntilExists(timeout: 5))
        attachScreenshot("bar-many-buttons")

        // Everything drawn sits between Back and the right edge, and the pill is not wider than that room.
        let back = app.buttons["sshTerminal.back"].frame
        XCTAssertGreaterThan(app.buttons["sshTerminal.bar.keyboard"].frame.minX, back.maxX, "The pill must not cover Back")
        XCTAssertLessThanOrEqual(more.frame.maxX, app.frame.maxX)
        more.tap()
        XCTAssertTrue(app.buttons["sshTerminal.menu.customize"].waitUntilExists(timeout: 5))
        attachScreenshot("more-menu-overflow")
        assertRunning()
    }

    /// A Rex pane keeps its one Rex control in a pill of its own at the bottom
    /// right; the bar's pill sits between Back and it.
    func testRexPaneSwitcherHasItsOwnPillAtTheTrailingCorner() {
        launch(screen: "ssh-terminal-rex-panes")
        let switcher = app.buttons["sshTerminal.bar.rexPanes"]
        XCTAssertTrue(switcher.waitUntilExists(timeout: 15), "The pane switcher did not appear")
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
        XCTAssertTrue(element("sshTerminal.rexPanel.thisPane").waitUntilExists(timeout: 5))
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
        XCTAssertTrue(switcher.waitUntilExists(timeout: 15), "The pane switcher did not appear")
        XCTAssertFalse(app.buttons["sshTerminal.programStatus"].exists, "A Rex pane has no separate status symbol")
        XCTAssertFalse(app.buttons["sshTerminal.rex"].exists, "A Rex pane has no separate Rex Sessions button")
        let pane = "\u{03C0} - oppi, 1 of 3"
        XCTAssertTrue(
            waitFor((switcher.value as? String).map { $0.hasPrefix(pane + ", ") } == true),
            "The icon speaks the program's status after the pane: \(switcher.value as? String ?? "nil")"
        )
        attachScreenshot("rex-pill-working")

        switcher.tap()
        XCTAssertTrue(element("sshTerminal.rexPanel.thisPane").waitUntilExists(timeout: 5), "A tap must open the Rex panel")
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
        XCTAssertTrue(logs.waitUntilExists(timeout: 5))
        logs.tap()
        XCTAssertTrue(
            waitFor((switcher.value as? String)?.hasPrefix("tail -f server.log, 2 of 3") == true),
            "The panel must show the pane it was asked for: \(switcher.value as? String ?? "nil")"
        )
        XCTAssertFalse(element("sshTerminal.rexPanel.panes").exists, "Picking a pane closes the panel")

        // Another session's pane opens through the panel.
        switcher.tap()
        XCTAssertTrue(element("sshTerminal.rexPanel.thisPane").waitUntilExists(timeout: 5))
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
        closeBottomBarSettings()
        let switcher = app.buttons["sshTerminal.bar.rexPanes"]
        XCTAssertTrue(switcher.waitUntilExists(timeout: 10))
        switcher.tap()
        XCTAssertTrue(element("sshTerminal.rexPanel.panes").waitUntilExists(timeout: 5))
        scroll { element("sshTerminal.rexPanel.newPane").exists }
        XCTAssertFalse(element("sshTerminal.rexPanel.otherSessions").exists, "Other Sessions was turned off")
        assertRunning()
    }

    /// With the terminal keyboard up, the bar rides the keyboard bar under the
    /// same identifiers: Attach and … are in reach, Customize Bar… opens from
    /// there and the keyboard comes back after it, a custom key made there sends
    /// from the keyboard bar, and after ⌄ the same ids are on the pill.
    func testWithTheKeyboardUpTheKeyboardBarCarriesTheBar() {
        launch(screen: "ssh-terminal")
        let typeInTerminal = app.buttons["sshTerminal.bar.keyboard"]
        XCTAssertTrue(typeInTerminal.waitUntilExists(timeout: 10))
        typeInTerminal.tap()
        let hide = app.buttons["sshTerminal.hideKeyboard"]
        XCTAssertTrue(hide.waitUntilExists(timeout: 5), "The terminal keyboard did not come up")
        let escape = app.buttons["sshTerminal.escape"]
        let attach = app.buttons["sshTerminal.bar.attach"]
        let more = app.buttons["sshTerminal.more"]
        XCTAssertTrue(attach.waitUntilExists(timeout: 5), "Attach must ride the keyboard bar")
        XCTAssertTrue(attach.isHittable)
        XCTAssertGreaterThan(attach.frame.minY, escape.frame.maxY, "Attach sits in the keyboard bar's second row")
        XCTAssertTrue(more.isHittable)
        XCTAssertLessThan(more.frame.midY, hide.frame.midY, "… sits above ⌄")
        XCTAssertEqual(more.frame.midX, hide.frame.midX, accuracy: 2, "… shares ⌄'s dock")
        XCTAssertFalse(app.buttons["sshTerminal.bar.keyboard"].exists, "Type in Terminal is not repeated on the keyboard")
        let back = app.buttons["sshTerminal.back"]
        if app.windows.firstMatch.horizontalSizeClass == .regular {
            XCTAssertTrue(back.isHittable, "Back has a dock on regular width")
            XCTAssertGreaterThan(back.frame.minY, escape.frame.minY - 50, "Back is in the keyboard bar")
        } else {
            XCTAssertFalse(back.exists, "Compact width has no Back on the keyboard bar")
        }
        attachScreenshot("keyboard-bar")

        // Customize Bar… from the keyboard bar's …; the keyboard comes back after it.
        openBottomBarSettings()
        addEOFKey()
        closeBottomBarSettings()
        XCTAssertTrue(hide.waitUntilExists(timeout: 5), "The keyboard must come back after Customize")
        // iPad mini has room for it; an iPhone's two slots go to Dictate and
        // Attach, so it is in the keyboard bar's … menu, two taps away.
        let sent = app.staticTexts["sshTerminal.preview.sent"]
        if app.windows.firstMatch.horizontalSizeClass == .regular {
            XCTAssertTrue(waitFor(self.customButtons.count == 1), "The new key must be on the keyboard bar")
            let eof = customButtons.element(boundBy: 0)
            XCTAssertGreaterThan(eof.frame.minY, escape.frame.maxY)
            eof.tap()
        } else {
            XCTAssertEqual(customButtons.count, 0, "No room for the key on a phone's keyboard bar")
            more.tap()
            let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshTerminal.menu.custom.")).firstMatch
            XCTAssertTrue(item.waitUntilExists(timeout: 5), "The key is in the keyboard bar's … menu")
            item.tap()
        }
        XCTAssertTrue(waitFor(sent.label.hasSuffix("04")), "EOF on the keyboard bar must send ^D: \(sent.label)")
        XCTAssertTrue(hide.exists, "Sending a key keeps the keyboard up")
        attachScreenshot("keyboard-bar-with-key")

        // Keyboard down: the same ids answer on the pill.
        hide.tap()
        XCTAssertTrue(hide.waitUntilGone(timeout: 5))
        XCTAssertFalse(escape.exists, "The keyboard bar went with the keyboard")
        XCTAssertTrue(waitFor(attach.isHittable), "Attach is on the pill again")
        XCTAssertTrue(app.buttons["sshTerminal.bar.keyboard"].waitUntilExists(timeout: 5))
        XCTAssertTrue(more.isHittable)
        XCTAssertTrue(back.isHittable)
        assertRunning()
    }

    private func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "The app must still be running", file: file, line: line)
    }
}
