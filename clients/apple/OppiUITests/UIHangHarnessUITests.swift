import XCTest

/// UI hang regression harness tests.
///
/// Exercises the collection-backed chat timeline harness with deterministic
/// fixture data and synthetic streaming.
@MainActor
final class UIHangHarnessUITests: UIHarnessTestCase {
    /// Every test drives harness screens only; the app keeps one launch per launch configuration.
    override class var reusesLaunch: Bool { true }

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

    private func enableBusyStreaming() {
        let streamToggle = app.descendants(matching: .any)["harness.stream.toggle"]
        XCTAssertTrue(streamToggle.waitUntilExists(timeout: 4))
        streamToggle.tap()
        XCTAssertEqual(waitForDiagnostic("diag.isBusy", equals: 1, timeout: 4), 1)
        XCTAssertEqual(waitForDiagnostic("diag.streaming", equals: 1, timeout: 4), 1)
    }

    private func reachDetachedScrolledUpState() {
        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        XCTAssertTrue(expandAll.waitUntilExists(timeout: 4))
        expandAll.tap()

        let topButton = app.descendants(matching: .any)["harness.scroll.top"]
        XCTAssertTrue(topButton.waitUntilExists(timeout: 4))
        topButton.tap()

        let timeline = app.descendants(matching: .any)["harness.timeline"]
        let diagTick = app.descendants(matching: .any)["harness.diag.tick"]
        XCTAssertTrue(timeline.waitUntilExists(timeout: 4))
        XCTAssertTrue(diagTick.waitUntilExists(timeout: 4))

        let deadline = Date().addingTimeInterval(8)
        var lastTop: Int?
        var lastNear: Int?
        while Date() < deadline {
            diagTick.tap()
            lastTop = tryPollDiagnostic("diag.topIndex", timeout: 0.3)
            lastNear = tryPollDiagnostic("diag.nearBottom", timeout: 0.3)
            if let top = lastTop, (0...3).contains(top), lastNear == 0 {
                return
            }
            dragTimeline(
                timeline,
                from: CGVector(dx: 0.5, dy: 0.22),
                to: CGVector(dx: 0.5, dy: 0.88)
            )
        }

        XCTFail(
            "Opted-in yank test did not reach a scrolled-up detached state " +
            "(topIndex=\(lastTop.map(String.init) ?? "nil"), nearBottom=\(lastNear.map(String.init) ?? "nil"))"
        )
    }

    private func reachAttachedBottomState() {
        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]
        XCTAssertTrue(bottomButton.waitUntilExists(timeout: 4))
        bottomButton.tap()

        let timeline = app.descendants(matching: .any)["harness.timeline"]
        let diagTick = app.descendants(matching: .any)["harness.diag.tick"]
        XCTAssertTrue(timeline.waitUntilExists(timeout: 4))
        XCTAssertTrue(diagTick.waitUntilExists(timeout: 4))

        let deadline = Date().addingTimeInterval(8)
        var lastNear: Int?
        while Date() < deadline {
            diagTick.tap()
            lastNear = tryPollDiagnostic("diag.nearBottom", timeout: 0.3)
            if lastNear == 1 {
                return
            }
            dragTimeline(
                timeline,
                from: CGVector(dx: 0.5, dy: 0.82),
                to: CGVector(dx: 0.5, dy: 0.18)
            )
        }

        XCTFail(
            "Opted-in pin test did not reach an attached near-bottom state " +
            "(nearBottom=\(lastNear.map(String.init) ?? "nil"))"
        )
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

        XCTAssertTrue(alpha.waitUntilExists(timeout: 4))
        XCTAssertTrue(beta.waitUntilExists(timeout: 4))
        XCTAssertTrue(gamma.waitUntilExists(timeout: 4))

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
        XCTAssertTrue(focus.waitUntilExists(timeout: 4))
        focus.tap()

