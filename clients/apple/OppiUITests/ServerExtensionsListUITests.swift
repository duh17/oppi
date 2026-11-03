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
        XCTAssertTrue(app.navigationBars["Extensions"].waitUntilExists(timeout: 10))

        let server = app.descendants(matching: .any)["serverCatalog.server.passive"]
        XCTAssertTrue(server.waitUntilExists(timeout: 5), "A single paired server is a passive row")
        XCTAssertEqual(server.label, "Current server: mac-studio")

        for header in ["Built into Durable Sessions", "Needs Attention", "Enabled", "Disabled"] {
            XCTAssertTrue(app.staticTexts[header].exists, "\(header) section is missing")
        }
        // Built-in plugins keep their state; the one the runtime needs says it is always on.
        XCTAssertEqual(app.buttons["extensions.row.oppi-control"].label, "oppi-control, Oppi, Enabled, always on")
        XCTAssertEqual(app.buttons["extensions.row.oppi-sql-explorer"].label, "oppi-sql-explorer, Oppi, Disabled")
        let workflow = app.buttons["extensions.row.workflow"]
        XCTAssertTrue(workflow.exists, "An extension row is one button")
        XCTAssertEqual(workflow.label, "workflow, ~/.pi/agent/extensions, Enabled")
        XCTAssertEqual(app.buttons["extensions.row.review-helper"].label, "review-helper, Pi user settings, Error")
        XCTAssertFalse(app.descendants(matching: .any)["extensions.cachedWarning"].exists)
        attachScreenshot("extensions-list")
        // The Disabled section is last, below the fold.
        app.collectionViews["extensions.list"].swipeUp()
        let simplify = app.buttons["extensions.row.simplify"]
        XCTAssertTrue(simplify.waitUntilExists(timeout: 5))
        XCTAssertEqual(simplify.label, "simplify, ~/.pi/agent/extensions, Disabled")
    }

    func testSearchFiltersAndShowsNoResults() {
        launchSettingsSweep(page: "extensions")
        let search = app.searchFields["Search extensions"]
        XCTAssertTrue(search.waitUntilExists(timeout: 10), "The search bar did not render")
        search.tap()
        search.typeText("workflow")
        XCTAssertTrue(app.buttons["extensions.row.workflow"].waitUntilExists(timeout: 5))
        XCTAssertTrue(
            app.buttons["extensions.row.oppi-control"].waitUntilGone(timeout: 5),
            "Search must filter rows"
        )
        XCTAssertFalse(app.buttons["extensions.row.oppi-ask"].exists)

        search.clearAndTypeText("no-matching-extension")
        XCTAssertTrue(app.staticTexts["extensions.state"].waitUntilExists(timeout: 5))
        XCTAssertEqual(
            app.staticTexts["extensions.state"].label, "No extensions match “no-matching-extension”.",
            "The empty state names the query"
        )
        attachScreenshot("extensions-no-results")

        search.clearAndTypeText("")
        XCTAssertTrue(app.buttons["extensions.row.oppi-ask"].waitUntilExists(timeout: 5), "Clearing search brings the rows back")
    }

    func testCachedCatalogShowsOfflineWarningOverRows() {
        launchSettingsSweep(page: "extensions-offline")
        let warning = app.descendants(matching: .any)["extensions.cachedWarning"]
        XCTAssertTrue(warning.waitUntilExists(timeout: 10), "A failed sync over a cached catalog warns")
        XCTAssertTrue(warning.label.contains("Showing cached settings for mac-studio"))
        hold()
        XCTAssertTrue(app.buttons["extensions.row.workflow"].exists, "The cached rows stay")
        attachScreenshot("extensions-cached-offline")
    }

    func testUnavailableCatalogShowsRetry() {
        launchSettingsSweep(page: "extensions-unavailable")
        let retry = app.buttons["extensions.state"]
        XCTAssertTrue(retry.waitUntilExists(timeout: 20), "A failed first load offers Retry")
        XCTAssertTrue(retry.label.localizedCaseInsensitiveContains("Couldn't Load Extensions"), "The row says what failed: \(retry.label)")
        XCTAssertFalse(app.buttons["extensions.row.workflow"].exists)
        attachScreenshot("extensions-unavailable")
    }

    /// A built-in plugin the runtime needs: its server default is on and cannot be switched.
    func testRuntimeBuiltInDetailKeepsItsSwitchOn() {
        launchSettingsSweep(page: "extension-detail-builtin")
        let toggle = app.switches["server.extension.enabled"]
        XCTAssertTrue(toggle.waitUntilExists(timeout: 10), "The server default row did not render")
        XCTAssertEqual(toggle.value as? String, "1", "A runtime built-in is on")
        XCTAssertFalse(toggle.isEnabled, "A runtime built-in cannot be turned off")
        attachScreenshot("extension-detail-builtin")
    }

    /// A tool opens its page and its schema; a section with text opens the reader; a section
    /// written per conversation is a read-only row.
    func testDetailOpensAToolPageAndASectionReader() {
        launchSettingsSweep(page: "extension-detail-builtin")
        let list = app.collectionViews["server.extension.list"]
        let tool = app.buttons["server.extension.tool.plugin.oppi_control"]
        XCTAssertTrue(tool.waitUntilExists(timeout: 10), "A tool with a definition is a button")
        XCTAssertTrue(app.cells["server.extension.about.runsIn"].exists)
        attachScreenshot("extension-detail-redesign")

        tool.tap()
        let schema = app.buttons["server.extensionTool.schema"]
        XCTAssertTrue(schema.waitUntilExists(timeout: 5), "The tool page did not open")
        XCTAssertTrue(app.cells["server.extensionTool.parameter.action"].exists)
        attachScreenshot("extension-tool-page")
        schema.tap()
        let close = app.buttons["fullScreen.code.close"].firstMatch
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "The schema did not open in the reader")
        close.tap()
        XCTAssertTrue(schema.waitUntilExists(timeout: 5), "Back returns to the tool page")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()

        let section = app.buttons["server.extension.section.control-guidelines"]
        for _ in 0..<3 where !section.isHittable { list.swipeUp() }
        XCTAssertTrue(section.waitUntilExists(timeout: 5), "A section with text is a button")
        let perConversation = app.cells["server.extension.section.oppi-control"]
        XCTAssertTrue(perConversation.exists, "A per-conversation section is listed")
        XCTAssertFalse(app.buttons["server.extension.section.oppi-control"].exists, "and opens nothing")
        section.tap()
        XCTAssertTrue(app.buttons["fullScreen.code.close"].firstMatch.waitUntilExists(timeout: 5), "The section did not open in the reader")
        attachScreenshot("extension-section-reader")
    }

    func testCatalogWithoutPiExtensionsSaysSo() {
        launchSettingsSweep(page: "extensions-builtin-only")
        XCTAssertTrue(app.staticTexts["extensions.noPi"].waitUntilExists(timeout: 10))
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
