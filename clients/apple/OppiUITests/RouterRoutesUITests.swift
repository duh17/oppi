import XCTest

/// Taps through every route the UIKit router owns, on real screens with
/// fixture services (`SCREENSHOT_SCREEN=router-routes`): a pushed screen, a
/// sheet with detents in a navigation controller, a popover anchored to a
/// SwiftUI control, a full-screen modal that pushes inside itself, and a
/// host-owned search field. A hosted page that lost the app environment
/// crashes on its first required service read, so every step checks the app
/// is still running. Screenshots of each route are kept in the result bundle.
@MainActor
final class RouterRoutesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Router route tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testHostedRootShowsItsBottomBar() {
        launch(colorScheme: "dark")
        XCTAssertTrue(app.navigationBars["Router Routes"].exists)
        let bottomBarItem = app.staticTexts["routerRoutes.dismissedModals"]
        XCTAssertTrue(bottomBarItem.waitForExistence(timeout: 5), "A .bottomBar item needs the toolbar shown")
        XCTAssertEqual(bottomBarItem.label, "Dismissed 0")
        attachScreenshot("root-large-title-bottom-bar")
        assertRunning()
    }

    /// Light theme: the sheet and popover chrome follow the theme store.
    func testPushedScreenOpensSheetAndPopoverThenFinishes() {
        launch(colorScheme: "light")
        app.buttons["routerRoutes.quickComments"].tap()
        let quickComments = app.navigationBars["Quick Comments"]
        XCTAssertTrue(quickComments.waitForExistence(timeout: 5), "Quick Comments was not pushed")
        assertRunning()

        button(labelBeginningWith: "Explain").tap()
        let editor = app.navigationBars["Edit Quick Comment"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Editor sheet did not open in a navigation bar")
        attachScreenshot("sheet-medium-detent-light")
        assertRunning()

        app.buttons["quickComments.editor.symbolPicker"].tap()
        let idea = button(labelContaining: "Idea")
        XCTAssertTrue(idea.waitForExistence(timeout: 5), "Icon popover did not open")
        attachScreenshot("popover-anchored-light")
        assertRunning()
        idea.tap()
        XCTAssertTrue(waitForDisappearance(of: idea), "Picking an icon must close the popover")
        XCTAssertTrue(editor.exists, "Closing the popover must keep the editor sheet")

        cancelButton.tap()
        XCTAssertTrue(waitForDisappearance(of: editor), "Cancel must close the editor sheet")
        XCTAssertTrue(quickComments.exists)
        assertRunning()

        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["Router Routes"].waitForExistence(timeout: 5), "Back must pop to the root")
        assertRunning()
    }

    /// A selection changed on a pushed page reaches the editor and its save.
    func testFullScreenModalPushesInsideAndSavesThePushedSelection() {
        launch(colorScheme: "dark")
        app.buttons["routerRoutes.editAgent"].tap()
        let editAgent = app.navigationBars["Edit Agent"]
        XCTAssertTrue(editAgent.waitForExistence(timeout: 5), "Edit Agent did not present")
        attachScreenshot("full-screen-edit-agent")
        let toolsRow = app.buttons["agent.nativeEdit.tools"]
        XCTAssertTrue(text(of: toolsRow).contains("1 selected"), "Fixture agent starts with one tool: \(text(of: toolsRow))")
        assertRunning()

        toolsRow.tap()
        let tools = app.navigationBars["Agent Tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 5), "Tools was not pushed inside the modal")
        attachScreenshot("in-modal-push-tools")
        app.buttons["agent.nativeEdit.toolMode"].tap()
        let piDefaults = app.buttons["Pi defaults"].firstMatch
        XCTAssertTrue(piDefaults.waitForExistence(timeout: 5), "Tool selection menu did not open")
        piDefaults.tap()
        assertRunning()

        app.buttons["BackButton"].tap()
        XCTAssertTrue(waitForDisappearance(of: tools), "Back must pop Tools")
        XCTAssertTrue(
            waitFor(text(of: toolsRow).contains("Pi defaults")),
            "The pushed page's choice must show on the editor: \(text(of: toolsRow))"
        )

        app.buttons["agent.nativeEdit.save"].tap()
        XCTAssertTrue(waitForDisappearance(of: editAgent), "Save must close the full-screen modal")
        XCTAssertEqual(app.staticTexts["routerRoutes.lastSave"].label, "agent tools=inherit")
        XCTAssertEqual(app.staticTexts["routerRoutes.dismissedModals"].label, "Dismissed 1")
        assertRunning()
    }

    func testFullScreenModalFinishesFromItsNavigationRoot() {
        launch(colorScheme: "dark")
        app.buttons["routerRoutes.editAgent"].tap()
        let editAgent = app.navigationBars["Edit Agent"]
        XCTAssertTrue(editAgent.waitForExistence(timeout: 5), "Edit Agent did not present")

        // The root of a presented navigation controller, where SwiftUI
        // dismiss() does nothing.
        cancelButton.tap()
        XCTAssertTrue(waitForDisappearance(of: editAgent), "Cancel must close the full-screen modal")
        let dismissed = app.staticTexts["routerRoutes.dismissedModals"]
        XCTAssertTrue(dismissed.waitForExistence(timeout: 5))
        XCTAssertEqual(dismissed.label, "Dismissed 1", "onDismiss must run once after finish()")
        XCTAssertEqual(app.staticTexts["routerRoutes.lastSave"].label, "none")
        assertRunning()
    }

    func testSearchModalFiltersAndReturnsSelection() {
        launch(colorScheme: "dark")
        app.buttons["routerRoutes.editSchedule"].tap()
        let editSchedule = app.navigationBars["Edit Schedule"]
        XCTAssertTrue(editSchedule.waitForExistence(timeout: 5), "Edit Schedule did not present")

        openTimeZonePicker()
        let timeZone = app.navigationBars["Time Zone"]
        XCTAssertTrue(timeZone.waitForExistence(timeout: 5), "Time zone sheet did not open in a navigation bar")
        let search = app.searchFields["Search time zones"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The host must own a search field")
        assertRunning()

        search.tap()
        search.typeText("Tokyo")
        let tokyo = app.buttons["Asia/Tokyo"]
        XCTAssertTrue(tokyo.waitForExistence(timeout: 5), "Search must keep the matching zone")
        XCTAssertFalse(app.buttons["America/Los Angeles"].exists, "Search must filter other zones")
        attachScreenshot("search-sheet-filtered")

        tokyo.tap()
        XCTAssertTrue(waitForDisappearance(of: timeZone), "Choosing a zone must close the sheet")
        XCTAssertTrue(editSchedule.exists, "Closing the sheet must keep Edit Schedule")
        let row = app.buttons["schedule.nativeEdit.timeZone"]
        XCTAssertTrue(text(of: row).contains("Asia/Tokyo"), "The chosen zone must reach the screen: \(text(of: row))")
        assertRunning()

        app.buttons["schedule.nativeEdit.save"].tap()
        XCTAssertTrue(waitForDisappearance(of: editSchedule), "Save must close Edit Schedule")
        XCTAssertEqual(app.staticTexts["routerRoutes.lastSave"].label, "schedule timeZone=Asia/Tokyo")
        XCTAssertEqual(app.staticTexts["routerRoutes.dismissedModals"].label, "Dismissed 1")
        assertRunning()
    }

    /// Swipe-down does not go through the router's dismiss. With search
    /// active, the dismissed sheet used to leave its bar over the editor.
    func testSwipingDownASearchingSheetLeavesTheEditorUsable() {
        launch(colorScheme: "dark")
        app.buttons["routerRoutes.editSchedule"].tap()
        let editSchedule = app.navigationBars["Edit Schedule"]
        XCTAssertTrue(editSchedule.waitForExistence(timeout: 5), "Edit Schedule did not present")

        openTimeZonePicker()
        let search = app.searchFields["Search time zones"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The host must own a search field")
        search.tap()
        search.typeText("Tok")
        XCTAssertTrue(app.buttons["Asia/Tokyo"].waitForExistence(timeout: 5), "Search did not filter")

        // Pull the sheet's own content down while the search is active.
        dragToBottom(app.buttons["Asia/Tokyo"])
        XCTAssertTrue(waitForDisappearance(of: search), "Swipe-down must close the searching sheet")
        XCTAssertTrue(editSchedule.waitForExistence(timeout: 5))
        assertRunning()

        // The editor takes taps again: its row reopens the sheet.
        openTimeZonePicker()
        let timeZone = app.navigationBars["Time Zone"]
        XCTAssertTrue(timeZone.waitForExistence(timeout: 5), "The editor must take taps after the swipe")
        dragToBottom(timeZone)
        XCTAssertTrue(waitForDisappearance(of: timeZone), "Swipe-down must close the sheet")

        cancelButton.tap()
        XCTAssertTrue(waitForDisappearance(of: editSchedule), "Cancel must close Edit Schedule")
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
            XCTAssertTrue(editor.waitForExistence(timeout: 5), "\(editorTitle) did not present")

            tapRowLabel(modelRow, "Model")
            let models = app.navigationBars["Models"]
            XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not open from \(editorTitle)")
            attachScreenshot("model-picker-\(editorTitle)")
            assertRunning()
            dragToBottom(models)
            XCTAssertTrue(waitForDisappearance(of: models), "Swipe-down must close the model picker")

            // The binding cleared on swipe-down, so the row opens it again.
            tapRowLabel(modelRow, "Model")
            XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not reopen from \(editorTitle)")
            dragToBottom(models)
            XCTAssertTrue(waitForDisappearance(of: models))

            cancelButton.tap()
            XCTAssertTrue(waitForDisappearance(of: editor), "Cancel must close \(editorTitle)")
            assertRunning()
        }
        XCTAssertEqual(app.staticTexts["routerRoutes.dismissedModals"].label, "Dismissed 2")
    }

    /// The real workspace shell over fixture services
    /// (`SCREENSHOT_SCREEN=workspace-shell`), whose UIKit stacks follow
    /// `AppNavigation`: the sidebar opens a workspace, its list opens a chat,
    /// and Back pops each; Skills searches in the host's bar; Settings, still
    /// in its own SwiftUI stack, pushes a page that reads app services and
    /// comes back. iPhone and the Duo's outer display use the drawer, iPad in
    /// landscape the split view.
    func testWorkspaceShellOpensAndPopsRoutes() {
        launchShell()
        let drawerButton = app.buttons["workspace.sidebar.open"]
        let isSplit = !drawerButton.waitForExistence(timeout: 3)
        XCTAssertTrue(
            app.searchFields["Search sessions"].waitForExistence(timeout: 5),
            "All Sessions must search in the host's bar"
        )
        attachScreenshot("shell-inbox")

        revealSidebar(isSplit: isSplit)
        app.buttons["workspace.open.oppi"].tap()
        let session = app.buttons["session.nav.rail-2"]
        XCTAssertTrue(session.waitForExistence(timeout: 10), "The workspace's sessions did not show")
        attachScreenshot("shell-workspace")
        assertRunning()

        session.tap()
        let chatBack = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(chatBack.waitForExistence(timeout: 10), "The chat did not open")
        attachScreenshot("shell-chat")
        assertRunning()
        chatBack.tap()
        XCTAssertTrue(session.waitForExistence(timeout: 5), "Back from the chat must return to the workspace")
        assertRunning()
        if !isSplit {
            app.buttons["BackButton"].tap()
            XCTAssertTrue(drawerButton.waitForExistence(timeout: 5), "Back must pop to All Sessions")
        }

        revealSidebar(isSplit: isSplit)
        app.buttons["workspace.skills.open"].tap()
        XCTAssertTrue(app.searchFields["Search skills"].waitForExistence(timeout: 5), "Skills must search in the host's bar")
        assertRunning()
        if !isSplit {
            app.buttons["BackButton"].tap()
            XCTAssertTrue(drawerButton.waitForExistence(timeout: 5), "Back must pop Skills")
        }

        revealSidebar(isSplit: isSplit)
        app.buttons["App Settings"].tap()
        let settings = app.navigationBars["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings did not open")
        app.buttons["settings.row.appearance"].tap()
        let appearance = app.navigationBars["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5), "Settings did not push Appearance")
        attachScreenshot("shell-settings-page")
        assertRunning()
        // On the Duo the back control sits on the vertical rail, outside the bar.
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Back must return to Settings")
        if !isSplit {
            app.buttons["BackButton"].tap()
            XCTAssertTrue(drawerButton.waitForExistence(timeout: 5), "Back must pop Settings")
        }
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
        XCTAssertTrue(session.waitForExistence(timeout: 10), "The workspace's sessions did not show")
        session.tap()
        let chatBack = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(chatBack.waitForExistence(timeout: 10), "The chat did not open")

        let splitToggle = app.buttons["workspace.split.sidebarToggle"]
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForDisappearance(of: splitToggle, timeout: 10), "Portrait must leave the split view")
        XCTAssertTrue(chatBack.waitForExistence(timeout: 5), "The chat must stay open in the stack")
        attachScreenshot("shell-ipad-portrait-chat")
        assertRunning()
        chatBack.tap()
        XCTAssertTrue(session.waitForExistence(timeout: 5), "Back must return to the workspace under the chat")
        XCTAssertTrue(app.buttons["BackButton"].exists, "The workspace must sit above All Sessions")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(splitToggle.waitForExistence(timeout: 10), "Landscape must split again")
        XCTAssertTrue(session.waitForExistence(timeout: 5), "The split detail must keep the workspace")
        attachScreenshot("shell-ipad-landscape-workspace")
        assertRunning()
    }

    private func launchShell() {
        // iPad splits in landscape; iPhone and the Duo outer display stay compact.
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        app = XCUIApplication()
        app.launchArguments += ["--screenshot-preview", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "workspace-shell"
        app.launch()
        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 10),
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
            app.buttons["workspace.open.oppi"].waitForExistence(timeout: 5),
            "The workspace sidebar did not show"
        )
    }

    private func launch(colorScheme: String) {
        app = XCUIApplication()
        app.launchArguments += ["--screenshot-preview", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "router-routes"
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = colorScheme
        app.launch()
        XCTAssertTrue(
            app.buttons["routerRoutes.quickComments"].waitForExistence(timeout: 10),
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
        tapRowLabel("schedule.nativeEdit.timeZone", "Time Zone")
    }

    /// The editors' plain-style rows only take taps on their text; the row's
    /// center is empty space between label and value. On the Duo's shorter
    /// outer display a row can start below the fold.
    private func tapRowLabel(_ row: String, _ label: String) {
        let button = app.buttons[row]
        var swipes = 0
        while !(button.exists && button.isHittable), swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
        button.staticTexts[label].firstMatch.tap()
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

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    private func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "The app must still be running", file: file, line: line)
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
