import XCTest

/// Paired-server screenshot lab for native extension UI surfaces.
///
/// The server-side harness is only enabled when `OPPI_E2E_UI_HARNESS=1` is
/// present on the E2E server process. It broadcasts the same protocol messages
/// produced by managed SDK sessions and mirrored terminal sessions, so these
/// screenshots exercise the phone rendering path without depending on a model
/// turn or a specific host extension installation.
final class ExtensionUISnapshotLabE2ETests: E2ETestCase {
    func testExtensionUISnapshotMatrix() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)

        try captureRPCDemoSurface(sessionId: sessionId)
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
                "message": "View source path?\n/Users/chenda/.pi/agent/extensions/rpc-demo.ts",
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
        try capturePrefill(sessionId: sessionId)
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
        ])
        waitForText("Loaded and ready.", timeout: 10)
        try saveLabScreenshot(name: "extension-ui-01-rpc-surface-e2e")
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

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10), "Chat input did not appear for prefill snapshot")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if String(describing: chatInput.value ?? "").contains(prefill) {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            String(describing: chatInput.value ?? "").contains(prefill),
            "Chat input did not receive extension prefill"
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

    private func settleRequest(sessionId: String, requestId: String) throws {
        try sendHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_settled",
            "id": requestId,
        ])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    private func dismissKeyboardLearningOverlayIfNeeded() {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 1) {
            tap(continueButton, named: "keyboard learning overlay continue", timeout: 1)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func waitForText(_ text: String, timeout: TimeInterval) {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            text,
            text
        )
        let match = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), "Expected text did not appear: \(text)")
    }
}
