import XCTest

/// A Rex terminal's pane swipe puts the pane it moves to on the grid.
///
/// `SCREENSHOT_SCREEN=ssh-terminal-rex-panes` is a real `RexSessionConnection`
/// against a fake Rex session of three panes (`RexFakeSession`), so a swipe runs
/// the real switch. The grid cannot be read for text (it paints cells) and this
/// test does not trust an instrumentation hook: it reads what the app itself
/// publishes — the grid's accessibility value, which is the pane on the grid (the
/// same value VoiceOver reads), and the switcher's "N of 3".
@MainActor
final class SSHTerminalRexLivePanesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("SSH terminal pane tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    private func launch() {
        app = OppiTestLaunch.makeApp()
        // Rex is an experiment (Settings → Experiments): this test asks for it.
        app.launchArguments += OppiTestLaunch.experimentArguments([.rex: true])
        app.launchArguments += ["--screenshot-preview"]
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "ssh-terminal-rex-panes"
        app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = "dark"
        app.launch()
        XCTAssertEqual(app.wait(for: .runningForeground, timeout: 10), true)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func attachScreenshot(_ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["OPPI_BAR_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// The switcher's "N of M": its value, as `RouterModalSitesUITests` reads it.
    private func paneValue(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    /// The pane on the grid: the terminal's own value.
    private func gridPane(_ grid: XCUIElement) -> String {
        (grid.value as? String) ?? ""
    }

    /// The switcher's pane name: its value without the "N of M" tail.
    private func paneName(_ switcher: XCUIElement) -> String {
        paneValue(switcher).components(separatedBy: ", ").first ?? ""
    }

    /// A committed swipe lands the next pane on the grid itself — the pane the
    /// switcher names, not a card in front of the old one — and doing it twice
    /// brings the third.
    func testACommittedSwipePutsTheNextPaneOnTheGrid() {
        launch()
        let switcher = app.buttons["sshTerminal.bar.rexPanes"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "The pane switcher did not appear")
        let grid = element("sshTerminal.grid")
        XCTAssertTrue(grid.waitForExistence(timeout: 15), "The terminal grid never appeared")
        // The pane count settles when the panes' titles arrive, after the pill.
        XCTAssertTrue(waitFor(paneValue(switcher).contains("1 of 3")), "Not three panes: \(paneValue(switcher))")
        // The grid names the pane it paints, and it is the pane the switcher
        // names: two independent readouts of the same state.
        let first = paneName(switcher)
        XCTAssertTrue(waitFor(gridPane(grid) == first), "The grid names the pane it paints: \(gridPane(grid)) vs \(first)")

        grid.swipeLeft()
        XCTAssertTrue(
            waitFor(paneValue(switcher).contains("2 of 3")),
            "The swipe did not commit to the next pane: \(paneValue(switcher))"
        )
        // The grid shows the pane the session moved to: the grid's value is that
        // pane, and it is not the one it showed before.
        XCTAssertTrue(waitFor(gridPane(grid) == paneName(switcher) && gridPane(grid) != first),
                      "The grid did not follow to the next pane: \(gridPane(grid)) vs \(paneName(switcher))")
        let second = gridPane(grid)
        attachScreenshot("rex-pane-2")

        grid.swipeLeft()
        XCTAssertTrue(
            waitFor(paneValue(switcher).contains("3 of 3")),
            "The second swipe did not commit: \(paneValue(switcher))"
        )
        XCTAssertTrue(waitFor(gridPane(grid) == paneName(switcher) && gridPane(grid) != second),
                      "The grid did not follow to the third pane: \(gridPane(grid)) vs \(paneName(switcher))")
        attachScreenshot("rex-pane-3")
    }
}
