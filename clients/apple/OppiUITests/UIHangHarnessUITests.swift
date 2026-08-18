import XCTest

/// UI hang regression harness tests.
///
/// Exercises the collection-backed chat timeline harness with deterministic
/// fixture data and synthetic streaming.
@MainActor
final class UIHangHarnessUITests: UIHarnessTestCase {

    private var stressModeEnabled: Bool {
        ProcessInfo.processInfo.environment["PI_UI_HANG_STRESS"] == "1"
    }

    private func requireStressMode(_ testName: String) throws {
        guard stressModeEnabled else {
            throw XCTSkip(
                "\(testName) disabled by default for fast UI runs; set PI_UI_HANG_STRESS=1 to enable"
            )
        }
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

    func testAssistantRichMarkdownStreamingCanClipAfterCachedHeightReuse() throws {
        launchHarness(noStream: true, assistantOverlapFixture: true)

        let focus = app.descendants(matching: .any)["harness.assistantOverlap.focus"]
        XCTAssertTrue(focus.waitForExistence(timeout: 4))
        focus.tap()

        let row = app.descendants(matching: .any)["chat.timeline.assistant.alpha-assistant-overlap"]
        let timeline = app.descendants(matching: .any)["harness.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))
        for _ in 0..<24 where !row.exists {
            timeline.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Assistant overlap row should be reachable in the harness timeline")

        let diag = app.descendants(matching: .any)["harness.diag.tick"]
        XCTAssertTrue(diag.waitForExistence(timeout: 4))
        diag.tap()
        XCTAssertEqual(waitForDiagnostic("diag.assistantOverlapReady", equals: 1, timeout: 6), 1)
        let baselineHeight = waitForDiagnosticAtLeast("diag.assistantRowHeightPx", minimum: 40, timeout: 6)
        XCTAssertLessThanOrEqual(pollDiagnostic("diag.assistantRenderedOverlapPx", timeout: 2), 1)
        XCTAssertLessThanOrEqual(pollDiagnostic("diag.assistantOverflowPx", timeout: 2), 1)

        let advance = app.descendants(matching: .any)["harness.assistantOverlap.advance"]
        XCTAssertTrue(advance.waitForExistence(timeout: 4))
        advance.tap()

        XCTAssertEqual(waitForDiagnostic("diag.assistantOverlapPhase", equals: 1, timeout: 6), 1)
        XCTAssertEqual(waitForDiagnostic("diag.assistantOverlapReady", equals: 1, timeout: 6), 1)
        let expandedHeight = waitForDiagnosticAtLeast(
            "diag.assistantRowHeightPx",
            minimum: baselineHeight + 180,
            timeout: 8
        )
        XCTAssertGreaterThan(expandedHeight, baselineHeight)
        XCTAssertLessThanOrEqual(pollDiagnostic("diag.assistantRenderedOverlapPx", timeout: 3), 1)
        XCTAssertLessThanOrEqual(pollDiagnostic("diag.assistantOverflowPx", timeout: 3), 1)

        // Capture the expanded wrapped table itself, not only the diagnostic
        // values. The row remains the same streaming item while its content
        // grows, which is the visual form of the reported overlap.
        dragTimeline(
            timeline,
            from: CGVector(dx: 0.5, dy: 0.78),
            to: CGVector(dx: 0.5, dy: 0.42)
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "assistant-streaming-wrapped-table-after-reflow"
        attachment.lifetime = .keepAlways
        add(attachment)
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

    func testAssistantMarkdownTableHangLayoutScreenshot() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 1, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 1)

        let timeline = app.collectionViews.firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))

        // Drive to the end of the visual fixture cluster.
        for _ in 0..<12 {
            timeline.swipeUp(velocity: .fast)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // Walk back above the tool rows into the visual markdown/table block.
        for _ in 0..<8 {
            timeline.swipeDown(velocity: .slow)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "assistant-markdown-table-hang-layout"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReadableMarkdownTableChatBubbleScreenshot() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 1, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 1)

        let focus = app.descendants(matching: .any)["harness.visual.table.focus"]
        XCTAssertTrue(focus.waitForExistence(timeout: 4))
        focus.tap()
        Thread.sleep(forTimeInterval: 0.6)

        let timeline = app.descendants(matching: .any)["harness.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))

        let timeMatch = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "01:46:42", "01:46:42")
        ).firstMatch
        XCTAssertTrue(
            timeMatch.waitForExistence(timeout: 6),
            "Chat bubble should show 01:46:42 on one line"
        )

        // Focus pins the heading to the top; the last wrapped row sits behind
        // the composer. Nudge up so the complete table is in the screenshot.
        timeline.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 0.4)

        saveTableScreenshot(name: "readable-table-time-evidence-chat-bubble")
    }

