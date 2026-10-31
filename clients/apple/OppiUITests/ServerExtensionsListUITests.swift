import XCTest

/// The Extensions list on the real screen over the settings sweep fixture
/// server (`SCREENSHOT_SCREEN=settings-sweep`): its sections, search, and the
/// states a server's catalog can be in. Opening a row goes through
/// `AppNavigation`, which only the shell mounts; the paired-server E2E drives
/// that.
@MainActor
final class ServerExtensionsListUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Screenshot preview tests are simulator-only")
#endif
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testCatalogSectionsAndRowsAreButtons() {
        launchSettingsSweep(page: "extensions")
        XCTAssertTrue(app.navigationBars["Extensions"].waitForExistence(timeout: 10))

        let server = app.descendants(matching: .any)["serverCatalog.server.passive"]
        XCTAssertTrue(server.waitForExistence(timeout: 5), "A single paired server is a passive row")
        XCTAssertEqual(server.label, "Current server: mac-studio")

        for header in ["Built-in", "Needs Attention", "Enabled Pi Extensions", "Disabled Pi Extensions"] {
            XCTAssertTrue(app.staticTexts[header].exists, "\(header) section is missing")
        }
        let workflow = app.buttons["extensions.row.workflow"]
        XCTAssertTrue(workflow.exists, "An extension row is one button")
        XCTAssertEqual(workflow.label, "workflow, ~/.pi/agent/extensions, Enabled")
        XCTAssertEqual(app.buttons["extensions.row.review-helper"].label, "review-helper, Pi user settings, Error")
        XCTAssertEqual(app.buttons["extensions.row.simplify"].label, "simplify, ~/.pi/agent/extensions, Disabled")
        XCTAssertFalse(app.descendants(matching: .any)["extensions.cachedWarning"].exists)
        attachScreenshot("extensions-list")
    }

    func testSearchFiltersAndShowsNoResults() {
        launchSettingsSweep(page: "extensions")
        let search = app.searchFields["Search extensions"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "The search bar did not render")
        search.tap()
        search.typeText("workflow")
        XCTAssertTrue(app.buttons["extensions.row.workflow"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["extensions.row.simplify"].waitForNonExistence(timeout: 5),
            "Search must filter rows"
        )
        XCTAssertFalse(app.buttons["extensions.row.oppi-ask"].exists)

        search.clearAndTypeText("no-matching-extension")
        XCTAssertTrue(app.staticTexts["extensions.state"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts["extensions.state"].label, "No extensions match “no-matching-extension”.",
            "The empty state names the query"
        )
        attachScreenshot("extensions-no-results")

        search.clearAndTypeText("")
        XCTAssertTrue(app.buttons["extensions.row.simplify"].waitForExistence(timeout: 5), "Clearing search brings the rows back")
    }

    func testCachedCatalogShowsOfflineWarningOverRows() {
        launchSettingsSweep(page: "extensions-offline")
        let warning = app.descendants(matching: .any)["extensions.cachedWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "A failed sync over a cached catalog warns")
        XCTAssertTrue(warning.label.contains("Showing cached settings for mac-studio"))
        XCTAssertTrue(app.buttons["extensions.row.workflow"].exists, "The cached rows stay")
        attachScreenshot("extensions-cached-offline")
    }

    func testUnavailableCatalogShowsRetry() {
        launchSettingsSweep(page: "extensions-unavailable")
        let retry = app.buttons["extensions.state"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20), "A failed first load offers Retry")
        XCTAssertTrue(retry.label.localizedCaseInsensitiveContains("Couldn't Load Extensions"), "The row says what failed: \(retry.label)")
        XCTAssertFalse(app.buttons["extensions.row.workflow"].exists)
        attachScreenshot("extensions-unavailable")
    }

    func testCatalogWithoutPiExtensionsSaysSo() {
        launchSettingsSweep(page: "extensions-builtin-only")
        XCTAssertTrue(app.staticTexts["extensions.noPi"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["extensions.row.oppi-ask"].exists, "Built-in extensions still list")
        attachScreenshot("extensions-no-pi")
    }
}

private extension XCUIElement {
    func clearAndTypeText(_ text: String) {
        guard let current = value as? String, !current.isEmpty else {
            if !text.isEmpty { typeText(text) }
            return
        }
        tap()
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
