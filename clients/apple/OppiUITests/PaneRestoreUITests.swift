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
    /// comes back beside it (landscape on the iPad mini: in portrait a panel
    /// opens full over the chat).
    func testARelaunchRestoresTheChatAndItsPanel() throws {
        let landscape: UIDeviceOrientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchShell(orientation: landscape)
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

        launchShell(orientation: landscape)
        XCTAssertTrue(git.waitUntilExists(timeout: 10), "The chat is back after a relaunch")
        if wide {
            XCTAssertTrue(app.navigationBars["Git"].waitUntilExists(timeout: 10), "Its Git panel is back beside it")
        }
        attachScreenshot("restore-after-relaunch")
    }

    /// Rotating the iPad mini changes the shell (split in landscape, stack in
    /// portrait) and nothing else: Outline stays open beside the chat, the
    /// chat is the same screen (its composer keeps the typed text and the
    /// keyboard), and back in landscape the pane has the width it had.
    func testRotationKeepsThePanesTheirWidthAndTheComposer() throws {
        // On iPhone, panels are sheets in either orientation (build plan §1.5).
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Panes sit beside the chat on the iPad mini only")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: [:], ready: nil)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The shell came up")
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        let outlineButton = app.buttons["chat.toolbar.outline"]
        XCTAssertTrue(outlineButton.waitUntilExists(timeout: 10), "The chat opened")
        outlineButton.tap()
        let divider = app.descendants(matching: .any)["pane.divider.0"]
        XCTAssertTrue(divider.waitUntilExists(timeout: 5), "Outline opened beside the chat")
        let outlineClose = app.buttons["chat.outline.close"]
        XCTAssertTrue(outlineClose.waitUntilExists(timeout: 5), "Outline is the pane beside")
        let input = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(input.waitUntilExists(timeout: 5), "Composer input missing")
        input.tap()
        input.typeText("typed before ")
        hold()
        let window = app.windows.firstMatch
        let landscapeShare = (window.frame.maxX - divider.frame.midX) / window.frame.width
        attachScreenCapture("rotation-landscape-before")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitFor(window.frame.height > window.frame.width), "The window turned to portrait")
        hold()
        XCTAssertTrue(outlineClose.waitUntilExists(timeout: 5), "Outline is still open in portrait")
        XCTAssertTrue(divider.exists, "The pane is still beside the chat, or zoomed over it")
        attachScreenCapture("rotation-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitFor(window.frame.width > window.frame.height), "The window turned back to landscape")
        hold()
        XCTAssertTrue(outlineClose.waitUntilExists(timeout: 5), "Outline is still open back in landscape")
        let share = (window.frame.maxX - divider.frame.midX) / window.frame.width
        XCTAssertEqual(share, landscapeShare, accuracy: 0.01, "The pane came back at the width it had")
        // `typeText` fails unless the composer still has the keyboard.
        input.typeText("and after")
        XCTAssertTrue(
            waitFor(((input.value as? String) ?? "").contains("typed before and after")),
            "The composer kept its text and the keyboard: \(input.value ?? "nil")"
        )
        attachScreenCapture("rotation-landscape-after")
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

    /// A folder page opened in a side pane is part of that pane's route: Back
    /// pops it in the pane, and a relaunch brings the pane's page back.
    func testASidePanesFolderPagePopsAndComesBackAfterARelaunch() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Side panes need the iPad mini")
        let landscape: UIDeviceOrientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        // Three panes: the workspace's sessions, its folder, and its Git.
        launchShell(environment: ["PANE_RESTORE_SEED": "splits"], orientation: landscape)
        let folder = app.buttons["fileBrowser.row.Sources/"]
        XCTAssertTrue(folder.waitUntilExists(timeout: 15), "The folder's pane lists the workspace")
        folder.tap()
        let page = app.navigationBars["Sources"]
        XCTAssertTrue(page.waitUntilExists(timeout: 10), "The folder page opened in the pane")
        attachScreenCapture("side-pane-folder-page")

        // Back pops the pane's page, and the pane shows its folder again.
        page.buttons.firstMatch.tap()
        XCTAssertTrue(page.waitUntilGone(timeout: 10), "Back popped the pane's page")
        XCTAssertTrue(folder.waitUntilExists(timeout: 10), "The pane is back at the workspace")
        folder.tap()
        XCTAssertTrue(page.waitUntilExists(timeout: 10), "The folder page opened again")
        // Past the 500 ms settle, so the tree is written before the process dies.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attachScreenCapture("side-pane-before-relaunch")

        launchShell(orientation: landscape)
        XCTAssertTrue(page.waitUntilExists(timeout: 15), "The side pane's page is back after a relaunch")
        attachScreenCapture("side-pane-after-relaunch")
    }

    private func launchShell(environment: [String: String] = [:], orientation: UIDeviceOrientation = .portrait) {
        XCUIDevice.shared.orientation = orientation
        launchPreview(screen: "pane-restore", environment: environment, ready: nil)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The shell came up")
    }

    /// The screen's capture, not the app's: in landscape `app.screenshot()`
    /// draws the iPad's interface sideways into a clipped portrait canvas.
    private func attachScreenCapture(_ name: String) {
        let attachment = XCTAttachment(uprightScreenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