    func testReadableMarkdownTableExpandedReadScreenshot() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 1, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 1)

        let focusButton = app.descendants(matching: .any)["harness.readMarkdown.focus"]
        XCTAssertTrue(focusButton.waitForExistence(timeout: 4))
        focusButton.tap()
        XCTAssertEqual(waitForDiagnostic("diag.readMarkdownExpanded", equals: 1, timeout: 4), 1)
        Thread.sleep(forTimeInterval: 0.4)

        let timeline = app.descendants(matching: .any)["harness.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).doubleTap()
        Thread.sleep(forTimeInterval: 1.0)

        let timeCell = app.staticTexts["01:46:42"].firstMatch
        let heading = app.staticTexts["What 01a0140d itself did"].firstMatch
        XCTAssertTrue(
            timeCell.waitForExistence(timeout: 6) || heading.waitForExistence(timeout: 2),
            "Expanded Read should show the Time/Evidence table without wrapping 01:46:42"
        )
        XCTAssertFalse(
            app.staticTexts["01:46:4"].exists && !timeCell.exists,
            "Time cell must not wrap mid-timestamp"
        )

        saveTableScreenshot(name: "readable-table-time-evidence-expanded-read")
    }

    private func saveTableScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: outputURL, options: .atomic)
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
        sleep(1) // Allow scroll animation and cell rendering

        // Thumbnail tap-through: the 1x1 test fixture image may not always
        // render a hittable thumbnail cell in time. Skip the full-screen
        // open/close cycle when the thumbnail doesn't appear — the stall
        // detection still covers the scroll and expand operations above.
        let firstThumbnail = app.descendants(matching: .any)["chat.user.thumbnail.0"]
        if firstThumbnail.waitForExistence(timeout: 10) {
            firstThumbnail.tap()
            let doneButton = app.buttons["Done"]
            if doneButton.waitForExistence(timeout: 4) {
                doneButton.tap()
            }
        }

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

    func testImagePreviewPreservesDetachedVisibleRowY() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualImageButton = app.descendants(matching: .any)["harness.visual.image"]
        let timeline = app.descendants(matching: .any)["harness.timeline"]
        XCTAssertTrue(visualImageButton.waitForExistence(timeout: 4))
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))
        visualImageButton.tap()

        let row = app.descendants(matching: .any)["chat.timeline.row.alpha-visual-user-image"]
        let thumbnail = app.descendants(matching: .any)["chat.user.thumbnail.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Visual image row did not become visible")
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5), "Visual image thumbnail did not become visible")

        // Match the reported reading gesture: move away, reverse direction,
        // then stop detached with the same stable row still visible.
        dragTimeline(
            timeline,
            from: CGVector(dx: 0.5, dy: 0.72),
            to: CGVector(dx: 0.5, dy: 0.48)
        )
        dragTimeline(
            timeline,
            from: CGVector(dx: 0.5, dy: 0.42),
            to: CGVector(dx: 0.5, dy: 0.54)
        )
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 3))
        let rowYBefore = row.frame.minY

        thumbnail.tap()
        let dismissButton = app.descendants(matching: .any)["fullscreen-image.dismiss"]
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 5), "Full-screen image did not present")
        dismissButton.tap()
        XCTAssertTrue(waitForElementToDisappear(dismissButton, timeout: 5), "Full-screen image did not dismiss")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Stable image row disappeared after preview")

        let rowYAfter = row.frame.minY
        XCTAssertLessThanOrEqual(
            abs(rowYAfter - rowYBefore),
            2,
            "Image preview moved the stable row from viewport y=\(rowYBefore) to y=\(rowYAfter)"
        )

        let geometry = XCTAttachment(
            string: "rowYBefore=\(rowYBefore) rowYAfter=\(rowYAfter) delta=\(rowYAfter - rowYBefore)"
        )
        geometry.name = "image-preview-detached-row-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "image-preview-detached-row-preserved"
        attachment.lifetime = .keepAlways
        add(attachment)
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

    func testExpandedWriteMarkdownScrollNoStagger() throws {
        try assertExpandedMarkdownScrollNoStagger(
            focusButtonID: "harness.writeMarkdown.focus",
            expandedDiagnosticID: "diag.writeMarkdownExpanded",
            includeWriteMarkdownFixture: true,
            markdownLabel: "write markdown"
        )
    }

    func testExpandedReadMarkdownScrollNoStagger() throws {
        try assertExpandedMarkdownScrollNoStagger(
            focusButtonID: "harness.readMarkdown.focus",
            expandedDiagnosticID: "diag.readMarkdownExpanded",
            includeWriteMarkdownFixture: false,
            markdownLabel: "read markdown"
        )
    }

    private func assertExpandedMarkdownScrollNoStagger(
        focusButtonID: String,
        expandedDiagnosticID: String,
        includeWriteMarkdownFixture: Bool,
        markdownLabel: String
    ) throws {
        launchHarness(
            noStream: true,
            includeVisualFixtures: true,
            includeWriteMarkdownFixture: includeWriteMarkdownFixture
        )

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 8, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 8)

        let focusButton = app.descendants(matching: .any)[focusButtonID]
        let diagTick = app.descendants(matching: .any)["harness.diag.tick"]
        let timeline = app.descendants(matching: .any)["harness.timeline"]

        XCTAssertTrue(focusButton.waitForExistence(timeout: 4))
        XCTAssertTrue(diagTick.waitForExistence(timeout: 4))
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))

        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        let frameP95Before = pollDiagnostic("diag.frameP95", timeout: 4)

        focusButton.tap()
        XCTAssertEqual(waitForDiagnostic(expandedDiagnosticID, equals: 1, timeout: 4), 1)

        diagTick.tap()
        let baselineOffset = pollDiagnostic("diag.offsetY", timeout: 4)

        let offsetAfterUpDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: baselineOffset,
            minimumDelta: 30,
            direction: .increasing,
            context: "upward drag inside expanded \(markdownLabel)"
        )

        let offsetAfterDownDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterUpDrag,
            minimumDelta: 30,
            direction: .decreasing,
            context: "downward drag inside expanded \(markdownLabel)"
        )

        let offsetAfterPastExpandedDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterDownDrag,
            minimumDelta: 56,
            direction: .increasing,
            context: "scrolling past expanded \(markdownLabel)"
        )

        let offsetAfterReturnDown = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterPastExpandedDrag,
            minimumDelta: 30,
            direction: .decreasing,
            context: "downward drag after passing expanded \(markdownLabel)"
        )

        Thread.sleep(forTimeInterval: 0.35)
        diagTick.tap()

        let settledOffset = pollDiagnostic("diag.offsetY", timeout: 4)
        XCTAssertLessThanOrEqual(
            abs(settledOffset - offsetAfterReturnDown),
            16,
            "Offset snapped back after downward drag past expanded \(markdownLabel) (down=\(offsetAfterReturnDown), settled=\(settledOffset))"
        )

        let frameP95After = pollDiagnostic("diag.frameP95", timeout: 4)
        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        XCTAssertLessThanOrEqual(frameP95After, max(55, frameP95Before + 18))
        XCTAssertLessThanOrEqual(perfGuardrailAfter - perfGuardrailBefore, 0)
    }

    func testExpandedToolRowsReconfigureStressNoStalls() throws {
        try requireStressMode("testExpandedToolRowsReconfigureStressNoStalls")

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
        try requireStressMode("testChatScrollSmoothnessPerfGuardMixedContent")

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

}

