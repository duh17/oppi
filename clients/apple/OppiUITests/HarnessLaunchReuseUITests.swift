import XCTest

/// What a reused harness launch must hand the next test (`ReusedHarnessLaunch`):
/// the state of a fresh process. Both tests run the same journey, so whichever
/// runs second proves the first one left nothing behind, in either order.
final class HarnessLaunchReuseUITests: UIHarnessTestCase {
    override class var reusesLaunch: Bool { true }

    func testThemeStartsDefaultThenChangesFirst() throws {
        try assertStartsDarkThenSwitchesTheme()
    }

    func testThemeStartsDefaultThenChangesSecond() throws {
        try assertStartsDarkThenSwitchesTheme()
    }

    private func assertStartsDarkThenSwitchesTheme() throws {
        launchHarness(noStream: true)
        // Dark is ordinal 0. A reused launch that kept the last test's theme would read 1.
        XCTAssertEqual(pollDiagnostic("diag.theme", timeout: 4), 0, "Harness did not start on the default theme")

        let toggle = app.descendants(matching: .any)["harness.theme.toggle"]
        tapHarnessControl(toggle)
        XCTAssertEqual(waitForDiagnostic("diag.theme", equals: 1, timeout: 4), 1)
    }
}
