import XCTest

private enum E2ELifecycleStressError: Error {
    case missingSubscriberCount
    case noBackgroundSubscriber
}

/// First paired-server oracle for same-process scene recovery while a focused
/// chat remains busy. It intentionally uses harness events, not a model turn.
@MainActor
final class LifecycleSceneStressE2ETests: E2ETestCase {
    private static let cycleCount = 20

    override var e2eLaunchesSessionsInboxOnly: Bool {
        name.contains("testSessionsInboxSurvivesTwentySceneCycles")
    }

    override var e2eStartsInAutoCreatedChat: Bool {
        !e2eLaunchesSessionsInboxOnly
    }

    override var e2eRequiresFreshLaunch: Bool { true }

    func testStreamingChatSurvivesTwentySceneCycles() throws {
        createAndEnterSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: sessionId, level: "full")

        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        defer { _ = try? sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"]) }

        let stopButton = app.buttons["chat.stop"]
        XCTAssertTrue(waitForElementToExist(stopButton, timeout: 10), "Busy chat did not show its stop control")
        var lifecycle = e2eLifecycleSnapshot()
        var snapshots: [E2ELifecycleDiagnosticSnapshot] = []
        var backgroundSubscriberCounts: [Int] = []

        for cycle in 1...Self.cycleCount {
            let toolCallId = "lifecycle-live-output-\(cycle)"
            let marker = "E2E_LIVE_BACKGROUND_OUTPUT_\(cycle)"
            try sendE2EHarnessMessage(sessionId: sessionId, [
                "type": "tool_start",
                "tool": "read",
                "toolCallId": toolCallId,
                "args": ["path": "lifecycle-marker-\(cycle).txt"],
            ])
            let toolRow = app.descendants(matching: .any)["chat.timeline.row.\(toolCallId)"]
            guard toolRow.waitForExistence(timeout: 10) else {
                recordLifecycleCycleFailure(scenario: "busy", cycle: cycle, message: "Tool row did not appear before Home")
                return
            }

            lifecycle = try backgroundAndActivate(after: lifecycle, scenario: "busy", cycle: cycle) {
                let outputResponse = try sendE2EHarnessMessage(sessionId: sessionId, [
                    "type": "tool_output",
                    "toolCallId": toolCallId,
                    "output": marker,
                ])
                guard let subscriberCount = outputResponse["subscriberCount"] as? Int else {
                    self.recordLifecycleCycleFailure(
                        scenario: "busy",
                        cycle: cycle,
                        message: "Background tool output response omitted subscriberCount"
                    )
                    throw E2ELifecycleStressError.missingSubscriberCount
                }
                backgroundSubscriberCounts.append(subscriberCount)
                guard subscriberCount == 1 else {
                    self.recordLifecycleCycleFailure(
                        scenario: "busy",
                        cycle: cycle,
                        message: "Busy stream expected exactly one subscriber for background tool output; observed \(subscriberCount)"
                    )
                    throw E2ELifecycleStressError.noBackgroundSubscriber
                }
            }
            snapshots.append(lifecycle)

            guard e2eDiagnosticMatches("e2e.ws.status", timeout: 10, matching: { $0 == "connected" }),
                  e2eDiagnosticMatches("e2e.ws.focusedSession", timeout: 10, matching: { $0 == sessionId }),
                  e2eDiagnosticMatches("e2e.ws.ackedSubscriptions", timeout: 10, matching: { $0 == "\(sessionId):full" }) else {
                recordLifecycleCycleFailure(scenario: "busy", cycle: cycle, message: "Focused stream did not recover its full subscription")
                return
            }

            tapToolRowChrome(toolRow)
            guard waitForTimelineTextContaining(marker, timeout: 10) else {
                recordLifecycleCycleFailure(
                    scenario: "busy",
                    cycle: cycle,
                    message: "Live background tool output was not rendered after foreground activation"
                )
                return
            }
            try sendE2EHarnessMessage(sessionId: sessionId, [
                "type": "tool_end",
                "tool": "read",
                "toolCallId": toolCallId,
            ])

            // The harness does not persist synthetic agent status in the server
            // session snapshot. Reassert its busy event after the foreground
            // refresh so every next cycle starts from the busy chat UI.
            try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
            guard waitForElementToExist(stopButton, timeout: 10) else {
                recordLifecycleCycleFailure(scenario: "busy", cycle: cycle, message: "Busy chat controls did not recover")
                return
            }
            guard app.buttons["chat.toolbar.files"].exists else {
                recordLifecycleCycleFailure(scenario: "busy", cycle: cycle, message: "Chat UI did not recover")
                return
            }
        }

        print("METRIC lifecycle_busy_live_output_background_subscribers=\(backgroundSubscriberCounts)")
        reportLifecycleDurations(snapshots, scenario: "busy")
    }

