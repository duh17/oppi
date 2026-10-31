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
final class RouterSettingsModalsUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Router modal tests are simulator-only")
#endif
        continueAfterFailure = false
        // The simulator keeps the orientation an earlier test left. In iPhone
        // landscape (compact height) a sheet presents full screen, which has no
        // swipe-down to close, so every sheet claim here is a portrait claim.
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Agents

    func testPiPromptViewerAndOppiBar() {
        launch(page: "agents-pi")

        let prompt = app.buttons["agents.pi.systemPrompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "Pi detail did not load")
        // Pi's prompt reader is one screen whether or not SYSTEM.md exists: the
        // page opens it as a sheet, and the sheet's own dismiss control closes it.
        assertReviewSheet { prompt.tap() }

        // SYSTEM.md does not exist here, and the reader still offers the pencil.
        // Its editor starts from Pi's default prompt — the text the reader shows —
        // so leaving it alone writes nothing.
        prompt.tap()
        let pencil = app.buttons["workspace-file-editor.edit"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 5), "A missing SYSTEM.md must still be editable")
        attachScreenshot("pi-prompt-reader-pencil")
        tapBarButton(pencil)
        let editor = app.textViews["workspace-file-editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "The pencil must open the editor")
        XCTAssertEqual(
            (editor.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            "You are a coding agent.",
            "The editor opens on Pi's default prompt, not on nothing"
        )
        attachScreenshot("pi-prompt-editor-default")
        assertRunning()
        tapBarButton(app.buttons["workspace-file-editor.done"])
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "Done must return to the reader")
        XCTAssertFalse(
            lastWrite.contains("PUT /files/current"),
            "An untouched default writes nothing: \(lastWrite)"
        )

        // The first real edit is the person's to save: Auto-Save is off by default,
        // so Done asks, and Discard Changes writes nothing. The fixture records the
        // write's method and path (a text body is not summarised), so that is what
        // this can see; the create's `If-None-Match: *` is the unit test's claim.
        tapBarButton(pencil)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" Ship it.")
        tapBarButton(app.buttons["workspace-file-editor.done"])
        XCTAssertTrue(
            app.staticTexts["Create SYSTEM.md?"].waitForExistence(timeout: 5),
            "Done must ask before creating a file Pi reads for every new session"
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Pi uses this file for every new session on")
            ).firstMatch.exists,
            "the confirmation must say what else reads SYSTEM.md"
        )
        attachScreenshot("pi-prompt-done-confirmation")
        tapBarButton(app.buttons["workspaceFileEditor.discard"])
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "Discard Changes must return to the reader")
        XCTAssertFalse(
            lastWrite.contains("PUT /files/current"),
            "Discard Changes writes nothing: \(lastWrite)"
        )

        // Save writes it, and the reader comes back without a second question.
        tapBarButton(pencil)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" Ship it.")
        tapBarButton(app.buttons["workspace-file-editor.done"])
        tapBarButton(app.buttons["workspaceFileEditor.save"])
        XCTAssertTrue(
            waitFor(lastWrite.contains("PUT /files/current"), timeout: 15),
            "Save must create the file: \(lastWrite)"
        )
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "Save must return to the reader")
        app.buttons["fullScreen.code.close"].tap()

        assertCompactOppiBar(page: "agents-pi")
    }

    /// Tools is a pushed screen of its own: a toggle there must show its new
    /// state and save at once, and Back returns to Pi.
    func testPiToolsPushSavesAndGoesBack() {
        launch(page: "agents-pi")
        let toolsRow = app.buttons["agents.pi.tools"]
        XCTAssertTrue(toolsRow.waitForExistence(timeout: 10), "Pi detail did not load")
        toolsRow.tap()
        XCTAssertTrue(app.navigationBars["Pi Tools"].waitForExistence(timeout: 5), "Pi did not push Tools")
        // The fixture's Pi tools are `+codemode`.
        let codemode = app.switches["agent.nativeEdit.optionalTool.codemode"]
        XCTAssertTrue(codemode.waitForExistence(timeout: 5))
        XCTAssertEqual(codemode.value as? String, "1", "Tools must open with Pi's loaded selection")
        codemode.tap()
        XCTAssertTrue(waitFor(codemode.value as? String == "0", timeout: 10), "The pushed page must show its own change")
        XCTAssertTrue(
            waitFor(lastWrite.contains("PUT /server/resources/pi/default-tools"), timeout: 10),
            "The change must save at once: \(lastWrite)"
        )
        assertRunning()

        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(toolsRow.waitForExistence(timeout: 5), "Back must return to Pi")
        assertRunning()
    }

    func testPiFilePromptOpensReviewSheet() {
        launch(page: "agents-pi-file")
        let prompt = app.buttons["agents.pi.systemPrompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "Pi detail did not load")
        assertReviewSheet { prompt.tap() }

        // A SYSTEM.md that exists is a document: the reader has the pencil, and
        // the "…" beside it holds Edit with Session.
        prompt.tap()
        let more = app.buttons["document.edit.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "The prompt reader offered no edit entry")
        let pencil = app.buttons["workspace-file-editor.edit"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "An existing SYSTEM.md must be editable")
        attachScreenshot("pi-prompt-reader-entry")
        tapBarButton(pencil)
        let text = app.textViews["workspace-file-editor.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "The pencil did not open the editor")
        attachScreenshot("pi-prompt-editor")
        assertRunning()
        tapBarButton(app.buttons["workspace-file-editor.done"])
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "Done must return to the reader")
        tapBarButton(more)
        let edit = app.buttons["controlFile.editInSession"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "The overflow did not offer Edit with Session")
        attachScreenshot("pi-prompt-session-menu")
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
        XCTAssertTrue(pickerList.waitForNonExistence(timeout: 10), "Cancel must close the icon picker")
        if !compactWidth {
            iconRow.tap()
            XCTAssertTrue(pickerList.waitForExistence(timeout: 5), "Icon picker did not reopen")
            dragToBottom(app.navigationBars["Agent Icon"])
            XCTAssertTrue(pickerList.waitForNonExistence(timeout: 10), "Swipe-down must close the icon picker")
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
        XCTAssertTrue(pickerList.waitForNonExistence(timeout: 10), "Save must close the icon picker")
        XCTAssertTrue(
            waitFor(lastWrite.contains("PATCH /agents/agent-design") && lastWrite.contains(symbolName), timeout: 10),
            "The picked icon must reach the server: \(lastWrite)"
        )
        // The fixture server answers with a fox emoji; the detail under the
        // full-screen picker on iPhone must show it afterwards.
        XCTAssertTrue(
            waitFor((iconRow.value as? String) == "Emoji 🦊", timeout: 10),
            "The saved agent must reach the detail: \(String(describing: iconRow.value))"
        )
        assertRunning()

        assertReviewSheet { self.app.buttons["agents.detail.definition"].tap() }

        assertGuidedSheet(
            opener: { self.tapScrolledIntoView(self.app.buttons["agents.detail.schedule"]) },
            title: "Create Schedule"
        )

        assertCompactOppiBar(page: "agents-detail")
    }

    /// The keyboard of the Agents list's guided composer must not outlive the
    /// screen: open an Agent and its full-screen editor while the composer
    /// has the keyboard, close both, and the composer is above the keyboard
    /// or the keyboard is down. It once stayed up over a list whose composer
    /// had gone, with nothing left to dismiss it.
    func testGuidedComposerKeyboardAfterAgentDetailAndEditor() {
        launch(page: "agents")
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Agents composer did not appear")
        input.tap()
        input.typeText("Draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The composer did not raise the keyboard")

        let row = app.buttons["agents.row.agent-design"]
        row.tap()
        let edit = app.buttons["agents.detail.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Agent detail did not load")
        tapBarButton(edit)
        XCTAssertTrue(app.navigationBars["Edit Agent"].waitForExistence(timeout: 10), "The editor did not open")
        tapBarButton(cancelButton)
        XCTAssertTrue(app.navigationBars["Edit Agent"].waitForNonExistence(timeout: 10), "Cancel must close the editor")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Back must return to Agents")

        XCTAssertTrue(input.waitForExistence(timeout: 5), "The composer must be back")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(
            waitFor(!keyboard.exists || input.frame.maxY <= keyboard.frame.minY + 1, timeout: 10),
            "The composer must sit above the keyboard or the keyboard be down: input \(input.frame), keyboard \(keyboard.exists ? keyboard.frame : .zero)"
        )
        // A keyboard left up must belong to the composer, so it can dismiss it.
        if keyboard.exists {
            XCTAssertEqual(
                input.value(forKey: "hasKeyboardFocus") as? Bool, true,
                "A keyboard that is up must belong to the composer"
            )
        }
        attachScreenshot("agents-composer-after-detail")
        assertRunning()
    }

    /// The guided composer's model pill opens the shared UIKit model picker
    /// over the Agents list; Cancel and swipe-down both close it.
    func testGuidedComposerModelPicker() {
        launch(page: "agents")
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Agents composer did not appear")
        input.tap()
        let pill = app.buttons["session.toolbar.model"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "A focused guided composer shows the model pill")
        let models = app.navigationBars["Models"]

        pill.tap()
        XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not open")
        attachScreenshot("guided-composer-model-picker")
        assertRunning()
        tapBarButton(cancelButton)
        XCTAssertTrue(models.waitForNonExistence(timeout: 10), "Cancel must close the model picker")

        pill.tap()
        XCTAssertTrue(models.waitForExistence(timeout: 5), "Model picker did not reopen")
        dragToBottom(models)
        XCTAssertTrue(models.waitForNonExistence(timeout: 10), "Swipe-down must close the model picker")
        assertRunning()
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

        // A schedule's prompt carries the same pencil as an Agent's: the reader
        // edits the schedule's own prompt in place (its save and conflict are
        // the transport and owner tests').
        tapScrolledIntoView(prompt)
        let pencil = app.buttons["workspace-file-editor.edit"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "The schedule prompt reader has no pencil")
        XCTAssertTrue(app.buttons["document.edit.more"].exists, "The prompt reader keeps Edit with Session beside the pencil")
        tapBarButton(app.buttons["fullScreen.code.close"])
        XCTAssertTrue(pencil.waitForNonExistence(timeout: 10), "Its dismiss control must close the review sheet")

        assertCompactOppiBar(page: "schedule-detail")
    }

    /// An Agent's prompt opens in our editor from the reader's pencil; typing
    /// saves through the Agent with the mode the record already had, and Done
    /// returns to the definition reader showing the new text. The "…" keeps
    /// Edit with Session beside the pencil.
    func testAgentPromptReaderEditsInPlace() {
        launch(page: "agents")
        let row = app.buttons["agents.row.agent-design"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Agents list did not load")
        row.tap()
        let definition = app.buttons["agents.detail.definition"]
        XCTAssertTrue(definition.waitForExistence(timeout: 10), "Agent detail did not load")
        tapScrolledIntoView(definition)

        let pencil = app.buttons["workspace-file-editor.edit"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "The prompt reader has no pencil")
        let more = app.buttons["document.edit.more"]
        XCTAssertTrue(more.exists, "The prompt reader keeps Edit with Session beside the pencil")
        attachScreenshot("agent-prompt-reader")
        assertRunning()

        tapBarButton(pencil)
        let text = app.textViews["workspace-file-editor.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "The pencil did not open the editor")
        XCTAssertFalse(
            app.segmentedControls["agentPromptEditor.mode"].exists, // ax-id-guard: absent-on-purpose
            "The prompt editor edits text only; the Agent's own form holds the mode"
        )
        attachScreenshot("agent-prompt-editor")
        assertRunning()

        text.tap()
        text.typeText(" Ship it.")
        XCTAssertTrue(
            waitFor(
                lastWrite.contains("PATCH /agents/agent-design") && lastWrite.contains("Ship it"),
                timeout: 15
            ),
            "The edit must save through the Agent: \(lastWrite)"
        )
        XCTAssertTrue(
            lastWrite.contains("\"mode\":\"append\""),
            "The save keeps the Agent's own mode: \(lastWrite)"
        )

        tapBarButton(app.buttons["workspace-file-editor.done"])
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "Done must return to the reader")
        // The reader shows the whole definition again, not the prompt alone.
        let definitionField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Pi Session Defaults", "Pi Session Defaults"))
            .firstMatch
        XCTAssertTrue(definitionField.waitForExistence(timeout: 10), "The reader must still show the Agent's definition")
        let saved = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Ship it.", "Ship it."))
            .firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "The reader must show the saved prompt")
        assertRunning()
    }

    // MARK: SSH hosts

    func testSSHHostFormPushesAndGoesBack() {
        launch(page: "ssh-hosts")
        let add = app.buttons["sshTerminal.host.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "SSH host list did not appear")
        tapBarButton(add)
        let hostField = app.textFields["sshTerminal.host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 5), "Add Host did not push the host form")
        assertRunning()
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(hostField.waitForNonExistence(timeout: 10), "Back must pop the host form")
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Back must return to the host list")
        assertRunning()
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

    /// A server without Skill file editing: the entry is the "…" alone, and it
    /// holds Edit with Session.
    func testSkillFileGuidedRevisionSheet() {
        launch(page: "skill-file-review")
        let more = app.buttons["document.edit.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Skill file viewer did not load")
        XCTAssertFalse(app.buttons["workspace-file-editor.edit"].exists, "No editor means no pencil")
        assertGuidedSheet(
            opener: {
                self.tapBarButton(more)
                let edit = self.app.buttons["controlFile.editInSession"]
                XCTAssertTrue(edit.waitForExistence(timeout: 5), "The overflow did not offer Edit with Session")
                self.attachScreenshot("skill-file-session-menu")
                edit.tap()
            },
            title: "Revise release"
        )
    }

    /// An extension that is a user-owned file: its page carries the compact
    /// Oppi bar for that extension.
    func testExtensionDetailShowsTheOppiBar() {
        launch(page: "extension-detail")
        assertCompactOppiBar(page: "extension-detail")
    }

    /// A server that edits Skill files: the pencil opens the editor on the same
    /// file, and the "…" beside it holds Edit with Session. Typing saves through
    /// the Skill, and Done returns to the reader with both controls.
    func testSkillFileEditEntryEditsInPlaceOrWithSession() {
        launch(page: "skill-file-edit")
        let pencil = app.buttons["workspace-file-editor.edit"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "Skill file edit entry did not load")
        let more = app.buttons["document.edit.more"]
        XCTAssertTrue(more.exists, "The edit entry must offer Edit with Session beside the pencil")
        attachScreenshot("skill-file-edit-entry")

        pencil.tap()
        let text = app.textViews["workspace-file-editor.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "The pencil did not open the editor")
        text.tap()
        text.typeText("Ship it.")
        XCTAssertTrue(
            waitFor(lastWrite.contains("PUT /files/current"), timeout: 15),
            "The edit must autosave through the Skill: \(lastWrite)"
        )
        tapBarButton(app.buttons["workspace-file-editor.done"])
        XCTAssertTrue(pencil.waitForExistence(timeout: 10), "Done did not return to the reader")
        assertRunning()

        assertGuidedSheet(
            opener: {
                self.tapBarButton(more)
                let edit = self.app.buttons["controlFile.editInSession"]
                XCTAssertTrue(edit.waitForExistence(timeout: 5), "The overflow did not offer Edit with Session")
                edit.tap()
            },
            title: "Revise release"
        )
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
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Cancel must close Add MCP Server")
        add.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Add MCP Server did not reopen")
        dragToBottom(sheet)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Swipe-down must close Add MCP Server")

        add.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Add MCP Server did not reopen after the swipe")
        let name = app.textFields["mcp.add.name"]
        name.tap()
        name.typeText("notes2")
        let url = app.textFields["mcp.add.url"]
        url.tap()
        url.typeText("https://notes2.example.com/mcp")
        tapBarButton(app.buttons["mcp.add.save"])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Add must close the sheet")
        XCTAssertTrue(
            waitFor(lastWrite.contains("POST /mcp/scopes/global/servers") && lastWrite.contains("\"name\":\"notes2\""), timeout: 10),
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
        XCTAssertTrue(waitFor(lastWrite.contains("\"name\":\"slow\""), timeout: 10), "The add did not start: \(lastWrite)")

        dragToBottom(sheet)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(sheet.exists, "Swipe-down must not close the sheet while it saves")
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 20), "The finished add must close the sheet")
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
        XCTAssertTrue(signIn.waitForNonExistence(timeout: 10), "Close must close sign-in")
        assertRunning()

        app.buttons["BackButton"].firstMatch.tap()
        let resume = app.buttons["mcp.auth.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "The list must keep the live sign-in")
        XCTAssertFalse(signIn.exists, "Going back must not present sign-in again")
        resume.tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5), "Continue Sign-In did not open from the list")
        dragToBottom(signIn)
        XCTAssertTrue(signIn.waitForNonExistence(timeout: 10), "Swipe-down must close sign-in")

        app.buttons["mcp.auth.cancel"].tap()
        XCTAssertTrue(
            waitFor(lastWrite.contains("POST /mcp/auth/flows/mcp-flow/cancel"), timeout: 10),
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
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 10), "Swipe-down must close the approval")
        assertRunning()

        launch(page: "pairing-approval")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "The pending approval did not present")
        // The controller blocks a denied approval and clears the prompt;
        // the binding change dismisses it. (The deny request itself waits for
        // a ready server transport, which the fixture connection lacks.)
        app.buttons["pairing.approval.deny"].tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 10), "Deny must close the approval")
        assertRunning()
    }

    func testOnboardingManualEntrySheet() {
        launch(page: "onboarding-add-server")
        let manual = app.buttons["onboarding.manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10), "Onboarding did not load")
        let entry = app.navigationBars["Connect Manually"]

        manual.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Manual entry did not open in a navigation bar")
        tapBarButton(cancelButton)
        XCTAssertTrue(entry.waitForNonExistence(timeout: 10), "Cancel must close manual entry")
        manual.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Manual entry did not reopen")
        dragToBottom(entry)
        XCTAssertTrue(entry.waitForNonExistence(timeout: 10), "Swipe-down must close manual entry")
        assertRunning()

        // An unsigned link names no server identity, so it cannot pair: the
        // field flags it and Connect stays off, so nothing is sent.
        manual.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Manual entry did not reopen after the swipe")
        let connect = app.buttons["onboarding.manual.connect"]
        XCTAssertFalse(connect.isEnabled, "Connect needs a pairing link")
        let link = app.textFields["onboarding.manual.link"]
        link.tap()
        link.typeText(
            "oppi://connect?v=3&payload=%7B%22v%22:3,%22host%22:%22127.0.0.1%22,%22port%22:1,"
                + "%22token%22:%22%22,%22pairingToken%22:%22pt_none%22,%22name%22:%22Unsigned%22%7D"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["onboarding.manual.invalidLink"].waitForExistence(timeout: 5),
            "An unsigned link must be flagged in the field"
        )
        XCTAssertFalse(connect.isEnabled, "An unsigned link must not enable Connect")
        XCTAssertTrue(entry.exists, "Manual entry stays open on an unsigned link")
        XCTAssertFalse(app.descendants(matching: .any)["onboarding.failure"].exists, "Nothing was sent, so nothing failed")
        assertRunning()
    }

    /// Onboarding's Set Up a Computer opens Tailscale as a sheet in a navigation
    /// controller: its Set Up a Mac or Linux Computer row pushes the Set Up a
    /// Computer screen inside the sheet, and Cancel closes it.
    func testOnboardingTailscaleSheetPushesSetUpAComputer() {
        launch(page: "onboarding-tailscale")
        let connect = app.buttons["onboarding.tailscale"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "Onboarding did not load")
        connect.tap()
        let tailscale = app.navigationBars["Tailscale"]
        XCTAssertTrue(tailscale.waitForExistence(timeout: 5), "Tailscale did not open in a navigation bar")
        assertRunning()

        let setUp = app.buttons["tailnet.checkMachine"]
        for _ in 0..<6 where !setUp.isHittable { app.swipeUp() }
        setUp.tap()
        XCTAssertTrue(app.navigationBars["Set Up a Computer"].waitForExistence(timeout: 5), "Set Up a Computer was not pushed")
        attachScreenshot("onboarding-set-up-a-computer")
        assertRunning()
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(tailscale.waitForExistence(timeout: 5), "Back must return to Tailscale")

        tapBarButton(cancelButton)
        XCTAssertTrue(tailscale.waitForNonExistence(timeout: 10), "Cancel must close the Tailscale sheet")
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        assertRunning()
    }

    // MARK: Shared checks

    /// A detail page's compact Oppi bar: one line at rest with no pills, the
    /// pills open with the keyboard, and typing enables Send. Sending is
    /// proved by the model and launch unit tests.
    private func assertCompactOppiBar(page: String) {
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "\(page) did not show the Oppi bar")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "\(page) did not show Send")
        let model = app.buttons["session.toolbar.model"]
        XCTAssertFalse(send.isEnabled, "Send must wait for a request")
        XCTAssertFalse(model.exists, "The compact bar shows no pills at rest")
        attachScreenshot("\(page)-oppi-bar-rest")
        input.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5), "Focus must open the pills")
        input.typeText("Make it shorter")
        XCTAssertTrue(waitFor(send.isEnabled, timeout: 10), "Typing must enable Send")
        attachScreenshot("\(page)-oppi-bar-expanded")
        assertRunning()
    }

    /// A guided control-session sheet: Cancel (`finish()` at the root of the
    /// router's navigation controller), then swipe-down, then it opens again.
    private func assertGuidedSheet(opener: () -> Void, title: String) {
        let sheet = app.navigationBars[title]
        opener()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "\(title) did not open in a navigation bar")
        attachScreenshot(title)
        assertRunning()
        tapBarButton(cancelButton)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Cancel must close \(title)")
        opener()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "\(title) did not reopen")
        dragToBottom(sheet)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Swipe-down must close \(title)")
        opener()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "\(title) did not reopen after the swipe")
        tapBarButton(cancelButton)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        assertRunning()
    }

    /// A reviewable Markdown sheet: its dismiss control, then swipe-down.
    private func assertReviewSheet(opener: () -> Void) {
        let dismiss = app.buttons["fullScreen.code.close"]
        opener()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "The review sheet did not open")
        // The leave control keeps one id in every mode; a sheet's reads Done, a pushed viewer's reads Back.
        XCTAssertEqual(dismiss.label, "Done", "The review must open as a sheet, not a pushed viewer")
        attachScreenshot("review-sheet")
        assertRunning()
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 10), "Its dismiss control must close the review sheet")
        opener()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "The review sheet did not reopen")
        dragToBottom(dismiss)
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 10), "Swipe-down must close the review sheet")
        opener()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "The review sheet did not reopen after the swipe")
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 10))
        assertRunning()
    }

    /// Bar items in a router sheet report no hit point ({-1, -1}) to XCTest,
    /// so tap the center of their frame.
    private func tapBarButton(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) is missing")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func launch(page: String, writeDelay: Int = 0) {
        launchSettingsSweep(page: page, showsWrites: true, writeDelay: writeDelay)
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

    /// Waits default to 10 s in `waitFor`: a loaded pool simulator can take
    /// several seconds to finish a sheet's dismissal animation.

    /// `Button(role: .cancel)` draws the system cancel control. Bar items can
    /// sit outside the navigation bar element: the iPhone Duo moves them to a
    /// vertical rail.
    /// The front-most one: presented controllers come last in the tree. Add
    /// Server onboarding's own Cancel stays under its sheets, so it is left out.
    private var cancelButton: XCUIElement {
        let matches = app.buttons.matching(NSPredicate(
            format: "label IN %@ AND identifier != %@",
            ["Cancel", "Close"],
            "onboarding.cancel"
        ))
        return matches.element(boundBy: max(matches.count - 1, 0))
    }
}