        let row = app.descendants(matching: .any)["chat.timeline.assistant.alpha-assistant-overlap"]
        let timeline = app.descendants(matching: .any)["harness.timeline"]
        XCTAssertTrue(timeline.waitUntilExists(timeout: 4))
        for _ in 0..<24 where !row.exists {
            timeline.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(row.waitUntilExists(timeout: 3), "Assistant overlap row should be reachable in the harness timeline")

        let diag = app.descendants(matching: .any)["harness.diag.tick"]
        XCTAssertTrue(diag.waitUntilExists(timeout: 4))
        diag.tap()
        XCTAssertEqual(waitForDiagnostic("diag.assistantOverlapReady", equals: 1, timeout: 6), 1)
        let baselineHeight = waitForDiagnosticAtLeast("diag.assistantRowHeightPx", minimum: 40, timeout: 6)
        XCTAssertLessThanOrEqual(pollDiagnostic("diag.assistantRenderedOverlapPx", timeout: 2), 1)
        XCTAssertLessThanOrEqual(pollDiagnostic("diag.assistantOverflowPx", timeout: 2), 1)

        let advance = app.descendants(matching: .any)["harness.assistantOverlap.advance"]
        XCTAssertTrue(advance.waitUntilExists(timeout: 4))
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

        launchHarness(noStream: true, realBusyLane: true)
        reachAttachedBottomState()
        enableBusyStreaming()
        XCTAssertEqual(
            waitForDiagnostic("diag.nearBottom", equals: 1, timeout: 6),
            1,
            "Busy streaming must keep the already-attached bottom pin"
        )

        let pulse = app.descendants(matching: .any)["harness.stream.pulse"]
        XCTAssertTrue(pulse.waitUntilExists(timeout: 4))

        let topBefore = pollDiagnostic("diag.topIndex", timeout: 4)
        XCTAssertGreaterThanOrEqual(topBefore, 0)

        let tickBefore = pollDiagnostic("diag.streamTick", timeout: 4)
        let charsBefore = pollDiagnostic("diag.streamChars", timeout: 2)
        pulse.tap()

        let tickAfter = waitForDiagnosticAtLeast("diag.streamTick", minimum: tickBefore + 1, timeout: 4)
        XCTAssertGreaterThan(tickAfter, tickBefore)
        XCTAssertGreaterThan(
            waitForDiagnosticAtLeast("diag.streamChars", minimum: charsBefore + 1, timeout: 4),
            charsBefore
        )

        XCTAssertEqual(pollDiagnostic("diag.nearBottom", timeout: 4), 1)
        let topAfter = pollDiagnostic("diag.topIndex", timeout: 4)
        XCTAssertGreaterThanOrEqual(topAfter, topBefore - 2)
    }

