import XCTest

/// Real paired-server proof for the server-global Skills route.
@MainActor
final class ServerResourcesE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool {
        true
    }

    override var e2eAutoCreatesSessionOnLaunch: Bool {
        false
    }

    func testIPhoneSkillsSearchShowsNoResults() throws {
        XCUIDevice.shared.orientation = .portrait

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
