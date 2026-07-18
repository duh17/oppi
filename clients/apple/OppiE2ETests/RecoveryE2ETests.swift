import XCTest

/// Focused connectivity coverage for session stream recovery.
final class RecoveryE2ETests: E2ETestCase {
    override var e2eRequiresFreshLaunch: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    @MainActor
    func testComposerDraftSurvivesSessionSwitchAndProcessRelaunch() throws {
        createAndEnterSession()
        let draftSessionID = waitForFocusedSessionId(timeout: 20)
        let draft = "E2E draft survives background and relaunch"
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10), "Chat input did not appear")
        chatInput.tap()
        chatInput.typeText(draft)
        XCTAssertTrue(waitForTextValue(chatInput, equals: draft, timeout: 5), "Draft did not enter the composer")

        // Leave immediately after the latest edit. This exercises the synchronous
        // lifecycle snapshot instead of relying on the debounced file write.
        XCUIDevice.shared.press(.home)
        waitForAppToLeaveForeground(timeout: 5)
        app.terminate()
        app.launch()
        enterSession(id: draftSessionID)

        let restoredInput = app.textViews["chat.input"]
        XCTAssertTrue(
            waitForTextValue(restoredInput, equals: draft, timeout: 10),
            "Draft did not restore after immediate process relaunch"
        )

        navigateBackToWorkspace()
        createAndEnterSession()
        let otherSessionID = waitForFocusedSessionId(excluding: draftSessionID, timeout: 20)
        XCTAssertNotEqual(otherSessionID, draftSessionID)
        XCTAssertFalse(
            waitForTextValue(app.textViews["chat.input"], equals: draft, timeout: 1),
            "Draft leaked into another session in the same workspace"
        )

        navigateBackToWorkspace()
        enterSession(id: draftSessionID)
        XCTAssertTrue(
            waitForTextValue(app.textViews["chat.input"], equals: draft, timeout: 10),
            "Draft did not restore after switching sessions"
        )

        tap(app.buttons["chat.send"], named: "draft send button", timeout: 5)
        XCTAssertTrue(
            waitForTextValueToDiffer(restoredInput, from: draft, timeout: 10),
            "Composer did not clear after dispatch"
        )
        XCTAssertTrue(
            waitForClientDispatchAcknowledgement(timeout: 10),
            "Client did not process the dispatched send acknowledgement"
        )

        XCUIDevice.shared.press(.home)
        waitForAppToLeaveForeground(timeout: 5)
        app.terminate()
        app.launch()
        enterSession(id: draftSessionID)
        XCTAssertFalse(
            waitForTextValue(app.textViews["chat.input"], equals: draft, timeout: 2),
            "Acknowledged draft returned after relaunch"
        )
    }

    @MainActor
    func testIrohForegroundRecoveryReplacesTransportWithoutProcessRestart() throws {
        guard ProcessInfo.processInfo.environment["OPPI_E2E_IROH_PAIRING"] == "1" else {
            throw XCTSkip("Run with OPPI_E2E_IROH_PAIRING=1 to exercise the Apple Iroh transport")
        }
        defer { terminateSharedApp() }

        XCTAssertEqual(waitForTransportPath("iroh"), "iroh")
        createAndEnterSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: sessionId, level: "full")
        let connectionIDBeforeBackground = waitForWebSocketConnectionID()

        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        defer { _ = try? sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"]) }
        XCTAssertTrue(
            waitForElementToExist(app.buttons["chat.stop"], timeout: 10),
            "Busy chat did not show its stop control before backgrounding"
        )

        let lifecycleBeforeBackground = e2eLifecycleSnapshot()
        _ = try backgroundAndActivate(
            after: lifecycleBeforeBackground,
            scenario: "iroh_foreground_recovery",
            cycle: 1
        )

        XCTAssertEqual(waitForTransportPath("iroh"), "iroh")
        let connectionIDAfterForeground = waitForWebSocketConnectionID(
            greaterThan: connectionIDBeforeBackground
        )
        XCTAssertGreaterThan(connectionIDAfterForeground, connectionIDBeforeBackground)
        waitForWebSocketConnected()
        waitForAckedSubscription(sessionId: sessionId, level: "full")
        try waitForE2EHarnessSubscriberCount(sessionId: sessionId, 1, timeout: 20)

        let toolCallId = "iroh-foreground-recovery-tool"
        let marker = "E2E_IROH_FOREGROUND_RECOVERY_OK"
        let startResponse = try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": "read",
            "toolCallId": toolCallId,
            "args": ["path": "iroh-foreground-recovery.txt"],
        ])
        XCTAssertEqual(startResponse["subscriberCount"] as? Int, 1)
        let toolRow = app.descendants(matching: .any)["chat.timeline.row.\(toolCallId)"]
        XCTAssertTrue(
            waitForElementToExist(toolRow, timeout: 10),
            "Post-recovery event did not reach the focused-session continuation"
        )
        let outputResponse = try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_output",
            "toolCallId": toolCallId,
            "output": marker,
        ])
        XCTAssertEqual(outputResponse["subscriberCount"] as? Int, 1)
        toolRow.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.16)).tap()
        XCTAssertTrue(
            waitForTimelineTextContaining(marker, timeout: 10),
            "Post-recovery tool output did not render through the preserved continuation"
        )
        _ = try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": "read",
            "toolCallId": toolCallId,
        ])

        navigateBackToWorkspace()
        XCTAssertFalse(
            app.descendants(matching: .any)["workspace.sessionList.cachedWarning"].waitForExistence(timeout: 1),
            "Selected Iroh server still showed cached data after foreground recovery"
        )
    }

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
    private func waitForTextValue(
        _ element: XCUIElement,
        equals expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.value as? String == expected
    }

    @MainActor
    private func waitForTextValueToDiffer(
        _ element: XCUIElement,
        from value: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String != value {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.value as? String != value
    }

    @MainActor
    private func waitForClientDispatchAcknowledgement(timeout: TimeInterval) -> Bool {
        let progress = app.staticTexts["chat.sendProgress"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if progress.exists,
               progress.label == "Dispatched…" || progress.label == "Started…" {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return progress.exists
            && (progress.label == "Dispatched…" || progress.label == "Started…")
    }

}
