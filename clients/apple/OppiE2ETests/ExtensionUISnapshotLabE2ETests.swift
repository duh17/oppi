import XCTest

/// Paired-server journeys for native extension UI surfaces: a request's
/// response reaches the server once, a sheet or card goes when its request or
/// session ends, and surfaces follow their notifications.
///
/// The server-side harness is only enabled when `OPPI_E2E_UI_HARNESS=1` is
/// present on the E2E server process. It broadcasts the same protocol messages
/// produced by managed SDK sessions and mirrored terminal sessions, so these
/// tests run without depending on a model turn or a specific host extension
/// installation.
@MainActor
final class ExtensionUISnapshotLabE2ETests: E2ETestCase {
    func testExtensionUIResponseActions() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        try clearHarnessResponses(sessionId: sessionId)

        try assertSelectResponse(sessionId: sessionId)
        try assertConfirmResponse(sessionId: sessionId)
        try assertInputResponse(sessionId: sessionId)
        try assertEditorResponse(sessionId: sessionId)
    }

    func testApprovalPromptRestoresPendingMessageDraft() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        try clearHarnessResponses(sessionId: sessionId)

        let draft = "message that must survive approval"
        let chatInput = focusChatInput()
        chatInput.typeText(draft)
        XCTAssertTrue(waitForInputValue(chatInput, equals: draft, timeout: 5))

        let requestId = "draft-preservation-confirm"
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_request",
            "id": requestId,
            "method": "confirm",
            "title": "Approve command?",
            "message": "The pending message must return after this approval.",
        ])

        let confirm = app.buttons["Confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Approval prompt did not appear")
        XCTAssertTrue(waitForInputValue(chatInput, equals: "", timeout: 5))
        tap(confirm, named: "confirm option")
        _ = try waitForHarnessResponse(sessionId: sessionId, requestId: requestId)
        try settleRequest(sessionId: sessionId, requestId: requestId)

        XCTAssertTrue(
            waitForInputValue(chatInput, equals: draft, timeout: 10),
            "Approval settlement did not restore the pending message draft"
        )
    }

    func testSemanticApprovalRenderedControlsRespondOnceAndKeepActionsPinned() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        try clearHarnessResponses(sessionId: sessionId)

        let confirmRequestId = "semantic-approval-confirm"
        let diff = (0..<80)
            .map { $0.isMultiple(of: 2) ? "-old-line-\($0)" : "+new-line-\($0)" }
            .joined(separator: "\n")
        try sendScrollableConfirmation(
            sessionId: sessionId,
            requestId: confirmRequestId,
            summary: "Update Skill file SKILL.md",
            diff: diff
        )

        let expand = app.descendants(matching: .any)["ask.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        expand.tap()
        let confirm = app.buttons["ask.confirmation.confirm"]
        let cancel = app.buttons["ask.confirmation.cancel"]
        let closeDetails = app.buttons["ask.confirmation.closeDetails"]
        for button in [confirm, cancel, closeDetails] {
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isHittable)
        }

        closeDetails.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(
            try harnessResponses(sessionId: sessionId)
                .filter { $0["id"] as? String == confirmRequestId }
                .isEmpty,
            "Close Details must not send an extension UI response"
        )

        expand.tap()
        let scrollView = app.scrollViews["ask.approval.scroll"]
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        let pinnedFrames = [confirm.frame, cancel.frame, closeDetails.frame]
        let firstDiffLine = waitForText("-old-line-0", timeout: 5)
        let firstLineFrame = firstDiffLine.frame
        scrollView.swipeUp()
        scrollView.swipeUp()
        XCTAssertTrue(
            !firstDiffLine.isHittable || firstDiffLine.frame.minY < firstLineFrame.minY - 20,
            "Large diff content did not move after scrolling"
        )
        for (button, frame) in zip([confirm, cancel, closeDetails], pinnedFrames) {
            XCTAssertTrue(button.isHittable)
            XCTAssertEqual(button.frame.minY, frame.minY, accuracy: 2)
        }

        confirm.tap()
        let confirmed = try waitForHarnessResponse(
            sessionId: sessionId,
            requestId: confirmRequestId
        )
        XCTAssertEqual(confirmed["confirmed"] as? Bool, true)
        XCTAssertNil(confirmed["value"])
        XCTAssertNil(confirmed["cancelled"])
        try assertExactlyOneHarnessResponse(sessionId: sessionId, requestId: confirmRequestId)

        let cancelRequestId = "semantic-approval-cancel"
        try sendScrollableConfirmation(
            sessionId: sessionId,
            requestId: cancelRequestId,
            summary: "Update Agent Reviewer",
            diff: "-Old\n+New"
        )
        let cancelExpand = app.descendants(matching: .any)["ask.expand"]
        XCTAssertTrue(cancelExpand.waitForExistence(timeout: 10))
        cancelExpand.tap()
        let renderedCancel = app.buttons["ask.confirmation.cancel"]
        XCTAssertTrue(renderedCancel.waitForExistence(timeout: 5))
        renderedCancel.tap()

        let cancelled = try waitForHarnessResponse(
            sessionId: sessionId,
            requestId: cancelRequestId
        )
        XCTAssertEqual(cancelled["cancelled"] as? Bool, true)
        XCTAssertNil(cancelled["value"])
        XCTAssertNil(cancelled["confirmed"])
        try assertExactlyOneHarnessResponse(sessionId: sessionId, requestId: cancelRequestId)
    }

    func testExtensionUISheetDismissesWhenSessionEnds() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_request",
            "id": "terminal-cleanup-editor",
            "method": "editor",
            "title": "Editor should dismiss on session end",
            "prefill": "This sheet should not survive session end.",
        ])

        let editor = app.textViews["extension.dialog.editor"]
        XCTAssertTrue(
            editor.waitForExistence(timeout: 10),
            "Editor sheet did not appear before session end. \(extensionDialogDiagnostics())"
        )
        assertExtensionSheetPresented(true, method: "editor")

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "session_ended",
            "reason": "e2e-terminal-cleanup",
        ])

        waitForExtensionSheetDismissed(method: "editor")
    }

    func testExtensionUIActivityRowLinkOpensRelatedSession() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let originSessionId = waitForFocusedSessionId(timeout: 20)
        let workspaceId = try workspaceId(forSessionId: originSessionId)
        let linkedSessionId = try XCTUnwrap(
            createLabSessions(count: 1, workspaceId: workspaceId, stopAfterCreate: false).first,
            "Linked target session was not created"
        )
        try sendHarnessMessage(sessionId: originSessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": "activity-link",
            "widgetLines": ["Open linked session"],
            "nativeSurface": [
                "version": 1,
                "id": "widget:activity-link",
                "source": "widget",
                "presentation": [
                    "style": "surfacePanel",
                    "title": "Related Sessions",
                ],
                "blocks": [
                    [
                        "type": "activityList",
                        "id": "related-sessions",
                        "rows": [
                            [
                                "id": linkedSessionId,
                                "title": "Open linked activity session",
                                "subtitle": "Generic activity row link",
                                "state": "success",
                                "link": "oppi://session/\(linkedSessionId)?workspaceId=\(workspaceId)",
                            ],
                        ],
                    ],
                ],
                "fallback": [
                    "lines": ["Open linked activity session"],
                ],
            ],
        ])

        expandNativeSurface(title: "Related Sessions")
        let rowButton = app.descendants(matching: .any)["extension.native.activity.row.\(linkedSessionId)"]
        tap(rowButton, named: "native activity row link")
        XCTAssertEqual(
            waitForFocusedSessionId(linkedSessionId, timeout: 20),
            linkedSessionId,
            "Tapping an extension activity row should focus the linked session"
        )
        XCTAssertTrue(
            app.textViews["chat.input"].waitForExistence(timeout: 15),
            "Linked session chat did not open after tapping extension activity row"
        )
    }

    func testDoubleTappingNativeSurfaceViewportOpensFullScreenDetail() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let widgetKey = "viewport-double-tap"
        let headerTitle = "Viewport double-tap native surface"
        let bodyText = "Double-tap this expanded viewport body to open the full-screen surface."
        let identifierSuffix = "widget-\(widgetKey)"
        let viewportIdentifier = "extension-native-surface-\(identifierSuffix)-viewport"

        // Given a native extension widget whose detail view is available from the header.
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": widgetKey,
            "statusText": "Viewport gesture ready",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
            "widgetLines": [bodyText],
            "nativeSurface": [
                "version": 1,
                "id": "widget:\(widgetKey)",
                "source": "widget",
                "presentation": [
                    "style": "surfacePanel",
                    "title": headerTitle,
                ],
                "blocks": [
                    [
                        "type": "markdown",
                        "id": "viewport-double-tap-body",
                        "markdown": bodyText,
                    ],
                ],
                "fallback": [
                    "lines": [bodyText],
                ],
            ],
        ])

        let header = waitForText(headerTitle, timeout: 10)
        tap(header, named: "native surface header")
        let body = waitForText(bodyText, timeout: 5)
        let viewport = app.descendants(matching: .any)[viewportIdentifier]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), "Native surface expanded viewport did not appear")
        XCTAssertGreaterThan(
            viewport.frame.midY,
            header.frame.maxY,
            "Test must double tap inside the expanded scroll viewport, not the header row"
        )
        XCTAssertTrue(
            viewport.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: body.frame.midX, y: body.frame.midY)),
            "Body text should be inside the expanded scroll viewport before the double tap. viewport=\(viewport.frame), body=\(body.frame)"
        )
        XCTAssertLessThanOrEqual(
            body.frame.minY - viewport.frame.minY,
            28,
            "Short native surface content should start near the top of the expanded viewport. viewport=\(viewport.frame), body=\(body.frame)"
        )
        XCTAssertLessThanOrEqual(
            viewport.frame.maxY - body.frame.maxY,
            44,
            "Short native surface content should not leave a large blank area inside the expanded viewport. viewport=\(viewport.frame), body=\(body.frame)"
        )

        // When the person double taps inside the expanded scroll viewport.
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)).doubleTap()

        // Then the native surface opens in the chat reader, which pushes the detail with Back chrome.
        let detailBackButton = app.buttons["extension-native-surface-\(identifierSuffix)-detail-back"]
        XCTAssertTrue(
            detailBackButton.waitForExistence(timeout: 5),
            "Double tapping an expanded native surface viewport should open full-screen detail"
        )
        waitForText(bodyText, timeout: 5)
        try saveLabScreenshot(name: "extension-ui-native-surface-viewport-double-tap-e2e")
        tap(detailBackButton, named: "native surface detail back button", timeout: 5)

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": widgetKey,
        ])
    }

    func testUpdatedNativeSurfaceViewportShrinksWithoutEmptyScrollSpace() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let widgetKey = "viewport-empty-space"
        let headerTitle = "Viewport empty space native surface"
        let shortBody = "Updated native surface fits its content."
        let identifierSuffix = "widget-\(widgetKey)"
        let viewportIdentifier = "extension-native-surface-\(identifierSuffix)-viewport"
        let longRows = (1 ... 18).map { index in
            [
                "id": "task-\(index)",
                "title": "Scrollable native surface task \(index)",
                "subtitle": "Forces the expanded viewport to scroll before replacement",
                "state": index == 18 ? "running" : "inactive",
            ]
        }

        // Given a native extension widget whose expanded viewport has scrollable content.
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": widgetKey,
            "statusText": "Viewport should compact",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
            "widgetLines": ["Scrollable native surface task 1"],
            "nativeSurface": [
                "version": 1,
                "id": "widget:\(widgetKey)",
                "source": "widget",
                "presentation": [
                    "style": "surfacePanel",
                    "title": headerTitle,
                ],
                "blocks": [
                    [
                        "type": "activityList",
                        "id": "long-activity-list",
                        "rows": longRows,
                    ],
                ],
                "fallback": [
                    "lines": ["Scrollable native surface task 1"],
                ],
            ],
        ])

        let header = waitForText(headerTitle, timeout: 10)
        tap(header, named: "native surface header")
        let viewport = app.descendants(matching: .any)[viewportIdentifier]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), "Native surface expanded viewport did not appear")
        viewport.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // When the same widget updates to content shorter than the viewport limit.
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
            "widgetLines": [shortBody],
            "nativeSurface": [
                "version": 1,
                "id": "widget:\(widgetKey)",
                "source": "widget",
                "presentation": [
                    "style": "surfacePanel",
                    "title": headerTitle,
                ],
                "blocks": [
                    [
                        "type": "markdown",
                        "id": "short-markdown",
                        "markdown": shortBody,
                    ],
                ],
                "fallback": [
                    "lines": [shortBody],
                ],
            ],
        ])

        // Then the viewport clamps stale scroll position and fits the updated content.
        let body = waitForText(shortBody, timeout: 5)
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), "Native surface expanded viewport disappeared after update")
        XCTAssertLessThanOrEqual(
            body.frame.minY - viewport.frame.minY,
            28,
            "Updated native surface content should start near the top of the expanded viewport. viewport=\(viewport.frame), body=\(body.frame)"
        )
        XCTAssertLessThanOrEqual(
            viewport.frame.maxY - body.frame.maxY,
            44,
            "Updated native surface content should not leave a large blank area inside the expanded viewport. viewport=\(viewport.frame), body=\(body.frame)"
        )
        XCTAssertLessThan(
            viewport.frame.height,
            140,
            "Updated short native surface should shrink below the max scroll height. viewport=\(viewport.frame), body=\(body.frame)"
        )

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": widgetKey,
        ])
    }

    func testExtensionUIWorkingRowNotifications() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let workingMessage = "Running extension checks"

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWorkingMessage",
            "message": workingMessage,
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWorkingIndicator",
            "workingIndicator": [
                "frames": ["WIP"],
                "intervalMs": 120,
            ],
        ])
        try sendHarnessMessage(sessionId: sessionId, ["type": "agent_start"])

        waitForText(workingMessage, timeout: 10)
        waitForText("WIP", timeout: 5)

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWorkingVisible",
            "workingVisible": false,
        ])
        waitForTextToDisappear(workingMessage, timeout: 5)

        try sendHarnessMessage(sessionId: sessionId, ["type": "agent_end"])
    }

    func testExtensionUIHiddenThinkingLabelNotifications() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let sourceLabel = "Private reasoning"
        let thinkingText = "Analyzing native extension parity"

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setHiddenThinkingLabel",
            "hiddenThinkingLabel": sourceLabel,
        ])
        try sendHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "thinking_delta",
            "delta": thinkingText,
        ])

        waitForText(thinkingText, timeout: 10)
        waitForText(sourceLabel, timeout: 10)

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setHiddenThinkingLabel",
        ])
        waitForTextToDisappear(sourceLabel, timeout: 5)

        try sendHarnessMessage(sessionId: sessionId, ["type": "agent_end"])
    }

    func testExtensionUIToolsExpandedNotifications() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let toolId = "tool-expanded-e2e"
        let command = "printf native-tools-expanded"
        let output = "native-tools-expanded-output"

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setToolsExpanded",
            "toolsExpanded": true,
        ])
        try sendHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": "bash",
            "toolCallId": toolId,
            "args": ["command": command],
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "tool_output",
            "toolCallId": toolId,
            "output": output,
        ])

        waitForText(output, timeout: 10)

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setToolsExpanded",
            "toolsExpanded": false,
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": "bash",
            "toolCallId": toolId,
        ])
        try sendHarnessMessage(sessionId: sessionId, ["type": "agent_end"])
    }

    func testExtensionUIEditorTextHandoffNotification() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let handoff = "native composer handoff e2e"

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "set_editor_text",
            "text": handoff,
        ])

        waitForChatInput(
            containing: handoff,
            failureMessage: "Chat input did not receive extension editor text handoff"
        )
    }

    /// A status and a widget that share a key are one pill (the documented
    /// `key === widgetKey` attachment): the collapsed pill summarizes with the
    /// status, and the widget's lines are in its drawer. Clearing either one
    /// must leave the other on screen.
    func testExtensionUIPersistentSurfaceClears() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let title = "native surface clear title e2e"
        let status = "native surface clear status e2e"
        let widgetLine = "native surface clear widget e2e"
        let sharedKey = "surface-clear"
        let setStatus: [String: Any] = [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": sharedKey,
            "statusText": status,
        ]
        let clearStatus: [String: Any] = [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": sharedKey,
        ]
        let widgetPill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-\(sharedKey)"]
        let standaloneStatusPill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-status-\(sharedKey)"]
        let widgetDrawer = app.descendants(matching: .any)["extension-strip-aboveEditor-drawer-\(sharedKey)"]

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setTitle",
            "title": title,
        ])
        try sendHarnessMessage(sessionId: sessionId, setStatus)
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": sharedKey,
            "widgetLines": [widgetLine],
        ])

        waitForText(title, timeout: 10)
        XCTAssertTrue(widgetPill.waitForExistence(timeout: 5), "Shared-key widget pill did not appear")
        waitForValue(of: widgetPill, toContain: status, timeout: 5)
        XCTAssertFalse(standaloneStatusPill.exists, "An attached status must not also show as its own pill")

        // The widget's lines are one tap away, in the pill's drawer.
        tap(widgetPill, named: "shared-key widget pill")
        XCTAssertTrue(widgetDrawer.waitForExistence(timeout: 5), "Shared-key widget drawer did not open")
        waitForText(widgetLine, timeout: 5)
        try saveLabScreenshot(name: "extension-ui-shared-key-status-and-widget-e2e")

        // Clearing the status keeps the widget; the pill falls back to its first line.
        try sendHarnessMessage(sessionId: sessionId, clearStatus)
        waitForTextToDisappear(status, timeout: 5)
        XCTAssertTrue(widgetDrawer.exists, "Clearing the status closed the widget's drawer")
        waitForValue(of: widgetPill, toContain: widgetLine, timeout: 5)

        // Clearing the widget keeps the status, now as its own pill.
        try sendHarnessMessage(sessionId: sessionId, setStatus)
        waitForValue(of: widgetPill, toContain: status, timeout: 5)
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": sharedKey,
        ])
        waitForTextToDisappear(widgetLine, timeout: 5)
        XCTAssertTrue(standaloneStatusPill.waitForExistence(timeout: 5), "Status vanished with its widget")
        waitForValue(of: standaloneStatusPill, toContain: status, timeout: 5)

        try sendHarnessMessage(sessionId: sessionId, clearStatus)
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setTitle",
        ])

        waitForTextToDisappear(status, timeout: 5)
        waitForTextToDisappear(title, timeout: 5)
    }

    func testExtensionUIWidgetPlacementAboveAndBelowEditor() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let aboveLine = "native above editor placement e2e"
        let belowLine = "native below editor placement e2e"

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": "above-placement",
            "widgetLines": [aboveLine],
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": "below-placement",
            "widgetPlacement": "belowEditor",
            "widgetLines": [belowLine],
        ])

        let aboveElement = waitForText(aboveLine, timeout: 10)
        let belowElement = waitForText(belowLine, timeout: 10)
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10), "Chat input not available for placement check")
        waitForWidgetPlacement(
            aboveElement: aboveElement,
            belowElement: belowElement,
            chatInput: chatInput,
            timeout: 5
        )
    }

    private func sendScrollableConfirmation(
        sessionId: String,
        requestId: String,
        summary: String,
        diff: String
    ) throws {
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_request",
            "id": requestId,
            "method": "confirm",
            "title": "Approve Oppi command",
            "message": """
            \(summary)

            ```diff
            \(diff)
            ```
            """,
        ])
    }

    private func assertExactlyOneHarnessResponse(
        sessionId: String,
        requestId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let matching = try harnessResponses(sessionId: sessionId)
            .filter { $0["id"] as? String == requestId }
        XCTAssertEqual(
            matching.count,
            1,
            "Rendered action must submit exactly one response for \(requestId)",
            file: file,
            line: line
        )
    }

    private func assertSelectResponse(sessionId: String) throws {
        let requestId = "response-select"
        let selectedValue = "Native Select Choice B"
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_request",
            "id": requestId,
            "method": "select",
            "title": "Choose a native select response",
            "options": ["Native Select Choice A", selectedValue],
        ])

        waitForText(selectedValue, timeout: 10)
        assertExtensionSheetPresented(false, method: "select")
        tap(app.buttons[selectedValue].firstMatch, named: "select option")
        allowAISharingIfAsked()

        let response = try waitForHarnessResponse(sessionId: sessionId, requestId: requestId)
        XCTAssertEqual(response["value"] as? String, selectedValue)
        XCTAssertNil(response["confirmed"])
        XCTAssertNil(response["cancelled"])
    }

    private func assertConfirmResponse(sessionId: String) throws {
        let requestId = "response-confirm"
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_request",
            "id": requestId,
            "method": "confirm",
            "title": "Confirm native response?",
            "message": "This should send confirmed true.",
        ])

        waitForText("This should send confirmed true.", timeout: 10)
        assertExtensionSheetPresented(false, method: "confirm")
        tap(app.buttons["Confirm"].firstMatch, named: "confirm option")

        let response = try waitForHarnessResponse(sessionId: sessionId, requestId: requestId)
        XCTAssertEqual(response["confirmed"] as? Bool, true)
        XCTAssertNil(response["value"])
        XCTAssertNil(response["cancelled"])
    }

    private func assertInputResponse(sessionId: String) throws {
        let requestId = "response-input"
        let value = "e2einputvalue123"
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_request",
            "id": requestId,
            "method": "input",
            "title": "Enter native input",
            "placeholder": "type E2E input value",
        ])

        waitForText("Enter native input", timeout: 10)
        assertExtensionSheetPresented(false, method: "input")
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10), "Chat input not available for native input")
        chatInput.tap()
        chatInput.typeText(value)
        tap(app.buttons["chat.send"], named: "input submit button", timeout: 5)
        allowAISharingIfAsked()

        let response = try waitForHarnessResponse(sessionId: sessionId, requestId: requestId)
        XCTAssertEqual(response["value"] as? String, value)
        XCTAssertNil(response["confirmed"])
        XCTAssertNil(response["cancelled"])
    }

    private func assertEditorResponse(sessionId: String) throws {
        let requestId = "response-editor"
        let prefill = "base"
        let suffix = " e2eeditorvalue123"
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_request",
            "id": requestId,
            "method": "editor",
            "title": "Edit native editor",
            "prefill": prefill,
        ])

        let editor = app.textViews["extension.dialog.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Native editor text view did not appear")
        assertExtensionSheetPresented(true, method: "editor")
        editor.tap()
        editor.typeText(suffix)
        tap(app.buttons["extension.dialog.submit"], named: "editor submit button", timeout: 5)
        allowAISharingIfAsked()

        let response = try waitForHarnessResponse(sessionId: sessionId, requestId: requestId)
        XCTAssertEqual(response["value"] as? String, prefill + suffix)
        XCTAssertNil(response["confirmed"])
        XCTAssertNil(response["cancelled"])
    }

    /// Injects one protocol message into a live session. The harness only
    /// broadcasts to sockets the server has attached for that session, so a
    /// message injected before the chat's stream attaches is dropped without an
    /// error and the sheet it asked for never appears. Wait for the socket, then
    /// fail here — not ten seconds later on the missing sheet — when the server
    /// had nobody to deliver to. A `persist` send lands in the server's stored
    /// transcript whether or not a socket is attached, so it is sent once:
    /// resending a request the server already kept would duplicate it.
    @discardableResult
    private func sendHarnessMessage(sessionId: String, _ message: [String: Any]) throws -> [String: Any] {
        let isPersisted = (message["persist"] as? Bool) == true
        let deadline = Date().addingTimeInterval(10)
        var response: [String: Any] = [:]
        while true {
            response = try e2eLabAPIJSON(
                method: "POST",
                path: "/e2e/ui/sessions/\(sessionId)/message",
                body: message
            )
            let subscribers = response["subscriberCount"] as? Int ?? 0
            if isPersisted || subscribers > 0 || Date() >= deadline { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if !isPersisted {
            XCTAssertGreaterThan(
                response["subscriberCount"] as? Int ?? 0,
                0,
                "The server had no subscribed socket for \(sessionId), so \(message["type"] ?? "the message") was dropped"
            )
        }
        return response
    }

    /// The app's own view of the extension dialog, for a failure message: the
    /// request it would present, every queued one, and the session it watches.
    private func extensionDialogDiagnostics() -> String {
        ["e2e.extension.dialog", "e2e.extension.dialogs", "e2e.root.modals", "e2e.ws.focusedSession", "e2e.ws.ackedSubscriptions"]
            .map { id in
                let label = app.staticTexts[id]
                return "\(id)=\(label.exists ? label.label : "missing")"
            }
            .joined(separator: " ")
    }

    private func workspaceId(forSessionId sessionId: String, timeout: TimeInterval = 10) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSessions: [[String: Any]] = []

        while Date() < deadline {
            let response = try e2eLabAPIJSON(method: "GET", path: "/sessions/recent")
            let sessions = response["sessions"] as? [[String: Any]] ?? []
            lastSessions = sessions
            if let row = sessions.first(where: { $0["id"] as? String == sessionId }),
               let workspaceId = row["workspaceId"] as? String,
               !workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return workspaceId
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail("No workspace id found for session \(sessionId). Recent sessions: \(lastSessions)")
        return ""
    }

    private func waitForInputValue(
        _ input: XCUIElement,
        equals expectedValue: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: input
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func settleRequest(sessionId: String, requestId: String) throws {
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_settled",
            "id": requestId,
        ])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    private func clearHarnessResponses(sessionId: String) throws {
        _ = try e2eLabAPIJSON(
            method: "DELETE",
            path: "/e2e/ui/sessions/\(sessionId)/responses"
        )
    }

    private func harnessResponses(sessionId: String) throws -> [[String: Any]] {
        let response = try e2eLabAPIJSON(
            method: "GET",
            path: "/e2e/ui/sessions/\(sessionId)/responses"
        )
        return response["responses"] as? [[String: Any]] ?? []
    }

    private func assertExtensionSheetPresented(
        _ expected: Bool,
        method: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sheetCancelButton = app.buttons["extension.dialog.cancel"]
        if expected {
            XCTAssertTrue(
                sheetCancelButton.waitForExistence(timeout: 2),
                "\(method) should present as an extension sheet",
                file: file,
                line: line
            )
        } else {
            XCTAssertFalse(
                sheetCancelButton.waitForExistence(timeout: 0.5),
                "\(method) should stay inline instead of presenting an extension sheet",
                file: file,
                line: line
            )
        }
    }

    private func waitForExtensionSheetDismissed(
        method: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sheetCancelButton = app.buttons["extension.dialog.cancel"]
        let deadline = Date().addingTimeInterval(timeout)
        while sheetCancelButton.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(
            sheetCancelButton.exists,
            "\(method) extension sheet should dismiss",
            file: file,
            line: line
        )
    }

    private func waitForHarnessResponse(
        sessionId: String,
        requestId: String,
        timeout: TimeInterval = 10
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                if let response = try harnessResponses(sessionId: sessionId)
                    .first(where: { $0["id"] as? String == requestId }) {
                    return response
                }
            } catch {
                lastError = error
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        if let lastError {
            throw lastError
        }
        XCTFail("No harness response recorded for \(requestId)")
        return [:]
    }

    @discardableResult
    private func waitForChatInput(
        containing text: String,
        timeout: TimeInterval = 10,
        failureMessage: String
    ) -> XCUIElement {
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: timeout), "Chat input did not appear")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if String(describing: chatInput.value ?? "").contains(text) {
                return chatInput
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(String(describing: chatInput.value ?? "").contains(text), failureMessage)
        return chatInput
    }

    @discardableResult
    private func waitForText(_ text: String, timeout: TimeInterval) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            text,
            text
        )
        let match = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "Expected text did not appear: \(text)")
        return match
    }

    private func expandNativeSurface(title: String, timeout: TimeInterval = 10) {
        let collapsePredicate = NSPredicate(
            format: "label CONTAINS[c] %@",
            "Collapse \(title) surface"
        )
        let collapseToggle = app.descendants(matching: .any).matching(collapsePredicate).firstMatch
        if collapseToggle.waitForExistence(timeout: 0.5) {
            return
        }

        let expandPredicate = NSPredicate(
            format: "label CONTAINS[c] %@",
            "Expand \(title) surface"
        )
        let expandToggle = app.descendants(matching: .any).matching(expandPredicate).firstMatch
        XCTAssertTrue(
            expandToggle.waitForExistence(timeout: timeout),
            "Native surface \(title) expand toggle did not appear"
        )

        let strip = app.descendants(matching: .any)["extension-strip-aboveEditor-collapsed"]
        for _ in 0..<4 where !expandToggle.isHittable && strip.exists {
            strip.swipeLeft()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        tap(expandToggle, named: "native surface \(title) expand toggle", timeout: timeout)
        XCTAssertTrue(
            collapseToggle.waitForExistence(timeout: timeout),
            "Native surface \(title) did not expand"
        )
    }

    private func waitForWidgetPlacement(
        aboveElement: XCUIElement,
        belowElement: XCUIElement,
        chatInput: XCUIElement,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastAboveFrame = CGRect.zero
        var lastBelowFrame = CGRect.zero
        var lastInputFrame = CGRect.zero

        while Date() < deadline {
            lastAboveFrame = aboveElement.frame
            lastBelowFrame = belowElement.frame
            lastInputFrame = chatInput.frame
            if aboveElement.exists,
               belowElement.exists,
               chatInput.exists,
               !lastAboveFrame.isEmpty,
               !lastBelowFrame.isEmpty,
               !lastInputFrame.isEmpty,
               lastAboveFrame.midY < lastInputFrame.midY,
               lastBelowFrame.midY > lastInputFrame.midY {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertLessThan(
            lastAboveFrame.midY,
            lastInputFrame.midY,
            "Default extension widget should render above the composer. above=\(lastAboveFrame), input=\(lastInputFrame)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            lastBelowFrame.midY,
            lastInputFrame.midY,
            "belowEditor extension widget should render below the composer. below=\(lastBelowFrame), input=\(lastInputFrame)",
            file: file,
            line: line
        )
    }

    private func waitForValue(
        of element: XCUIElement,
        toContain text: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            if element.exists {
                last = String(describing: element.value ?? "")
                if last.contains(text) { return }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("\(element) value did not show \"\(text)\" (last=\"\(last)\")", file: file, line: line)
    }

    private func waitForTextToDisappear(_ text: String, timeout: TimeInterval) {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            text,
            text
        )
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let match = app.descendants(matching: .any).matching(predicate).firstMatch
            if !match.exists {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let match = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertFalse(match.exists, "Expected text to disappear: \(text)")
    }
}
