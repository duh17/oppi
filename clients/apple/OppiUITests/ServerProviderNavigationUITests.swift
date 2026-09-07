import XCTest

/// Behavior regression for the Server Settings Model Providers row.
///
/// Uses the isolated `server-provider-navigation-regression` preview, which
/// hosts the production row and `AppNavigation` owner. Not a screenshot dump.
@MainActor
final class ServerProviderNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Server provider navigation tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testTappingProvidersRowOpensSourceHostAndBackReturnsToServerSettings() {
        launchRegressionPreview()

        let row = app.buttons["server.modelProviders.open"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Model Providers row did not appear")
        XCTAssertTrue(row.isHittable)
        XCTAssertEqual(row.label, "Model Providers")
        XCTAssertEqual(row.value as? String, "Needs setup")
        XCTAssertLessThanOrEqual(
            row.frame.width,
            ServerProviderNavigationUITests.proofWidth + 8,
            "Row must keep title, status, and disclosure inside the 320pt fixture"
        )
        XCTAssertTrue(
            row.images["chevron.right"].exists,
            "Disclosure chevron must stay on the row at 320pt"
        )

        let connection = app.staticTexts["Connection"].firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Connection"].exists)
        connection.tap()
        XCTAssertTrue(
            app.navigationBars["Server"].waitForExistence(timeout: 2),
            "Status Connection must stay passive"
        )
        XCTAssertFalse(app.navigationBars["Model Providers"].exists)

        let blank = row.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.5))
        blank.tap()

        XCTAssertTrue(
            app.navigationBars["Model Providers"].waitForExistence(timeout: 5),
            "Blank-space tap on the row must open Model Providers"
        )
        let opened = app.descendants(matching: .any)["server.modelProviders.openedServerId"]
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "Opened server id did not appear")
        XCTAssertTrue(
            opened.label.contains("sha256:source-server")
                || (opened.value as? String)?.contains("sha256:source-server") == true,
            "Row must open the source settings host, not the other paired server"
        )
        XCTAssertFalse(
            opened.label.contains("sha256:other-server")
                || (opened.value as? String)?.contains("sha256:other-server") == true
        )

        let back = app.navigationBars["Model Providers"].buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 2))
        back.tap()

        XCTAssertTrue(
            app.navigationBars["Server"].waitForExistence(timeout: 5),
            "Back must return to Server Settings"
        )
        XCTAssertTrue(app.buttons["server.modelProviders.open"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["Current server: Source Host"].waitForExistence(timeout: 2),
            "Back must keep the source settings host"
        )
    }

    private func launchRegressionPreview() {
        app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "server-provider-navigation-regression"
        app.launch()

        let ready = app.descendants(matching: .any)["screenshot.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 8), "Regression preview did not become ready")
    }

    private static let proofWidth: CGFloat = 320
}
