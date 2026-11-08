import XCTest

/// Taps through every route the UIKit router owns, on real screens with
/// fixture services (`SCREENSHOT_SCREEN=router-routes`): a pushed screen, a
/// sheet with detents in a navigation controller, a popover anchored to a
/// SwiftUI control, a full-screen modal that pushes inside itself, and a
/// host-owned search field. A hosted page that lost the app environment
/// crashes on its first required service read, so every step checks the app
/// is still running. Screenshots of each route are kept in the result bundle.
@MainActor
final class RouterRoutesUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!
    static var reusesLaunch: Bool { true }

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Router route tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// Light theme: the sheet and popover chrome follow the theme store.
    func testPushedScreenOpensSheetAndPopoverThenFinishes() {
        launch(colorScheme: "light")
        XCTAssertEqual(app.staticTexts["routerRoutes.dismissedModals"].label, "Dismissed 0")
        app.buttons["routerRoutes.quickComments"].tap()
        let quickComments = app.navigationBars["Quick Comments"]
        XCTAssertTrue(quickComments.waitUntilExists(timeout: 5), "Quick Comments was not pushed")
        assertRunning()

        button(labelBeginningWith: "Explain").tap()
        let editor = app.navigationBars["Edit Quick Comment"]
        XCTAssertTrue(editor.waitUntilExists(timeout: 5), "Editor sheet did not open in a navigation bar")
        attachScreenshot("sheet-medium-detent-light")
        assertRunning()

        app.buttons["quickComments.editor.symbolPicker"].tap()
        let idea = button(labelContaining: "Idea")
        XCTAssertTrue(idea.waitUntilExists(timeout: 5), "Icon popover did not open")
        attachScreenshot("popover-anchored-light")
        assertRunning()
        idea.tap()
        XCTAssertTrue(idea.waitUntilGone(timeout: 5), "Picking an icon must close the popover")
        hold()
        XCTAssertTrue(editor.exists, "Closing the popover must keep the editor sheet")

        cancelButton.tap()
        XCTAssertTrue(editor.waitUntilGone(timeout: 5), "Cancel must close the editor sheet")
        XCTAssertTrue(quickComments.exists)
        assertRunning()

        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["Router Routes"].waitUntilExists(timeout: 5), "Back must pop to the root")
        assertRunning()
    }

    /// A selection changed on a pushed page reaches the editor and its save.
    func testFullScreenModalPushesInsideAndSavesThePushedSelection() {
        launch(colorScheme: "dark")
        app.buttons["routerRoutes.editAgent"].tap()
        let editAgent = app.navigationBars["Edit Agent"]
        XCTAssertTrue(editAgent.waitUntilExists(timeout: 5), "Edit Agent did not present")
        attachScreenshot("full-screen-edit-agent")
        let toolsRow = app.buttons["agent.nativeEdit.tools"]
        XCTAssertTrue(text(of: toolsRow).contains("1 selected"), "Fixture agent starts with one tool: \(text(of: toolsRow))")
        assertRunning()

        toolsRow.tap()
        let tools = app.navigationBars["Agent Tools"]
        XCTAssertTrue(tools.waitUntilExists(timeout: 5), "Tools was not pushed inside the modal")
        attachScreenshot("in-modal-push-tools")
        app.buttons["agent.nativeEdit.toolMode"].tap()
        let piDefaults = app.buttons["Pi defaults"].firstMatch
        XCTAssertTrue(piDefaults.waitUntilExists(timeout: 5), "Tool selection menu did not open")
        piDefaults.tap()
        assertRunning()

        app.buttons["BackButton"].tap()
        XCTAssertTrue(tools.waitUntilGone(timeout: 5), "Back must pop Tools")
        XCTAssertTrue(
            waitFor(text(of: toolsRow).contains("Pi defaults")),
            "The pushed page's choice must show on the editor: \(text(of: toolsRow))"
        )

        app.buttons["agent.nativeEdit.save"].tap()
        XCTAssertTrue(editAgent.waitUntilGone(timeout: 5), "Save must close the full-screen modal")
        let lastSave = app.staticTexts["routerRoutes.lastSave"]
        XCTAssertTrue(waitFor(lastSave.label == "agent tools=inherit"), "The save must reach the stub server: \(lastSave.label)")
        hold()
        XCTAssertEqual(app.staticTexts["routerRoutes.dismissedModals"].label, "Dismissed 1")
        assertRunning()
    }

    func testFullScreenModalFinishesFromItsNavigationRoot() {
        launch(colorScheme: "dark")
        app.buttons["routerRoutes.editAgent"].tap()
        let editAgent = app.navigationBars["Edit Agent"]
        XCTAssertTrue(editAgent.waitUntilExists(timeout: 5), "Edit Agent did not present")

        // The System Prompt footer follows the toggle and Append/Replace.
        XCTAssertTrue(app.staticTexts["Uses the server's default system prompt."].exists)
        app.switches["agent.nativeEdit.customPrompt"].tap()
        XCTAssertTrue(
            app.staticTexts["Adds these instructions after the server's default system prompt."].waitUntilExists(timeout: 5),
            "Turning on a custom prompt must describe Append"
        )
        app.buttons["agent.nativeEdit.promptMode"].tap()
        app.buttons["Replace"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Uses these instructions instead of the server's default system prompt."].waitUntilExists(timeout: 5),
            "Replace must describe replacing the default prompt"
        )

        // The root of a presented navigation controller, where SwiftUI
        // dismiss() does nothing.
        cancelButton.tap()
        XCTAssertTrue(editAgent.waitUntilGone(timeout: 5), "Cancel must close the full-screen modal")
        let dismissed = app.staticTexts["routerRoutes.dismissedModals"]
        XCTAssertTrue(dismissed.waitUntilExists(timeout: 5))
        hold()
        XCTAssertEqual(dismissed.label, "Dismissed 1", "onDismiss must run once after finish()")
        XCTAssertEqual(app.staticTexts["routerRoutes.lastSave"].label, "none")
        assertRunning()
    }

    func testSearchModalFiltersAndReturnsSelection() {
        launch(colorScheme: "dark")
        app.buttons["routerRoutes.editSchedule"].tap()
        let editSchedule = app.navigationBars["Edit Schedule"]
        XCTAssertTrue(editSchedule.waitUntilExists(timeout: 5), "Edit Schedule did not present")

        openTimeZonePicker()
        let timeZone = app.navigationBars["Time Zone"]
        XCTAssertTrue(timeZone.waitUntilExists(timeout: 5), "Time zone sheet did not open in a navigation bar")
        let search = app.searchFields["Search time zones"]
        XCTAssertTrue(search.waitUntilExists(timeout: 5), "The host must own a search field")
        assertRunning()

        search.tap()
        search.typeText("Tokyo")
        let tokyo = app.buttons["Asia/Tokyo"]
        hold()
        XCTAssertTrue(tokyo.waitUntilExists(timeout: 5), "Search must keep the matching zone")
        XCTAssertFalse(app.buttons["America/Los Angeles"].exists, "Search must filter other zones")
        attachScreenshot("search-sheet-filtered")

        tokyo.tap()
        XCTAssertTrue(timeZone.waitUntilGone(timeout: 5), "Choosing a zone must close the sheet")
        hold()
        XCTAssertTrue(editSchedule.exists, "Closing the sheet must keep Edit Schedule")
        let row = app.buttons["schedule.nativeEdit.timeZone"]
        XCTAssertTrue(text(of: row).contains("Asia/Tokyo"), "The chosen zone must reach the screen: \(text(of: row))")
        assertRunning()

        app.buttons["schedule.nativeEdit.save"].tap()
        XCTAssertTrue(editSchedule.waitUntilGone(timeout: 5), "Save must close Edit Schedule")
        let lastSave = app.staticTexts["routerRoutes.lastSave"]
        XCTAssertTrue(waitFor(lastSave.label == "schedule timeZone=Asia/Tokyo"), "The save must reach the stub server: \(lastSave.label)")
        hold()
        XCTAssertEqual(app.staticTexts["routerRoutes.dismissedModals"].label, "Dismissed 1")
        assertRunning()
    }

    /// Swipe-down does not go through the router's dismiss. With search
    /// active, the dismissed sheet used to leave its bar over the editor.
    func testSwipingDownASearchingSheetLeavesTheEditorUsable() {
        launch(colorScheme: "dark")
        app.buttons["routerRoutes.editSchedule"].tap()
        let editSchedule = app.navigationBars["Edit Schedule"]
        XCTAssertTrue(editSchedule.waitUntilExists(timeout: 5), "Edit Schedule did not present")

        openTimeZonePicker()
        let search = app.searchFields["Search time zones"]
        XCTAssertTrue(search.waitUntilExists(timeout: 5), "The host must own a search field")
        search.tap()
        search.typeText("Tok")
        XCTAssertTrue(app.buttons["Asia/Tokyo"].waitUntilExists(timeout: 5), "Search did not filter")

        // Pull the sheet's own content down while the search is active.
        dragToBottom(app.buttons["Asia/Tokyo"])
        XCTAssertTrue(search.waitUntilGone(timeout: 5), "Swipe-down must close the searching sheet")
        XCTAssertTrue(editSchedule.waitUntilExists(timeout: 5))
        assertRunning()

        // The editor takes taps again: its row reopens the sheet.
        openTimeZonePicker()
        let timeZone = app.navigationBars["Time Zone"]
        XCTAssertTrue(timeZone.waitUntilExists(timeout: 5), "The editor must take taps after the swipe")
        dragToBottom(timeZone)
        XCTAssertTrue(timeZone.waitUntilGone(timeout: 5), "Swipe-down must close the sheet")

        cancelButton.tap()
        XCTAssertTrue(editSchedule.waitUntilGone(timeout: 5), "Cancel must close Edit Schedule")
        hold()
        XCTAssertEqual(app.staticTexts["routerRoutes.dismissedModals"].label, "Dismissed 1")
        assertRunning()
    }

    /// The model picker is a router modal over each hosted editor.
    func testModelPickerOpensFromBothEditors() {
        launch(colorScheme: "dark")
        for (entry, editorTitle, modelRow) in [
            ("routerRoutes.editAgent", "Edit Agent", "agent.nativeEdit.model"),
            ("routerRoutes.editSchedule", "Edit Schedule", "schedule.nativeEdit.model"),
        ] {
            app.buttons[entry].tap()
            let editor = app.navigationBars[editorTitle]
            XCTAssertTrue(editor.waitUntilExists(timeout: 5), "\(editorTitle) did not present")

            tapRow(modelRow)
            let models = app.navigationBars["Models"]
            XCTAssertTrue(models.waitUntilExists(timeout: 5), "Model picker did not open from \(editorTitle)")
            attachScreenshot("model-picker-\(editorTitle)")
            assertRunning()
            dragToBottom(models)
            XCTAssertTrue(models.waitUntilGone(timeout: 5), "Swipe-down must close the model picker")

            // The binding cleared on swipe-down, so the row opens it again.
            tapRow(modelRow)
            XCTAssertTrue(models.waitUntilExists(timeout: 5), "Model picker did not reopen from \(editorTitle)")
            dragToBottom(models)
            XCTAssertTrue(models.waitUntilGone(timeout: 5))

            cancelButton.tap()
            XCTAssertTrue(editor.waitUntilGone(timeout: 5), "Cancel must close \(editorTitle)")
            assertRunning()
        }
        XCTAssertEqual(app.staticTexts["routerRoutes.dismissedModals"].label, "Dismissed 2")
    }

    /// The real workspace shell over fixture services
    /// (`SCREENSHOT_SCREEN=workspace-shell`), whose UIKit stacks follow
    /// `AppNavigation`: the sidebar opens a workspace, its list opens a chat,
    /// and Back pops each; Skills searches in the host's bar. iPhone and the
    /// Duo's outer display use the drawer, iPad in landscape the split view.
    func testWorkspaceShellOpensAndPopsRoutes() {
        launchShell()
        let drawerButton = app.buttons["workspace.sidebar.open"]
        let isSplit = !drawerButton.waitUntilExists(timeout: 3)
        XCTAssertTrue(
            app.searchFields["Search sessions"].waitUntilExists(timeout: 5),
            "All Sessions must search in the host's bar"
        )
        attachScreenshot("shell-inbox")

        revealSidebar(isSplit: isSplit)
        app.buttons["workspace.open.oppi"].tap()
        let session = app.buttons["session.nav.rail-2"]
        XCTAssertTrue(session.waitUntilExists(timeout: 10), "The workspace's sessions did not show")
        attachScreenshot("shell-workspace")
        assertRunning()

        session.tap()
        let chatBack = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(chatBack.waitUntilExists(timeout: 10), "The chat did not open")
        attachScreenshot("shell-chat")
        assertRunning()
        chatBack.tap()
        XCTAssertTrue(session.waitUntilExists(timeout: 5), "Back from the chat must return to the workspace")
        assertRunning()
        if !isSplit {
            app.buttons["BackButton"].tap()
            XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "Back must pop to All Sessions")
        }

        revealSidebar(isSplit: isSplit)
        app.buttons["workspace.skills.open"].tap()
        XCTAssertTrue(app.searchFields["Search skills"].waitUntilExists(timeout: 5), "Skills must search in the host's bar")
        assertRunning()
        if !isSplit {
            app.buttons["BackButton"].tap()
            XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "Back must pop Skills")
        }
        assertRunning()
    }

    /// App Settings and Server Settings in the shell, hosted directly under
    /// UIKit bars. The Servers row opens Server Settings as its route; each of
    /// its rows pushes a page and Model Providers opens as a route. Every
    /// Settings row, and every link on those pages, pushes a page that reads
    /// app services (Appearance once crashed without its theme store), and
    /// Back returns to where it was.
    func testShellSettingsPushesEveryPageAndBack() {
        launchShell()
        let drawerButton = app.buttons["workspace.sidebar.open"]
        let isSplit = !drawerButton.waitUntilExists(timeout: 3)
        revealSidebar(isSplit: isSplit)
        app.buttons["App Settings"].tap()
        let settings = app.navigationBars["Settings"]
        XCTAssertTrue(settings.waitUntilExists(timeout: 5), "Settings did not open")
        XCTAssertTrue(
            app.buttons["settings.addServer"].waitUntilExists(timeout: 5),
            "The Servers section must offer Add Server"
        )
        // App Settings is the root of its pages, so it keeps a large title: the
        // bar is taller than an inline one (44 pt plus the large-title row).
        // On the iPhone Duo's vertical rail the title is inline by design; the
        // rail is where Back sits outside the bar element.
        let onVerticalRail = !settings.buttons["BackButton"].exists && app.buttons["BackButton"].exists
        if !onVerticalRail {
            XCTAssertGreaterThan(
                settings.frame.height, 70,
                "Settings must draw its large title (bar was \(settings.frame))"
            )
        }
        attachScreenshot("shell-settings")
        assertRunning()

        app.buttons["settings.server.sha256:rail-inbox-preview"].tap()
        let serverSettings = app.navigationBars["Server Settings"]
        XCTAssertTrue(serverSettings.waitUntilExists(timeout: 5), "The Servers row did not open Server Settings")
        assertRunning()
        for (row, title) in [
            ("server.manageWorkspaces", "Workspaces"),
            ("server.dictationDictionary", "Dictation Dictionary"),
            ("server.row.pairedDevices", "Paired Devices"),
            ("server.row.about", "About This Server"),
            ("server.row.badge", "Badge Icon"),
            ("server.modelProviders.open", "Model Providers"),
        ] {
            pushAndReturn(row: row, title: title, to: serverSettings)
        }
        goBack()
        XCTAssertTrue(settings.waitUntilExists(timeout: 5), "Back must return from Server Settings to Settings")

        let pages: [(row: String, title: String, links: [(row: String, title: String)])] = [
            ("settings.row.general", "General", []),
            ("settings.row.appearance", "Appearance", [("settings.appearance.theme", "Theme"), ("settings.appearance.customThemes", "Custom Themes")]),
            ("settings.row.text", "Text", []),
            ("settings.row.editor", "Editor", []),
            ("settings.row.chat", "Chat", [("Quick Comments", "Quick Comments")]),
            ("settings.row.sessions", "Session Rows", []),
            ("settings.row.voice", "Voice & Dictation", [("settings.dictationDictionary", "Dictation Dictionary")]),
            ("settings.tailscale", "Tailscale", []),
            ("settings.sshTerminal", "Terminal", []),
            ("settings.row.privacy", "Privacy & Security", []),
            ("settings.row.experiments", "Experiments", []),
            ("settings.row.storage", "Storage & About", []),
        ]
        for page in pages {
            let row = reveal(app.buttons[page.row])
            if page.row == "settings.row.sessions" {
                // The row is named for the page it opens and shows the density it sets.
                XCTAssertEqual(row.label, "Session Rows", "The Sessions row must be named for the page it opens")
                XCTAssertEqual(row.value as? String, "Standard", "The Session Rows row must show its density")
            }
            row.tap()
            let bar = app.navigationBars[page.title]
            XCTAssertTrue(bar.waitUntilExists(timeout: 5), "\(page.row) did not push \(page.title)")
            assertRunning()
            for link in page.links {
                pushAndReturn(row: link.row, title: link.title, to: bar)
            }
            goBack()
            XCTAssertTrue(settings.waitUntilExists(timeout: 5), "Back from \(page.title) must return to Settings")
        }
        attachScreenshot("shell-settings-after-pages")

        if !isSplit {
            goBack()
            XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "Back must pop Settings")
        }
        assertRunning()
    }

    /// Agents and Workspace Settings are hosted in the shell's UIKit stack
    /// with its bar, and their pages push onto that stack: Pi from Agents,
    /// every Workspace Settings page (each reads the workspace's server
    /// services), and a workspace's settings from Server Settings →
    /// Workspaces; Server Metrics from the host pill. Back pops each.
    func testWorkspaceShellUtilityAndSettingsPagesPushAndPop() {
        launchShell()
        let drawerButton = app.buttons["workspace.sidebar.open"]
        let isSplit = !drawerButton.waitUntilExists(timeout: 3)

        let hostPill = app.buttons["server.switcher"]
        XCTAssertTrue(hostPill.waitUntilExists(timeout: 5), "All Sessions has no host pill")
        hostPill.tap()
        let metricsItem = app.buttons["hostSwitcher.serverMetrics"]
        XCTAssertTrue(metricsItem.waitUntilExists(timeout: 5), "The host pill has no Server Metrics item")
        metricsItem.tap()
        XCTAssertTrue(app.navigationBars["Server Metrics"].waitUntilExists(timeout: 5), "Server Metrics did not open")
        let metricsBar = app.navigationBars["Server Metrics"]
        let range = app.segmentedControls["server.metrics.range"]
        XCTAssertTrue(range.exists, "Server Metrics has no range control")
        // The host switcher is on the Metrics bar (or the Duo's rail), not a pill left on All Sessions.
        let metricsPill = metricsBar.buttons["server.switcher"]
        let railPill = app.buttons["server.switcher"]
        XCTAssertTrue(metricsPill.exists || (railPill.exists && !app.collectionViews["workspace.sessionList"].exists), "Server Metrics has no host switcher")
        if isSplit {
            // The sidebar floats over the detail column: the page must start right of it, not under it.
            XCTAssertTrue(app.buttons["workspace.open.oppi"].exists, "The sidebar is not showing beside Server Metrics")
            let sidebarRight = app.buttons["workspace.open.oppi"].frame.maxX
            XCTAssertGreaterThanOrEqual(
                range.frame.minX, sidebarRight,
                "The Server Metrics range control sits under the sidebar (range \(range.frame), sidebar edge \(sidebarRight))"
            )
        }
        attachScreenshot("shell-server-metrics")
        assertRunning()
        if !isSplit {
            goBack()
            XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "Back must pop Server Metrics")
        }

        revealSidebar(isSplit: isSplit)
        app.buttons["workspace.agents.open"].tap()
        let agents = app.navigationBars["Agents"]
        XCTAssertTrue(agents.waitUntilExists(timeout: 5), "Agents did not open in the UIKit bar")
        // The shell's paired server points at this machine's own address, so what the load does
        // depends on the host (refused, or a pinned-certificate cancel). Either way the list and
        // Pi report it in a row, never an alert, and a cancel never reads as a failure.
        XCTAssertTrue(app.buttons["agents.row.pi"].waitUntilExists(timeout: 5), "Agents has no Pi row")
        assertFailedLoadRowIsNotACancel("agents.state")
        app.buttons["agents.row.pi"].tap()
        XCTAssertTrue(app.navigationBars["Pi"].waitUntilExists(timeout: 5), "Agents did not push Pi")
        assertFailedLoadRowIsNotACancel("agents.pi.state")
        attachScreenshot("shell-agents-pi")
        assertRunning()
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(agents.waitUntilExists(timeout: 5), "Back must return to Agents")
        assertFailedLoadRowIsNotACancel("agents.state")
        if !isSplit {
            app.buttons["BackButton"].tap()
            XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "Back must pop Agents")
        }

        revealSidebar(isSplit: isSplit)
        app.buttons["workspace.mcpServers.open"].tap()
        XCTAssertTrue(app.navigationBars["MCP Servers"].waitUntilExists(timeout: 5), "MCP Servers did not open in the UIKit bar")
        XCTAssertTrue(app.buttons["mcp.add"].exists, "MCP Servers has no Add button")
        attachScreenshot("shell-mcp-servers")
        assertRunning()
        if !isSplit {
            app.buttons["BackButton"].tap()
            XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "Back must pop MCP Servers")
        }

        revealSidebar(isSplit: isSplit)
        app.buttons["workspace.open.oppi"].tap()
        let openSettings = app.buttons["workspace.edit.open"].firstMatch
        XCTAssertTrue(openSettings.waitUntilExists(timeout: 10), "The workspace did not show")
        openSettings.tap()
        let settings = app.navigationBars["Workspace Settings"]
        XCTAssertTrue(settings.waitUntilExists(timeout: 10), "Workspace Settings did not open in the UIKit bar")
        for (row, title) in [
            ("workspace.edit.details", "Details"),
            ("workspace.edit.instructions", "Instructions"),
            ("workspace.edit.skills", "Skills"),
            ("workspace.edit.extensions", "Extensions"),
            ("workspace.edit.mcpServers", "MCP Servers"),
            ("workspace.edit.dictionary", "Dictation Dictionary"),
        ] {
            pushAndReturn(row: row, title: title, to: settings)
        }
        attachScreenshot("shell-workspace-settings-after-pages")
        if !isSplit {
            goBack()
            goBack()
            XCTAssertTrue(drawerButton.waitUntilExists(timeout: 5), "Back must pop to All Sessions")
        }

        revealSidebar(isSplit: isSplit)
        app.buttons["App Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitUntilExists(timeout: 5), "Settings did not open")
        app.buttons["settings.server.sha256:rail-inbox-preview"].tap()
        XCTAssertTrue(app.navigationBars["Server Settings"].waitUntilExists(timeout: 5), "Server Settings did not open")
        reveal(app.buttons["server.manageWorkspaces"]).tap()
        let workspaces = app.navigationBars["Workspaces"]
        XCTAssertTrue(workspaces.waitUntilExists(timeout: 5), "Server Settings did not push Workspaces")
        // The row's only swipe action, Delete, is also in its context menu (a
        // pointer's secondary click); a second tap outside closes the menu.
        app.buttons["server.workspace.oppi"].press(forDuration: 1.0)
        let delete = app.descendants(matching: .any).matching(identifier: "Delete").firstMatch
        XCTAssertTrue(delete.waitUntilExists(timeout: 5), "The workspace row's context menu has no Delete")
        attachScreenshot("workspace-row-context-menu")
        workspaces.tap()
        XCTAssertTrue(delete.waitUntilGone(timeout: 5), "The context menu must close")
        app.buttons["server.workspace.oppi"].tap()
        XCTAssertTrue(settings.waitUntilExists(timeout: 10), "Workspaces did not push the workspace's settings")
        pushAndReturn(row: "workspace.edit.instructions", title: "Instructions", to: settings)
        goBack()
        XCTAssertTrue(workspaces.waitUntilExists(timeout: 5), "Back must return to Workspaces")
        assertRunning()
    }

    /// iPad: the split view turns into the drawer stack in portrait and back
    /// in landscape, rebuilt from `AppNavigation`, so the open chat and its
    /// workspace survive both changes.
    func testWorkspaceShellKeepsTheRouteAcrossLayoutChanges() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Layout changes need an iPad window")
        launchShell()
        revealSidebar(isSplit: true)
        app.buttons["workspace.open.oppi"].tap()
        let session = app.buttons["session.nav.rail-2"]
        XCTAssertTrue(session.waitUntilExists(timeout: 10), "The workspace's sessions did not show")
        session.tap()
        let chatBack = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(chatBack.waitUntilExists(timeout: 10), "The chat did not open")

        let splitToggle = app.buttons["workspace.split.sidebarToggle"]
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(splitToggle.waitUntilGone(timeout: 10), "Portrait must leave the split view")
        hold()
        XCTAssertTrue(chatBack.waitUntilExists(timeout: 5), "The chat must stay open in the stack")
        attachScreenshot("shell-ipad-portrait-chat")
        assertRunning()
        chatBack.tap()
        XCTAssertTrue(session.waitUntilExists(timeout: 5), "Back must return to the workspace under the chat")
        XCTAssertTrue(app.buttons["BackButton"].exists, "The workspace must sit above All Sessions")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(splitToggle.waitUntilExists(timeout: 10), "Landscape must split again")
        hold()
        XCTAssertTrue(session.waitUntilExists(timeout: 5), "The split detail must keep the workspace")
        attachScreenshot("shell-ipad-landscape-workspace")
        assertRunning()
    }

    /// Presses Cmd-F until `element` has the cursor. The first key press after a
    /// launch can arrive before UIKit has built and validated the app's menu, so
    /// it is repeated (Find is idempotent) a few times before this fails.
    private func pressFind(focusing element: XCUIElement, _ message: String) {
        func hasFocus() -> Bool { (element.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        for _ in 0..<4 where !hasFocus() {
            app.typeKey("f", modifierFlags: .command)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, !hasFocus() {
                _ = XCTWaiter().wait(for: [XCTestExpectation()], timeout: 0.2)
            }
        }
        attachScreenshot("key-focus-\(message.prefix(12))")
        XCTAssertTrue(hasFocus(), message)
    }

    /// iPad with a hardware keyboard: Cmd-N opens Quick Session while a search
    /// is active (an active search is no modal that blocks app commands).
    func testNewSessionKeyWorksWhileSearching() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The key commands are proven on the iPad mini")
        launchShell()
        // Quick Session stays up (its Esc needs focus in its composer), so the
        // next test gets a fresh launch.
        addTeardownBlock { [app] in app?.terminate() }
        pressFind(focusing: app.searchFields.firstMatch, "Cmd-F must put the cursor in the session search")
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(
            app.buttons["quickSession.workspacePicker"].waitUntilExists(timeout: 5),
            "Cmd-N must open Quick Session while a search is active"
        )
    }

    /// iPad with a hardware keyboard: real key presses reach the app's menu
    /// commands. Cmd-F focuses the front search; Cmd-W cancels the search, then
    /// closes a pane (Option-Command-1 opened Files); Cmd-L focuses the composer.
    /// Cmd-F and Cmd-W are checked in the session list and in the Files panel.
    func testHardwareKeyCommandsDriveSearchPanesAndSheets() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The key commands are proven on the iPad mini")
        launchShell()

        let sessionSearch = app.searchFields.firstMatch
        pressFind(focusing: sessionSearch, "Cmd-F must put the cursor in the session search")

        app.typeKey("w", modifierFlags: .command)
        let session = app.buttons["session.nav.rail-2"]
        XCTAssertTrue(session.waitUntilExists(timeout: 5), "The session list must show after the search ends")
        assertKeyboardFocusLost(sessionSearch, "Cmd-W must cancel the session search")
        session.tap()
        XCTAssertTrue(app.buttons["chat.toolbar.back"].waitUntilExists(timeout: 10), "The chat did not open")

        app.typeKey("1", modifierFlags: [.option, .command])
        let files = app.navigationBars["Files"]
        XCTAssertTrue(files.waitUntilExists(timeout: 5), "Option-Command-1 must open Files")
        let fileSearch = app.searchFields["Search files"]
        pressFind(focusing: fileSearch, "Cmd-F must focus the Files panel's search")
        app.typeKey("w", modifierFlags: .command)
        assertKeyboardFocusLost(fileSearch, "The first Cmd-W must cancel the search")
        XCTAssertTrue(files.exists, "The first Cmd-W must leave the pane open")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(files.waitUntilGone(timeout: 5), "The second Cmd-W must close the pane")

        app.typeKey("l", modifierFlags: .command)
        let modelPill = app.buttons["session.toolbar.model"]
        XCTAssertTrue(modelPill.waitUntilExists(timeout: 10), "Cmd-L must focus the composer")
        assertRunning()
    }

    private func assertKeyboardFocusLost(_ element: XCUIElement, _ message: String) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, (element.value(forKey: "hasKeyboardFocus") as? Bool) != false {
            _ = XCTWaiter().wait(for: [XCTestExpectation()], timeout: 0.2)
        }
        XCTAssertEqual(element.value(forKey: "hasKeyboardFocus") as? Bool, false, message)
    }

    /// iPad: a section header's title stays level with the rows' text when the sidebar hides
    /// and shows again. The secondary column extends under the sidebar, so a header that
    /// takes its inset from the safe area would carry the sidebar's width into the title.
    func testSessionListHeadersStayWithTheRowsAcrossTheSidebarToggle() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The sidebar toggle needs the split view")
        launchShell()
        revealSidebar(isSplit: true)
        let toggle = app.buttons["workspace.split.sidebarToggle"]
        let list = app.collectionViews["workspace.sessionList"]
        let row = app.buttons["session.nav.rail-2"]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The first section's row did not show")
        let titles = ["Your Turn", "Working"]
        /// How far a header's title sits in from the rows' leading edge.
        func offset(_ title: String) -> CGFloat {
            list.staticTexts[title].firstMatch.frame.minX - row.frame.minX
        }

        let baseline = offset("Your Turn")
        XCTAssertTrue((0...40).contains(baseline), "A header title must sit just inside the rows, not \(baseline) pt (a sidebar's width)")
        for state in ["hidden", "shown"] {
            toggle.tap()
            for title in titles {
                XCTAssertTrue(
                    waitFor(abs(offset(title) - baseline) <= 1),
                    "\(title) must keep its \(baseline) pt offset with the sidebar \(state), not \(offset(title))"
                )
            }
        }
    }

    /// Taps `row`, expects the page titled `title`, then goes back to `bar`.
    private func pushAndReturn(row: String, title: String, to bar: XCUIElement) {
        reveal(app.buttons[row]).tap()
        XCTAssertTrue(app.navigationBars[title].waitUntilExists(timeout: 5), "\(row) did not push \(title)")
        assertRunning()
        goBack()
        XCTAssertTrue(bar.waitUntilExists(timeout: 5), "Back from \(title) must return")
        assertRunning()
    }

    /// UIKit's back button. On the Duo it sits on the vertical rail, outside the bar.
    private func goBack() {
        app.buttons["BackButton"].firstMatch.tap()
    }

    /// Scrolls the page's list until `element` can take a tap. The drag runs in
    /// the right-hand part of the largest list on screen: on an iPad split view
    /// `app.swipeUp()` can start over the sidebar and scroll that instead, and a
    /// page that fits the window (the iPad Pro) never showed it. A row below the
    /// fold is not in the hierarchy yet, so the list is found by size, not by row.
    private func reveal(_ element: XCUIElement) -> XCUIElement {
        _ = element.waitUntilExists(timeout: 5)
        for _ in 0..<8 where !element.isHittable {
            let lists = app.collectionViews.allElementsBoundByIndex.filter(\.exists)
            guard let list = lists.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                app.swipeUp()
                continue
            }
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
        }
        XCTAssertTrue(element.isHittable, "\(element) is not reachable")
        return element
    }

    private func launchShell() {
        // iPad splits in landscape; iPhone and the Duo outer display stay compact in
        // portrait. The simulator keeps the orientation an earlier test left, and an
        // iPhone in landscape shows the drawer too short to reach the workspace rows.
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        // Appearance lists one Theme row in Manual and two in Match System; a
        // simulator that an earlier run left on Match System must not change
        // which rows the page walk finds.
        launchPreview(
            screen: "workspace-shell",
            arguments: ["-dev.chenda.Oppi.theme.mode", "manual"],
            ready: nil
        )
        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitUntilExists(timeout: 10),
            "The workspace shell did not appear"
        )
    }

    /// Compact: the drawer. Split: the sidebar column, when hidden.
    private func revealSidebar(isSplit: Bool) {
        if isSplit {
            let toggle = app.buttons["workspace.split.sidebarToggle"]
            if toggle.exists, toggle.label.localizedCaseInsensitiveContains("show") {
                toggle.tap()
            }
        } else {
            app.buttons["workspace.sidebar.open"].tap()
        }
        XCTAssertTrue(
            app.buttons["workspace.open.oppi"].waitUntilExists(timeout: 5),
            "The workspace sidebar did not show"
        )
    }

    private func launch(colorScheme: String) {
        launchPreview(screen: "router-routes", colorScheme: colorScheme, ready: nil)
        XCTAssertTrue(
            app.buttons["routerRoutes.quickComments"].waitUntilExists(timeout: 10),
            "Router routes harness did not appear"
        )
    }

    /// Swipe-down from `element` to the bottom of the screen. `swipeDown()`
    /// stays inside the element's frame, too short to dismiss a sheet.
    private func dragToBottom(_ element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func openTimeZonePicker() {
        tapRow("schedule.nativeEdit.timeZone")
    }

    /// An editor row is one button, so a tap anywhere on it runs it. On the
    /// Duo's shorter outer display a row can start below the fold, and a UIKit
    /// row below the fold is not in the hierarchy until scrolled to.
    private func tapRow(_ row: String) {
        let element = app.buttons[row]
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
        element.tap()
    }

    private func text(of element: XCUIElement) -> String {
        "\(element.label) \(element.value as? String ?? "")"
    }

    private func button(labelBeginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func button(labelContaining text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// `Button(role: .cancel)` draws the system cancel control. Bar items can
    /// sit outside the navigation bar element: the iPhone Duo moves them to a
    /// vertical rail.
    private var cancelButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch
    }

    /// Agents and Pi report a failed load in a row with Retry (a button), never an
    /// alert, and a cancelled load never reads as the failure. The row is awaited:
    /// the list reloads on every appearance against the shell's unreachable address,
    /// so on a return (Back from Pi) the row is the loading row, not a button, until
    /// the connect attempt fails again, which under a loaded pool can exceed 5 s.
    private func assertFailedLoadRowIsNotACancel(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons[identifier]
        XCTAssertTrue(row.waitUntilExists(timeout: 15), "\(identifier) never showed its failure row", file: file, line: line)
        XCTAssertNotEqual(row.label, "cancelled", "A cancelled load must not show as a failure", file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, "A failed load must not raise an alert", file: file, line: line)
    }
}
