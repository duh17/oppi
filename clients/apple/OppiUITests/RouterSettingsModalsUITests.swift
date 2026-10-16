import XCTest

/// Opens every settings, server, agent, schedule, MCP, pairing, and onboarding
/// modal that the UIKit router presents, on the real screens over the settings
/// sweep fixture server (`SCREENSHOT_SCREEN=settings-sweep`). Each modal closes
/// through its own control (the screen's `finish()` or its presenter's
/// binding) and, for sheets, by swipe-down, then opens again: a binding left
/// set by a swipe would keep it from reopening. Edits that reach the fixture
/// server show in `settingsSweep.lastWrite`. A modal content that lost the app
/// environment crashes on its first service read, so every step checks the
/// app is still running.
@MainActor
final class RouterSettingsModalsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Router modal tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    // MARK: Agents

    func testPiPromptViewerAndGuidedSheet() {
        launch(page: "agents-pi")

        let prompt = app.buttons["agents.pi.systemPrompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "Pi detail did not load")
        prompt.tap()
        let back = app.buttons["fullscreen-code.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "The default prompt did not open full screen")
        assertRunning()
        back.tap()
        XCTAssertTrue(waitForDisappearance(of: back), "Back must close the full-screen viewer")
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5), "The viewer must open again")
        back.tap()
        XCTAssertTrue(waitForDisappearance(of: back))

        assertGuidedSheet(
            opener: { self.app.buttons["agents.pi.editSystemPrompt"].tap() },
            title: "Revise Pi global configuration"
        )
    }

    func testPiFilePromptOpensReviewSheet() {
        launch(page: "agents-pi-file")
        let prompt = app.buttons["agents.pi.systemPrompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "Pi detail did not load")
        assertReviewSheet { prompt.tap() }
    }

    func testAgentDetailModals() {
        launch(page: "agents")
        let row = app.buttons["agents.row.agent-design"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Agents list did not load")
        row.tap()
        let iconRow = app.buttons["agents.detail.icon"]
        XCTAssertTrue(iconRow.waitForExistence(timeout: 10), "Agent detail did not load")
        assertRunning()

        // Icon picker: full screen in compact width, its bar where the
        // detail's bar is; a sheet below that otherwise. Its own Cancel,
        // swipe-down where it is a sheet, then a saved choice.
        let compactWidth = app.windows.firstMatch.horizontalSizeClass == .compact
        let detailBarTop = app.navigationBars.firstMatch.frame.minY
        let pickerList = app.descendants(matching: .any)["agent.iconPicker.list"]
        let pickerBar = app.navigationBars["Agent Icon"]
        iconRow.tap()
        XCTAssertTrue(pickerList.waitForExistence(timeout: 5), "Icon picker did not open")
        XCTAssertTrue(pickerBar.waitForExistence(timeout: 5), "Icon picker has no navigation bar")
        attachScreenshot("agent-icon-picker")
        if compactWidth {
            XCTAssertEqual(pickerBar.frame.minY, detailBarTop, accuracy: 1, "In compact width the picker covers the window")
        } else {
            XCTAssertGreaterThan(pickerBar.frame.minY, detailBarTop + 10, "In regular width the picker is a sheet")
        }
        tapBarButton(app.buttons["agent.iconPicker.cancel"])
        XCTAssertTrue(waitForDisappearance(of: pickerList), "Cancel must close the icon picker")
        if !compactWidth {
            iconRow.tap()
            XCTAssertTrue(pickerList.waitForExistence(timeout: 5), "Icon picker did not reopen")
            dragToBottom(app.navigationBars["Agent Icon"])
            XCTAssertTrue(waitForDisappearance(of: pickerList), "Swipe-down must close the icon picker")
        }
        XCTAssertTrue(iconRow.waitForExistence(timeout: 5))
        iconRow.tap()
        XCTAssertTrue(pickerList.waitForExistence(timeout: 5), "Icon picker did not reopen")
        let symbol = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "agent.iconPicker.symbol.")).firstMatch
        var swipes = 0
        while !(symbol.exists && symbol.isHittable), swipes < 8 {
            pickerList.swipeUp()
            swipes += 1
        }
        let symbolName = symbol.identifier.replacingOccurrences(of: "agent.iconPicker.symbol.", with: "")
        symbol.tap()
        tapBarButton(app.buttons["agent.iconPicker.save"])
        XCTAssertTrue(waitForDisappearance(of: pickerList), "Save must close the icon picker")
        XCTAssertTrue(
            waitFor(lastWrite.contains("PATCH /agents/agent-design") && lastWrite.contains(symbolName)),
            "The picked icon must reach the server: \(lastWrite)"
        )
        // The fixture server answers with a fox emoji; the detail under the
        // full-screen picker on iPhone must show it afterwards.
        XCTAssertTrue(
            waitFor((iconRow.value as? String) == "Emoji 🦊"),
            "The saved agent must reach the detail: \(String(describing: iconRow.value))"
        )
        assertRunning()

        assertReviewSheet { self.app.buttons["agents.detail.definition"].tap() }

        assertGuidedSheet(
            opener: { self.tapScrolledIntoView(self.app.buttons["agents.detail.schedule"]) },
            title: "Create Schedule"
        )

        assertGuidedSheet(
            opener: { self.openOverflowAction("Edit with Oppi") },
            title: "Revise Design Reviewer"
        )
    }

    // MARK: Schedules

    func testScheduleDetailModals() {
        launch(page: "schedules")
        let row = app.buttons["schedules.row.schedule-nightly"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Schedules list did not load")
        row.tap()
        let prompt = app.buttons["schedule.detail.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "Schedule detail did not load")
        assertRunning()

        assertReviewSheet { self.tapScrolledIntoView(prompt) }
        assertGuidedSheet(
            opener: { self.openOverflowAction("Edit with Oppi") },
            title: "Revise Nightly digest"
        )
    }

    // MARK: Themes and skills

    func testThemeRevisionSheet() {
        launch(page: "theme-import")
        let row = app.buttons["themes.row.paper"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Themes did not load")
        assertGuidedSheet(
            opener: {
                row.press(forDuration: 1.0)
                let edit = self.app.buttons["themes.row.paper.edit"]
                XCTAssertTrue(edit.waitForExistence(timeout: 5), "Theme context menu did not open")
                edit.tap()
            },
            title: "Revise Paper"
        )
    }

    func testSkillFileGuidedRevisionSheet() {
        launch(page: "skill-file-review")
        let edit = app.buttons["fullscreen-code.action.edit-in-session"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Skill file viewer did not load")
        assertGuidedSheet(opener: { edit.tap() }, title: "Revise release")
    }

    // MARK: MCP

    func testMcpAddServerClosesAndSaves() {
        launch(page: "mcp")
        let add = app.buttons["mcp.add"]
        XCTAssertTrue(waitFor(add.exists && add.isEnabled, timeout: 10), "MCP list did not load")
        let sheet = app.navigationBars["Add MCP Server"]

        add.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Add MCP Server did not open in a navigation bar")
        attachScreenshot("mcp-add")
        tapBarButton(cancelButton)
        XCTAssertTrue(waitForDisappearance(of: sheet), "Cancel must close Add MCP Server")
        add.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Add MCP Server did not reopen")
        dragToBottom(sheet)
        XCTAssertTrue(waitForDisappearance(of: sheet), "Swipe-down must close Add MCP Server")

        add.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Add MCP Server did not reopen after the swipe")
        let name = app.textFields["mcp.add.name"]
        name.tap()
        name.typeText("notes2")
        let url = app.textFields["mcp.add.url"]
        url.tap()
        url.typeText("https://notes2.example.com/mcp")
        tapBarButton(app.buttons["mcp.add.save"])
        XCTAssertTrue(waitForDisappearance(of: sheet), "Add must close the sheet")
        XCTAssertTrue(
            waitFor(lastWrite.contains("POST /mcp/scopes/global/servers") && lastWrite.contains("\"name\":\"notes2\"")),
            "The new server must reach the host: \(lastWrite)"
        )
        assertRunning()
    }

    /// `.interactiveDismissDisabled` while saving must hold on a router sheet
    /// in a navigation controller: a swiped-away sheet left the add running.
    func testMcpAddServerCannotBeSweptAwayWhileSaving() {
        launch(page: "mcp", writeDelay: 8)
        let add = app.buttons["mcp.add"]
        XCTAssertTrue(waitFor(add.exists && add.isEnabled, timeout: 10), "MCP list did not load")
        let sheet = app.navigationBars["Add MCP Server"]
        add.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Add MCP Server did not open")
        let name = app.textFields["mcp.add.name"]
        name.tap()
        name.typeText("slow")
        let url = app.textFields["mcp.add.url"]
        url.tap()
        url.typeText("https://slow.example.com/mcp")
        tapBarButton(app.buttons["mcp.add.save"])
        XCTAssertTrue(waitFor(lastWrite.contains("\"name\":\"slow\"")), "The add did not start: \(lastWrite)")

        dragToBottom(sheet)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(sheet.exists, "Swipe-down must not close the sheet while it saves")
        XCTAssertTrue(waitForDisappearance(of: sheet, timeout: 20), "The finished add must close the sheet")
        assertRunning()
    }

    /// Sign-in starts on a pushed server detail, which covers the list. The
    /// detail presents the sheet; after going back, the list presents it.
    func testMcpSignInPresentsFromDetailAndList() {
        launch(page: "mcp")
        let github = app.buttons["mcp.server.global.github"]
        XCTAssertTrue(github.waitForExistence(timeout: 10), "MCP list did not load")
        github.tap()
        let login = app.buttons["mcp.login"]
        tapScrolledIntoView(login)
        let signIn = app.navigationBars["Sign In"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5), "Sign-in did not open from the server detail")
        XCTAssertTrue(app.textFields["mcp.auth.callback"].waitForExistence(timeout: 5))
        attachScreenshot("mcp-sign-in")
        tapBarButton(cancelButton)
        XCTAssertTrue(waitForDisappearance(of: signIn), "Close must close sign-in")
        assertRunning()

        app.buttons["BackButton"].firstMatch.tap()
        let resume = app.buttons["mcp.auth.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "The list must keep the live sign-in")
        XCTAssertFalse(signIn.exists, "Going back must not present sign-in again")
        resume.tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5), "Continue Sign-In did not open from the list")
        dragToBottom(signIn)
        XCTAssertTrue(waitForDisappearance(of: signIn), "Swipe-down must close sign-in")

        app.buttons["mcp.auth.cancel"].tap()
        XCTAssertTrue(
            waitFor(lastWrite.contains("POST /mcp/auth/flows/mcp-flow/cancel")),
            "Cancel must reach the host: \(lastWrite)"
        )
        assertRunning()
    }

    // MARK: Pairing and onboarding

    func testPairingApprovalSwipesAwayAndDenies() {
        launch(page: "pairing-approval")
        let prompt = app.navigationBars["Approve New Device?"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "The pending approval did not present")
        XCTAssertEqual(app.staticTexts["pairing.approval.deviceName"].label, "Chen's iPad")
        attachScreenshot("pairing-approval")
        dragToBottom(prompt)
        XCTAssertTrue(waitForDisappearance(of: prompt), "Swipe-down must close the approval")
        assertRunning()

        launch(page: "pairing-approval")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "The pending approval did not present")
        // The controller blocks a denied approval and clears the prompt;
        // the binding change dismisses it. (The deny request itself waits for
        // a ready server transport, which the fixture connection lacks.)
        app.buttons["pairing.approval.deny"].tap()
        XCTAssertTrue(waitForDisappearance(of: prompt), "Deny must close the approval")
        assertRunning()
    }

    func testOnboardingManualEntrySheet() {
        launch(page: "onboarding-add-server")
        // By label: the harness root's ready identifier replaces identifiers
        // in the same SwiftUI host.
        let manual = app.buttons["Enter manually"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10), "Onboarding did not load")
        let entry = app.navigationBars["Connect Manually"]

        manual.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Manual entry did not open in a navigation bar")
        tapBarButton(cancelButton)
        XCTAssertTrue(waitForDisappearance(of: entry), "Cancel must close manual entry")
        manual.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Manual entry did not reopen")
        dragToBottom(entry)
        XCTAssertTrue(waitForDisappearance(of: entry), "Swipe-down must close manual entry")
        assertRunning()

        // Connect hands the credentials back: onboarding starts pairing and
        // shows its outcome (no server answers here).
        manual.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Manual entry did not reopen after the swipe")
        let host = app.textFields["Host (e.g. my-mac.local)"]
        host.tap()
        host.typeText("127.0.0.1")
        let token = app.secureTextFields["Token"]
        token.tap()
        token.typeText("sk_none")
        tapBarButton(app.buttons["Connect"].firstMatch)
        XCTAssertTrue(waitForDisappearance(of: entry), "Connect must close manual entry")
        XCTAssertTrue(
            app.staticTexts["Connection failed"].waitForExistence(timeout: 30)
                || app.staticTexts["Pairing…"].exists,
            "Onboarding must receive the entered credentials"
        )
        assertRunning()
    }

    /// Connect through Tailscale is a sheet in a navigation controller: its
    /// Check a Machine row pushes inside the sheet, and Cancel closes it.
    func testOnboardingTailscaleSheetPushesCheckAMachine() {
        launch(page: "onboarding-tailscale")
        let connect = app.buttons["Connect through Tailscale"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "Onboarding did not load")
        connect.tap()
        let tailscale = app.navigationBars["Tailscale"]
        XCTAssertTrue(tailscale.waitForExistence(timeout: 5), "Tailscale did not open in a navigation bar")
        assertRunning()

        let check = app.buttons["Check a Machine for Oppi"]
        for _ in 0..<6 where !check.isHittable { app.swipeUp() }
        check.tap()
        XCTAssertTrue(app.navigationBars["Check a Machine"].waitForExistence(timeout: 5), "Check a Machine was not pushed")
        attachScreenshot("onboarding-check-a-machine")
        assertRunning()
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(tailscale.waitForExistence(timeout: 5), "Back must return to Tailscale")

        tapBarButton(cancelButton)
        XCTAssertTrue(waitForDisappearance(of: tailscale), "Cancel must close the Tailscale sheet")
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        assertRunning()
    }

    // MARK: Shared checks

    /// A guided control-session sheet: Cancel (`finish()` at the root of the
    /// router's navigation controller), then swipe-down, then it opens again.
    private func assertGuidedSheet(opener: () -> Void, title: String) {
        let sheet = app.navigationBars[title]
        opener()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "\(title) did not open in a navigation bar")
        attachScreenshot(title)
        assertRunning()
        tapBarButton(cancelButton)
        XCTAssertTrue(waitForDisappearance(of: sheet), "Cancel must close \(title)")
        opener()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "\(title) did not reopen")
        dragToBottom(sheet)
        XCTAssertTrue(waitForDisappearance(of: sheet), "Swipe-down must close \(title)")
        opener()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "\(title) did not reopen after the swipe")
        tapBarButton(cancelButton)
        XCTAssertTrue(waitForDisappearance(of: sheet))
        assertRunning()
    }

    /// A reviewable Markdown sheet: its dismiss control, then swipe-down.
    private func assertReviewSheet(opener: () -> Void) {
        let dismiss = app.buttons["fullscreen-code.dismiss"]
        opener()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "The review sheet did not open")
        attachScreenshot("review-sheet")
        assertRunning()
        dismiss.tap()
        XCTAssertTrue(waitForDisappearance(of: dismiss), "Its dismiss control must close the review sheet")
        opener()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "The review sheet did not reopen")
        dragToBottom(dismiss)
        XCTAssertTrue(waitForDisappearance(of: dismiss), "Swipe-down must close the review sheet")
        opener()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "The review sheet did not reopen after the swipe")
        dismiss.tap()
        XCTAssertTrue(waitForDisappearance(of: dismiss))
        assertRunning()
    }

    /// Detail actions sit in the system overflow menu on iOS 27, whose items
    /// keep their labels but not their identifiers.
    private func openOverflowAction(_ label: String) {
        let more = app.buttons.matching(NSPredicate(format: "label IN %@", ["More", "Agent actions", "Schedule actions"])).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "No overflow menu")
        tapBarButton(more)
        let action = app.buttons[label].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), "\(label) is not in the overflow menu")
        action.tap()
    }

    /// Bar items in a router sheet report no hit point ({-1, -1}) to XCTest,
    /// so tap the center of their frame.
    private func tapBarButton(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) is missing")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func launch(page: String, writeDelay: Int = 0) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += ["--screenshot-preview", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "settings-sweep"
        app.launchEnvironment["SCREENSHOT_SWEEP_PAGE"] = page
        app.launchEnvironment["SCREENSHOT_SWEEP_SHOWS_WRITES"] = "1"
        app.launchEnvironment["SCREENSHOT_SWEEP_WRITE_DELAY"] = String(writeDelay)
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = "dark"
        app.launch()
        XCTAssertTrue(lastWriteElement.waitForExistence(timeout: 10), "Settings sweep harness did not appear")
    }

    private var lastWriteElement: XCUIElement {
        app.staticTexts["settingsSweep.lastWrite"]
    }

    private var lastWrite: String {
        lastWriteElement.label
    }

    /// Swipe-down from `element` to the bottom of the screen. `swipeDown()`
    /// stays inside the element's frame, too short to dismiss a sheet.
    private func dragToBottom(_ element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// The Duo's shorter outer display can start a row below the fold.
    private func tapScrolledIntoView(_ element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        element.tap()
    }

    /// Waits default to 10 s: a loaded pool simulator can take several
    /// seconds to finish a sheet's dismissal animation.
    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 10) -> Bool {
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

    /// `Button(role: .cancel)` draws the system cancel control. Bar items can
    /// sit outside the navigation bar element: the iPhone Duo moves them to a
    /// vertical rail.
    /// The front-most one: presented controllers come last in the tree.
    private var cancelButton: XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"]))
        return matches.element(boundBy: max(matches.count - 1, 0))
    }

    private func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "The app must still be running", file: file, line: line)
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
