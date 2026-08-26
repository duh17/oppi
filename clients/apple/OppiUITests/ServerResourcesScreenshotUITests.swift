import XCTest

/// Deterministic visual proof for server-scoped Skills and Extensions.
@MainActor
final class ServerResourcesScreenshotUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Screenshot preview tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testServerResourcesNormalDynamicTypePreviews() throws {
        launchPreview(screen: "server-resources-skills")
        XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 5))
        assertServerScope()
        XCTAssertTrue(app.descendants(matching: .any)["serverResources.skills.release"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["serverResources.skills.error"].label.contains("Error"))
        saveScreenshot(name: "server-resources-skills-normal")

        app.terminate()
        launchPreview(screen: "server-resources-extensions")
        XCTAssertTrue(app.navigationBars["Extensions"].waitForExistence(timeout: 5))
        assertServerScope()
        XCTAssertTrue(app.descendants(matching: .any)["serverResources.extensions.error"].label.contains("Error"))
        saveScreenshot(name: "server-resources-extensions-normal")
    }

    func testServerResourcesOfflineAndPendingPreviews() throws {
        launchPreview(screen: "server-resources-cached-offline")
        XCTAssertTrue(app.navigationBars["Extensions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["serverResources.cachedWarning"].waitForExistence(timeout: 5))
        saveScreenshot(name: "server-resources-cached-offline")
    }

    private func assertServerScope() {
        let scope = app.descendants(matching: .any)["serverResources.serverScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertEqual(scope.label, "Current server: Preview Server")
        XCTAssertEqual(scope.value as? String, "Connected")
    }

    private func launchPreview(screen: String) {
        app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        app.launch()

        let ready = app.descendants(matching: .any)["screenshot.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 8), "Screenshot preview did not become ready")
    }

    private func saveScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