    func testSessionsInboxSurvivesTwentySceneCycles() throws {
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(waitForElementToExist(inbox, timeout: 10), "HTTP-first sessions inbox did not appear")
        var lifecycle = e2eLifecycleSnapshot()
        var snapshots: [E2ELifecycleDiagnosticSnapshot] = []

        for cycle in 1...Self.cycleCount {
            lifecycle = try backgroundAndActivate(after: lifecycle, scenario: "inbox", cycle: cycle)
            snapshots.append(lifecycle)

            guard waitForElementToExist(inbox, timeout: 5), inbox.isHittable else {
                recordLifecycleCycleFailure(scenario: "inbox", cycle: cycle, message: "HTTP-first sessions inbox did not return interactively")
                return
            }
            guard e2eDiagnosticMatches("e2e.ws.focusedSession", timeout: 5, matching: { $0 == "none" }),
                  e2eDiagnosticMatches("e2e.ws.desiredSubscriptions", timeout: 5, matching: { $0 == "none" }),
                  e2eDiagnosticMatches("e2e.ws.ackedSubscriptions", timeout: 5, matching: { $0 == "none" }) else {
                recordLifecycleCycleFailure(scenario: "inbox", cycle: cycle, message: "Inbox unexpectedly opened a focused session stream")
                return
            }
        }

        reportLifecycleDurations(snapshots, scenario: "inbox")
    }

    /// Exercises the draft-present lifecycle path only. Process-relaunch
    /// persistence remains owned by RecoveryE2ETests.
    func testIdleChatVisibleDraftSurvivesTwentySceneCycles() throws {
        createAndEnterSession()
        let draft = "E2E_LIFECYCLE_DRAFT " + String(
            repeating: "Preserve this valid draft through synchronous lifecycle fallback. ",
            count: 32
        )
        let input = app.textViews["chat.input"]
        XCTAssertTrue(waitForElementToExist(input, timeout: 10), "Chat input did not appear")
        input.tap()
        input.typeText(draft)
        XCTAssertTrue(waitForInputValue(input, equals: draft, timeout: 10), "Large draft did not enter the composer")

        var lifecycle = e2eLifecycleSnapshot()
        var snapshots: [E2ELifecycleDiagnosticSnapshot] = []
        for cycle in 1...Self.cycleCount {
            lifecycle = try backgroundAndActivate(after: lifecycle, scenario: "idle_draft", cycle: cycle)
            snapshots.append(lifecycle)

            guard waitForElementToExist(input, timeout: 5),
                  waitForInputValue(input, equals: draft, timeout: 5),
                  input.isEnabled else {
                recordLifecycleCycleFailure(scenario: "idle_draft", cycle: cycle, message: "Visible in-process draft did not remain usable")
                return
            }
        }

        reportLifecycleDurations(snapshots, scenario: "idle_chat_draft")
    }

    private func waitForInputValue(_ element: XCUIElement, equals expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.value as? String == expected
    }

    private func tapToolRowChrome(_ row: XCUIElement) {
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.16)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func reportLifecycleDurations(_ snapshots: [E2ELifecycleDiagnosticSnapshot], scenario: String) {
        let backgroundMax = snapshots.map(\.backgroundDurationMs).max() ?? 0
        let activeMax = snapshots.map(\.activeDurationMs).max() ?? 0
        print("METRIC lifecycle_\(scenario)_app_owned_sync_background_handler_max_ms=\(backgroundMax)")
        print("METRIC lifecycle_\(scenario)_app_owned_sync_active_handler_max_ms=\(activeMax)")
    }
}
