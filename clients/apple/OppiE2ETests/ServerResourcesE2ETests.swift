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
        XCTAssertTrue(app.staticTexts["skills.state"].waitForExistence(timeout: 5))
        try saveLabScreenshot(name: "iphone-server-resources-skills-no-results-e2e")
    }

    /// The shell mounts the Extensions list for the paired server and loads its
    /// catalog. The E2E server's catalog holds the Oppi built-in extensions and its
    /// configured `auto-name` package, which the list shows below them (so the
    /// "no Pi extensions" notice never appears here); a row opening its detail is
    /// proven in `ServerExtensionsViewControllerTests`.
    func testIPhoneExtensionsListLoadsServerCatalog() throws {
        openCompactSidebar()
        tap(app.buttons["workspace.extensions.open"], named: "Extensions sidebar destination")
        XCTAssertTrue(app.navigationBars["Extensions"].waitForExistence(timeout: 10))
        assertServerScope()
        let list = app.collectionViews["extensions.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 15), "The extensions list did not appear")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "extensions.row."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "The server's extension catalog did not load")
        XCTAssertTrue(app.searchFields["Search extensions"].exists)
        // The package row is the last one, below the built-ins: the catalog loaded in full. The
        // row's identifier is `extensions.row.<id>`, with the id the server's own catalog gives it.
        let catalog = try e2eLabAPIJSON(method: "GET", path: "/server/resources/extensions?plugins=true")
        let packageId = try XCTUnwrap(
            (catalog["extensions"] as? [[String: Any]])?.first { $0["name"] as? String == "auto-name" }?["id"] as? String,
            "The server's catalog does not list its configured auto-name package"
        )
        XCTAssertTrue(
            scrollToElement(app.buttons["extensions.row.\(packageId)"], in: list),
            "The server's configured package is missing from the extensions list"
        )
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
