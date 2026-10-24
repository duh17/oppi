import XCTest

/// Opens every modal the router presents for the app root, workspaces, quick
/// session, the document and stash viewers, and the SSH terminal, on the real
/// presenters with fixture services (`SCREENSHOT_SCREEN=router-modal-sites`
/// and the existing settings, workspace, and terminal previews). Each modal
/// closes through its own control and, for sheets, by swipe-down; a modal
/// that edits something shows the result on its presenter. A screen that lost
/// the app environment crashes on its first required service read, so every
/// step checks the app is still running.
@MainActor
final class RouterModalSitesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Router modal site tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    // MARK: App root

    /// The dialog blocks swipe-down until it is answered; Cancel answers it.
    func testExtensionDialogIgnoresSwipeAndCancelReachesTheConnection() {
        launchSite("root")
        app.buttons["routerModalSites.dialog"].tap()
        let dialog = app.navigationBars["Pick a Plan"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "Extension dialog did not open in a navigation bar")
        attachScreenshot("extension-dialog")
        assertRunning()

        dragToBottom(dialog)
        XCTAssertTrue(dialog.waitForExistence(timeout: 2), "Swipe-down must not dismiss an unanswered dialog")

        app.buttons["extension.dialog.cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: dialog), "Cancel must close the dialog")
        XCTAssertEqual(label("routerModalSites.lastResponse"), "cancelled")
        assertRunning()
    }

    func testExtensionEditorSubmitsTheTypedValue() {
        launchSite("root")
        app.buttons["routerModalSites.editor"].tap()
        let editor = app.textViews["extension.dialog.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Extension editor did not open")
        attachScreenshot("extension-editor")
        editor.tap()
        editor.typeText("ship it")
        app.buttons["extension.dialog.submit"].tap()
        XCTAssertTrue(waitForDisappearance(of: editor), "Submit must close the editor")
        XCTAssertEqual(label("routerModalSites.lastResponse"), "value=ship it")
        assertRunning()
    }

    func testNoticeClosesByDoneAndBySwipe() {
        launchSite("root")
        let notice = app.navigationBars["Notice"]
        for closesBySwipe in [false, true] {
            app.buttons["routerModalSites.notice"].tap()
            XCTAssertTrue(notice.waitForExistence(timeout: 5), "Notice did not open in a navigation bar")
            if closesBySwipe {
                dragToBottom(notice)
            } else {
                attachScreenshot("notice")
                app.buttons["Done"].firstMatch.tap()
            }
            XCTAssertTrue(waitForDisappearance(of: notice), "Notice must close")
            XCTAssertTrue(waitFor(self.label("routerModalSites.noticeState") == "Notice cleared"))
            assertRunning()
        }
    }

    /// Full screen covers the root, so Continue closes the screen itself and
    /// the cleared flag lets it open again.
    func testWhatsNewContinueClosesAndReopens() {
        launchSite("root")
        for _ in 0..<2 {
            app.buttons["routerModalSites.whatsNew"].tap()
            let done = app.buttons["whatsNew.done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5), "What's New did not open")
            done.tap()
            XCTAssertTrue(waitForDisappearance(of: done), "Continue must close What's New")
            XCTAssertTrue(waitFor(self.label("routerModalSites.whatsNewState") == "What's New cleared"))
            assertRunning()
        }
    }

    // MARK: Viewers

    func testDocumentViewerClosesAndClearsItsBinding() {
        launchSite("document")
        app.buttons["routerModalSites.openDocument"].tap()
        let dismiss = app.buttons["fullscreen-code.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Document viewer did not open")
        attachScreenshot("document-viewer")
        assertRunning()
        dismiss.tap()
        XCTAssertTrue(waitForDisappearance(of: dismiss), "Dismiss must close the viewer")
        XCTAssertEqual(label("routerModalSites.documentCloses"), "Viewer closed 1")

        // Compact width shows a page sheet; regular width covers the window.
        app.buttons["routerModalSites.openDocument"].tap()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Document viewer did not reopen")
        if isRegularWidth {
            dismiss.tap()
        } else {
            dragToBottom(dismiss)
        }
        XCTAssertTrue(waitForDisappearance(of: dismiss), "The viewer must close again")
        XCTAssertEqual(label("routerModalSites.documentCloses"), "Viewer closed 2")
        assertRunning()
    }

    func testStashSheetRemovesACommentThenCloses() {
        launchSite("stash")
        XCTAssertEqual(label("routerModalSites.staged"), "Staged 2")
        app.buttons["fullscreen-code.review-comments.stash"].tap()
        let removeByLabel = app.buttons["Remove review comment"].firstMatch
        XCTAssertTrue(removeByLabel.waitForExistence(timeout: 5), "Stash sheet did not open")
        attachScreenshot("stash-sheet")
        removeByLabel.tap()
        XCTAssertTrue(waitFor(self.label("routerModalSites.staged") == "Staged 1"), "The removal must reach the stash")

        cancelButton.tap()
        XCTAssertTrue(waitForDisappearance(of: removeByLabel), "Close must close the stash sheet")
        assertRunning()

        app.buttons["fullscreen-code.review-comments.stash"].tap()
        XCTAssertTrue(removeByLabel.waitForExistence(timeout: 5), "Stash sheet did not reopen")
        dragToBottom(removeByLabel)
        XCTAssertTrue(waitForDisappearance(of: removeByLabel), "Swipe-down must close the stash sheet")
        XCTAssertEqual(label("routerModalSites.staged"), "Staged 1")
        assertRunning()
    }

    func testNowPlayingPlayerOpensFromTheInboxAndGoesBack() {
        launchSite("inbox-now-playing")
        openNowPlayingAndGoBackTwice()
    }

    func testNowPlayingPlayerOpensFromAWorkspaceAndGoesBack() {
        launchSite("workspace-now-playing")
        openNowPlayingAndGoBackTwice()
    }

    // MARK: Quick session

    func testQuickSessionPickerPopoversSelectIntoTheSheet() {
        launchSite("quick-session")
        let workspacePicker = app.buttons["quickSession.workspacePicker"]
        XCTAssertTrue(workspacePicker.waitForExistence(timeout: 10), "Quick session did not appear")

        workspacePicker.tap()
        let kypu = app.buttons["quickSession.workspace.kypu"]
        XCTAssertTrue(kypu.waitForExistence(timeout: 5), "Workspace popover did not open")
        attachScreenshot("quick-session-workspace-popover")
        kypu.tap()
        XCTAssertTrue(waitForDisappearance(of: kypu), "Choosing a workspace must close the popover")
        XCTAssertTrue(waitFor(workspacePicker.label.contains("kypu")), "Workspace pill: \(workspacePicker.label)")

        workspacePicker.tap()
        let oppi = app.buttons["quickSession.workspace.oppi"]
        XCTAssertTrue(oppi.waitForExistence(timeout: 5), "Workspace popover did not reopen")
        oppi.tap()
        XCTAssertTrue(waitFor(workspacePicker.label.contains("oppi")), "Workspace pill: \(workspacePicker.label)")
        assertRunning()

        let worktreePicker = app.buttons["quickSession.worktreePicker"]
        XCTAssertTrue(worktreePicker.waitForExistence(timeout: 5), "Two worktrees must show the worktree pill")
        worktreePicker.tap()
        let routerFix = app.buttons["quickSession.worktree.router-fix"]
        XCTAssertTrue(routerFix.waitForExistence(timeout: 5), "Worktree popover did not open")
        routerFix.tap()
        XCTAssertTrue(waitForDisappearance(of: routerFix), "Choosing a worktree must close the popover")
        XCTAssertTrue(waitFor(worktreePicker.label.contains("router-fix")), "Worktree pill: \(worktreePicker.label)")
        assertRunning()

        let agentPicker = app.buttons["quickSession.agentPicker"]
        agentPicker.tap()
        let reviewer = app.buttons["quickSession.agent.reviewer"]
        XCTAssertTrue(reviewer.waitForExistence(timeout: 5), "Agent popover did not open")
        attachScreenshot("quick-session-agent-popover")
        reviewer.tap()
        XCTAssertTrue(waitForDisappearance(of: reviewer), "Choosing an Agent must close the popover")
        XCTAssertTrue(waitFor(agentPicker.label.contains("Reviewer")), "Agent pill: \(agentPicker.label)")

        // A tap outside closes a popover without choosing.
        agentPicker.tap()
        let pi = app.buttons["quickSession.agent.pi"]
        XCTAssertTrue(pi.waitForExistence(timeout: 5), "Agent popover did not reopen")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(waitForDisappearance(of: pi), "A tap outside must close the popover")
        XCTAssertTrue(agentPicker.label.contains("Reviewer"))
        assertRunning()
    }

    /// A failed default save shows its alert while a search is active: the
    /// picker is already presenting the search controller then, and an alert
    /// presented from the picker itself is dropped.
    func testModelPickerDefaultSaveFailureAlertShowsWhileSearching() {
        launchSite("quick-session")
        let model = app.buttons["session.toolbar.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10), "Quick session did not appear")
        model.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5), "Model picker did not open")

        let alert = app.alerts["Couldn't Set Default Model"]
        let search = app.searchFields["Search models…"]
        search.tap()
        search.typeText("steady")
        let star = app.buttons["model.picker.star.fixture/fixture-steady"]
        XCTAssertTrue(star.waitForExistence(timeout: 5), "The search must keep the matching model")
        star.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "The failed save must show its alert over the active search")
        attachScreenshot("model-picker-default-failure-alert")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitForDisappearance(of: alert), "OK must dismiss the alert")
        XCTAssertTrue(app.navigationBars["Models"].exists, "The picker stays open after a failed save")
        assertRunning()
    }

    func testQuickSessionModelSheetAndExpandedComposerReachTheSheet() {
        launchSite("quick-session")
        let model = app.buttons["session.toolbar.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10), "Quick session did not appear")

        model.tap()
        let models = app.navigationBars["Models"]
        XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not open")
        let steady = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "fixture-steady")).firstMatch
        XCTAssertTrue(steady.waitForExistence(timeout: 5), "Stub models did not load")
        attachScreenshot("quick-session-model-sheet")
        steady.tap()
        XCTAssertTrue(waitForDisappearance(of: models), "Choosing a model must close the picker")
        XCTAssertTrue(waitFor(self.text(of: model).contains("fixture-steady")), "Model pill: \(text(of: model))")

        model.tap()
        XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not reopen")
        dragToBottom(models)
        XCTAssertTrue(waitForDisappearance(of: models), "Swipe-down must close the model picker")
        assertRunning()

        // Expand shows once the draft fills the inline budget.
        let inline = app.textViews["chat.input"]
        inline.tap()
        inline.typeText("one\ntwo\nthree\nfour\nfive\nsix")
        let expand = app.buttons["chat.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "A long draft must show Expand")
        expand.tap()
        let editor = app.textViews["expanded.composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Expanded composer did not open")
        XCTAssertTrue((editor.value as? String)?.contains("six") == true, "The expanded composer must show the draft")
        attachScreenshot("quick-session-expanded-composer")
        editor.tap()
        editor.typeText(" from expanded")
        app.buttons["expanded.composer.cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: editor), "Cancel must close the expanded composer")
        XCTAssertTrue(
            waitFor((inline.value as? String)?.contains("from expanded") == true),
            "The expanded edit must reach the quick session: \(inline.value as? String ?? "nil")"
        )
        assertRunning()
    }

    // MARK: Workspaces

    func testWorkspaceCreateIconPickerSavesIntoTheForm() {
        launch(screen: "settings-sweep", environment: ["SCREENSHOT_SWEEP_PAGE": "workspace-create-configure"])
        pickIconAndSave(row: app.buttons["workspace.create.icon"])
    }

    func testWorkspaceCreateWithOppiOpensTheGuidedComposerAboveTheForm() {
        launch(screen: "settings-sweep", environment: ["SCREENSHOT_SWEEP_PAGE": "workspace-create"])
        let row = app.buttons["workspace.create.createWithOppi"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Create with Oppi row did not appear")
        row.tap()
        XCTAssertTrue(
            app.navigationBars["Create Workspace"].waitForExistence(timeout: 5),
            "Create with Oppi must open the guided composer titled Create Workspace"
        )
        attachScreenshot("workspace-create-guided-composer")

        // The server has no workspace, and the composer still takes the request.
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "The guided composer's input did not appear")
        let send = app.buttons["chat.send"]
        XCTAssertFalse(send.isEnabled, "Send must wait for a request")
        input.tap()
        input.typeText("A workspace for my notes")
        XCTAssertTrue(
            waitFor(send.isEnabled),
            "Send must enable once a request is typed, with no workspace on the server"
        )
        attachScreenshot("workspace-create-guided-send-enabled")

        // Cancel closes the guided sheet and leaves the form under it.
        cancelButton.tap()
        XCTAssertTrue(
            waitForDisappearance(of: app.navigationBars["Create Workspace"]),
            "Cancel must close the guided composer"
        )
        XCTAssertTrue(app.buttons["workspace.create.manual"].waitForExistence(timeout: 5), "The create form must stay open")
        assertRunning()
    }

    func testWorkspaceDetailsIconPickerSavesIntoTheDraft() {
        launch(screen: "workspace-settings", environment: ["SCREENSHOT_WORKSPACE_PAGE": "details"])
        pickIconAndSave(row: app.buttons["workspace.edit.icon"])
    }

    /// Workspace Settings' Edit with Oppi row opens the guided composer sheet
    /// for this workspace; it creates nothing until Send.
    func testWorkspaceSettingsEditWithOppiOpensTheGuidedSheet() {
        launch(screen: "workspace-settings")
        let row = app.buttons["workspace.edit.editWithOppi"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Workspace Settings did not show Edit with Oppi")
        row.tap()
        let sheet = app.navigationBars["Revise oppi-dev"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Edit with Oppi did not open the guided composer")
        attachScreenshot("workspace-settings-edit-with-oppi")
        cancelButton.tap()
        XCTAssertTrue(waitForDisappearance(of: sheet), "Cancel must close the guided composer")
        XCTAssertTrue(row.exists, "Cancel must leave Workspace Settings open")
        assertRunning()
    }

    // MARK: SSH terminal

    func testHerdrSheetClosesByDoneAndBySwipe() {
        launch(screen: "ssh-terminal")
        let herdr = app.buttons["sshTerminal.herdr"]
        XCTAssertTrue(herdr.waitForExistence(timeout: 10), "Herdr toolbar button did not appear")
        let sheet = app.navigationBars["Herdr"]
        for closesBySwipe in [false, true] {
            herdr.tap()
            XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Herdr sheet did not open in a navigation bar")
            if closesBySwipe {
                dragToBottom(sheet)
            } else {
                attachScreenshot("herdr-sheet")
                app.buttons["Done"].firstMatch.tap()
            }
            XCTAssertTrue(waitForDisappearance(of: sheet), "Herdr sheet must close")
            assertRunning()
        }
    }

    func testProgramStatusPopoverOpensAndClosesOnOutsideTap() {
        launch(screen: "ssh-terminal-status-blocked")
        let glyph = app.buttons["sshTerminal.programStatus"]
        XCTAssertTrue(glyph.waitForExistence(timeout: 10), "Program status glyph did not appear")
        let detail = app.descendants(matching: .any)["sshTerminal.programStatusDetail"]
        for _ in 0..<2 {
            glyph.tap()
            XCTAssertTrue(detail.waitForExistence(timeout: 5), "Program status popover did not open")
            attachScreenshot("program-status-popover")
            // Let the presentation settle first: a popover swallows taps while
            // it animates in, which is not something an outside tap can fix.
            XCTAssertTrue(waitForPopoverToSettle(detail), "Program status popover never settled")
            // The glyph sits in the bottom bar, so the popover opens upward from
            // the bottom of the screen and reaches where a fixed low point used
            // to be. Tap the grid above where it actually opened.
            let popover = detail.frame
            let point = outsidePoint(above: popover)
            let tap = CGPoint(
                x: app.frame.minX + point.dx * app.frame.width,
                y: app.frame.minY + point.dy * app.frame.height
            )
            XCTAssertFalse(
                popover.contains(tap),
                "The outside tap \(tap) must not land inside the popover \(popover)"
            )
            app.coordinate(withNormalizedOffset: point).tap()
            XCTAssertTrue(
                waitForDisappearance(of: detail),
                "A tap outside must close the popover (popover \(popover), tapped at \(tap))"
            )
            assertRunning()
        }
    }

    /// The popover stops moving and takes hits: its presentation animation is
    /// over. Kept separate from `waitForExistence`, which returns as soon as the
    /// element exists, when a tap outside would still be swallowed.
    private func waitForPopoverToSettle(_ popover: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = CGRect.null
        while Date() < deadline {
            let frame = popover.frame
            if popover.isHittable, !frame.isEmpty, frame == previous { return true }
            previous = frame
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// A normalized point inside the app but above `popover`, so a tap there is
    /// provably outside it and clear of the status bar and the top inset.
    private func outsidePoint(above popover: CGRect) -> CGVector {
        let app = app.frame
        let y = min(app.maxY - 120, max(app.minY + 140, popover.minY - 100))
        let x = app.midX
        return CGVector(dx: (x - app.minX) / app.width, dy: (y - app.minY) / app.height)
    }

    /// The Save Password toggle edits the host list's profile through the
    /// sheet, so its state round-trips through the presenter.
    func testPasswordSheetEditsTheProfileAndClosesByCancelAndSwipe() {
        launch(screen: "settings-sweep", environment: ["SCREENSHOT_SWEEP_PAGE": "ssh-hosts"])
        let host = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sshTerminal.host.row.")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 10), "SSH host list did not appear")
        let sheet = app.navigationBars["SSH Sign In"]

        host.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Password sheet did not open in a navigation bar")
        let savePassword = app.switches["Save Password"]
        XCTAssertTrue(savePassword.waitForExistence(timeout: 5))
        XCTAssertEqual(savePassword.value as? String, "0")
        savePassword.tap()
        XCTAssertTrue(waitFor(savePassword.value as? String == "1"), "The toggle must round-trip through the host list")
        attachScreenshot("ssh-password-sheet")
        cancelButton.tap()
        XCTAssertTrue(waitForDisappearance(of: sheet), "Cancel must close the password sheet")
        assertRunning()

        host.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Password sheet did not reopen")
        dragToBottom(sheet)
        XCTAssertTrue(waitForDisappearance(of: sheet), "Swipe-down must close the password sheet")
        XCTAssertTrue(host.isEnabled, "The host row must take taps again")
        assertRunning()
    }

    // MARK: - Helpers

    private func openNowPlayingAndGoBackTwice() {
        let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now Playing")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Now Playing control did not appear")
        for _ in 0..<2 {
            open.tap()
            let back = app.buttons["fullscreen-audio.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 5), "Now Playing player did not open")
            attachScreenshot("now-playing")
            assertRunning()
            back.tap()
            XCTAssertTrue(waitForDisappearance(of: back), "Back must close the player")
            XCTAssertTrue(open.waitForExistence(timeout: 5), "The presenter must be back")
            assertRunning()
        }
    }

    private func pickIconAndSave(row: XCUIElement) {
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Icon row did not appear")
        scrollUntilHittable(row)
        let before = row.value as? String
        let picker = app.descendants(matching: .any)["workspace.iconPicker.list"]

        row.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Icon picker did not open")
        cancelButton.tap()
        XCTAssertTrue(waitForDisappearance(of: picker), "Cancel must close the icon picker")
        assertRunning()

        // Full screen in compact width; swipe-down only where it is a sheet.
        if app.windows.firstMatch.horizontalSizeClass != .compact {
            row.tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "Icon picker did not reopen")
            dragToBottom(app.navigationBars.firstMatch)
            XCTAssertTrue(waitForDisappearance(of: picker), "Swipe-down must close the icon picker")
            assertRunning()
        }

        row.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Icon picker did not open a third time")
        let symbol = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.iconPicker.symbol.")).firstMatch
        scrollUntilHittable(symbol)
        let symbolID = symbol.identifier
        symbol.tap()
        attachScreenshot("icon-picker")
        app.buttons["workspace.iconPicker.save"].tap()
        // Save commits asynchronously before the picker closes.
        XCTAssertTrue(waitForDisappearance(of: picker, timeout: 15), "Save must close the icon picker")
        XCTAssertTrue(
            waitFor(row.value as? String != before),
            "The picked icon (\(symbolID)) must reach the form: \(row.value as? String ?? "nil")"
        )
        assertRunning()
    }

    private func launchSite(_ site: String) {
        launch(screen: "router-modal-sites", environment: ["SCREENSHOT_MODAL_SITE": site])
    }

    private func launch(screen: String, environment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchArguments += ["--screenshot-preview", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = "dark"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        XCTAssertEqual(app.wait(for: .runningForeground, timeout: 10), true)
    }

    private var isRegularWidth: Bool {
        app.windows.firstMatch.frame.width >= 700
    }

    private func label(_ identifier: String) -> String {
        let element = app.staticTexts[identifier]
        _ = element.waitForExistence(timeout: 5)
        return element.label
    }

    private func text(of element: XCUIElement) -> String {
        "\(element.label) \(element.value as? String ?? "")"
    }

    private func scrollUntilHittable(_ element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
    }

    /// Swipe-down from `element` to the bottom of the screen. `swipeDown()`
    /// stays inside the element's frame, too short to dismiss a sheet.
    private func dragToBottom(_ element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0)
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

    /// System cancel and close controls. Bar items can sit outside the
    /// navigation bar element: the iPhone Duo moves them to a vertical rail.
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
