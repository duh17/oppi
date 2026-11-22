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
    static var reusesLaunch: Bool { true }

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Chat route tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    // MARK: - Top bar

    // Which buttons a layout puts on the bar and in the … menu, and in what
    // order, is `ChatTopBarLayoutTests` and `BarPlacementTests`; what
    // Customize shows and writes is `BarCustomizePageTests`; the bar at 375 pt
    // is `ChatTopBarOverflowTests`. These tests are the bar the chat draws
    // from a stored layout, its … menu, and Customize as a sheet.

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
        XCTAssertTrue(tip.waitUntilExists(timeout: 15), "A chat on the default bar must show the chat tools hint")
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
        XCTAssertTrue(git.waitUntilExists(timeout: 5), "The menu must offer Git")
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
        XCTAssertTrue(outline.waitUntilExists(timeout: 5), "Outline must open from the menu")
        outline.tap()
        XCTAssertTrue(outline.waitUntilGone(timeout: 5), "Close must close the outline")
        XCTAssertFalse(tip.exists, "Opening the menu must retire the hint")

        app.terminate()
        launchScreen("chat-top-bar-default")
        XCTAssertTrue(app.buttons["chat.toolbar.context"].waitUntilExists(timeout: 15))
        XCTAssertFalse(tip.waitForExistence(timeout: 3), "The hint shows once")
        assertRunning()
    }

    /// The Duo's vertical rail (sim-pool `duo` profile): every pinned action is
    /// a rail item, Git's logo among them, in the chosen order top to bottom.
    /// Elsewhere there is no rail and the test skips.
    func testVerticalRailCarriesTheGitLogoInOrder() throws {
        launchScreen("chat-top-bar-all")
        XCTAssertTrue(app.buttons["chat.toolbar.context"].waitUntilExists(timeout: 15), "The all-on bar must load")
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
    /// stored order left to right, as many as its width holds, and the … menu
    /// holds the rest in the same order above Customize Top Bar… (an iPhone
    /// crowds some out; the iPad and the Duo rail hold all five). Customize
    /// opens as a sheet listing the same order with a reorder handle on every
    /// row; turning a button off leaves the bar behind the sheet, and Reset to
    /// Default brings the default bar back. A customized bar needs no hint
    /// about where its buttons went. A three-character Git count ("99+") fits
    /// Git's slot: every control keeps one even pitch, Git does not run into the
    /// button after it, and the button still says the full count.
    func testTopBarFollowsTheChosenOrder() {
        launchScreen(
            "chat-top-bar-reordered",
            environment: ["CHAT_ROUTES_MANY_CHANGES": "1"],
            arguments: ["--reset-feature-tips"]
        )
        let ids = ["outline", "files", "context", "git", "terminal"]
        XCTAssertTrue(app.buttons["chat.toolbar.outline"].waitUntilExists(timeout: 15), "The first button in the order must be on the bar")
        XCTAssertTrue(app.buttons["chat.toolbar.more"].exists, "… is always on the bar")
        // The Duo's vertical rail (`chat.rail.session`) runs the order down the
        // screen, so every position below is read along the bar's own axis.
        let onRail = app.buttons["chat.rail.session"].exists
        // What fits is the start of the order; the rest is crowded out.
        let drawn = ids.filter { app.buttons["chat.toolbar.\($0)"].exists }
        let crowdedOut = Array(ids.dropFirst(drawn.count))
        XCTAssertEqual(drawn, Array(ids.prefix(drawn.count)), "The bar must keep the first buttons in the order")
        XCTAssertGreaterThanOrEqual(drawn.count, 2, "Even an iPhone bar holds a few buttons: \(drawn)")
        if onRail || app.windows.firstMatch.frame.width >= 500 {
            XCTAssertEqual(drawn, ids, "A rail or a bar 500 pt wide holds every button")
        }
        let buttons = drawn.map { app.buttons["chat.toolbar.\($0)"] }
        if onRail {
            assertTopToBottom(buttons, "The reordered rail")
        } else {
            assertLeftToRight(buttons, "The reordered bar")
        }

        let git = app.buttons["chat.toolbar.git"]
        if drawn.contains("git") {
            XCTAssertTrue(
                // Changes, not touches: the touched files Git reports (121 of 122).
                waitFor((git.value as? String)?.contains("121 changed files") == true, timeout: 10),
                "The Git button must say the full count: \(git.value ?? "nil")"
            )
        }
        let terminal = app.buttons["chat.toolbar.terminal"]
        if drawn.contains("git"), drawn.contains("terminal") {
            XCTAssertLessThanOrEqual(
                onRail ? git.frame.maxY : git.frame.maxX, onRail ? terminal.frame.minY : terminal.frame.minX,
                "The badge's button must end before Terminal starts"
            )
        }
        // The rail's spacing is the system's, set by each item's own size: only the
        // bar this layout draws promises one even pitch.
        if !onRail {
            let centers = (drawn + ["more"]).map { app.buttons["chat.toolbar.\($0)"].frame.midX }.sorted()
            let pitches = zip(centers.dropFirst(), centers).map { $0 - $1 }
            XCTAssertLessThan(
                (pitches.max() ?? 0) - (pitches.min() ?? 0), 1,
                "The bar's controls must sit on one pitch: \(pitches)"
            )
        }
        attachScreenshot("chat-top-bar-reordered")
        XCTAssertFalse(
            app.descendants(matching: .any)["feature-tip.chat-top-bar-more.tip"].waitForExistence(timeout: 4),
            "A customized bar must not show the chat tools hint"
        )

        app.buttons["chat.toolbar.more"].tap()
        let customize = app.buttons["Customize Top Bar…"]
        hold()
        XCTAssertTrue(customize.waitUntilExists(timeout: 5), "The … menu stays")
        for id in ids {
            XCTAssertEqual(
                app.buttons["chat.toolbar.menu.\(id)"].exists, crowdedOut.contains(id),
                "The … menu holds exactly the buttons the bar had no room for: \(crowdedOut)"
            )
        }
        attachScreenshot("chat-top-bar-overflow-menu")
        customize.tap()
        XCTAssertTrue(app.navigationBars["Top Bar"].waitUntilExists(timeout: 5))
        let rows = ["outline", "files", "context", "git", "terminal"].map { "settings.chat.topBar.row.\($0)" }
        for id in rows {
            XCTAssertTrue(app.cells[id].waitUntilExists(timeout: 5), "\(id) must be a row")
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

        // A sheet over the chat, so the bar stays in view above it. The harness
        // pins its layout in the volatile domain, which a switch cannot
        // override; what a switch and Reset write is `BarCustomizePageTests`.
        XCTAssertTrue(app.buttons["chat.toolbar.more"].exists, "The chat's bar stays in view above the sheet")
        attachScreenshot("chat-customize-sheet")
        app.buttons["barCustomize.done"].tap()
        XCTAssertTrue(app.navigationBars["Top Bar"].waitUntilGone(timeout: 5), "Done closes the sheet")
        assertRunning()
    }

    /// Settings → Chat → Top Bar is a row that pushes the page, and its summary
    /// names the buttons the bar shows.
    func testSettingsChatTopBarRowOpensThePage() {
        launchScreen("settings-chat")
        let row = app.buttons["settings.chat.topBar"]
        XCTAssertTrue(row.waitUntilExists(timeout: 15), "The Chat settings page must show its Top Bar row")
        let summary = row.value as? String ?? ""
        XCTAssertTrue(summary.contains("Context"), "The row must summarize the layout, not the label again: \(summary)")
        row.tap()
        XCTAssertTrue(app.navigationBars["Top Bar"].waitUntilExists(timeout: 5), "The Top Bar row must push its page")
        XCTAssertTrue(
            app.switches["settings.chat.topBar.files"].waitUntilExists(timeout: 5),
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

    /// Regular width puts these beside the chat;
    /// compact width presents them as sheets.
    func testOutlineSearchesAndClosesBothWays() {
        launchWide()
        let outlineButton = app.buttons["chat.toolbar.outline"]
        XCTAssertTrue(outlineButton.waitUntilExists(timeout: 10), "Seeded timeline must make the outline available")
        outlineButton.tap()
        let outline = app.navigationBars["Session Outline"]
        XCTAssertTrue(outline.waitUntilExists(timeout: 5), "Outline did not open in a router navigation bar")
        assertOpenInColumn("chat.toolbar.outline")
        let search = outlineSearchField()
        search.tap()
        search.typeText("ROUTES_FILL_2")
        // Each outline row is one button whose label is its summary.
        hold()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ROUTES_FILL_2")).firstMatch
            .waitUntilExists(timeout: 5), "Search must keep the matching entry")
        attachScreenshot("outline-search")
        assertRunning()

        // On iPhone an active search bar takes over the bar's leading items;
        // end it first.
        let close = app.buttons["chat.outline.close"]
        if !(close.exists && close.isHittable) {
            app.buttons.matching(NSPredicate(format: "label ==[c] %@ AND identifier != %@", "close", "chat.outline.close"))
                .firstMatch.tap()
        }
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "Ending search must restore Close")
        close.tap()
        XCTAssertTrue(outline.waitUntilGone(timeout: 5), "Close must close the outline")
        assertRunning()

        if usesSheets {
            outlineButton.tap()
            XCTAssertTrue(outline.waitUntilExists(timeout: 5), "Outline did not reopen")
            dragToBottom(outline)
            XCTAssertTrue(outline.waitUntilGone(timeout: 5), "Swipe-down must close the outline sheet")
            outlineButton.tap()
            XCTAssertTrue(outline.waitUntilExists(timeout: 5), "The binding cleared on swipe-down, so the button reopens it")
            // A sheet's bar button can show as two elements while it presents (`dev/testing/apple.md`, Gotchas).
            app.buttons.matching(identifier: "chat.outline.close").firstMatch.tap()
            XCTAssertTrue(outline.waitUntilGone(timeout: 5))
        }
        assertRunning()
    }

    /// A long session (about 700 rows): an outline tap on a far row, one
    /// mid-session, and one near the tail each land that row's top edge just
    /// below the chat's top chrome, and the row lights up.
    func testOutlineJumpLandsOnTheTappedRow() {
        launch(environment: ["CHAT_ROUTES_LONG_TURNS": "175"])
        let outlineButton = app.buttons["chat.toolbar.outline"]
        XCTAssertTrue(outlineButton.waitUntilExists(timeout: 10), "Seeded timeline must make the outline available")
        let landing = app.staticTexts["chatRoutes.landing"]
        // Far rows (the whole history renders), one mid-session, one near the tail.
        for turn in [3, 21, 91, 171] {
            outlineButton.tap()
            let outline = app.navigationBars["Session Outline"]
            XCTAssertTrue(outline.waitUntilExists(timeout: 5), "Outline did not open")
            let search = outlineSearchField()
            search.tap()
            search.typeText("LONG_BASH_\(turn)")
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "echo LONG_BASH_\(turn) &&")).firstMatch
            XCTAssertTrue(row.waitUntilExists(timeout: 5), "Search must list bash \(turn)")
            row.tap()
            XCTAssertTrue(
                search.waitUntilGone(timeout: 5),
                "Selecting a search hit must dismiss the outline search field so the chat is visible"
            )
            XCTAssertTrue(outline.waitUntilGone(timeout: 5), "Selecting a row must close the outline")
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
        XCTAssertTrue(files.waitUntilExists(timeout: 5), "Files panel did not open")
        XCTAssertTrue(app.searchFields["Search files"].waitUntilExists(timeout: 5), "The browser must search in the panel's bar")
        XCTAssertTrue(app.buttons["fileBrowser.viewOptions"].exists, "The panel's bar must offer View Options")
        // The folder's row, not a timeline pill: Git changed a file inside it.
        let sources = app.buttons["fileBrowser.row.Sources/"]
        XCTAssertTrue(sources.waitUntilExists(timeout: 5), "The root must list the Sources folder")
        XCTAssertTrue(sources.label.contains("Contains changes"), "The root must mark the folder that holds a change: \(sources.label)")
        attachScreenshot("files-panel-browser")

        // View Options sorts: Alpha.txt is first by name, Route.md (newer)
        // first by date.
        let alphaRow = app.buttons["fileBrowser.row.Alpha.txt"]
        let routeRow = app.buttons["fileBrowser.row.Route.md"]
        XCTAssertTrue(routeRow.waitUntilExists(timeout: 5), "The root listing did not load")
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
        XCTAssertTrue(sourcesBar.waitUntilExists(timeout: 5), "The Sources folder did not open")
        let row = app.buttons["fileBrowser.row.Sources/App.swift"]
        XCTAssertTrue(row.waitUntilExists(timeout: 5), "The Sources folder must list App.swift")
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
        XCTAssertTrue(scopes.waitUntilExists(timeout: 5), "Searching below the root must offer Everywhere / this folder")
        XCTAssertTrue(rootHit.waitUntilExists(timeout: 5), "Everywhere must find the root's Route.md")
        XCTAssertTrue(folderHit.exists, "Everywhere must find Sources/RouteView.swift")
        attachScreenshot("files-panel-search-everywhere")
        scopes.buttons["Sources"].tap()
        XCTAssertTrue(rootHit.waitUntilGone(timeout: 5), "This folder must drop Route.md, which is outside Sources/")
        hold()
        XCTAssertTrue(folderHit.exists, "This folder must keep Sources/RouteView.swift")
        attachScreenshot("files-panel-search-this-folder")
        scopes.buttons["Everywhere"].tap()
        XCTAssertTrue(rootHit.waitUntilExists(timeout: 5), "Everywhere must bring Route.md back")
        app.dismissSearch(search)

        XCTAssertTrue(row.waitUntilExists(timeout: 5), "Ending the search must show the folder again")
        row.tap()
        popPushedReader(returningTo: sourcesBar, "The workspace file")
        app.buttons["fileBrowser.inlineBack"].tap()
        XCTAssertTrue(files.waitUntilExists(timeout: 5), "Back must return to the root")

        if app.buttons["fileBrowser.close"].exists {
            app.buttons["fileBrowser.close"].tap()
            XCTAssertTrue(files.waitUntilGone(timeout: 5), "Close must close the files panel")
        } else {
            app.buttons["chat.toolbar.files"].tap()
            XCTAssertTrue(files.waitUntilGone(timeout: 5), "The files button must close the column")
        }
        assertRunning()

        if usesSheets {
            app.buttons["chat.toolbar.files"].tap()
            XCTAssertTrue(files.waitUntilExists(timeout: 5))
            dragToBottom(files)
            XCTAssertTrue(files.waitUntilGone(timeout: 5), "Swipe-down must close the files sheet")
        }
        assertRunning()
    }

    func testContextOpensAndCloses() {
        launchWide()
        app.buttons["chat.toolbar.context"].tap()
        let context = app.navigationBars["Context"]
        XCTAssertTrue(context.waitUntilExists(timeout: 5), "Context did not open")
        assertOpenInColumn("chat.toolbar.context")
        // The window splits in request order; tools loaded on demand are listed apart.
        for segment in ["systemPrompt", "agentsFiles", "skills", "messages", "tools", "compactionReserve", "onDemand"] {
            XCTAssertTrue(
                app.cells["chat.context.segment.\(segment)"].waitUntilExists(timeout: 10),
                "Context is missing the \(segment) row"
            )
        }
        attachScreenshot("context")

        // Sections open collapsed; an MCP server lists its on-demand tools when opened.
        let servers = app.cells["chat.context.section.mcpServers"]
        scrollTo(servers)
        servers.tap()
        let docs = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "docs")).firstMatch
        XCTAssertTrue(docs.waitUntilExists(timeout: 5), "Opening MCP servers did not list the docs server")
        scrollTo(docs)
        docs.tap()
        XCTAssertTrue(
            app.cells.matching(NSPredicate(format: "label CONTAINS %@", "mcp__docs__search")).firstMatch
                .waitUntilExists(timeout: 5),
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
        XCTAssertTrue(extensionPage.waitUntilExists(timeout: 5), "The extension was not pushed inside Context")
        XCTAssertTrue(app.cells["chat.context.extension.edit"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "label CONTAINS %@", "forecast")).firstMatch.exists)
        attachScreenshot("context-extension")
        barButton(extensionPage, NSPredicate(format: "identifier == %@", "BackButton")).tap()
        XCTAssertTrue(context.waitUntilExists(timeout: 5), "Back must pop to Context")

        // A loaded skill, then one of its files, push inside the panel.
        let skills = app.cells["chat.context.section.skills"]
        scrollTo(skills)
        skills.tap()
        let skillRow = app.cells["chat.context.skill.route-skill"]
        XCTAssertTrue(skillRow.waitUntilExists(timeout: 10), "The session's loaded skill is missing")
        scrollTo(skillRow)
        skillRow.tap()
        let skill = app.navigationBars["route-skill"]
        XCTAssertTrue(skill.waitUntilExists(timeout: 5), "The skill was not pushed inside Context")
        let fileRow = app.buttons["notes.md"]
        XCTAssertTrue(fileRow.waitUntilExists(timeout: 5), "The skill's files did not load")
        fileRow.tap()
        popPushedReader(returningTo: skill, "The skill file")
        barButton(skill, NSPredicate(format: "identifier == %@", "BackButton")).tap()
        XCTAssertTrue(context.waitUntilExists(timeout: 5), "Back must pop to Context")
        assertRunning()

        app.buttons["chat.context.close"].tap()
        XCTAssertTrue(context.waitUntilGone(timeout: 5), "Close must close Context")
        if usesSheets {
            app.buttons["chat.toolbar.context"].tap()
            XCTAssertTrue(context.waitUntilExists(timeout: 5))
            dragToBottom(context)
            XCTAssertTrue(context.waitUntilGone(timeout: 5), "Swipe-down must close the Context sheet")
        }
        assertRunning()
    }

    // MARK: - Composer modals

    /// Model and thinking chosen from the composer's row. Regular width keeps
    /// "+", model, and thinking in the row without focus, as Quick Session
    /// does, with thinking as a pop-up menu; compact width shows the row with
    /// the keyboard and thinking as a popover. Both keep the option ids.
    func testModelAndThinkingSelectionFromTheComposer() {
        launch()
        let modelPill = app.buttons["session.toolbar.model"]
        if usesSheets {
            focusComposer()
            XCTAssertTrue(modelPill.waitUntilExists(timeout: 10), "A focused composer shows the model pill")
        } else {
            XCTAssertTrue(modelPill.waitUntilExists(timeout: 10), "Regular width keeps the model picker in the row without focus")
            XCTAssertTrue(app.buttons["chat.attach"].exists, "The + shares the row with the pickers")
            XCTAssertFalse(app.keyboards.firstMatch.exists, "The row shows without the keyboard")
        }
        modelPill.tap()
        let models = app.navigationBars["Models"]
        XCTAssertTrue(models.waitUntilExists(timeout: 5), "Model picker did not open")
        XCTAssertTrue(app.buttons["model.picker.row.openai/gpt-routes"].waitUntilExists(timeout: 5), "Model picker must list the chat's models")
        attachScreenshot("model-picker")
        if usesSheets {
            dragToBottom(models)
            XCTAssertTrue(models.waitUntilGone(timeout: 5), "Swipe-down must close the model picker")
        } else {
            // A popover at the pill, with the chat still visible. A width check alone misreads
            // the iPad mini in portrait, where a 380 pt popover is over half the window.
            XCTAssertTrue(app.otherElements["PopoverDismissRegion"].exists, "Regular width shows the picker as a popover")
            XCTAssertLessThan(models.frame.width, app.windows.firstMatch.frame.width, "The popover must not span the window")
            XCTAssertTrue(app.buttons["chat.toolbar.outline"].exists, "The chat's bar stays visible beside the popover")
            cancelButton.tap()
            XCTAssertTrue(models.waitUntilGone(timeout: 5), "Cancel must close the popover")
        }
        modelPill.tap()
        XCTAssertTrue(models.waitUntilExists(timeout: 5), "Model picker did not reopen")
        app.buttons["model.picker.row.openai/gpt-routes"].tap()
        XCTAssertTrue(models.waitUntilGone(timeout: 5), "Choosing a model must close the picker")
        XCTAssertTrue(
            waitFor((modelPill.value as? String) == "gpt-routes"),
            "The chosen model must read back on the pill: \(modelPill.value as? String ?? "nil")"
        )
        assertRunning()

        app.buttons["session.toolbar.thinking"].tap()
        let high = app.descendants(matching: .any)["session.toolbar.thinking.option.high"]
        XCTAssertTrue(high.waitUntilExists(timeout: 5), "The thinking levels did not open")
        assertThinkingOptionsRunMaxToLow()
        attachScreenshot(usesSheets ? "thinking-popover" : "thinking-menu")
        high.tap()
        XCTAssertTrue(high.waitUntilGone(timeout: 5), "Choosing a level must close the levels")
        assertRunning()
    }

    /// `@` offers the chat's models beside files; choosing one writes its
    /// canonical `provider/model-id` into the draft as plain text.
    func testAtMentionInsertsTheChosenModelID() {
        launch()
        focusComposer()
        let input = app.descendants(matching: .any)["chat.input"]
        input.typeText("Use @son")
        let row = app.buttons["composer.suggestion.model.anthropic/claude-sonnet-routes"]
        XCTAssertTrue(row.waitUntilExists(timeout: 5), "Typing @son must offer the Sonnet model")
        XCTAssertFalse(
            app.buttons["composer.suggestion.model.openai/gpt-routes"].exists,
            "A model the query does not match must not show"
        )
        attachScreenshot("model-mention-suggestions")
        row.tap()
        XCTAssertTrue(
            waitFor(self.text(of: input).contains("Use anthropic/claude-sonnet-routes")),
            "The chosen model's id must reach the draft: \(text(of: input))"
        )
        XCTAssertTrue(row.waitUntilGone(timeout: 5), "Choosing a model must close the suggestions")
        input.typeText("for implementation work")
        attachScreenshot("model-mention-inserted")
        assertRunning()
    }

    /// Models list above files without hiding them: a file row below the model
    /// rows still selects its own file.
    func testAtMentionKeepsFileRowsSelectableBelowModels() {
        launch()
        focusComposer()
        let input = app.descendants(matching: .any)["chat.input"]
        input.typeText("@route")
        XCTAssertTrue(
            app.buttons["composer.suggestion.model.openai/gpt-routes"].waitUntilExists(timeout: 5),
            "@route must offer the models whose names match; the draft reads: \(text(of: input))"
        )
        let file = app.buttons["composer.suggestion.file.Route.md"]
        XCTAssertTrue(file.waitUntilExists(timeout: 5), "@route must still offer the Route.md file row")
        file.tap()
        // The repo-file pill has no identifier: its name and remove control are the proof.
        XCTAssertTrue(
            app.staticTexts["Route.md"].waitUntilExists(timeout: 5) && app.buttons["Remove file"].exists,
            "Tapping the file row must attach that file, not a model"
        )
        XCTAssertFalse(
            text(of: app.descendants(matching: .any)["chat.input"]).contains("routes"),
            "A file choice must not insert a model id"
        )
    }

    func testBusyModePopoverChoiceReachesTheComposer() {
        launch(environment: ["CHAT_ROUTES_STATUS": "busy"])
        focusComposer()
        let busyMode = app.buttons["chat.busyMode"]
        XCTAssertTrue(busyMode.waitUntilExists(timeout: 10), "A busy session shows the send mode picker")
        XCTAssertEqual(busyMode.value as? String, "Steering")
        busyMode.tap()
        let followUp = app.buttons["chat.busyMode.option.followUp"]
        XCTAssertTrue(followUp.waitUntilExists(timeout: 5), "Busy mode popover did not open")
        attachScreenshot("busy-mode-popover")
        followUp.tap()
        XCTAssertTrue(followUp.waitUntilGone(timeout: 5), "Choosing a mode must close the popover")
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
        XCTAssertTrue(expand.waitUntilExists(timeout: 10), "A multi-line draft shows the expand button")
        expand.tap()
        let editor = app.textViews["expanded.composer.editor"]
        XCTAssertTrue(editor.waitUntilExists(timeout: 5), "Expanded composer did not open")
        editor.tap()
        editor.typeText("routed text")
        assertRunning()

        // The chat presents the picker; it stays live under the composer.
        app.buttons["expanded.composer.model"].tap()
        let models = app.navigationBars["Models"]
        XCTAssertTrue(models.waitUntilExists(timeout: 5), "Model picker did not open above the composer")
        // A sheet closes with a swipe down; a popover (regular width) has Cancel.
        if usesSheets { dragToBottom(models) } else { cancelButton.tap() }
        XCTAssertTrue(models.waitUntilGone(timeout: 5))
        hold()
        XCTAssertTrue(editor.exists, "Closing the picker must keep the composer")

        app.buttons["expanded.composer.cancel"].tap()
        XCTAssertTrue(editor.waitUntilGone(timeout: 5), "Cancel must close the expanded composer")
        let inline = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(waitFor(self.text(of: inline).contains("routed text")), "Typed text must reach the chat composer: \(text(of: inline))")
        assertRunning()
    }

    func testAskSheetPagesBackToTheCard() {
        launch(environment: ["CHAT_ROUTES_ASK": "1"])
        let expand = app.descendants(matching: .any)["ask.expand"]
        XCTAssertTrue(expand.waitUntilExists(timeout: 10), "Ask card did not appear")
        expand.tap()
        let sheet = app.descendants(matching: .any)["ask.approval.scroll"]
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "Expanded ask sheet did not open")
        attachScreenshot("ask-sheet")
        sheet.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Popover")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Next")).firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Question 2 of 2"].waitUntilExists(timeout: 5),
            "Answering the first question must page the sheet"
        )
        // From the header: a drag on the question list scrolls it.
        dragToBottom(app.staticTexts["Question 2 of 2"])
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "Swipe-down must close the ask sheet")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Which route next?")).firstMatch
                .waitUntilExists(timeout: 5),
            "The sheet's page must reach the inline card"
        )
        expand.tap()
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "The binding cleared on swipe-down, so expand reopens it")
        XCTAssertTrue(app.staticTexts["Question 2 of 2"].exists, "The reopened sheet starts on the card's page")
        app.buttons["ask.expanded.collapse"].tap()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "Collapse must close the ask sheet")
        assertRunning()
    }

    /// A custom answer typed into the composer and sent from an ask card, with the surface drawer
    /// open above the composer and the footer repainting under it as a busy session's does. The
    /// ask card covers the strip while it shows, so the drawer was opened first.
    func testAskCustomAnswerSendsWithTheSurfaceDrawerOpen() {
        runAskCustomAnswer(environment: ["CHAT_ROUTES_SURFACE": "tall"], opensDrawer: true)
    }

    func testAskCustomAnswerSendsWithoutADrawer() {
        runAskCustomAnswer(environment: [:], opensDrawer: false)
    }

    /// The same answer typed into the expanded ask sheet's own field and sent from the sheet.
    func testAskSheetCustomAnswerSendsWithTheSurfaceDrawerOpen() {
        runAskCustomAnswer(environment: ["CHAT_ROUTES_SURFACE": "tall"], opensDrawer: true, fromSheet: true)
    }

    private func runAskCustomAnswer(environment: [String: String], opensDrawer: Bool, fromSheet: Bool = false) {
        launch(environment: environment)
        let drawer = app.descendants(matching: .any)["extension-strip-aboveEditor-drawer-surface-query"]
        if opensDrawer {
            let pill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-surface-query"]
            XCTAssertTrue(pill.waitUntilExists(timeout: 10), "The published surface shows its pill")
            pill.tap()
            XCTAssertTrue(drawer.waitUntilExists(timeout: 5), "Tapping the pill opens its drawer")
        }
        app.buttons["chatRoutes.raiseAsk"].tap()
        let expand = app.descendants(matching: .any)["ask.expand"]
        XCTAssertTrue(expand.waitUntilExists(timeout: 10), "Ask card did not appear")
        attachScreenshot("ask-custom-raised")
        if fromSheet {
            expand.tap()
            let field = app.descendants(matching: .any)["ask.input"]
            XCTAssertTrue(field.waitUntilExists(timeout: 5), "The expanded ask sheet did not open")
            field.tap()
            field.typeText("a custom answer")
            XCTAssertTrue(app.keyboards.firstMatch.waitUntilExists(timeout: 5), "Sending must come with the keyboard up")
            attachScreenshot("ask-custom-typed")
            app.buttons["Send"].firstMatch.tap()
        } else {
            focusComposer()
            app.descendants(matching: .any)["chat.input"].typeText("a custom answer")
            XCTAssertTrue(app.keyboards.firstMatch.waitUntilExists(timeout: 5), "Sending must come with the keyboard up")
            attachScreenshot("ask-custom-typed")
            app.buttons["chat.send"].tap()
        }
        let allow = app.buttons["aiConsent.allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertTrue(expand.waitUntilGone(timeout: 10), "The answered ask card must leave the composer")
        hold()
        attachScreenshot("ask-custom-sent")
        if opensDrawer {
            XCTAssertTrue(drawer.waitUntilExists(timeout: 5), "The drawer comes back after the ask is answered")
        }
        assertRunning()
    }

    /// A queued report taller than the screen stays inside the drawer: its
    /// collapse button and Edit in composer stay on screen, a double tap opens
    /// the message rendered in the reader, and the drawer still collapses.
    func testLongQueuedMessageKeepsTheDrawerCollapsibleAndOpensFullScreen() {
        launch(environment: ["CHAT_ROUTES_QUEUE": "long"])
        let pill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-message-queue"]
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "The queued report shows the queue pill")
        pill.tap()

        let collapse = app.buttons["extension-strip-aboveEditor-drawer-collapse"]
        let edit = app.buttons["chat.messageQueue.editInComposer"]
        XCTAssertTrue(edit.waitUntilExists(timeout: 5), "Expanding the queue shows Edit in composer")
        XCTAssertTrue(collapse.isHittable, "A long report must not push the collapse button off screen")
        XCTAssertTrue(edit.isHittable, "A long report must not push Edit in composer off screen")
        attachScreenshot("message-queue-long-expanded")

        app.descendants(matching: .any)["chat.messageQueue.message.routes-queued-report"].doubleTap()
        let body = app.descendants(matching: .any)["full-screen.markdown.body"]
        XCTAssertTrue(body.waitUntilExists(timeout: 5), "A double tap opens the queued message rendered")
        attachScreenshot("message-queue-full-screen")
        app.buttons["fullScreen.code.close"].tap()
        XCTAssertTrue(body.waitUntilGone(timeout: 5), "Back returns to the chat")

        XCTAssertTrue(waitFor(collapse.isHittable), "The drawer is still open after the reader")
        collapse.tap()
        XCTAssertTrue(edit.waitUntilGone(timeout: 5), "Collapse closes the queue drawer")
        assertRunning()
    }

    /// Queueing a follow-up during a busy turn: the send scrolls the chat to its bottom, and the
    /// queue pill brings the strip up above the composer while that scroll still moves
    /// (`chatRoutes.queueFollowUp`). The working row must end above the strip once it settles;
    /// the inset growth used to be dropped mid-scroll, leaving the row under the pills.
    func testQueuedFollowUpKeepsTheWorkingRowAboveTheStrip() {
        runQueuedFollowUpKeepsTheWorkingRowAboveTheStrip(environment: [:]) {
            self.app.staticTexts["chat.timeline.working.text"]
        }
    }

    /// The same in Chat style, whose working row also carries the turn's folded work.
    func testQueuedFollowUpKeepsTheChatWorkingRowAboveTheStrip() {
        runQueuedFollowUpKeepsTheWorkingRowAboveTheStrip(
            environment: ["CHAT_ROUTES_CHAT_STYLE": "chat", "CHAT_ROUTES_LIVE_WORK": "1"]
        ) { self.workingRow }
    }

    private func runQueuedFollowUpKeepsTheWorkingRowAboveTheStrip(
        environment: [String: String],
        workingRow: () -> XCUIElement
    ) {
        launch(environment: environment.merging([
            "CHAT_ROUTES_STATUS": "busy",
            "CHAT_ROUTES_LONG_TURNS": "30",
            "CHAT_ROUTES_REVIEW_COMMENT": "none",
        ]) { $1 })
        let working = workingRow()
        XCTAssertTrue(working.waitUntilExists(timeout: 10), "A busy session shows the working row")
        let strip = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-message-queue"]
        XCTAssertFalse(strip.exists, "Nothing is queued yet, so no strip shows")

        // A little above the tail, so the send's scroll to the bottom moves.
        let timeline = app.collectionViews["chat.timeline"]
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(
                forDuration: 0.1,
                thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                withVelocity: .slow,
                thenHoldForDuration: 0.3
            )
        hold()
        app.buttons["chatRoutes.queueFollowUp"].tap()
        XCTAssertTrue(strip.waitUntilExists(timeout: 10), "The queued follow-up shows the queue pill")
        XCTAssertTrue(waitFor(strip.label.contains("1 follow-up") || (strip.value as? String)?.contains("1 follow-up") == true),
                      "The queue pill names only the follow-up: \(strip.label) \(strip.value as? String ?? "")")
        hold(for: 2)
        attachScreenshot("queued-follow-up-working-row")
        XCTAssertTrue(working.exists, "The working row stays while the turn runs")
        XCTAssertLessThanOrEqual(
            working.frame.maxY, strip.frame.minY + 0.5,
            "The working row (\(working.frame)) must end above the strip (\(strip.frame))"
        )
        assertRunning()
    }

    /// In Chat style a running turn is one row: the working row carries the turn's folded work
    /// (one control, its spinner and the turn's time and steps on one line). Its tap opens the
    /// steps under it, and when the turn ends the same control is the Worked pill.
    func testRunningTurnIsOneRowThatOpensItsStepsAndEndsAsTheWorkedPill() {
        launch(environment: [
            "CHAT_ROUTES_STATUS": "busy",
            "CHAT_ROUTES_LIVE_WORK": "1",
            "CHAT_ROUTES_CHAT_STYLE": "chat",
            "CHAT_ROUTES_REVIEW_COMMENT": "none",
        ])
        let row = workingRow
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The running turn shows its working row")
        XCTAssertEqual(row.value as? String, "Working, Collapsed")
        XCTAssertTrue(row.label.contains("1 step"), "The row carries the turn's steps: \(row.label)")
        XCTAssertFalse(
            app.staticTexts["chat.timeline.working.text"].exists,
            "No second working row under the turn's work"
        )
        attachScreenshot("running-turn-one-row")

        row.tap()
        XCTAssertTrue(waitFor((row.value as? String) == "Working, Expanded"), "The tap opens the turn's steps")
        let step = app.cells["chat.timeline.row.chat-routes-live-tool"]
        XCTAssertTrue(step.waitUntilExists(timeout: 5), "The running tool call shows under the row")
        XCTAssertGreaterThanOrEqual(step.frame.minY, row.frame.maxY - 1, "The steps open under the row")
        XCTAssertFalse(app.staticTexts["chat.timeline.working.text"].exists, "Still one working row")
        attachScreenshot("running-turn-steps-open")

        app.buttons["chatRoutes.endTurn"].tap()
        XCTAssertTrue(waitFor((row.value as? String) == "Expanded"), "The ended turn's row is the work pill")
        XCTAssertTrue(row.label.hasPrefix("Worked"), "The ended turn reads Worked: \(row.label)")
        attachScreenshot("running-turn-ended")
        assertRunning()
    }

    /// The running turn's one row (Chat style): the work line's own control.
    private var workingRow: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quiet-work-line:'")).firstMatch
    }

    /// A surface drawer taller than the space above the composer keeps its own height inside that
    /// space and scrolls: the Actions card at its foot is reachable, and its button reaches the
    /// socket. The session's activity clock ticks under the open drawer, as a busy session's does,
    /// and each tick repaints the footer; the button must live through that.
    func testTallSurfaceDrawerScrollsAboveTheComposerAndDispatchesItsAction() {
        runTallSurfaceDrawer()
    }

    /// The session's launch warnings are the strip's notice, never a banner: collapsed, the pill
    /// carries the short title only; a tap opens the drawer with the server's full text; Dismiss
    /// drops it.
    func testSessionLaunchWarningRidesTheNoticePillWithItsTextInTheDrawer() {
        launch(environment: ["CHAT_ROUTES_WARNINGS": "launch"])
        let pill = app.descendants(matching: .any)["chat.extensionNotify.chip"]
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "A launch warning shows its notice pill")
        XCTAssertTrue(pill.label.hasPrefix("Session warning"), "The pill names what it is: \(pill.label)")
        XCTAssertLessThanOrEqual(pill.frame.height, 44, "The warning is a strip pill, not a banner: \(pill.frame)")
        let drawer = app.descendants(matching: .any)["chat.extensionNotify.expanded"]
        XCTAssertFalse(drawer.exists, "The text waits for a tap")
        let fullText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "mcp__gmail__account"))
        XCTAssertEqual(fullText.count, 1, "Collapsed, the text is the pill's own label and no banner's")
        attachScreenshot("launch-warning-collapsed")

        pill.tap()
        XCTAssertTrue(drawer.waitUntilExists(timeout: 5), "Tapping the pill opens the drawer")
        XCTAssertTrue(fullText.firstMatch.waitUntilExists(timeout: 5), "The drawer shows the full warning")
        attachScreenshot("launch-warning-expanded")

        app.buttons["chat.extensionNotify.dismiss"].tap()
        XCTAssertTrue(pill.waitUntilGone(timeout: 5), "Dismiss drops the warning")
        assertRunning()
    }

    /// The same pill follows the notice policy: it leaves on its own after its reading time, so
    /// nothing about the launch stays above the composer.
    func testSessionLaunchWarningLeavesOnTheNoticePolicy() {
        launch(environment: ["CHAT_ROUTES_WARNINGS": "launch"])
        let pill = app.descendants(matching: .any)["chat.extensionNotify.chip"]
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "A launch warning shows its notice pill")
        XCTAssertTrue(pill.waitUntilGone(timeout: 25), "The notice policy removes the pill on its own")
        assertRunning()
    }

    private func runTallSurfaceDrawer() {
        launch(environment: ["CHAT_ROUTES_SURFACE": "tall"])
        let pill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-surface-query"]
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "The published surface shows its pill")
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(composer.waitUntilExists(timeout: 10))
        attachScreenshot("surface-collapsed")
        pill.tap()

        let drawer = app.descendants(matching: .any)["extension-strip-aboveEditor-drawer-surface-query"]
        let again = app.buttons["extension.surface.query.actions.again"]
        XCTAssertTrue(drawer.waitUntilExists(timeout: 5), "Tapping the pill opens its drawer")
        attachScreenshot("surface-expanded")
        XCTAssertLessThanOrEqual(
            drawer.frame.maxY, composer.frame.minY,
            "The drawer must end above the composer: \(drawer.frame) vs \(composer.frame)"
        )
        // The Duo's rail stands beside the chat, so nothing sits above the drawer but the screen's edge.
        let aboveDrawer = app.buttons["chat.rail.session"].exists
            ? app.windows.firstMatch.frame.minY
            : app.buttons["chat.toolbar.context"].frame.maxY
        XCTAssertGreaterThanOrEqual(
            drawer.frame.minY, aboveDrawer,
            "The drawer must start below the bar: \(drawer.frame)"
        )

        // The drawer's own scroll view takes the swipe: its viewport is a band inside the drawer
        // (the title row and padding stay put), and a swipe aimed at the whole drawer's center can
        // start on the title row, where nothing scrolls.
        let viewport = drawer.scrollViews.firstMatch
        for _ in 0..<8 where !(again.exists && again.isHittable) {
            viewport.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(again.isHittable, "Run again must scroll into reach: \(again.frame)")
        XCTAssertLessThanOrEqual(
            again.frame.maxY, composer.frame.minY,
            "Run again must sit above the composer: \(again.frame)"
        )
        attachScreenshot("surface-scrolled")
        // Held, so a repaint lands while the finger is down: a button replaced under it never
        // sends.
        again.press(forDuration: 0.5)
        XCTAssertTrue(
            waitFor(app.staticTexts["chatRoutes.surfaceActions"].label == "query/actions/again"),
            "Run again must reach the socket: \(app.staticTexts["chatRoutes.surfaceActions"].label)"
        )
        assertRunning()
    }

    /// Scrolling an open drawer's list leaves the timeline above the strip as it was. The
    /// timeline's bottom edge effect is shaped by what the footer holds, and UIKit counts the
    /// rows a drawer has scrolled out of its own viewport: those rows once dragged a frosted
    /// band up over the chat as far as they had scrolled.
    func testScrollingAnOpenDrawerLeavesTheTimelineAboveIt() throws {
        launch(environment: ["CHAT_ROUTES_SURFACE": "subagents-many", "CHAT_ROUTES_REVIEW_COMMENT": "none"])
        func element(_ kind: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "extension-strip-aboveEditor-\(kind)-", "subagents"
            )).firstMatch
        }
        let pill = element("pill")
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "The Subagents widget shows its pill")
        pill.tap()
        let drawer = element("drawer")
        XCTAssertTrue(drawer.waitUntilExists(timeout: 5), "Tapping the pill opens its drawer")
        hold()
        let firstRow = drawer.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "codemode-row")).firstMatch
        XCTAssertTrue(firstRow.exists, "The drawer lists the first working child")
        let rowTop = firstRow.frame.minY
        // The timeline from under the bar down to the strip, short of the soft fade the edge
        // effect keeps over the footer's top edge.
        let window = app.windows.firstMatch.frame
        let bandTop = app.buttons["chat.toolbar.context"].frame.maxY + 8
        let band = CGRect(x: window.minX, y: bandTop, width: window.width, height: pill.frame.minY - 50 - bandTop)
        let before = app.screenshot()
        attachScreenshot("drawer-open")

        drawer.scrollViews.firstMatch.swipeUp(velocity: .slow)
        hold()
        XCTAssertLessThan(firstRow.frame.minY, rowTop - 100, "The drawer's list scrolled: \(firstRow.frame.minY) vs \(rowTop)")
        let after = app.screenshot()
        attachScreenshot("drawer-scrolled")

        let changed = try changedPixelShare(before, after, in: band, window: window)
        XCTAssertLessThan(changed, 0.002, "The timeline above the strip changed while the drawer scrolled: \(changed) of \(band)")
        assertRunning()
    }

    /// The share of pixels in `rect` (points, in `window`) whose colour moved by more than a few
    /// levels between two screenshots of the app.
    private func changedPixelShare(
        _ first: XCUIScreenshot, _ second: XCUIScreenshot, in rect: CGRect, window: CGRect
    ) throws -> Double {
        func pixels(_ shot: XCUIScreenshot) throws -> (bytes: [UInt8], width: Int, height: Int) {
            let image = try XCTUnwrap(shot.image.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (bytes, image.width, image.height)
        }
        let a = try pixels(first)
        let b = try pixels(second)
        XCTAssertEqual(a.width, b.width)
        let scale = CGFloat(a.width) / window.width
        let rows = max(0, Int((rect.minY - window.minY) * scale))..<min(a.height, Int((rect.maxY - window.minY) * scale))
        let columns = max(0, Int((rect.minX - window.minX) * scale))..<min(a.width, Int((rect.maxX - window.minX) * scale))
        var changed = 0
        for y in rows {
            for x in columns {
                let offset = (y * a.width + x) * 4
                let delta = (0..<3).map { abs(Int(a.bytes[offset + $0]) - Int(b.bytes[offset + $0])) }.max() ?? 0
                if delta > 12 { changed += 1 }
            }
        }
        return Double(changed) / Double(max(1, rows.count * columns.count))
    }

    /// A surface placed as a panel (`placement.kind: "panel"`) has no drawer: its pill opens the
    /// surface in its pane under Oppi's bar with the surface's title and subtitle. Where it goes
    /// follows the fit rule, read from the window as the app reads it: beside the chat when both
    /// minimums fit (iPad mini landscape), full over the chat with Close on a wide window that
    /// cannot hold both (mini portrait), and full screen on a compact one.
    func testAPanelPlacedSurfaceOpensItsPaneFromThePill() throws {
        launch(environment: ["CHAT_ROUTES_SURFACE": "panel", "CHAT_ROUTES_REVIEW_COMMENT": "none"])
        let pill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-surface-jobs"]
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "The panel surface shows its pill")
        pill.tap()

        let bar = app.navigationBars["Jobs"]
        XCTAssertTrue(bar.waitUntilExists(timeout: 5), "The pill opens the surface's pane")
        let drawer = app.descendants(matching: .any)["extension-strip-aboveEditor-drawer-surface-jobs"]
        XCTAssertFalse(drawer.exists, "A panel surface has no drawer")
        XCTAssertTrue(app.staticTexts["npm test · running"].waitUntilExists(timeout: 5), "The pane draws the surface")
        let window = app.windows.firstMatch
        let wide = window.horizontalSizeClass == .regular
        // The chat's 375 pt beside a panel's 390 pt and the divider.
        let beside = wide && window.frame.width >= 375 + 1 + 390
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(
            waitFor(timeline.isHittable == beside),
            beside ? "Beside the chat when both fit" : "Over the chat when they do not (\(window.frame.width) pt)"
        )
        attachScreenshot(beside ? "panel-surface-beside-chat" : "panel-surface-full")

        if wide {
            app.buttons["extensionPanel.close"].tap()
        } else {
            bar.buttons.firstMatch.tap()
        }
        XCTAssertTrue(bar.waitUntilGone(timeout: 5), "The pane closes")
        assertRunning()
    }

    /// Opening a drawer grows the strip up over the timeline: the composer keeps the exact frame it
    /// has collapsed, the drawer spans the same column (never a narrower one sized to its content),
    /// and the timeline does not move, at its bottom or not: the drawer covers rows, never pushes
    /// them. Closing it leaves the composer where it was. Modes: a native widget (Subagents) and a
    /// composable surface (Background jobs); idle, and busy (steer composer) with a queued
    /// follow-up's pill beside the widget's; with the keyboard up; the chat's full width and the
    /// wide window's centred column (iPad landscape).
    func testOpeningAWidgetDrawerKeepsTheComposerWidth() {
        launch(environment: ["CHAT_ROUTES_SURFACE": "subagents", "CHAT_ROUTES_REVIEW_COMMENT": "none"])
        assertDrawerKeepsTheComposer(surface: "subagents", shot: "subagents")
    }

    func testOpeningAWidgetDrawerKeepsTheComposerWidthWide() {
        launchWide(environment: ["CHAT_ROUTES_SURFACE": "subagents", "CHAT_ROUTES_REVIEW_COMMENT": "none"])
        assertDrawerKeepsTheComposer(surface: "subagents", shot: "subagents-wide")
    }

    /// Each running activity row's working mark sits on its own title's line, the first under its
    /// section's header, in the drawer and in the panel pane. The pane lays its rows out once where
    /// the drawer measures them again and again, so a mark placed from a stale title position showed
    /// only there: half a row up, on the separator above, the first on the "Working" header.
    func testActivityRowMarkSitsOnItsTitleLineInTheDrawerAndThePane() {
        launchWide(environment: ["CHAT_ROUTES_SURFACE": "subagents-many", "CHAT_ROUTES_REVIEW_COMMENT": "none"])
        let pill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-widget-subagents"]
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "The surface shows its pill")
        pill.tap()
        let drawer = app.descendants(matching: .any)["extension-strip-aboveEditor-drawer-widget-subagents"]
        XCTAssertTrue(drawer.waitUntilExists(timeout: 5), "Tapping the pill opens its drawer")
        assertWorkingMarkOnItsTitleLine(in: drawer, host: "drawer")

        app.buttons["extension.strip.fullScreen.aboveEditor"].tap()
        let reader = app.descendants(matching: .any)["extension-native-surface-widget-subagents-detail"]
        XCTAssertTrue(reader.waitUntilExists(timeout: 5), "The drawer's button opens the surface's reader")
        assertWorkingMarkOnItsTitleLine(in: reader, host: "pane")
        attachScreenshot("subagents-pane-rows")
    }

    /// The row's top margin is 8 pt and its title a subheadline line, so the title's line centres
    /// about 17 pt under the row's top.
    private func assertWorkingMarkOnItsTitleLine(in host: XCUIElement, host name: String) {
        let header = host.staticTexts["Working"]
        XCTAssertTrue(header.waitUntilExists(timeout: 5), "The \(name) draws the Working header")
        let first = host.buttons["extension.native.activity.row.a1"].images["play.circle.fill"]
        XCTAssertTrue(first.exists, "The first running row draws its working mark in the \(name)")
        XCTAssertGreaterThanOrEqual(
            first.frame.minY, header.frame.maxY,
            "The \(name)'s first working mark must sit under the Working header: mark \(first.frame), header \(header.frame)"
        )
        // `subagents-many`: a1, then six more working rows.
        for id in ["a1"] + (0 ..< 6).map({ "w\($0)" }) {
            let row = host.buttons["extension.native.activity.row.\(id)"]
            let mark = row.images["play.circle.fill"]
            XCTAssertTrue(mark.exists, "Row \(id) draws its working mark in the \(name)")
            let offset = mark.frame.midY - row.frame.minY
            XCTAssertTrue(
                (12 ... 24).contains(offset),
                "Row \(id)'s working mark in the \(name) must centre on its title's line, about 17 pt under the row's top: \(offset)"
            )
        }
    }

    func testOpeningASurfaceDrawerKeepsTheComposerWidthWide() {
        launchWide(environment: ["CHAT_ROUTES_SURFACE": "jobs", "CHAT_ROUTES_REVIEW_COMMENT": "none"])
        assertDrawerKeepsTheComposer(surface: "surface-background_2djobs", shot: "jobs-wide")
    }

    func testOpeningAWidgetDrawerWhileBusyWithAQueuedFollowUpCoversTheTimeline() {
        launch(environment: Self.busyWithQueue)
        assertDrawerKeepsTheComposer(surface: "subagents", shot: "subagents-busy-queue", queued: true)
    }

    func testOpeningAWidgetDrawerWhileBusyWithAQueuedFollowUpCoversTheTimelineWide() {
        launchWide(environment: Self.busyWithQueue)
        assertDrawerKeepsTheComposer(surface: "subagents", shot: "subagents-busy-queue-wide", queued: true)
    }

    func testOpeningAWidgetDrawerWithTheKeyboardUpKeepsTheComposerWidth() {
        launch(environment: Self.busyWithQueue)
        assertDrawerKeepsTheComposer(surface: "subagents", shot: "subagents-busy-keyboard", queued: true, keyboard: true)
    }

    /// A running turn in Chat style, a long timeline, and one queued follow-up beside the widget.
    private static let busyWithQueue = [
        "CHAT_ROUTES_SURFACE": "subagents", "CHAT_ROUTES_REVIEW_COMMENT": "none",
        "CHAT_ROUTES_STATUS": "busy", "CHAT_ROUTES_LIVE_WORK": "1", "CHAT_ROUTES_CHAT_STYLE": "chat",
        "CHAT_ROUTES_LONG_TURNS": "30", "CHAT_ROUTES_QUEUE": "followup",
    ]

    /// `surface` is the end of the pill's and drawer's identifiers.
    private func assertDrawerKeepsTheComposer(surface: String, shot: String, queued: Bool = false, keyboard: Bool = false) {
        func element(_ kind: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "extension-strip-aboveEditor-\(kind)-", surface
            )).firstMatch
        }
        // The screen, not the app's own screenshot, which comes out cut and turned in landscape.
        func shoot(_ name: String) {
            let attachment = XCTAttachment(uprightScreenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let pill = element("pill")
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "The surface shows its pill")
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(composer.waitUntilExists(timeout: 10))
        if queued {
            let queue = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-message-queue"]
            XCTAssertTrue(queue.waitUntilExists(timeout: 10), "The queued follow-up shows its pill")
            // A pill past the edge (a phone) is reached by scrolling the strip, never cut for good.
            // An iPad's strip holds both pills as they are.
            let strip = app.scrollViews["extension-strip-aboveEditor-collapsed"]
            if strip.frame.width < 700, queue.frame.maxX > strip.frame.maxX {
                strip.swipeLeft()
                hold()
            }
            XCTAssertLessThanOrEqual(queue.frame.maxX, strip.frame.maxX, "The queue pill is whole: \(queue.frame) in \(strip.frame)")
        }
        if keyboard {
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitUntilExists(timeout: 5), "The keyboard comes up")
        }
        hold()
        let collapsed = composer.frame
        // The lowest row on screen: it stays put while the drawer opens and closes.
        let timeline = app.collectionViews["chat.timeline"]
        let row = timeline.cells.allElementsBoundByIndex
            .filter { $0.frame.minY < collapsed.minY && $0.frame.height > 0 }
            .max { $0.frame.minY < $1.frame.minY }
        let rowFrame = row?.frame
        shoot("\(shot)-collapsed")

        pill.tap()
        let drawer = element("drawer")
        XCTAssertTrue(drawer.waitUntilExists(timeout: 5), "Tapping the pill opens its drawer")
        hold()
        shoot("\(shot)-expanded")
        XCTAssertEqual(composer.frame.minX, collapsed.minX, accuracy: 0.5, "The composer must not move: \(composer.frame) vs \(collapsed)")
        XCTAssertEqual(composer.frame.width, collapsed.width, accuracy: 0.5, "The composer must keep its width: \(composer.frame) vs \(collapsed)")
        XCTAssertGreaterThan(
            drawer.frame.width, collapsed.width,
            "The drawer spans the composer's column, not its content's width: \(drawer.frame) vs \(collapsed)"
        )
        XCTAssertLessThanOrEqual(drawer.frame.maxY, composer.frame.minY, "The drawer grows up from the composer")
        if !keyboard, let row, let rowFrame {
            XCTAssertEqual(row.frame.minY, rowFrame.minY, accuracy: 0.5, "The drawer covers the timeline, never pushes it: \(row.frame) vs \(rowFrame)")
        }

        app.buttons["extension-strip-aboveEditor-drawer-collapse"].tap()
        XCTAssertTrue(drawer.waitUntilGone(timeout: 5), "Collapse closes the drawer")
        hold()
        XCTAssertEqual(composer.frame.width, collapsed.width, accuracy: 0.5, "Closing keeps the composer's width")
        if !keyboard, let row, let rowFrame {
            XCTAssertEqual(row.frame.minY, rowFrame.minY, accuracy: 0.5, "Closing leaves the timeline where it was")
        }
        assertRunning()
    }

    /// A job card whose output block outgrows the drawer's cap: the drawer scrolls under a finger
    /// that starts on the output, the block's expand control opens its text in the reader, and the
    /// drawer's own full-screen button opens every card with its Stop button in reach.
    func testLongJobOutputScrollsInTheDrawerAndOpensFullScreen() {
        launch(environment: ["CHAT_ROUTES_SURFACE": "jobs"])
        let pill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-surface-background_2djobs"]
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "The jobs surface shows its pill")
        pill.tap()
        let drawer = app.descendants(matching: .any)["extension-strip-aboveEditor-drawer-surface-background_2djobs"]
        XCTAssertTrue(drawer.waitUntilExists(timeout: 5), "Tapping the pill opens its drawer")
        let fullScreen = app.buttons["extension.strip.fullScreen.aboveEditor"]
        XCTAssertTrue(fullScreen.waitUntilExists(timeout: 5), "A body taller than the drawer's cap offers full screen")
        attachScreenshot("jobs-drawer-open")

        // The pan starts on the output block, which sits under the middle of the drawer. Wrapped,
        // its lines take more height and its own scroll view stops scrolling sideways.
        let output = app.textViews["markdown.codeBlock.text"]
        XCTAssertTrue(output.exists, "The job's output block is in the drawer")
        app.buttons["markdown.codeBlock.wrap"].tap()
        hold()
        let before = output.frame.minY
        drawer.swipeUp(velocity: .slow)
        XCTAssertTrue(
            waitFor(output.frame.minY < before - 20),
            "The drawer must scroll under a pan on the output: \(before) -> \(output.frame.minY)"
        )
        attachScreenshot("jobs-drawer-scrolled")
        drawer.swipeDown(velocity: .slow)

        // The output block's own expand control: the text in the full-screen code reader.
        let expand = app.buttons["extension.surface.background_2djobs.jobs.tail_3abash_2d72.expand"]
        XCTAssertTrue(expand.waitUntilExists(timeout: 5), "The output block offers to expand")
        expand.tap()
        let close = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "Expand opens the output in the full-screen reader")
        attachScreenshot("jobs-output-full-screen")
        close.tap()
        XCTAssertTrue(close.waitUntilGone(timeout: 5), "Back returns to the chat")

        // The drawer's full-screen button: every card, uncapped. At regular width it opens the
        // surface's panel pane beside the chat, which leaves by its Close.
        XCTAssertTrue(waitFor(fullScreen.isHittable), "The drawer is still open after the reader")
        fullScreen.tap()
        let back = app.windows.firstMatch.horizontalSizeClass == .regular
            ? app.buttons["extensionPanel.close"]
            : app.buttons["extension.surfaceReader.back.surface-background_2djobs"]
        XCTAssertTrue(back.waitUntilExists(timeout: 5), "The drawer's full-screen button opens the surface reader")
        // At regular width the reader sits in the pane beside the chat, whose
        // drawer keeps its own Stop with the same identifier: ask the reader's.
        let stop = app.scrollViews["extension.surfaceReader.scroll.surface-background_2djobs"]
            .buttons["extension.surface.background_2djobs.jobs.stop_3abash_2d72"]
        XCTAssertTrue(stop.waitUntilExists(timeout: 5), "The reader draws the job's Stop button")
        XCTAssertTrue(stop.isHittable, "Stop is in reach without scrolling the reader")
        attachScreenshot("jobs-surface-full-screen")
        // Stop in the reader is the drawer's Stop: the same action reaches the session's socket.
        stop.tap()
        back.tap()
        XCTAssertTrue(back.waitUntilGone(timeout: 5), "Back returns to the chat")
        XCTAssertTrue(
            waitFor(app.staticTexts["chatRoutes.surfaceActions"].label == "background-jobs/jobs/stop"),
            "Stop in the reader must reach the socket: \(app.staticTexts["chatRoutes.surfaceActions"].label)"
        )
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
        XCTAssertTrue(tile.waitUntilExists(timeout: 10), "Seeded composer image did not appear")

        openAnnotateCanvas(from: tile)
        attachScreenshot("canvas-bar-after")

        // The bar carries undo/redo beside the checkmark; both start disabled.
        let undo = app.buttons["canvas.undo"]
        let redo = app.buttons["canvas.redo"]
        XCTAssertTrue(undo.waitUntilExists(timeout: 5), "The canvas must offer Undo")
        XCTAssertTrue(redo.waitUntilExists(timeout: 5), "The canvas must offer Redo")
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
        XCTAssertTrue(app.navigationBars["Canvas"].waitUntilGone(timeout: 5), "Add to Chat must close the canvas")
        XCTAssertTrue(
            waitFor(app.descendants(matching: .any)["chat.input"].isHittable),
            "The composer must be back after Add to Chat"
        )
        XCTAssertTrue(composerImageTile().exists, "The annotated image must stay in the composer")

        openAnnotateCanvas(from: composerImageTile())
        app.buttons["composer.canvas.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Canvas"].waitUntilGone(timeout: 5), "Cancel must close the canvas")
        XCTAssertTrue(
            waitFor(app.descendants(matching: .any)["chat.input"].isHittable),
            "The composer must be back after Cancel"
        )
        XCTAssertTrue(composerImageTile().exists, "Cancel must keep the attachment")

        // The expanded composer presents the same canvas from its own host.
        focusComposer()
        app.descendants(matching: .any)["chat.input"].typeText("Draft\nacross\nseveral\ncomposer\nlines ")
        let expand = app.buttons["chat.expand"]
        XCTAssertTrue(expand.waitUntilExists(timeout: 10), "A multi-line draft shows the expand button")
        expand.tap()
        let expandedEditor = app.textViews["expanded.composer.editor"]
        XCTAssertTrue(expandedEditor.waitUntilExists(timeout: 5), "Expanded composer did not open")
        openAnnotateCanvas(from: composerImageTile())
        app.buttons["composer.canvas.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Canvas"].waitUntilGone(timeout: 5), "Cancel must close the expanded canvas")
        XCTAssertTrue(
            waitFor(expandedEditor.isHittable),
            "The expanded composer must be back after Cancel"
        )
        app.buttons["expanded.composer.cancel"].tap()
        XCTAssertTrue(expandedEditor.waitUntilGone(timeout: 5), "The expanded composer must close")
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
        XCTAssertTrue(app.navigationBars["Canvas"].waitUntilExists(timeout: 10), "Tapping the image must open the canvas")
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
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "Staged comment pill missing")
        pill.doubleTap()
        let edit = app.buttons["Edit review comment"].firstMatch
        XCTAssertTrue(edit.waitUntilExists(timeout: 5), "Stash sheet did not open")
        edit.tap()
        let editor = app.textViews["Review comment text"]
        XCTAssertTrue(editor.waitUntilExists(timeout: 5))
        editor.tap()
        editor.typeText(" edited")
        app.buttons["Save"].tap()
        XCTAssertTrue(editor.waitUntilGone(timeout: 5))
        // The sheet lists the chat's comments; reopening the editor reads the
        // saved body back from them.
        edit.tap()
        XCTAssertTrue(editor.waitUntilExists(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Route comment edited", "The edit must reach the chat's comments")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(editor.waitUntilGone(timeout: 5))
        attachScreenshot("stash-edited")
        dragToBottom(edit)
        XCTAssertTrue(edit.waitUntilGone(timeout: 5), "Swipe-down must close the stash sheet")
        assertRunning()

        pill.doubleTap()
        XCTAssertTrue(edit.waitUntilExists(timeout: 5), "The stash sheet did not reopen")
        cancelButton.tap()
        XCTAssertTrue(edit.waitUntilGone(timeout: 5), "Close must close the stash sheet")
        assertRunning()
    }

    func testShareSheetRefreshesItsPreviewAndKeepsThePolicy() {
        launch()
        openShareSheet()
        let share = app.navigationBars["Share Session"]
        // Without a server the preflight fails after the scan starts. Its
        // error shows only if the open sheet reads chat's share model live.
        XCTAssertTrue(
            app.staticTexts["WebSocket not connected"].waitUntilExists(timeout: 10),
            "The preflight result must reach the open sheet"
        )
        let emails = app.switches["Email Addresses"]
        XCTAssertEqual(emails.value as? String, "1")
        emails.tap()
        XCTAssertTrue(waitFor(emails.value as? String == "0"), "The toggle must follow the policy binding")
        attachScreenshot("share-sheet")
        cancelButton.tap()
        XCTAssertTrue(share.waitUntilGone(timeout: 5), "Cancel must close the share sheet")

        openShareSheet()
        XCTAssertEqual(app.switches["Email Addresses"].value as? String, "0", "The edited policy must be remembered")
        if usesSheets {
            dragToBottom(share)
            XCTAssertTrue(share.waitUntilGone(timeout: 5), "Swipe-down must close the share sheet")
        } else {
            cancelButton.tap()
            XCTAssertTrue(share.waitUntilGone(timeout: 5))
        }
        assertRunning()
    }

    // MARK: - Empty chat

    /// An Agent's new chat opens on that Agent: the circle, its name and
    /// description, and the composer naming it. The title's menu carries what the
    /// title used to do (Rename, Share) and opens the Agent's page.
    func testEmptyAgentChatGreetsAndOpensTheSessionMenu() {
        launchScreen("chat-routes", environment: ["CHAT_ROUTES_AGENT": "1", "CHAT_ROUTES_EMPTY": "1"])
        let title = app.buttons["chat.title"]
        XCTAssertTrue(title.waitUntilExists(timeout: 15), "An empty chat still has its title")

        let name = app.staticTexts["chat.emptyState.name"]
        XCTAssertTrue(name.waitUntilExists(timeout: 10), "The greeting names the Agent")
        XCTAssertEqual(name.label, "Routes Agent")
        let description = app.staticTexts["chat.emptyState.description"]
        XCTAssertTrue(description.waitUntilExists(timeout: 5), "The greeting says what the Agent does")
        let hero = app.descendants(matching: .any)["chat.emptyState.hero"]
        XCTAssertTrue(hero.exists, "The Agent's circle is the empty chat's centre")
        XCTAssertEqual(title.value as? String, "Routes", "The title still names the session")
        attachScreenshot("empty-agent-chat")

        title.tap()
        for item in ["Copy Session ID", "Rename", "Share Session", "Edit Agent"] {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", item)).firstMatch
            XCTAssertTrue(button.waitUntilExists(timeout: 5), "\(item) is missing from the title's menu")
        }
        attachScreenshot("title-menu")
        app.buttons.matching(NSPredicate(format: "label == %@", "Rename")).firstMatch.tap()
        let alert = app.alerts["Rename Session"]
        XCTAssertTrue(alert.waitUntilExists(timeout: 5), "Rename comes from the menu")
        alert.buttons.matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch.tap()
        XCTAssertTrue(alert.waitUntilGone(timeout: 5))

        assertRunning()
    }

    /// The first message ends the greeting: the circle lands in the title, the
    /// description goes, and the composer stops naming the Agent.
    func testFirstMessageSendsTheGreetingIntoTheTitle() {
        launchScreen("chat-routes", environment: ["CHAT_ROUTES_AGENT": "1", "CHAT_ROUTES_EMPTY": "1"])
        let name = app.staticTexts["chat.emptyState.name"]
        XCTAssertTrue(name.waitUntilExists(timeout: 15), "The empty chat greets first")

        app.buttons["chatRoutes.firstMessage"].tap()
        XCTAssertTrue(name.waitUntilGone(timeout: 10), "The greeting leaves with the first message")
        XCTAssertFalse(app.descendants(matching: .any)["chat.emptyState.hero"].exists)
        XCTAssertTrue(app.buttons["chat.title"].waitUntilExists(timeout: 5), "The title stays")
        hold()
        attachScreenshot("first-message-landed")
        assertRunning()
    }

    // MARK: - Review modals

    /// Compact width presents the commit as a sheet, with New Session pushing
    /// its chat onto the sheet's own stack. Regular width hosts the commit
    /// inside the Git panel's own trailing-column navigation instead: a
    /// native Back leads to Git, and New Session closes the column before
    /// opening its chat on this chat's stack, after which Git reopens.
    func testGitPanelCommitPushesAChatAndShowsTheDiffPanel() {
        launchWide()
        openGitPanel()
        tapCommitRow()
        let commit = app.navigationBars["Commit"]
        XCTAssertTrue(commit.waitUntilExists(timeout: 5), "Commit did not open in a router navigation bar")
        guard usesSheets else {
            assertPanelCommitNewSessionOpensBesideAndGitReopens(commit)
            return
        }
        openAndCloseDiff(pushed: false)

        // New Session pushes a chat onto the sheet's own stack.
        // iOS 27 puts the actions in the system overflow menu.
        barButton(commit, NSPredicate(format: "label IN %@", ["More", "Actions"])).tap()
        let newSession = app.buttons["New Session"].firstMatch
        XCTAssertTrue(newSession.waitUntilExists(timeout: 5), "New Session missing from the commit actions")
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
        XCTAssertTrue(commit.waitUntilExists(timeout: 5), "Back must pop to the commit")
        assertRunning()

        app.buttons[closeLabel].firstMatch.tap()
        XCTAssertTrue(commit.waitUntilGone(timeout: 5), "Close must close the commit sheet")
        let created = app.descendants(matching: .any)["chatRoutes.createdSessions"]
        XCTAssertEqual(created.value as? String, "1", "The stub must have received the new session")
        tapCommitRow()
        XCTAssertTrue(commit.waitUntilExists(timeout: 5))
        dragToBottom(commit)
        XCTAssertTrue(commit.waitUntilGone(timeout: 5), "Swipe-down must close the commit sheet")
        assertRunning()
    }

    private func assertPanelCommitNewSessionOpensBesideAndGitReopens(_ commit: XCUIElement) {
        let panel = app.navigationBars["Git"]
        XCTAssertFalse(app.buttons[closeLabel].exists, "A panel-hosted commit must not draw its own Close")
        openAndCloseDiff(pushed: true)
        barButton(commit, NSPredicate(format: "label IN %@", ["More", "Actions"])).tap()
        let newSession = app.buttons["New Session"].firstMatch
        XCTAssertTrue(newSession.waitUntilExists(timeout: 5), "A panel-hosted commit must offer New Session")
        newSession.tap()

        XCTAssertTrue(waitFor(chatIsShown(title: "New routes session")), "New Session must open its chat")
        XCTAssertTrue(commit.waitUntilGone(timeout: 5), "Starting a session must close the column's commit")
        XCTAssertFalse(panel.exists, "Starting a session must close the Git panel")
        let backButtons = app.buttons.matching(identifier: "chat.toolbar.back")
        // The push has ended by the time `tap()` returns, but the chat
        // underneath keeps its Back in the accessibility tree for a moment
        // after it (the outgoing bar items fade out); a chat inside the
        // column would keep a second Back for good.
        XCTAssertTrue(
            waitFor(backButtons.count == 1, timeout: 5),
            "The new chat must be the only chat on screen, not one inside the column"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["chatRoutes.createdSessions"].value as? String, "1",
            "The stub must have received the new session"
        )
        attachScreenshot("panel-commit-new-session-chat")
        backButtons.element(boundBy: 0).tap()
        XCTAssertTrue(
            waitFor(chatIsShown(title: "Routes")),
            "Back must return to the chat the panel was opened from"
        )
        hold()
        XCTAssertFalse(panel.exists, "Back must not return to the Git panel")

        // The column is gone cleanly: Git reopens, and its commit pushes again.
        openGitPanel()
        assertOpenInColumn("chat.toolbar.git")
        tapCommitRow()
        XCTAssertTrue(commit.waitUntilExists(timeout: 5), "The reopened panel must push its commit again")
        barButton(commit, NSPredicate(format: "identifier == %@", "BackButton")).tap()
        XCTAssertTrue(commit.waitUntilGone(timeout: 5), "Back must pop the commit")
        app.buttons["git.panel.close"].tap()
        XCTAssertTrue(panel.waitUntilGone(timeout: 5), "Close must close the Git panel")
        assertRunning()
    }

    /// The Git panel opens from the bar, lists only the session's file until
    /// All changes lists every change, opens a file's review over itself, and
    /// closes by its own control and, as a sheet, by swipe-down.
    func testGitPanelScopesItsFilesAndOpensAReview() {
        launchWide()
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
        XCTAssertTrue(loadMore.waitUntilExists(timeout: 5), "A graph with more pages must offer Load more")
        loadMore.tap()
        XCTAssertTrue(baseCommit.waitUntilExists(timeout: 5), "Load more must append the next page")
        XCTAssertTrue(loadMore.waitUntilGone(timeout: 5), "The last page must leave no Load more")
        assertOpenInColumn("chat.toolbar.git")
        let otherChange = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "README.md")).firstMatch
        XCTAssertFalse(otherChange.exists, "This session must not list a change the session did not make")
        let scope = app.segmentedControls["workspace-context-bar.scope"]
        XCTAssertTrue(scope.waitUntilExists(timeout: 5), "A main-checkout session must offer This session / All changes")
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
        XCTAssertTrue(sessionCopyRow.waitUntilExists(timeout: 5), "This session must list a touched file Git does not report")
        sessionCopyRow.tap()
        let sessionCopyBack = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(sessionCopyBack.waitUntilExists(timeout: 10), "The session's copy did not open")
        attachScreenshot("git-panel-session-copy")
        sessionCopyBack.tap()
        XCTAssertTrue(sessionCopyBack.waitUntilGone(timeout: 5), "Back must close the session's copy")
        hold()
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
        XCTAssertTrue(app.staticTexts["1 selected"].waitUntilExists(timeout: 5), "Select All must skip the no-diff file")
        // While selecting, the no-diff row reads as dimmed text, not a button.
        let unselectableRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "plan.md", "No diff")
        ).firstMatch
        XCTAssertTrue(unselectableRow.exists, "While selecting, the no-diff row must not be a button")
        XCTAssertFalse(unselectableRow.isEnabled, "While selecting, the no-diff row must read as not enabled")
        unselectableRow.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists, "A no-diff row cannot be selected")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Select"].waitUntilExists(timeout: 5))

        scope.buttons["All changes (2)"].tap()
        XCTAssertTrue(otherChange.waitUntilExists(timeout: 5), "All changes must list every change")
        XCTAssertFalse(sessionCopyRow.exists, "All changes lists Git's changes only")
        attachScreenshot("git-panel-all-changes")
        scope.buttons["This session"].tap()
        XCTAssertTrue(otherChange.waitUntilGone(timeout: 5), "This session must narrow the list again")

        // The panel's row carries the line counts; the timeline's file pill
        // beside the column does not.
        let fileRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "App.swift", "+2")
        ).firstMatch
        fileRow.tap()
        let review = app.navigationBars["App.swift"]
        XCTAssertTrue(review.waitUntilExists(timeout: 5), "File review did not open")
        attachScreenshot("git-panel-file-review")
        if usesSheets {
            app.buttons[closeLabel].firstMatch.tap()
            XCTAssertTrue(review.waitUntilGone(timeout: 5), "Close must close the file review")
            fileRow.tap()
            XCTAssertTrue(review.waitUntilExists(timeout: 5))
            dragToBottom(review)
            XCTAssertTrue(review.waitUntilGone(timeout: 5), "Swipe-down must close the file review")
        } else {
            // Regular width hosts the review inside the Git panel's own
            // trailing-column navigation: a native Back, not a sheet, leads
            // back to Git.
            XCTAssertFalse(app.buttons[closeLabel].exists, "A panel-hosted review must not draw its own Close")
            XCTAssertTrue(
                review.buttons.matching(NSPredicate(format: "label IN %@", ["More", "Actions"])).count > 0,
                "A panel-hosted review must keep its New Session and prompt templates"
            )
            barButton(review, NSPredicate(format: "identifier == %@", "BackButton")).tap()
            XCTAssertTrue(review.waitUntilGone(timeout: 5), "Back must pop the review")
        }
        hold()
        XCTAssertTrue(panel.exists, "Closing the review must leave the Git panel open")
        assertRunning()

        app.buttons["git.panel.close"].tap()
        XCTAssertTrue(panel.waitUntilGone(timeout: 5), "Close must close the Git panel")
        if usesSheets {
            openGitPanel()
            dragToBottom(panel)
            XCTAssertTrue(panel.waitUntilGone(timeout: 5), "Swipe-down must close the Git sheet")
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
        XCTAssertTrue(select.waitUntilExists(timeout: 5), "The Git panel must offer Select")
        select.tap()
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "App.swift", "+2")
        ).firstMatch.tap()
        let newSession = app.buttons["Start new session with selected files"]
        XCTAssertTrue(newSession.waitUntilExists(timeout: 5), "Selecting must offer New Session")
        newSession.tap()

        XCTAssertTrue(waitFor(chatIsShown(title: "New routes session")), "New Session must open its chat")
        XCTAssertTrue(panel.waitUntilGone(timeout: 10), "Starting a session must close the Git panel")
        let created = app.descendants(matching: .any)["chatRoutes.createdSessions"]
        XCTAssertEqual(created.value as? String, "1", "The stub must have received the new session")
        attachScreenshot("git-panel-new-session-chat")

        let backButtons = app.buttons.matching(identifier: "chat.toolbar.back")
        XCTAssertEqual(backButtons.count, 1, "The new chat must be the only chat on screen, not one inside a sheet")
        backButtons.element(boundBy: 0).tap()
        XCTAssertTrue(
            waitFor(chatIsShown(title: "Routes")),
            "Back must return to the chat the panel was opened from"
        )
        hold()
        XCTAssertFalse(panel.exists, "Back must not return to the Git panel")
        // The panel closed cleanly: it opens again.
        openGitPanel()
        app.buttons["git.panel.close"].tap()
        XCTAssertTrue(panel.waitUntilGone(timeout: 5), "Close must close the reopened Git panel")
        assertRunning()
    }

    /// What a commit pill and a file pill open, through the destination action
    /// the chat gave its timeline (harness controls; a test tap on the pill does
    /// not reach it). Compact width presents a modal; regular width opens the
    /// attached leaf, with the chat still beside it.
    func testTimelineCommitAndFileViewers() {
        launchWide()
        XCTAssertTrue(
            app.descendants(matching: .any)["chat.user.path-pill.abc1234"].waitUntilExists(timeout: 10),
            "Seeded commit pill missing"
        )
        app.buttons["chatRoutes.openCommitViewer"].tap()
        let commit = app.navigationBars["Commit"]
        XCTAssertTrue(commit.waitUntilExists(timeout: 5), "Commit viewer did not open in a router navigation bar")
        assertChatBesideTimelineViewer("commit")
        if !usesSheets {
            XCTAssertEqual(app.buttons["chat.commit-detail.dismiss"].label.lowercased(), "close", "A pane closes with the X the other panes use")
        }
        openAndCloseDiff(pushed: !usesSheets)
        app.buttons["chat.commit-detail.dismiss"].tap()
        XCTAssertTrue(commit.waitUntilGone(timeout: 5), "Close must close the commit viewer")
        assertRunning()

        app.buttons["chatRoutes.openFileViewer"].tap()
        let back = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(back.waitUntilExists(timeout: 10), "File viewer did not open with its back control")
        assertChatBesideTimelineViewer("file")
        if !usesSheets {
            XCTAssertEqual(back.label.lowercased(), "close", "A pane closes with the X the other panes use")
            XCTAssertTrue(
                app.staticTexts["Sources/App.swift"].exists,
                "The pane names its file: it is ambiguous beside the chat"
            )
        }
        attachScreenshot("file-viewer")
        back.tap()
        XCTAssertTrue(back.waitUntilGone(timeout: 5), "Back at the viewer's root must close it")
        XCTAssertTrue(waitFor(self.app.buttons["chat.toolbar.context"].isHittable), "Closing the viewer must return to the chat")
        assertRunning()
    }

    // MARK: - Other hosts

    /// The outline's summary-instructions sheet is a router sheet above it;
    /// the typed instructions reach the outline's tree navigation.
    func testOutlineSummarySheetSendsInstructionsToTheOutline() {
        launchScreen("session-timeline")
        let outline = app.navigationBars["Session Outline"]
        XCTAssertTrue(outline.waitUntilExists(timeout: 10), "Outline preview did not appear in a navigation bar")
        _ = outlineSearchField()
        app.buttons["Tree"].tap()
        let node = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ship list mode first")).firstMatch
        XCTAssertTrue(node.waitUntilExists(timeout: 5), "Tree rows missing")
        node.tap()
        let custom = app.buttons["Summarize with custom instructions"]
        XCTAssertTrue(custom.waitUntilExists(timeout: 5), "Tree navigation options missing")
        custom.tap()
        let sheet = app.navigationBars["Summary Instructions"]
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "Summary sheet did not open in a navigation bar")
        dragToBottom(sheet)
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "Swipe-down must close the summary sheet")

        node.tap()
        XCTAssertTrue(custom.waitUntilExists(timeout: 5))
        custom.tap()
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "Summary sheet did not reopen")
        let editor = app.textViews["tree-summary-instructions"]
        editor.tap()
        editor.typeText("keep router notes")
        app.buttons["tree-summary-navigate"].tap()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "Navigate must close the summary sheet")
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
        if !search.waitUntilExists(timeout: 3), app.buttons["Search"].exists {
            app.buttons["Search"].tap()
        }
        XCTAssertTrue(search.waitUntilExists(timeout: 5), "The outline's host must own its search field", file: file, line: line)
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
            XCTAssertTrue(item.waitUntilExists(timeout: 5), "View Options must offer sort \(pick)")
            item.tap()
        }
    }

    private func popPushedReader(returningTo bar: XCUIElement, _ name: String) {
        let back = app.buttons["fullScreen.code.close"]
        XCTAssertTrue(back.waitUntilExists(timeout: 10), "\(name) reader was not pushed")
        assertRunning()
        // The reader brings its own Back, so the panel's bar under it hides:
        // once the text loads, and animated.
        XCTAssertTrue(bar.waitUntilGone(timeout: 5), "\(name) reader shows the panel's bar above its own Back")
        back.tap()
        XCTAssertTrue(bar.waitUntilExists(timeout: 5), "\(name) reader's back must pop it")
    }

    /// `pushed`: the commit itself is hosted in the Git panel's trailing
    /// column (`testGitPanelCommitPushesAChatAndShowsTheDiffPanel`'s regular
    /// width), so its own file diff pushes into that same navigation too,
    /// with a native Back, instead of this screen's own column or sheet.
    private func openAndCloseDiff(pushed: Bool) {
        let fileRow = app.buttons["commit-detail.file"].firstMatch
        XCTAssertTrue(fileRow.waitUntilExists(timeout: 5), "The commit's file list did not load")
        fileRow.tap()
        let diff = app.navigationBars["App.swift"]
        XCTAssertTrue(diff.waitUntilExists(timeout: 5), "The diff panel did not open")
        if pushed {
            XCTAssertFalse(app.buttons["commit-detail.diff.close"].exists, "A panel-hosted diff must not draw its own Close")
            attachScreenshot("commit-diff-pushed")
            barButton(diff, NSPredicate(format: "identifier == %@", "BackButton")).tap()
            XCTAssertTrue(diff.waitUntilGone(timeout: 5), "Back must pop the diff")
        } else {
            let close = app.buttons["commit-detail.diff.close"]
            XCTAssertTrue(close.exists, "The diff panel did not draw its own Close")
            attachScreenshot(usesSheets ? "commit-diff-sheet" : "commit-diff-column")
            close.tap()
            XCTAssertTrue(close.waitUntilGone(timeout: 5), "Close must close the diff panel")
            if usesSheets {
                fileRow.tap()
                XCTAssertTrue(diff.waitUntilExists(timeout: 5))
                dragToBottom(diff)
                XCTAssertTrue(diff.waitUntilGone(timeout: 5), "Swipe-down must close the diff sheet")
            }
        }
        hold()
        XCTAssertTrue(app.navigationBars["Commit"].exists, "Closing the diff must keep the commit")
        assertRunning()
    }

    /// Regular width opens a timeline viewer beside the chat: the chat's
    /// timeline keeps its own width and stays hittable beside it. Compact width
    /// covers the chat with a sheet, so there is nothing to check.
    private func assertChatBesideTimelineViewer(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard !usesSheets else { return }
        attachScreenshot("timeline-\(name)-beside-chat")
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(timeline.exists, "The chat's timeline must stay on screen beside the \(name) viewer", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            timeline.frame.width, 375,
            "The chat keeps its minimum width beside the \(name) viewer", file: file, line: line
        )
        XCTAssertLessThan(
            timeline.frame.width, app.windows.firstMatch.frame.width,
            "The \(name) viewer must share the window with the chat, not cover it", file: file, line: line
        )
    }

    /// Whether the chat named `title` is on screen. Its title button says so; the
    /// Duo's vertical rail has none, so its session item's value names the chat.
    private func chatIsShown(title: String) -> Bool {
        let named = app.buttons["chat.title"]
        if named.exists, named.value as? String == title { return true }
        return app.buttons["chat.rail.session"].exists && app.buttons["chat.rail.session"].value as? String == title
    }

    /// The Git panel's commit row: one button across the row.
    private func tapCommitRow() {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Route commit")).firstMatch.tap()
    }

    /// Opens the Git panel from the top bar and waits for its rows to stop moving.
    private func openGitPanel() {
        let git = app.buttons["chat.toolbar.git"]
        XCTAssertTrue(git.waitUntilExists(timeout: 10), "The Git button is on the default bar")
        git.tap()
        XCTAssertTrue(app.navigationBars["Git"].waitUntilExists(timeout: 5), "The Git panel did not open")
        let commitRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Route commit")).firstMatch
        XCTAssertTrue(commitRow.waitUntilExists(timeout: 5), "The Git panel must list the commit")
        var lastFrame = CGRect.zero
        XCTAssertTrue(waitFor({
            let current = commitRow.frame
            defer { lastFrame = current }
            return current == lastFrame
        }()), "The expanded bar did not settle")
    }

    /// Share is in the title's menu, which a tap on the title opens, or in the
    /// session menu on the vertical rail (iPhone Duo).
    private func openShareSheet() {
        let railSession = app.buttons["chat.rail.session"]
        if railSession.exists {
            railSession.tap()
        } else {
            let title = app.buttons["chat.title"]
            XCTAssertTrue(title.waitUntilExists(timeout: 10))
            title.tap()
        }
        let share = app.buttons["Share Session"]
        XCTAssertTrue(share.waitUntilExists(timeout: 5), "Share Session missing from the title menu")
        share.tap()
        XCTAssertTrue(app.navigationBars["Share Session"].waitUntilExists(timeout: 5), "Share sheet did not open")
    }

    /// The chat-routes bar is complete once Outline is on it: Outline shows only
    /// while the fixture timeline has rows, and it takes a slot before the ring,
    /// so a tap before it arrives can land on the wrong button.
    /// A test that checks a panel beside the chat: on the iPad mini that is
    /// landscape, since a panel is at least an iPhone wide and opens full in
    /// portrait. Phones are unchanged.
    private func launchWide(environment: [String: String] = [:]) {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        if pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        }
        launch(environment: environment)
        guard pad else { return }
        // A fresh launch can come up in the orientation SpringBoard last had.
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        XCTAssertTrue(waitFor(window.frame.width > window.frame.height), "The iPad turned to landscape")
    }

    private func launch(environment: [String: String] = [:]) {
        launchScreen("chat-routes", environment: environment)
        XCTAssertTrue(app.buttons["chat.toolbar.context"].waitUntilExists(timeout: 15), "Chat routes harness did not appear")
        XCTAssertTrue(app.buttons["chat.toolbar.outline"].waitUntilExists(timeout: 10), "The fixture timeline did not load")
    }

    /// A chat preview whose test waits for the panel or bar it drives, so the
    /// launch does not also wait on the host's `screenshot.ready` marker.
    private func launchScreen(_ screen: String, environment: [String: String] = [:], arguments: [String] = []) {
        launchPreview(screen: screen, environment: environment, arguments: arguments, ready: nil)
    }

    /// Beside the chat (regular width) the panel's bar button stays on
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
    /// beside the chat, Share included (`PaneUITests`). The window's size class decides,
    /// as the app does: a point width misreads the Duo's inner display.
    private var usesSheets: Bool {
        app.windows.firstMatch.horizontalSizeClass == .compact
    }

    /// The review sheets' close control (`FullScreenViewerNavigationChrome`).
    private var closeLabel: String { "Done" }

    /// The composer's action row (model, thinking, attach, expand, busy mode)
    /// shows while the input has focus.
    private func focusComposer() {
        let input = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(input.waitUntilExists(timeout: 10), "Composer input missing")
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
