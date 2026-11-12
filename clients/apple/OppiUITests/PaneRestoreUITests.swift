import XCTest

/// The window's panes across a relaunch, in the production shell over the
/// chat-routes fixtures (`SCREENSHOT_SCREEN=pane-restore`): what was open
/// comes back, and what cannot open shows its leaf state. Both relaunches are
/// real: the second launch in a test keeps what the first one wrote.
@MainActor
final class PaneRestoreUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    private let sessionRow = "session.nav.chat-routes-session"

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Pane restore tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// The chat comes back after a relaunch; on a wide window its Git panel
    /// comes back beside it.
    func testARelaunchRestoresTheChatAndItsPanel() throws {
        launchShell()
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        let git = app.buttons["chat.toolbar.git"]
        XCTAssertTrue(git.waitUntilExists(timeout: 10), "The chat opened")
        let wide = app.windows.firstMatch.frame.width >= 640
        if wide {
            git.tap()
            XCTAssertTrue(app.navigationBars["Git"].waitUntilExists(timeout: 5), "The Git panel opened beside the chat")
        }
        // Past the 500 ms settle, so the tree is written before the process dies.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attachScreenshot("restore-before-relaunch")

        launchShell()
        XCTAssertTrue(git.waitUntilExists(timeout: 10), "The chat is back after a relaunch")
        if wide {
            XCTAssertTrue(app.navigationBars["Git"].waitUntilExists(timeout: 10), "Its Git panel is back beside it")
        }
        attachScreenshot("restore-after-relaunch")
    }

    /// X1–X4: a tree whose stack holds an offline server's session, an
    /// unpaired server's, a deleted session and a deleted file shows each
    /// leaf's state, and Close Pane steps down through them.
    func testMissingStatesShowTheirRemedyAndClose() throws {
        launchShell(environment: ["PANE_RESTORE_SEED": "missing"])
        expectState("pane.state.unreachable", text: "mac-mini Is Offline", shot: "missing-offline-server")
        XCTAssertTrue(app.buttons["Retry"].exists, "An unreachable remote server offers Retry")
        closePane()
        expectState("pane.state.missing.server", text: "Server Removed", shot: "missing-server-removed")
        closePane()
        expectState("pane.state.missing.session", text: "Session Not Found", shot: "missing-session")
        closePane()
        XCTAssertTrue(
            app.staticTexts["File Not Found"].waitUntilExists(timeout: 10),
            "A file the server no longer has shows as missing"
        )
        attachScreenshot("missing-file")
    }

    private func launchShell(environment: [String: String] = [:]) {
        // Portrait: the iPad mini is still wide (744 pt holds the chat and a
        // panel), and landscape captures come out with a black band.
        XCUIDevice.shared.orientation = .portrait
        launchPreview(screen: "pane-restore", environment: environment, ready: nil)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The shell came up")
    }

    private func expectState(_ identifier: String, text: String, shot: String) {
        XCTAssertTrue(
            app.descendants(matching: .any)[identifier].waitUntilExists(timeout: 15),
            "Expected the \(identifier) leaf state"
        )
        XCTAssertTrue(app.staticTexts[text].waitUntilExists(timeout: 5), "Expected “\(text)”")
        attachScreenshot(shot)
    }

    private func closePane() {
        let close = app.buttons["Close Pane"]
        XCTAssertTrue(close.waitUntilExists(timeout: 5), "Close Pane is offered")
        close.tap()
    }
}
