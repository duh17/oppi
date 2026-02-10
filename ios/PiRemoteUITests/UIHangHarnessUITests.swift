import XCTest

/// UI hang regression harness tests.
///
/// These tests launch the app in harness mode (deterministic fixture data,
/// no server connection) and verify the main thread stays responsive
/// during typical UI operations like session switching.
///
/// The harness runs with streaming disabled (`PI_UI_HANG_NO_STREAM=1`)
/// so the app reaches XCUITest "idle" state between interactions.
final class UIHangHarnessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments.append("--ui-hang-harness")
        app.launchEnvironment["PI_UI_HANG_HARNESS"] = "1"
        app.launchEnvironment["PI_UI_HANG_NO_STREAM"] = "1"
        app.launch()

        // Wait for harness to fully render
        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"]
                .waitForExistence(timeout: 10),
            "Harness did not become ready"
        )
    }

    /// Core regression test: session switching must not cause main-thread stalls.
    ///
    /// - Loads 3 fixture sessions with 30 turns each (60 items per session)
    /// - Reads baseline diagnostics (heartbeat, stallCount, itemCount)
    /// - Rapidly switches sessions 15 times (5 rounds x 3 sessions)
    /// - Asserts heartbeat advanced (main thread responsive)
    /// - Asserts stallCount == 0 (no watchdog-detected hangs)
    /// - Asserts itemCount > 0 (fixture data still loaded)
    func testSessionSwitchNoStalls() throws {
        // -- Baseline diagnostics --
        let hbBefore = pollDiagnostic("diag.heartbeat", timeout: 8)
        XCTAssertGreaterThanOrEqual(hbBefore, 0, "Could not read initial heartbeat")

        let stallBefore = pollDiagnostic("diag.stallCount", timeout: 4)
        XCTAssertEqual(stallBefore, 0, "Unexpected stalls at start")

        let itemsBefore = pollDiagnostic("diag.itemCount", timeout: 4)
        XCTAssertGreaterThan(itemsBefore, 0, "No fixture items loaded")

        // -- Rapid session switching --
        let alpha = app.descendants(matching: .any)["harness.session.alpha"]
        let beta = app.descendants(matching: .any)["harness.session.beta"]
        let gamma = app.descendants(matching: .any)["harness.session.gamma"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4))
        XCTAssertTrue(beta.waitForExistence(timeout: 4))
        XCTAssertTrue(gamma.waitForExistence(timeout: 4))

        for _ in 0..<5 {
            alpha.tap()
            Thread.sleep(forTimeInterval: 0.08)
            beta.tap()
            Thread.sleep(forTimeInterval: 0.08)
            gamma.tap()
            Thread.sleep(forTimeInterval: 0.08)
        }

        // -- Post-churn assertions --
        let hbAfter = pollDiagnostic("diag.heartbeat", timeout: 10)
        XCTAssertGreaterThan(hbAfter, hbBefore, "Heartbeat did not advance after session switches")

        let stallAfter = pollDiagnostic("diag.stallCount", timeout: 4)
        XCTAssertEqual(stallAfter, 0, "Main-thread stalls detected after session switches")

        let itemsAfter = pollDiagnostic("diag.itemCount", timeout: 4)
        XCTAssertGreaterThan(itemsAfter, 0, "Item count dropped to zero")
    }

    // MARK: - Helpers

    /// Poll a diagnostic accessibility element until a parsable int is returned.
    private func pollDiagnostic(_ id: String, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let el = app.descendants(matching: .any)[id]
            if el.waitForExistence(timeout: 0.5) {
                let raw = (el.value as? String) ?? el.label
                if let v = Int(raw) { return v }
                let digits = raw.filter(\.isNumber)
                if let v = Int(digits) { return v }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail("Could not read diagnostic \(id) within \(timeout)s")
        return -1
    }
}
