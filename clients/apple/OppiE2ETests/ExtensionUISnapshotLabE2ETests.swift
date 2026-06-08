import XCTest

/// Paired-server screenshot lab for native extension UI surfaces.
///
/// The server-side harness is only enabled when `OPPI_E2E_UI_HARNESS=1` is
/// present on the E2E server process. It broadcasts the same protocol messages
/// produced by managed SDK sessions and mirrored terminal sessions, so these
/// screenshots exercise the phone and iPad rendering paths without depending
/// on a model turn or a specific host extension installation.
@MainActor
final class ExtensionUISnapshotLabE2ETests: E2ETestCase {
    func testExtensionUISnapshotMatrix() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)

        try captureRPCDemoSurface(sessionId: sessionId)
        try captureNativeDisplayBlockSurface(sessionId: sessionId)
        try captureTerminalFallbackLinkSurface(sessionId: sessionId)
        try captureDialog(
            name: "extension-ui-02-rpc-dangerous-select-e2e",
            sessionId: sessionId,
            requestId: "snap-rpc-dangerous-select",
            anchorText: "Block",
            message: [
                "type": "extension_ui_request",
                "id": "snap-rpc-dangerous-select",
                "method": "select",
                "title": "Dangerous command: rm -rf /tmp/rpc-demo",
                "options": ["Allow", "Block"],
            ]
        )
        try captureDialog(
            name: "extension-ui-03-approval-select-e2e",
            sessionId: sessionId,
            requestId: "snap-approval-select",
            anchorText: "Yes",
            message: [
                "type": "extension_ui_request",
                "id": "snap-approval-select",
                "method": "select",
                "title": "⚠️ Dangerous command:\n\n  sudo rm -rf /important\n\nAllow?",
                "options": ["Yes", "No"],
            ]
        )
        try captureDialog(
            name: "extension-ui-04-clear-session-confirm-e2e",
            sessionId: sessionId,
            requestId: "snap-clear-confirm",
            anchorText: "All messages will be lost.",
            message: [
                "type": "extension_ui_request",
                "id": "snap-clear-confirm",
                "method": "confirm",
                "title": "Clear session?",
                "message": "All messages will be lost.",
            ]
        )
        try captureDialog(
            name: "extension-ui-05-rpc-input-e2e",
            sessionId: sessionId,
            requestId: "snap-rpc-input",
            anchorText: "type something...",
            message: [
                "type": "extension_ui_request",
                "id": "snap-rpc-input",
                "method": "input",
                "title": "Enter a value",
                "placeholder": "type something...",
            ]
        )
        try captureDialog(
            name: "extension-ui-06-rpc-editor-e2e",
            sessionId: sessionId,
            requestId: "snap-rpc-editor",
            anchorText: "Line 2",
            message: [
                "type": "extension_ui_request",
                "id": "snap-rpc-editor",
                "method": "editor",
                "title": "Edit some text",
                "prefill": "Line 1\nLine 2\nLine 3",
            ]
        )
        try captureNotification(
            name: "extension-ui-07-notify-e2e",
            sessionId: sessionId,
            text: "Command allowed"
        )
        try captureDialog(
            name: "extension-ui-09-timed-confirm-e2e",
            sessionId: sessionId,
            requestId: "snap-timed-confirm",
            anchorText: "Expires in about",
            message: [
                "type": "extension_ui_request",
                "id": "snap-timed-confirm",
                "method": "confirm",
                "title": "Timed Confirmation",
                "message": "This dialog will auto-cancel in 5 seconds. Confirm?",
                "timeout": 5_000,
            ]
        )
        try captureDialog(
            name: "extension-ui-10-timed-select-e2e",
            sessionId: sessionId,
            requestId: "snap-timed-select",
            anchorText: "Option C",
            message: [
                "type": "extension_ui_request",
                "id": "snap-timed-select",
                "method": "select",
                "title": "Pick an option",
                "options": ["Option A", "Option B", "Option C"],
                "timeout": 10_000,
            ]
        )
        try captureDialog(
            name: "extension-ui-11-commands-list-e2e",
            sessionId: sessionId,
            requestId: "snap-commands-list",
            anchorText: "/rpc-editor - Open multi-line editor",
            message: [
                "type": "extension_ui_request",
                "id": "snap-commands-list",
                "method": "select",
                "title": "Available Commands",
                "options": [
                    "--- Extensions ---",
                    "/rpc-input - Prompt for text input",
                    "/rpc-editor - Open multi-line editor",
                    "/rpc-prefill - Prefill the input editor",
                    "/commands - List available slash commands",
                    "--- Skills ---",
                    "/review - Review the current diff",
                ],
            ]
        )
        try captureDialog(
            name: "extension-ui-12-command-path-confirm-e2e",
            sessionId: sessionId,
            requestId: "snap-command-path-confirm",
            anchorText: "View source path?",
            message: [
                "type": "extension_ui_request",
                "id": "snap-command-path-confirm",
                "method": "confirm",
                "title": "rpc-editor",
                "message": "View source path?\n/Users/testuser/.pi/agent/extensions/rpc-demo.ts",
            ]
        )
        try capturePlanModeSurface(sessionId: sessionId)
        try captureDialog(
            name: "extension-ui-14-plan-next-select-e2e",
            sessionId: sessionId,
            requestId: "snap-plan-next-select",
            anchorText: "Refine the plan",
            message: [
                "type": "extension_ui_request",
                "id": "snap-plan-next-select",
                "method": "select",
                "title": "Plan mode - what next?",
                "options": [
                    "Execute the plan (track progress)",
                    "Stay in plan mode",
                    "Refine the plan",
                ],
            ]
        )
        try captureDialog(
            name: "extension-ui-15-plan-refine-editor-e2e",
            sessionId: sessionId,
            requestId: "snap-plan-refine-editor",
            anchorText: "Add tests for extension UI replay",
            message: [
                "type": "extension_ui_request",
                "id": "snap-plan-refine-editor",
                "method": "editor",
                "title": "Refine the plan:",
                "prefill": "Add tests for extension UI replay\nSmoke the mirrored terminal flow",
            ]
        )
        try captureAskCard(sessionId: sessionId)
        try captureDialog(
            name: "extension-ui-17-unsupported-fallback-e2e",
            sessionId: sessionId,
            requestId: "snap-unsupported-fallback",
            anchorText: "Unsupported extension UI",
            message: [
                "type": "extension_ui_request",
                "id": "snap-unsupported-fallback",
                "method": "futureForm",
                "title": "Future Pi UI",
                "message": "This future extension UI method should stay cancellable.",
            ]
        )
        try capturePrefill(sessionId: sessionId)
    }

    func testIPadExtensionUISnapshotCoverage() throws {
        try assertIPadSizedCanvas()
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)

        try captureNativeDisplayBlockSurface(
            sessionId: sessionId,
            screenshotName: "ipad-extension-ui-native-surface-e2e"
        )
        try captureDialog(
            name: "ipad-extension-ui-native-prompt-e2e",
            sessionId: sessionId,
            requestId: "ipad-native-prompt",
            anchorText: "Use native iPad prompt",
            message: [
                "type": "extension_ui_request",
                "id": "ipad-native-prompt",
                "method": "select",
                "title": "Use native iPad prompt?",
                "options": [
                    "Use native iPad prompt",
                    "Use terminal fallback",
                ],
            ]
        )
        try captureTerminalFallbackLinkSurface(
            sessionId: sessionId,
            screenshotName: "ipad-extension-ui-terminal-fallback-e2e"
        )
    }

    func testExtensionUIWidgetInNormalTimelineScreenshot() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)

        try captureNormalTimelineWidgetSurface(sessionId: sessionId)
    }

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
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Editor sheet did not appear before session end")
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

        waitForText("Open linked activity session", timeout: 10)
        let rowButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Open linked activity session")
        ).firstMatch
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

    func testExtensionUIPersistentSurfaceClears() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let title = "native surface clear title e2e"
        let status = "native surface clear status e2e"
        let widgetLine = "native surface clear widget e2e"
        let statusKey = "surface-clear"
        let widgetKey = "surface-clear"

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setTitle",
            "title": title,
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": statusKey,
            "statusText": status,
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
            "widgetLines": [widgetLine],
        ])

        waitForText(title, timeout: 10)
        waitForText(status, timeout: 5)
        waitForText(widgetLine, timeout: 5)

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": statusKey,
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setTitle",
        ])

        waitForTextToDisappear(widgetLine, timeout: 5)
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

        let response = try waitForHarnessResponse(sessionId: sessionId, requestId: requestId)
        XCTAssertEqual(response["value"] as? String, prefill + suffix)
        XCTAssertNil(response["confirmed"])
        XCTAssertNil(response["cancelled"])
    }

    private func captureRPCDemoSurface(sessionId: String) throws {
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setTitle",
            "title": "pi RPC Demo (new session)",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": "rpc-demo",
            "statusText": "Turns: 0",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": "rpc-demo",
            "widgetLines": ["--- RPC Extension UI Demo ---", "Loaded and ready."],
            "nativeSurface": [
                "version": 1,
                "id": "widget:rpc-demo",
                "source": "widget",
                "presentation": [
                    "style": "surfacePanel",
                    "title": "RPC Demo",
                ],
                "blocks": [
                    [
                        "type": "activityList",
                        "id": "rpc-demo-native",
                        "rows": [
                            [
                                "id": "rpc-ready",
                                "title": "Native RPC widget ready",
                                "subtitle": "Surface panel",
                                "state": "success",
                            ],
                        ],
                    ],
                ],
                "fallback": [
                    "lines": ["--- RPC Extension UI Demo ---", "Loaded and ready."],
                ],
            ],
        ])
        waitForText("Native RPC widget ready", timeout: 10)
        try saveLabScreenshot(name: "extension-ui-01-rpc-surface-e2e")
    }

    private func captureNormalTimelineWidgetSurface(sessionId: String) throws {
        let widgetKey = "normal-timeline-goal"
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "agent_start",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "thinking_delta",
            "delta": "Inspecting lifecycle for extension widget updates.",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": "bash",
            "toolCallId": "normal-timeline-widget-rg",
            "args": ["command": "rg -n \"setWidget\" clients/apple/Oppi server/src"],
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "tool_output",
            "toolCallId": "normal-timeline-widget-rg",
            "output": "clients/apple/Oppi/Features/Chat/Support/ExtensionSurfacePanel.swift: widget surface rendered\nserver/src/routes/e2e-ui-harness.ts: setWidget forwarded\n",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": "bash",
            "toolCallId": "normal-timeline-widget-rg",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
            "widgetLines": [
                "1 of 4 tasks completed",
                "Read relevant Pi extension docs and Oppi architecture files",
                "Trace server setWidget event ingestion and lifecycle",
                "Trace iOS rendering/ordering of widget cards",
                "Summarize likely bug, risks, and concrete fixes",
            ],
            "nativeSurface": [
                "version": 1,
                "id": "widget:\(widgetKey)",
                "source": "widget",
                "presentation": [
                    "style": "surfacePanel",
                    "title": "1 of 4 tasks completed",
                ],
                "blocks": [
                    [
                        "type": "progress",
                        "id": "goal-progress",
                        "value": 0.25,
                    ],
                    [
                        "type": "activityList",
                        "id": "goal-tasks",
                        "rows": [
                            [
                                "id": "read-docs",
                                "title": "Read relevant Pi extension docs and Oppi architecture files",
                                "state": "success",
                            ],
                            [
                                "id": "trace-server",
                                "title": "Trace server setWidget event ingestion and lifecycle",
                                "state": "running",
                            ],
                            [
                                "id": "trace-ios",
                                "title": "Trace iOS rendering/ordering of widget cards",
                                "state": "inactive",
                            ],
                            [
                                "id": "summarize",
                                "title": "Summarize likely bug, risks, and concrete fixes",
                                "state": "inactive",
                            ],
                        ],
                    ],
                ],
                "fallback": [
                    "lines": [
                        "1 of 4 tasks completed",
                        "Trace server setWidget event ingestion and lifecycle",
                    ],
                ],
            ],
        ])

        waitForText("Inspecting lifecycle", timeout: 10)
        waitForText("Trace server setWidget", timeout: 10)
        try saveLabScreenshot(name: "extension-ui-normal-timeline-widget-e2e")

        let activeTaskButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Trace server setWidget event ingestion")
        ).firstMatch
        tap(activeTaskButton, named: "normal timeline active task row", timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try saveLabScreenshot(name: "extension-ui-normal-timeline-widget-expanded-e2e")

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "agent_end",
        ])
    }

    private func captureNativeDisplayBlockSurface(
        sessionId: String,
        screenshotName: String = "extension-ui-18-native-block-matrix-e2e"
    ) throws {
        let widgetKey = "block-matrix"
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
            "widgetLines": ["Native display block fallback"],
            "nativeSurface": [
                "version": 1,
                "id": "widget:\(widgetKey)",
                "source": "widget",
                "presentation": [
                    "style": "surfacePanel",
                    "title": "Native Blocks",
                ],
                "blocks": [
                    [
                        "type": "text",
                        "id": "native-text",
                        "spans": [
                            ["text": "Native ", "role": "primary"],
                            [
                                "text": "text block",
                                "role": "accent",
                                "traits": ["bold", "underline"],
                                "link": "oppi://session/\(sessionId)",
                            ],
                            ["text": " visible", "role": "success"],
                        ],
                    ],
                    [
                        "type": "markdown",
                        "id": "native-markdown",
                        "markdown": "Markdown block rendered",
                    ],
                    [
                        "type": "progress",
                        "id": "native-progress",
                        "label": "Indexing workspace",
                        "value": 0.42,
                    ],
                    [
                        "type": "activityList",
                        "id": "native-activity",
                        "rows": [
                            [
                                "id": "native-row",
                                "title": "Native activity row",
                                "subtitle": "Generic activity list",
                                "state": "running",
                                "link": "oppi://session/\(sessionId)",
                            ],
                        ],
                    ],
                    [
                        "type": "terminal",
                        "id": "native-terminal",
                        "lines": [
                            [
                                ["text": "terminal fallback line"],
                            ],
                        ],
                    ],
                    [
                        "type": "code",
                        "id": "native-code",
                        "language": "swift",
                        "text": "print(\"native code block\")",
                    ],
                ],
                "fallback": [
                    "lines": ["Native display block fallback"],
                ],
            ],
        ])
        waitForText("Native text block visible", timeout: 10)
        waitForText("Markdown block rendered", timeout: 5)
        waitForText("Indexing workspace", timeout: 5)
        waitForText("Native activity row", timeout: 5)
        waitForText("terminal fallback line", timeout: 5)
        waitForText("native code block", timeout: 5)
        try saveLabScreenshot(name: screenshotName)

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
        ])
    }

    private func captureTerminalFallbackLinkSurface(
        sessionId: String,
        screenshotName: String = "extension-ui-19-terminal-fallback-link-e2e"
    ) throws {
        let widgetKey = "terminal-link-fallback"
        let linkedLine = "Open \u{001B}]8;;oppi://session/\(sessionId)\u{0007}linked session\u{001B}]8;;\u{0007} from terminal fallback"
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
            "widgetLines": [linkedLine],
        ])
        waitForText("Open linked session from terminal fallback", timeout: 10)
        try saveLabScreenshot(name: screenshotName)

        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": widgetKey,
        ])
    }

    private func captureNotification(name: String, sessionId: String, text: String) throws {
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "notify",
            "message": text,
            "notifyType": "info",
        ])
        waitForText(text, timeout: 10)
        try saveLabScreenshot(name: name)
        tap(app.buttons["Done"], named: "extension notification done button", timeout: 5)
    }

    private func capturePrefill(sessionId: String) throws {
        let prefill = "This text was set by the rpc-demo extension."
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "set_editor_text",
            "text": prefill,
        ])

        waitForChatInput(
            containing: prefill,
            failureMessage: "Chat input did not receive extension prefill"
        )
        dismissKeyboardLearningOverlayIfNeeded()
        try saveLabScreenshot(name: "extension-ui-16-prefill-e2e")
    }

    private func capturePlanModeSurface(sessionId: String) throws {
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": "rpc-demo",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": "rpc-demo",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setTitle",
            "title": "Plan mode execution",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setStatus",
            "statusKey": "plan-mode",
            "statusText": "📋 2/5",
        ])
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setWidget",
            "widgetKey": "plan-todos",
            "widgetLines": [
                "☑ inspect current API",
                "☑ add protocol guardrail",
                "☐ wire mirror runtime",
                "☐ add tests",
                "☐ smoke rpc-demo",
            ],
        ])
        waitForText("smoke rpc-demo", timeout: 10)
        try saveLabScreenshot(name: "extension-ui-13-plan-mode-surface-e2e")
    }

    private func captureAskCard(sessionId: String) throws {
        let requestId = "snap-ask-card"
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_request",
            "id": requestId,
            "method": "ask",
            "allowCustom": true,
            "questions": [
                [
                    "id": "surface",
                    "question": "Which extension UI cases should stay native?",
                    "multiSelect": true,
                    "options": [
                        ["value": "dialogs", "label": "Dialogs", "description": "select, confirm, input, editor"],
                        ["value": "status", "label": "Status", "description": "title, status, widgets"],
                        ["value": "composer", "label": "Composer", "description": "setEditorText / pasteToEditor"],
                    ],
                ],
            ],
        ])
        waitForText("Which extension UI cases should stay native?", timeout: 10)
        try saveLabScreenshot(name: "extension-ui-08-ask-card-e2e")
        try settleRequest(sessionId: sessionId, requestId: requestId)
    }

    private func captureDialog(
        name: String,
        sessionId: String,
        requestId: String,
        anchorText: String,
        message: [String: Any]
    ) throws {
        try sendHarnessMessage(sessionId: sessionId, message)
        waitForText(anchorText, timeout: 10)
        try saveLabScreenshot(name: name)
        try settleRequest(sessionId: sessionId, requestId: requestId)
    }

    @discardableResult
    private func sendHarnessMessage(sessionId: String, _ message: [String: Any]) throws -> [String: Any] {
        try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/sessions/\(sessionId)/message",
            body: message
        )
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

    private func assertIPadSizedCanvas(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let shorterSide = min(app.frame.width, app.frame.height)
        try XCTSkipUnless(
            shorterSide >= 700,
            "iPad extension UI screenshots require an iPad-sized simulator",
            file: file,
            line: line
        )
    }

    private func dismissKeyboardLearningOverlayIfNeeded() {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 1) {
            tap(continueButton, named: "keyboard learning overlay continue", timeout: 1)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
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
