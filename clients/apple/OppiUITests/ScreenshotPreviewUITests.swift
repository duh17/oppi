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

        // Wait for the form to populate — skills section should appear.
        let enabledHeader = app.staticTexts["Enabled Skills"]
        XCTAssertTrue(enabledHeader.waitForExistence(timeout: 5), "Enabled Skills header not found")

        saveScreenshot(name: "workspace-edit-enabled")

        // Scroll to show the boundary between enabled and disabled sections.
        let lastEnabled = app.staticTexts["sentry"]
        if lastEnabled.exists {
            app.swipeUp()
        }

        saveScreenshot(name: "workspace-edit-disabled")
    }

    func testSessionTimelinePreview() throws {
        launchPreview(screen: "session-timeline")

        let title = app.staticTexts["Session Timeline"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Session Timeline title not found")

        saveScreenshot(name: "session-timeline-list")

        let treeTab = app.buttons["Tree"]
        if treeTab.waitForExistence(timeout: 2) {
            treeTab.tap()
            XCTAssertTrue(app.staticTexts["Tree mode is live and searchable."].waitForExistence(timeout: 3), "Tree tab content not visible")
            saveScreenshot(name: "session-timeline-tree")

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
            saveScreenshot(name: "session-timeline-tree-summary-none")

            openTreeNavigateDialog()
            app.buttons["Summarize abandoned branch"].tap()
            XCTAssertTrue(waitForTreeNavigationCapture(contains: "mode=default"), "Default-summary navigation capture missing")
            saveScreenshot(name: "session-timeline-tree-summary-default")

            openTreeNavigateDialog()
            app.buttons["Summarize with custom instructions"].tap()

            let instructionsEditor = app.textViews["tree-summary-instructions"]
            XCTAssertTrue(instructionsEditor.waitForExistence(timeout: 3), "Custom summary instructions editor not shown")
            instructionsEditor.tap()
            instructionsEditor.typeText("Focus on TODOs")
            saveScreenshot(name: "session-timeline-tree-summary-custom-sheet")

            let navigateButton = app.buttons["Navigate"]
            XCTAssertTrue(navigateButton.waitForExistence(timeout: 2), "Custom summary navigate button not found")
            navigateButton.tap()

            XCTAssertTrue(waitForTreeNavigationCapture(contains: "mode=custom"), "Custom-summary navigation capture missing")
            XCTAssertTrue(waitForTreeNavigationCapture(contains: "instructions=Focus on TODOs"), "Custom summary instructions not captured")
            saveScreenshot(name: "session-timeline-tree-summary-custom")
        }

        let filesTab = app.buttons["Files (3)"]
        if filesTab.waitForExistence(timeout: 2) {
            filesTab.tap()
            XCTAssertTrue(app.staticTexts["SessionOutlineView.swift"].waitForExistence(timeout: 3), "Files tab content not visible")
            saveScreenshot(name: "session-timeline-files")
        }
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
        let searchField = app.searchFields["Search session tree…"].firstMatch
        let fallbackSearchField = app.searchFields["Search session tree..."].firstMatch
        let activeSearchField: XCUIElement

        if searchField.waitForExistence(timeout: 1) {
            activeSearchField = searchField
        } else if fallbackSearchField.waitForExistence(timeout: 1) {
            activeSearchField = fallbackSearchField
        } else {
            activeSearchField = app.searchFields.firstMatch
            XCTAssertTrue(activeSearchField.waitForExistence(timeout: 3), "Tree search field not visible")
        }

        activeSearchField.tap()
        activeSearchField.typeText("user")

        let rootNode = app.staticTexts["Plan rollout for timeline branch/fork UX on mobile."]
        let branchNode = app.staticTexts["Ship list mode first."]
        let siblingNode = app.staticTexts["Actually add a tree tab in Session Timeline."]

        XCTAssertTrue(rootNode.waitForExistence(timeout: 3), "Filtered root node not visible")
        XCTAssertTrue(branchNode.waitForExistence(timeout: 3), "Filtered branch node not visible")
        XCTAssertTrue(siblingNode.waitForExistence(timeout: 3), "Filtered sibling branch node not visible")
        XCTAssertFalse(
            app.staticTexts["Drafted a migration plan and test checklist."].exists,
            "Assistant node should be filtered out in user-only search"
        )

        let rootX = rootNode.frame.minX
        let branchX = branchNode.frame.minX
        let siblingX = siblingNode.frame.minX

        XCTAssertGreaterThan(
            branchX - rootX,
            12,
            "Filtered branch node should stay indented relative to visible ancestor"
        )
        XCTAssertLessThan(
            abs(branchX - siblingX),
            8,
            "Filtered sibling branches should share the same indent"
        )

        saveScreenshot(name: "session-timeline-tree-filtered-user")

        if activeSearchField.buttons["Clear text"].waitForExistence(timeout: 1) {
            activeSearchField.buttons["Clear text"].tap()
        }

        XCTAssertTrue(
            app.staticTexts["Drafted a migration plan and test checklist."].waitForExistence(timeout: 3),
            "Clearing tree search should restore assistant nodes"
        )
    }

    private func saveScreenshot(name: String) {
        let screenshot = app.screenshot()

        // Attach to test results (visible in Xcode).
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Also write to /tmp for agent review.
        let dir = "/tmp/oppi-screenshots"
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let path = "\(dir)/\(name).png"
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
    }
}
