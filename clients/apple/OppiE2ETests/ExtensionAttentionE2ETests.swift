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

}
