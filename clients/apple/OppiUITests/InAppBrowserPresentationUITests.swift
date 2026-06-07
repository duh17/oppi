import XCTest

@MainActor
final class InAppBrowserPresentationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI harness tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testInAppBrowserFillsRegularWidthIPad() throws {
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "-ApplePersistenceIgnoreState",
            "YES",
            "--e2e-open-in-app-browser=https://github.com/",
        ])
        app.launchEnvironment["OPPI_E2E_OPEN_IN_APP_BROWSER_URL"] = "https://github.com/"
        app.launch()

        let browserView = app.descendants(matching: .any)["inAppBrowser.view"]
        let githubNavigationBar = app.navigationBars["github.com"]
        XCTAssertTrue(
            browserView.waitForExistence(timeout: 15) || githubNavigationBar.waitForExistence(timeout: 3),
            "In-app browser did not open"
        )

        let measuredSurface = githubNavigationBar.exists ? githubNavigationBar : browserView
        XCTAssertGreaterThanOrEqual(
            measuredSurface.frame.width,
            app.frame.width * 0.88,
            "In-app browser should present full-screen on iPad. Surface width: \(measuredSurface.frame.width), app width: \(app.frame.width)"
        )

        saveScreenshot(name: "ipad-in-app-browser-fullscreen")
    }

    private func saveScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: outputURL, options: .atomic)
    }
}
