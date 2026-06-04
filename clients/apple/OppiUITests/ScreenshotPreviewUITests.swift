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
        let tasksHeader = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Tasks")).firstMatch
        XCTAssertTrue(tasksHeader.waitForExistence(timeout: 5), "Extension widget task header not visible")

        saveScreenshot(name: "extension-widget")
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

        let filesTab = app.buttons["Files (3)"]
        if filesTab.waitForExistence(timeout: 2) {
            filesTab.tap()
            XCTAssertTrue(app.staticTexts["SessionOutlineView.swift"].waitForExistence(timeout: 3), "Files tab content not visible")
            saveScreenshot(name: "session-outline-files")
        }
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
        XCTAssertFalse(
            app.staticTexts["Drafted a migration plan and test checklist."].exists,
            "Assistant node should be filtered out in Users tree filter"
        )

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
