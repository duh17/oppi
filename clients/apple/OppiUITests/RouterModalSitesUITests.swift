import XCTest

/// Opens every modal the router presents for the app root, workspaces, quick
/// session, Now Playing, and the SSH terminal, on the real
/// presenters with fixture services (`SCREENSHOT_SCREEN=router-modal-sites`
/// and the existing settings, workspace, and terminal previews). Each modal
/// closes through its own control and, for sheets, by swipe-down; a modal
/// that edits something shows the result on its presenter. A screen that lost
/// the app environment crashes on its first required service read, so every
/// step checks the app is still running.
@MainActor
final class RouterModalSitesUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

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
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5), "Cancel must close the dialog")
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
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Submit must close the editor")
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
            XCTAssertTrue(notice.waitForNonExistence(timeout: 5), "Notice must close")
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
            XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Continue must close What's New")
            XCTAssertTrue(waitFor(self.label("routerModalSites.whatsNewState") == "What's New cleared"))
            assertRunning()
        }
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
        XCTAssertTrue(kypu.waitForNonExistence(timeout: 5), "Choosing a workspace must close the popover")
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
        XCTAssertTrue(routerFix.waitForNonExistence(timeout: 5), "Choosing a worktree must close the popover")
        XCTAssertTrue(waitFor(worktreePicker.label.contains("router-fix")), "Worktree pill: \(worktreePicker.label)")
        assertRunning()

        let agentPicker = app.buttons["quickSession.agentPicker"]
        agentPicker.tap()
        let reviewer = app.buttons["quickSession.agent.reviewer"]
        XCTAssertTrue(reviewer.waitForExistence(timeout: 5), "Agent popover did not open")
        attachScreenshot("quick-session-agent-popover")
        reviewer.tap()
        XCTAssertTrue(reviewer.waitForNonExistence(timeout: 5), "Choosing an Agent must close the popover")
        XCTAssertTrue(waitFor(agentPicker.label.contains("Reviewer")), "Agent pill: \(agentPicker.label)")

        // A tap outside closes a popover without choosing.
        agentPicker.tap()
        let pi = app.buttons["quickSession.agent.pi"]
        XCTAssertTrue(pi.waitForExistence(timeout: 5), "Agent popover did not reopen")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(pi.waitForNonExistence(timeout: 5), "A tap outside must close the popover")
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
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "OK must dismiss the alert")
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
        XCTAssertTrue(models.waitForNonExistence(timeout: 5), "Choosing a model must close the picker")
        XCTAssertTrue(waitFor(self.text(of: model).contains("fixture-steady")), "Model pill: \(text(of: model))")

        model.tap()
        XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not reopen")
        dragToBottom(models)
        XCTAssertTrue(models.waitForNonExistence(timeout: 5), "Swipe-down must close the model picker")
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
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Cancel must close the expanded composer")
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
            app.navigationBars["Create Workspace"].waitForNonExistence(timeout: 5),
            "Cancel must close the guided composer"
        )
        XCTAssertTrue(app.buttons["workspace.create.manual"].waitForExistence(timeout: 5), "The create form must stay open")
        assertRunning()
    }

    func testWorkspaceDetailsIconPickerSavesIntoTheDraft() {
        launch(screen: "workspace-settings", environment: ["SCREENSHOT_WORKSPACE_PAGE": "details"])
        pickIconAndSave(row: app.buttons["workspace.edit.icon"])
    }

    /// The Skills page lists one switch per skill with its saved state; a write
    /// with no server shows its error inline, and a skill's info button pushes
    /// that skill's detail on the page's server.
    func testWorkspaceSkillsPageTogglesAndOpensDetail() {
        launch(screen: "workspace-settings", environment: ["SCREENSHOT_WORKSPACE_PAGE": "skills"])
        let list = app.collectionViews["workspace.edit.skills.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "The Skills page did not open")
        XCTAssertTrue(app.navigationBars["Skills"].exists, "The Skills page must carry its title")
        let enabled = list.switches["workspace.edit.skill.agents-md"]
        let disabled = list.switches["workspace.edit.skill.audio-transcribe"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5), "A skill must show its switch")
        XCTAssertEqual(enabled.value as? String, "1")
        XCTAssertEqual(disabled.value as? String, "0")
        // The controls keep their own size at the trailing edge, wide iPad row
        // included: the info button never takes the row's spare width.
        let info = list.buttons["workspace.edit.skill.agents-md.detail"]
        XCTAssertTrue(info.exists, "A skill must show its info button")
        XCTAssertLessThanOrEqual(info.frame.width, 60, "The info button must not stretch")
        XCTAssertLessThanOrEqual(info.frame.minX - enabled.frame.maxX, 16, "The switch must sit beside the info button")
        XCTAssertEqual(enabled.frame.minX, disabled.frame.minX, accuracy: 1, "The switches must form one column")
        attachScreenshot("workspace-skills-page")

        enabled.tap()
        XCTAssertTrue(
            list.staticTexts["Server is offline"].waitForExistence(timeout: 5),
            "A write with no server must show its error"
        )
        XCTAssertEqual(enabled.value as? String, "1", "A refused write must put the switch back")

        info.tap()
        XCTAssertTrue(app.navigationBars["agents-md"].waitForExistence(timeout: 5), "The info button did not push the skill")
        XCTAssertTrue(app.staticTexts["Failed to load"].waitForExistence(timeout: 5), "A detail with no server must say it failed")
        attachScreenshot("workspace-skill-detail-offline")
        assertRunning()
    }

    /// The Extensions page lists Oppi's and Pi's extensions with a switch each; a
    /// write with no server shows its error inline and puts the switch back.
    func testWorkspaceExtensionsPageTogglesAndShowsItsError() {
        launch(screen: "workspace-settings", environment: ["SCREENSHOT_WORKSPACE_PAGE": "extensions"])
        let list = app.collectionViews["workspace.edit.extensions.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "The Extensions page did not open")
        XCTAssertTrue(app.navigationBars["Extensions"].exists, "The Extensions page must carry its title")
        let enabled = list.switches["workspace.edit.extension.workflow"]
        let disabled = list.switches["workspace.edit.extension.simplify"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5), "An extension must show its switch")
        XCTAssertEqual(enabled.value as? String, "1")
        XCTAssertEqual(disabled.value as? String, "0")
        attachScreenshot("workspace-extensions-page")

        enabled.tap()
        XCTAssertTrue(
            list.staticTexts["Server is offline"].waitForExistence(timeout: 5),
            "A write with no server must show its error"
        )
        XCTAssertEqual(enabled.value as? String, "1", "A refused write must put the switch back")
        assertRunning()
    }

    /// Workspace Settings carries the compact Oppi bar for this workspace:
    /// no pills at rest, the pills with the keyboard, Send once there is text.
    func testWorkspaceSettingsShowsTheOppiBar() {
        launch(screen: "workspace-settings")
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Workspace Settings did not show the Oppi bar")
        let send = app.buttons["chat.send"]
        let model = app.buttons["session.toolbar.model"]
        XCTAssertFalse(send.isEnabled, "Send must wait for a request")
        XCTAssertFalse(model.exists, "The compact bar shows no pills at rest")
        attachScreenshot("workspace-settings-oppi-bar-rest")
        input.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5), "Focus must open the pills")
        input.typeText("Rename it")
        XCTAssertTrue(waitFor(send.isEnabled), "Typing must enable Send")
        attachScreenshot("workspace-settings-oppi-bar-expanded")
        assertRunning()
    }

    // MARK: SSH terminal

    func testHerdrSheetClosesByDoneAndBySwipe() {
        // Herdr is an experiment (Settings → Experiments): this test asks for it.
        launch(screen: "ssh-terminal", arguments: OppiTestLaunch.experimentArguments([.herdr: true]))
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
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Herdr sheet must close")
            assertRunning()
        }
    }

    /// A Rex terminal moves between its session's panes with a sideways swipe,
    /// and a vertical drag on the same grid still scrolls history (the swipe
    /// must neither swallow the scroll nor scroll along with it). The bar's pane
    /// switcher names the pane on screen and its menu shows another. The layout
    /// minimap is hidden at rest and while history scrolls, and shows only
    /// while the pane changes.
    func testRexTerminalSwipesBetweenPanesAndStillScrollsHistory() {
        // Rex is an experiment (Settings → Experiments): this test asks for it.
        launch(screen: "ssh-terminal-rex-panes", arguments: OppiTestLaunch.experimentArguments([.rex: true]))
        let switcher = app.buttons["sshTerminal.bar.rexPanes"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "The pane switcher did not appear in the bar")
        XCTAssertEqual(switcher.label, "Pane")
        XCTAssertEqual(paneValue(switcher), "\u{03C0} - oppi, 1 of 3", "The session opens on its first pane")
        let cells = (0...2).map { app.buttons["sshTerminal.rexMinimap.\($0)"] }
        XCTAssertFalse(cells[0].exists, "The minimap stays hidden when the terminal opens")
        let grid = app.descendants(matching: .any)["sshTerminal.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        attachScreenshot("rex-panes-first")

        // A vertical drag scrolls history: the grid leaves the live screen and the pane stays.
        let backToLive = app.buttons["sshTerminal.backToLive"]
        XCTAssertFalse(backToLive.exists, "The grid starts on the live screen")
        let top = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let bottom = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        top.press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .default, thenHoldForDuration: 0)
        XCTAssertTrue(backToLive.waitForExistence(timeout: 5), "A vertical drag must scroll the history")
        XCTAssertEqual(paneValue(switcher), "\u{03C0} - oppi, 1 of 3", "A vertical drag must not change pane")
        XCTAssertFalse(cells[0].exists, "Scrolling history does not show the minimap")
        attachScreenshot("rex-panes-scrolled")
        backToLive.tap()
        XCTAssertTrue(backToLive.waitForNonExistence(timeout: 5), "Back to Live must return the grid to the live screen")

        // A sideways swipe moves to the next pane, and back.
        grid.swipeLeft()
        XCTAssertTrue(waitFor(paneValue(switcher) == "tail -f server.log, 2 of 3"), "A swipe left must show the next pane")
        XCTAssertTrue(cells[1].waitForNonExistence(timeout: 5), "The minimap is not left on screen after the switch settles")
        attachScreenshot("rex-panes-second")
        grid.swipeRight()
        XCTAssertTrue(waitFor(paneValue(switcher) == "\u{03C0} - oppi, 1 of 3"), "A swipe right must show the previous pane")
        XCTAssertTrue(cells[0].waitForNonExistence(timeout: 5), "The minimap is not left on screen after the swipe back")

        // Touch and hold shows the quick menu of the panes in strip order, and shows the one chosen
        // (a tap opens the Rex panel instead).
        switcher.press(forDuration: 1.0)
        let third = app.buttons["sshTerminal.rexPanes.2"]
        XCTAssertTrue(third.waitForExistence(timeout: 5), "The switcher's menu did not open")
        XCTAssertTrue(app.buttons["sshTerminal.rexPanes.0"].exists && app.buttons["sshTerminal.rexPanes.1"].exists)
        attachScreenshot("rex-panes-menu")
        third.tap()
        XCTAssertTrue(waitFor(paneValue(switcher) == "\u{2733} Fixing the build, 3 of 3"), "A menu choice must show that pane")
        XCTAssertTrue(cells[2].waitForNonExistence(timeout: 5), "The minimap is not left on screen after a menu choice")

        // Customize Bar opened from this Rex pane lists the switcher but neither
        // Herdr nor Rex Sessions: a terminal in Rex offers only Rex, and its one
        // Rex control (the pane switcher) holds Rex Sessions.
        app.buttons["sshTerminal.more"].tap()
        let customize = app.buttons["sshTerminal.menu.customize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5), "The … menu did not open")
        customize.tap()
        let list = app.descendants(matching: .any)["settings.sshTerminal.bar.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), "Customize Bar did not open")
        XCTAssertTrue(app.descendants(matching: .any)["settings.sshTerminal.bar.row.switcher"].waitForExistence(timeout: 5), "A Rex pane's Customize Bar must list the switcher")
        XCTAssertFalse(app.descendants(matching: .any)["settings.sshTerminal.bar.row.rex"].exists, "A Rex pane's Customize Bar must not list Rex Sessions")
        let panelChoice = app.descendants(matching: .any)["settings.sshTerminal.bar.rexPanel.thisPane"]
        scrollUntilHittable(panelChoice)
        XCTAssertTrue(panelChoice.exists, "A Rex pane's Customize Bar must offer the Rex panel's choices")
        XCTAssertFalse(app.descendants(matching: .any)["settings.sshTerminal.bar.row.herdr"].exists, "A Rex pane's Customize Bar must not list Herdr")
        attachScreenshot("rex-customize-bar")
        assertRunning()
    }

    /// Swiping left past the last pane opens a new one, shown on arrival; the
    /// switcher counts it and rolls to it. The switcher menu's New Pane item
    /// opens another, and a swipe right at the first pane opens nothing.
    func testRexTerminalSwipePastTheLastPaneOpensANewPane() {
        // Rex is an experiment (Settings → Experiments): this test asks for it.
        launch(screen: "ssh-terminal-rex-panes", arguments: OppiTestLaunch.experimentArguments([.rex: true]))
        let switcher = app.buttons["sshTerminal.bar.rexPanes"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "The pane switcher did not appear in the bar")
        XCTAssertEqual(paneValue(switcher), "\u{03C0} - oppi, 1 of 3")
        let grid = app.descendants(matching: .any)["sshTerminal.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))

        // The first pane's edge gives way and opens nothing.
        grid.swipeRight()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(paneValue(switcher), "\u{03C0} - oppi, 1 of 3", "A swipe right at the first pane must not change anything")

        // Walk to the last pane, then swipe past it.
        grid.swipeLeft()
        XCTAssertTrue(waitFor(paneValue(switcher) == "tail -f server.log, 2 of 3"))
        grid.swipeLeft()
        XCTAssertTrue(waitFor(paneValue(switcher) == "\u{2733} Fixing the build, 3 of 3"))
        grid.swipeLeft()
        XCTAssertTrue(waitFor(paneValue(switcher) == "new shell, 4 of 4"), "A swipe past the last pane must open and show a new pane")
        attachScreenshot("rex-panes-new")
        XCTAssertFalse(app.buttons["sshTerminal.openNotice"].exists, "A pane that opened has no error to show")

        // The menu's last item opens another one after the shown pane.
        switcher.press(forDuration: 1.0)
        let newPane = app.buttons["sshTerminal.rexPanes.new"]
        XCTAssertTrue(newPane.waitForExistence(timeout: 5), "The switcher's menu has no New Pane item")
        XCTAssertEqual(newPane.label, "New Pane")
        attachScreenshot("rex-panes-new-menu")
        newPane.tap()
        XCTAssertTrue(waitFor(paneValue(switcher) == "new shell, 5 of 5"), "The menu's New Pane must open and show a pane")
        assertRunning()
    }

    /// The Terminal tab leads with the saved Rex host's live sessions: one
    /// row per session naming it, where it works, its windows and panes, and
    /// who waits on you, with the status as its value. The disclosure lists a
    /// session's panes, grouped by window, and a tap on a pane or on the
    /// session opens it as a Rex terminal.
    func testTerminalTabListsRexSessionsExpandsThemAndATapOpensTheTerminal() {
        // Rex is an experiment (Settings → Experiments): this test asks for it.
        launch(screen: "ssh-terminal-rex-list", arguments: OppiTestLaunch.experimentArguments([.rex: true]))
        let hostID = "5E5E5E5E-0000-4000-8000-000000000001"
        let prefix = "sshTerminal.rexList.\(hostID)."
        let oppi = app.buttons[prefix + "session:01a18a26-6620-76be-b529-4d9ad2b36c63"]
        let dotfiles = app.buttons[prefix + "session:01a18a26-6620-76be-b529-4d9ad2b36c64"]
        XCTAssertTrue(oppi.waitForExistence(timeout: 15), "The Rex section did not list its sessions")
        XCTAssertTrue(dotfiles.exists)
        XCTAssertTrue(app.descendants(matching: .any)[prefix + "header"].exists, "The host's heading is missing")
        XCTAssertEqual(oppi.label, "oppi, in oppi, 2 windows \u{00B7} 3 panes \u{00B7} 1 needs you")
        XCTAssertEqual(oppi.value as? String, "Needs approval")
        XCTAssertEqual(dotfiles.label, "dotfiles, in dotfiles, 1 pane")
        XCTAssertEqual(dotfiles.value as? String, "Idle")
        // The host's own row stays below the section.
        XCTAssertTrue(app.buttons["sshTerminal.host.row.\(hostID)"].exists, "The Rex host's row must stay")
        attachScreenshot("terminal-tab-rex-section")

        // The disclosure shows the session's panes under the name of each window.
        let pi = app.cells[prefix + "block:01a18a7e-911a-721b-a50b-14dfc0cc62ca"]
        XCTAssertFalse(pi.exists, "Sessions start collapsed")
        let disclosure = app.buttons[prefix + "session:01a18a26-6620-76be-b529-4d9ad2b36c63.disclosure"]
        XCTAssertEqual(disclosure.value as? String, "Collapsed")
        disclosure.tap()
        XCTAssertTrue(pi.waitForExistence(timeout: 5), "The disclosure must list the session's panes")
        XCTAssertEqual(disclosure.value as? String, "Expanded")
        XCTAssertTrue(app.descendants(matching: .any)[prefix + "window:01a18a26-6645-713c-97f1-2f1058c8c82f"].exists, "A session with two windows names each")
        XCTAssertTrue(app.cells[prefix + "block:01a18a26-6620-78ba-80d4-4e8caa018b37"].exists)
        XCTAssertFalse(app.cells[prefix + "block:01a18a7e-911a-721b-a50b-14dfc0cc62cc"].exists, "Another session stays collapsed")
        attachScreenshot("terminal-tab-rex-expanded")

        // A tap on a pane opens the session's terminal.
        pi.tap()
        let switcher = app.buttons["sshTerminal.bar.rexPanes"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "A tap on a pane must open its Rex terminal")
        attachScreenshot("terminal-tab-rex-opened")
        assertRunning()
    }

    /// Rex and Herdr are experiments, and the app ships with both off: the
    /// Terminal tab then has no Rex UI at all, though the host saved with Rex is
    /// still a saved host, opening as its plain shell.
    func testTerminalTabHasNoRexOrHerdrWhileBothExperimentsAreOff() {
        // Both off explicitly: the app ships this way, and a value another run left
        // in the slot's app container must not decide it.
        launch(screen: "ssh-terminal-rex-list", arguments: OppiTestLaunch.experimentArguments([.rex: false, .herdr: false]))
        let hostID = "5E5E5E5E-0000-4000-8000-000000000001"
        let host = app.buttons["sshTerminal.host.row.\(hostID)"]
        XCTAssertTrue(host.waitForExistence(timeout: 15), "The saved Rex host is still listed with the experiment off")
        XCTAssertFalse(app.descendants(matching: .any)["sshTerminal.rexList.\(hostID).header"].exists, "No Rex section with the experiment off")
        // The tailnet list is Settings › Terminal › Rex on Your Tailnet now, and that
        // page has no Rex row while the experiment is off (`SSHTerminalSettingsUITests`).
        attachScreenshot("terminal-tab-experiments-off")
        assertRunning()
    }

    /// A session on the Terminal tab is closed only after a confirmation,
    /// renamed from an alert (the list follows Rex's event), and a new one is
    /// made and opened by the row after the sessions.
    func testTerminalTabClosesRenamesAndCreatesRexSessions() {
        // Rex is an experiment (Settings → Experiments): this test asks for it.
        launch(screen: "ssh-terminal-rex-list", arguments: OppiTestLaunch.experimentArguments([.rex: true]))
        let prefix = "sshTerminal.rexList.5E5E5E5E-0000-4000-8000-000000000001."
        let dotfiles = app.buttons[prefix + "session:01a18a26-6620-76be-b529-4d9ad2b36c64"]
        XCTAssertTrue(dotfiles.waitForExistence(timeout: 15), "The Rex section did not list its sessions")

        // Close asks first, and Cancel leaves the session where it is.
        dotfiles.swipeLeft()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "A swipe must offer Close")
        XCTAssertTrue(app.buttons["Rename"].exists, "A swipe must offer Rename")
        attachScreenshot("terminal-tab-rex-swipe")
        close.tap()
        let confirm = app.alerts["Close session \u{201C}dotfiles\u{201D}?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Close must ask first")
        XCTAssertTrue(confirm.staticTexts["Every pane's program ends."].exists)
        attachScreenshot("terminal-tab-rex-close-confirm")
        confirm.buttons["Cancel"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(dotfiles.exists, "Cancel must leave the session")

        // Rename: the name goes to Rex and the row follows its event.
        dotfiles.swipeLeft()
        app.buttons["Rename"].tap()
        let field = app.textFields["sshTerminal.rexList.rename.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Rename must ask for a name")
        XCTAssertEqual(field.value as? String, "dotfiles")
        attachScreenshot("terminal-tab-rex-rename")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "config")
        // The accessibility tree doubles an identified alert button (one inside the other, same identifier).
        app.alerts["Rename Session"].buttons["sshTerminal.rexList.rename.confirm"].firstMatch.tap()
        XCTAssertTrue(waitFor(dotfiles.label.hasPrefix("config,"), timeout: 10), "The row must take the new name from Rex's event")

        // Closing it, confirmed, removes it.
        dotfiles.swipeLeft()
        app.buttons["Close"].tap()
        let again = app.alerts["Close session \u{201C}config\u{201D}?"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        // The accessibility tree doubles an identified alert button here too (Close is not the preferred one).
        again.buttons["sshTerminal.rexList.close.confirm"].firstMatch.tap()
        XCTAssertTrue(dotfiles.waitForNonExistence(timeout: 10), "A closed session must leave the list")
        attachScreenshot("terminal-tab-rex-closed")

        // New Rex Session opens the shell it makes.
        let new = app.cells[prefix + "new"]
        XCTAssertTrue(new.waitForExistence(timeout: 5), "New Rex Session is missing")
        new.tap()
        XCTAssertTrue(app.buttons["sshTerminal.bar.rexPanes"].waitForExistence(timeout: 15), "New Rex Session must open the new shell")
        assertRunning()
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
                detail.waitForNonExistence(timeout: 5),
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
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Cancel must close the password sheet")
        assertRunning()

        host.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Password sheet did not reopen")
        dragToBottom(sheet)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Swipe-down must close the password sheet")
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
            XCTAssertTrue(back.waitForNonExistence(timeout: 5), "Back must close the player")
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
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "Cancel must close the icon picker")
        assertRunning()

        // Full screen in compact width; swipe-down only where it is a sheet.
        if app.windows.firstMatch.horizontalSizeClass != .compact {
            row.tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "Icon picker did not reopen")
            dragToBottom(app.navigationBars.firstMatch)
            XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "Swipe-down must close the icon picker")
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
        XCTAssertTrue(picker.waitForNonExistence(timeout: 15), "Save must close the icon picker")
        XCTAssertTrue(
            waitFor(row.value as? String != before),
            "The picked icon (\(symbolID)) must reach the form: \(row.value as? String ?? "nil")"
        )
        assertRunning()
    }

    private func launchSite(_ site: String) {
        launch(screen: "router-modal-sites", environment: ["SCREENSHOT_MODAL_SITE": site])
    }

    /// A preview on fixture services: these sites wait for their own surface,
    /// so the launch does not also wait on the host's `screenshot.ready` marker.
    private func launch(screen: String, environment: [String: String] = [:], arguments: [String] = []) {
        launchPreview(screen: screen, environment: environment, colorScheme: "dark", arguments: arguments, ready: nil)
    }

    private func label(_ identifier: String) -> String {
        let element = app.staticTexts[identifier]
        _ = element.waitForExistence(timeout: 5)
        return element.label
    }

    /// The pane switcher's value up to "N of M": what follows is its program's
    /// status, which the panes of the preview have or have not.
    private func paneValue(_ element: XCUIElement) -> String? {
        guard let value = element.value as? String,
              let range = value.range(of: #"^.*?, \d+ of \d+"#, options: .regularExpression) else { return element.value as? String }
        return String(value[range])
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

    /// System cancel and close controls. Bar items can sit outside the
    /// navigation bar element: the iPhone Duo moves them to a vertical rail.
    private var cancelButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch
    }
}
