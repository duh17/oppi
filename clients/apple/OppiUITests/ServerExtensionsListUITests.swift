import XCTest

/// The Extensions list on the real screen over the settings sweep fixture
/// server (`SCREENSHOT_SCREEN=settings-sweep`): its sections, search, and the
/// states a server's catalog can be in. Opening a row goes through
/// `AppNavigation`, which only the shell mounts; the paired-server E2E drives
/// that.
@MainActor
final class ServerExtensionsListUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Screenshot preview tests are simulator-only")
#endif
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testCatalogSectionsAndRowsAreButtons() {
        launch(page: "extensions")
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
        launch(page: "extensions")
        let search = app.searchFields["Search extensions"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "The search bar did not render")
        search.tap()
        search.typeText("workflow")
        XCTAssertTrue(app.buttons["extensions.row.workflow"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForDisappearance(of: app.buttons["extensions.row.simplify"]), "Search must filter rows")
        XCTAssertFalse(app.buttons["extensions.row.oppi-ask"].exists)

        search.clearAndTypeText("no-matching-extension")
        XCTAssertTrue(app.staticTexts["extensions.noResults"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts["extensions.noResults"].label, "No extensions match “no-matching-extension”.",
            "The empty state names the query"
        )
        attachScreenshot("extensions-no-results")

        search.clearAndTypeText("")
        XCTAssertTrue(app.buttons["extensions.row.simplify"].waitForExistence(timeout: 5), "Clearing search brings the rows back")
    }

    func testCachedCatalogShowsOfflineWarningOverRows() {
        launch(page: "extensions-offline")
        let warning = app.descendants(matching: .any)["extensions.cachedWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "A failed sync over a cached catalog warns")
        XCTAssertTrue(warning.label.contains("Showing cached settings for mac-studio"))
        XCTAssertTrue(app.buttons["extensions.row.workflow"].exists, "The cached rows stay")
        attachScreenshot("extensions-cached-offline")
    }

    func testUnavailableCatalogShowsRetry() {
        launch(page: "extensions-unavailable")
        XCTAssertTrue(app.buttons["extensions.retry"].waitForExistence(timeout: 20), "A failed first load offers Retry")
        XCTAssertFalse(app.buttons["extensions.row.workflow"].exists)
        attachScreenshot("extensions-unavailable")
    }

    func testCatalogWithoutPiExtensionsSaysSo() {
        launch(page: "extensions-builtin-only")
        XCTAssertTrue(app.staticTexts["extensions.noPi"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["extensions.row.oppi-ask"].exists, "Built-in extensions still list")
        attachScreenshot("extensions-no-pi")
    }

    private func launch(page: String) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += ["--screenshot-preview", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "settings-sweep"
        app.launchEnvironment["SCREENSHOT_SWEEP_PAGE"] = page
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = "dark"
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["screenshot.ready"].waitForExistence(timeout: 10),
            "Settings sweep harness did not appear"
        )
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
