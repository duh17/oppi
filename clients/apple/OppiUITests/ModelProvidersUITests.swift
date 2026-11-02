import XCTest

/// Model Providers and its API key sheet on the real UIKit controllers over the
/// settings sweep fixture server (`SCREENSHOT_SCREEN=settings-sweep`): the
/// connected and available groups, the usage footer, and a key typed into a
/// sheet that opens from its row.
@MainActor
final class ModelProvidersUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

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
        launchSettingsSweep(page: "model-providers", showsWrites: true)
        XCTAssertTrue(
            app.collectionViews["server.modelProviders.list"].waitUntilExists(timeout: 10),
            "The providers list did not appear"
        )
        let connected = app.staticTexts["Connected"]
        XCTAssertTrue(connected.waitUntilExists(timeout: 10), "The connected group is missing")
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
        XCTAssertTrue(setKey.waitUntilExists(timeout: 5), "The unconnected provider has no connect button")
        setKey.tap()
        let sheet = app.navigationBars["Set API Key"]
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "The key sheet did not open from its row")
        // A key is a secure field, so XCUITest reports it as a secure text field.
        let field = app.secureTextFields["server.modelProviders.apiKey.field"]
        XCTAssertTrue(field.waitUntilExists(timeout: 5), "The key sheet has no field")
        attachScreenshot("model-providers-api-key")

        let save = app.buttons["server.modelProviders.apiKey.save"]
        XCTAssertTrue(waitFor(save.exists && !save.isEnabled, timeout: 10), "Save waits for a key")
        field.tap()
        field.typeText("sk-live-not-a-real-key")
        XCTAssertTrue(waitFor(save.isEnabled, timeout: 10), "Save takes the key typed")
        assertRunning()

        // A bar item in a router sheet reports no hit point to XCTest, so tap
        // the center of its frame.
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitUntilExists(timeout: 5), "The key sheet has no Cancel")
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 10), "Cancel must close the key sheet")
        hold()
        XCTAssertTrue(app.staticTexts["Connected"].waitUntilExists(timeout: 5), "The list must still be there")
        assertRunning()
    }
}
