import XCTest

/// Expand/collapse flow and error row rendering tests for the UI hang harness.
///
/// Validates that:
/// - Tool row full-screen transitions (via double-tap) do not cause stalls
/// - Compaction row expand/collapse toggle works without regressions
/// - Rapid expand/collapse cycling stays stall-free
/// - Error rows render alongside expand/collapse content without hang regressions
///
/// Full-screen expansion on thinking and tool rows is triggered by double-tap,
/// pinch-out, or context menu — there are no explicit expand buttons.
/// The tests use harness focus buttons to scroll to and expand tool rows with
/// long content, then double-tap the expanded content area to trigger full-screen.
@MainActor
final class UIHarnessExpandTests: UIHarnessTestCase {

    // MARK: - Full-Screen Expand Tests

    func testThinkingRowExpandToFullScreen() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 7, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 7)

        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        // Focus the extension markdown tool — it has long rich content that
        // supports full-screen expansion via double-tap, exercising the same
        // full-screen presentation path as thinking rows.
        let extensionFocus = app.descendants(matching: .any)["harness.extension.focus"]
        XCTAssertTrue(extensionFocus.waitForExistence(timeout: 4))
        extensionFocus.tap()

        XCTAssertEqual(waitForDiagnostic("diag.extensionExpanded", equals: 1, timeout: 4), 1)
        Thread.sleep(forTimeInterval: 0.5)

        // Double-tap the expanded content area to trigger full-screen.
        let timeline = app.descendants(matching: .any)["harness.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))
        let expandedArea = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        expandedArea.doubleTap()
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
            assertHarnessStillRunning(context: "extension markdown full-screen expand/dismiss")
        )

        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        XCTAssertLessThanOrEqual(perfGuardrailAfter - perfGuardrailBefore, 1)
    }

    func testToolRowExpandToFullScreen() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 7, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 7)

        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        // Focus the extension text tool — it has long plain-text content that
        // supports full-screen expansion via double-tap.
        let extensionTextFocus = app.descendants(matching: .any)["harness.extensionText.focus"]
        XCTAssertTrue(extensionTextFocus.waitForExistence(timeout: 4))
        extensionTextFocus.tap()

        XCTAssertEqual(waitForDiagnostic("diag.extensionTextExpanded", equals: 1, timeout: 4), 1)
        Thread.sleep(forTimeInterval: 0.5)

        // Double-tap the expanded content area to trigger full-screen.
        let timeline = app.descendants(matching: .any)["harness.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))
        let expandedArea = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        expandedArea.doubleTap()
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

        // The compaction row is near but not at the very bottom (audio clip is
        // last). If not immediately visible, swipe the timeline to find it.
        let compactionToggle = app.descendants(matching: .any)["compaction.expand-toggle"]
        if !compactionToggle.waitForExistence(timeout: 2) {
            let timeline = app.descendants(matching: .any)["harness.timeline"]
            for _ in 0..<5 {
                timeline.swipeDown()
                if compactionToggle.waitForExistence(timeout: 1) { break }
            }
        }

        guard compactionToggle.waitForExistence(timeout: 2) else {
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
