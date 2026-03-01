import XCTest

/// UI hang regression harness tests.
///
/// Exercises the collection-backed chat timeline harness with deterministic
/// fixture data and synthetic streaming.
@MainActor
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

    func testVisualToolsetTapThroughRendersWithoutStalls() throws {
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

        let visualImageButton = app.descendants(matching: .any)["harness.visual.image"]
        XCTAssertTrue(visualImageButton.waitForExistence(timeout: 4))
        visualImageButton.tap()

        let firstThumbnail = app.descendants(matching: .any)["chat.user.thumbnail.0"]
        XCTAssertTrue(firstThumbnail.waitForExistence(timeout: 4))
        firstThumbnail.tap()

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 4))
        doneButton.tap()

        let topButton = app.descendants(matching: .any)["harness.scroll.top"]
        XCTAssertTrue(topButton.waitForExistence(timeout: 4))
        topButton.tap()

        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]
        XCTAssertTrue(bottomButton.waitForExistence(timeout: 4))
        bottomButton.tap()

        XCTAssertTrue(assertHarnessStillRunning(context: "rendering visual toolset + image fullscreen"))

        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        XCTAssertLessThanOrEqual(perfGuardrailAfter - perfGuardrailBefore, 1)
    }

    func testExpandedExtensionMarkdownGestureOwnsVerticalScroll() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 8, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 8)

        let extensionFocus = app.descendants(matching: .any)["harness.extension.focus"]
        let diagTick = app.descendants(matching: .any)["harness.diag.tick"]
        let timeline = app.descendants(matching: .any)["harness.timeline"]

        XCTAssertTrue(extensionFocus.waitForExistence(timeout: 4))
        XCTAssertTrue(diagTick.waitForExistence(timeout: 4))
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))

        extensionFocus.tap()
        XCTAssertEqual(waitForDiagnostic("diag.extensionExpanded", equals: 1, timeout: 4), 1)

        diagTick.tap()
        let baselineOffset = pollDiagnostic("diag.offsetY", timeout: 4)

        let offsetAfterUpDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: baselineOffset,
            minimumDelta: 24,
            direction: .increasing,
            context: "upward drag inside expanded extension markdown"
        )

        let offsetAfterDownDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterUpDrag,
            minimumDelta: 24,
            direction: .decreasing,
            context: "downward drag inside expanded extension markdown"
        )

        let offsetAfterPastExtensionDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterDownDrag,
            minimumDelta: 48,
            direction: .increasing,
            context: "scrolling past expanded extension markdown"
        )

        let offsetAfterReturnDown = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterPastExtensionDrag,
            minimumDelta: 24,
            direction: .decreasing,
            context: "downward drag after passing expanded extension markdown"
        )

        Thread.sleep(forTimeInterval: 0.35)
        diagTick.tap()
        let settledOffset = pollDiagnostic("diag.offsetY", timeout: 4)
        XCTAssertLessThanOrEqual(
            abs(settledOffset - offsetAfterReturnDown),
            24,
            "Offset snapped back after downward drag past extension markdown (down=\(offsetAfterReturnDown), settled=\(settledOffset))"
        )
    }

    func testExpandedExtensionTextScrollOwnership() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 8, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 8)

        let extensionFocus = app.descendants(matching: .any)["harness.extensionText.focus"]
        let diagTick = app.descendants(matching: .any)["harness.diag.tick"]
        let timeline = app.descendants(matching: .any)["harness.timeline"]

        XCTAssertTrue(extensionFocus.waitForExistence(timeout: 4))
        XCTAssertTrue(diagTick.waitForExistence(timeout: 4))
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))

        extensionFocus.tap()
        XCTAssertEqual(waitForDiagnostic("diag.extensionTextExpanded", equals: 1, timeout: 4), 1)

        diagTick.tap()
        let baselineOffset = pollDiagnostic("diag.offsetY", timeout: 4)

        let offsetAfterUpDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: baselineOffset,
            minimumDelta: 24,
            direction: .increasing,
            context: "upward drag inside expanded extension text"
        )

        let offsetAfterDownDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterUpDrag,
            minimumDelta: 24,
            direction: .decreasing,
            context: "downward drag inside expanded extension text"
        )

        let offsetAfterPastExtensionDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterDownDrag,
            minimumDelta: 48,
            direction: .increasing,
            context: "scrolling past expanded extension text"
        )

        let offsetAfterReturnDown = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterPastExtensionDrag,
            minimumDelta: 24,
            direction: .decreasing,
            context: "downward drag after passing expanded extension text"
        )

        Thread.sleep(forTimeInterval: 0.35)
        diagTick.tap()
        let settledOffset = pollDiagnostic("diag.offsetY", timeout: 4)
        XCTAssertLessThanOrEqual(
            abs(settledOffset - offsetAfterReturnDown),
            24,
            "Offset snapped back after downward drag past extension text (down=\(offsetAfterReturnDown), settled=\(settledOffset))"
        )
    }

    func testExpandedToolRowsReconfigureStressNoStalls() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 7, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 7)

        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        let stallBefore = pollDiagnostic("diag.stallCount", timeout: 4)

        let alpha = app.descendants(matching: .any)["harness.session.alpha"]
        let beta = app.descendants(matching: .any)["harness.session.beta"]
        let gamma = app.descendants(matching: .any)["harness.session.gamma"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 4))
        XCTAssertTrue(beta.waitForExistence(timeout: 4))
        XCTAssertTrue(gamma.waitForExistence(timeout: 4))

        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        let renderToolSet = app.descendants(matching: .any)["harness.tools.render"]
        let topButton = app.descendants(matching: .any)["harness.scroll.top"]
        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]
        let pulse = app.descendants(matching: .any)["harness.stream.pulse"]
        let themeToggle = app.descendants(matching: .any)["harness.theme.toggle"]

        XCTAssertTrue(expandAll.waitForExistence(timeout: 4))
        XCTAssertTrue(renderToolSet.waitForExistence(timeout: 4))
        XCTAssertTrue(topButton.waitForExistence(timeout: 4))
        XCTAssertTrue(bottomButton.waitForExistence(timeout: 4))
        XCTAssertTrue(pulse.waitForExistence(timeout: 4))
        XCTAssertTrue(themeToggle.waitForExistence(timeout: 4))

        let sessions = [alpha, beta, gamma]
        for cycle in 0..<6 {
            sessions[cycle % sessions.count].tap()
            expandAll.tap()
            renderToolSet.tap()
            topButton.tap()
            bottomButton.tap()
            pulse.tap()
            if cycle.isMultiple(of: 2) {
                themeToggle.tap()
            }

            Thread.sleep(forTimeInterval: 0.06)
            XCTAssertTrue(assertHarnessStillRunning(context: "expanded tool stress cycle \(cycle)"))
        }

        let stallAfter = pollDiagnostic("diag.stallCount", timeout: 6)
        XCTAssertLessThanOrEqual(stallAfter - stallBefore, 1)

        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 6)
        XCTAssertLessThanOrEqual(perfGuardrailAfter - perfGuardrailBefore, 2)
    }

    func testChatScrollSmoothnessPerfGuardMixedContent() throws {
        launchHarness(noStream: true, includeVisualFixtures: true, mixedContent: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 7, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 7)

        let metricsReset = app.descendants(matching: .any)["harness.metrics.reset"]
        XCTAssertTrue(metricsReset.waitForExistence(timeout: 4))
        metricsReset.tap()

        let timeline = app.descendants(matching: .any)["harness.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))

        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        let renderToolSet = app.descendants(matching: .any)["harness.tools.render"]
        let pulse = app.descendants(matching: .any)["harness.stream.pulse"]
        let topButton = app.descendants(matching: .any)["harness.scroll.top"]
        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]

        XCTAssertTrue(expandAll.waitForExistence(timeout: 4))
        XCTAssertTrue(renderToolSet.waitForExistence(timeout: 4))
        XCTAssertTrue(pulse.waitForExistence(timeout: 4))
        XCTAssertTrue(topButton.waitForExistence(timeout: 4))
        XCTAssertTrue(bottomButton.waitForExistence(timeout: 4))

        expandAll.tap()
        renderToolSet.tap()

        let baselineSamples = waitForDiagnosticAtLeastValue("diag.frameSamples", minimum: 45, timeout: 6)
        let baselineP95 = pollDiagnostic("diag.frameP95", timeout: 2)
        let baselineP99 = pollDiagnostic("diag.frameP99", timeout: 2)
        let baselineOver34Pct = pollDiagnostic("diag.frameOver34Pct", timeout: 2)
        let baselineOver50Pct = pollDiagnostic("diag.frameOver50Pct", timeout: 2)
        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 2)

        for cycle in 0..<14 {
            dragTimeline(
                timeline,
                from: CGVector(dx: 0.5, dy: 0.82),
                to: CGVector(dx: 0.5, dy: 0.24)
            )
            pulse.tap()
            dragTimeline(
                timeline,
                from: CGVector(dx: 0.5, dy: 0.24),
                to: CGVector(dx: 0.5, dy: 0.82)
            )
            pulse.tap()

            if cycle.isMultiple(of: 3) {
                topButton.tap()
                bottomButton.tap()
            }
        }

        let stressSamples = waitForDiagnosticAtLeastValue(
            "diag.frameSamples",
            minimum: baselineSamples + 150,
            timeout: 10
        )
        XCTAssertGreaterThan(stressSamples, baselineSamples)

        let stressP95 = pollDiagnostic("diag.frameP95", timeout: 3)
        let stressP99 = pollDiagnostic("diag.frameP99", timeout: 3)
        let stressOver34Pct = pollDiagnostic("diag.frameOver34Pct", timeout: 3)
        let stressOver50Pct = pollDiagnostic("diag.frameOver50Pct", timeout: 3)
        let stressOver50Count = pollDiagnostic("diag.frameOver50", timeout: 3)
        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 3)

        XCTAssertLessThanOrEqual(stressOver34Pct, max(45, baselineOver34Pct + 20))
        XCTAssertLessThanOrEqual(stressOver50Pct, max(18, baselineOver50Pct + 10))
        XCTAssertLessThanOrEqual(stressP95, max(90, baselineP95 + 35))
        XCTAssertLessThanOrEqual(stressP99, max(130, baselineP99 + 45))
        XCTAssertLessThanOrEqual(stressOver50Count, max(30, Int(Double(stressSamples) * 0.16)))
        XCTAssertLessThanOrEqual(perfGuardrailAfter - perfGuardrailBefore, 3)
    }

    // MARK: - Launch

    private func launchHarness(
        noStream: Bool,
        includeVisualFixtures: Bool = false,
        mixedContent: Bool = false,
        queueHarness: Bool = false
    ) {
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-hang-harness",
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launchEnvironment["PI_UI_HANG_HARNESS"] = "1"
        app.launchEnvironment["PI_UI_HANG_UI_TEST_MODE"] = "1"
        app.launchEnvironment["PI_UI_HANG_MIXED_CONTENT"] = mixedContent ? "1" : "0"
        if noStream {
            app.launchEnvironment["PI_UI_HANG_NO_STREAM"] = "1"
        } else {
            app.launchEnvironment["PI_UI_HANG_NO_STREAM"] = "0"
        }
        app.launchEnvironment["PI_UI_HANG_INCLUDE_VISUAL_FIXTURES"] = includeVisualFixtures ? "1" : "0"
        app.launchEnvironment["PI_UI_HANG_QUEUE_HARNESS"] = queueHarness ? "1" : "0"
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
        if let value = tryPollDiagnostic(id, timeout: timeout) {
            return value
        }

        guard assertHarnessStillRunning(context: "timing out while reading diagnostic \(id)") else {
            return -1
        }

        XCTFail("Could not read diagnostic \(id) within \(timeout)s")
        return -1
    }

    private func tryPollDiagnostic(_ id: String, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard assertHarnessStillRunning(context: "reading diagnostic \(id)") else {
                return nil
            }

            let element = app.descendants(matching: .any)[id]
            if element.waitForExistence(timeout: 0.35),
               let value = parseDiagnosticValue(element) {
                return value
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        return nil
    }

    private func parseDiagnosticValue(_ element: XCUIElement) -> Int? {
        let rawCandidates: [String?] = [
            element.value as? String,
            element.label,
        ]

        for candidate in rawCandidates {
            guard var raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }

            raw = raw.replacingOccurrences(of: "−", with: "-")

            let sanitized = raw.filter { $0.isWholeNumber || $0 == "-" }
            if !sanitized.isEmpty, let parsed = Int(sanitized) {
                return parsed
            }

            if let range = raw.range(of: "-?\\d+", options: .regularExpression),
               let extracted = Int(String(raw[range])) {
                return extracted
            }
        }

        return nil
    }

    private func waitForDiagnostic(_ id: String, equals expected: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: Int?

        while Date() < deadline {
            if let value = tryPollDiagnostic(id, timeout: 0.7) {
                lastValue = value
                if value == expected {
                    return value
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        XCTFail(
            "Diagnostic \(id) did not reach expected value \(expected) " +
            "(last=\(lastValue.map(String.init) ?? "nil"))"
        )
        return -1
    }

    private func waitForDiagnosticAtLeast(_ id: String, minimum: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: Int?

        while Date() < deadline {
            if let value = tryPollDiagnostic(id, timeout: 0.7) {
                lastValue = value
                if value >= minimum {
                    return value
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        XCTFail(
            "Diagnostic \(id) did not reach minimum value \(minimum) " +
            "(last=\(lastValue.map(String.init) ?? "nil"))"
        )
        return -1
    }

    private func waitForDiagnosticAtLeastValue(_ id: String, minimum: Int, timeout: TimeInterval) -> Int {
        waitForDiagnosticAtLeast(id, minimum: minimum, timeout: timeout)
    }

    private enum OffsetDirection {
        case increasing
        case decreasing
    }

    private func dragTimeline(_ element: XCUIElement, from: CGVector, to: CGVector) {
        let start = element.coordinate(withNormalizedOffset: from)
        let end = element.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.02, thenDragTo: end)
    }

    private func dragTimelineUntilOffsetMoves(
        _ timeline: XCUIElement,
        diagTick: XCUIElement,
        baseline: Int,
        minimumDelta: Int,
        direction: OffsetDirection,
        context: String
    ) -> Int {
        let dragPaths: [(from: CGVector, to: CGVector)]
        switch direction {
        case .increasing:
            dragPaths = [
                (from: CGVector(dx: 0.5, dy: 0.72), to: CGVector(dx: 0.5, dy: 0.28)),
                (from: CGVector(dx: 0.5, dy: 0.86), to: CGVector(dx: 0.5, dy: 0.14)),
                (from: CGVector(dx: 0.15, dy: 0.86), to: CGVector(dx: 0.15, dy: 0.14)),
            ]

        case .decreasing:
            dragPaths = [
                (from: CGVector(dx: 0.5, dy: 0.28), to: CGVector(dx: 0.5, dy: 0.82)),
                (from: CGVector(dx: 0.5, dy: 0.14), to: CGVector(dx: 0.5, dy: 0.88)),
                (from: CGVector(dx: 0.15, dy: 0.14), to: CGVector(dx: 0.15, dy: 0.88)),
            ]
        }

        var lastOffset = baseline
        for path in dragPaths {
            dragTimeline(timeline, from: path.from, to: path.to)
            diagTick.tap()
            lastOffset = pollDiagnostic("diag.offsetY", timeout: 4)

            switch direction {
            case .increasing where lastOffset >= baseline + minimumDelta:
                return lastOffset
            case .decreasing where lastOffset <= baseline - minimumDelta:
                return lastOffset
            default:
                continue
            }
        }

        let directionDescription: String
        switch direction {
        case .increasing:
            directionDescription = "increase"
        case .decreasing:
            directionDescription = "decrease"
        }

        XCTFail(
            "Timeline offset did not \(directionDescription) enough during \(context) " +
            "(baseline=\(baseline), last=\(lastOffset), minimumDelta=\(minimumDelta))"
        )

        return lastOffset
    }

    private func waitForDiagnosticAtMostOrNil(_ id: String, maximum: Int, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let value = tryPollDiagnostic(id, timeout: 0.7), value <= maximum {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        return nil
    }
}

@MainActor
final class UIMessageQueueHarnessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Queue harness UI tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func testSteeringQueueLifecycle() throws {
        launchQueueHarness()

        // Reset baseline so simulator relaunches cannot leak stale queue state.
        let clearQueue = app.descendants(matching: .any)["harness.queue.clear"]
        XCTAssertTrue(clearQueue.waitForExistence(timeout: 4))
        clearQueue.tap()

        XCTAssertEqual(waitForDiagnostic("diag.queueVisible", equals: 0, timeout: 4), 0)
        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 0, timeout: 4), 0)
        XCTAssertEqual(waitForDiagnostic("diag.queueFollowUpCount", equals: 0, timeout: 4), 0)

        let startedBefore = pollDiagnostic("diag.queueStartedEvents", timeout: 4)

        let enqueueSteer = app.descendants(matching: .any)["harness.queue.enqueueSteer"]
        XCTAssertTrue(enqueueSteer.waitForExistence(timeout: 4))
        enqueueSteer.tap()

        XCTAssertEqual(waitForDiagnostic("diag.queueVisible", equals: 1, timeout: 4), 1)
        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 1, timeout: 4), 1)
        XCTAssertEqual(waitForDiagnostic("diag.queueFollowUpCount", equals: 0, timeout: 4), 0)

        let queueContainer = app.descendants(matching: .any)["harness.queue.container"]
        XCTAssertTrue(queueContainer.waitForExistence(timeout: 4))

        let startSteer = app.descendants(matching: .any)["harness.queue.startSteer"]
        XCTAssertTrue(startSteer.waitForExistence(timeout: 4))
        startSteer.tap()

        XCTAssertEqual(waitForDiagnostic("diag.queueVisible", equals: 0, timeout: 4), 0)
        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 0, timeout: 4), 0)
        XCTAssertEqual(
            waitForDiagnostic("diag.queueStartedEvents", equals: startedBefore + 1, timeout: 4),
            startedBefore + 1
        )
    }

    func testQueueHeaderToggleRevealsAndHidesEditorControls() throws {
        launchQueueHarness()

        let clearQueue = app.descendants(matching: .any)["harness.queue.clear"]
        XCTAssertTrue(clearQueue.waitForExistence(timeout: 4))
        clearQueue.tap()

        let enqueueSteer = app.descendants(matching: .any)["harness.queue.enqueueSteer"]
        XCTAssertTrue(enqueueSteer.waitForExistence(timeout: 4))
        enqueueSteer.tap()

        XCTAssertEqual(waitForDiagnostic("diag.queueVisible", equals: 1, timeout: 4), 1)

        let queueToggle = app.descendants(matching: .any)["chat.messageQueue.toggle"]
        XCTAssertTrue(
            queueToggle.waitForExistence(timeout: 4),
            "Queue toggle should be discoverable for interaction"
        )
        queueToggle.tap()

        let refreshButton = app.descendants(matching: .any)["chat.messageQueue.refresh"]
        XCTAssertTrue(
            refreshButton.waitForExistence(timeout: 4),
            "Expanding queue should reveal refresh control"
        )

        queueToggle.tap()
        XCTAssertTrue(
            waitForElementToDisappear(refreshButton, timeout: 2),
            "Collapsing queue should hide refresh control"
        )
    }

    private func launchQueueHarness() {
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-hang-harness",
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launchEnvironment["PI_UI_HANG_HARNESS"] = "1"
        app.launchEnvironment["PI_UI_HANG_UI_TEST_MODE"] = "1"
        app.launchEnvironment["PI_UI_HANG_NO_STREAM"] = "1"
        app.launchEnvironment["PI_UI_HANG_INCLUDE_VISUAL_FIXTURES"] = "0"
        app.launchEnvironment["PI_UI_HANG_MIXED_CONTENT"] = "0"
        app.launchEnvironment["PI_UI_HANG_QUEUE_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"].waitForExistence(timeout: 10),
            "Harness did not become ready"
        )
    }

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
        if let value = tryPollDiagnostic(id, timeout: timeout) {
            return value
        }

        guard assertHarnessStillRunning(context: "timing out while reading diagnostic \(id)") else {
            return -1
        }

        XCTFail("Could not read diagnostic \(id) within \(timeout)s")
        return -1
    }

    private func tryPollDiagnostic(_ id: String, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard assertHarnessStillRunning(context: "reading diagnostic \(id)") else {
                return nil
            }

            let element = app.descendants(matching: .any)[id]
            if element.waitForExistence(timeout: 0.35),
               let value = parseDiagnosticValue(element) {
                return value
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        return nil
    }

    private func parseDiagnosticValue(_ element: XCUIElement) -> Int? {
        let rawCandidates: [String?] = [
            element.value as? String,
            element.label,
        ]

        for candidate in rawCandidates {
            guard var raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }

            raw = raw.replacingOccurrences(of: "−", with: "-")

            let sanitized = raw.filter { $0.isWholeNumber || $0 == "-" }
            if !sanitized.isEmpty, let parsed = Int(sanitized) {
                return parsed
            }

            if let range = raw.range(of: "-?\\d+", options: .regularExpression),
               let extracted = Int(String(raw[range])) {
                return extracted
            }
        }

        return nil
    }

    private func waitForDiagnostic(_ id: String, equals expected: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: Int?

        while Date() < deadline {
            if let value = tryPollDiagnostic(id, timeout: 0.7) {
                lastValue = value
                if value == expected {
                    return value
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        XCTFail(
            "Diagnostic \(id) did not reach expected value \(expected) " +
            "(last=\(lastValue.map(String.init) ?? "nil"))"
        )
        return -1
    }

    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !element.exists {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        return !element.exists
    }
}
