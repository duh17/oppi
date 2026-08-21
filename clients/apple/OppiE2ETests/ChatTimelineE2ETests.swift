import Foundation
import XCTest

/// E2E test that pairs with a real E2E server,
/// sends a chat message, and verifies the timeline renders.
///
/// Requires the E2E server and local model endpoint to be running.
/// The E2E server harness writes the invite URL to `/tmp/oppi-e2e-invite.txt`.
@MainActor
final class ChatTimelineE2ETests: E2ETestCase {

    nonisolated private var usesCompactTurnsFixture: Bool {
        name.contains("testQuietModeFinishedTurnAndControlsStaySynchronized")
    }

    override func setUpWithError() throws {
        let shouldPrepareCompactTurns = usesCompactTurnsFixture
        if shouldPrepareCompactTurns {
            terminateSharedApp()
        }

        do {
            try super.setUpWithError()
        } catch {
            if shouldPrepareCompactTurns {
                terminateSharedApp()
                setCompactTurnsPreference(enabled: false)
            }
            throw error
        }
    }

    override func tearDownWithError() throws {
        if usesCompactTurnsFixture {
            // XCTest still calls teardown after an assertion aborts. Stop the
            // process before resetting its persisted defaults, then invalidate
            // the shared handle so the next E2E must launch and read the reset.
            terminateSharedApp()
            setCompactTurnsPreference(enabled: false)
        }
        try super.tearDownWithError()
    }

    func testSendMessageAndReceiveResponse() throws {
        createAndEnterSession()

        sendMessageAndWaitForResponse(localEchoPrompt("E2E_CHAT_OK"))

        XCTAssertTrue(
            waitForTimelineTextContaining("E2E_CHAT_OK"),
            "E2E_CHAT_OK did not appear in timeline"
        )
    }

    /// Paired-server proof of Compact turns after `agent_end` + `agent_settled`.
    /// Device Settings is the control; there is no chat chip.
    func testQuietModeFinishedTurnAndControlsStaySynchronized() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        XCTAssertFalse(app.buttons["chat.quietMode"].exists, "Compact turns must not show a chat chip")
        let sessionId = waitForFocusedSessionId(timeout: 20)

        navigateBackToWorkspace()
        openAppSettingsFromSessionList()
        let settingsCompactTurns = app.switches["settings.compactTurns"]
        XCTAssertTrue(settingsCompactTurns.waitForExistence(timeout: 10), "Settings Compact turns toggle did not appear")
        if !isSwitchOn(settingsCompactTurns) {
            tap(settingsCompactTurns, named: "Settings Compact turns toggle")
        }
        XCTAssertTrue(
            waitForSwitch(settingsCompactTurns, toBeOn: true, timeout: 5),
            "Settings Compact turns did not turn On for this fold fixture"
        )
        closeAppSettingsToSessionList()
        openSessionDeepLink(id: sessionId)

