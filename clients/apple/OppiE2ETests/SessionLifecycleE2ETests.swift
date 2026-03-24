import XCTest

/// E2E tests for session lifecycle: stopping mid-stream,
/// multi-turn conversations, and switching between sessions.
///
/// Requires the Docker server and MLX model server to be running.
/// Run via `ios/scripts/e2e.sh` which handles server lifecycle
/// and writes the invite URL to `/tmp/oppi-e2e-invite.txt`.
final class SessionLifecycleE2ETests: E2ETestCase {

    // MARK: - Tests

    func testStopMidStream() throws {
        createAndEnterSession()

        // Send a prompt that produces a long response
        let chatInput = app.textViews["chat.input"]
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
        XCTAssertEqual(
            XCTWaiter.wait(for: [stopGone], timeout: 30), .completed,
            "Stop button did not disappear after tapping stop"
        )

        // Verify composer re-enables
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 15),
            "Chat input did not reappear after stopping stream"
        )
    }

    func testMultiTurnConversation() throws {
        createAndEnterSession()

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
        XCTAssertTrue(turnOne.exists, "TURN_ONE_OK disappeared after second turn")

        // Turn 3
        sendMessageAndWaitForResponse("Reply with exactly: TURN_THREE_OK")
        let turnThree = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'TURN_THREE_OK'")
        ).firstMatch
        XCTAssertTrue(
            turnThree.waitForExistence(timeout: 10),
            "TURN_THREE_OK not found in timeline after third turn"
        )
        XCTAssertTrue(turnOne.exists, "TURN_ONE_OK missing after third turn")
        XCTAssertTrue(turnTwo.exists, "TURN_TWO_OK missing after third turn")
    }

    func testSessionSwitching() throws {
        // Create two sessions (both stay at workspace detail)
        createSession()
        createSession()

        // Enter session B (newest, index 1 after header)
        enterLatestSession()

        sendMessageAndWaitForResponse("Reply with exactly: SESSION_B_MARKER")
        let markerB = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'SESSION_B_MARKER'")
        ).firstMatch
        XCTAssertTrue(
            markerB.waitForExistence(timeout: 10),
            "SESSION_B_MARKER not found in session B"
        )

        // Navigate back and enter session A (older session, index 2)
        navigateBackToWorkspace()
        enterSession(at: 2)

        // Verify session B's marker is not in session A
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
}
