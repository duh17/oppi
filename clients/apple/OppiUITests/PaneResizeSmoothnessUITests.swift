import XCTest

/// How a live divider resize runs beside a long chat: a 2,000-event session
/// (`CHAT_ROUTES_LONG_TURNS=400`) on the chat's side and a 5,000-line file in
/// the reader in the chat's attached leaf. The app measures each drag itself
/// (`PaneResizeMeter`) and the debug harness prints the latest one in the
/// readout `paneResize.drag`, with the timeline's layout work while the divider
/// moved apart from its settles.
///
/// The simulator proves the counters: no timeline layout while the divider
/// moves and a bounded settle. Its frame times say whether the main thread
/// kept up, not how the iPad mini feels; each test prints one `PANE_METRIC` line and attaches it.
@MainActor
final class PaneResizeSmoothnessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Pane resize smoothness tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    private func launch() throws {
        app = OppiTestLaunch.makeApp()
        app.launchArguments += ["--screenshot-preview"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "chat-routes"
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = "dark"
        app.launchEnvironment["CHAT_ROUTES_LONG_TURNS"] = "400"
        app.launchEnvironment["CHAT_ROUTES_LONG_FILE"] = "5000"
        app.launchEnvironment["CHAT_ROUTES_PANE_RESIZE"] = "1"
        app.launch()
        XCTAssertEqual(app.wait(for: .runningForeground, timeout: 10), true)
        app.requireNonCompactWindowOnPad()
        guard app.windows.firstMatch.horizontalSizeClass == .regular else {
            throw XCTSkip("The attached leaf needs a regular-width window")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        // The simulator keeps its orientation for the next test.
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["chat.toolbar.context"].waitUntilExists(timeout: 20), "The chat did not appear")
        app.buttons["chatRoutes.openFileViewer"].tap()
        XCTAssertTrue(
            app.buttons["fullScreen.code.close"].waitUntilExists(timeout: 15),
            "The file did not open beside the chat"
        )
        XCTAssertTrue(handle.waitUntilExists(timeout: 5), "The divider did not appear")
    }

