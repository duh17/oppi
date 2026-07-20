import XCTest

/// Screenshot capture tests for visual review.
///
/// Launches the app in screenshot-preview mode with mock data,
/// waits for the target screen to render, and saves a screenshot
/// to `/tmp/oppi-screenshots/`.
@MainActor
final class ScreenshotPreviewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Screenshot preview tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testAgentIconCriticalJourneyPreview() throws {
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "agent-icons")

        let agentRow = app.descendants(matching: .any)["agent.proof.agentRow"]
        XCTAssertTrue(agentRow.waitForExistence(timeout: 5), "Seeded Agent row not visible")
        agentRow.tap()

        let detailIcon = app.buttons["agent.proof.detail.icon"]
        XCTAssertTrue(detailIcon.waitForExistence(timeout: 5), "Agent detail icon control not visible")
        XCTAssertEqual(detailIcon.value as? String, "Default")
        detailIcon.tap()

        let pickerList = app.collectionViews["agent.iconPicker.list"]
        let suggestion = app.buttons["agent.iconPicker.suggestion.sparkles"]
        for _ in 0..<3 where !suggestion.exists {
            pickerList.swipeUp()
        }
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "Sparkles suggestion not visible")
        suggestion.tap()

        let preview = app.descendants(matching: .any)["agent.iconPicker.preview"]
        for _ in 0..<3 where !preview.exists {
            pickerList.swipeDown()
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 3), "Draft icon preview not visible")
        XCTAssertTrue(
            preview.label.localizedCaseInsensitiveContains("sparkles"),
            "Draft preview did not describe the selected SF Symbol"
        )
        saveScreenshot(name: "agent-icons-sf-symbol-preview")
        app.buttons["agent.iconPicker.save"].tap()

        XCTAssertTrue(detailIcon.waitForExistence(timeout: 5), "Agent detail did not return after saving")
        XCTAssertEqual(detailIcon.value as? String, "SF Symbol sparkles")

        let backToAgents = app.navigationBars.buttons["Agents"]
        XCTAssertTrue(backToAgents.waitForExistence(timeout: 3), "Agents back button not visible")
        backToAgents.tap()
        XCTAssertTrue(agentRow.waitForExistence(timeout: 3), "Agent list did not return")
        XCTAssertEqual(agentRow.value as? String, "SF Symbol sparkles")
        saveScreenshot(name: "agent-icons-sf-symbol-agent-list")

        agentRow.tap()
        XCTAssertTrue(detailIcon.waitForExistence(timeout: 3), "Agent detail did not reopen")
        detailIcon.tap()

        let useDefault = app.buttons["agent.iconPicker.default"]
        for _ in 0..<3 where !useDefault.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(useDefault.waitForExistence(timeout: 3), "Use Default Icon action not visible")
        useDefault.tap()

        XCTAssertTrue(detailIcon.waitForExistence(timeout: 5), "Agent detail did not return after clearing")
        XCTAssertEqual(detailIcon.value as? String, "Default")

        detailIcon.tap()
        let customIcon = app.textFields["agent.iconPicker.custom"]
        XCTAssertTrue(customIcon.waitForExistence(timeout: 5), "Custom icon field not visible")
        customIcon.tap()
        customIcon.typeText("🧘")

        XCTAssertTrue(preview.waitForExistence(timeout: 3), "Emoji draft preview not visible")
        XCTAssertTrue(preview.label.contains("Emoji 🧘"), "Draft preview did not show the selected emoji")
        saveScreenshot(name: "agent-icons-emoji-preview")
        app.buttons["agent.iconPicker.save"].tap()

        XCTAssertTrue(detailIcon.waitForExistence(timeout: 5), "Agent detail did not return after emoji save")
        XCTAssertEqual(detailIcon.value as? String, "Emoji 🧘")
        backToAgents.tap()
        XCTAssertTrue(agentRow.waitForExistence(timeout: 3), "Agent list did not return after emoji save")
        XCTAssertEqual(agentRow.value as? String, "Emoji 🧘")
        saveScreenshot(name: "agent-icons-emoji-agent-list")

        agentRow.tap()
        XCTAssertTrue(detailIcon.waitForExistence(timeout: 3), "Emoji Agent detail did not reopen")
        XCTAssertEqual(detailIcon.value as? String, "Emoji 🧘")

        let launch = app.buttons["agent.proof.launch"]
        XCTAssertTrue(launch.waitForExistence(timeout: 5), "Agent launch proof action not visible")
        launch.tap()

        let agentSession = app.descendants(matching: .any)["agent.proof.session.agent"]
        let ordinarySession = app.descendants(matching: .any)["agent.proof.session.ordinary"]
        XCTAssertTrue(agentSession.waitForExistence(timeout: 5), "Agent session row not visible")
        XCTAssertTrue(ordinarySession.waitForExistence(timeout: 5), "Ordinary session row not visible")
        XCTAssertTrue(
            (agentSession.value as? String)?.contains("Launched with a saved Agent") == true,
            "Agent session row did not expose its saved-Agent identity"
        )
        XCTAssertFalse(
            (ordinarySession.value as? String)?.contains("Launched with a saved Agent") == true,
            "Ordinary session must retain global assistant identity"
        )
        saveScreenshot(name: "agent-icons-emoji-session-identities")

        agentSession.tap()
        let titleIdentity = app.descendants(matching: .any)["agent.proof.chat.titleIdentity"]
        let agentIdentity = app.descendants(matching: .any)["agent.proof.chat.agentIdentity"]
        let ordinaryIdentity = app.descendants(matching: .any)["agent.proof.chat.ordinaryIdentity"]
        XCTAssertTrue(titleIdentity.waitForExistence(timeout: 5), "Agent icon chat title not visible")
        XCTAssertTrue(agentIdentity.waitForExistence(timeout: 5), "Agent chat empty-state identity not visible")
        XCTAssertTrue(ordinaryIdentity.waitForExistence(timeout: 5), "Ordinary avatar comparison not visible")
        XCTAssertTrue(titleIdentity.label.contains("Emoji 🧘"), "Chat title did not expose the emoji identity")
        XCTAssertTrue(agentIdentity.label.contains("Emoji 🧘"), "Chat empty state did not expose the emoji identity")
        XCTAssertEqual(ordinaryIdentity.label, "Ordinary session uses the global assistant avatar")
        saveScreenshot(name: "agent-icons-emoji-chat-identities")
    }

    func testWorkspaceSidebarGitStatusPreview() throws {
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "workspace-sidebar-git-status")

        let longWorkspace = app.staticTexts["Oppi Mobile Client and Self-Hosted Server"]
        XCTAssertTrue(longWorkspace.waitForExistence(timeout: 5), "Long workspace name not visible")
        XCTAssertTrue(app.staticTexts["14 changes"].waitForExistence(timeout: 5), "Dirty file count not visible")
        XCTAssertTrue(app.staticTexts["3"].waitForExistence(timeout: 5), "Unpushed commit count not visible")
        XCTAssertTrue(app.staticTexts["Native client and server runtime"].waitForExistence(timeout: 5), "Dirty workspace description should remain visible")
        XCTAssertTrue(app.staticTexts["Blog and long-form writing"].waitForExistence(timeout: 5), "Clean workspace description should remain visible")

        saveScreenshot(name: "workspace-sidebar-git-status")
    }

    func testWorkspaceEditSkillGrouping() throws {
        launchPreview(screen: "workspace-edit")

        let extensionsHeader = app.staticTexts["Pi Extensions"]
        XCTAssertTrue(extensionsHeader.waitForExistence(timeout: 5), "Pi Extensions header not found")
        saveScreenshot(name: "workspace-edit-extensions")

        let enabledHeader = app.staticTexts["Enabled Skills"]
        var foundEnabledHeader = enabledHeader.exists
        for _ in 0..<2 where !foundEnabledHeader {
            app.swipeUp()
            foundEnabledHeader = enabledHeader.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(foundEnabledHeader, "Enabled Skills header not found")

        sleep(1)
        saveScreenshot(name: "workspace-edit-skills")
    }

    func testExtensionWidgetPreview() throws {
        launchPreview(screen: "extension-widget")

        let title = app.staticTexts["Extension surface"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Extension surface title not found")

        let textWidgetPill = app.buttons["Expand autoresearch widget"]
        XCTAssertTrue(textWidgetPill.waitForExistence(timeout: 5), "Collapsed text widget pill not visible")

        let nativeSurfacePill = app.buttons["Expand 1 of 5 tasks completed surface"]
        XCTAssertTrue(nativeSurfacePill.waitForExistence(timeout: 5), "Collapsed native surface pill not visible")

        let longMetricLine = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "streaming_max_us")).firstMatch
        XCTAssertFalse(longMetricLine.waitForExistence(timeout: 1), "Collapsed strip should hide terminal widget body lines")
        saveScreenshot(name: "extension-widget-collapsed-strip")

        textWidgetPill.tap()
        XCTAssertTrue(app.buttons["Collapse autoresearch widget"].waitForExistence(timeout: 3), "Text widget did not expand into the shared drawer")
        XCTAssertTrue(longMetricLine.waitForExistence(timeout: 3), "Long terminal-compatible widget line not visible after expansion")
        saveScreenshot(name: "extension-widget-expanded-left")

        longMetricLine.swipeLeft()
        saveScreenshot(name: "extension-widget-expanded-right")

        longMetricLine.doubleTap()
        let dismissFullScreen = app.buttons["fullscreen-code.dismiss"]
        XCTAssertTrue(dismissFullScreen.waitForExistence(timeout: 5), "Terminal full-screen viewer did not open")
        saveScreenshot(name: "extension-widget-terminal-fullscreen")
        dismissFullScreen.tap()

        nativeSurfacePill.tap()
        let runningTask = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Read HTTP Range semantics")).firstMatch
        XCTAssertTrue(runningTask.waitForExistence(timeout: 3), "Native surface content should open in the shared drawer")
        XCTAssertFalse(longMetricLine.exists, "Expanding another pill should replace the drawer instead of stacking widget cards")
        saveScreenshot(name: "extension-widget-native-expanded")

        let nativeViewport = app.descendants(matching: .any)["extension-native-surface-widget-tasks-viewport"]
        XCTAssertTrue(nativeViewport.waitForExistence(timeout: 3), "Native drawer viewport not visible")
        nativeViewport.doubleTap()
        let nativeDone = app.buttons["Done"]
        XCTAssertTrue(nativeDone.waitForExistence(timeout: 5), "Native surface full-screen detail did not open")
        saveScreenshot(name: "extension-widget-native-fullscreen")
        nativeDone.tap()
    }

    func testChatInputAttachmentContainmentPreview() throws {
        launchPreview(screen: "chat-input-attachment-containment")

        let attachment = app.descendants(matching: .any)["chat.attachment.image.preview-image"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 5), "Pending attachment thumbnail not visible")

        let input = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "Chat input not visible")

        XCTAssertLessThan(
            attachment.frame.minY,
            input.frame.minY,
            "Attachment strip should sit above the text row inside the composer"
        )
        XCTAssertLessThanOrEqual(
            attachment.frame.maxY,
            input.frame.minY + 2,
            "Attachment strip should reserve layout height above the text row instead of overlapping it"
        )

        saveScreenshot(name: "chat-input-attachment-contained")
    }

    func testQuickSessionDictationComposerStreamsWithoutLayoutJumps() throws {
        launchPreview(screen: "quick-session-dictation-composer")

        let input = app.descendants(matching: .any)["dictation.preview.input"]
        let composer = app.descendants(matching: .any)["dictation.preview.composer"]
        let step = app.staticTexts["dictation.preview.step"]
        let caretProbe = app.staticTexts["dictation.preview.caretProbe"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "Dictation input not visible")
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Dictation composer not visible")
        XCTAssertTrue(step.waitForExistence(timeout: 5), "Dictation progress probe not visible")
        XCTAssertTrue(caretProbe.waitForExistence(timeout: 5), "Dictation caret probe not visible")

        let finalStep = NSPredicate(format: "label == %@", "step 4")
        let finalStepExpectation = XCTNSPredicateExpectation(predicate: finalStep, object: step)
        XCTAssertEqual(
            XCTWaiter.wait(for: [finalStepExpectation], timeout: 5),
            .completed,
            "Simulated dictation did not finish streaming"
        )

        let allCaretSteps = NSPredicate(format: "label == %@", "4/4 caret steps passed")
        let caretExpectation = XCTNSPredicateExpectation(predicate: allCaretSteps, object: caretProbe)
        XCTAssertEqual(
            XCTWaiter.wait(for: [caretExpectation], timeout: 3),
            .completed,
            "Every streamed update must report a terminal caret both immediately and after deferred correction"
        )

        XCTAssertTrue(
            (input.value as? String)?.contains("it actually busts our") == true,
            "Final streamed transcript did not reach the text view"
        )
        XCTAssertGreaterThan(
            input.frame.height,
            55,
            "The final streamed transcript did not occupy multiple rows"
        )
        XCTAssertTrue(composer.frame.contains(input.frame), "Text input escaped the composer surface")
        XCTAssertLessThan(
            composer.frame.height - input.frame.height,
            110,
            "Composer wrapper left an oversized blank region around multiline input"
        )
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Suppressed dictation input should not show the keyboard")

        saveScreenshot(name: "quick-session-dictation-composer-streamed")
    }

    func testLongAskPillsStayPutAndScroll() throws {
        launchPreview(screen: "ask-card-long-composer")

        let keyboardFirstRunContinue = app.buttons["Continue"]
        if keyboardFirstRunContinue.waitForExistence(timeout: 2) {
            keyboardFirstRunContinue.tap()
        }

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Keyboard did not appear for the long ask response")

        let modelPill = app.staticTexts["gpt-5.5"]
        let thinkingPill = app.staticTexts["max"]

        XCTAssertTrue(modelPill.waitForExistence(timeout: 5), "Model pill not visible")
        XCTAssertTrue(thinkingPill.waitForExistence(timeout: 5), "Thinking pill not visible")

        for pill in [modelPill, thinkingPill] {
            XCTAssertGreaterThan(pill.frame.height, 0, "Composer pill must have a visible frame")
            XCTAssertLessThanOrEqual(
                pill.frame.maxY,
                keyboard.frame.minY - 4,
                "Composer pill must remain visibly separated from the keyboard"
            )
            XCTAssertGreaterThanOrEqual(pill.frame.minX, app.frame.minX, "Composer pill must remain inside the leading screen edge")
            XCTAssertLessThanOrEqual(pill.frame.maxX, app.frame.maxX, "Composer pill must remain inside the trailing screen edge")
        }
        XCTAssertEqual(
            modelPill.frame.midY,
            thinkingPill.frame.midY,
            accuracy: 2,
            "Composer pills must remain aligned in the same action row"
        )
        XCTAssertLessThan(
            modelPill.frame.maxX,
            thinkingPill.frame.minX,
            "Composer pills must remain separately visible instead of overlapping"
        )

        sleep(1)
        saveScreenshot(name: "ask-card-long-composer-contained")

        let visibleOption = app.staticTexts["Keep a launch-only helper"]
        let hiddenOption = app.staticTexts["Delete CLI and visible runtimes"]
        XCTAssertTrue(visibleOption.isHittable, "A visible ask option is required to drive the scroll gesture")
        XCTAssertFalse(hiddenOption.isHittable, "The final option should begin below the capped ask viewport")

        let modelFrameBeforeScroll = modelPill.frame
        let thinkingFrameBeforeScroll = thinkingPill.frame
        let question = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "session launcher still supports")).firstMatch
        XCTAssertTrue(question.isHittable, "The ask question is required to locate the scroll viewport")

        let scrollStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(
            CGVector(dx: visibleOption.frame.midX, dy: visibleOption.frame.midY)
        )
        let scrollEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(
            CGVector(dx: visibleOption.frame.midX, dy: question.frame.minY + 20)
        )
        for _ in 0..<2 where !hiddenOption.isHittable {
            scrollStart.press(forDuration: 0.05, thenDragTo: scrollEnd)
        }

        XCTAssertTrue(hiddenOption.waitForExistence(timeout: 3), "The final ask option did not enter the visible viewport")
        XCTAssertTrue(hiddenOption.isHittable, "The long ask card must scroll to its final option")
        XCTAssertTrue(keyboard.exists, "Scrolling the ask card must not dismiss the keyboard")
        XCTAssertEqual(modelPill.frame, modelFrameBeforeScroll, "Scrolling the ask must not move the model pill")
        XCTAssertEqual(thinkingPill.frame, thinkingFrameBeforeScroll, "Scrolling the ask must not move the thinking pill")

        sleep(1)
        saveScreenshot(name: "ask-card-long-composer-scrolled")
    }

    func testExtensionDockStressPreview() throws {
        launchPreview(screen: "extension-dock-stress")

        let keyboardFirstRunContinue = app.buttons["Continue"]
        if keyboardFirstRunContinue.waitForExistence(timeout: 2) {
            keyboardFirstRunContinue.tap()
        }

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Keyboard did not appear for stress preview")

        saveScreenshot(name: "extension-dock-stress-keyboard")

        app.terminate()
        launchPreview(screen: "extension-dock-goal-detail")
        let detailTitle = app.staticTexts["extensionDockStress.goalDetail.title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5), "Goal detail preview did not open")
        saveScreenshot(name: "extension-dock-stress-goal-detail")
    }

    func testExtensionDockReviewCombinedPreview() throws {
        launchPreview(screen: "extension-dock-review-combined")

        let combinedWidget = app.buttons["Expand Pi review open widget"]
        XCTAssertTrue(combinedWidget.waitForExistence(timeout: 5), "Collapsed pi-review widget pill not visible")
        XCTAssertTrue(app.staticTexts["Pi review open"].waitForExistence(timeout: 5), "Promoted status title not visible")
        XCTAssertFalse(app.staticTexts["pi-review"].exists, "Generated key label should be suppressed when status already names the surface")
        saveScreenshot(name: "extension-dock-review-combined-collapsed")

        combinedWidget.tap()
        XCTAssertTrue(app.buttons["Collapse Pi review open widget"].waitForExistence(timeout: 3), "Combined pi-review widget did not expand")
        XCTAssertTrue(
            app.staticTexts["Pi review — vs origin/main — use the native window"].waitForExistence(timeout: 3),
            "Combined pi-review drawer content not visible"
        )
        XCTAssertFalse(app.staticTexts["pi-review"].exists, "Expanded drawer should still suppress the generated key label")
        saveScreenshot(name: "extension-dock-review-combined-expanded")
    }

    func testExtensionDockScopedAgentsPreview() throws {
        launchPreview(screen: "extension-dock-scoped-agents")

        let scopedWidget = app.buttons["Expand Subagents widget"]
        XCTAssertTrue(scopedWidget.waitForExistence(timeout: 5), "Scoped agents widget pill not visible")
        XCTAssertTrue(app.staticTexts["Subagents"].waitForExistence(timeout: 5), "Extension scope title not visible")
        XCTAssertTrue(app.staticTexts["1 running agent"].waitForExistence(timeout: 5), "Scoped status not attached")
        XCTAssertFalse(app.staticTexts["subagents"].exists, "Status key should not render as a separate row")
        XCTAssertFalse(app.staticTexts["agents"].exists, "Widget key should not replace the extension scope title")
        saveScreenshot(name: "extension-dock-scoped-agents-collapsed")

        scopedWidget.tap()
        XCTAssertTrue(app.buttons["Collapse Subagents widget"].waitForExistence(timeout: 3), "Scoped agents widget did not expand")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Deep telemetry correlation")).firstMatch.waitForExistence(timeout: 3), "Scoped agents drawer content not visible")
        saveScreenshot(name: "extension-dock-scoped-agents-expanded")
    }

    func testAskCardPreview() throws {
        launchPreview(screen: "ask-card")

        let question = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Git push")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5), "Permission gate title not visible")
        let commandLabel = app.staticTexts["Command"]
        XCTAssertTrue(commandLabel.waitForExistence(timeout: 5), "Command preview label not visible")
        let commandPreview = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "git push origin main")).firstMatch
        XCTAssertTrue(commandPreview.waitForExistence(timeout: 5), "Command preview text not visible")
        let firstOption = app.staticTexts["Allow once"]
        XCTAssertTrue(firstOption.waitForExistence(timeout: 5), "Allow option row not visible")
        let secondOption = app.staticTexts["Deny"]
        XCTAssertTrue(secondOption.waitForExistence(timeout: 5), "Deny option row not visible")

        saveScreenshot(name: "ask-card-inline")

        app.terminate()
        launchPreview(screen: "ask-card-expanded-sheet")
        let fullPrompt = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Review the complete implementation and tests")
        ).firstMatch
        XCTAssertTrue(fullPrompt.waitForExistence(timeout: 5), "Complete Oppi prompt not visible in expanded approval")
        let confirm = app.buttons["ask.confirmation.confirm"]
        let cancel = app.buttons["ask.confirmation.cancel"]
        let ignore = app.buttons["ask.confirmation.ignore"]
        XCTAssertTrue(confirm.isHittable, "Confirm should stay pinned for long content")
        XCTAssertTrue(cancel.isHittable, "Cancel should stay pinned for long content")
        XCTAssertTrue(ignore.isHittable, "Ignore should stay pinned for long content")

        let promptTail = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "END OF COMPLETE PROMPT")
        ).firstMatch
        for _ in 0..<6 where !promptTail.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(promptTail.isHittable, "Long approval content should scroll to its final line")
        XCTAssertTrue(confirm.isHittable, "Confirm should remain pinned after scrolling")
        XCTAssertTrue(cancel.isHittable, "Cancel should remain pinned after scrolling")
        XCTAssertTrue(ignore.isHittable, "Ignore should remain pinned after scrolling")

        saveScreenshot(name: "ask-card-expanded-sheet")
    }

    func testOppiCommandApprovalRequiresDetailsAndRoutesActions() throws {
        launchPreview(screen: "oppi-command-approval-inline")

        XCTAssertTrue(app.staticTexts["Waiting"].waitForExistence(timeout: 3))
        tapInlineOption("Confirm")
        XCTAssertTrue(app.buttons["ask.confirmation.confirm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Waiting"].exists, "Opening details must not approve")

        app.buttons["ask.confirmation.ignore"].tap()
        XCTAssertTrue(app.staticTexts["Waiting"].exists, "Ignore should close details without responding")

        app.terminate()
        launchPreview(screen: "oppi-command-approval-inline")
        tapInlineOption("Cancel")
        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 3), "Inline Cancel should respond immediately")

        app.terminate()
        launchPreview(screen: "oppi-command-approval-inline")
        tapInlineOption("Confirm")
        app.buttons["ask.confirmation.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Confirmed"].waitForExistence(timeout: 3))

        app.terminate()
        launchPreview(screen: "oppi-command-approval-inline")
        tapInlineOption("Confirm")
        app.buttons["ask.confirmation.cancel"].tap()
        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 3))
    }

    func testOppiCommandApprovalAccessibilitySizePreview() throws {
        launchPreview(
            screen: "ask-card-expanded-sheet",
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        )

        XCTAssertTrue(app.buttons["ask.confirmation.confirm"].isHittable)
        XCTAssertTrue(app.buttons["ask.confirmation.cancel"].isHittable)
        XCTAssertTrue(app.buttons["ask.confirmation.ignore"].isHittable)
        saveScreenshot(name: "oppi-command-approval-accessibility-size")
    }

    func testAskCardMultiSelectLongOptionsPreview() throws {
        launchPreview(screen: "ask-card-multiselect-long")

        let mode = app.staticTexts["Select multiple"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5), "Multi-select mode hint not visible")

        let longOption = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "alternate descent cached")).firstMatch
        XCTAssertTrue(longOption.waitForExistence(timeout: 5), "Full long option label not visible")
        let longDescription = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "airplane mode")).firstMatch
        XCTAssertTrue(longDescription.waitForExistence(timeout: 5), "Full long option description not visible")
        let shortOption = app.staticTexts["Weather window confirmed"]
        XCTAssertTrue(shortOption.waitForExistence(timeout: 5), "Short comparison option not visible")
        let shortDescription = app.staticTexts["Clear forecast."]
        XCTAssertTrue(shortDescription.waitForExistence(timeout: 5), "Short comparison description not visible")

        XCTAssertGreaterThan(
            longOption.frame.height,
            shortOption.frame.height + 8,
            "Long option label should render as multiple visible lines, not just expose a full accessibility label"
        )
        XCTAssertGreaterThan(
            longDescription.frame.height,
            shortDescription.frame.height + 6,
            "Long option description should render as multiple visible lines, not just expose a full accessibility label"
        )

        XCTAssertTrue(longOption.isHittable, "Long multi-select option label should be tappable")
        longOption.tap()

        let done = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Done (1 selected)")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 3), "Selecting a multi-select option should stay on the page and show Done")

        saveScreenshot(name: "ask-card-multiselect-long")
    }

    func testSessionTimelinePreview() throws {
        launchPreview(screen: "session-timeline")

        let title = app.staticTexts["Session Outline"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Session Outline title not found")

        saveScreenshot(name: "session-outline-timeline")

        let treeLayout = app.buttons["Tree"]
        if treeLayout.waitForExistence(timeout: 2) {
            treeLayout.tap()
            XCTAssertTrue(app.staticTexts["Tree mode is live and searchable."].waitForExistence(timeout: 3), "Tree layout content not visible")
            saveScreenshot(name: "session-outline-tree")

            let rootToggle = app.buttons["tree-toggle-entry-1"]
            if rootToggle.waitForExistence(timeout: 2) {
                rootToggle.tap()
                XCTAssertFalse(
                    app.staticTexts["Drafted a migration plan and test checklist."].exists,
                    "Tree collapse did not hide descendants"
                )

                rootToggle.tap()
                XCTAssertTrue(
                    app.staticTexts["Drafted a migration plan and test checklist."].waitForExistence(timeout: 2),
                    "Tree expand did not restore descendants"
                )
            }

            verifyFilteredTreeIndentation()

            openTreeNavigateDialog()
            app.buttons["Switch without summary"].tap()
            XCTAssertTrue(waitForTreeNavigationCapture(contains: "mode=none"), "No-summary navigation capture missing")
            saveScreenshot(name: "session-outline-tree-summary-none")
        }

        XCTAssertFalse(
            app.buttons["Files (3)"].exists,
            "Session Outline should not expose the old Files tab; use the chat file panel instead"
        )
    }

    func testChatFileBrowserPanelPreview() throws {
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "chat-file-panel")

        XCTAssertTrue(app.staticTexts["Files"].waitForExistence(timeout: 5), "Files panel header not visible")
        sleep(1)
        saveScreenshot(name: "chat-file-panel-portrait-changed")

        app.buttons["All"].tap()
        let clientsDirectory = app.staticTexts["clients"]
        XCTAssertTrue(clientsDirectory.waitForExistence(timeout: 5), "All-files browser did not open")
        sleep(1)
        saveScreenshot(name: "chat-file-panel-portrait-all")

        let trailingX = min(app.frame.maxX - 48, clientsDirectory.frame.maxX + 220)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: trailingX, dy: clientsDirectory.frame.midY))
            .tap()
        XCTAssertTrue(
            app.buttons["fileBrowser.inlineBack"].waitForExistence(timeout: 3),
            "Tapping the trailing side of a folder row should navigate into the directory"
        )
        sleep(1)
        saveScreenshot(name: "chat-file-panel-portrait-all-back")

        XCUIDevice.shared.orientation = .portrait
    }

    func testSessionFilesDirectoryGroupingPreview() throws {
        launchPreview(screen: "chat-file-panel")

        let changedTab = app.buttons["Changed"]
        XCTAssertTrue(changedTab.waitForExistence(timeout: 5), "Changed files tab not visible")
        changedTab.tap()

        let chatGroup = app.buttons["Collapse clients/apple/Oppi/Features/Chat files"]
        XCTAssertTrue(chatGroup.waitForExistence(timeout: 3), "Chat directory group not visible")
        XCTAssertTrue(app.staticTexts["ChatView.swift"].waitForExistence(timeout: 3), "Chat file row not visible before collapse")

        chatGroup.tap()
        XCTAssertFalse(app.staticTexts["ChatView.swift"].waitForExistence(timeout: 1), "Collapsed directory should hide its file rows")

        let expandChatGroup = app.buttons["Expand clients/apple/Oppi/Features/Chat files"]
        XCTAssertTrue(expandChatGroup.waitForExistence(timeout: 3), "Collapsed Chat directory expand control not visible")
        expandChatGroup.tap()
        XCTAssertTrue(app.staticTexts["ChatView.swift"].waitForExistence(timeout: 3), "Expanded directory should restore its file rows")

        saveScreenshot(name: "chat-file-panel-changed-grouped")
    }

    func testContextBarOverlapPreview() throws {
        launchPreview(screen: "context-bar-overlap")

        let title = app.staticTexts["Cross-session overlap"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Context bar overlap title not found")
        XCTAssertTrue(app.staticTexts["2 changed"].waitForExistence(timeout: 5), "Scoped changed count not visible")

        let hint = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "touched in another session")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 3), "Overlap hint not visible")
        let sharedFile = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "WorkspaceContextBar.swift")).firstMatch
        XCTAssertTrue(sharedFile.waitForExistence(timeout: 3), "Expanded file list not visible")
        saveScreenshot(name: "context-bar-overlap-expanded")
    }

    func testVoiceMessageExpandedPreview() throws {
        launchPreview(screen: "voice-message-expanded")

        let title = app.staticTexts["Expanded voice message"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Voice message preview title not found")

        saveScreenshot(name: "voice-message-expanded")
    }

    func testGlobalAudioPlaybackBannerPreview() throws {
        launchPreview(screen: "global-audio-banner")

        let title = app.staticTexts["Voice reply playing"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Global audio playback banner title not found")

        sleep(1)
        saveScreenshot(name: "global-audio-banner")
    }

    func testShareRedactionReportPreview() throws {
        launchPreview(screen: "share-redaction-report")

        let title = app.staticTexts["Redaction report"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Redaction report title not found")

        saveScreenshot(name: "share-redaction-report")
    }

    func testShareRedactionSettingsPreview() throws {
        launchPreview(screen: "share-redaction-settings")

        let title = app.navigationBars["Share Session"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Share session settings title not found")

        let summary = app.staticTexts["share-redaction-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Preflight redaction summary not shown")

        saveScreenshot(name: "share-redaction-settings")
    }

    func testSplitFileNavigationRegressionPreview() throws {
        launchPreview(screen: "split-file-navigation-regression")

        let openFlow = app.buttons["splitFileNavigation.open"]
        XCTAssertTrue(openFlow.waitForExistence(timeout: 5), "Split navigation regression trigger not visible")
        openFlow.tap()

        let linkedFile = app.staticTexts["splitFileNavigation.linkedFile"]
        XCTAssertTrue(linkedFile.waitForExistence(timeout: 5), "Linked file destination was not reconstructed")
        XCTAssertEqual(linkedFile.label, "Linked file: notes/second.md")

        saveScreenshot(name: "split-file-navigation-linked-file")

        let backToSession = app.buttons["splitFileNavigation.backToSession"]
        XCTAssertTrue(backToSession.waitForExistence(timeout: 3), "Back-to-session control not visible")
        backToSession.tap()

        let session = app.staticTexts["splitFileNavigation.session"]
        XCTAssertTrue(session.waitForExistence(timeout: 5), "Session back target was not preserved")
        XCTAssertEqual(session.label, "Session: session-1")

        saveScreenshot(name: "split-file-navigation-back-session")
    }

    // MARK: - Helpers

    private func tapInlineOption(_ label: String) {
        let option = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3), "Inline option \(label) not visible")
        option.tap()
    }

    private func launchPreview(screen: String, contentSizeCategory: String? = nil) {
        app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        app.launch()

        // Wait for the preview to signal readiness.
        let ready = app.descendants(matching: .any)["screenshot.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 8), "Screenshot preview did not become ready")
    }

    private func openTreeNavigateDialog() {
        let targetNode = app.staticTexts["Tree mode is live and searchable."]
        XCTAssertTrue(targetNode.waitForExistence(timeout: 3), "Tree node for navigation not visible")
        targetNode.tap()

        let switchWithoutSummary = app.buttons["Switch without summary"]
        XCTAssertTrue(switchWithoutSummary.waitForExistence(timeout: 3), "Tree navigate options dialog not shown")
    }

    private func waitForTreeNavigationCapture(contains fragment: String) -> Bool {
        let matchingText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
        return matchingText.waitForExistence(timeout: 3)
    }

    private func verifyFilteredTreeIndentation() {
        let usersFilter = app.buttons["Users"]
        XCTAssertTrue(usersFilter.waitForExistence(timeout: 2), "Users tree filter not visible")
        usersFilter.tap()

        let rootNode = app.staticTexts["Plan rollout for timeline branch/fork UX on mobile."]
        let branchNode = app.staticTexts["Ship list mode first."]
        let siblingNode = app.staticTexts["Actually add a tree tab in Session Timeline."]

        XCTAssertTrue(rootNode.waitForExistence(timeout: 3), "Filtered root node not visible")
        XCTAssertTrue(branchNode.waitForExistence(timeout: 3), "Filtered branch node not visible")
        XCTAssertTrue(siblingNode.waitForExistence(timeout: 3), "Filtered sibling branch node not visible")
        XCTAssertFalse(rootNode.frame.isEmpty, "Filtered root node frame missing")
        XCTAssertFalse(branchNode.frame.isEmpty, "Filtered branch node frame missing")
        XCTAssertFalse(siblingNode.frame.isEmpty, "Filtered sibling node frame missing")

        saveScreenshot(name: "session-outline-tree-filtered-user")

        let defaultFilter = app.buttons["Default"]
        XCTAssertTrue(defaultFilter.waitForExistence(timeout: 2), "Default tree filter not visible")
        defaultFilter.tap()

        XCTAssertTrue(
            app.staticTexts["Drafted a migration plan and test checklist."].waitForExistence(timeout: 3),
            "Resetting tree filter should restore assistant nodes"
        )
    }

    private func saveScreenshot(name: String) {
        let screenshot = app.screenshot()
        let variant = ProcessInfo.processInfo.environment["SCREENSHOT_VARIANT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = if let variant, !variant.isEmpty {
            "\(name)-\(variant)"
        } else {
            name
        }

        // Attach to test results (visible in Xcode).
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = resolvedName
        attachment.lifetime = .keepAlways
        add(attachment)

        // Also write to /tmp for agent review.
        let dir = "/tmp/oppi-screenshots"
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let path = "\(dir)/\(resolvedName).png"
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
    }
}
