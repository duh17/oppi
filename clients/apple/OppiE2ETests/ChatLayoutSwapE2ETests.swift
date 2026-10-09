import XCTest

/// Portrait stack to landscape split and back, with a chat already open.
///
/// Chen's device symptom is the open chat mounting, remounting about two
/// seconds later, then landing on the session list. This journey is the
/// missing proof: the same chat and its composer must survive the shell swap,
/// including while the keyboard is up.
@MainActor
final class ChatLayoutSwapE2ETests: E2ETestCase {
    override func setUpWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testOpenChatSurvivesStackSplitSwapWithAndWithoutKeyboard() throws {
        try XCTSkipUnless(
            min(app.frame.width, app.frame.height) >= 700,
            "Stack/split swap needs an iPad simulator"
        )

        try waitForOrientation(.portrait)
        createSession()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        XCTAssertNotEqual(sessionId, "none")
        XCTAssertFalse(sessionId.isEmpty)
        XCTAssertTrue(
            app.textViews["chat.input"].waitForExistence(timeout: 10),
            "Composer did not appear before the layout swap"
        )

        try waitForOrientation(.landscapeLeft)
        assertChatStaysOpen(sessionId, context: "landscape split")

        try waitForOrientation(.portrait)
        assertChatStaysOpen(sessionId, context: "portrait stack after split")

        let composer = app.textViews["chat.input"]
        tap(composer, named: "chat composer", timeout: 5)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            "Keyboard did not appear before the keyboard-up layout swap"
        )

        try waitForOrientation(.landscapeLeft)
        assertChatStaysOpen(sessionId, context: "landscape split with keyboard up")

        try waitForOrientation(.portrait)
        assertChatStaysOpen(sessionId, context: "portrait stack after keyboard-up split")
    }

    private func waitForOrientation(_ orientation: UIDeviceOrientation) throws {
        XCUIDevice.shared.orientation = orientation
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let size = app.frame.size
            let matches = orientation == .portrait
                ? size.height > size.width
                : size.width > size.height
            if matches && size.width > 100 && size.height > 100 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("App did not rotate to \(orientation). Frame: \(app.frame)")
    }

    /// Watch the open chat through the ~2s remount window. A shell swap may
    /// remount the chat; it must not replace it with the session list.
    private func assertChatStaysOpen(_ sessionId: String, context: String) {
        let deadline = Date().addingTimeInterval(3.5)
        var lastFocus = ""
        while Date() < deadline {
            lastFocus = app.staticTexts["e2e.ws.focusedSession"].label
            if lastFocus != sessionId && lastFocus != "none" && !lastFocus.isEmpty {
                XCTFail("\(context): focus left \(sessionId) for \(lastFocus)")
                return
            }
            if sessionListReplacedChat() {
                XCTFail("\(context): session list replaced the open chat. Focus: \(lastFocus)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertEqual(
            app.staticTexts["e2e.ws.focusedSession"].label,
            sessionId,
            "\(context): focused session did not stay \(sessionId). Last: \(lastFocus)"
        )
        XCTAssertTrue(
            app.textViews["chat.input"].exists,
            "\(context): composer was gone after the layout swap settled"
        )
        XCTAssertFalse(
            sessionListReplacedChat(),
            "\(context): session list was the visible screen after the layout swap"
        )
    }

    private func sessionListReplacedChat() -> Bool {
        let chatOpen = app.textViews["chat.input"].exists
            || app.buttons["chat.toolbar.back"].exists
            || app.buttons["chat.toolbar.files"].exists
        guard !chatOpen else { return false }
        let sessionList = app.collectionViews["workspace.sessionList"]
        return sessionList.exists && sessionList.isHittable
    }
}
