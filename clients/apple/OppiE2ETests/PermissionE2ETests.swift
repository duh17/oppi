import XCTest

/// E2E tests for the permission approval/denial flow.
/// Triggers tool usage (bash) to exercise the permission sheet,
/// then verifies approve and deny paths.
///
/// These tests depend on the local MLX model deciding to invoke
/// the bash tool. If the model does not produce a tool call,
/// the test skips gracefully rather than failing.
///
/// Requires the Docker server and MLX model server to be running.
/// Run via `ios/scripts/e2e.sh` which handles server lifecycle
/// and writes the invite URL to `/tmp/oppi-e2e-invite.txt`.
final class PermissionE2ETests: E2ETestCase {

    // MARK: - Tests

    func testPermissionApproveFlow() throws {
        createAndEnterSession()

        // Ask the model to use bash — triggers a permission request
        let chatInput = app.textViews["chat.input"]
        chatInput.tap()
        chatInput.typeText("Use the bash tool to run: echo PERMISSION_APPROVED_OK")

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3), "Send button not found")
        sendButton.tap()

        // Wait for the permission sheet (model needs to decide to call bash)
        let approveButton = app.buttons["permission.approve"]
        guard approveButton.waitForExistence(timeout: 60) else {
            throw XCTSkip(
                "Permission sheet never appeared — the MLX model may not have invoked the bash tool"
            )
        }

        // Approve the permission
        approveButton.tap()

        // Wait for tool execution and response to complete
        let stopButton = app.buttons["chat.stop"]
        if stopButton.waitForExistence(timeout: 30) {
            let predicate = NSPredicate(format: "exists == false")
            let exp = XCTNSPredicateExpectation(predicate: predicate, object: stopButton)
            XCTAssertEqual(
                XCTWaiter.wait(for: [exp], timeout: 300), .completed,
                "Agent did not finish within 5 minutes after approval"
            )
        }

        // Verify the tool output contains the echoed string
        let toolOutput = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'PERMISSION_APPROVED_OK'")
        ).firstMatch
        XCTAssertTrue(
            toolOutput.waitForExistence(timeout: 15),
            "PERMISSION_APPROVED_OK not found in timeline after approving bash tool"
        )

        // Confirm the session is still usable
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 15),
            "Chat input did not reappear after permission approval flow"
        )
    }

    func testPermissionDenyFlow() throws {
        createAndEnterSession()

        // Ask the model to use bash — triggers a permission request
        let chatInput = app.textViews["chat.input"]
        chatInput.tap()
        chatInput.typeText("Use the bash tool to run: echo PERMISSION_DENIED_TEST")

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3), "Send button not found")
        sendButton.tap()

        // Wait for the permission sheet
        let approveButton = app.buttons["permission.approve"]
        guard approveButton.waitForExistence(timeout: 60) else {
            throw XCTSkip(
                "Permission sheet never appeared — the MLX model may not have invoked the bash tool"
            )
        }

        // Deny the permission
        let denyButton = app.buttons["permission.deny"]
        XCTAssertTrue(denyButton.exists, "Deny button not found alongside approve button")
        denyButton.tap()

        // Wait for the model to process the denial and finish responding
        let stopButton = app.buttons["chat.stop"]
        if stopButton.waitForExistence(timeout: 30) {
            let predicate = NSPredicate(format: "exists == false")
            let exp = XCTNSPredicateExpectation(predicate: predicate, object: stopButton)
            XCTAssertEqual(
                XCTWaiter.wait(for: [exp], timeout: 300), .completed,
                "Agent did not finish within 5 minutes after denial"
            )
        }

        // Session should still be functional
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 15),
            "Chat input did not reappear after permission denial — session may be stuck"
        )

        // The denied command's output should NOT appear in the timeline
        let deniedOutput = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'PERMISSION_DENIED_TEST'")
        ).firstMatch
        XCTAssertFalse(
            deniedOutput.waitForExistence(timeout: 5),
            "PERMISSION_DENIED_TEST appeared in timeline despite denying permission"
        )
    }
}
