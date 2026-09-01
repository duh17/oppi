import XCTest

@MainActor
final class ModelProvidersNavigationE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    func testModelProvidersOpensDirectlyFromInboxAndUsage() {
        openServerSwitcher()
        tap(app.buttons["workspace.modelProviders.open"], named: "inbox model providers", timeout: 5)
        assertModelProvidersVisible()

        navigateBack()
        openServerSwitcher()
        tap(app.buttons["hostSwitcher.usage"], named: "usage", timeout: 5)
        XCTAssertTrue(
            app.navigationBars["Usage"].waitForExistence(timeout: 10),
            "Usage navigation title did not appear"
        )
        openServerSwitcher()
        tap(app.buttons["workspace.modelProviders.open"], named: "usage model providers", timeout: 5)
        assertModelProvidersVisible()
    }

    private func openServerSwitcher() {
        let switcher = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Current server:"))
            .firstMatch
        tap(switcher, named: "server switcher", timeout: 10)
    }

    private func assertModelProvidersVisible() {
        XCTAssertTrue(
            app.navigationBars["Model Providers"].waitForExistence(timeout: 10),
            "Model Providers navigation title did not appear"
        )
        XCTAssertTrue(
            app.collectionViews["server.modelProviders.list"].waitForExistence(timeout: 10),
            "Dedicated provider list did not appear"
        )
        XCTAssertTrue(
            app.staticTexts["Connected"].exists || app.staticTexts["Available"].exists,
            "Provider sections did not render"
        )
    }

    private func navigateBack() {
        let backButton = app.navigationBars.buttons.firstMatch
        tap(backButton, named: "model providers back button", timeout: 5)
        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 10),
            "Session Inbox did not reappear after leaving Model Providers"
        )
    }
}