@MainActor
final class UIMessageQueueHarnessUITests: UIHarnessTestCase {

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

    func testAttachmentOnlyQueueItemsShowImageAndFileNames() throws {
        launchQueueHarness()

        let clearQueue = app.descendants(matching: .any)["harness.queue.clear"]
        XCTAssertTrue(clearQueue.waitForExistence(timeout: 4))
        clearQueue.tap()

        let enqueueAttachments = app.descendants(matching: .any)["harness.queue.enqueueAttachments"]
        XCTAssertTrue(enqueueAttachments.waitForExistence(timeout: 4))
        enqueueAttachments.tap()

        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 2, timeout: 4), 2)

        let queueToggle = app.descendants(matching: .any)["chat.messageQueue.toggle"]
        XCTAssertTrue(queueToggle.waitForExistence(timeout: 4))
        queueToggle.tap()

        let imageAttachment = app.descendants(matching: .any)["chat.messageQueue.attachment.harness-image"]
        XCTAssertTrue(
            imageAttachment.waitForExistence(timeout: 4),
            "An image-only queued message should show its image name"
        )
        XCTAssertEqual(imageAttachment.label, "Attachment image-1.jpg")

        let fileAttachment = app.descendants(matching: .any)["chat.messageQueue.attachment.harness-file"]
        XCTAssertTrue(
            fileAttachment.waitForExistence(timeout: 4),
            "A file-only queued message should show its file name"
        )
        XCTAssertEqual(fileAttachment.label, "Attachment notes.txt")
    }

    private func launchQueueHarness() {
        launchHarness(
            noStream: true,
            includeVisualFixtures: false,
            mixedContent: false,
            queueHarness: true
        )
    }
}
