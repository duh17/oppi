import XCTest

/// Focused connectivity coverage for session stream recovery.
final class RecoveryE2ETests: E2ETestCase {
    override var e2eRequiresFreshLaunch: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    @MainActor
    func testRelaunchRecoveryReplaysDurableEventsForFocusedSession() throws {
        createAndEnterSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: sessionId, level: "full")

        let toolCallId = "recovery-catchup-tool"

        XCUIDevice.shared.press(.home)
        waitForAppToLeaveForeground(timeout: 5)
        app.terminate()
        try waitForE2EHarnessSubscriberCount(sessionId: sessionId, 0, timeout: 10)

        let startResponse = try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": "read",
            "toolCallId": toolCallId,
            "args": ["path": "recovery-catchup.txt"],
        ])
        XCTAssertEqual(startResponse["subscriberCount"] as? Int, 0, "Tool start should be emitted while the session stream is disconnected")
        let endResponse = try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": "read",
            "toolCallId": toolCallId,
            "details": ["output": "E2E_RECOVERY_CATCHUP_OK"],
        ])
        XCTAssertEqual(endResponse["subscriberCount"] as? Int, 0, "Tool end should be emitted while the session stream is disconnected")

        app.launch()
        enterSession(id: sessionId)
        XCTAssertTrue(waitForElementToExist(app.textViews["chat.input"], timeout: 20), "Chat input did not return after relaunching")
        waitForSessionStreamEndpoint()
        XCTAssertEqual(waitForFocusedSessionId(sessionId, timeout: 20), sessionId)
        waitForAckedSubscription(sessionId: sessionId, level: "full")
        XCTAssertTrue(
            waitForElementToExist(app.descendants(matching: .any)["chat.timeline.row.\(toolCallId)"], timeout: 20),
            "Durable tool row emitted while disconnected was not replayed after relaunch recovery"
        )
    }

    @MainActor
    private func waitForAppToLeaveForeground(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while app.state == .runningForeground && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertNotEqual(app.state, .runningForeground, "App did not leave foreground after Home button")
    }
}
