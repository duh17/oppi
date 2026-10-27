import XCTest

/// Real paired-server proof for the server-global Skills and Extensions routes.
@MainActor
final class ServerResourcesE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool {
        true
    }

    override var e2eAutoCreatesSessionOnLaunch: Bool {
        false
    }

    func testIPhoneSkillsSearchShowsNoResults() throws {
        openCompactSidebar()
        tap(app.buttons["workspace.skills.open"], named: "Skills sidebar destination")
        XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 10))
        assertServerScope()

        let search = app.searchFields["Search skills"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Skills search field did not render")
        search.tap()
        search.typeText("no-matching-e2e-skill")
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 5))
        try saveLabScreenshot(name: "iphone-server-resources-skills-no-results-e2e")
    }

    /// The shell mounts the Extensions list for the paired server and loads its
    /// catalog. The E2E server has no Pi extensions, so the list says so; a row
    /// opening its detail is proven in `ServerExtensionsViewControllerTests`.
    func testIPhoneExtensionsListLoadsServerCatalog() throws {
        openCompactSidebar()
        tap(app.buttons["workspace.extensions.open"], named: "Extensions sidebar destination")
        XCTAssertTrue(app.navigationBars["Extensions"].waitForExistence(timeout: 10))
        assertServerScope()
        XCTAssertTrue(
            app.staticTexts["No Pi Extensions Found"].waitForExistence(timeout: 15),
            "The server's empty extension catalog did not load"
        )
        XCTAssertTrue(app.searchFields["Search extensions"].exists)
        try saveLabScreenshot(name: "iphone-server-resources-extensions-e2e")
    }

    private func openCompactSidebar() {
        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar button", timeout: 10)
        XCTAssertTrue(
            app.buttons["workspace.skills.open"].waitForExistence(timeout: 10),
            "Compact sidebar did not reveal Skills"
        )
    }

    private func assertServerScope() {
        let scope = app.descendants(matching: .any)["serverCatalog.server.passive"]
        XCTAssertTrue(scope.waitForExistence(timeout: 10), "Single-server catalog scope row did not render")
        XCTAssertTrue(scope.label.hasPrefix("Current server:"), "Catalog scope row did not name the active server")
        XCTAssertEqual(scope.value as? String, "Connected")
    }
}
