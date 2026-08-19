import XCTest

/// Focused coverage for cross-session ask attention.
final class ExtensionAttentionE2ETests: E2ETestCase {
    @MainActor
    func testBackgroundAskMovesSessionToYourTurnAndOpensAskCard() throws {
        createAndEnterSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        let backgroundSession = waitForFocusedSessionId(timeout: 20)

        navigateBackToWorkspace()
        createSession()
        let focusedSession = waitForFocusedSessionId(excluding: backgroundSession, timeout: 20)

        let requestId = "background-ask-attention"
        let question = "E2E background ask prompt"
        let requestPayload: [String: Any] = [
            "type": "extension_ui_request",
            "id": requestId,
            "method": "ask",
            "allowCustom": false,
            "questions": [[
                "id": "background",
                "question": question,
                "multiSelect": false,
                "options": [[
                    "value": "background-approve",
                    "label": "Approve background ask",
                ]],
            ]],
        ]
        try clearE2EHarnessResponses(sessionId: backgroundSession)
        try sendE2EHarnessMessage(sessionId: backgroundSession, requestPayload)

        XCTAssertEqual(waitForFocusedSessionId(focusedSession, timeout: 5), focusedSession)
        navigateBackToWorkspace()

        XCTAssertTrue(waitForElementToExist(app.staticTexts["Your Turn"], timeout: 20), "Your Turn section did not appear")
        XCTAssertTrue(
            waitForElementToExist(app.descendants(matching: .any)["session.nav.\(backgroundSession)"], timeout: 20),
            "Background session did not appear in the session list"
        )
        openSessionDeepLink(id: backgroundSession)
        XCTAssertEqual(waitForFocusedSessionId(backgroundSession, timeout: 20), backgroundSession)
        let option = app.buttons["ask.option.background-approve"]
        if !waitForElementToExist(option, timeout: 5) {
            let expand = app.buttons["ask.expand"]
            if waitForElementToExist(expand, timeout: 5) {
                tap(expand, named: "background ask expand", timeout: 1)
            }
        }
        XCTAssertTrue(waitForElementToExist(option, timeout: 20), "Background ask card did not open in the target chat")
        tap(option, named: "background ask option", timeout: 1)

        let response = try waitForE2EHarnessResponse(sessionId: backgroundSession, requestId: requestId)
        XCTAssertEqual(response["value"] as? String, "{\"background\":\"background-approve\"}")
        XCTAssertNil(response["cancelled"])
        try settleE2EUIRequest(sessionId: backgroundSession, requestId: requestId)
    }

    /// Notification tap / `oppi://session` open must show the ask card and a
    /// real timeline row, not a blank thread with only the permission card.
    @MainActor
    func testNotificationStyleOpenShowsAskCardAndTimeline() throws {
        createAndEnterSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        let backgroundSession = waitForFocusedSessionId(timeout: 20)

        try sendE2EHarnessMessage(sessionId: backgroundSession, ["type": "agent_start"])
        try sendE2EHarnessMessage(sessionId: backgroundSession, [
            "type": "text_delta",
            "delta": "NOTIFY_TAP_TIMELINE_OK",
        ])
        try sendE2EHarnessMessage(sessionId: backgroundSession, [
            "type": "message_end",
            "role": "assistant",
            "content": "NOTIFY_TAP_TIMELINE_OK",
            "persist": true,
        ])
        try sendE2EHarnessMessage(sessionId: backgroundSession, ["type": "agent_end"])
        XCTAssertTrue(
            waitForTimelineTextContaining("NOTIFY_TAP_TIMELINE_OK", timeout: 20),
            "Seeded timeline row did not appear before leaving the session"
        )

        navigateBackToWorkspace()
        createSession()
        let focusedSession = waitForFocusedSessionId(excluding: backgroundSession, timeout: 20)

        let requestId = "notify-tap-ask-timeline"
        let question = "E2E notify-tap ask prompt"
        let requestPayload: [String: Any] = [
            "type": "extension_ui_request",
            "id": requestId,
            "method": "ask",
            "allowCustom": false,
            "questions": [[
                "id": "notify-tap",
                "question": question,
                "multiSelect": false,
                "options": [[
                    "value": "notify-tap-approve",
                    "label": "Approve notify-tap ask",
                ]],
            ]],
        ]
        try clearE2EHarnessResponses(sessionId: backgroundSession)
        try sendE2EHarnessMessage(sessionId: backgroundSession, requestPayload)

        XCTAssertEqual(waitForFocusedSessionId(focusedSession, timeout: 5), focusedSession)
        navigateBackToWorkspace()

        XCTAssertTrue(waitForElementToExist(app.staticTexts["Your Turn"], timeout: 20), "Your Turn section did not appear")
        openSessionDeepLink(id: backgroundSession)
        XCTAssertEqual(waitForFocusedSessionId(backgroundSession, timeout: 20), backgroundSession)
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()

        let option = app.buttons["ask.option.notify-tap-approve"]
        if !waitForElementToExist(option, timeout: 5) {
            let expand = app.buttons["ask.expand"]
            if waitForElementToExist(expand, timeout: 5) {
                tap(expand, named: "notify-tap ask expand", timeout: 1)
            }
        }
        XCTAssertTrue(waitForElementToExist(option, timeout: 20), "Ask card did not open after notification-style session open")
        XCTAssertTrue(
            waitForTimelineTextContaining("NOTIFY_TAP_TIMELINE_OK", timeout: 20),
            "Notification-style open must show a timeline row, not a blank thread"
        )
        tap(option, named: "notify-tap ask option", timeout: 1)

        let response = try waitForE2EHarnessResponse(sessionId: backgroundSession, requestId: requestId)
        XCTAssertEqual(response["value"] as? String, "{\"notify-tap\":\"notify-tap-approve\"}")
        XCTAssertNil(response["cancelled"])
        try settleE2EUIRequest(sessionId: backgroundSession, requestId: requestId)
    }

}
