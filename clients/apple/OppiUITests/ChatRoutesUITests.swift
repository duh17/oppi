import XCTest

/// Taps through every router modal and side panel chat owns, on the
/// production ChatViewController with fixture services (`SCREENSHOT_SCREEN=chat-routes`).
/// Each modal opens, any push inside it is tapped through and popped, it closes
/// by its own control and, where it is a sheet, by swipe-down, and the app is
/// still running after every step: a hosted page that lost a presenter-local
/// service crashes on its first read. Where a modal edits chat state, the edit
/// is read back from the chat.
@MainActor
final class ChatRoutesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Chat route tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    // MARK: - Top bar

    /// The default bar: Files, Git, Outline, and the context ring, with Terminal
    /// in the … menu. Customize Top Bar… opens the Top Bar page over the chat.
    func testTopBarShowsTheDefaultButtonsAndTheRestInTheMenu() {
        // The default layout is pinned in the volatile domain, so this reads
        // the default and not whatever an earlier run saved on this simulator.
        launchScreen("chat-top-bar-default")
        dismissMicrophonePrompt()
        let files = app.buttons["chat.toolbar.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 15), "Files is on by default")
        XCTAssertTrue(app.buttons["chat.toolbar.git"].exists, "Git is on by default")
        XCTAssertTrue(app.buttons["chat.toolbar.outline"].exists, "Outline is on by default")
        XCTAssertTrue(app.buttons["chat.toolbar.context"].exists, "The context ring is on by default")
        XCTAssertFalse(app.buttons["chat.toolbar.terminal"].exists, "Terminal is in the … menu by default")
        attachScreenshot("chat-top-bar-default")

        let more = app.buttons["chat.toolbar.more"]
        XCTAssertTrue(more.exists, "The bar keeps a … menu")
        more.tap()
        let customize = app.buttons["Customize Top Bar…"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5), "The … menu must offer Customize Top Bar…")
        attachScreenshot("chat-top-bar-menu")
        customize.tap()
        XCTAssertTrue(app.navigationBars["Top Bar"].waitForExistence(timeout: 5), "Customize Top Bar must open the Top Bar page")
        for id in ["files", "git", "outline", "context", "terminal"] {
            XCTAssertTrue(
                app.switches["settings.chat.topBar.\(id)"].waitForExistence(timeout: 5),
                "The Top Bar page must show the \(id) switch"
            )
        }
        XCTAssertEqual(app.switches["settings.chat.topBar.files"].value as? String, "1", "Files starts on")
        XCTAssertEqual(app.switches["settings.chat.topBar.terminal"].value as? String, "0", "Terminal starts off")
        XCTAssertTrue(
            app.switches["settings.chat.topBar.terminal"].isEnabled,
            "Terminal's switch works like the others"
        )
        attachScreenshot("chat-settings-top-bar")
        assertRunning()
    }

    /// Terminal on and shown: it takes its place in the bar, and the buttons the
    /// user hid — Git, Outline, and the ring — are in the … menu instead.
    func testTopBarWithTerminalOnAndTheRestInTheMenu() {
        launchScreen("chat-top-bar-terminal")
        dismissMicrophonePrompt()
        XCTAssertTrue(
            app.buttons["chat.toolbar.terminal"].waitForExistence(timeout: 15),
            "Terminal must show when it is on"
        )
        XCTAssertTrue(app.buttons["chat.toolbar.files"].exists, "Files is on")
        XCTAssertFalse(app.buttons["chat.toolbar.git"].exists, "A hidden Git is not on the bar")
        XCTAssertFalse(app.buttons["chat.toolbar.outline"].exists, "A hidden Outline is not on the bar")
        XCTAssertFalse(app.buttons["chat.toolbar.context"].exists, "A hidden ring is not on the bar")
        attachScreenshot("chat-top-bar-terminal")

        app.buttons["chat.toolbar.more"].tap()
        XCTAssertTrue(
            app.buttons["chat.toolbar.menu.outline"].waitForExistence(timeout: 5),
            "Outline is the … menu's action"
        )
        XCTAssertTrue(app.buttons["chat.toolbar.menu.context"].exists, "The hidden ring is in the … menu")
        XCTAssertTrue(app.buttons["chat.toolbar.menu.git"].exists, "The hidden Git is in the … menu")
        attachScreenshot("chat-top-bar-terminal-menu")
        assertRunning()
    }

    /// Every button on: all five are in the bar in the chosen order, and the …
    /// menu has nothing but Customize Top Bar….
    func testTopBarShowsEveryButtonWhenAllAreOn() {
        launchScreen("chat-top-bar-all")
        dismissMicrophonePrompt()
        let order = [
            "chat.toolbar.files", "chat.toolbar.git", "chat.toolbar.outline", "chat.toolbar.context", "chat.toolbar.terminal",
        ]
        for id in order {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 15), "\(id) must be on the bar")
        }
        assertLeftToRight(order.map { app.buttons[$0] }, "The all-on bar")
        attachScreenshot("chat-top-bar-all")

        app.buttons["chat.toolbar.more"].tap()
        XCTAssertTrue(app.buttons["Customize Top Bar…"].waitForExistence(timeout: 5), "The … menu stays")
        XCTAssertFalse(
            app.buttons["chat.toolbar.menu.files"].exists,
            "Nothing is hidden, so the … menu holds only Customize Top Bar…"
        )
        assertRunning()
    }

    /// Every button off: only … is left, and the menu offers all five.
    func testTopBarShowsOnlyTheMenuWhenEveryButtonIsOff() {
        launchScreen("chat-top-bar-none")
        dismissMicrophonePrompt()
        let more = app.buttons["chat.toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 15), "… is the only bar control left")
        for id in ["files", "git", "outline", "context", "terminal"] {
            XCTAssertFalse(app.buttons["chat.toolbar.\(id)"].exists, "\(id) is hidden")
        }
        attachScreenshot("chat-top-bar-none")

        more.tap()
        for id in ["files", "git", "outline", "context", "terminal"] {
            XCTAssertTrue(
                app.buttons["chat.toolbar.menu.\(id)"].waitForExistence(timeout: 5),
                "\(id) must be in the … menu"
            )
        }
        XCTAssertTrue(app.buttons["Customize Top Bar…"].exists, "Customize Top Bar… stays last")
        attachScreenshot("chat-top-bar-none-menu")
        assertRunning()
    }

    /// A stored order is what the bar reads, and the Top Bar page lists the same
    /// order with a reorder handle on every row.
    func testTopBarFollowsTheChosenOrder() {
        launchScreen("chat-top-bar-reordered")
        dismissMicrophonePrompt()
        let order = [
            "chat.toolbar.outline", "chat.toolbar.files", "chat.toolbar.context", "chat.toolbar.git", "chat.toolbar.terminal",
        ]
        for id in order {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 15), "\(id) must be on the bar")
        }
        assertLeftToRight(order.map { app.buttons[$0] }, "The reordered bar")
        attachScreenshot("chat-top-bar-reordered")

        app.buttons["chat.toolbar.more"].tap()
        let customize = app.buttons["Customize Top Bar…"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5))
        customize.tap()
        XCTAssertTrue(app.navigationBars["Top Bar"].waitForExistence(timeout: 5))
        let rows = ["outline", "files", "context", "git", "terminal"].map { "settings.chat.topBar.row.\($0)" }
        for id in rows {
            XCTAssertTrue(app.cells[id].waitForExistence(timeout: 5), "\(id) must be a row")
        }
        assertTopToBottom(rows.map { app.cells[$0] }, "The Top Bar page rows")
        for id in rows {
            // The handle carries the row's identifier and a "Reorder <label>"
            // label, so the page is always in editing mode.
            XCTAssertTrue(
                app.cells[id].buttons[id].exists,
                "\(id) must keep its reorder handle: the page is always in editing mode"
            )
        }
        attachScreenshot("chat-settings-top-bar-reorder")
        assertRunning()
    }

    /// Settings → Chat → Top Bar is a row that pushes the page, and its summary
    /// names the buttons the bar shows.
    func testSettingsChatTopBarRowOpensThePage() {
        launchScreen("settings-chat")
        let row = app.buttons["settings.chat.topBar"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The Chat settings page must show its Top Bar row")
        let summary = row.value as? String ?? ""
        XCTAssertTrue(summary.contains("Files"), "The row must summarize the layout, not the label again: \(summary)")
        row.tap()
        XCTAssertTrue(app.navigationBars["Top Bar"].waitForExistence(timeout: 5), "The Top Bar row must push its page")
        XCTAssertTrue(
            app.switches["settings.chat.topBar.files"].waitForExistence(timeout: 5),
            "The pushed page must be the Top Bar page"
        )
        assertRunning()
    }

    /// The Top Bar page itself, with nothing pinned in the argument domain, so
    /// these are the writes a person makes: a switch writes the layout, a drag
    /// reorders it, and both survive a relaunch.
    ///
    /// This is the one test that writes the persistent layout, so it opens with
    /// `SCREENSHOT_RESET_TOP_BAR` and restores through a teardown block: a
    /// failure here cannot leave the bar changed for the suites that share this
    /// simulator.
    func testTopBarSettingsSwitchAndReorderWriteTheLayout() {
        launchScreen("settings-chat-top-bar", environment: ["SCREENSHOT_RESET_TOP_BAR": "1"])
        addTeardownBlock { [weak self] in
            // Teardown blocks run on the main thread, where the test's launch
            // helper and its app handle live.
            MainActor.assumeIsolated { self?.resetSavedTopBar() }
        }
        let rowIDs = ["files", "git", "outline", "context", "terminal"]
        func row(_ id: String) -> XCUIElement { app.cells["settings.chat.topBar.row.\(id)"] }
        func handle(_ id: String) -> XCUIElement { row(id).buttons["settings.chat.topBar.row.\(id)"] }
        for id in rowIDs {
            XCTAssertTrue(row(id).waitForExistence(timeout: 15), "\(id) must be a row")
        }
        assertTopToBottom(rowIDs.map(row), "The Top Bar page's opening order")
        let outlineSwitch = app.switches["settings.chat.topBar.outline"]
        XCTAssertEqual(outlineSwitch.value as? String, "1", "Outline starts on")

        // A switch writes: Outline off.
        outlineSwitch.tap()
        XCTAssertTrue(
            waitFor((outlineSwitch.value as? String) == "0"),
            "Turning Outline off must flip its switch"
        )

        // A drag writes: Terminal's handle to the top.
        XCTAssertTrue(handle("terminal").exists, "Terminal must keep its reorder handle")
        drag(handle("terminal"), above: row("files"))
        XCTAssertTrue(
            waitFor(row("terminal").frame.minY < row("files").frame.minY),
            "Dragging Terminal to the top must reorder the page"
        )
        assertTopToBottom(["terminal", "files", "git", "outline", "context"].map(row), "The dragged order")

        // Both writes are the layout, not the screen: a fresh launch reads them
        // back on the page the writes came from.
        app.terminate()
        launchScreen("settings-chat-top-bar")
        for id in rowIDs {
            XCTAssertTrue(row(id).waitForExistence(timeout: 15), "\(id) must come back as a row")
        }
        assertTopToBottom(["terminal", "files", "git", "outline", "context"].map(row), "The order after a relaunch")
        XCTAssertEqual(
            app.switches["settings.chat.topBar.outline"].value as? String,
            "0",
            "The hidden button must still be hidden after a relaunch"
        )

        // And the reset flag the test opened with is what puts the device back:
        // the same launch reads the default layout again.
        app.terminate()
        launchScreen("settings-chat-top-bar", environment: ["SCREENSHOT_RESET_TOP_BAR": "1"])
        for id in rowIDs {
            XCTAssertTrue(row(id).waitForExistence(timeout: 15), "\(id) must come back as a row")
        }
        assertTopToBottom(rowIDs.map(row), "The order after a reset")
        XCTAssertEqual(
            app.switches["settings.chat.topBar.outline"].value as? String,
            "1",
            "The reset must show the hidden button again"
        )
        assertRunning()
    }

    /// Puts the saved top bar layout back on this simulator, whether the test
    /// that wrote it finished or stopped early.
    private func resetSavedTopBar() {
        launchScreen("settings-chat-top-bar", environment: ["SCREENSHOT_RESET_TOP_BAR": "1"])
        XCTAssertTrue(
            app.cells["settings.chat.topBar.row.files"].waitForExistence(timeout: 15),
            "The reset launch must reach the Top Bar page"
        )
    }

    /// Drags a row's reorder handle above or below another row, the way a person
    /// moves it: press on the handle, drag, and hold so the list commits the
    /// move instead of flinging.
    private func drag(_ handle: XCUIElement, above row: XCUIElement) {
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.8,
            thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
            withVelocity: .slow,
            thenHoldForDuration: 0.6
        )
    }

    /// Left-to-right order of the controls the caller names, which is the order
    /// the user chose. A missing element fails rather than reading as a frame at
    /// zero, which would sort into place and pass.
    private func assertLeftToRight(
        _ elements: [XCUIElement],
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertOrder(elements, label, keyPath: \.minX, description: "left to right", file: file, line: line)
    }

    /// Top-to-bottom order of the rows the caller names, for a page whose rows
    /// stack instead of running across the bar.
    private func assertTopToBottom(
        _ elements: [XCUIElement],
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertOrder(elements, label, keyPath: \.minY, description: "top to bottom", file: file, line: line)
    }

    private func assertOrder(
        _ elements: [XCUIElement],
        _ label: String,
        keyPath: KeyPath<CGRect, CGFloat>,
        description: String,
        file: StaticString,
        line: UInt
    ) {
        let frames = elements.map(\.frame)
        for (index, frame) in frames.enumerated() where frame.isEmpty {
            XCTFail("\(label): element \(index) is missing or has no frame", file: file, line: line)
        }
        XCTAssertEqual(
            frames.map { $0[keyPath: keyPath] },
            frames.map { $0[keyPath: keyPath] }.sorted(),
            "\(label) must read \(description) in this order",
            file: file,
            line: line
        )
    }

    // MARK: - Side panels

    /// Regular width puts these in the trailing column beside the chat;
    /// compact width presents them as sheets.
    func testOutlineSearchesAndClosesBothWays() {
        launch()
        let outlineButton = app.buttons["chat.toolbar.outline"]
        XCTAssertTrue(outlineButton.waitForExistence(timeout: 10), "Seeded timeline must make the outline available")
        outlineButton.tap()
        let outline = app.navigationBars["Session Outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 5), "Outline did not open in a router navigation bar")
        let search = outlineSearchField()
        search.tap()
        search.typeText("ROUTES_FILL_2")
        // Each outline row is one button whose label is its summary.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ROUTES_FILL_2")).firstMatch
            .waitForExistence(timeout: 5), "Search must keep the matching entry")
        attachScreenshot("outline-search")
        assertRunning()

        // On iPhone an active search bar takes over the bar's leading items;
        // end it first.
        let close = app.buttons["chat.outline.close"]
        if !(close.exists && close.isHittable) {
            app.buttons.matching(NSPredicate(format: "label ==[c] %@ AND identifier != %@", "close", "chat.outline.close"))
                .firstMatch.tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Ending search must restore Close")
        close.tap()
        XCTAssertTrue(waitForDisappearance(of: outline), "Close must close the outline")
        assertRunning()

        if usesSheets {
            outlineButton.tap()
            XCTAssertTrue(outline.waitForExistence(timeout: 5), "Outline did not reopen")
            dragToBottom(outline)
            XCTAssertTrue(waitForDisappearance(of: outline), "Swipe-down must close the outline sheet")
            outlineButton.tap()
            XCTAssertTrue(outline.waitForExistence(timeout: 5), "The binding cleared on swipe-down, so the button reopens it")
            app.buttons["chat.outline.close"].tap()
            XCTAssertTrue(waitForDisappearance(of: outline))
        }
        assertRunning()
    }

    /// A long session (about 700 rows): an outline tap on a far row, one
    /// mid-session, and one near the tail each land that row's top edge just
    /// below the chat's top chrome, and the row lights up.
    func testOutlineJumpLandsOnTheTappedRow() {
        launch(environment: ["CHAT_ROUTES_LONG_TURNS": "175"])
        let outlineButton = app.buttons["chat.toolbar.outline"]
        XCTAssertTrue(outlineButton.waitForExistence(timeout: 10), "Seeded timeline must make the outline available")
        let landing = app.staticTexts["chatRoutes.landing"]
        // Far rows (the whole history renders), one mid-session, one near the tail.
        for turn in [3, 21, 91, 171] {
            outlineButton.tap()
            let outline = app.navigationBars["Session Outline"]
            XCTAssertTrue(outline.waitForExistence(timeout: 5), "Outline did not open")
            let search = outlineSearchField()
            search.tap()
            search.typeText("LONG_BASH_\(turn)")
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "echo LONG_BASH_\(turn) &&")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Search must list bash \(turn)")
            row.tap()
            XCTAssertTrue(
                waitForDisappearance(of: search),
                "Selecting a search hit must dismiss the outline search field so the chat is visible"
            )
            XCTAssertTrue(waitForDisappearance(of: outline), "Selecting a row must close the outline")
            XCTAssertTrue(
                waitFor(outlineButton.isHittable),
                "The chat must be visible after a search jump (outline toolbar hittable): usesSheets=\(usesSheets) width=\(app.windows.firstMatch.frame.width)"
            )
            let target = "long-bash-\(turn)"
            // The row lights up once the outline is gone, not under it.
            XCTAssertTrue(
                waitFor(text(of: landing).contains("arrived=\(target)/open "), timeout: 3),
                "The landed row must light up after the outline closes: \(text(of: landing))"
            )
            let settled = text(of: landing)
            XCTAssertTrue(
                ["@0 ", "@1 ", "@-1 "].contains { settled.contains("top=\(target)\($0)") },
                "Outline jump to \(target) must land its top edge under the chrome: \(settled)"
            )
        }
        assertRunning()
    }

    func testFilesPanelPushesAReviewAndCloses() {
        launch()
        app.buttons["chat.toolbar.files"].tap()
        let files = app.navigationBars["Files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "Files panel did not open")
        let changedSearch = app.searchFields["Search changed files"]
        XCTAssertTrue(changedSearch.waitForExistence(timeout: 5), "Changed files must search in the panel's bar")
        // The panel's row, not the timeline's file pill beside the column.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "App.swift")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Changed file row missing")
        row.tap()
        let review = app.navigationBars["App.swift"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "The file review was not pushed inside the panel")
        attachScreenshot("files-panel-push")
        assertRunning()
        barButton(review, NSPredicate(format: "identifier == %@", "BackButton")).tap()
        XCTAssertTrue(files.waitForExistence(timeout: 5), "Back must pop to the file list")

        // A file the session wrote outside Git opens its current bytes.
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "plan.md")).firstMatch.tap()
        popPushedReader(returningTo: files, "The session file")

        // All: the tab's own search takes the bar, and a file pushes its reader.
        app.buttons["All"].firstMatch.tap()
        XCTAssertTrue(app.searchFields["Search files"].waitForExistence(timeout: 5), "The All tab must search in the panel's bar")
        let allRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "App.swift")).firstMatch
        XCTAssertTrue(allRow.waitForExistence(timeout: 5), "The workspace listing did not load")
        allRow.tap()
        popPushedReader(returningTo: files, "The workspace file")
        app.buttons["Changed"].firstMatch.tap()
        XCTAssertTrue(changedSearch.waitForExistence(timeout: 5), "Changed must take the bar back")

        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
            XCTAssertTrue(waitForDisappearance(of: files), "Done must close the files panel")
        } else {
            app.buttons["chat.toolbar.files"].tap()
            XCTAssertTrue(waitForDisappearance(of: files), "The files button must close the column")
        }
        assertRunning()

        if usesSheets {
            app.buttons["chat.toolbar.files"].tap()
            XCTAssertTrue(files.waitForExistence(timeout: 5))
            dragToBottom(files)
            XCTAssertTrue(waitForDisappearance(of: files), "Swipe-down must close the files sheet")
        }
        assertRunning()
    }

    func testContextOpensAndCloses() {
        launch()
        app.buttons["chat.toolbar.context"].tap()
        let context = app.navigationBars["Context"]
        XCTAssertTrue(context.waitForExistence(timeout: 5), "Context did not open")
        // The window splits in request order; tools loaded on demand are listed apart.
        for segment in ["systemPrompt", "agentsFiles", "skills", "messages", "tools", "compactionReserve", "onDemand"] {
            XCTAssertTrue(
                app.cells["chat.context.segment.\(segment)"].waitForExistence(timeout: 10),
                "Context is missing the \(segment) row"
            )
        }
        attachScreenshot("context")

        // Sections open collapsed; an MCP server lists its on-demand tools when opened.
        let servers = app.cells["chat.context.section.mcpServers"]
        scrollTo(servers)
        servers.tap()
        let docs = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "docs")).firstMatch
        XCTAssertTrue(docs.waitForExistence(timeout: 5), "Opening MCP servers did not list the docs server")
        scrollTo(docs)
        docs.tap()
        XCTAssertTrue(
            app.cells.matching(NSPredicate(format: "label CONTAINS %@", "mcp__docs__search")).firstMatch
                .waitForExistence(timeout: 5),
            "Opening the docs server did not list its tools"
        )
        attachScreenshot("context-mcp")

        // An extension opens its page with its tools and the edit action.
        let extensions = app.cells["chat.context.section.extensions"]
        scrollTo(extensions)
        extensions.tap()
        let weather = app.cells["chat.context.extension.weather"]
        scrollTo(weather)
        weather.tap()
        let extensionPage = app.navigationBars["weather"]
        XCTAssertTrue(extensionPage.waitForExistence(timeout: 5), "The extension was not pushed inside Context")
        XCTAssertTrue(app.cells["chat.context.extension.edit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "label CONTAINS %@", "forecast")).firstMatch.exists)
        attachScreenshot("context-extension")
        barButton(extensionPage, NSPredicate(format: "identifier == %@", "BackButton")).tap()
        XCTAssertTrue(context.waitForExistence(timeout: 5), "Back must pop to Context")

        // A loaded skill, then one of its files, push inside the panel.
        let skills = app.cells["chat.context.section.skills"]
        scrollTo(skills)
        skills.tap()
        let skillRow = app.cells["chat.context.skill.route-skill"]
        XCTAssertTrue(skillRow.waitForExistence(timeout: 10), "The session's loaded skill is missing")
        scrollTo(skillRow)
        skillRow.tap()
        let skill = app.navigationBars["route-skill"]
        XCTAssertTrue(skill.waitForExistence(timeout: 5), "The skill was not pushed inside Context")
        let fileRow = app.buttons["notes.md"]
        XCTAssertTrue(fileRow.waitForExistence(timeout: 5), "The skill's files did not load")
        fileRow.tap()
        popPushedReader(returningTo: skill, "The skill file")
        barButton(skill, NSPredicate(format: "identifier == %@", "BackButton")).tap()
        XCTAssertTrue(context.waitForExistence(timeout: 5), "Back must pop to Context")
        assertRunning()

        app.buttons["chat.context.close"].tap()
        XCTAssertTrue(waitForDisappearance(of: context), "Close must close Context")
        if usesSheets {
            app.buttons["chat.toolbar.context"].tap()
            XCTAssertTrue(context.waitForExistence(timeout: 5))
            dragToBottom(context)
            XCTAssertTrue(waitForDisappearance(of: context), "Swipe-down must close the Context sheet")
        }
        assertRunning()
    }

    // MARK: - Composer modals

    func testModelPickerAndThinkingPopover() {
        launch()
        focusComposer()
        let modelPill = app.buttons["session.toolbar.model"]
        XCTAssertTrue(modelPill.waitForExistence(timeout: 10), "A focused composer shows the model pill")
        modelPill.tap()
        let models = app.navigationBars["Models"]
        XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not open")
        XCTAssertTrue(app.buttons["model.picker.row.openai/gpt-routes"].waitForExistence(timeout: 5), "Model picker must list the chat's models")
        attachScreenshot("model-picker")
        dragToBottom(models)
        XCTAssertTrue(waitForDisappearance(of: models), "Swipe-down must close the model picker")
        modelPill.tap()
        XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not reopen")
        cancelButton.tap()
        XCTAssertTrue(waitForDisappearance(of: models), "Cancel must close the model picker")
        assertRunning()

        app.buttons["session.toolbar.thinking"].tap()
        let high = app.buttons["session.toolbar.thinking.option.high"]
        XCTAssertTrue(high.waitForExistence(timeout: 5), "Thinking popover did not open")
        attachScreenshot("thinking-popover")
        high.tap()
        XCTAssertTrue(waitForDisappearance(of: high), "Choosing a level must close the popover")
        assertRunning()
    }

    func testBusyModePopoverChoiceReachesTheComposer() {
        launch(environment: ["CHAT_ROUTES_STATUS": "busy"])
        focusComposer()
        let busyMode = app.buttons["chat.busyMode"]
        XCTAssertTrue(busyMode.waitForExistence(timeout: 10), "A busy session shows the send mode picker")
        XCTAssertEqual(busyMode.value as? String, "Steering")
        busyMode.tap()
        let followUp = app.buttons["chat.busyMode.option.followUp"]
        XCTAssertTrue(followUp.waitForExistence(timeout: 5), "Busy mode popover did not open")
        attachScreenshot("busy-mode-popover")
        followUp.tap()
        XCTAssertTrue(waitForDisappearance(of: followUp), "Choosing a mode must close the popover")
        XCTAssertTrue(waitFor(busyMode.value as? String == "Follow-up"), "The choice must reach the composer")
        assertRunning()
    }

    func testExpandedComposerKeepsTextAndPresentsModelPickerAbove() {
        launch()
        focusComposer()
        // Expand shows once the draft runs over a few lines; wide windows
        // need the line breaks.
        app.descendants(matching: .any)["chat.input"].typeText("Draft\nacross\nseveral\ncomposer\nlines ")
        let expand = app.buttons["chat.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10), "A multi-line draft shows the expand button")
        expand.tap()
        let editor = app.textViews["expanded.composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Expanded composer did not open")
        editor.tap()
        editor.typeText("routed text")
        assertRunning()

        // The chat presents the picker; it stays live under the composer.
        app.buttons["session.toolbar.model"].firstMatch.tap()
        let models = app.navigationBars["Models"]
        XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not open above the composer")
        dragToBottom(models)
        XCTAssertTrue(waitForDisappearance(of: models))
        XCTAssertTrue(editor.exists, "Closing the picker must keep the composer")

        app.buttons["expanded.composer.cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: editor), "Cancel must close the expanded composer")
        let inline = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(waitFor(self.text(of: inline).contains("routed text")), "Typed text must reach the chat composer: \(text(of: inline))")
        assertRunning()
    }

    func testAskSheetPagesBackToTheCard() {
        launch(environment: ["CHAT_ROUTES_ASK": "1"])
        let expand = app.descendants(matching: .any)["ask.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10), "Ask card did not appear")
        expand.tap()
        let sheet = app.descendants(matching: .any)["ask.approval.scroll"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Expanded ask sheet did not open")
        attachScreenshot("ask-sheet")
        sheet.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Popover")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Next")).firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Question 2 of 2"].waitForExistence(timeout: 5),
            "Answering the first question must page the sheet"
        )
        // From the header: a drag on the question list scrolls it.
        dragToBottom(app.staticTexts["Question 2 of 2"])
        XCTAssertTrue(waitForDisappearance(of: sheet), "Swipe-down must close the ask sheet")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Which route next?")).firstMatch
                .waitForExistence(timeout: 5),
            "The sheet's page must reach the inline card"
        )
        expand.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The binding cleared on swipe-down, so expand reopens it")
        XCTAssertTrue(app.staticTexts["Question 2 of 2"].exists, "The reopened sheet starts on the card's page")
        app.buttons["ask.expanded.collapse"].tap()
        XCTAssertTrue(waitForDisappearance(of: sheet), "Collapse must close the ask sheet")
        assertRunning()
    }

    /// The composers' covers, opened from harness controls: with the attach
    /// menu open the app never reports idle to the test runner.
    func testPhotoLibraryAndCanvasCovers() {
        launch()
        for (control, name) in [("chatRoutes.photoLibrary", "photo-library"), ("chatRoutes.canvas", "canvas")] {
            app.buttons[control].tap()
            let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 10), "\(name) cover did not open")
            XCTAssertFalse(app.buttons["chat.toolbar.context"].isHittable, "The \(name) cover must cover the chat")
            attachScreenshot("cover-\(name)")
            close.tap()
            XCTAssertTrue(
                waitFor(self.app.buttons["chat.toolbar.context"].isHittable),
                "Closing the \(name) cover must return to the chat"
            )
            assertRunning()
        }
    }

    /// A pending composer image opens the annotate canvas. Its bar must carry
    /// undo/redo beside the checkmark — Add to Chat returns the annotated image,
    /// Cancel keeps the attachment — and the composer must be usable again
    /// after each.
    func testPendingImageAnnotateCanvasReturnsToTheComposer() {
        launch(environment: ["OPPI_E2E_CHAT_PENDING_IMAGE_BASE64": Self.composerImagePNGBase64])
        focusComposer()
        let tile = composerImageTile()
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "Seeded composer image did not appear")

        openAnnotateCanvas(from: tile)
        attachScreenshot("canvas-bar-after")

        // The bar carries undo/redo beside the checkmark; both start disabled.
        let undo = app.buttons["canvas.undo"]
        let redo = app.buttons["canvas.redo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "The canvas must offer Undo")
        XCTAssertTrue(redo.waitForExistence(timeout: 5), "The canvas must offer Redo")
        XCTAssertFalse(undo.isEnabled, "Undo starts disabled on a fresh canvas")
        XCTAssertFalse(redo.isEnabled, "Redo starts disabled on a fresh canvas")

        // A finger stroke on the canvas lands in its own undo stack.
        let canvas = app.windows.firstMatch
        let strokeStart = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
        let strokeEnd = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        strokeStart.press(forDuration: 0.15, thenDragTo: strokeEnd, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(waitFor(undo.isEnabled), "Drawing a stroke must enable Undo")
        attachScreenshot("composer-annotate-undo-redo")
        attachScreenshot("canvas-bar-after-drawn")

        undo.tap()
        XCTAssertTrue(waitFor(redo.isEnabled), "Undoing a stroke must enable Redo")
        redo.tap()
        XCTAssertTrue(waitFor(undo.isEnabled), "Redoing a stroke must enable Undo again")

        app.buttons["composer.canvas.addToChat"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.navigationBars["Canvas"]), "Add to Chat must close the canvas")
        XCTAssertTrue(
            waitFor(app.descendants(matching: .any)["chat.input"].isHittable),
            "The composer must be back after Add to Chat"
        )
        XCTAssertTrue(composerImageTile().exists, "The annotated image must stay in the composer")

        openAnnotateCanvas(from: composerImageTile())
        app.buttons["composer.canvas.cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.navigationBars["Canvas"]), "Cancel must close the canvas")
        XCTAssertTrue(
            waitFor(app.descendants(matching: .any)["chat.input"].isHittable),
            "The composer must be back after Cancel"
        )
        XCTAssertTrue(composerImageTile().exists, "Cancel must keep the attachment")

        // The expanded composer presents the same canvas from its own host.
        focusComposer()
        app.descendants(matching: .any)["chat.input"].typeText("Draft\nacross\nseveral\ncomposer\nlines ")
        let expand = app.buttons["chat.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10), "A multi-line draft shows the expand button")
        expand.tap()
        let expandedEditor = app.textViews["expanded.composer.editor"]
        XCTAssertTrue(expandedEditor.waitForExistence(timeout: 5), "Expanded composer did not open")
        openAnnotateCanvas(from: composerImageTile())
        app.buttons["composer.canvas.cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.navigationBars["Canvas"]), "Cancel must close the expanded canvas")
        XCTAssertTrue(
            waitFor(expandedEditor.isHittable),
            "The expanded composer must be back after Cancel"
        )
        app.buttons["expanded.composer.cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: expandedEditor), "The expanded composer must close")
        XCTAssertTrue(
            waitFor(app.descendants(matching: .any)["chat.input"].isHittable),
            "The inline composer must be back"
        )
        XCTAssertTrue(composerImageTile().exists, "The attachment must survive the expanded canvas")
        assertRunning()
    }

    /// The composer's image tile, by prefix: Add to Chat replaces it with a
    /// freshly exported attachment, so its id changes.
    private func composerImageTile() -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.attachment.image.annotate.")
        ).firstMatch
    }

    private func openAnnotateCanvas(from tile: XCUIElement) {
        XCTAssertTrue(tile.isHittable, "The composer image tile must be tappable")
        tile.tap()
        XCTAssertTrue(app.navigationBars["Canvas"].waitForExistence(timeout: 10), "Tapping the image must open the canvas")
        XCTAssertTrue(
            app.buttons["composer.canvas.cancel"].isHittable,
            "The canvas must offer a visible way back to the chat"
        )
        XCTAssertTrue(
            app.buttons["composer.canvas.addToChat"].isHittable,
            "The canvas must offer a visible save back to the composer"
        )
        attachScreenshot("composer-annotate")
    }

    // MARK: - Chat sheets

    func testStashSheetEditReachesTheChat() {
        launch()
        let pill = app.descendants(matching: .any)["chat.reviewComments.pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "Staged comment pill missing")
        pill.doubleTap()
        let edit = app.buttons["Edit review comment"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Stash sheet did not open")
        edit.tap()
        let editor = app.textViews["Review comment text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" edited")
        app.buttons["Save"].tap()
        XCTAssertTrue(waitForDisappearance(of: editor))
        // The sheet lists the chat's comments; reopening the editor reads the
        // saved body back from them.
        edit.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Route comment edited", "The edit must reach the chat's comments")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(of: editor))
        attachScreenshot("stash-edited")
        dragToBottom(edit)
        XCTAssertTrue(waitForDisappearance(of: edit), "Swipe-down must close the stash sheet")
        assertRunning()

        pill.doubleTap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "The stash sheet did not reopen")
        cancelButton.tap()
        XCTAssertTrue(waitForDisappearance(of: edit), "Close must close the stash sheet")
        assertRunning()
    }

    func testShareSheetRefreshesItsPreviewAndKeepsThePolicy() {
        launch()
        openShareSheet()
        let share = app.navigationBars["Share Session"]
        // Without a server the preflight fails after the scan starts. Its
        // error shows only if the open sheet reads chat's share model live.
        XCTAssertTrue(
            app.staticTexts["WebSocket not connected"].waitForExistence(timeout: 10),
            "The preflight result must reach the open sheet"
        )
        let emails = app.switches["Email Addresses"]
        XCTAssertEqual(emails.value as? String, "1")
        emails.tap()
        XCTAssertTrue(waitFor(emails.value as? String == "0"), "The toggle must follow the policy binding")
        attachScreenshot("share-sheet")
        cancelButton.tap()
        XCTAssertTrue(waitForDisappearance(of: share), "Cancel must close the share sheet")

        openShareSheet()
        XCTAssertEqual(app.switches["Email Addresses"].value as? String, "0", "The edited policy must be remembered")
        if usesSheets {
            dragToBottom(share)
            XCTAssertTrue(waitForDisappearance(of: share), "Swipe-down must close the share sheet")
        } else {
            cancelButton.tap()
            XCTAssertTrue(waitForDisappearance(of: share))
        }
        assertRunning()
    }

    // MARK: - Review modals

    func testGitPanelCommitPushesAChatAndShowsTheDiffPanel() {
        launch()
        openGitPanel()
        tapCommitRow()
        let commit = app.navigationBars["Commit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5), "Commit sheet did not open in a router navigation bar")
        openAndCloseDiff()

        // New Session pushes a chat onto the sheet's own stack.
        // iOS 27 puts the actions in the system overflow menu.
        barButton(commit, NSPredicate(format: "label IN %@", ["More", "Actions"])).tap()
        let newSession = app.buttons["New Session"].firstMatch
        XCTAssertTrue(newSession.waitForExistence(timeout: 5), "New Session missing from the commit actions")
        newSession.tap()
        // The pushed chat's Back is the lower one: the chat under the sheet
        // has its own (and on iPad a tap there closes the sheet).
        let backButtons = app.buttons.matching(identifier: "chat.toolbar.back")
        XCTAssertTrue(waitFor(backButtons.count == 2, timeout: 10), "New Session must push its chat")
        let back = [backButtons.element(boundBy: 0), backButtons.element(boundBy: 1)]
            .max { $0.frame.minY < $1.frame.minY }!
        attachScreenshot("commit-pushed-chat")
        assertRunning()
        back.tap()
        XCTAssertTrue(commit.waitForExistence(timeout: 5), "Back must pop to the commit")
        assertRunning()

        app.buttons[closeLabel].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(of: commit), "Close must close the commit sheet")
        let created = app.descendants(matching: .any)["chatRoutes.createdSessions"]
        XCTAssertEqual(created.value as? String, "1", "The stub must have received the new session")
        tapCommitRow()
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        dragToBottom(commit)
        XCTAssertTrue(waitForDisappearance(of: commit), "Swipe-down must close the commit sheet")
        assertRunning()
    }

    /// The Git panel opens from the bar, lists only the session's file until
    /// All changes lists every change, opens a file's review over itself, and
    /// closes by its own control and, as a sheet, by swipe-down.
    func testGitPanelScopesItsFilesAndOpensAReview() {
        launch()
        openGitPanel()
        let panel = app.navigationBars["Git"]
        XCTAssertTrue(panel.exists, "The Git panel must be titled Git")
        let worktreeBranch = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "branch feat/routes, checked out in feat/routes")
        ).firstMatch
        XCTAssertTrue(worktreeBranch.exists, "The graph must list every branch and mark one another worktree has out")
        let otherChange = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "README.md")).firstMatch
        XCTAssertFalse(otherChange.exists, "This session must not list a change the session did not make")
        let scope = app.segmentedControls["workspace-context-bar.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "A main-checkout session must offer This session / All changes")
        attachScreenshot("git-panel-this-session")
        scope.buttons["All changes (2)"].tap()
        XCTAssertTrue(otherChange.waitForExistence(timeout: 5), "All changes must list every change")
        attachScreenshot("git-panel-all-changes")
        scope.buttons["This session"].tap()
        XCTAssertTrue(waitForDisappearance(of: otherChange), "This session must narrow the list again")

        // The panel's row carries the line counts; the timeline's file pill
        // beside the column does not.
        let fileRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "App.swift", "+2")
        ).firstMatch
        fileRow.tap()
        let review = app.navigationBars["App.swift"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "File review sheet did not open")
        attachScreenshot("git-panel-file-review")
        app.buttons[closeLabel].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(of: review), "Close must close the file review")
        fileRow.tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        dragToBottom(review)
        XCTAssertTrue(waitForDisappearance(of: review), "Swipe-down must close the file review")
        XCTAssertTrue(panel.exists, "Closing the review must leave the Git panel open")
        assertRunning()

        app.buttons["chat.git.close"].tap()
        XCTAssertTrue(waitForDisappearance(of: panel), "Close must close the Git panel")
        if usesSheets {
            openGitPanel()
            dragToBottom(panel)
            XCTAssertTrue(waitForDisappearance(of: panel), "Swipe-down must close the Git sheet")
        }
        assertRunning()
    }

    /// New Session from the Git panel's selection closes the panel and opens
    /// the new chat on this chat's own stack, not inside the sheet or column:
    /// Back from it lands on the chat, with no Git panel to come back to.
    func testGitPanelNewSessionOpensOnTheChatStack() {
        launch()
        openGitPanel()
        let panel = app.navigationBars["Git"]
        let select = app.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5), "The Git panel must offer Select")
        select.tap()
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "App.swift", "+2")
        ).firstMatch.tap()
        let newSession = app.buttons["Start new session with selected files"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5), "Selecting must offer New Session")
        newSession.tap()

        let newChatTitle = app.buttons.matching(
            NSPredicate(format: "label == %@ AND value == %@", "Rename session", "New routes session")
        ).firstMatch
        XCTAssertTrue(newChatTitle.waitForExistence(timeout: 10), "New Session must open its chat")
        XCTAssertTrue(waitForDisappearance(of: panel, timeout: 10), "Starting a session must close the Git panel")
        let created = app.descendants(matching: .any)["chatRoutes.createdSessions"]
        XCTAssertEqual(created.value as? String, "1", "The stub must have received the new session")
        attachScreenshot("git-panel-new-session-chat")

        let backButtons = app.buttons.matching(identifier: "chat.toolbar.back")
        XCTAssertEqual(backButtons.count, 1, "The new chat must be the only chat on screen, not one inside a sheet")
        backButtons.element(boundBy: 0).tap()
        let originalTitle = app.buttons.matching(
            NSPredicate(format: "label == %@ AND value == %@", "Rename session", "Routes")
        ).firstMatch
        XCTAssertTrue(originalTitle.waitForExistence(timeout: 5), "Back must return to the chat the panel was opened from")
        XCTAssertFalse(panel.exists, "Back must not return to the Git panel")
        assertRunning()
    }

    /// What a commit pill and a file pill open, through the chat's destination
    /// presenter (harness controls; a test tap on the pill does not reach it).
    func testTimelineCommitAndFileViewers() {
        launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["chat.user.path-pill.abc1234"].waitForExistence(timeout: 10),
            "Seeded commit pill missing"
        )
        app.buttons["chatRoutes.openCommitViewer"].tap()
        let commit = app.navigationBars["Commit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5), "Commit viewer did not open in a router navigation bar")
        openAndCloseDiff()
        app.buttons["chat.commit-detail.dismiss"].tap()
        XCTAssertTrue(waitForDisappearance(of: commit), "Close must close the commit viewer")
        assertRunning()

        app.buttons["chatRoutes.openFileViewer"].tap()
        let back = app.buttons["fullscreen-code.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "File viewer did not open with its back control")
        attachScreenshot("file-viewer")
        back.tap()
        XCTAssertTrue(waitForDisappearance(of: back), "Back at the viewer's root must close it")
        XCTAssertTrue(waitFor(self.app.buttons["chat.toolbar.context"].isHittable), "Closing the viewer must return to the chat")
        assertRunning()
    }

    // MARK: - Other hosts

    /// The outline's summary-instructions sheet is a router sheet above it;
    /// the typed instructions reach the outline's tree navigation.
    func testOutlineSummarySheetSendsInstructionsToTheOutline() {
        launchScreen("session-timeline")
        let outline = app.navigationBars["Session Outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 10), "Outline preview did not appear in a navigation bar")
        _ = outlineSearchField()
        app.buttons["Tree"].tap()
        let node = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ship list mode first")).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 5), "Tree rows missing")
        node.tap()
        let custom = app.buttons["Summarize with custom instructions"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5), "Tree navigation options missing")
        custom.tap()
        let sheet = app.navigationBars["Summary Instructions"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Summary sheet did not open in a navigation bar")
        dragToBottom(sheet)
        XCTAssertTrue(waitForDisappearance(of: sheet), "Swipe-down must close the summary sheet")

        node.tap()
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Summary sheet did not reopen")
        let editor = app.textViews["tree-summary-instructions"]
        editor.tap()
        editor.typeText("keep router notes")
        app.buttons["tree-summary-navigate"].tap()
        XCTAssertTrue(waitForDisappearance(of: sheet), "Navigate must close the summary sheet")
        let capture = app.staticTexts["session-timeline.last-navigation"]
        XCTAssertTrue(
            waitFor(capture.label.contains("mode=custom instructions=keep router notes")),
            "The instructions must reach the outline: \(capture.label)"
        )
        attachScreenshot("outline-summary-sent")
        assertRunning()
    }

    // MARK: - Steps

    /// The outline's search field. A short sheet (iPhone Duo outer display)
    /// minimizes it to a Search button in the bottom toolbar.
    private func outlineSearchField(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3), app.buttons["Search"].exists {
            app.buttons["Search"].tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The outline's host must own its search field", file: file, line: line)
        return search
    }

    /// A navigation bar's button. On the iPhone Duo's vertical rail a bar's
    /// items sit in a toolbar outside the bar element; the presented screen's
    /// item is then the last match.
    private func barButton(_ bar: XCUIElement, _ predicate: NSPredicate) -> XCUIElement {
        let inBar = bar.buttons.matching(predicate)
        if inBar.count > 0 { return inBar.firstMatch }
        let all = app.buttons.matching(predicate)
        return all.element(boundBy: max(all.count - 1, 0))
    }

    /// A text reader pushed inside a panel: its own back control pops it.
    private func popPushedReader(returningTo bar: XCUIElement, _ name: String) {
        let back = app.buttons["fullscreen-code.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "\(name) reader was not pushed")
        assertRunning()
        back.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "\(name) reader's back must pop it")
    }

    private func openAndCloseDiff() {
        let fileRow = app.buttons["commit-detail.file"].firstMatch
        XCTAssertTrue(fileRow.waitForExistence(timeout: 5), "The commit's file list did not load")
        fileRow.tap()
        let close = app.buttons["commit-detail.diff.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The diff panel did not open")
        XCTAssertTrue(app.navigationBars["App.swift"].exists, "The diff panel needs its own navigation bar")
        attachScreenshot(usesSheets ? "commit-diff-sheet" : "commit-diff-column")
        close.tap()
        XCTAssertTrue(waitForDisappearance(of: close), "Close must close the diff panel")
        if usesSheets {
            fileRow.tap()
            let diff = app.navigationBars["App.swift"]
            XCTAssertTrue(diff.waitForExistence(timeout: 5))
            dragToBottom(diff)
            XCTAssertTrue(waitForDisappearance(of: diff), "Swipe-down must close the diff sheet")
        }
        XCTAssertTrue(app.navigationBars["Commit"].exists, "Closing the diff must keep the commit")
        assertRunning()
    }

    /// The Git panel's commit row: one button across the row.
    private func tapCommitRow() {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Route commit")).firstMatch.tap()
    }

    /// Opens the Git panel from the top bar and waits for its rows to stop moving.
    private func openGitPanel() {
        let git = app.buttons["chat.toolbar.git"]
        XCTAssertTrue(git.waitForExistence(timeout: 10), "The Git button is on the default bar")
        git.tap()
        XCTAssertTrue(app.navigationBars["Git"].waitForExistence(timeout: 5), "The Git panel did not open")
        let commitRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Route commit")).firstMatch
        XCTAssertTrue(commitRow.waitForExistence(timeout: 5), "The Git panel must list the commit")
        var lastFrame = CGRect.zero
        XCTAssertTrue(waitFor({
            let current = commitRow.frame
            defer { lastFrame = current }
            return current == lastFrame
        }()), "The expanded bar did not settle")
    }

    /// Share is in the title's context menu, or in the session menu on the
    /// vertical rail (iPhone Duo).
    private func openShareSheet() {
        let railSession = app.buttons["chat.rail.session"]
        if railSession.exists {
            railSession.tap()
        } else {
            let title = app.buttons["Rename session"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            title.press(forDuration: 1.0)
        }
        let share = app.buttons["Share Session"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "Share Session missing from the title menu")
        share.tap()
        XCTAssertTrue(app.navigationBars["Share Session"].waitForExistence(timeout: 5), "Share sheet did not open")
    }

    private func launch(environment: [String: String] = [:]) {
        launchScreen("chat-routes", environment: environment)
        XCTAssertTrue(app.buttons["chat.toolbar.context"].waitForExistence(timeout: 15), "Chat routes harness did not appear")
    }

    private func launchScreen(_ screen: String, environment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchArguments += ["--screenshot-preview", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
    }

    /// Compact width presents chat panels as sheets; regular width puts them
    /// in the trailing column, and Share full screen.
    private var usesSheets: Bool {
        app.windows.firstMatch.frame.width < 700
    }

    /// The review sheets' close control (`FullScreenViewerNavigationChrome`).
    private var closeLabel: String { "Done" }

    /// The composer's action row (model, thinking, attach, expand, busy mode)
    /// shows while the input has focus.
    private func focusComposer() {
        let input = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Composer input missing")
        input.tap()
    }

    private var cancelButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch
    }

    /// Swipe-down from `element` to the bottom of the screen.
    private func dragToBottom(_ element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Scrolls the Context list until all of `element` shows above the list's
    /// bottom edge; a row cut off there reports hittable but misses the tap.
    private func scrollTo(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews["chat.context.list"]
        let visible = { element.exists && list.frame.insetBy(dx: 0, dy: 40).contains(element.frame) }
        for _ in 0..<8 where !visible() {
            list.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(visible(), "\(element) never scrolled into reach", file: file, line: line)
    }

    private func text(of element: XCUIElement) -> String {
        "\(element.label) \(element.value as? String ?? "")"
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// The chat fixtures touch dictation, which asks for the microphone on a
    /// fresh simulator. Answer it before the screenshots.
    private func dismissMicrophonePrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons["Don’t Allow"]
        if dontAllow.waitForExistence(timeout: 5) {
            dontAllow.tap()
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "The app must still be running", file: file, line: line)
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// A 48×32 red tile with a white block, so the canvas has real image bounds.
    private static let composerImagePNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAADAAAAAgCAIAAADbtmxLAAAASUlEQVR42u3XsQ0AIAgFUTAOAxO4f6cTsI4b2BF/cddS8BIqfEeYUsPEAgQIUHfzPV5VTYtPJicDBAgQIECAACnk/GWAAAH63AU51wVxubmRQwAAAABJRU5ErkJggg=="
}
