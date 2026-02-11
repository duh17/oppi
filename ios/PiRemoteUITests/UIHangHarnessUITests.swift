import XCTest

/// UI hang regression harness tests.
///
/// Exercises the collection-backed chat timeline harness with deterministic
/// fixture data and synthetic streaming.
final class UIHangHarnessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSessionSwitchNoStalls() throws {
        launchHarness(noStream: true)

        let hbBefore = pollDiagnostic("diag.heartbeat", timeout: 8)
        XCTAssertGreaterThanOrEqual(hbBefore, 0)

        let stallBefore = pollDiagnostic("diag.stallCount", timeout: 4)
        XCTAssertEqual(stallBefore, 0)

        let itemsBefore = pollDiagnostic("diag.itemCount", timeout: 4)
        XCTAssertGreaterThan(itemsBefore, 0)

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

        let hbAfter = pollDiagnostic("diag.heartbeat", timeout: 10)
        XCTAssertGreaterThan(hbAfter, hbBefore)

        let stallAfter = pollDiagnostic("diag.stallCount", timeout: 4)
        XCTAssertEqual(stallAfter, 0)

        let itemsAfter = pollDiagnostic("diag.itemCount", timeout: 4)
        XCTAssertGreaterThan(itemsAfter, 0)
    }

    func testStreamingKeepsBottomPinnedWhenNearBottom() throws {
        if ProcessInfo.processInfo.environment["PI_UI_HANG_LONG"] != "1" {
            throw XCTSkip("Long streaming pin test disabled by default")
        }

        launchHarness(noStream: true)

        let streamToggle = app.descendants(matching: .any)["harness.stream.toggle"]
        XCTAssertTrue(streamToggle.waitForExistence(timeout: 4))
        streamToggle.tap()

        let pulse = app.descendants(matching: .any)["harness.stream.pulse"]
        XCTAssertTrue(pulse.waitForExistence(timeout: 4))

        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]
        XCTAssertTrue(bottomButton.waitForExistence(timeout: 4))
        bottomButton.tap()

        let topBefore = pollDiagnostic("diag.topIndex", timeout: 4)
        XCTAssertGreaterThanOrEqual(topBefore, 0)

        let tickBefore = pollDiagnostic("diag.streamTick", timeout: 4)
        pulse.tap()

        let tickAfter = pollDiagnostic("diag.streamTick", timeout: 4)
        XCTAssertGreaterThan(tickAfter, tickBefore)

        let topAfter = pollDiagnostic("diag.topIndex", timeout: 4)
        XCTAssertGreaterThanOrEqual(topAfter, topBefore - 2)
    }

    func testStreamingDoesNotYankWhenScrolledUp() throws {
        launchHarness(noStream: true)

        let streamToggle = app.descendants(matching: .any)["harness.stream.toggle"]
        XCTAssertTrue(streamToggle.waitForExistence(timeout: 4))
        streamToggle.tap()

        let pulse = app.descendants(matching: .any)["harness.stream.pulse"]
        XCTAssertTrue(pulse.waitForExistence(timeout: 4))

        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        XCTAssertTrue(expandAll.waitForExistence(timeout: 4))
        expandAll.tap()

        let topButton = app.descendants(matching: .any)["harness.scroll.top"]
        XCTAssertTrue(topButton.waitForExistence(timeout: 4))
        topButton.tap()

        XCTAssertEqual(waitForDiagnostic("diag.nearBottom", equals: 0, timeout: 6), 0)

        let topBefore = pollDiagnostic("diag.topIndex", timeout: 4)
        XCTAssertGreaterThanOrEqual(topBefore, 0)

        pulse.tap()
        pulse.tap()
        pulse.tap()

        let nearBottomAfter = pollDiagnostic("diag.nearBottom", timeout: 4)
        XCTAssertEqual(nearBottomAfter, 0)

        let topAfter = pollDiagnostic("diag.topIndex", timeout: 4)
        XCTAssertLessThanOrEqual(topAfter, topBefore + 8)
    }

    func testThemeToggleAndKeyboardDuringStreamingNoStalls() throws {
        launchHarness(noStream: true)

        let streamToggle = app.descendants(matching: .any)["harness.stream.toggle"]
        XCTAssertTrue(streamToggle.waitForExistence(timeout: 4))
        streamToggle.tap()

        let pulse = app.descendants(matching: .any)["harness.stream.pulse"]
        XCTAssertTrue(pulse.waitForExistence(timeout: 4))
        pulse.tap()

        let hbBefore = pollDiagnostic("diag.heartbeat", timeout: 6)

        let themeToggle = app.descendants(matching: .any)["harness.theme.toggle"]
        XCTAssertTrue(themeToggle.waitForExistence(timeout: 4))
        themeToggle.tap()

        let input = app.textFields["harness.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 4))
        input.tap()

        // Advance stream once more while keyboard is up.
        pulse.tap()

        let stallAfter = pollDiagnostic("diag.stallCount", timeout: 6)
        XCTAssertEqual(stallAfter, 0)

        let hbAfter = pollDiagnostic("diag.heartbeat", timeout: 6)
        XCTAssertGreaterThan(hbAfter, hbBefore)
    }

    // MARK: - Launch

    private func launchHarness(noStream: Bool) {
        app = XCUIApplication()
        app.launchArguments.append("--ui-hang-harness")
        app.launchEnvironment["PI_UI_HANG_HARNESS"] = "1"
        if noStream {
            app.launchEnvironment["PI_UI_HANG_NO_STREAM"] = "1"
        } else {
            app.launchEnvironment["PI_UI_HANG_NO_STREAM"] = "0"
        }
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"].waitForExistence(timeout: 10),
            "Harness did not become ready"
        )
    }

    // MARK: - Helpers

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

    private func waitForDiagnostic(_ id: String, equals expected: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let value = pollDiagnostic(id, timeout: 0.8)
            if value == expected {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        XCTFail("Diagnostic \(id) did not reach expected value \(expected)")
        return -1
    }

    private func waitForDiagnosticAtLeast(_ id: String, minimum: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let value = pollDiagnostic(id, timeout: 0.8)
            if value >= minimum {
                return minimum
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        XCTFail("Diagnostic \(id) did not reach minimum value \(minimum)")
        return -1
    }
}
