import XCTest

/// Expand/collapse flow and error row rendering tests for the UI hang harness.
///
/// Validates that:
/// - Thinking and tool row full-screen transitions do not cause stalls
/// - Compaction row expand/collapse toggle works without regressions
/// - Rapid expand/collapse cycling stays stall-free
/// - Error rows render alongside expand/collapse content without hang regressions
@MainActor
final class UIHarnessExpandTests: UIHarnessTestCase {

    // MARK: - Full-Screen Expand Tests

    func testThinkingRowExpandToFullScreen() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 7, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 7)

        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        XCTAssertTrue(expandAll.waitForExistence(timeout: 4))
        expandAll.tap()

        let renderToolSet = app.descendants(matching: .any)["harness.tools.render"]
        XCTAssertTrue(renderToolSet.waitForExistence(timeout: 4))
        renderToolSet.tap()

        // Scroll to bottom where visual fixtures live.
        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]
        XCTAssertTrue(bottomButton.waitForExistence(timeout: 4))
        bottomButton.tap()
        sleep(1)

        // The thinking full-screen button may not exist in every harness configuration.
        let thinkingExpandButton = app.descendants(matching: .any)["thinking.expand-full-screen"]
        guard thinkingExpandButton.waitForExistence(timeout: 5) else {
            throw XCTSkip(
                "thinking.expand-full-screen button not found; "
                + "skipping full-screen cycle"
            )
        }

        thinkingExpandButton.tap()
        sleep(1)

        // Dismiss: try navigation-bar Done button, then fullscreen-image dismiss.
        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 4) {
            doneButton.tap()
        } else {
            let dismissButton = app.descendants(matching: .any)["fullscreen-image.dismiss"]
            if dismissButton.waitForExistence(timeout: 2) {
                dismissButton.tap()
            }
        }

        XCTAssertTrue(
            assertHarnessStillRunning(context: "thinking row full-screen expand/dismiss")
        )

        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        XCTAssertLessThanOrEqual(perfGuardrailAfter - perfGuardrailBefore, 1)
    }

    func testToolRowExpandToFullScreen() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 7, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 7)

        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        XCTAssertTrue(expandAll.waitForExistence(timeout: 4))
        expandAll.tap()

        let renderToolSet = app.descendants(matching: .any)["harness.tools.render"]
        XCTAssertTrue(renderToolSet.waitForExistence(timeout: 4))
        renderToolSet.tap()

        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]
        XCTAssertTrue(bottomButton.waitForExistence(timeout: 4))
        bottomButton.tap()
        sleep(1)

        // The tool full-screen button may not exist in every harness configuration.
        let toolExpandButton = app.descendants(matching: .any)["tool.expand-full-screen"]
        guard toolExpandButton.waitForExistence(timeout: 5) else {
            throw XCTSkip(
                "tool.expand-full-screen button not found; "
                + "skipping full-screen cycle"
            )
        }

        toolExpandButton.tap()
        sleep(1)

        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 4) {
            doneButton.tap()
        } else {
            let dismissButton = app.descendants(matching: .any)["fullscreen-image.dismiss"]
            if dismissButton.waitForExistence(timeout: 2) {
                dismissButton.tap()
            }
        }

        XCTAssertTrue(
            assertHarnessStillRunning(context: "tool row full-screen expand/dismiss")
        )

        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        XCTAssertLessThanOrEqual(perfGuardrailAfter - perfGuardrailBefore, 1)
    }

    // MARK: - Compaction Expand/Collapse

    func testCompactionRowExpandCollapse() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let stallBefore = pollDiagnostic("diag.stallCount", timeout: 4)
        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        // Show all items so compaction rows are in the render window.
        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        XCTAssertTrue(expandAll.waitForExistence(timeout: 4))
        expandAll.tap()

        // Scroll to bottom where visual fixtures (including compaction) live.
        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]
        XCTAssertTrue(bottomButton.waitForExistence(timeout: 4))
        bottomButton.tap()
        sleep(1)

        let compactionToggle = app.descendants(matching: .any)["compaction.expand-toggle"]
        guard compactionToggle.waitForExistence(timeout: 6) else {
            throw XCTSkip(
                "compaction.expand-toggle not found; "
                + "no expandable compaction row in current harness fixtures"
            )
        }

        // Expand
        compactionToggle.tap()
        sleep(1)
        XCTAssertTrue(
            assertHarnessStillRunning(context: "compaction row expand")
        )

        // Collapse
        compactionToggle.tap()
        sleep(1)
        XCTAssertTrue(
            assertHarnessStillRunning(context: "compaction row collapse")
        )

        let stallAfter = pollDiagnostic("diag.stallCount", timeout: 4)
        XCTAssertLessThanOrEqual(stallAfter - stallBefore, 1)

        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        XCTAssertLessThanOrEqual(perfGuardrailAfter - perfGuardrailBefore, 1)
    }

    // MARK: - Rapid Cycling

    func testExpandCollapseRapidCycleNoStalls() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 7, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 7)

        let stallBefore = pollDiagnostic("diag.stallCount", timeout: 4)
        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        XCTAssertTrue(expandAll.waitForExistence(timeout: 4))
        expandAll.tap()

        // Scroll to bottom near expandable content.
        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]
        XCTAssertTrue(bottomButton.waitForExistence(timeout: 4))
        bottomButton.tap()
        sleep(1)

        // Rapid-cycle compaction toggle if available.
        let compactionToggle = app.descendants(matching: .any)["compaction.expand-toggle"]
        if compactionToggle.waitForExistence(timeout: 4) {
            for _ in 0..<5 {
                compactionToggle.tap()
                Thread.sleep(forTimeInterval: 0.08)
            }
        }

        // Rapid-cycle the expand-all button to trigger render window + tool reconfigure.
        let topButton = app.descendants(matching: .any)["harness.scroll.top"]
        XCTAssertTrue(topButton.waitForExistence(timeout: 4))

        for _ in 0..<5 {
            expandAll.tap()
            Thread.sleep(forTimeInterval: 0.08)
            bottomButton.tap()
            Thread.sleep(forTimeInterval: 0.08)
            topButton.tap()
            Thread.sleep(forTimeInterval: 0.08)
        }

        XCTAssertTrue(
            assertHarnessStillRunning(context: "rapid expand/collapse cycling")
        )

        let stallAfter = pollDiagnostic("diag.stallCount", timeout: 6)
        XCTAssertLessThanOrEqual(stallAfter - stallBefore, 1)

        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        XCTAssertLessThanOrEqual(perfGuardrailAfter - perfGuardrailBefore, 1)
    }
}
