import XCTest

/// E2E tests for session lifecycle: stopping mid-stream,
/// multi-turn conversations, and switching between sessions.
///
/// Requires the E2E server and local model endpoint to be running.
/// The E2E server harness writes the invite URL to `/tmp/oppi-e2e-invite.txt`.
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
        sendMessageAndWaitForResponse(localEchoPrompt("TURN_ONE_OK"))
        XCTAssertTrue(
            waitForTimelineTextContaining("TURN_ONE_OK"),
            "TURN_ONE_OK not found in timeline after first turn"
        )

        // Turn 2
        sendMessageAndWaitForResponse(localEchoPrompt("TURN_TWO_OK"))
        XCTAssertTrue(
            waitForTimelineTextContaining("TURN_TWO_OK"),
            "TURN_TWO_OK not found in timeline after second turn"
        )

        // Turn 3
        sendMessageAndWaitForResponse(localEchoPrompt("TURN_THREE_OK"))
        XCTAssertTrue(
            waitForTimelineTextContaining("TURN_THREE_OK"),
            "TURN_THREE_OK not found in timeline after third turn"
        )
    }

    func testSessionSwitching() throws {
        // Create session A, then go back and create session B.
        createSession()
        navigateBackToWorkspace()
        createSession()

        sendMessageAndWaitForResponse(localEchoPrompt("SESSION_B_MARKER"))
        XCTAssertTrue(
            waitForTimelineTextContaining("SESSION_B_MARKER"),
            "SESSION_B_MARKER not found in session B"
        )

        // Navigate back and enter session A (older session, index 2)
        navigateBackToWorkspace()
        enterSession(at: 2)

        // Verify session B's marker is not in session A
        XCTAssertFalse(
            waitForTimelineTextContaining("SESSION_B_MARKER", timeout: 5),
            "SESSION_B_MARKER leaked into session A"
        )

        // Send a message in session A
        sendMessageAndWaitForResponse(localEchoPrompt("SESSION_A_MARKER"))
        XCTAssertTrue(
            waitForTimelineTextContaining("SESSION_A_MARKER"),
            "SESSION_A_MARKER not found in session A"
        )

        // Confirm session B's marker still absent
        XCTAssertFalse(
            waitForTimelineTextContaining("SESSION_B_MARKER", timeout: 2),
            "SESSION_B_MARKER appeared in session A after sending a message"
        )
    }
}
