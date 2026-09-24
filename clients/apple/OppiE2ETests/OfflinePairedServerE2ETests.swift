import XCTest

/// Two real isolated HTTPS servers: pair both, make only the second unreachable,
/// then exercise the user-visible offline selection and local-only removal path.
/// Run with `bun server/scripts/e2e-two-server.ts`, not plain sim-test.
@MainActor
final class OfflinePairedServerE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        guard let fixtureData = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/oppi-e2e-two-server.json")),
              let fixture = try? JSONSerialization.jsonObject(with: fixtureData) as? [String: String],
              let expectedPort = fixture["firstPort"].flatMap(Int.init) else {
            XCTFail("Current two-server port fixture is unavailable to the UI runner")
            return
        }
        let fileInvite = try? String(contentsOfFile: "/tmp/oppi-e2e-invite.txt", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filePort = fileInvite.flatMap { try? E2ELabServerContext.baseURL(inviteURLString: $0).port }
        guard filePort == expectedPort, let fileInvite else {
            XCTFail("UI runner received a stale first-server invite file")
            return
        }
        application.launchEnvironment["OPPI_E2E_LAUNCH_INVITE"] = fileInvite
    }

    func testOfflinePickerInboxSidebarRetrySettingsAndConfirmedRemoval() async throws {
        XCUIDevice.shared.orientation = .portrait
        // The Xcode test runner does not pass arbitrary host environment values.
        // Match E2ETestCase's /tmp invite-file handoff for this isolated fixture.
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: "/tmp/oppi-e2e-two-server.json"))
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData) as? [String: String],
            "Run the two-server harness; second server fixture is required"
        )
        let secondInvite = try XCTUnwrap(fixture["invite"])
        let offlineURL = try XCTUnwrap(fixture["stopURL"].flatMap(URL.init(string:)))
        let first = app.buttons["Current server: e2e-server"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "First server did not pair")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Connected"), object: first
        )], timeout: 30), .completed, "First server did not connect")

        // Force the deep-link relaunch. Replaying the first invite at startup
        // would clear the second pairing before its link can be processed.
        app.launchEnvironment.removeValue(forKey: "PI_E2E_INVITE_URL")
        app.launchEnvironment["OPPI_E2E_LAUNCH_INVITE"] = "skip"
        app.terminate()
        app.open(try XCTUnwrap(URL(string: secondInvite)))
        let second = app.buttons["Current server: Offline E2E"]
        XCTAssertTrue(second.waitForExistence(timeout: 25), "Second real server did not pair and become selected")
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
        var stop = URLRequest(url: offlineURL)
        stop.httpMethod = "POST"
        let (_, stopResponse) = try await URLSession.shared.data(for: stop)
        XCTAssertEqual((stopResponse as? HTTPURLResponse)?.statusCode, 200, "The harness did not make the paired second server unreachable")

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
        XCTAssertTrue(app.navigationBars["Server"].waitForExistence(timeout: 10), "Offline Server Settings did not open")
        let list = app.collectionViews["server.details.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let remove = app.buttons["Remove Server"]
        if !remove.isHittable { list.swipeUp() }
        tap(remove, named: "Remove Server")
        XCTAssertTrue(app.staticTexts["Remove Offline E2E?"].waitForExistence(timeout: 5), "Removal confirmation missing")
        // Compact iPhone confirmation popovers dismiss on an outside tap and
        // need not expose the SwiftUI cancellation role as a visible button.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        XCTAssertFalse(app.staticTexts["Remove Offline E2E?"].exists, "Cancellation did not dismiss confirmation")
        XCTAssertTrue(app.navigationBars["Server"].exists, "Cancellation unexpectedly left settings")
        XCTAssertTrue(remove.exists, "Cancellation removed the pairing")
        tap(remove, named: "Remove Server again")
        XCTAssertTrue(app.staticTexts["Remove Offline E2E?"].waitForExistence(timeout: 5))
        tap(app.buttons.matching(identifier: "Remove Server").element(boundBy: 1), named: "confirm local removal")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "Removal did not return to the remaining connected server")
        tap(first, named: "remaining server picker")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Offline E2E")).firstMatch.exists, "Removed pairing remained selectable")
        XCTAssertTrue(firstRow.exists, "Removal affected the other pairing")
        try saveLabScreenshot(name: "offline-paired-after-removal")
    }
}