    func testStreamingDoesNotYankWhenScrolledUp() throws {
        if ProcessInfo.processInfo.environment["PI_UI_HANG_ENABLE_SCROLL_YANK_TEST"] != "1" {
            throw XCTSkip("Scroll-yank harness assertion disabled by default; opt in with PI_UI_HANG_ENABLE_SCROLL_YANK_TEST=1")
        }

        launchHarness(noStream: true, realBusyLane: true)
        reachDetachedScrolledUpState()
        enableBusyStreaming()
        XCTAssertEqual(
            waitForDiagnostic("diag.nearBottom", equals: 0, timeout: 6),
            0,
            "Busy streaming must keep the already-detached scrolled-up state"
        )

        let pulse = app.descendants(matching: .any)["harness.stream.pulse"]
        XCTAssertTrue(pulse.waitUntilExists(timeout: 4))

        let row = app.descendants(matching: .any)["chat.timeline.row.alpha-u-1"]
        XCTAssertTrue(
            row.waitUntilExists(timeout: 5),
            "Opted-in yank test must show the scrolled-up user row"
        )
        let glyph = row.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Alpha prompt 1:",
                "Alpha prompt 1:"
            )
        ).firstMatch
        XCTAssertTrue(
            glyph.waitUntilExists(timeout: 5),
            "Opted-in yank test must show the scrolled-up prompt glyph"
        )
        let rowYBefore = row.frame.minY
        let glyphYBefore = glyph.frame.minY

        let tickBefore = pollDiagnostic("diag.streamTick", timeout: 2)
        let charsBefore = pollDiagnostic("diag.streamChars", timeout: 2)

        pulse.tap()
        pulse.tap()
        pulse.tap()

        XCTAssertGreaterThan(
            waitForDiagnosticAtLeast("diag.streamTick", minimum: tickBefore + 1, timeout: 4),
            tickBefore
        )
        XCTAssertGreaterThan(
            waitForDiagnosticAtLeast("diag.streamChars", minimum: charsBefore + 1, timeout: 4),
            charsBefore
        )

        XCTAssertTrue(row.waitUntilExists(timeout: 3), "Visible row identity disappeared after stream pulse")
        XCTAssertTrue(glyph.waitUntilExists(timeout: 3), "Visible glyph disappeared after stream pulse")
        let rowYAfter = row.frame.minY
        let glyphYAfter = glyph.frame.minY
        XCTAssertLessThanOrEqual(
            abs(rowYAfter - rowYBefore),
            2,
            "Streaming yank moved the stable row from viewport y=\(rowYBefore) to y=\(rowYAfter)"
        )
        XCTAssertLessThanOrEqual(
            abs(glyphYAfter - glyphYBefore),
            2,
            "Streaming yank moved the stable glyph from viewport y=\(glyphYBefore) to y=\(glyphYAfter)"
        )
        XCTAssertEqual(pollDiagnostic("diag.nearBottom", timeout: 4), 0)

        let geometry = XCTAttachment(
            string: "rowYBefore=\(rowYBefore) rowYAfter=\(rowYAfter) glyphYBefore=\(glyphYBefore) glyphYAfter=\(glyphYAfter)"
        )
        geometry.name = "streaming-yank-detached-row-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
    }

    func testThemeToggleAndKeyboardDuringStreamingNoStalls() throws {
        launchHarness(noStream: true)

        let streamToggle = app.descendants(matching: .any)["harness.stream.toggle"]
        XCTAssertTrue(streamToggle.waitUntilExists(timeout: 4))
        streamToggle.tap()

        let pulse = app.descendants(matching: .any)["harness.stream.pulse"]
        XCTAssertTrue(pulse.waitUntilExists(timeout: 4))
        pulse.tap()

        let hbBefore = pollDiagnostic("diag.heartbeat", timeout: 6)
        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        let themeToggle = app.descendants(matching: .any)["harness.theme.toggle"]
        XCTAssertTrue(themeToggle.waitUntilExists(timeout: 4))
        themeToggle.tap()

        let input = app.textFields["harness.input"]
        XCTAssertTrue(input.waitUntilExists(timeout: 4))
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
        XCTAssertTrue(expandAll.waitUntilExists(timeout: 4))
        expandAll.tap()

        let renderToolSet = app.descendants(matching: .any)["harness.tools.render"]
        XCTAssertTrue(renderToolSet.waitUntilExists(timeout: 4))
        renderToolSet.tap()

        let visualImageButton = app.descendants(matching: .any)["harness.visual.image"]
        XCTAssertTrue(visualImageButton.waitUntilExists(timeout: 4))
        visualImageButton.tap()
        sleep(1) // Allow scroll animation and cell rendering

        // Thumbnail tap-through: a user photo opens the pushed chat reader
        // (as in a real chat), and its back button returns to the timeline.
        let firstThumbnail = app.descendants(matching: .any)["chat.user.thumbnail.0"]
        XCTAssertTrue(firstThumbnail.waitUntilExists(timeout: 10), "Visual image thumbnail did not become visible")
        firstThumbnail.tap()
        let readerBack = app.descendants(matching: .any)["fullscreen-image.back"]
        XCTAssertTrue(readerBack.waitUntilExists(timeout: 5), "Image reader did not open")
        readerBack.tap()
        XCTAssertTrue(waitForElementToDisappear(readerBack, timeout: 5), "Image reader did not close")

        let topButton = app.descendants(matching: .any)["harness.scroll.top"]
        XCTAssertTrue(topButton.waitUntilExists(timeout: 4))
        topButton.tap()

        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]
        XCTAssertTrue(bottomButton.waitUntilExists(timeout: 4))
        bottomButton.tap()

        XCTAssertTrue(assertHarnessStillRunning(context: "rendering visual toolset + image fullscreen"))

        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        let applyMax = pollDiagnostic("diag.applyMax", timeout: 2)
        let layoutMax = pollDiagnostic("diag.layoutMax", timeout: 2)
        let cellMax = pollDiagnostic("diag.cellMax", timeout: 2)
        let breaches = perfGuardrailAfter - perfGuardrailBefore
        let summary = "guardrail breaches=\(breaches) applyMax=\(applyMax)ms layoutMax=\(layoutMax)ms cellMax=\(cellMax)ms"
        let maxima = XCTAttachment(string: summary)
        maxima.name = "toolset-guardrail-maxima"
        maxima.lifetime = .keepAlways
        add(maxima)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // A 13-inch viewport builds all nine ToolSet rows, so this flow really renders
            // them expanded; before the reconfigure fix these rows never expanded on iPad
            // (main read 0 breaches, layoutMax 10 ms). Three costs are inherent to that
            // and are bounded here by what was measured with about 2x margin, instead of
            // by the breach count: the runs breached 1 to 3 times, so any count limit that
            // passes them is either flaky or no bound at all:
            //   - the ToolSet apply, 9 cell configures in one pass (apply 247-326 ms in 12
            //     runs at host load 5-27), bounded at 600 ms;
            //   - the Read markdown row's expanded layout, about 110 ms alone now that the
            //     inline reader lays out one viewport of text instead of the whole 8 KB
            //     document (it was 335 ms); layout 228-269 ms in 6 runs at host load 5-27,
            //     bounded at 400 ms, so a revert of the trim (layout 483-495 ms) fails;
            //   - one slow cell configure (cell 58-101 ms in 6 runs), bounded at 200 ms.
            // Any larger stall, or a different one, still fails.
            XCTAssertLessThanOrEqual(applyMax, 600, "ToolSet apply stalled: \(summary)")
            XCTAssertLessThanOrEqual(layoutMax, 400, "Expanded-row layout stalled: \(summary)")
            XCTAssertLessThanOrEqual(cellMax, 200, "Cell configure stalled: \(summary)")
        } else {
            XCTAssertLessThanOrEqual(breaches, 1, summary)
        }
    }

    func testImagePreviewPreservesDetachedVisibleRowY() throws {
        launchHarness(noStream: true, includeVisualFixtures: true)

        let visualImageButton = app.descendants(matching: .any)["harness.visual.image"]
        let timeline = app.descendants(matching: .any)["harness.timeline"]
        XCTAssertTrue(visualImageButton.waitUntilExists(timeout: 4))
        XCTAssertTrue(timeline.waitUntilExists(timeout: 4))
        visualImageButton.tap()

        let row = app.descendants(matching: .any)["chat.timeline.row.alpha-visual-user-image"]
        let thumbnail = app.descendants(matching: .any)["chat.user.thumbnail.0"]
        XCTAssertTrue(row.waitUntilExists(timeout: 5), "Visual image row did not become visible")
        XCTAssertTrue(thumbnail.waitUntilExists(timeout: 5), "Visual image thumbnail did not become visible")

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
        XCTAssertTrue(row.waitUntilExists(timeout: 3))
        XCTAssertTrue(thumbnail.waitUntilExists(timeout: 3))
        // Measured inside the timeline: the router shows its navigation bar again
        // when the reader pops, which moves the harness chrome but not the viewport.
        let rowYBefore = row.frame.minY - timeline.frame.minY

        // A user photo opens the pushed chat reader; Back must land on the same viewport.
        thumbnail.tap()
        let readerBack = app.descendants(matching: .any)["fullscreen-image.back"]
        XCTAssertTrue(readerBack.waitUntilExists(timeout: 5), "Image reader did not open")
        readerBack.tap()
        XCTAssertTrue(waitForElementToDisappear(readerBack, timeout: 5), "Image reader did not close")
        XCTAssertTrue(row.waitUntilExists(timeout: 5), "Stable image row disappeared after preview")

        let rowYAfter = row.frame.minY - timeline.frame.minY
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

    /// Re-reads the timeline offset until two fresh readings agree and at least the
    /// 0.35 s snap-back window has passed since the drag, so the snap-back
    /// assertions compare against the resting offset instead of one sampled a fixed
    /// time after the drag. Fails if the offset keeps moving for the whole timeout.
    /// A tap plus a read can itself take seconds on a loaded machine, so the timeout
    /// only counts once three readings (two comparisons) have been taken.
    private func waitForTimelineOffsetToRest(
        diagTick: XCUIElement,
        minimumWindow: TimeInterval = 0.35,
        timeout: TimeInterval = 6
    ) -> Int {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var previous: Int?
        var readings = 0
        while true {
            tapHarnessControl(diagTick)
            let reading = pollDiagnostic("diag.offsetY", timeout: 4)
            readings += 1
            if reading == previous, Date().timeIntervalSince(start) >= minimumWindow { return reading }
            if Date() >= deadline, readings >= 3 {
                XCTFail("Timeline offset did not come to rest within \(timeout)s (last=\(reading), previous=\(previous.map(String.init) ?? "nil"), readings=\(readings))")
                return reading
            }
            previous = reading
        }
    }

    /// The timeline's offset once the expanded row has finished self-sizing: the
    /// same offset *and* the same on-screen row frame for a whole `minimumWindow`,
    /// counted from the last change of either.
    ///
    /// A repeat of one offset reading is too weak here. The row's final height
    /// starts a top-anchored correction after the first readings match, and a drag
    /// taken before it lands measures that correction instead of itself: on iPad
    /// the offset then moved +183 pt against a downward drag
    /// (`testExpandedExtensionTextScrollOwnership`).
    ///
    /// A change seen more than `restBound` after the row painted fails: content
    /// that moves under the person's finger is a bug, not something to wait out.
    /// The bound is on movement, not on the wait, because each reading is two
    /// XCUITest queries and a loaded lane makes them slow without the row moving.
    private func waitForExpandedRowAtRest(
        diagTick: XCUIElement,
        row: XCUIElement,
        minimumWindow: TimeInterval = 1,
        restBound: TimeInterval = 3,
        timeout: TimeInterval = 8
    ) -> Int {
        XCTAssertTrue(row.exists, "The expanded row is not realized")
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var previousOffset: Int?
        var previousFrame: CGRect?
        var lastChangeAt = start
        var readings = 0
        while true {
            tapHarnessControl(diagTick)
            let now = Date()
            let offset = pollDiagnostic("diag.offsetY", timeout: 4)
            let frame = row.frame
            readings += 1
            if offset != previousOffset || frame != previousFrame {
                if now.timeIntervalSince(start) > restBound {
                    XCTFail(
                        "The expanded row was still moving "
                            + "\(now.timeIntervalSince(start))s after it painted (bound \(restBound)s): "
                            + "the content moves under the finger"
                    )
                }
                lastChangeAt = now
            } else if row.exists, now.timeIntervalSince(lastChangeAt) >= minimumWindow {
                return offset
            }
            if now >= deadline, readings >= 3 {
                XCTFail(
                    "The expanded row did not come to rest within \(timeout)s "
                        + "(offset=\(offset), previous=\(previousOffset.map(String.init) ?? "nil"), "
                        + "frame=\(frame), previousFrame=\(previousFrame.map(String.init(describing:)) ?? "nil"), "
                        + "readings=\(readings))"
                )
                return offset
            }
            previousOffset = offset
            previousFrame = frame
        }
    }

    /// Scrolls the visual fixture rows into view before a focus button expands one of
    /// them. A tall iPad viewport then holds every fixture row as a built cell, which
    /// is the state where an expansion change must reconfigure a row instead of
    /// reaching it only when it is first built.
    private func revealVisualFixtureRows() {
        let tableFocus = app.descendants(matching: .any)["harness.visual.table.focus"]
        tapHarnessControl(tableFocus)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    /// The realized row of `itemID`, once its own header reports `Expanded` and it is
    /// the top visible row. `diag.*Expanded` reads the reducer, not the cell, so the
    /// header's accessibility value is what proves the row painted expanded.
    private func expandedTopRow(itemID: String, topDiagnostic: String, diagTick: XCUIElement) -> XCUIElement {
        let header = app.descendants(matching: .any)["chat.timeline.row.\(itemID).header"]
        XCTAssertTrue(header.waitUntilExists(timeout: 4), "Header for \(itemID) is not on screen")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, (header.value as? String)?.contains("Expanded") != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            (header.value as? String)?.contains("Expanded") == true,
            "Row \(itemID) did not paint expanded (header value=\(String(describing: header.value)))"
        )
        diagTick.tap()
        XCTAssertEqual(waitForDiagnostic(topDiagnostic, equals: 1, timeout: 4), 1)
        let row = app.descendants(matching: .any)["chat.timeline.row.\(itemID)"]
        XCTAssertTrue(row.exists, "Row \(itemID) is not realized")
        return row
    }

    func testExpandedExtensionMarkdownGestureOwnsVerticalScroll() throws {
        // The focused row scrolls to the viewport top, so enough rows must follow it
        // for an iPad-height viewport to still have room to drag the timeline.
        launchHarness(noStream: true, includeVisualFixtures: true, tailFillerRows: 30)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 8, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 8)

        let extensionFocus = app.descendants(matching: .any)["harness.extension.focus"]
        let diagTick = app.descendants(matching: .any)["harness.diag.tick"]
        let timeline = app.descendants(matching: .any)["harness.timeline"]

        XCTAssertTrue(extensionFocus.waitUntilExists(timeout: 4))
        XCTAssertTrue(diagTick.waitUntilExists(timeout: 4))
        XCTAssertTrue(timeline.waitUntilExists(timeout: 4))

        revealVisualFixtureRows()
        extensionFocus.tap()
        XCTAssertEqual(waitForDiagnostic("diag.extensionExpanded", equals: 1, timeout: 4), 1)
        let extensionRow = expandedTopRow(
            itemID: "alpha-visual-tool-extension-b",
            topDiagnostic: "diag.extensionTop",
            diagTick: diagTick
        )

        // The top-anchored scroll keeps adjusting the offset while the expanded row
        // self-sizes; a baseline read before that settles is not a baseline.
        let baselineOffset = waitForTimelineOffsetToRest(diagTick: diagTick)

        // Both drags start on the expanded row, so the row must stay on screen between
        // them: drag toward earlier content first (the row moves down, away from the top
        // edge), then back. The reverse order can fling a short row out of the viewport.
        let offsetAfterDownDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: baselineOffset,
            minimumDelta: 24,
            direction: .decreasing,
            context: "downward drag inside expanded extension markdown",
            startingInside: extensionRow
        )

        let offsetAfterUpDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterDownDrag,
            minimumDelta: 24,
            direction: .increasing,
            context: "upward drag inside expanded extension markdown",
            startingInside: extensionRow
        )

        let offsetAfterPastExtensionDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterUpDrag,
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

        let settledOffset = waitForTimelineOffsetToRest(diagTick: diagTick)
        XCTAssertLessThanOrEqual(
            abs(settledOffset - offsetAfterReturnDown),
            24,
            "Offset snapped back after downward drag past extension markdown (down=\(offsetAfterReturnDown), settled=\(settledOffset))"
        )
    }

    func testExpandedExtensionTextScrollOwnership() throws {
        // See testExpandedExtensionMarkdownGestureOwnsVerticalScroll.
        launchHarness(noStream: true, includeVisualFixtures: true, tailFillerRows: 30)

        let visualTools = waitForDiagnosticAtLeast("diag.visualTools", minimum: 8, timeout: 6)
        XCTAssertGreaterThanOrEqual(visualTools, 8)

        let extensionFocus = app.descendants(matching: .any)["harness.extensionText.focus"]
        let diagTick = app.descendants(matching: .any)["harness.diag.tick"]
        let timeline = app.descendants(matching: .any)["harness.timeline"]

        XCTAssertTrue(extensionFocus.waitUntilExists(timeout: 4))
        XCTAssertTrue(diagTick.waitUntilExists(timeout: 4))
        XCTAssertTrue(timeline.waitUntilExists(timeout: 4))

        revealVisualFixtureRows()
        extensionFocus.tap()
        XCTAssertEqual(waitForDiagnostic("diag.extensionTextExpanded", equals: 1, timeout: 4), 1)
        let extensionRow = expandedTopRow(
            itemID: "alpha-visual-tool-extension-a",
            topDiagnostic: "diag.extensionTextTop",
            diagTick: diagTick
        )

        // The row's final height starts a top-anchored correction after the offset
        // first holds still; a baseline read before that lands is not a baseline.
        let baselineOffset = waitForExpandedRowAtRest(diagTick: diagTick, row: extensionRow)

        // Both drags start on the expanded row, so the row must stay on screen between
        // them: drag toward earlier content first (the row moves down, away from the top
        // edge), then back. The reverse order can fling a short row out of the viewport.
        let offsetAfterDownDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: baselineOffset,
            minimumDelta: 24,
            direction: .decreasing,
            context: "downward drag inside expanded extension text",
            startingInside: extensionRow
        )

        let offsetAfterUpDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterDownDrag,
            minimumDelta: 24,
            direction: .increasing,
            context: "upward drag inside expanded extension text",
            startingInside: extensionRow
        )

        let offsetAfterPastExtensionDrag = dragTimelineUntilOffsetMoves(
            timeline,
            diagTick: diagTick,
            baseline: offsetAfterUpDrag,
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

        let settledOffset = waitForTimelineOffsetToRest(diagTick: diagTick)
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

        XCTAssertTrue(diagTick.waitUntilExists(timeout: 4))
        XCTAssertTrue(timeline.waitUntilExists(timeout: 4))

        tapHarnessControl(focusButton)
        XCTAssertEqual(waitForDiagnostic(expandedDiagnosticID, equals: 1, timeout: 4), 1)

        // Expand/layout frames must not pollute the scroll smoothness window.
        let metricsReset = app.descendants(matching: .any)["harness.metrics.reset"]
        tapHarnessControl(metricsReset)
        _ = waitForDiagnosticAtLeast("diag.frameSamples", minimum: 30, timeout: 4)

        tapHarnessControl(diagTick)
        let perfGuardrailBefore = pollDiagnostic("diag.perfGuardrail", timeout: 4)
        let frameP95Before = pollDiagnostic("diag.frameP95", timeout: 4)
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

        let settledOffset = waitForTimelineOffsetToRest(diagTick: diagTick)
        XCTAssertLessThanOrEqual(
            abs(settledOffset - offsetAfterReturnDown),
            16,
            "Offset snapped back after downward drag past expanded \(markdownLabel) (down=\(offsetAfterReturnDown), settled=\(settledOffset))"
        )

        let frameP95After = pollDiagnostic("diag.frameP95", timeout: 4)
        let frameP99After = pollDiagnostic("diag.frameP99", timeout: 2)
        let frameMaxAfter = pollDiagnostic("diag.frameMax", timeout: 2)
        let frameSamplesAfter = pollDiagnostic("diag.frameSamples", timeout: 2)
        let perfGuardrailAfter = pollDiagnostic("diag.perfGuardrail", timeout: 4)

        XCTAssertLessThanOrEqual(
            frameP95After,
            max(55, frameP95Before + 18),
            "\(markdownLabel) scroll frameP95=\(frameP95After) p99=\(frameP99After) max=\(frameMaxAfter) samples=\(frameSamplesAfter) before=\(frameP95Before)"
        )
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
        XCTAssertTrue(alpha.waitUntilExists(timeout: 4))
        XCTAssertTrue(beta.waitUntilExists(timeout: 4))
        XCTAssertTrue(gamma.waitUntilExists(timeout: 4))

        let expandAll = app.descendants(matching: .any)["harness.expand.all"]
        let renderToolSet = app.descendants(matching: .any)["harness.tools.render"]
        let topButton = app.descendants(matching: .any)["harness.scroll.top"]
        let bottomButton = app.descendants(matching: .any)["harness.scroll.bottom"]
        let pulse = app.descendants(matching: .any)["harness.stream.pulse"]
        let themeToggle = app.descendants(matching: .any)["harness.theme.toggle"]

        XCTAssertTrue(expandAll.waitUntilExists(timeout: 4))
        XCTAssertTrue(renderToolSet.waitUntilExists(timeout: 4))
        XCTAssertTrue(topButton.waitUntilExists(timeout: 4))
        XCTAssertTrue(bottomButton.waitUntilExists(timeout: 4))
        XCTAssertTrue(pulse.waitUntilExists(timeout: 4))
        XCTAssertTrue(themeToggle.waitUntilExists(timeout: 4))

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

}

