import XCTest

/// Fixture proof for the app-behavior feature-education tip catalogue.
///
/// This launches the app's DEBUG screenshot-preview surface from the E2E target
/// so the simulator recording can verify every candidate tip card is present
/// and scroll through the full catalogue for visual review.
@MainActor
final class FeatureEducationTipsPreviewE2ETests: XCTestCase {
    private var app: XCUIApplication!

    private struct P0TipCase {
        let id: String
        let expectedMessage: String
    }

    private static let p0TipCases = [
        P0TipCase(id: "tool-details", expectedMessage: "Tap a tool row to inspect"),
        P0TipCase(id: "output-shortcuts", expectedMessage: "Double-tap or pinch expanded output"),
        P0TipCase(id: "changed-files", expectedMessage: "Tap the changed-files bar"),
        P0TipCase(id: "prompt", expectedMessage: "Pick an option or type a response"),
        P0TipCase(id: "busy-send", expectedMessage: "Use Steer for this turn"),
        P0TipCase(id: "review-selection", expectedMessage: "Select text, then tap Comment"),
    ]

    private static let tipIDs = [
        "open-tool-details",
        "tool-output-shortcuts",
        "open-changed-files-bar",
        "answer-inline-asks-and-extension-prompts",
        "steer-vs-follow-up-while-busy",
        "select-text-for-review-comments",
        "context-bar-multi-select-and-drag-select",
        "message-queue-review-and-editing",
        "session-outline-tree",
        "fork-from-a-point-in-history",
        "context-usage-inspector",
        "cross-session-attention",
        "file-repo-references",
        "slash-command-autocomplete",
        "expanded-full-screen-composer",
        "workspace-row-previews",
        "ipad-split-workspace-shell",
        "quick-session-from-app-controls",
        "workspace-picker-in-quick-session",
        "file-browser-fuzzy-search",
        "share-and-export-rendered-output",
        "local-pi-session-import",
        "stop-active-session-swipe-action",
    ]

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Feature education tip preview is simulator-only")
#endif
        continueAfterFailure = false
    }

    func testFeatureEducationTipsCatalogVideo() throws {
        launchPreview(screen: "feature-tips")

        XCTAssertEqual(Self.tipIDs.count, 23, "The fixture should cover every app-behavior tip candidate")
        XCTAssertTrue(app.staticTexts["Feature education tips"].waitForExistence(timeout: 5), "Feature tip catalogue title missing")
        XCTAssertTrue(app.staticTexts["feature-tips.total"].waitForExistence(timeout: 5), "Feature tip count missing")
        XCTAssertEqual(app.staticTexts["feature-tips.total"].label, "23 tips covered")

        let catalog = app.scrollViews["feature-tips.catalog"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 5), "Feature tip catalogue scroll view missing")

        for tipID in Self.tipIDs {
            let tipTitle = app.staticTexts["feature-tip.\(tipID)"]
            XCTAssertTrue(
                scrollUntilVisible(tipTitle, in: catalog),
                "Missing feature education tip card: \(tipID)"
            )
            // Deliberately small pause so the simulator video can be reviewed by humans.
            RunLoop.current.run(until: Date().addingTimeInterval(0.18))
        }

        saveScreenshot(name: "feature-education-tips-catalog-e2e")
    }

    func testP0FeatureEducationTipsAreWiredIntoHiddenGestureSurfaces() throws {
        for tipCase in Self.p0TipCases {
            launchPreview(screen: "feature-tip-p0", p0Case: tipCase.id, forceTips: true)

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
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--screenshot-preview"]
        if forceTips {
            app.launchArguments.append("--reset-feature-tips")
            app.launchArguments.append("--show-feature-tips-for-testing")
        }
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        if let p0Case {
            app.launchEnvironment["FEATURE_TIP_PREVIEW_CASE"] = p0Case
        }
        app.launch()

        let ready = app.descendants(matching: .any)["screenshot.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 8), "Feature tip preview did not become ready")
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

    private func scrollUntilVisible(_ element: XCUIElement, in scrollView: XCUIElement) -> Bool {
        if element.waitForExistence(timeout: 0.5), element.isHittable {
            return true
        }

        for _ in 0..<12 {
            scrollView.swipeUp()
            if element.waitForExistence(timeout: 0.5), element.isHittable {
                return true
            }
        }

        return element.exists
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
