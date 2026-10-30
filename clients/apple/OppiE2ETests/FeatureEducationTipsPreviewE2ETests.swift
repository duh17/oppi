import XCTest

/// Fixture proof that the P0 feature-education tips appear on the hidden-gesture
/// surfaces they teach.
///
/// This launches the app's DEBUG screenshot-preview surface from the E2E target
/// with the tips forced on.
@MainActor
final class FeatureEducationTipsPreviewE2ETests: XCTestCase {
    private var app: XCUIApplication!

    private struct P0TipCase {
        let id: String
        let expectedMessage: String
        /// The preview that shows the tip's surface: the P0 gallery, or for a
        /// tip about the chat's own bar, the production chat.
        var screen = "feature-tip-p0"
    }

    private static let p0TipCases = [
        P0TipCase(id: "tool-details", expectedMessage: "Tap a tool row to inspect"),
        P0TipCase(id: "output-shortcuts", expectedMessage: "Double-tap or pinch expanded output"),
        P0TipCase(id: "prompt", expectedMessage: "Pick an option or type a response"),
        P0TipCase(id: "busy-send", expectedMessage: "Use Steer for this turn"),
        P0TipCase(id: "review-selection", expectedMessage: "Select text, then tap Comment"),
        P0TipCase(
            id: "top-bar-more",
            expectedMessage: "Files, Git, and more are in the",
            screen: "chat-top-bar-default"
        ),
    ]

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Feature education tip preview is simulator-only")
#endif
        continueAfterFailure = false
    }

    func testP0FeatureEducationTipsAreWiredIntoHiddenGestureSurfaces() throws {
        for tipCase in Self.p0TipCases {
            launchPreview(screen: tipCase.screen, p0Case: tipCase.id, forceTips: true)

            XCTAssertTrue(
                waitForTip(case: tipCase, timeout: 8),
                "TipKit tip did not appear for P0 surface: \(tipCase.id)"
            )

            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            saveScreenshot(name: "feature-tip-p0-\(tipCase.id)-e2e")
            app.terminate()
        }
    }

    private func launchPreview(screen: String, p0Case: String? = nil, forceTips: Bool = false) {
        app = OppiTestLaunch.makeApp()
        app.launchArguments += ["--screenshot-preview"]
        if forceTips {
            app.launchArguments.append("--reset-feature-tips")
            app.launchArguments.append("--show-feature-tips-for-testing")
        }
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        if let p0Case {
            app.launchEnvironment["FEATURE_TIP_PREVIEW_CASE"] = p0Case
        }
        app.launch()

        // The production chat has no `screenshot.ready` marker; its bar is.
        let ready = screen == "chat-top-bar-default"
            ? app.buttons["chat.toolbar.context"]
            : app.descendants(matching: .any)["screenshot.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 15), "Feature tip preview did not become ready")
    }

    private func waitForTip(case tipCase: P0TipCase, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let message = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", tipCase.expectedMessage))
            .firstMatch

        while Date() < deadline {
            if message.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return message.exists
    }

    private func saveScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(
            to: directory.appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }
}
