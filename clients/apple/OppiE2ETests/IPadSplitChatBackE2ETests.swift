import XCTest

/// iPad landscape split: Back on a chat that is the detail root must return
/// to the session list. The chat is not a pushed path element, so a no-op
/// dismiss leaves the same chat on screen.
@MainActor
final class IPadSplitChatBackE2ETests: E2ETestCase {
    override var e2eStartsInAutoCreatedChat: Bool { true }

    override func setUpWithError() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testIPadLandscapeBackFromChatShowsSessionList() throws {
        try XCTSkipUnless(
            min(app.frame.width, app.frame.height) >= 700,
            "Split Back needs an iPad simulator"
        )
        try waitForLandscape()

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 20),
            "Chat did not open before Back"
        )
        let sessionId = waitForFocusedSessionId(timeout: 20)
        XCTAssertFalse(sessionId.isEmpty)
        XCTAssertNotEqual(sessionId, "none")

        let back = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "chat.toolbar.back did not appear")
        XCTAssertTrue(back.isHittable, "chat.toolbar.back was not hittable. Frame: \(back.frame)")
        let backFrame = back.frame
        tap(back, named: "chat back")

        let sessionList = app.collectionViews["workspace.sessionList"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if sessionList.exists, sessionList.isHittable, !app.buttons["chat.toolbar.back"].exists {
                XCTAssertFalse(
                    app.textViews["chat.input"].exists,
                    "Chat input stayed up after Back returned to the session list"
                )
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        let focus = app.staticTexts["e2e.ws.focusedSession"].label
        XCTFail(
            "Session list did not reappear after navigating back. "
                + "backFrame=\(backFrame) opened=\(sessionId) focus=\(focus) "
                + "listExists=\(sessionList.exists) listHittable=\(sessionList.isHittable) "
                + "backStillExists=\(app.buttons["chat.toolbar.back"].exists)"
        )
    }

    private func waitForLandscape() throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let size = app.frame.size
            if size.width > size.height, size.width > 100, size.height > 100 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("App did not reach landscape. Frame: \(app.frame)")
    }
}

/// iPhone stack Back must still pop the chat. Split's launch-hint gate must
/// not change this path.
@MainActor
final class IPhoneStackChatBackE2ETests: E2ETestCase {
    override var e2eStartsInAutoCreatedChat: Bool { true }

    override func setUpWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.setUpWithError()
    }

    func testIPhoneStackBackFromChatShowsSessionList() throws {
        try XCTSkipUnless(
            min(app.frame.width, app.frame.height) < 700,
            "Stack Back check needs an iPhone simulator"
        )

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 20), "Chat did not open before Back")
        let back = app.buttons["chat.toolbar.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "chat.toolbar.back did not appear")
        tap(back, named: "chat back")

        let sessionList = app.collectionViews["workspace.sessionList"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if sessionList.exists, sessionList.isHittable, !app.buttons["chat.toolbar.back"].exists {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Session list did not reappear after navigating back on iPhone")
    }
}
