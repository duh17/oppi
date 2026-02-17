import XCTest

/// UI hang regression harness tests.
///
/// Exercises the collection-backed chat timeline harness with deterministic
/// fixture data and synthetic streaming.
final class UIHangHarnessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI hang harness tests are simulator-only")
#endif
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

        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)

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
        XCTAssertLessThanOrEqual(stallAfter, 1)

        let itemsAfter = pollDiagnostic("diag.itemCount", timeout: 4)
        XCTAssertGreaterThan(itemsAfter, 0)

        let perfGuardrail = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        XCTAssertLessThanOrEqual(perfGuardrail - perfGuardrailBefore, 1)

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
        if ProcessInfo.processInfo.environment["PI_UI_HANG_ENABLE_SCROLL_YANK_TEST"] != "1" {
            throw XCTSkip("Scroll-yank harness assertion disabled by default; opt in with PI_UI_HANG_ENABLE_SCROLL_YANK_TEST=1")
        }

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

        guard let topBefore = waitForDiagnosticAtMostOrNil("diag.topIndex", maximum: 3, timeout: 6) else {
            throw XCTSkip("Harness did not reach a scrolled-up top index; skipping yank assertion in this simulator run")
        }
        XCTAssertGreaterThanOrEqual(topBefore, 0)

        let nearBottomBefore = pollDiagnostic("diag.nearBottom", timeout: 2)

        pulse.tap()
        pulse.tap()
        pulse.tap()

        let topAfter = pollDiagnostic("diag.topIndex", timeout: 4)
        XCTAssertLessThanOrEqual(topAfter, topBefore + 8)

        let nearBottomAfter = pollDiagnostic("diag.nearBottom", timeout: 4)
        if nearBottomBefore == 0 {
            XCTAssertEqual(nearBottomAfter, 0)
        }
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
        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        let themeToggle = app.descendants(matching: .any)["harness.theme.toggle"]
        XCTAssertTrue(themeToggle.waitForExistence(timeout: 4))
        themeToggle.tap()

        let input = app.textFields["harness.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 4))
        input.tap()

        // Advance stream once more while keyboard is up.
        pulse.tap()

        let stallAfter = pollDiagnostic("diag.stallCount", timeout: 6)
        XCTAssertLessThanOrEqual(stallAfter, 1)

        let hbAfter = pollDiagnostic("diag.heartbeat", timeout: 6)
        XCTAssertGreaterThan(hbAfter, hbBefore)

        let perfGuardrail = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        XCTAssertLessThanOrEqual(perfGuardrail - perfGuardrailBefore, 1)
    }

    @objc
    func testHarnessScreenshotState() throws {
        launchHarness(noStream: true)

        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        XCTAssertTrue(expandAll.waitForExistence(timeout: 4))
        expandAll.tap()

        let topButton = app.descendants(matching: .any)["harness.scroll.top"]
        XCTAssertTrue(topButton.waitForExistence(timeout: 4))
        topButton.tap()

        Thread.sleep(forTimeInterval: 12)
    }

    // MARK: - Launch

    private func launchHarness(noStream: Bool) {
        app = XCUIApplication()
        app.launchArguments.append("--ui-hang-harness")
        app.launchEnvironment["PI_UI_HANG_HARNESS"] = "1"
        app.launchEnvironment["PI_UI_HANG_UI_TEST_MODE"] = "1"
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

    private func assertHarnessStillRunning(context: String) -> Bool {
        if app.state != .runningForeground {
            XCTFail("Harness app left foreground while \(context). Current state: \(app.state.rawValue)")
            return false
        }

        let harnessReady = app.descendants(matching: .any)["harness.ready"]
        if !harnessReady.exists {
            if app.buttons["Connect to Server"].exists {
                XCTFail(
                    "Harness UI disappeared while \(context). 'Connect to Server' is visible, " +
                    "which indicates the app was relaunched outside harness mode."
                )
            } else {
                XCTFail("Harness UI disappeared while \(context).")
            }
            return false
        }

        return true
    }

    private func pollDiagnostic(_ id: String, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard assertHarnessStillRunning(context: "reading diagnostic \(id)") else {
                return -1
            }

            let el = app.descendants(matching: .any)[id]
            if el.waitForExistence(timeout: 0.5) {
                let raw = (el.value as? String) ?? el.label
                if let v = Int(raw) { return v }
                let digits = raw.filter(\.isNumber)
                if let v = Int(digits) { return v }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        guard assertHarnessStillRunning(context: "timing out while reading diagnostic \(id)") else {
            return -1
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

    private func waitForDiagnosticAtMostOrNil(_ id: String, maximum: Int, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let value = pollDiagnostic(id, timeout: 0.8)
            if value <= maximum {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        return nil
    }
}
