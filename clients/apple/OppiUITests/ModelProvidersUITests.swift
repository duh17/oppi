import XCTest

/// Model Providers and its API key sheet on the real UIKit controllers over the
/// settings sweep fixture server (`SCREENSHOT_SCREEN=settings-sweep`): the
/// connected and available groups, the usage footer, and a key typed into a
/// sheet that opens from its row.
@MainActor
final class ModelProvidersUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Settings sweep previews are simulator-only")
#endif
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// The page loads both groups from its server, says when the usage was read,
    /// and opens the key sheet from the provider that still needs one.
    func testProvidersLoadTheirGroupsAndOpenTheKeySheet() {
        launch(page: "model-providers")
        XCTAssertTrue(
            app.collectionViews["server.modelProviders.list"].waitForExistence(timeout: 10),
            "The providers list did not appear"
        )
        let connected = app.staticTexts["Connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 10), "The connected group is missing")
        XCTAssertTrue(app.staticTexts["Available"].exists, "The available group is missing")
        XCTAssertTrue(
            app.buttons["server.modelProviders.anthropic.manage"].exists,
            "The connected provider has no manage menu"
        )
        // The connected group's footer is the usage time, from the same load.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Usage as of")).firstMatch.exists,
            "The connected group does not say when its usage was read"
        )
        attachScreenshot("model-providers")
        assertRunning()

        let setKey = app.buttons["server.modelProviders.openai.connect"]
        XCTAssertTrue(setKey.waitForExistence(timeout: 5), "The unconnected provider has no connect button")
        setKey.tap()
        let sheet = app.navigationBars["Set API Key"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The key sheet did not open from its row")
        // A key is a secure field, so XCUITest reports it as a secure text field.
        let field = app.secureTextFields["server.modelProviders.apiKey.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The key sheet has no field")
        attachScreenshot("model-providers-api-key")

        let save = app.buttons["server.modelProviders.apiKey.save"]
        XCTAssertTrue(waitFor(save.exists && !save.isEnabled), "Save waits for a key")
        field.tap()
        field.typeText("sk-live-not-a-real-key")
        XCTAssertTrue(waitFor(save.isEnabled), "Save takes the key typed")
        assertRunning()

        // A bar item in a router sheet reports no hit point to XCTest, so tap
        // the center of its frame.
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "The key sheet has no Cancel")
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitFor(!sheet.exists), "Cancel must close the key sheet")
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5), "The list must still be there")
        assertRunning()
    }

    // MARK: Helpers

    private func launch(page: String) {
        app?.terminate()
        app = OppiTestLaunch.makeApp()
        app.launchArguments += ["--screenshot-preview"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "settings-sweep"
        app.launchEnvironment["SCREENSHOT_SWEEP_PAGE"] = page
        app.launchEnvironment["SCREENSHOT_SWEEP_SHOWS_WRITES"] = "1"
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = "dark"
        app.launch()
        XCTAssertTrue(
            app.staticTexts["settingsSweep.lastWrite"].waitForExistence(timeout: 10),
            "Settings sweep harness did not appear"
        )
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "The app must still be running", file: file, line: line)
    }
}