    private var handle: XCUIElement {
        app.descendants(matching: .any)["pane.divider.0"]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private struct Readout {
        let values: [String: String]

        init(_ text: String) {
            var values: [String: String] = [:]
            for word in text.split(separator: " ") {
                let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { values[pair[0]] = pair[1] }
            }
            self.values = values
        }

        func number(_ key: String) -> Double { values[key].flatMap(Double.init) ?? .nan }
    }

    /// One slow drag of the divider by `dx`, then the drag the app measured.
    private func drag(by dx: CGFloat) -> Readout {
        let readout = element("paneResize.drag")
        let before = Readout(readout.label).number("drag")
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)),
            withVelocity: 400,
            thenHoldForDuration: 0.05
        )
        XCTAssertTrue(
            waitFor({ let count = Readout(readout.label).number("drag"); return count.isFinite && !(count <= before) }(), timeout: 10),
            "The app never reported the drag: \(readout.label)"
        )
        return Readout(readout.label)
    }

    private func report(_ name: String, _ line: String) {
        print("PANE_METRIC \(name) \(line)")
        let attachment = XCTAttachment(string: "PANE_METRIC \(name) \(line)")
        attachment.name = "pane-metric-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDividerDragHoldsTheTimelineAndReaderAndSettlesOnce() throws {
        try launch()
        let width = app.windows.firstMatch.frame.width
        var drags: [Readout] = []
        for dx in [-width * 0.12, width * 0.12, -width * 0.08] {
            drags.append(drag(by: dx))
        }
        let screenshot = XCTAttachment(uprightScreenshot: app.screenshot())
        screenshot.name = "after-drags"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        for (index, drag) in drags.enumerated() {
            report("drag\(index + 1)", drag.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            XCTAssertGreaterThanOrEqual(drag.number("frames"), 2, "A drag measured fewer than two frames")
            // Rebuilds a data change asked for meanwhile (`moving_content_rebuilds`,
            // the harness re-seeding the chat) are reported, not the resize's own.
            XCTAssertEqual(drag.number("moving_rebuilds"), 0, "The divider laid the timeline's rows out while it moved")
            XCTAssertEqual(drag.number("moving_measured"), 0, "Timeline rows were measured while the divider moved")
            XCTAssertLessThanOrEqual(drag.number("settle_max_measured"), 12, "A settle measured too many rows")
            XCTAssertLessThanOrEqual(drag.number("reflow_max_ms"), 100, "A settle took longer than 100 ms")
        }
    }

    /// Where the chat's rows on screen sit (identifier to top edge), once they
    /// have stopped moving.
    private func restingRowTops() -> [String: CGFloat] {
        let window = app.windows.firstMatch.frame
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.timeline."))
        func read() -> [String: CGFloat] {
            var tops: [String: CGFloat] = [:]
            for row in rows.allElementsBoundByIndex where row.exists {
                let frame = row.frame
                if frame.intersects(window), tops[row.identifier] == nil { tops[row.identifier] = frame.minY }
            }
            return tops
        }
        var last = read()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let now = read()
            if now == last { break }
            last = now
        }
        return last
    }

    /// A reader scrolled up in the chat, by finger, keeps the row they read
    /// through a drag of the divider and the spring that lands it: the first
    /// row read stays where it was and the rows under it wrap around it, so
    /// one row on screen has not moved. A chat thrown to its tail, or to the
    /// offset it had when the pane opened, keeps none.
    func testDividerDragKeepsAScrolledUpReadersRow() throws {
        try launch()
        let window = app.windows.firstMatch
        let tail = restingRowTops()
        let finger = window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.35))
        for _ in 0..<3 {
            finger.press(
                forDuration: 0.05,
                thenDragTo: finger.withOffset(CGVector(dx: 0, dy: window.frame.height * 0.4)),
                withVelocity: 600,
                thenHoldForDuration: 0.3
            )
        }
        let before = restingRowTops()
        XCTAssertFalse(before.isEmpty, "The chat shows no rows to read")
        XCTAssertNotEqual(before, tail, "The chat did not scroll off its tail")

        let measured = drag(by: -150)
        let after = restingRowTops()
        let moved = before.compactMap { identifier, top in after[identifier].map { abs($0 - top) } }
        report(
            "detached-reader",
            "rows_before=\(before.count) rows_kept=\(moved.count) least_moved=\(moved.min() ?? .nan) reflows=\(measured.number("reflows"))"
        )
        let screenshot = XCTAttachment(uprightScreenshot: app.screenshot())
        screenshot.name = "detached-reader-after-drag"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertLessThanOrEqual(moved.min() ?? .infinity, 1, "The row read moved: \(before) then \(after)")
    }

    /// The timeline's running row count once it has stopped changing: a
    /// rotation's layout is over.
    private func settledMeasuredRows() -> Double {
        let readout = element("paneResize.timeline")
        var last = Readout(readout.label).number("measured")
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let now = Readout(readout.label).number("measured")
            if now != last {
                last = now
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 1.5 {
                break
            }
        }
        return last
    }

    func testRotatingBackMeasuresNoTimelineRows() throws {
        try launch()
        var measured = [settledMeasuredRows()]
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            measured.append(settledMeasuredRows())
        }
        let deltas = zip(measured.dropFirst(), measured).map { $0 - $1 }
        report("rotation", "portrait=\(deltas[0]) landscape_again=\(deltas[1]) portrait_again=\(deltas[2])")
        XCTAssertTrue(
            XCUIDevice.shared.orientation == .portrait && handle.exists,
            "The attached leaf must stay open in portrait"
        )
        XCTAssertEqual(deltas[1], 0, "Back in landscape, the timeline measured rows it had heights for")
        XCTAssertEqual(deltas[2], 0, "In portrait again, the timeline measured rows it had heights for")
    }
}
