import XCTest

/// How smoothly the SSH terminal scrolls a fling through thousands of history
/// rows, measured by the app itself: its grid measures each gesture (frames,
/// hitches, hitch time ratio, worst frame) and the debug harness prints the
/// latest one in the readout `sshTerminal.preview.scroll`. A device uploads the
/// same numbers summed per visit (`app.terminal_scroll_visit`).
///
/// - `ssh-terminal-scrollback`: a plain shell, the comparison.
/// - `ssh-terminal-rex-scrollback`: the fake Rex session (`RexFakeSession`), quiet neighbours.
/// - `ssh-terminal-rex-busy`: the same, with both neighbour panes streaming output.
///
/// The simulator's numbers say whether the main thread kept up with the
/// gesture, not how a phone feels; each test prints one `SCROLL_METRIC` line
/// and attaches it, so a run's numbers can be compared with another's.
@MainActor
final class SSHTerminalScrollSmoothnessUITests: XCTestCase {
    private var app: XCUIApplication!
    private static let flings = 5

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("SSH terminal scroll tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    private func launch(screen: String) {
        app = OppiTestLaunch.makeApp()
        // Rex is an experiment (Settings → Experiments): the Rex screens need it.
        app.launchArguments += OppiTestLaunch.experimentArguments([.rex: true])
        app.launchArguments += ["--screenshot-preview"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = screen
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = "dark"
        app.launch()
        XCTAssertEqual(app.wait(for: .runningForeground, timeout: 10), true)
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

    private struct Gesture {
        let count: Int
        let values: [String: String]

        init?(_ readout: String) {
            let words = readout.split(separator: " ").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
            var values: [String: String] = [:]
            for word in words where word.count == 2 { values[word[0]] = word[1] }
            guard let count = values["gesture"].flatMap(Int.init) else { return nil }
            self.count = count
            self.values = values
        }

        func number(_ key: String) -> Double { values[key].flatMap(Double.init) ?? .nan }
    }

    /// Flings the grid toward older history `flings` times, one gesture each,
    /// and returns what the grid measured for each.
    private func fling(_ grid: XCUIElement, flings: Int) -> [Gesture] {
        let readout = element("sshTerminal.preview.scroll")
        XCTAssertTrue(readout.waitUntilExists(timeout: 10), "The scroll readout never appeared")
        var gestures: [Gesture] = []
        for _ in 0..<flings {
            let before = gestures.last?.count ?? 0
            grid.swipeDown(velocity: .fast)
            // The gesture is reported once its coasting ends.
            XCTAssertTrue(
                waitFor(Gesture(readout.label).map { $0.count > before } ?? false, timeout: 20),
                "The grid never reported the gesture: \(readout.label)"
            )
            if let latest = Gesture(readout.label) { gestures.append(latest) }
        }
        return gestures
    }

    private func report(_ name: String, _ gestures: [Gesture]) {
        let ratios = gestures.map { $0.number("hitch_ratio") }
        let worst = gestures.map { $0.number("worst_frame_ms") }
        let hitches = gestures.map { $0.number("hitches") }
        let frames = gestures.map { $0.number("frames") }
        let deferred = gestures.map { $0.number("deferred_bytes") }
        let line = String(
            format: "SCROLL_METRIC %@ gestures=%d frames=%.0f hitches=%.0f hitch_ratio_mean=%.4f hitch_ratio_max=%.4f worst_frame_ms=%.1f deferred_bytes=%.0f modes=%@ paths=%@",
            name, gestures.count, frames.reduce(0, +), hitches.reduce(0, +),
            ratios.reduce(0, +) / Double(max(1, ratios.count)), ratios.max() ?? 0, worst.max() ?? 0, deferred.reduce(0, +),
            Set(gestures.compactMap { $0.values["terminal_mode"] }).sorted().joined(separator: ","),
            Set(gestures.compactMap { $0.values["scroll_path"] }).sorted().joined(separator: ",")
        )
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "scroll-metric-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(frames.allSatisfy { $0 >= 2 }, "A gesture measured fewer than two frames: \(line)")
        XCTAssertTrue(ratios.allSatisfy { $0.isFinite }, "A gesture has no hitch ratio: \(line)")
    }

    func testShellFling() {
        launch(screen: "ssh-terminal-scrollback")
        let grid = element("sshTerminal.grid")
        XCTAssertTrue(grid.waitUntilExists(timeout: 15), "The terminal grid never appeared")
        let gestures = fling(grid, flings: Self.flings)
        XCTAssertEqual(Set(gestures.compactMap { $0.values["terminal_mode"] }), ["shell"])
        XCTAssertEqual(Set(gestures.compactMap { $0.values["scroll_path"] }), ["history"])
        report("shell", gestures)
    }

    func testRexFling() {
        launch(screen: "ssh-terminal-rex-scrollback")
        flingRex(name: "rex")
    }

    func testRexFlingWithBusyNeighbours() {
        launch(screen: "ssh-terminal-rex-busy")
        flingRex(name: "rex_busy")
    }

    private func flingRex(name: String) {
        let switcher = app.buttons["sshTerminal.bar.rexPanes"]
        XCTAssertTrue(switcher.waitUntilExists(timeout: 15), "The pane switcher did not appear")
        let grid = element("sshTerminal.grid")
        XCTAssertTrue(grid.waitUntilExists(timeout: 15), "The terminal grid never appeared")
        // The pane count settles when the panes' titles arrive, after the pill.
        XCTAssertTrue(
            waitFor(((switcher.value as? String) ?? switcher.label).contains("1 of 3"), timeout: 15),
            "Not three panes: \((switcher.value as? String) ?? switcher.label)"
        )
        let gestures = fling(grid, flings: Self.flings)
        XCTAssertEqual(Set(gestures.compactMap { $0.values["terminal_mode"] }), ["rex"])
        XCTAssertEqual(Set(gestures.compactMap { $0.values["scroll_path"] }), ["history"])
        report(name, gestures)
    }
}
