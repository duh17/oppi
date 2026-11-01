import XCTest

/// Taps through every router modal and side panel chat owns, on the
/// production ChatViewController with fixture services (`SCREENSHOT_SCREEN=chat-routes`).
/// Each modal opens, any push inside it is tapped through and popped, it closes
/// by its own control and, where it is a sheet, by swipe-down, and the app is
/// still running after every step: a hosted page that lost a presenter-local
/// service crashes on its first read. Where a modal edits chat state, the edit
/// is read back from the chat.
@MainActor
final class ChatRoutesUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Chat route tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    // MARK: - Top bar

    // Which buttons a layout puts on the bar and in the … menu, and in what
    // order, is `ChatTopBarLayoutTests`; what the Top Bar page shows and
    // writes is `SettingsChatTopBarPageTests`. These tests are the bar the
    // chat draws from a stored layout, the system menu, and the push to the
    // page.

    /// The default bar (the context ring alone, with Files, Git, Outline, and
    /// Terminal in the … menu) and its one-time hint: it shows under the bar
    /// of a chat on the default bar and says where the other tools went.
    /// Opening the menu is finding them, so the hint goes and stays gone after
    /// a relaunch. The menu keeps each item's glance on its label's line
    /// (Git's changes here).
    func testDefaultBarHintPointsAtTheMenuUntilItIsOpened() {
        // The default layout is pinned in the volatile domain, so this reads
        // the default and not whatever an earlier run saved on this simulator.
        launchScreen("chat-top-bar-default", arguments: ["--reset-feature-tips"])
        let tip = app.descendants(matching: .any)["feature-tip.chat-top-bar-more.tip"]
        XCTAssertTrue(tip.waitForExistence(timeout: 15), "A chat on the default bar must show the chat tools hint")
        XCTAssertTrue(app.buttons["chat.toolbar.context"].exists, "The context ring is the default bar")
        for id in ["files", "git", "outline", "terminal"] {
            XCTAssertFalse(app.buttons["chat.toolbar.\(id)"].exists, "\(id) is in the menu by default, not the bar")
        }
        let message = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Pin them to the top bar in Settings"))
            .firstMatch
        XCTAssertTrue(message.exists, "The hint must say where to pin the tools")
        attachScreenshot("chat-top-bar-hint")

        app.buttons["chat.toolbar.more"].tap()
        let git = app.buttons["chat.toolbar.menu.git"]
        XCTAssertTrue(git.waitForExistence(timeout: 5), "The menu must offer Git")
        XCTAssertTrue(
            git.label.hasPrefix("Git") && git.label.contains("+2"),
            "Git's menu item must carry its changes on its line: \(git.label)"
        )
        // Terminal too: the harness workspace has a folder a shell can start in.
        for id in ["files", "outline", "terminal"] {
            XCTAssertTrue(app.buttons["chat.toolbar.menu.\(id)"].exists, "The menu must offer \(id)")
        }
        XCTAssertTrue(app.buttons["Customize Top Bar…"].exists, "The … menu must offer Customize Top Bar…")
        attachScreenshot("chat-top-bar-menu-glance")
        app.buttons["chat.toolbar.menu.outline"].tap()
        let outline = app.buttons["chat.outline.close"]
        XCTAssertTrue(outline.waitForExistence(timeout: 5), "Outline must open from the menu")
        outline.tap()
        XCTAssertTrue(outline.waitForNonExistence(timeout: 5), "Close must close the outline")
        XCTAssertFalse(tip.exists, "Opening the menu must retire the hint")

        app.terminate()
        launchScreen("chat-top-bar-default")
        XCTAssertTrue(app.buttons["chat.toolbar.context"].waitForExistence(timeout: 15))
        XCTAssertFalse(tip.waitForExistence(timeout: 3), "The hint shows once")
        assertRunning()
    }

    /// The Duo's vertical rail (sim-pool `duo` profile): every pinned action is
    /// a rail item, Git's logo among them, in the chosen order top to bottom.
    /// Elsewhere there is no rail and the test skips.
    func testVerticalRailCarriesTheGitLogoInOrder() throws {
        launchScreen("chat-top-bar-all")
        XCTAssertTrue(app.buttons["chat.toolbar.context"].waitForExistence(timeout: 15), "The all-on bar must load")
        guard app.buttons["chat.rail.session"].exists else {
            throw XCTSkip("No vertical toolbar rail on this device")
        }
        let order = ["files", "git", "outline", "context", "terminal"].map { app.buttons["chat.toolbar.\($0)"] }
        for item in order {
            XCTAssertTrue(item.exists, "\(item) must be on the rail")
        }
        assertTopToBottom(order, "The rail")
        let git = app.buttons["chat.toolbar.git"]
        let outline = app.buttons["chat.toolbar.outline"]
        XCTAssertEqual(git.frame.width, outline.frame.width, accuracy: 2, "Git's rail item must be a standard rail item")
        attachScreenshot("chat-rail-git-logo")
        assertRunning()
    }

    /// A customized bar, every button on in a chosen order: the bar reads the
    /// stored order left to right, the … menu holds nothing but Customize Top
    /// Bar…, and that opens the Top Bar page listing the same order with a
    /// reorder handle on every row. A customized bar needs no hint about where
    /// its buttons went. A three-character Git count ("99+") fits Git's slot:
    /// every control keeps one even pitch, Git does not run into the button
    /// after it, and the button still says the full count.
    func testTopBarFollowsTheChosenOrder() {
        launchScreen(
            "chat-top-bar-reordered",
            environment: ["CHAT_ROUTES_MANY_CHANGES": "1"],
            arguments: ["--reset-feature-tips"]
        )
        let ids = ["outline", "files", "context", "git", "terminal"]
        for id in ids {
            XCTAssertTrue(app.buttons["chat.toolbar.\(id)"].waitForExistence(timeout: 15), "\(id) must be on the bar")
        }
        assertLeftToRight(ids.map { app.buttons["chat.toolbar.\($0)"] }, "The reordered bar")

        let git = app.buttons["chat.toolbar.git"]
        XCTAssertTrue(
            // Changes, not touches: the touched files Git reports (121 of 122).
            waitFor((git.value as? String)?.contains("121 changed files") == true, timeout: 10),
            "The Git button must say the full count: \(git.value ?? "nil")"
        )
        XCTAssertLessThanOrEqual(
            git.frame.maxX, app.buttons["chat.toolbar.terminal"].frame.minX,
            "The badge's button must end before Terminal starts"
        )
        let centers = (ids + ["more"]).map { app.buttons["chat.toolbar.\($0)"].frame.midX }.sorted()
        let pitches = zip(centers.dropFirst(), centers).map { $0 - $1 }
        XCTAssertLessThan(
            (pitches.max() ?? 0) - (pitches.min() ?? 0), 1,
            "The bar's controls must sit on one pitch: \(pitches)"
        )
        attachScreenshot("chat-top-bar-reordered")
        XCTAssertFalse(
            app.descendants(matching: .any)["feature-tip.chat-top-bar-more.tip"].waitForExistence(timeout: 4),
            "A customized bar must not show the chat tools hint"
        )

        app.buttons["chat.toolbar.more"].tap()
        let customize = app.buttons["Customize Top Bar…"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5), "The … menu stays")
        XCTAssertFalse(
            app.buttons["chat.toolbar.menu.files"].exists,
            "Nothing is hidden, so the … menu holds only Customize Top Bar…"
        )
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
        XCTAssertTrue(summary.contains("Context"), "The row must summarize the layout, not the label again: \(summary)")
        row.tap()
        XCTAssertTrue(app.navigationBars["Top Bar"].waitForExistence(timeout: 5), "The Top Bar row must push its page")
        XCTAssertTrue(
            app.switches["settings.chat.topBar.files"].waitForExistence(timeout: 5),
            "The pushed page must be the Top Bar page"
        )
        assertRunning()
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
        assertOpenInColumn("chat.toolbar.outline")
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
        XCTAssertTrue(outline.waitForNonExistence(timeout: 5), "Close must close the outline")
        assertRunning()

        if usesSheets {
            outlineButton.tap()
            XCTAssertTrue(outline.waitForExistence(timeout: 5), "Outline did not reopen")
            dragToBottom(outline)
            XCTAssertTrue(outline.waitForNonExistence(timeout: 5), "Swipe-down must close the outline sheet")
            outlineButton.tap()
            XCTAssertTrue(outline.waitForExistence(timeout: 5), "The binding cleared on swipe-down, so the button reopens it")
            app.buttons["chat.outline.close"].tap()
            XCTAssertTrue(outline.waitForNonExistence(timeout: 5))
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
                search.waitForNonExistence(timeout: 5),
                "Selecting a search hit must dismiss the outline search field so the chat is visible"
            )
            XCTAssertTrue(outline.waitForNonExistence(timeout: 5), "Selecting a row must close the outline")
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
            // A row near the tail cannot reach the top edge when less than a
            // viewport of content follows it (a tall iPad): the timeline then
            // rests at its scroll limit with the row visible and lit. Only the
            // last turn is near enough the tail for that.
            XCTAssertTrue(
                (turn == 171 && settled.contains(" end=1"))
                    || ["@0 ", "@1 ", "@-1 "].contains { settled.contains("top=\(target)\($0)") },
                "Outline jump to \(target) must land its top edge under the chrome: \(settled)"
            )
        }
        assertRunning()
    }

    /// The Files panel is the checkout's browser alone (what changed is the
    /// Git panel's): Git's marks on a changed folder and file, View Options
    /// sorting, the Everywhere / this-folder search scope, and a file pushes
    /// its reader inside the panel.
    func testFilesPanelBrowsesTheCheckoutAndCloses() {
        launch()
        app.buttons["chat.toolbar.files"].tap()
        let files = app.navigationBars["Files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "Files panel did not open")
        XCTAssertTrue(app.searchFields["Search files"].waitForExistence(timeout: 5), "The browser must search in the panel's bar")
        XCTAssertTrue(app.buttons["fileBrowser.viewOptions"].exists, "The panel's bar must offer View Options")
        // The folder's row, not a timeline pill: Git changed a file inside it.
        let sources = app.buttons["fileBrowser.row.Sources/"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5), "The root must list the Sources folder")
        XCTAssertTrue(sources.label.contains("Contains changes"), "The root must mark the folder that holds a change: \(sources.label)")
        attachScreenshot("files-panel-browser")

        // View Options sorts: Alpha.txt is first by name, Route.md (newer)
        // first by date.
        let alphaRow = app.buttons["fileBrowser.row.Alpha.txt"]
        let routeRow = app.buttons["fileBrowser.row.Route.md"]
        XCTAssertTrue(routeRow.waitForExistence(timeout: 5), "The root listing did not load")
        sortFiles(by: "name")
        XCTAssertTrue(waitFor(alphaRow.frame.minY < routeRow.frame.minY), "Name order lists Alpha.txt before Route.md")
        sortFiles(by: "modified")
        XCTAssertTrue(waitFor(routeRow.frame.minY < alphaRow.frame.minY), "Newest first lists Route.md before Alpha.txt")
        attachScreenshot("files-panel-sorted-by-date")
        sortFiles(by: "name")
        XCTAssertTrue(waitFor(alphaRow.frame.minY < routeRow.frame.minY), "Back to name order")

        // Inside Sources/ the changed file carries Git's dot and counts.
        sources.tap()
        let sourcesBar = app.navigationBars["Sources"]
        XCTAssertTrue(sourcesBar.waitForExistence(timeout: 5), "The Sources folder did not open")
        let row = app.buttons["fileBrowser.row.Sources/App.swift"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The Sources folder must list App.swift")
        XCTAssertTrue(
            waitFor(row.label.contains("Modified, 2 added, 1 removed")),
            "The changed file must carry Git's mark: \(row.label)"
        )
        attachScreenshot("files-panel-changed-file")

        // Search scope: "route" from Sources/ finds Route.md (root) and
        // RouteView.swift everywhere, only RouteView.swift in this folder.
        let search = app.searchFields["Search files"]
        search.tap()
        search.typeText("route")
        let rootHit = app.buttons["fileBrowser.row.Route.md"]
        let folderHit = app.buttons["fileBrowser.row.Sources/RouteView.swift"]
        let scopes = app.segmentedControls["fileBrowser.searchScope"]
        XCTAssertTrue(scopes.waitForExistence(timeout: 5), "Searching below the root must offer Everywhere / this folder")
        XCTAssertTrue(rootHit.waitForExistence(timeout: 5), "Everywhere must find the root's Route.md")
        XCTAssertTrue(folderHit.exists, "Everywhere must find Sources/RouteView.swift")
        attachScreenshot("files-panel-search-everywhere")
        scopes.buttons["Sources"].tap()
        XCTAssertTrue(rootHit.waitForNonExistence(timeout: 5), "This folder must drop Route.md, which is outside Sources/")
        XCTAssertTrue(folderHit.exists, "This folder must keep Sources/RouteView.swift")
        attachScreenshot("files-panel-search-this-folder")
        scopes.buttons["Everywhere"].tap()
        XCTAssertTrue(rootHit.waitForExistence(timeout: 5), "Everywhere must bring Route.md back")
        app.dismissSearch(search)

        XCTAssertTrue(row.waitForExistence(timeout: 5), "Ending the search must show the folder again")
        row.tap()
        popPushedReader(returningTo: sourcesBar, "The workspace file")
        app.buttons["fileBrowser.inlineBack"].tap()
        XCTAssertTrue(files.waitForExistence(timeout: 5), "Back must return to the root")

        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
            XCTAssertTrue(files.waitForNonExistence(timeout: 5), "Done must close the files panel")
        } else {
            app.buttons["chat.toolbar.files"].tap()
            XCTAssertTrue(files.waitForNonExistence(timeout: 5), "The files button must close the column")
        }
        assertRunning()

        if usesSheets {
            app.buttons["chat.toolbar.files"].tap()
            XCTAssertTrue(files.waitForExistence(timeout: 5))
            dragToBottom(files)
            XCTAssertTrue(files.waitForNonExistence(timeout: 5), "Swipe-down must close the files sheet")
        }
        assertRunning()
    }

    func testContextOpensAndCloses() {
        launch()
        app.buttons["chat.toolbar.context"].tap()
        let context = app.navigationBars["Context"]
        XCTAssertTrue(context.waitForExistence(timeout: 5), "Context did not open")
        assertOpenInColumn("chat.toolbar.context")
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
        XCTAssertTrue(context.waitForNonExistence(timeout: 5), "Close must close Context")
        if usesSheets {
            app.buttons["chat.toolbar.context"].tap()
            XCTAssertTrue(context.waitForExistence(timeout: 5))
            dragToBottom(context)
            XCTAssertTrue(context.waitForNonExistence(timeout: 5), "Swipe-down must close the Context sheet")
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
        XCTAssertTrue(models.waitForNonExistence(timeout: 5), "Swipe-down must close the model picker")
        modelPill.tap()
        XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not reopen")
        cancelButton.tap()
        XCTAssertTrue(models.waitForNonExistence(timeout: 5), "Cancel must close the model picker")
        assertRunning()

        app.buttons["session.toolbar.thinking"].tap()
        let high = app.buttons["session.toolbar.thinking.option.high"]
        XCTAssertTrue(high.waitForExistence(timeout: 5), "Thinking popover did not open")
        attachScreenshot("thinking-popover")
        high.tap()
        XCTAssertTrue(high.waitForNonExistence(timeout: 5), "Choosing a level must close the popover")
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
        XCTAssertTrue(followUp.waitForNonExistence(timeout: 5), "Choosing a mode must close the popover")
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
        app.buttons["expanded.composer.model"].tap()
        let models = app.navigationBars["Models"]
        XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not open above the composer")
        dragToBottom(models)
        XCTAssertTrue(models.waitForNonExistence(timeout: 5))
        XCTAssertTrue(editor.exists, "Closing the picker must keep the composer")

        app.buttons["expanded.composer.cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Cancel must close the expanded composer")
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
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Swipe-down must close the ask sheet")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Which route next?")).firstMatch
                .waitForExistence(timeout: 5),
            "The sheet's page must reach the inline card"
        )
        expand.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The binding cleared on swipe-down, so expand reopens it")
        XCTAssertTrue(app.staticTexts["Question 2 of 2"].exists, "The reopened sheet starts on the card's page")
        app.buttons["ask.expanded.collapse"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Collapse must close the ask sheet")
        assertRunning()
    }

    /// A queued report taller than the screen stays inside the drawer: its
    /// collapse button and Edit in composer stay on screen, a double tap opens
    /// the message rendered in the reader, and the drawer still collapses.
    func testLongQueuedMessageKeepsTheDrawerCollapsibleAndOpensFullScreen() {
        launch(environment: ["CHAT_ROUTES_QUEUE": "long"])
        let pill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-message-queue"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "The queued report shows the queue pill")
        pill.tap()

        let collapse = app.buttons["extension-strip-aboveEditor-drawer-collapse"]
        let edit = app.buttons["chat.messageQueue.editInComposer"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Expanding the queue shows Edit in composer")
        XCTAssertTrue(collapse.isHittable, "A long report must not push the collapse button off screen")
        XCTAssertTrue(edit.isHittable, "A long report must not push Edit in composer off screen")
        attachScreenshot("message-queue-long-expanded")

        app.descendants(matching: .any)["chat.messageQueue.message.routes-queued-report"].doubleTap()
        let body = app.descendants(matching: .any)["full-screen.markdown.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5), "A double tap opens the queued message rendered")
        attachScreenshot("message-queue-full-screen")
        app.buttons["fullScreen.code.close"].tap()
        XCTAssertTrue(body.waitForNonExistence(timeout: 5), "Back returns to the chat")

        XCTAssertTrue(waitFor(collapse.isHittable), "The drawer is still open after the reader")
        collapse.tap()
        XCTAssertTrue(edit.waitForNonExistence(timeout: 5), "Collapse closes the queue drawer")
        assertRunning()
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
        XCTAssertTrue(app.navigationBars["Canvas"].waitForNonExistence(timeout: 5), "Add to Chat must close the canvas")
        XCTAssertTrue(
            waitFor(app.descendants(matching: .any)["chat.input"].isHittable),
            "The composer must be back after Add to Chat"
        )
        XCTAssertTrue(composerImageTile().exists, "The annotated image must stay in the composer")

        openAnnotateCanvas(from: composerImageTile())
        app.buttons["composer.canvas.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Canvas"].waitForNonExistence(timeout: 5), "Cancel must close the canvas")
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
        XCTAssertTrue(app.navigationBars["Canvas"].waitForNonExistence(timeout: 5), "Cancel must close the expanded canvas")
        XCTAssertTrue(
            waitFor(expandedEditor.isHittable),
            "The expanded composer must be back after Cancel"
        )
        app.buttons["expanded.composer.cancel"].tap()
        XCTAssertTrue(expandedEditor.waitForNonExistence(timeout: 5), "The expanded composer must close")
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
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        // The sheet lists the chat's comments; reopening the editor reads the
        // saved body back from them.
        edit.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Route comment edited", "The edit must reach the chat's comments")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        attachScreenshot("stash-edited")
        dragToBottom(edit)
        XCTAssertTrue(edit.waitForNonExistence(timeout: 5), "Swipe-down must close the stash sheet")
        assertRunning()

        pill.doubleTap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "The stash sheet did not reopen")
        cancelButton.tap()
        XCTAssertTrue(edit.waitForNonExistence(timeout: 5), "Close must close the stash sheet")
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
        XCTAssertTrue(share.waitForNonExistence(timeout: 5), "Cancel must close the share sheet")

        openShareSheet()
        XCTAssertEqual(app.switches["Email Addresses"].value as? String, "0", "The edited policy must be remembered")
        if usesSheets {
            dragToBottom(share)
            XCTAssertTrue(share.waitForNonExistence(timeout: 5), "Swipe-down must close the share sheet")
        } else {
            cancelButton.tap()
            XCTAssertTrue(share.waitForNonExistence(timeout: 5))
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
        XCTAssertTrue(commit.waitForNonExistence(timeout: 5), "Close must close the commit sheet")
        let created = app.descendants(matching: .any)["chatRoutes.createdSessions"]
        XCTAssertEqual(created.value as? String, "1", "The stub must have received the new session")
        tapCommitRow()
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        dragToBottom(commit)
        XCTAssertTrue(commit.waitForNonExistence(timeout: 5), "Swipe-down must close the commit sheet")
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
        // The graph's first page fits on screen, so Load more fetches page two.
        let baseCommit = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Base commit")).firstMatch
        XCTAssertFalse(baseCommit.exists, "The base commit is on the graph's second page")
        let loadMore = app.buttons["Load more"]
        XCTAssertTrue(loadMore.waitForExistence(timeout: 5), "A graph with more pages must offer Load more")
        loadMore.tap()
        XCTAssertTrue(baseCommit.waitForExistence(timeout: 5), "Load more must append the next page")
        XCTAssertTrue(loadMore.waitForNonExistence(timeout: 5), "The last page must leave no Load more")
        assertOpenInColumn("chat.toolbar.git")
        let otherChange = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "README.md")).firstMatch
        XCTAssertFalse(otherChange.exists, "This session must not list a change the session did not make")
        let scope = app.segmentedControls["workspace-context-bar.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "A main-checkout session must offer This session / All changes")
        XCTAssertTrue(
            app.staticTexts["workspace-context-bar.sessionNote"].exists,
            "This session must say it is approximate"
        )
        attachScreenshot("git-panel-this-session")

        // A file the session wrote that Git does not report opens the
        // session's copy, not a diff.
        let sessionCopyRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "plan.md", "No diff")
        ).firstMatch
        XCTAssertTrue(sessionCopyRow.waitForExistence(timeout: 5), "This session must list a touched file Git does not report")
        sessionCopyRow.tap()
        let sessionCopyBack = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(sessionCopyBack.waitForExistence(timeout: 10), "The session's copy did not open")
        attachScreenshot("git-panel-session-copy")
        sessionCopyBack.tap()
        XCTAssertTrue(sessionCopyBack.waitForNonExistence(timeout: 5), "Back must close the session's copy")
        XCTAssertTrue(panel.exists, "Closing the session's copy must leave the Git panel open")
        // The summary counts what the list shows.
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "2 touched \u{00B7} 1 with changes")).firstMatch.exists,
            "This session's summary must count every touched file and the ones Git has"
        )

        // Select picks only Git's files: the server refuses any other path.
        app.buttons["Select"].tap()
        app.buttons["Select All"].tap()
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5), "Select All must skip the no-diff file")
        // While selecting, the no-diff row reads as dimmed text, not a button.
        let unselectableRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "plan.md", "No diff")
        ).firstMatch
        XCTAssertTrue(unselectableRow.exists, "While selecting, the no-diff row must not be a button")
        XCTAssertFalse(unselectableRow.isEnabled, "While selecting, the no-diff row must read as not enabled")
        unselectableRow.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists, "A no-diff row cannot be selected")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5))

        scope.buttons["All changes (2)"].tap()
        XCTAssertTrue(otherChange.waitForExistence(timeout: 5), "All changes must list every change")
        XCTAssertFalse(sessionCopyRow.exists, "All changes lists Git's changes only")
        attachScreenshot("git-panel-all-changes")
        scope.buttons["This session"].tap()
        XCTAssertTrue(otherChange.waitForNonExistence(timeout: 5), "This session must narrow the list again")

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
        XCTAssertTrue(review.waitForNonExistence(timeout: 5), "Close must close the file review")
        fileRow.tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        dragToBottom(review)
        XCTAssertTrue(review.waitForNonExistence(timeout: 5), "Swipe-down must close the file review")
        XCTAssertTrue(panel.exists, "Closing the review must leave the Git panel open")
        assertRunning()

        app.buttons["git.panel.close"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Close must close the Git panel")
        if usesSheets {
            openGitPanel()
            dragToBottom(panel)
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Swipe-down must close the Git sheet")
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
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10), "Starting a session must close the Git panel")
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
        XCTAssertTrue(commit.waitForNonExistence(timeout: 5), "Close must close the commit viewer")
        assertRunning()

        app.buttons["chatRoutes.openFileViewer"].tap()
        let back = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "File viewer did not open with its back control")
        attachScreenshot("file-viewer")
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 5), "Back at the viewer's root must close it")
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
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Swipe-down must close the summary sheet")

        node.tap()
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Summary sheet did not reopen")
        let editor = app.textViews["tree-summary-instructions"]
        editor.tap()
        editor.typeText("keep router notes")
        app.buttons["tree-summary-navigate"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Navigate must close the summary sheet")
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
    /// Sorts by View Options' `key` in its own starting direction (names A to
    /// Z, dates newest first): another key first, so the pick is a new key
    /// and not a reversal of a choice an earlier run left on the device.
    private func sortFiles(by key: String) {
        for pick in [key == "kind" ? "size" : "kind", key] {
            app.buttons["fileBrowser.viewOptions"].tap()
            let item = app.buttons["fileBrowser.sort.\(pick)"]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "View Options must offer sort \(pick)")
            item.tap()
        }
    }

    private func popPushedReader(returningTo bar: XCUIElement, _ name: String) {
        let back = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "\(name) reader was not pushed")
        assertRunning()
        // The reader brings its own Back, so the panel's bar under it hides:
        // once the text loads, and animated.
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "\(name) reader shows the panel's bar above its own Back")
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
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Close must close the diff panel")
        if usesSheets {
            fileRow.tap()
            let diff = app.navigationBars["App.swift"]
            XCTAssertTrue(diff.waitForExistence(timeout: 5))
            dragToBottom(diff)
            XCTAssertTrue(diff.waitForNonExistence(timeout: 5), "Swipe-down must close the diff sheet")
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

    /// A chat preview whose test waits for the panel or bar it drives, so the
    /// launch does not also wait on the host's `screenshot.ready` marker.
    private func launchScreen(_ screen: String, environment: [String: String] = [:], arguments: [String] = []) {
        launchPreview(screen: screen, environment: environment, arguments: arguments, ready: nil)
    }

    /// In the trailing column (regular width) the panel's bar button stays on
    /// screen beside it and reads as selected; no other panel button does.
    /// A compact-width sheet covers the bar, so there is nothing to check.
    private func assertOpenInColumn(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        guard !usesSheets else { return }
        XCTAssertTrue(
            waitFor(app.buttons[identifier].isSelected),
            "\(identifier) must read as selected while its panel is open in the column",
            file: file,
            line: line
        )
        for other in ["chat.toolbar.files", "chat.toolbar.git", "chat.toolbar.outline", "chat.toolbar.context"]
        where other != identifier && app.buttons[other].exists {
            XCTAssertFalse(app.buttons[other].isSelected, "\(other) must not read as selected", file: file, line: line)
        }
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

    /// A 48×32 red tile with a white block, so the canvas has real image bounds.
    private static let composerImagePNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAADAAAAAgCAIAAADbtmxLAAAASUlEQVR42u3XsQ0AIAgFUTAOAxO4f6cTsI4b2BF/cddS8BIqfEeYUsPEAgQIUHfzPV5VTYtPJicDBAgQIECAACnk/GWAAAH63AU51wVxubmRQwAAAABJRU5ErkJggg=="
}
