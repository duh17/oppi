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

        let textWidgetToggle = app.buttons["Collapse autoresearch widget"]
        XCTAssertTrue(textWidgetToggle.waitForExistence(timeout: 5), "Text widget collapse toggle not visible")

        let nativeSurfaceToggle = app.buttons["Collapse 1 of 5 tasks completed surface"]
        XCTAssertTrue(nativeSurfaceToggle.waitForExistence(timeout: 5), "Native surface collapse toggle not visible")

        let longMetricLine = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "streaming_max_us")).firstMatch
        XCTAssertTrue(longMetricLine.waitForExistence(timeout: 5), "Long terminal-compatible widget line not visible")
        saveScreenshot(name: "extension-widget-expanded-left")

        longMetricLine.swipeLeft()
        saveScreenshot(name: "extension-widget-expanded-right")

        textWidgetToggle.tap()
        let bodyMetricLine = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "zero_change_max_us")).firstMatch
        XCTAssertFalse(bodyMetricLine.waitForExistence(timeout: 1), "Collapsed text widget should hide body lines")
        saveScreenshot(name: "extension-widget-text-collapsed")

        let expandTextWidget = app.buttons["Expand autoresearch widget"]
        XCTAssertTrue(expandTextWidget.waitForExistence(timeout: 3), "Collapsed text widget expand toggle not visible")
        expandTextWidget.tap()

        nativeSurfaceToggle.tap()
        let runningTask = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Read HTTP Range semantics")).firstMatch
        XCTAssertFalse(runningTask.waitForExistence(timeout: 1), "Collapsed native surface should hide activity rows")
        saveScreenshot(name: "extension-widget-native-collapsed")

        let expandNativeSurface = app.buttons["Expand 1 of 5 tasks completed surface"]
        XCTAssertTrue(expandNativeSurface.waitForExistence(timeout: 3), "Collapsed native surface expand toggle not visible")
        expandNativeSurface.tap()
        XCTAssertTrue(runningTask.waitForExistence(timeout: 3), "Expanded native surface content should return")
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

        let combinedWidget = app.buttons["Collapse Pi review open widget"]
        XCTAssertTrue(combinedWidget.waitForExistence(timeout: 5), "Combined pi-review widget not visible")
        XCTAssertTrue(app.staticTexts["Pi review open"].waitForExistence(timeout: 5), "Promoted status title not visible")
        XCTAssertFalse(app.staticTexts["pi-review"].exists, "Generated key label should be suppressed when status already names the surface")
        saveScreenshot(name: "extension-dock-review-combined-expanded")

        combinedWidget.tap()
        let collapsedWidget = app.buttons["Expand Pi review open widget"]
        XCTAssertTrue(collapsedWidget.waitForExistence(timeout: 3), "Combined pi-review widget did not collapse")
        XCTAssertFalse(app.staticTexts["pi-review"].exists, "Collapsed card should still suppress the generated key label")
        saveScreenshot(name: "extension-dock-review-combined-collapsed")
    }

    func testExtensionDockScopedAgentsPreview() throws {
        launchPreview(screen: "extension-dock-scoped-agents")

        let scopedWidget = app.buttons["Collapse Subagents widget"]
        XCTAssertTrue(scopedWidget.waitForExistence(timeout: 5), "Scoped agents widget not visible")
        XCTAssertTrue(app.staticTexts["Subagents"].waitForExistence(timeout: 5), "Extension scope title not visible")
        XCTAssertTrue(app.staticTexts["1 running agent"].waitForExistence(timeout: 5), "Scoped status not attached")
        XCTAssertFalse(app.staticTexts["subagents"].exists, "Status key should not render as a separate row")
        XCTAssertFalse(app.staticTexts["agents"].exists, "Widget key should not replace the extension scope title")
        saveScreenshot(name: "extension-dock-scoped-agents")
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
        let expandedOption = app.staticTexts["Run this tool call now"]
        XCTAssertTrue(expandedOption.waitForExistence(timeout: 5), "Expanded permission gate not visible")

        saveScreenshot(name: "ask-card-expanded-sheet")
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

        clientsDirectory.tap()
        XCTAssertTrue(
            app.buttons["fileBrowser.inlineBack"].waitForExistence(timeout: 3),
            "Inline file browser directory should show a Back button"
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

    private func launchPreview(screen: String) {
        app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
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
