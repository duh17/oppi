import XCTest

/// Launch arguments that pin the chat top bar to Files, Git, Outline, and
/// Context, for tests about those panels rather than the default bar (which
/// shows only Context). The argument domain holds them for that launch only.
enum ChatTopBarTestLayout {
    static let panelButtons = [
        "-dev.chenda.Oppi.chatDisplay.topBarOrder", "(files, git, outline, context, terminal)",
        "-dev.chenda.Oppi.chatDisplay.topBarShown", "(files, git, outline, context)",
    ]
}

@MainActor
class UIHarnessTestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI harness tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// Override to `true` in a class whose tests only drive harness screens and
    /// leave nothing that survives an in-process reset (`ReusedHarnessLaunch`).
    /// The class then keeps one app launch across tests that ask for the same
    /// launch configuration; each test starts after the app has re-run the
    /// launch contract's reset and rebuilt the harness root, and fails with the
    /// stale generation when that did not take. Classes that need a fresh
    /// process per test (a relaunch, a route, an E2E pairing) keep the default;
    /// one test of a reusing class can pass `freshProcess: true` to `launchHarness`.
    class var reusesLaunch: Bool { false }

    func launchHarness(
        noStream: Bool,
        includeVisualFixtures: Bool = false,
        mixedContent: Bool = false,
        queueHarness: Bool = false,
        includeWriteMarkdownFixture: Bool = false,
        assistantOverlapFixture: Bool = false,
        realBusyLane: Bool = false,
        tailFillerRows: Int = 0,
        freshProcess: Bool = false
    ) {
        let environment = [
            "PI_UI_HANG_HARNESS": "1",
            "PI_UI_HANG_UI_TEST_MODE": "1",
            "PI_UI_HANG_MIXED_CONTENT": mixedContent ? "1" : "0",
            "PI_UI_HANG_NO_STREAM": noStream ? "1" : "0",
            "PI_UI_HANG_INCLUDE_VISUAL_FIXTURES": includeVisualFixtures ? "1" : "0",
            "PI_UI_HANG_INCLUDE_WRITE_MD_FIXTURE": includeWriteMarkdownFixture ? "1" : "0",
            "PI_UI_HANG_QUEUE_HARNESS": queueHarness ? "1" : "0",
            "PI_UI_HANG_ASSISTANT_OVERLAP_FIXTURE": assistantOverlapFixture ? "1" : "0",
            "PI_UI_HANG_REAL_BUSY": realBusyLane ? "1" : "0",
            "PI_UI_HANG_TAIL_FILLER_ROWS": String(tailFillerRows),
        ]
        let application = OppiTestLaunch.makeApp()
        application.launchArguments.append("--ui-hang-harness")
        application.launchEnvironment.merge(environment) { _, new in new }

        if ReusedHarnessLaunch.isEnabled(optedIn: Self.reusesLaunch) {
            app = ReusedHarnessLaunch.app(
                owner: String(describing: Self.self),
                application: application,
                readyID: "harness.ready",
                freshProcess: freshProcess
            ) {
                application.launch()
            }
        } else {
            application.launch()
            app = application
        }

        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"].waitUntilExists(timeout: 10),
            "Harness did not become ready"
        )
    }

    func assertHarnessStillRunning(context: String) -> Bool {
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

    func pollDiagnostic(_ id: String, timeout: TimeInterval) -> Int {
        if let value = tryPollDiagnostic(id, timeout: timeout) {
            return value
        }

        guard assertHarnessStillRunning(context: "timing out while reading diagnostic \(id)") else {
            return -1
        }

        XCTFail("Could not read diagnostic \(id) within \(timeout)s")
        return -1
    }

    func tryPollDiagnostic(_ id: String, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard assertHarnessStillRunning(context: "reading diagnostic \(id)") else {
                return nil
            }

            let element = app.descendants(matching: .any)[id]
            if element.waitUntilExists(timeout: 0.15),
               let value = parseDiagnosticValue(element) {
                return value
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return nil
    }

    func parseDiagnosticValue(_ element: XCUIElement) -> Int? {
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

    func waitForDiagnostic(_ id: String, equals expected: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: Int?

        while Date() < deadline {
            if let value = tryPollDiagnostic(id, timeout: 0.3) {
                lastValue = value
                if value == expected {
                    return value
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTFail(
            "Diagnostic \(id) did not reach expected value \(expected) " +
            "(last=\(lastValue.map(String.init) ?? "nil"))"
        )
        return -1
    }

    func waitForDiagnosticAtLeast(_ id: String, minimum: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: Int?

        while Date() < deadline {
            if let value = tryPollDiagnostic(id, timeout: 0.3) {
                lastValue = value
                if value >= minimum {
                    return value
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTFail(
            "Diagnostic \(id) did not reach minimum value \(minimum) " +
            "(last=\(lastValue.map(String.init) ?? "nil"))"
        )
        return -1
    }

    func waitForDiagnosticAtMostOrNil(_ id: String, maximum: Int, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let value = tryPollDiagnostic(id, timeout: 0.3), value <= maximum {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return nil
    }

    func waitForDiagnosticInRange(
        _ id: String,
        range: ClosedRange<Int>,
        timeout: TimeInterval
    ) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: Int?

        while Date() < deadline {
            if let value = tryPollDiagnostic(id, timeout: 0.3) {
                lastValue = value
                if range.contains(value) {
                    return value
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTFail(
            "Diagnostic \(id) did not reach range \(range.lowerBound)...\(range.upperBound) " +
            "(last=\(lastValue.map(String.init) ?? "nil"))"
        )
        return lastValue ?? -1
    }

    func tapHarnessControl(
        _ element: XCUIElement,
        timeout: TimeInterval = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitUntilExists(timeout: timeout),
            "Harness control did not exist",
            file: file,
            line: line
        )
        if element.isHittable {
            element.tap()
            return
        }
        // Wrapping chrome can still report a slightly off AX hit target;
        // coordinate tap reaches the same control without scrolling-to-visible.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// `element`'s top edge, relative to `container`'s when given, once it has
    /// stopped moving: two reads 0.2 s apart within half a point, or the last read
    /// at `timeout`.
    func settledMinY(of element: XCUIElement, in container: XCUIElement? = nil, timeout: TimeInterval = 3) -> CGFloat {
        func read() -> CGFloat { element.frame.minY - (container?.frame.minY ?? 0) }
        var last = read()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let next = read()
            if abs(next - last) < 0.5 { return next }
            last = next
        }
        return last
    }

    func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !element.exists {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        return !element.exists
    }

    enum OffsetDirection {
        case increasing
        case decreasing
    }

    /// `settling` ends the drag with a held finger, so the timeline stops where the
    /// finger does instead of flinging a row out of the viewport it must start in.
    func dragTimeline(_ element: XCUIElement, from: CGVector, to: CGVector, settling: Bool = false) {
        let start = element.coordinate(withNormalizedOffset: from)
        let end = element.coordinate(withNormalizedOffset: to)
        if settling {
            start.press(forDuration: 0.02, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        } else {
            start.press(forDuration: 0.02, thenDragTo: end)
        }
    }

    /// Normalized drag path whose start and end both lie in the part of `row` that
    /// is on screen inside `timeline`; nil when too little of the row is visible.
    private func dragPath(
        inside row: XCUIElement,
        of timeline: XCUIElement,
        direction: OffsetDirection
    ) -> (from: CGVector, to: CGVector)? {
        let timelineFrame = timeline.frame
        let visible = row.frame.intersection(timelineFrame)
        guard !visible.isNull, visible.height >= 120, timelineFrame.width > 0, timelineFrame.height > 0 else {
            return nil
        }
        let x = (visible.midX - timelineFrame.minX) / timelineFrame.width
        let upperY = (visible.minY + visible.height * 0.3 - timelineFrame.minY) / timelineFrame.height
        let lowerY = (visible.minY + visible.height * 0.7 - timelineFrame.minY) / timelineFrame.height
        switch direction {
        case .increasing:
            return (CGVector(dx: x, dy: lowerY), CGVector(dx: x, dy: upperY))
        case .decreasing:
            return (CGVector(dx: x, dy: upperY), CGVector(dx: x, dy: lowerY))
        }
    }

    /// Drags on `row`'s body and returns once the row itself has followed the finger by
    /// `minimumDelta` points, `.decreasing` meaning the finger goes down and the row with
    /// it. That the row under the finger moves is what "the timeline owns the drag"
    /// means; a row that does not move means the row's own text view kept the pan.
    ///
    /// The timeline's `contentOffset` cannot stand in for it. Scrolling toward earlier
    /// content realizes rows whose estimated heights are then replaced by their real
    /// ones, and the offset moves by that difference, in either direction, while every
    /// row still follows the finger (iPad: a +314 pt offset step beside a row that moved
    /// 81.5 pt down).
    func dragRowUntilItMoves(
        _ timeline: XCUIElement,
        row: XCUIElement,
        minimumDelta: CGFloat,
        direction: OffsetDirection,
        context: String
    ) {
        var lastMovement: CGFloat = 0
        for _ in 0..<3 {
            guard row.exists, let path = dragPath(inside: row, of: timeline, direction: direction) else {
                XCTFail(
                    "Drag start is not inside the row during \(context) " +
                    "(row=\(row.frame), exists=\(row.exists), timeline=\(timeline.frame))"
                )
                return
            }
            let before = row.frame.minY
            dragTimeline(timeline, from: path.from, to: path.to, settling: true)
            guard row.exists else {
                XCTFail("The row left the viewport during \(context) (it was at y=\(before))")
                return
            }
            // A downward finger moves the row toward larger y.
            let movement = direction == .decreasing ? row.frame.minY - before : before - row.frame.minY
            lastMovement = movement
            if movement >= minimumDelta { return }
        }
        let directionDescription = direction == .decreasing ? "down" : "up"
        XCTFail(
            "The row did not follow the finger \(directionDescription) enough during \(context) " +
            "(moved \(lastMovement) pt, minimumDelta=\(minimumDelta))"
        )
    }

    func dragTimelineUntilOffsetMoves(
        _ timeline: XCUIElement,
        diagTick: XCUIElement,
        baseline: Int,
        minimumDelta: Int,
        direction: OffsetDirection,
        context: String,
        startingInside row: XCUIElement? = nil
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
        for fixedPath in dragPaths {
            // A drag that must prove a row owns the gesture starts on that row's
            // body. The fixed fractions can land on other rows once the viewport is
            // taller than the row, and the timeline then scrolls either way.
            let path: (from: CGVector, to: CGVector)
            if let row {
                guard let rowPath = dragPath(inside: row, of: timeline, direction: direction) else {
                    XCTFail(
                        "Drag start is not inside the row during \(context) " +
                        "(row=\(row.frame), timeline=\(timeline.frame))"
                    )
                    return lastOffset
                }
                path = rowPath
            } else {
                path = fixedPath
            }
            dragTimeline(timeline, from: path.from, to: path.to, settling: row != nil)
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
}
