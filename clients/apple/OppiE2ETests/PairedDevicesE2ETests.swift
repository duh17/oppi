import XCTest

/// Server detail → Paired Devices against the real paired E2E server.
///
/// The harness pairs the app (a real P-256 pairing that sends the resolved device
/// name) and the `e2e-script-bootstrap` device whose token every lab-API call in
/// the run shares. The test enrolls a throwaway device and revokes only that one;
/// revoking the shared lab device would 401 every later E2E class in the run.
@MainActor
final class PairedDevicesE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    private let scriptDeviceName = "e2e-script-bootstrap"
    private let throwawayDeviceName = "e2e-throwaway-device"

    func testRosterMarksThisDeviceAndRevokesAnotherAfterConfirmation() throws {
        let throwaway = try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/fixtures/paired-device",
            body: ["name": throwawayDeviceName]
        )
        let throwawayId = try XCTUnwrap(throwaway["deviceId"] as? String)
        let throwawayToken = try XCTUnwrap(throwaway["accessToken"] as? String)

        let devices = try e2eLabAPIJSON(method: "GET", path: "/auth/devices")["devices"] as? [[String: Any]] ?? []
        let appDevice = try XCTUnwrap(
            devices.first { ![scriptDeviceName, throwawayDeviceName].contains($0["name"] as? String ?? "") },
            "Server did not enroll the app device"
        )
        let appName = try XCTUnwrap(appDevice["name"] as? String)
        let appId = try XCTUnwrap(appDevice["id"] as? String)
        XCTAssertNotEqual(appName, "Device", "App paired without sending a device name")
        let scriptId = try XCTUnwrap(
            devices.first { ($0["name"] as? String) == scriptDeviceName }?["id"] as? String
        )

        openServerSettings()
        XCTAssertTrue(
            app.collectionViews["server.details.list"].waitForExistence(timeout: 10),
            "Server settings list did not appear"
        )
        tap(app.buttons["server.row.pairedDevices"], named: "Paired Devices row", timeout: 10)
        let list = app.collectionViews["server.pairedDevices.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Paired Devices page did not appear")

        let revoke = app.buttons["server.pairedDevices.revoke.\(throwawayId)"]
        scrollUntilVisible(revoke, in: list)
        XCTAssertTrue(revoke.exists, "Other device has no Revoke button")
        XCTAssertEqual(revoke.label, "Revoke \(throwawayDeviceName)", "Revoke button is not labelled for VoiceOver")
        let throwawayRow = rosterRow("server.pairedDevices.row.\(throwawayId)")
        XCTAssertTrue(throwawayRow.exists, "Other device row missing from roster")
        XCTAssertTrue(throwawayRow.label.hasPrefix(throwawayDeviceName), "Other device name missing: \(throwawayRow.label)")
        XCTAssertTrue(throwawayRow.label.contains("Last used"), "Other device row has no last-used caption: \(throwawayRow.label)")
        let thisRow = rosterRow("server.pairedDevices.thisDevice")
        XCTAssertTrue(thisRow.exists, "This-device row missing")
        XCTAssertTrue(thisRow.label.hasPrefix(appName), "Paired name '\(appName)' missing from roster: \(thisRow.label)")
        XCTAssertTrue(thisRow.label.contains("This device"), "This-device marker missing: \(thisRow.label)")
        XCTAssertFalse(
            app.buttons["server.pairedDevices.revoke.\(appId)"].exists,
            "This device must not offer Revoke"
        )
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "server.pairedDevices.revoke.")).count,
            2,
            "Every other device (lab and throwaway) should offer Revoke, and only those"
        )
        try saveLabScreenshot(name: "paired-devices-roster")

        tap(revoke, named: "Revoke other device")
        XCTAssertTrue(
            app.staticTexts["Revoke \(throwawayDeviceName)?"].waitForExistence(timeout: 5),
            "Revoke confirmation did not name the device"
        )
        try saveLabScreenshot(name: "paired-devices-revoke-confirmation")

        // Compact iPhone popovers dismiss on an outside tap; that is Cancel.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        XCTAssertFalse(app.staticTexts["Revoke \(throwawayDeviceName)?"].exists, "Cancel did not dismiss confirmation")
        XCTAssertTrue(revoke.exists, "Cancel removed the device row")

        tap(revoke, named: "Revoke other device again")
        XCTAssertTrue(app.staticTexts["Revoke \(throwawayDeviceName)?"].waitForExistence(timeout: 5))
        tap(app.buttons.matching(NSPredicate(format: "label == %@", "Revoke")).firstMatch, named: "confirm revoke")
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: revoke)], timeout: 15),
            .completed,
            "Revoked device stayed in the roster"
        )
        XCTAssertFalse(throwawayRow.exists, "Revoked device row still listed")
        XCTAssertTrue(thisRow.exists, "Revoke removed this device's row")
        XCTAssertEqual(
            try e2eLabAPIBytes(method: "GET", path: "/auth/devices", bearerToken: throwawayToken).statusCode,
            401,
            "Revoked device token still works"
        )
        // The shared lab token must survive: later E2E classes in the run depend on it.
        let after = try e2eLabAPIJSON(method: "GET", path: "/auth/devices")["devices"] as? [[String: Any]] ?? []
        XCTAssertNil(after.first { $0["id"] as? String == scriptId }?["revokedAt"] as? NSNumber, "Lab device was revoked")
        XCTAssertNotNil(after.first { $0["id"] as? String == throwawayId }?["revokedAt"] as? NSNumber, "Server did not record the revocation")
        try saveLabScreenshot(name: "paired-devices-after-revoke")
    }

    private func rosterRow(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openServerSettings() {
        let switcher = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Current server:"))
            .firstMatch
        tap(switcher, named: "server switcher", timeout: 10)
        tap(app.buttons["hostSwitcher.serverSettings"], named: "Server Settings", timeout: 5)
        XCTAssertTrue(app.navigationBars["Server Settings"].waitForExistence(timeout: 10), "Server settings did not open")
    }

    private func scrollUntilVisible(_ element: XCUIElement, in list: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            list.swipeUp()
        }
    }
}