@MainActor
final class UIMessageQueueHarnessUITests: UIHarnessTestCase {

    func testSteeringQueueLifecycle() throws {
        launchQueueHarness()

        // Reset baseline so simulator relaunches cannot leak stale queue state.
        let clearQueue = app.descendants(matching: .any)["harness.queue.clear"]
        XCTAssertTrue(clearQueue.waitUntilExists(timeout: 4))
        clearQueue.tap()

        XCTAssertEqual(waitForDiagnostic("diag.queueVisible", equals: 0, timeout: 4), 0)
        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 0, timeout: 4), 0)
        XCTAssertEqual(waitForDiagnostic("diag.queueFollowUpCount", equals: 0, timeout: 4), 0)

        let startedBefore = pollDiagnostic("diag.queueStartedEvents", timeout: 4)

        let enqueueSteer = app.descendants(matching: .any)["harness.queue.enqueueSteer"]
        XCTAssertTrue(enqueueSteer.waitUntilExists(timeout: 4))
        enqueueSteer.tap()

        XCTAssertEqual(waitForDiagnostic("diag.queueVisible", equals: 1, timeout: 4), 1)
        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 1, timeout: 4), 1)
        XCTAssertEqual(waitForDiagnostic("diag.queueFollowUpCount", equals: 0, timeout: 4), 0)

        let queueContainer = app.descendants(matching: .any)["chat.messageQueue.toggle"]
        XCTAssertTrue(queueContainer.waitUntilExists(timeout: 4))

        let startSteer = app.descendants(matching: .any)["harness.queue.startSteer"]
        XCTAssertTrue(startSteer.waitUntilExists(timeout: 4))
        startSteer.tap()

        XCTAssertEqual(waitForDiagnostic("diag.queueVisible", equals: 0, timeout: 4), 0)
        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 0, timeout: 4), 0)
        XCTAssertEqual(
            waitForDiagnostic("diag.queueStartedEvents", equals: startedBefore + 1, timeout: 4),
            startedBefore + 1
        )
    }

    func testQueueHeaderToggleRevealsAndHidesActions() throws {
        launchQueueHarness()

        let clearQueue = app.descendants(matching: .any)["harness.queue.clear"]
        XCTAssertTrue(clearQueue.waitUntilExists(timeout: 4))
        clearQueue.tap()

        let enqueueSteer = app.descendants(matching: .any)["harness.queue.enqueueSteer"]
        XCTAssertTrue(enqueueSteer.waitUntilExists(timeout: 4))
        enqueueSteer.tap()

        XCTAssertEqual(waitForDiagnostic("diag.queueVisible", equals: 1, timeout: 4), 1)

        let queueToggle = app.descendants(matching: .any)["chat.messageQueue.toggle"]
        XCTAssertTrue(
            queueToggle.waitUntilExists(timeout: 4),
            "Queue toggle should be discoverable for interaction"
        )
        queueToggle.tap()

        let refreshButton = app.descendants(matching: .any)["chat.messageQueue.editInComposer"]
        XCTAssertTrue(
            refreshButton.waitUntilExists(timeout: 4),
            "Expanding queue should reveal Edit in composer"
        )

        queueToggle.tap()
        XCTAssertTrue(
            waitForElementToDisappear(refreshButton, timeout: 2),
            "Collapsing queue should hide Edit in composer"
        )
    }

    func testAttachmentOnlyQueueItemsShowImageAndFileNames() throws {
        launchQueueHarness()

        let clearQueue = app.descendants(matching: .any)["harness.queue.clear"]
        XCTAssertTrue(clearQueue.waitUntilExists(timeout: 4))
        clearQueue.tap()

        let enqueueAttachments = app.descendants(matching: .any)["harness.queue.enqueueAttachments"]
        XCTAssertTrue(enqueueAttachments.waitUntilExists(timeout: 4))
        enqueueAttachments.tap()

        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 2, timeout: 4), 2)

        let queueToggle = app.descendants(matching: .any)["chat.messageQueue.toggle"]
        XCTAssertTrue(queueToggle.waitUntilExists(timeout: 4))
        queueToggle.tap()

        let imageAttachment = app.descendants(matching: .any)["chat.messageQueue.attachment.harness-image"]
        XCTAssertTrue(
            imageAttachment.waitUntilExists(timeout: 4),
            "An image-only queued message should show its image name"
        )
        XCTAssertEqual(imageAttachment.label, "Photo image-1.jpg")

        let fileAttachment = app.descendants(matching: .any)["chat.messageQueue.attachment.harness-file"]
        XCTAssertTrue(
            fileAttachment.waitUntilExists(timeout: 4),
            "A file-only queued message should show its file name"
        )
        XCTAssertEqual(fileAttachment.label, "Attachment notes.txt")
    }

    func testRemoveAndEditInComposerWhileStreaming() throws {
        launchQueueHarness(realBusyLane: true)
        XCTAssertEqual(waitForDiagnostic("diag.isBusy", equals: 1, timeout: 4), 1)
        XCTAssertEqual(waitForDiagnostic("diag.streaming", equals: 1, timeout: 4), 1)
        let charactersBefore = pollDiagnostic("diag.streamChars", timeout: 4)
        app.descendants(matching: .any)["harness.stream.pulse"].tap()
        XCTAssertGreaterThan(pollDiagnostic("diag.streamChars", timeout: 4), charactersBefore)
        let clear = app.descendants(matching: .any)["harness.queue.clear"]
        XCTAssertTrue(clear.waitUntilExists(timeout: 4))
        clear.tap()
        app.descendants(matching: .any)["harness.queue.enqueueSteer"].tap()
        app.descendants(matching: .any)["harness.queue.enqueueFollow"].tap()
        app.descendants(matching: .any)["chat.messageQueue.toggle"].tap()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.messageQueue.remove.")).firstMatch
        XCTAssertTrue(remove.waitUntilExists(timeout: 4))
        XCTAssertGreaterThanOrEqual(remove.frame.width, 44)
        XCTAssertGreaterThanOrEqual(remove.frame.height, 44)
        remove.tap()
        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 0, timeout: 4), 0)
        XCTAssertEqual(waitForDiagnostic("diag.queueFollowUpCount", equals: 1, timeout: 4), 1)
        app.descendants(matching: .any)["chat.messageQueue.editInComposer"].tap()
        XCTAssertEqual(waitForDiagnostic("diag.queueVisible", equals: 0, timeout: 4), 0)
        let input = app.textFields["harness.input"]
        XCTAssertTrue(input.waitUntilExists(timeout: 4))
        XCTAssertTrue((input.value as? String ?? "").contains("Harness follow-up message"))
        XCTAssertEqual(pollDiagnostic("diag.isBusy", timeout: 4), 1)
        XCTAssertEqual(pollDiagnostic("diag.streaming", timeout: 4), 1)
    }

    private func launchQueueHarness(realBusyLane: Bool = false) {
        launchHarness(
            noStream: false,
            includeVisualFixtures: false,
            mixedContent: false,
            queueHarness: true,
            realBusyLane: realBusyLane
        )
    }
}
