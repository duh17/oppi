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
