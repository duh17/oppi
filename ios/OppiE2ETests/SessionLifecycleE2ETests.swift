import XCTest

/// End-to-end tests for session lifecycle: stopping mid-stream,
/// multi-turn conversations, and switching between sessions.
///
/// Requires the Docker server and MLX model server to be running.
/// Run via `ios/scripts/e2e.sh` which handles server lifecycle
/// and writes the invite URL to `/tmp/oppi-e2e-invite.txt`.
final class SessionLifecycleE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Tests

    func testStopMidStream() throws {
        try launchAndNavigateToWorkspace()
        try createAndEnterSession()

        // Send a prompt that produces a long response
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 30), "Chat input did not appear")
        chatInput.tap()
        chatInput.typeText("Write a detailed 500 word essay about the history of computing")

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3), "Send button not found")
        sendButton.tap()

        // Wait for streaming to start
        let stopButton = app.buttons["chat.stop"]
        XCTAssertTrue(
            stopButton.waitForExistence(timeout: 30),
            "Stop button never appeared — streaming did not start"
        )

        // Stop mid-stream
        stopButton.tap()

        // Verify streaming stopped (stop button disappears)
        let gonePredicate = NSPredicate(format: "exists == false")
        let stopGone = XCTNSPredicateExpectation(predicate: gonePredicate, object: stopButton)
        let stopResult = XCTWaiter.wait(for: [stopGone], timeout: 30)
        XCTAssertEqual(stopResult, .completed, "Stop button did not disappear after tapping stop")

        // Verify composer re-enables (chat input reappears)
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 15),
            "Chat input did not reappear after stopping stream"
        )
    }

    func testMultiTurnConversation() throws {
        try launchAndNavigateToWorkspace()
        try createAndEnterSession()

        // Turn 1
        sendMessageAndWaitForResponse("Reply with exactly: TURN_ONE_OK")
        let turnOne = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'TURN_ONE_OK'")
        ).firstMatch
        XCTAssertTrue(
            turnOne.waitForExistence(timeout: 10),
            "TURN_ONE_OK not found in timeline after first turn"
        )

        // Turn 2
        sendMessageAndWaitForResponse("Reply with exactly: TURN_TWO_OK")
        let turnTwo = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'TURN_TWO_OK'")
        ).firstMatch
        XCTAssertTrue(
            turnTwo.waitForExistence(timeout: 10),
            "TURN_TWO_OK not found in timeline after second turn"
        )
        // First turn marker should still be visible
        XCTAssertTrue(
            turnOne.exists,
            "TURN_ONE_OK disappeared after second turn"
        )

        // Turn 3
        sendMessageAndWaitForResponse("Reply with exactly: TURN_THREE_OK")
        let turnThree = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'TURN_THREE_OK'")
        ).firstMatch
        XCTAssertTrue(
            turnThree.waitForExistence(timeout: 10),
            "TURN_THREE_OK not found in timeline after third turn"
        )
        // All previous markers should still exist
        XCTAssertTrue(turnOne.exists, "TURN_ONE_OK missing after third turn")
        XCTAssertTrue(turnTwo.exists, "TURN_TWO_OK missing after third turn")
    }

    func testSessionSwitching() throws {
        try launchAndNavigateToWorkspace()

        // Create session A
        let newSessionButton = app.buttons["workspace.newSession"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 15), "New session button not found")
        newSessionButton.tap()
        sleep(3)

        // Create session B
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 15), "New session button not found for second session")
        newSessionButton.tap()
        sleep(3)

        // Enter session B (newest session, first after section header)
        let sessionList = app.collectionViews["workspace.sessionList"]
        let topSession = sessionList.cells.element(boundBy: 1)
        XCTAssertTrue(topSession.waitForExistence(timeout: 15), "Session B cell did not appear")
        topSession.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Send a message in session B
        sendMessageAndWaitForResponse("Reply with exactly: SESSION_B_MARKER")
        let markerB = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'SESSION_B_MARKER'")
        ).firstMatch
        XCTAssertTrue(
            markerB.waitForExistence(timeout: 10),
            "SESSION_B_MARKER not found in session B"
        )

        // Navigate back to session list
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "Session list did not reappear")

        // Enter session A (the other session, second row after header)
        let secondSession = sessionList.cells.element(boundBy: 2)
        XCTAssertTrue(secondSession.waitForExistence(timeout: 15), "Session A cell did not appear")
        secondSession.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Verify session B's marker is not in session A
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 30), "Chat input did not appear in session A")

        let staleMarker = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'SESSION_B_MARKER'")
        ).firstMatch
        XCTAssertFalse(
            staleMarker.waitForExistence(timeout: 5),
            "SESSION_B_MARKER leaked into session A"
        )

        // Send a message in session A
        sendMessageAndWaitForResponse("Reply with exactly: SESSION_A_MARKER")
        let markerA = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'SESSION_A_MARKER'")
        ).firstMatch
        XCTAssertTrue(
            markerA.waitForExistence(timeout: 10),
            "SESSION_A_MARKER not found in session A"
        )

        // Confirm session B's marker still absent
        XCTAssertFalse(
            staleMarker.exists,
            "SESSION_B_MARKER appeared in session A after sending a message"
        )
    }

    // MARK: - Helpers

    private func readInviteURL() throws -> String {
        let path = "/tmp/oppi-e2e-invite.txt"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("No invite URL found at \(path) — run ios/scripts/e2e.sh to set up server")
        }
        let url = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            throw XCTSkip("Invite URL file is empty")
        }
        return url
    }

    private func launchAndNavigateToWorkspace() throws {
        let inviteURL = try readInviteURL()

        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["PI_E2E_INVITE_URL"] = inviteURL
        app.launch()

        // Dismiss any system alerts
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            springboard.alerts.firstMatch.buttons.element(boundBy: 1).tap()
        }

        // Wait for Workspaces tab after pairing
        let workspacesNav = app.navigationBars["Workspaces"]
        XCTAssertTrue(
            workspacesNav.waitForExistence(timeout: 30),
            "Workspaces navigation bar did not appear after pairing"
        )

        // Find and tap the e2e-workspace cell
        let workspaceCell = app.collectionViews["workspace.list"]
            .cells.containing(.staticText, identifier: "e2e-workspace").firstMatch
        if !workspaceCell.waitForExistence(timeout: 30) {
            let list = app.collectionViews["workspace.list"]
            if list.exists {
                list.swipeDown()
                sleep(3)
            }
        }
        XCTAssertTrue(
            workspaceCell.waitForExistence(timeout: 15),
            "Workspace 'e2e-workspace' cell did not appear in list"
        )
        workspaceCell.tap()
    }

    private func createAndEnterSession() throws {
        let newSessionButton = app.buttons["workspace.newSession"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 15), "New session button not found")
        newSessionButton.tap()
        sleep(3)

        // Dismiss any system alerts
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            springboard.alerts.firstMatch.buttons.element(boundBy: 1).tap()
        }

        let sessionList = app.collectionViews["workspace.sessionList"]
        let sessionCell = sessionList.cells.element(boundBy: 1)
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 15), "Session cell did not appear")
        sessionCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 30), "Chat input did not appear after entering session")
    }

    /// Types a message, sends it, and waits for the full round-trip
    /// (stop button appears then disappears).
    private func sendMessageAndWaitForResponse(_ message: String) {
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 30), "Chat input not available before sending")
        chatInput.tap()
        chatInput.typeText(message)

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3), "Send button not found")
        sendButton.tap()

        // Wait for streaming to start then finish
        let stopButton = app.buttons["chat.stop"]
        if stopButton.waitForExistence(timeout: 30) {
            let predicate = NSPredicate(format: "exists == false")
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: stopButton)
            let result = XCTWaiter.wait(for: [expectation], timeout: 300)
            XCTAssertEqual(result, .completed, "Agent did not finish responding within 5 minutes")
        }

        // Confirm composer is ready for the next message
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 15),
            "Chat input did not reappear after response"
        )
    }
}