        let userPrompt = "QUIET_USER_PROMPT"
        let thinkingPlan = "QUIET_THINKING_PLAN"
        let thinkingNext = "QUIET_THINKING_NEXT"
        let bashOutput = "QUIET_TOOL_BASH"
        let readOutput = "QUIET_TOOL_READ"
        let grepOutput = "QUIET_TOOL_GREP"
        let liveAssistant = "QUIET_LIVE_ASSISTANT"
        let finishedAssistant = "QUIET_FINISHED_ASSISTANT"
        let hiddenAfterFold = [thinkingPlan, thinkingNext, bashOutput, readOutput, grepOutput]

        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "message_end",
            "role": "user",
            "content": userPrompt,
        ])
        XCTAssertTrue(waitForTimelineTextContaining(userPrompt, timeout: 10), "User prompt did not appear")

        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setToolsExpanded",
            "toolsExpanded": true,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        let stopButton = app.buttons["chat.stop"]
        XCTAssertTrue(
            waitForElementToExist(stopButton, timeout: 10),
            "Live turn did not enter busy after agent_start"
        )

        let workLine = quietWorkLine()
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "thinking_delta",
            "delta": thinkingPlan,
            "contentIndex": 0,
        ])
        XCTAssertTrue(waitForWorkLine(workLine, label: "1 thinking block", timeout: 10), "Live work line did not count thinking")
        XCTAssertFalse(timelineContains(thinkingPlan), "Live thinking should stay behind the work line")

        try sendFinishedTool(
            sessionId: sessionId,
            tool: "bash",
            toolCallId: "quiet-mode-bash",
            args: ["command": "printf bash-quiet"],
            output: bashOutput
        )
        XCTAssertTrue(waitForWorkLine(workLine, label: "1 tool, 1 thinking block", timeout: 10), "Live work line did not count bash")
        XCTAssertFalse(timelineContains(bashOutput), "Live bash output should stay behind the work line")

        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "thinking_delta",
            "delta": thinkingNext,
            "contentIndex": 2,
        ])
        XCTAssertTrue(waitForWorkLine(workLine, label: "1 tool, 2 thinking blocks", timeout: 10), "Live work line did not count follow-up thinking")
        XCTAssertFalse(timelineContains(thinkingNext), "Live follow-up thinking should stay behind the work line")

        try sendFinishedTool(
            sessionId: sessionId,
            tool: "read",
            toolCallId: "quiet-mode-read",
            args: ["path": "README.md"],
            output: readOutput
        )
        XCTAssertTrue(waitForWorkLine(workLine, label: "2 tools, 2 thinking blocks", timeout: 10), "Live work line did not count read")
        XCTAssertFalse(timelineContains(readOutput), "Live read output should stay behind the work line")

        try sendFinishedTool(
            sessionId: sessionId,
            tool: "grep",
            toolCallId: "quiet-mode-grep",
            args: ["pattern": "quiet-mode"],
            output: grepOutput
        )
        XCTAssertTrue(waitForWorkLine(workLine, label: "3 tools, 2 thinking blocks", timeout: 10), "Live work line did not count grep")
        XCTAssertFalse(timelineContains(grepOutput), "Live grep output should stay behind the work line")

        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "text_delta",
            "delta": liveAssistant,
        ])
        XCTAssertTrue(waitForTimelineTextContaining(liveAssistant, timeout: 10), "Live assistant text disappeared")

        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "message_end",
            "role": "assistant",
            "content": finishedAssistant,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])
        // Quiet Mode collapses only after the session store leaves busy.
        // agent_end closes one Pi run; agent_settled is the idle boundary.
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_settled"])
        XCTAssertTrue(
            waitForElementToDisappear(stopButton, timeout: 10),
            "Session stayed busy after agent_settled"
        )
        XCTAssertTrue(waitForElementToExist(app.textViews["chat.input"], timeout: 15), "Finished turn did not return the composer")
        XCTAssertTrue(waitForTimelineTextContaining(finishedAssistant, timeout: 10), "Finished assistant text disappeared")
        XCTAssertTrue(timelineContains(userPrompt), "Quiet Mode must keep the user prompt visible")

        XCTAssertTrue(waitForElementToExist(workLine, timeout: 10), "Quiet work line did not replace finished work")
        XCTAssertEqual(workLine.label, "3 tools, 2 thinking blocks", "Quiet work line lost finished-turn counts")
        XCTAssertEqual(workLine.value as? String, "Collapsed")
        for text in hiddenAfterFold {
            XCTAssertFalse(
                timelineContains(text),
                "Quiet Mode should hide \(text) behind the work line"
            )
        }
        XCTAssertTrue(timelineContains(finishedAssistant), "Quiet Mode must keep finished assistant text visible")
        XCTAssertTrue(
            waitForCollapsedWorkToStayHidden(workLine, hidden: hiddenAfterFold, duration: 2),
            "Collapsed Quiet work line did not remain folded long enough to inspect"
        )
        attachQuietTimelineEvidence(name: "quiet-mode-collapsed-work-line")

        // Expand restores nearby finished work without scrolling the header
        // away. Grep/read may sit below the fold; that scroll gap is reported,
        // not forced into this tap.
        tap(workLine, named: "Quiet finished-work line")
        XCTAssertTrue(waitForElementToHaveValue(workLine, "Expanded", timeout: 5), "Quiet work line did not expand")
        XCTAssertTrue(waitForTimelineTextContaining(thinkingPlan, timeout: 10), "Expanded work line did not restore thinking")
        XCTAssertTrue(waitForTimelineTextContaining(bashOutput, timeout: 10), "Expanded work line did not restore bash output")
        attachQuietTimelineEvidence(name: "quiet-mode-expanded-work-line")

        revealQuietWorkLine(workLine)
        tap(workLine, named: "Quiet finished-work line collapse")
        XCTAssertTrue(waitForElementToHaveValue(workLine, "Collapsed", timeout: 5), "Quiet work line did not collapse")
        XCTAssertTrue(
            waitForCollapsedWorkToStayHidden(workLine, hidden: hiddenAfterFold, duration: 1),
            "Collapsed work line left finished work visible"
        )
    }

    private func sendFinishedTool(
        sessionId: String,
        tool: String,
        toolCallId: String,
        args: [String: String],
        output: String
    ) throws {
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": tool,
            "toolCallId": toolCallId,
            "args": args,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_output",
            "toolCallId": toolCallId,
            "output": output,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": tool,
            "toolCallId": toolCallId,
        ])
    }

    private func openAppSettingsFromSessionList() {
        // Workspace-scoped session lists do not show the all-sessions server
        // switcher. Pop to the all-sessions root first, then use the sidebar's
        // stable App Settings destination.
        let serverSwitcher = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Current server:")
        ).firstMatch
        if !waitForElementToExist(serverSwitcher, timeout: 1) {
            let navigationBar = app.navigationBars.firstMatch
            let backButton = navigationBar.buttons.firstMatch
            XCTAssertTrue(waitForElementToExist(backButton, timeout: 5), "All Sessions back button did not appear")
            tap(backButton, named: "all sessions back button")
        }

        let sidebarButton = app.buttons["workspace.sidebar.open"]
        XCTAssertTrue(waitForElementToExist(sidebarButton, timeout: 10), "Workspace sidebar button did not appear")
        tap(sidebarButton, named: "workspace sidebar button")
        tap(app.buttons["workspace.settings.open"], named: "App Settings", timeout: 5)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings did not open")
    }

    private func closeAppSettingsToSessionList() {
        let settingsNavigationBar = app.navigationBars["Settings"]
        let backButton = settingsNavigationBar.buttons.firstMatch
        tap(backButton, named: "Settings back button", timeout: 5)
        XCTAssertTrue(app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 10), "Session list did not return from Settings")
    }

    private func isSwitchOn(_ toggle: XCUIElement) -> Bool {
        if toggle.isSelected { return true }
        if let number = toggle.value as? NSNumber {
            return number.boolValue
        }
        let value = String(describing: toggle.value).lowercased()
        return value == "1" || value == "true" || value == "on" || value.contains(" on")
    }

    private func waitForSwitch(_ element: XCUIElement, toBeOn expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isSwitchOn(element) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return isSwitchOn(element) == expected
    }

    private func waitForElementToHaveValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (element.value as? String) == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return (element.value as? String) == value
    }

    private func waitForWorkLine(_ workLine: XCUIElement, label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if workLineMatches(workLine, label: label) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return workLineMatches(workLine, label: label)
    }

    private func workLineMatches(_ workLine: XCUIElement, label: String) -> Bool {
        guard workLine.exists else { return false }
        let current = workLine.label
        return current == label || current.hasPrefix("\(label) · ") || current.contains(label)
    }

    private func quietWorkLine() -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier CONTAINS %@", "quiet-work-line:")
        ).firstMatch
    }

    private func revealQuietWorkLine(_ workLine: XCUIElement) {
        let timeline = app.collectionViews["chat.timeline"]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if workLine.exists && workLine.isHittable { return }
            if timeline.exists {
                timeline.swipeDown()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        if !element.exists { return true }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if !element.exists { return true }
        } while Date() < deadline
        return !element.exists
    }

    private func timelineContains(_ text: String) -> Bool {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            text,
            text
        )
        return app.collectionViews["chat.timeline"].descendants(matching: .any).matching(predicate).firstMatch.exists
    }

    private func waitForCollapsedWorkToStayHidden(
        _ workLine: XCUIElement,
        hidden texts: [String],
        duration: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            if (workLine.value as? String) != "Collapsed" { return false }
            if texts.contains(where: { timelineContains($0) }) { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return (workLine.value as? String) == "Collapsed"
            && texts.allSatisfy { !timelineContains($0) }
    }

    private func attachQuietTimelineEvidence(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(
            to: directory.appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }

    nonisolated private func setCompactTurnsPreference(enabled: Bool) {
        let environment = ProcessInfo.processInfo.environment
        guard let simulatorUDID = environment["SIMULATOR_UDID"] ?? environment["TARGET_DEVICE_IDENTIFIER"],
              !simulatorUDID.isEmpty else {
            XCTFail("No simulator identifier available for Compact turns preference reset")
            return
        }

        // iOS XCTest cannot spawn simctl. The host E2E harness writes the
        // persisted key before this process launches the app.
        do {
            _ = try e2eLabAPIJSON(
                method: "POST",
                path: "/e2e/ui/reset-quiet-mode",
                body: ["simulatorUDID": simulatorUDID, "enabled": enabled]
            )
        } catch {
            XCTFail("Could not set Compact turns preference: \(error.localizedDescription)")
        }
    }
}
