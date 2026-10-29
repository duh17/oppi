import XCTest

/// Server Settings follows the host switcher, one page per server. Two real isolated
/// HTTPS servers, both paired: open Server Settings for the first, switch to the second
/// through the page's own switcher, and nothing of the first may stay on screen.
/// Run with `TWO_SERVER_TEST=ServerSettingsSwitchE2ETests bun server/scripts/e2e-two-server.ts`
/// (`OPPI_SIM_DEVICE_PROFILE=ipad` for iPad) or name it to the batch gate, not plain `clients/apple/scripts/e2e.sh`.
@MainActor
final class ServerSettingsSwitchE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        do {
            application.launchEnvironment["OPPI_E2E_LAUNCH_INVITE"] = try TwoServerFixture.firstServerLaunchInvite()
            application.launchArguments += try TwoServerFixture.load().launchArguments
        } catch {
            XCTFail("\(error)")
        }
    }

    /// The summary row's name, which is the one place the page says which server it is for.
    private var summary: XCUIElement {
        app.descendants(matching: .any)["server.summary"]
    }

    private func waitForSummary(named name: String, _ message: String) {
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", name), object: summary
            )], timeout: 30),
            .completed,
            "\(message); the summary says \(summary.label)"
        )
    }

    func testSwitchingServersShowsTheOtherServersSettingsAndNothingOfTheFirst() async throws {
        let fixture = try TwoServerFixture.load()
        let first = app.buttons["Current server: e2e-server"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "First server did not pair")

        // Pair the second server by deep link, as the offline journey does, then come back to the first.
        app.launchEnvironment.removeValue(forKey: "PI_E2E_INVITE_URL")
        app.launchEnvironment["OPPI_E2E_LAUNCH_INVITE"] = "skip"
        app.terminate()
        app.open(try await fixture.mintInvite())
        let second = app.buttons["Current server: Offline E2E"]
        XCTAssertTrue(second.waitForExistence(timeout: 25), "Second real server did not pair and become selected")
        tap(second, named: "second server picker")
        let firstRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "e2e-server")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "First pairing was lost")
        tap(firstRow, named: "first server in picker")
        XCTAssertTrue(first.waitForExistence(timeout: 10), "Switch to first server failed")

        // Server Settings for the first server.
        tap(first, named: "host pill")
        tap(app.buttons["hostSwitcher.serverSettings"], named: "Server Settings", timeout: 5)
        XCTAssertTrue(app.navigationBars["Server Settings"].waitForExistence(timeout: 10), "Server Settings did not open")
        waitForSummary(named: "e2e-server", "Server Settings did not open on the first server")
        let list = app.collectionViews["server.details.list"]
        XCTAssertTrue(list.exists)
        try saveLabScreenshot(name: "server-settings-first-server")

        // Switch with the page's own switcher.
        tap(first, named: "Server Settings switcher")
        let secondRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Offline E2E")).firstMatch
        XCTAssertTrue(secondRow.waitForExistence(timeout: 5), "The switcher does not list the second server")
        tap(secondRow, named: "second server in the Server Settings switcher")

        // The page is the second server's: its name, its switcher, and no row or text of the first.
        waitForSummary(named: "Offline E2E", "Server Settings did not follow the switch")
        XCTAssertTrue(app.buttons["Current server: Offline E2E"].waitForExistence(timeout: 10), "The switcher did not move to the second server")
        XCTAssertFalse(first.exists, "The switcher still names the first server")
        XCTAssertEqual(app.navigationBars.matching(identifier: "Server Settings").count, 1, "A switch must not stack a second Server Settings")
        let leftovers = list.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "e2e-server", "e2e-server"))
        XCTAssertEqual(leftovers.count, 0, "Something of the first server stayed on the second server's page: \(leftovers.allElementsBoundByIndex.map(\.label))")
        // Its own workspaces, once its page has loaded: the second server has the one seeded workspace.
        let workspaces = app.buttons["server.manageWorkspaces"]
        XCTAssertTrue(workspaces.waitForExistence(timeout: 10))
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "1"), object: workspaces
            )], timeout: 30),
            .completed,
            "Workspaces does not show the second server's one workspace: \(workspaces.value ?? "nil")"
        )
        try saveLabScreenshot(name: "server-settings-second-server")

        // And back: the first server's page again.
        tap(app.buttons["Current server: Offline E2E"], named: "Server Settings switcher")
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "e2e-server")).firstMatch, named: "first server in the Server Settings switcher")
        waitForSummary(named: "e2e-server", "Server Settings did not follow the switch back")

        // Model Providers is a routed screen above Server Settings with a switcher of its own:
        // switching there keeps it on screen (a provider sign-in would stay alive) and re-points
        // Server Settings underneath it.
        tap(app.buttons["server.modelProviders.open"], named: "Model Providers row", timeout: 10)
        let providersBar = app.navigationBars["Model Providers"]
        XCTAssertTrue(providersBar.waitForExistence(timeout: 10), "Model Providers did not open")
        tap(first, named: "Model Providers switcher")
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Offline E2E")).firstMatch, named: "second server in the Model Providers switcher")
        XCTAssertTrue(app.buttons["Current server: Offline E2E"].waitForExistence(timeout: 10), "Model Providers did not follow its own switcher")
        XCTAssertTrue(providersBar.exists, "A switch from Model Providers closed it")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Server Settings"].waitForExistence(timeout: 10), "Back from Model Providers did not return to Server Settings")
        waitForSummary(named: "Offline E2E", "Server Settings did not follow the switch made above it")
    }
}
