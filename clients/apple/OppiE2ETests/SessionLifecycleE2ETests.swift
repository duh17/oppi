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
        tap(chatInput, named: "chat input")
        chatInput.typeText("Write a detailed 500 word essay about the history of computing")

        let sendButton = app.buttons["chat.send"]
        tap(sendButton, named: "send button", timeout: 3)

        // Wait for streaming to start
        let stopButton = app.buttons["chat.stop"]
        XCTAssertTrue(
            stopButton.waitForExistence(timeout: 30),
            "Stop button never appeared — streaming did not start"
        )

        // Stop mid-stream
        tap(stopButton, named: "stop button")

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

    func testSlashCommandSuggestionsRemainAvailableMidTurn() throws {
        createAndEnterSession()

        let chatInput = app.textViews["chat.input"]
        tap(chatInput, named: "chat input")
        chatInput.typeText("Write a detailed 500 word essay about the history of computing")
        tap(app.buttons["chat.send"], named: "send button", timeout: 3)

        let stopButton = app.buttons["chat.stop"]
        XCTAssertTrue(
            stopButton.waitForExistence(timeout: 30),
            "Streaming did not start before checking slash suggestions"
        )

        tap(chatInput, named: "chat input during active turn")
        chatInput.typeText("/")

        let reloadSuggestion = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "/reload"))
            .firstMatch
        XCTAssertTrue(
            reloadSuggestion.waitForExistence(timeout: 10),
            "Slash command suggestions did not appear during the active turn"
        )
        tap(reloadSuggestion, named: "reload slash suggestion")
        XCTAssertEqual(
            chatInput.value as? String,
            "/reload ",
            "Selecting a slash suggestion did not update the active-turn composer"
        )
        XCTAssertTrue(
            app.buttons["chat.busyMode"].exists,
            "Selecting a slash command left active-turn Steering/Follow-up mode"
        )

        chatInput.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        XCTAssertTrue(
            stopButton.waitForExistence(timeout: 3),
            "Stop action did not return after clearing the selected slash command"
        )
        tap(stopButton, named: "stop button")
    }

    func testBusyModePickerUsesStablePopoverOrderAndSelection() throws {
        createAndEnterSession()

        let chatInput = app.textViews["chat.input"]
        tap(chatInput, named: "chat input")
        chatInput.typeText("Write a detailed 500 word essay about the history of computing")
        tap(app.buttons["chat.send"], named: "send button", timeout: 3)

        let stopButton = app.buttons["chat.stop"]
        XCTAssertTrue(
            stopButton.waitForExistence(timeout: 30),
            "Streaming did not start before checking the busy mode picker"
        )

        let picker = app.buttons["chat.busyMode"]
        tap(picker, named: "busy mode picker", timeout: 5)

        let steering = app.buttons["chat.busyMode.option.steer"]
        let followUp = app.buttons["chat.busyMode.option.followUp"]
        XCTAssertTrue(steering.waitForExistence(timeout: 5), "Steering option did not appear")
        XCTAssertTrue(followUp.waitForExistence(timeout: 5), "Follow-up option did not appear")
        XCTAssertEqual(steering.label, "Steering")
        XCTAssertEqual(followUp.label, "Follow-up")
        XCTAssertLessThan(
            steering.frame.midY,
            followUp.frame.midY,
            "Busy mode picker must keep Steering above Follow-up"
        )
        XCTAssertEqual(steering.value as? String, "Selected")

        tap(followUp, named: "Follow-up busy mode", timeout: 5)
        XCTAssertEqual(picker.value as? String, "Follow-up")

        tap(stopButton, named: "stop button")
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

    func testTreeNavigationSwitchesBranchWithoutSummary() throws {
        createAndEnterSession()

        let firstMarker = "TREE_BRANCH_ONE"
        let abandonedMarker = "TREE_BRANCH_TWO"
        sendMessageAndWaitForResponse(localEchoPrompt(firstMarker))
        sendMessageAndWaitForResponse(localEchoPrompt(abandonedMarker))

        let outlineButton = app.buttons["chat.toolbar.outline"]
        tap(outlineButton, named: "session outline toolbar button")
        XCTAssertTrue(
            app.navigationBars["Session Outline"].waitForExistence(timeout: 10),
            "Session outline did not open"
        )

        let treeTab = app.buttons["Tree"]
        tap(treeTab, named: "session tree tab")

        let firstBranchNode = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", firstMarker))
            .firstMatch
        XCTAssertTrue(
            firstBranchNode.waitForExistence(timeout: 10),
            "First branch target did not appear in the real session tree"
        )
        tap(firstBranchNode, named: "first branch tree node")

        let switchWithoutSummary = app.buttons["Switch without summary"]
        tap(switchWithoutSummary, named: "switch without summary")

        let outlineNavigationBar = app.navigationBars["Session Outline"]
        let outlineDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: outlineNavigationBar
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [outlineDismissed], timeout: 15),
            .completed,
            "Successful tree navigation did not dismiss the session outline"
        )

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10), "Chat input did not return after tree navigation")
        XCTAssertTrue(
            (chatInput.value as? String)?.contains(firstMarker) == true,
            "Tree navigation did not restore the selected user message into the composer"
        )

        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "Chat timeline did not return after tree navigation")
        for marker in [firstMarker, abandonedMarker] {
            let staleTimelineText = timeline.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", marker, marker))
                .firstMatch
            XCTAssertFalse(
                staleTimelineText.exists,
                "Tree navigation left \(marker) in the active timeline instead of rewinding before the selected prompt"
            )
        }
    }

    func testSessionSwitching() throws {
        // Create session A, then go back and create session B.
        createSession()
        let sessionAId = waitForFocusedSessionId(timeout: 30)
        navigateBackToWorkspace()
        createSession()
        _ = waitForFocusedSessionId(excluding: sessionAId, timeout: 30)

        sendMessageAndWaitForResponse(localEchoPrompt("SESSION_B_MARKER"))
        XCTAssertTrue(
            waitForTimelineTextContaining("SESSION_B_MARKER"),
            "SESSION_B_MARKER not found in session B"
        )

        // Navigate back and enter session A by stable session identifier.
        navigateBackToWorkspace()
        enterSession(id: sessionAId)

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
