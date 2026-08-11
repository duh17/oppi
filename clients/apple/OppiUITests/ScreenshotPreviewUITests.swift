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
        XCTAssertTrue(
            app.staticTexts["Append System Prompt"].waitForExistence(timeout: 3),
            "Agent detail must use Pi system-prompt terminology"
        )
        XCTAssertTrue(
            app.staticTexts["Pi Session Defaults"].exists,
            "Agent detail must identify Pi session defaults explicitly"
        )
        XCTAssertTrue(app.staticTexts["Thinking Level"].exists)
        saveScreenshot(name: "agent-detail-system-prompt")

        let excludedTools = app.staticTexts["Excluded Tools"]
        for _ in 0..<3 where !excludedTools.exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Allowed Tools"].exists)
        XCTAssertTrue(excludedTools.exists)
        let toolAvailability = app.descendants(matching: .any)["agent.proof.tools.noTools"]
        XCTAssertTrue(toolAvailability.exists)
        XCTAssertTrue(toolAvailability.label.contains("No built-in tools"))
        saveScreenshot(name: "agent-detail-tool-defaults")

        for _ in 0..<3 where !detailIcon.isHittable {
            app.swipeDown()
        }
        detailIcon.tap()

        let pickerList = app.collectionViews["agent.iconPicker.list"]
        let suggestion = app.buttons["agent.iconPicker.symbol.sparkles"]
        for _ in 0..<3 where !suggestion.exists {
            pickerList.swipeUp()
        }
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "Sparkles suggestion not visible")
        suggestion.tap()

        XCTAssertFalse(
            app.descendants(matching: .any)["agent.iconPicker.current"].exists
                || app.descendants(matching: .any)["agent.iconPicker.draft"].exists,
            "The picker must not expose Current/Draft preview chrome"
        )
        saveScreenshot(name: "agent-icons-sf-symbol-draft")
        app.buttons["agent.iconPicker.save"].tap()

        XCTAssertTrue(detailIcon.waitForExistence(timeout: 5), "Agent detail did not return after saving")
        XCTAssertEqual(detailIcon.value as? String, "Sparkles")

        let backToAgents = app.navigationBars.buttons["Agents"]
        XCTAssertTrue(backToAgents.waitForExistence(timeout: 3), "Agents back button not visible")
        backToAgents.tap()
        XCTAssertTrue(agentRow.waitForExistence(timeout: 3), "Agent list did not return")
        XCTAssertEqual(agentRow.value as? String, "Sparkles")
        saveScreenshot(name: "agent-icons-sf-symbol-agent-list")

        agentRow.tap()
        XCTAssertTrue(detailIcon.waitForExistence(timeout: 3), "Agent detail did not reopen")
        detailIcon.tap()
        let chooseEmoji = app.buttons["agent.iconPicker.emojiGenmoji"]
        XCTAssertTrue(chooseEmoji.waitForExistence(timeout: 5), "Choose Emoji or Genmoji control not visible")
        XCTAssertFalse(
            app.textViews["agent.iconPicker.emojiInput"].exists,
            "The adaptive glyph input must not expose a visible empty text field"
        )
        chooseEmoji.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Choose Emoji or Genmoji did not focus the native input")
        XCTAssertFalse(app.buttons["iconPicker.dismissKeyboard"].exists, "Picker must not add a keyboard accessory control")
        app.typeText("🧘")
        XCTAssertTrue(
            (chooseEmoji.value as? String)?.contains("Emoji 🧘") == true,
            "The same control must report the selected Unicode emoji"
        )
        XCTAssertTrue(waitForKeyboardToDismiss(), "Valid emoji selection must dismiss the keyboard")
        XCTAssertFalse(
            app.descendants(matching: .any)["agent.iconPicker.customSelection"].exists,
            "The picker must not show a separate custom-selection check row"
        )
        saveScreenshot(name: "agent-icons-emoji-draft")
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
        for _ in 0..<3 where !launch.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(launch.waitForExistence(timeout: 5), "Agent launch proof action not visible")
        launch.tap()

        let agentSession = app.descendants(matching: .any)["agent.proof.session.agent"]
        let ordinarySession = app.descendants(matching: .any)["agent.proof.session.ordinary"]
        XCTAssertTrue(agentSession.waitForExistence(timeout: 5), "Agent session row not visible")
        XCTAssertTrue(ordinarySession.waitForExistence(timeout: 5), "Ordinary session row not visible")
        XCTAssertTrue(
            agentSession.label.contains("Saved Agent"),
            "Agent session row did not expose its saved-Agent identity"
        )
        XCTAssertTrue(
            ordinarySession.label.contains("Classic π"),
            "Ordinary session row must expose the selected assistant avatar identity"
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

    func testAgentIconTitleBarStressPreviewKeepsAllIconsInsideTwentyFourPointSlot() throws {
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "agent-icon-title-bar-stress")

        let navigationBar = app.navigationBars.firstMatch
        let nextIconButton = app.buttons["agent.proof.titlebar.next"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), "Navigation bar not visible")
        XCTAssertTrue(nextIconButton.waitForExistence(timeout: 5), "Title-bar stress control not visible")

        let title = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "A deliberately long focused chat session title")
        ).firstMatch
        let cost = app.staticTexts["$12.34"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Long title not visible in the principal item")
        XCTAssertTrue(cost.waitForExistence(timeout: 5), "Cost not visible in the principal item")

        let cases = ["emoji", "compact", "tall", "wide"]
        for (index, caseID) in cases.enumerated() {
            let icon = app.descendants(matching: .any)["agent.proof.titlebar.\(caseID).icon"]
            XCTAssertTrue(icon.waitForExistence(timeout: 5), "Missing \(caseID) title-bar icon")
            switch caseID {
            case "emoji":
                XCTAssertEqual(icon.frame.width, 24, accuracy: 1, "Emoji must retain the fixed title slot")
                XCTAssertEqual(icon.frame.height, 24, accuracy: 1, "Emoji must retain the fixed title slot")
            case "compact":
                XCTAssertGreaterThanOrEqual(icon.frame.width, 18, "Compact symbol became too narrow")
                XCTAssertGreaterThanOrEqual(icon.frame.height, 18, "Compact symbol became too short")
                XCTAssertLessThanOrEqual(icon.frame.width, 22.5, "Compact symbol exceeded its visual envelope")
                XCTAssertLessThanOrEqual(icon.frame.height, 22.5, "Compact symbol exceeded its visual envelope")
            case "tall":
                XCTAssertGreaterThanOrEqual(icon.frame.height, 18, "Tall symbol became too short")
                XCTAssertLessThanOrEqual(icon.frame.width, 22.5, "Tall symbol exceeded its visual envelope")
                XCTAssertLessThanOrEqual(icon.frame.height, 22.5, "Tall symbol exceeded its visual envelope")
            case "wide":
                XCTAssertGreaterThanOrEqual(icon.frame.width, 18, "Wide symbol became too narrow")
                XCTAssertLessThanOrEqual(icon.frame.width, 22.5, "Wide symbol exceeded its visual envelope")
                XCTAssertLessThanOrEqual(icon.frame.height, 22.5, "Wide symbol exceeded its visual envelope")
            default:
                XCTFail("Unexpected title-bar stress case: \(caseID)")
            }
            XCTAssertTrue(
                navigationBar.frame.contains(icon.frame),
                "\(caseID) icon must stay inside the actual navigation-bar principal placement"
            )
            XCTAssertFalse(title.frame.isEmpty, "Long title disappeared for \(caseID)")
            XCTAssertFalse(cost.frame.isEmpty, "Cost disappeared for \(caseID)")
            XCTAssertTrue(
                navigationBar.frame.contains(title.frame),
                "Long title escaped the navigation bar for \(caseID)"
            )
            XCTAssertTrue(
                navigationBar.frame.contains(cost.frame),
                "Cost escaped the navigation bar for \(caseID)"
            )

            saveScreenshot(name: "agent-icon-title-bar-stress-\(caseID)")
            if index < cases.count - 1 {
                nextIconButton.tap()
            }
        }
    }

    func testAssistantAvatarCancelAndInvalidEmojiKeepSavedAvatar() throws {
        launchPreview(screen: "assistant-avatar-picker")

        let savedAvatar = app.descendants(matching: .any)["assistant.avatarProof.saved"]
        XCTAssertTrue(savedAvatar.waitForExistence(timeout: 5), "Saved assistant avatar proof was not visible")
        XCTAssertTrue(savedAvatar.label.contains("Classic π"))

        app.buttons["assistant.avatarProof.open"].tap()
        let pickerList = app.collectionViews["assistant.avatarPicker.list"]
        XCTAssertTrue(pickerList.waitForExistence(timeout: 5), "Assistant picker list did not appear")
        pickerList.swipeUp()
        pickerList.swipeUp()
        let chooseEmoji = app.buttons["assistant.avatarPicker.emojiGenmoji"]
        XCTAssertTrue(chooseEmoji.waitForExistence(timeout: 5), "Assistant emoji control did not appear")
        chooseEmoji.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Assistant emoji control did not focus the native input")
        app.typeText("not an emoji")

        let validation = app.staticTexts["assistant.avatarPicker.validationError"]
        XCTAssertTrue(validation.waitForExistence(timeout: 3), "Invalid emoji must show input validation")
        let save = app.buttons["assistant.avatarPicker.save"]
        XCTAssertFalse(save.isEnabled, "Save must stay disabled for invalid custom emoji")
        let cancel = app.buttons["assistant.avatarPicker.cancel"]
        XCTAssertTrue(cancel.isHittable, "Assistant picker Cancel must remain reachable")
        cancel.tap()
        XCTAssertTrue(savedAvatar.waitForExistence(timeout: 3), "Cancel did not dismiss assistant picker")
        XCTAssertTrue(savedAvatar.label.contains("Classic π"), "Cancel must preserve the saved assistant avatar")
        saveScreenshot(name: "assistant-avatar-invalid-cancel")
    }

    func testAgentIconSaveFailureShowsRetryAndPreservesDraft() throws {
        launchPreview(screen: "agent-icons-save-failure")

        let agentRow = app.descendants(matching: .any)["agent.proof.agentRow"]
        XCTAssertTrue(agentRow.waitForExistence(timeout: 5))
        agentRow.tap()
        let detailIcon = app.buttons["agent.proof.detail.icon"]
        XCTAssertTrue(detailIcon.waitForExistence(timeout: 5))
        detailIcon.tap()

        let pickerList = app.collectionViews["agent.iconPicker.list"]
        let sparkle = app.buttons["agent.iconPicker.symbol.sparkles"]
        for _ in 0..<4 where !sparkle.isHittable {
            pickerList.swipeUp()
        }
        XCTAssertTrue(sparkle.isHittable, "Agent symbol choice was not reachable")
        sparkle.tap()
        app.buttons["agent.iconPicker.save"].tap()

        let saveError = app.descendants(matching: .any)["agent.iconPicker.saveError"].firstMatch
        XCTAssertTrue(saveError.waitForExistence(timeout: 5), "Agent save failure did not render immediately")
        XCTAssertTrue(saveError.isHittable, "Save failure must remain visible without scrolling")
        XCTAssertTrue(saveError.label.contains("Preview server is unavailable"))
        XCTAssertTrue(app.buttons["agent.iconPicker.retry"].isHittable, "Retry action must remain visible without scrolling")
        app.buttons["agent.iconPicker.retry"].tap()

        XCTAssertTrue(detailIcon.waitForExistence(timeout: 5), "Retry did not return to agent detail")
        XCTAssertEqual(detailIcon.value as? String, "Sparkles", "Retry lost the selected Agent icon")
        saveScreenshot(name: "agent-icon-save-failure-retry")
    }

    func testIconPickerStandardSelectionAffordances() throws {
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "agent-icons")

        let agentRow = app.descendants(matching: .any)["agent.proof.agentRow"]
        XCTAssertTrue(agentRow.waitForExistence(timeout: 5))
        agentRow.tap()
        let detailIcon = app.buttons["agent.proof.detail.icon"]
        XCTAssertTrue(detailIcon.waitForExistence(timeout: 5))
        detailIcon.tap()

        let pickerList = app.collectionViews["agent.iconPicker.list"]
        let chooseEmoji = app.buttons["agent.iconPicker.emojiGenmoji"]
        XCTAssertTrue(chooseEmoji.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(chooseEmoji.frame.height, 43.5)
        XCTAssertFalse(app.descendants(matching: .any)["agent.iconPicker.current"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["agent.iconPicker.draft"].exists)
        XCTAssertFalse(app.buttons["agent.iconPicker.option.default"].exists)
        XCTAssertFalse(app.staticTexts["Current and Draft"].exists)
        XCTAssertFalse(app.staticTexts["Default"].exists)
        XCTAssertFalse(app.staticTexts["Search Symbols"].exists)
        XCTAssertFalse(app.staticTexts["Emoji or Genmoji"].exists, "Chooser label makes a separate section header redundant")

        chooseEmoji.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Choose Emoji or Genmoji did not open the software keyboard")
        XCTAssertFalse(app.buttons["iconPicker.dismissKeyboard"].exists, "Picker must not add a keyboard accessory control")
        app.typeText("🧘")
        let emojiFeedback = chooseEmoji.value as? String
        XCTAssertTrue(
            emojiFeedback?.contains("Emoji 🧘") == true,
            "Unicode emoji did not update the chooser feedback: \(emojiFeedback ?? "nil")"
        )
        XCTAssertFalse(app.descendants(matching: .any)["agent.iconPicker.customSelection"].exists)
        XCTAssertTrue(waitForKeyboardToDismiss(), "Valid emoji selection must dismiss the keyboard")

        let symbolSection = app.staticTexts["Agent Symbols"]
        let search = app.textFields["Search SF Symbols"]
        for _ in 0..<3 where !search.isHittable {
            pickerList.swipeUp()
        }
        XCTAssertTrue(symbolSection.exists, "Agent Symbols section header was not visible")
        XCTAssertTrue(search.isHittable, "Symbol search was not reachable inside Agent Symbols")
        XCTAssertGreaterThanOrEqual(search.frame.height, 43.5)
        XCTAssertLessThan(symbolSection.frame.minY, search.frame.minY, "Search must live inside the symbol section")
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Symbol search did not open the software keyboard")
        search.typeText("cart")
        XCTAssertEqual(search.value as? String, "cart", "Symbol search must retain typed text before filtering")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Search must keep the software keyboard active while typing")
        let keyboardReturn = app.keyboards.buttons["Return"]
        XCTAssertTrue(keyboardReturn.waitForExistence(timeout: 3))
        keyboardReturn.tap()
        let cart = app.buttons["agent.iconPicker.symbol.cart"]
        for _ in 0..<3 where !cart.exists || !cart.isHittable {
            pickerList.swipeUp()
        }
        XCTAssertTrue(cart.waitForExistence(timeout: 3), "Search did not expose bottom catalog content")
        XCTAssertTrue(cart.isHittable, "Filtered bottom content was not reachable after keyboard dismissal")
        XCTAssertGreaterThanOrEqual(cart.frame.height, 43.5)
        XCTAssertTrue(app.buttons["agent.iconPicker.cancel"].isHittable)
        XCTAssertTrue(app.buttons["agent.iconPicker.save"].isHittable)
        saveScreenshot(name: "agent-icon-picker-standard-selection")
    }

    func testIconPickerInitialStateUsesLargePresentationInCompactHeight() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "agent-icons")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let application = object as? XCUIApplication else { return false }
                return application.frame.width > application.frame.height
            },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [landscape], timeout: 5),
            .completed,
            "Simulator did not settle into normalized landscape orientation"
        )

        let agentRow = app.descendants(matching: .any)["agent.proof.agentRow"]
        XCTAssertTrue(agentRow.waitForExistence(timeout: 5))
        agentRow.tap()
        let detailIcon = app.buttons["agent.proof.detail.icon"]
        XCTAssertTrue(detailIcon.waitForExistence(timeout: 5))
        detailIcon.tap()

        let pickerList = app.collectionViews["agent.iconPicker.list"]
        XCTAssertTrue(pickerList.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(
            pickerList.frame.height,
            app.frame.height * 0.65,
            "Compact-height picker must use the large presentation"
        )

        let chooseEmoji = app.buttons["agent.iconPicker.emojiGenmoji"]
        let symbolSection = app.staticTexts["Agent Symbols"]
        XCTAssertTrue(chooseEmoji.waitForExistence(timeout: 3), "Emoji or Genmoji control must be exposed initially in compact height")
        XCTAssertTrue(symbolSection.waitForExistence(timeout: 3), "Agent Symbols must follow the emoji control")
        XCTAssertFalse(app.descendants(matching: .any)["agent.iconPicker.current"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["agent.iconPicker.draft"].exists)
        XCTAssertFalse(app.buttons["agent.iconPicker.option.default"].exists)
        XCTAssertFalse(app.staticTexts["Emoji or Genmoji"].exists)
        XCTAssertLessThan(chooseEmoji.frame.minY, symbolSection.frame.minY)
        saveScreenshot(name: "agent-icon-picker-compact-height-simplified")
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

    func testWhatsNewBuild45LightScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "whats-new-build45-light", reduceMotion: true)
        assertWhatsNewBuild45Content()
        saveScreenshot(name: "whats-new-build45-light")
    }

    func testWhatsNewBuild45DarkScreenshot() throws {
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "whats-new-build45-dark", reduceMotion: true)
        assertWhatsNewBuild45Content()
        saveScreenshot(name: "whats-new-build45-dark")
    }

    func testModelProvidersQuotaInlinePreview() throws {
        launchPreview(screen: "model-providers-quota-inline")

        XCTAssertTrue(app.navigationBars["Model Providers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OpenAI Codex"].waitForExistence(timeout: 5))
        let codexPlan = app.descendants(matching: .any)["provider.quota.openai-codex.plan"]
        XCTAssertTrue(codexPlan.waitForExistence(timeout: 5), "Codex plan label not visible")
        XCTAssertFalse(app.staticTexts["Provider Quotas"].exists)

        let fiveHourQuota = app.descendants(matching: .any)["provider.quota.openai-codex.five_hour"]
        XCTAssertTrue(fiveHourQuota.waitForExistence(timeout: 5), "Codex quota row not visible")
        XCTAssertTrue(
            (fiveHourQuota.value as? String)?.contains("72% left") == true,
            "Quota accessibility value must expose remaining percentage"
        )
        XCTAssertTrue(
            (fiveHourQuota.value as? String)?.contains("resets") == true,
            "Quota accessibility value must expose reset time"
        )

        let weeklyQuota = app.descendants(matching: .any)["provider.quota.openai-codex.weekly"]
        XCTAssertTrue(weeklyQuota.waitForExistence(timeout: 5), "Weekly quota row not visible")
        XCTAssertTrue(app.staticTexts["Anthropic"].waitForExistence(timeout: 5))
        saveScreenshot(name: "model-providers-quota-inline")
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
        let closeDetails = app.buttons["ask.confirmation.closeDetails"]
        XCTAssertTrue(confirm.isHittable, "Confirm should stay pinned for long content")
        XCTAssertTrue(cancel.isHittable, "Cancel should stay pinned for long content")
        XCTAssertTrue(closeDetails.isHittable, "Close Details should stay pinned for long content")

        let promptTail = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "END OF COMPLETE PROMPT")
        ).firstMatch
        for _ in 0..<6 where !promptTail.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(promptTail.isHittable, "Long approval content should scroll to its final line")
        XCTAssertTrue(confirm.isHittable, "Confirm should remain pinned after scrolling")
        XCTAssertTrue(cancel.isHittable, "Cancel should remain pinned after scrolling")
        XCTAssertTrue(closeDetails.isHittable, "Close Details should remain pinned after scrolling")

        saveScreenshot(name: "ask-card-expanded-sheet")
    }

    func testOppiCommandApprovalRoutesInlineActionsImmediately() throws {
        launchPreview(screen: "oppi-command-approval-inline")

        XCTAssertTrue(app.staticTexts["Waiting"].waitForExistence(timeout: 3))
        tapInlineOption("Confirm")
        XCTAssertTrue(app.staticTexts["Confirmed"].waitForExistence(timeout: 3), "Inline Confirm should respond immediately")

        app.terminate()
        launchPreview(screen: "oppi-command-approval-inline")
        tapInlineOption("Cancel")
        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 3), "Inline Cancel should respond immediately")
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

    func testLatexRenderingPreview() throws {
        for colorScheme in ["dark", "light"] {
            launchPreview(
                screen: "latex-rendering",
                environment: ["SCREENSHOT_COLOR_SCHEME": colorScheme]
            )

            let content = app.descendants(matching: .any)["latex.preview.content"]
            XCTAssertTrue(
                content.waitForExistence(timeout: 5),
                "Production Markdown/LaTeX preview did not render in \(colorScheme) mode"
            )
            saveScreenshot(name: "latex-rendering-\(colorScheme)")
            app.terminate()
        }
    }

    func testWideLatexFormulaFullScreenHorizontalPanAndDismiss() throws {
        launchPreview(
            screen: "latex-rendering",
            environment: ["SCREENSHOT_COLOR_SCHEME": "dark"]
        )

        let formulas = app.buttons.matching(identifier: "latex.formula.open")
        XCTAssertGreaterThanOrEqual(formulas.count, 2, "Expected short and wide production formulas")
        let wideFormula = formulas.element(boundBy: formulas.count - 1)
        if !wideFormula.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(wideFormula.waitForExistence(timeout: 5), "Wide formula did not render")
        XCTAssertTrue(wideFormula.isHittable, "Wide formula could not be opened")
        wideFormula.tap()

        let latexScroll = app.scrollViews["fullscreen-latex.scroll"]
        let dismiss = app.buttons["fullscreen-code.dismiss"]
        XCTAssertTrue(latexScroll.waitForExistence(timeout: 5), "Full-screen formula scroll surface did not open")
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Full-screen formula dismiss control is missing")
        sleep(1) // Let the sheet presentation settle before capturing layout evidence.
        saveScreenshot(name: "latex-fullscreen-layout-leading")

        latexScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: latexScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        )
        saveScreenshot(name: "latex-fullscreen-horizontal-pan")

        // Return to the leading edge, then prove the modal navigation gesture
        // remains available after the formula consumed horizontal pans.
        latexScroll.swipeRight()
        latexScroll.swipeDown()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: dismiss
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [dismissed], timeout: 5),
            .completed,
            "Full-screen formula did not dismiss after horizontal panning"
        )
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

    private func waitForKeyboardToDismiss(timeout: TimeInterval = 3) -> Bool {
        let keyboard = app.keyboards.firstMatch
        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: keyboard
        )
        return XCTWaiter.wait(for: [disappeared], timeout: timeout) == .completed
    }

    private func tapInlineOption(_ label: String) {
        let option = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3), "Inline option \(label) not visible")
        option.tap()
    }

    private func launchPreview(
        screen: String,
        reduceMotion: Bool = false,
        environment: [String: String] = [:]
    ) {
        app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
        if reduceMotion {
            app.launchArguments.append(contentsOf: ["-UIAccessibilityReduceMotion", "YES"])
        }
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()

        // Wait for the preview to signal readiness.
        let ready = app.descendants(matching: .any)["screenshot.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 8), "Screenshot preview did not become ready")
    }

    private func assertWhatsNewBuild45Content() {
        // The launch arguments request reduced motion; this extra settle makes
        // the artifact safe even on simulators that ignore that preference.
        sleep(1)

        let title = app.staticTexts["whatsNew.title"]
        let caption = app.staticTexts["whatsNew.caption"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "What’s New title not visible")
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "Build caption not visible")
        XCTAssertEqual(title.label, "What’s New in Oppi")
        XCTAssertEqual(caption.label, "Build 45 · Changes since Build 43")

        let expectedFeatures = [
            (
                id: "agents-schedules",
                title: "Agents and schedules are easier to set up",
                description: "We cleaned up Agent creation and editing, and made schedules simpler to configure."
            ),
            (
                id: "chat-controls",
                title: "Chat controls are more reliable",
                description: "Context shows more Pi usage details, slash commands wait while the agent is busy, `/compact` works like a normal slash command, and extension prompts preserve your draft."
            ),
            (
                id: "workspace-wiki-links",
                title: "Open workspace files with wiki links",
                description: "Ask an agent to cite workspace files as `[[wiki links]]`, then tap a link to open the file in Oppi."
            ),
            (
                id: "model-providers",
                title: "Model providers are easier to manage",
                description: "Provider settings are easier to find, xAI shows quota and reset details, and extensions can supply custom model providers more reliably."
            ),
            (
                id: "server-connections",
                title: "More predictable server connections",
                description: "Choose Automatic, HTTPS Only, or Iroh Only for each server; Oppi now follows that choice more consistently."
            ),
        ]

        var rowFrames: [CGRect] = []
        for feature in expectedFeatures {
            let headline = app.staticTexts
                .containing(NSPredicate(format: "label == %@", feature.title))
                .firstMatch
            let description = app.staticTexts
                .containing(NSPredicate(format: "label == %@", feature.description))
                .firstMatch
            XCTAssertTrue(headline.waitForExistence(timeout: 5), "Missing What’s New headline: \(feature.title)")
            XCTAssertTrue(description.waitForExistence(timeout: 5), "Missing What’s New description: \(feature.title)")
            XCTAssertEqual(headline.label, feature.title)
            XCTAssertEqual(description.label, feature.description)
            XCTAssertTrue(headline.isHittable, "Headline is not visible: \(feature.title)")
            XCTAssertTrue(description.isHittable, "Description is not visible: \(feature.title)")
            rowFrames.append(headline.frame.union(description.frame))
        }

        for pair in zip(rowFrames, rowFrames.dropFirst()) {
            XCTAssertLessThan(pair.0.maxY, pair.1.minY, "What’s New rows overlap")
        }
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "turn your workspace into")).firstMatch.exists,
            "The wiki-link point must use factual workspace-file framing"
        )

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Done CTA not visible")
        XCTAssertTrue(done.isHittable, "Done CTA is not hittable")
        XCTAssertGreaterThanOrEqual(done.frame.height, 44, "Done CTA must preserve a 44-point touch target")
        XCTAssertLessThanOrEqual(rowFrames.last?.maxY ?? .greatestFiniteMagnitude, done.frame.minY, "Final What’s New row must remain above the CTA")
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
