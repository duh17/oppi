import XCTest

@MainActor
class UIHarnessTestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI harness tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    func launchHarness(
        noStream: Bool,
        includeVisualFixtures: Bool = false,
        mixedContent: Bool = false,
        queueHarness: Bool = false,
        includeWriteMarkdownFixture: Bool = false
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
        app.launchEnvironment["PI_UI_HANG_NO_STREAM"] = noStream ? "1" : "0"
        app.launchEnvironment["PI_UI_HANG_INCLUDE_VISUAL_FIXTURES"] = includeVisualFixtures ? "1" : "0"
        app.launchEnvironment["PI_UI_HANG_INCLUDE_WRITE_MD_FIXTURE"] = includeWriteMarkdownFixture ? "1" : "0"
        app.launchEnvironment["PI_UI_HANG_QUEUE_HARNESS"] = queueHarness ? "1" : "0"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"].waitForExistence(timeout: 10),
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
            if element.waitForExistence(timeout: 0.35),
               let value = parseDiagnosticValue(element) {
                return value
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
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

    func waitForDiagnosticAtLeast(_ id: String, minimum: Int, timeout: TimeInterval) -> Int {
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

    func waitForDiagnosticAtLeastValue(_ id: String, minimum: Int, timeout: TimeInterval) -> Int {
        waitForDiagnosticAtLeast(id, minimum: minimum, timeout: timeout)
    }

    func waitForDiagnosticAtMostOrNil(_ id: String, maximum: Int, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let value = tryPollDiagnostic(id, timeout: 0.7), value <= maximum {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        return nil
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

    func dragTimeline(_ element: XCUIElement, from: CGVector, to: CGVector) {
        let start = element.coordinate(withNormalizedOffset: from)
        let end = element.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.02, thenDragTo: end)
    }

    func dragTimelineUntilOffsetMoves(
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
}
