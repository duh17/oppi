import XCTest

/// Two real isolated HTTPS servers: pair both, make only the second unreachable,
/// then exercise the user-visible offline selection and local-only removal path.
/// Run with `bun server/scripts/e2e-two-server.ts` (or name it to the batch gate), not plain `clients/apple/scripts/e2e.sh`.
@MainActor
final class OfflinePairedServerE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        do {
            application.launchEnvironment["OPPI_E2E_LAUNCH_INVITE"] = try TwoServerFixture.firstServerLaunchInvite()
        } catch {
            XCTFail("\(error)")
        }
    }

    func testOfflinePickerInboxSidebarRetrySettingsAndConfirmedRemoval() async throws {
        let fixture = try TwoServerFixture.load()
        let first = app.serverSwitcher(named: "e2e-server")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "First server did not pair")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Connected"), object: first
        )], timeout: 30), .completed, "First server did not connect")

        // Force the deep-link relaunch. Replaying the first invite at startup
        // would clear the second pairing before its link can be processed.
        app.launchEnvironment.removeValue(forKey: "PI_E2E_INVITE_URL")
        app.launchEnvironment["OPPI_E2E_LAUNCH_INVITE"] = "skip"
        app.terminate()
        app.open(try await fixture.mintInvite())
        let second = app.serverSwitcher(named: "Offline E2E")
        assertExists(second, within: 25, "Second real server did not pair and become selected")
        XCTAssertEqual(second.value as? String, "Connected", "Second server was not online before failure")
        tap(second, named: "second server picker")
        let firstRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "e2e-server")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "First pairing was lost")
        XCTAssertTrue(app.buttons["Offline E2E"].exists, "Second pairing is absent from picker")
        tap(firstRow, named: "first server in picker")
        XCTAssertTrue(first.waitForExistence(timeout: 10), "Switch to first server failed")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Connected"), object: first
        )], timeout: 30), .completed, "First server did not reconnect")

        // The host kills only its second child, and replies after that process exits.
        try await fixture.stopSecondServer()

        tap(first, named: "server picker after failure")
        let offlineRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Offline E2E")).firstMatch
        XCTAssertTrue(offlineRow.waitForExistence(timeout: 15), "Offline pairing is missing from the picker")
        tap(offlineRow, named: "offline paired server")
        XCTAssertTrue(second.waitForExistence(timeout: 10), "Offline choice did not become current")
        XCTAssertFalse(first.exists, "Selection incorrectly reverted to the connected server")
        XCTAssertTrue(app.staticTexts["Server Data Unavailable"].waitForExistence(timeout: 25), "Inbox did not report unavailable data")
        XCTAssertTrue(app.staticTexts["Offline E2E's workspace and session data are unavailable."].exists)
        XCTAssertFalse(app.buttons["workspace.open.e2e-workspace"].exists, "Inbox leaked the other server's workspace")
        try saveLabScreenshot(name: "offline-paired-inbox")

        tap(app.buttons["workspace.sidebar.open"], named: "workspace sidebar")
        XCTAssertTrue(app.staticTexts["Saved workspaces may be out of date"].waitForExistence(timeout: 10), "Sidebar did not identify the saved catalog as stale")
        XCTAssertTrue(app.buttons["workspace.open.Offline E2E Workspace"].exists, "Sidebar lost the second server's saved workspace")
        XCTAssertFalse(app.buttons["workspace.open.e2e-workspace"].exists, "Sidebar leaked first server's workspace")
        try saveLabScreenshot(name: "offline-paired-sidebar")
        // Dismiss the compact sidebar to reach the inbox Retry action.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Inbox Retry was not reachable")
        tap(retry, named: "inbox Retry")
        XCTAssertTrue(app.staticTexts["Offline E2E is still unavailable after retry."].waitForExistence(timeout: 25), "Retry did not report its failed attempt")
        XCTAssertTrue(app.staticTexts["Server Data Unavailable"].exists, "Failed Retry was presented as success")
        XCTAssertTrue(second.exists, "Retry changed the selected server")

        tap(second, named: "server picker for settings")
        tap(app.buttons["hostSwitcher.serverSettings"], named: "Server Settings")
        XCTAssertTrue(app.navigationBars["Server Settings"].waitForExistence(timeout: 10), "Offline Server Settings did not open")
        let list = app.collectionViews["server.details.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let remove = app.buttons["server.remove"]
        scrollUntilHittable(remove, in: list)
        tap(remove, named: "Remove Server")
        XCTAssertTrue(app.staticTexts["Remove Offline E2E?"].waitForExistence(timeout: 5), "Removal confirmation missing")
        // The action sheet dismisses on an outside tap (iPad: a popover) as it does on Cancel.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        XCTAssertFalse(app.staticTexts["Remove Offline E2E?"].exists, "Cancellation did not dismiss confirmation")
        XCTAssertTrue(app.navigationBars["Server Settings"].exists, "Cancellation unexpectedly left settings")
        XCTAssertTrue(remove.exists, "Cancellation removed the pairing")
        tap(remove, named: "Remove Server again")
        XCTAssertTrue(app.staticTexts["Remove Offline E2E?"].waitForExistence(timeout: 5))
        // The row is also labelled "Remove Server"; the sheet's action is the button of that name that is not the row.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Remove Server", "server.remove")).firstMatch
        tap(confirm, named: "confirm local removal")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "Removal did not return to the remaining connected server")
        tap(first, named: "remaining server picker")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Offline E2E")).firstMatch.exists, "Removed pairing remained selectable")
        XCTAssertTrue(firstRow.exists, "Removal affected the other pairing")
        try saveLabScreenshot(name: "offline-paired-after-removal")
    }
}
