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

    func testMarkdownToolRowExpandToFullScreen() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 7, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 7)

        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        // Focus the read of a Markdown file: it paints the inline Markdown
        // viewport, and a double-tap on it opens the full-screen Markdown reader.
        // A generic extension call (`extensions.notes`) paints as a notebook cell
        // instead, so it cannot stand in for this surface.
        let readFocus = app.descendants(matching: .any)["harness.readMarkdown.focus"]
        XCTAssertTrue(readFocus.waitForExistence(timeout: 4))
        readFocus.tap()

        XCTAssertEqual(waitForDiagnostic("diag.readMarkdownExpanded", equals: 1, timeout: 4), 1)

        openFullScreenFromExpandedTool(
            rowIdentifier: "chat.timeline.row.alpha-visual-tool-read",
            contentIdentifier: "chat.timeline.row.alpha-visual-tool-read.markdownViewport",
            expectedFullscreenContentIdentifier: "full-screen.markdown.body",
            expectedContentSnippet: "network diagnosis"
        )
        dismissFullScreenAndReturnToTimeline(
            expectedFullscreenContentIdentifier: "full-screen.markdown.body"
        )

        XCTAssertTrue(
            assertHarnessStillRunning(context: "markdown read full-screen expand/dismiss")
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

        openFullScreenFromExpandedTool(
            rowIdentifier: "chat.timeline.row.alpha-visual-tool-extension-a",
            contentIdentifier: nil,
            expectedFullscreenContentIdentifier: nil,
            expectedContentSnippet: "extension lookup result"
        )
        dismissFullScreenAndReturnToTimeline(expectedFullscreenContentIdentifier: nil)

        XCTAssertTrue(
            assertHarnessStillRunning(context: "tool row full-screen expand/dismiss")
        )

        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        XCTAssertLessThanOrEqual(perfGuardrailAfter - perfGuardrailBefore, 1)
    }

    /// A single tap anywhere in an expanded notebook cell, including blank
    /// space beside a call, must leave the row expanded so it can be the first
    /// half of the double-tap that opens the reader.
    func testNotebookSingleTapKeepsRowExpandedForReaderDoubleTap() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)
        XCTAssertGreaterThanOrEqual(waitForDiagnosticAtLeast("diag.visualTools", minimum: 9, timeout: 6), 9)

        let scroll = app.descendants(matching: .any)["harness.notebook.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 4))
        scroll.tap()

        let row = app.descendants(matching: .any)["chat.timeline.row.alpha-visual-tool-notebook"].firstMatch
        let header = app.descendants(matching: .any)["chat.timeline.row.alpha-visual-tool-notebook.header"].firstMatch
        let timeline = app.descendants(matching: .any)["harness.timeline"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 4))
        XCTAssertEqual(pollDiagnostic("diag.notebookExpanded", timeout: 1), 0)
        header.tap()
        XCTAssertEqual(waitForDiagnostic("diag.notebookExpanded", equals: 1, timeout: 4), 1)

        let call = row.descendants(matching: .any)["tool.notebook.call"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 4))
        for _ in 0..<4 where !call.isHittable {
            timeline.swipeUp()
        }
        XCTAssertTrue(call.isHittable)
        let code = row.descendants(matching: .any)["tool.notebook.code"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 4))

        // The code text, then blank space right of a call name.
        for target in [code.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       call.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))] {
            target.tap()
            // Outlast the double-tap window so a deferred selection would land.
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            XCTAssertEqual(pollDiagnostic("diag.notebookExpanded", timeout: 1), 1, "A single tap collapsed the notebook row")
            XCTAssertTrue(call.exists, "The notebook cell disappeared after a single tap")
        }

        call.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).doubleTap()
        XCTAssertTrue(
            fullScreenDismissControl().waitForExistence(timeout: 4),
            "Double-tap on the calls section did not open the reader"
        )
        dismissFullScreenAndReturnToTimeline(expectedFullscreenContentIdentifier: nil)
        XCTAssertEqual(pollDiagnostic("diag.notebookExpanded", timeout: 1), 1)
    }

    func testCustomLogExpandsToCappedTerminal() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)
        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        XCTAssertTrue(expandAll.waitForExistence(timeout: 4))
        expandAll.tap()
        let bottom = app.descendants(matching: .any)["harness.scroll.bottom"]
        XCTAssertTrue(bottom.waitForExistence(timeout: 4))
        bottom.tap()

        let row = app.descendants(matching: .any)[
            "chat.timeline.row.alpha-visual-custom-log"
        ].firstMatch
        let timeline = app.descendants(matching: .any)["harness.timeline"].firstMatch
        for _ in 0..<8 where !row.isHittable {
            timeline.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        let preview = row.descendants(matching: .any)["custom.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 4))
        XCTAssertFalse(row.descendants(matching: .any)["custom.terminal"].firstMatch.exists)
        let collapsedHeight = row.frame.height
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20)).tap()
        let terminal = row.descendants(matching: .any)["custom.terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 4))
        XCTAssertFalse(preview.exists)
        XCTAssertGreaterThan(row.frame.height, collapsedHeight)
        XCTAssertLessThan(row.frame.height, collapsedHeight + 700)
        XCTAssertTrue(assertHarnessStillRunning(context: "custom log expand"))
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

        // The compaction row is near but not at the very bottom (audio clip is
        // last). If not immediately visible, swipe the timeline to find it.
        let timeline = app.descendants(matching: .any)["harness.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))
        let compactionRow = app.descendants(matching: .any)[
            "chat.timeline.row.alpha-visual-compaction-expandable"
        ]
        let compactionToggle = app.descendants(matching: .any)["compaction.expand-toggle"]
        if !compactionToggle.waitForExistence(timeout: 2) {
            for _ in 0..<8 {
                if compactionRow.exists || compactionToggle.exists { break }
                timeline.swipeDown()
            }
        }

        XCTAssertTrue(
            compactionToggle.waitForExistence(timeout: 3),
            "compaction.expand-toggle must exist so expand/collapse can be exercised"
        )
        XCTAssertTrue(
            compactionToggle.label.localizedCaseInsensitiveContains("Expand"),
            "Compaction toggle should start collapsed; label=\(compactionToggle.label)"
        )

        tapElement(compactionToggle)
        waitForToggleLabel(
            compactionToggle,
            containing: "Collapse",
            notContaining: "Expand",
            timeout: 4,
            context: "compaction row expand"
        )
        XCTAssertTrue(
            assertHarnessStillRunning(context: "compaction row expand")
        )

        tapElement(compactionToggle)
        waitForToggleLabel(
            compactionToggle,
            containing: "Expand",
            notContaining: "Collapse",
            timeout: 4,
            context: "compaction row collapse"
        )
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

    // MARK: - Full-screen interaction

    private func fullScreenDismissControl() -> XCUIElement {
        app.descendants(matching: .any)["fullscreen-code.back"].firstMatch
    }

    private func openFullScreenFromExpandedTool(
        rowIdentifier: String,
        contentIdentifier: String?,
        expectedFullscreenContentIdentifier: String?,
        expectedContentSnippet: String
    ) {
        let timeline = app.descendants(matching: .any)["harness.timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 4), "Harness timeline missing before full-screen expand")

        let row = app.descendants(matching: .any)[rowIdentifier].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "Expanded tool row \(rowIdentifier) did not appear")

        let doubleTapTarget: XCUIElement
        if let contentIdentifier {
            let content = app.descendants(matching: .any)[contentIdentifier].firstMatch
            XCTAssertTrue(
                content.waitForExistence(timeout: 4),
                "Expanded content \(contentIdentifier) did not appear"
            )
            doubleTapTarget = content
        } else {
            doubleTapTarget = row
        }

        let dismiss = fullScreenDismissControl()
        XCTAssertFalse(dismiss.exists, "Full-screen viewer was already open before the expand gesture")

        let offsets: [CGVector] = [
            CGVector(dx: 0.50, dy: 0.45),
            CGVector(dx: 0.50, dy: 0.30),
            CGVector(dx: 0.50, dy: 0.62),
            CGVector(dx: 0.35, dy: 0.40),
        ]
        for (index, offset) in offsets.enumerated() where !dismiss.exists {
            doubleTapTarget.coordinate(withNormalizedOffset: offset).doubleTap()
            let timeout: TimeInterval = index == 0 ? 2.5 : 1.2
            if dismiss.waitForExistence(timeout: timeout) { break }
        }

        if !dismiss.exists {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).doubleTap()
            _ = dismiss.waitForExistence(timeout: 1.5)
        }

        // Hosted markdown disables the row double-tap recognizer; context menu
        // is the documented full-screen affordance in that case.
        if !dismiss.exists {
            doubleTapTarget.press(forDuration: 1.1)
            guard let openFullScreen = firstExistingElement(
                named: "Open Full Screen",
                timeout: 3
            ) else {
                XCTFail("Double-tap and context menu both failed to expose Open Full Screen")
                return
            }
            tapElement(openFullScreen)
        }

        XCTAssertTrue(
            dismiss.waitForExistence(timeout: 4),
            "Full-screen viewer did not expose fullscreen-code.back"
        )

        if let expectedFullscreenContentIdentifier {
            XCTAssertTrue(
                app.descendants(matching: .any)[expectedFullscreenContentIdentifier]
                    .firstMatch
                    .waitForExistence(timeout: 4),
                "Intended full-screen content \(expectedFullscreenContentIdentifier) did not appear"
            )
        }

        let snippet = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", expectedContentSnippet)
        ).firstMatch
        XCTAssertTrue(
            snippet.waitForExistence(timeout: 4),
            "Full-screen content snippet '\(expectedContentSnippet)' did not appear"
        )
    }

    private func dismissFullScreenAndReturnToTimeline(
        expectedFullscreenContentIdentifier: String?
    ) {
        let dismiss = fullScreenDismissControl()
        XCTAssertTrue(dismiss.exists, "Full-screen dismiss control missing before tap")
        tapElement(dismiss)

        XCTAssertTrue(
            waitForElementToDisappear(dismiss, timeout: 5),
            "fullscreen-code.back did not disappear after tap"
        )

        if let expectedFullscreenContentIdentifier {
            let body = app.descendants(matching: .any)[expectedFullscreenContentIdentifier].firstMatch
            XCTAssertTrue(
                waitForElementToDisappear(body, timeout: 4),
                "\(expectedFullscreenContentIdentifier) remained after dismiss"
            )
        }

        let timeline = app.descendants(matching: .any)["harness.timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 4), "Timeline did not return after full-screen dismiss")
        XCTAssertTrue(
            timeline.isHittable,
            "Timeline was not hittable after returning from full-screen"
        )
    }

    private func waitForToggleLabel(
        _ toggle: XCUIElement,
        containing needle: String,
        notContaining excluded: String,
        timeout: TimeInterval,
        context: String
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLabel = toggle.label
        while Date() < deadline {
            lastLabel = toggle.label
            if lastLabel.localizedCaseInsensitiveContains(needle),
               !lastLabel.localizedCaseInsensitiveContains(excluded) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail(
            "Compaction toggle did not reach \(context) state. "
            + "Expected label containing '\(needle)' and not '\(excluded)'; last=\(lastLabel)"
        )
    }

    private func firstExistingElement(named title: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = [
                app.buttons[title],
                app.menuItems[title],
                app.staticTexts[title],
                app.descendants(matching: .any)[title],
            ]
            if let match = candidates.first(where: { $0.exists }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}
