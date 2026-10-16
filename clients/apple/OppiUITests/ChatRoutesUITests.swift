import XCTest

/// Taps through every router modal and side panel chat owns, on the
/// production ChatView with fixture services (`SCREENSHOT_SCREEN=chat-routes`).
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ROUTES_FILL_2")).firstMatch
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
        attachScreenshot("context")

        // A loaded skill, then one of its files, push inside the panel.
        let skillRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "route-skill")).firstMatch
        XCTAssertTrue(skillRow.waitForExistence(timeout: 10), "The session's loaded skill is missing")
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
        XCTAssertTrue(app.staticTexts["GPT Routes"].waitForExistence(timeout: 5), "Model picker must list the chat's models")
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
        emails.switches.firstMatch.tap()
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

    func testContextBarCommitPushesAChatAndShowsTheDiffPanel() {
        launch()
        openContextBar()
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

    func testContextBarFileReviewOpensAndCloses() {
        launch()
        openContextBar()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "App.swift")).firstMatch.tap()
        let review = app.navigationBars["App.swift"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "File review sheet did not open")
        attachScreenshot("context-bar-file-review")
        app.buttons[closeLabel].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(of: review), "Close must close the file review")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "App.swift")).firstMatch.tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        dragToBottom(review)
        XCTAssertTrue(waitForDisappearance(of: review), "Swipe-down must close the file review")
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

    /// Outside chat (no reader to push), the native detail is a router modal
    /// that closes with its own Done.
    func testExtensionNativeDetailClosesWithItsOwnDone() {
        launchScreen("extension-widget")
        let pill = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "extension-strip-aboveEditor-pill-widget")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "Native widget pill missing")
        pill.tap()
        let viewport = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "extension-native-surface-widget", "-viewport"))
            .firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), "Native widget drawer did not open")
        viewport.doubleTap()
        // The detail's container identifier also lands on its Done button.
        let done = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@ AND label == %@", "-detail", "Done")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Native detail did not open")
        attachScreenshot("extension-native-detail")
        done.tap()
        XCTAssertTrue(waitForDisappearance(of: done), "Done must close the native detail")
        XCTAssertTrue(pill.exists)
        assertRunning()
    }

    /// The outline's summary-instructions sheet is a router sheet above it;
    /// the typed instructions reach the outline's tree navigation.
    func testOutlineSummarySheetSendsInstructionsToTheOutline() {
        launchScreen("session-timeline")
        let outline = app.navigationBars["Session Outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 10), "Outline preview did not appear in a navigation bar")
        _ = outlineSearchField()
        app.buttons["Tree"].tap()
        let node = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Ship list mode first")).firstMatch
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

    /// The git bar's commit rows take taps on their text only: the space
    /// between message and chevron is not hit-testable.
    private func tapCommitRow() {
        app.staticTexts["Route commit"].firstMatch.tap()
    }

    /// Expands the git bar and waits for its rows to stop moving.
    private func openContextBar() {
        let toggle = app.buttons["workspace-context-bar.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Context bar missing")
        toggle.tap()
        let commitRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Route commit")).firstMatch
        XCTAssertTrue(commitRow.waitForExistence(timeout: 5), "The expanded bar must list the commit")
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

    private func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "The app must still be running", file: file, line: line)
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
