import XCTest

/// End-to-end tests for the permission approval/denial flow.
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
final class PermissionE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Tests

    func testPermissionApproveFlow() throws {
        try launchAndNavigateToWorkspace()
        try createAndEnterSession()

        // Ask the model to use bash — this should trigger a permission request
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 30), "Chat input did not appear")
        chatInput.tap()
        chatInput.typeText("Use the bash tool to run: echo PERMISSION_APPROVED_OK")

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3), "Send button not found")
        sendButton.tap()

        // Wait for the permission approve button to appear.
        // The model needs to decide to call bash, which may take a while.
        let approveButton = app.buttons["permission.approve"]
        guard approveButton.waitForExistence(timeout: 60) else {
            throw XCTSkip(
                "Permission sheet never appeared — the MLX model may not have invoked the bash tool"
            )
        }

        // Approve the permission
        approveButton.tap()

        // Wait for streaming to complete (the tool runs, model responds)
        let stopButton = app.buttons["chat.stop"]
        if stopButton.waitForExistence(timeout: 30) {
            let predicate = NSPredicate(format: "exists == false")
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: stopButton)
            let result = XCTWaiter.wait(for: [expectation], timeout: 300)
            XCTAssertEqual(result, .completed, "Agent did not finish within 5 minutes after approval")
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
        try launchAndNavigateToWorkspace()
        try createAndEnterSession()

        // Ask the model to use bash — this should trigger a permission request
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 30), "Chat input did not appear")
        chatInput.tap()
        chatInput.typeText("Use the bash tool to run: echo PERMISSION_DENIED_TEST")

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3), "Send button not found")
        sendButton.tap()

        // Wait for the permission approve button (we'll tap deny instead)
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

        // Wait for the model to process the denial and finish responding.
        // After denial, the model typically acknowledges it cannot execute
        // the command. The stop button may or may not appear depending on
        // whether the model streams a follow-up response.
        let stopButton = app.buttons["chat.stop"]
        if stopButton.waitForExistence(timeout: 30) {
            let predicate = NSPredicate(format: "exists == false")
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: stopButton)
            let result = XCTWaiter.wait(for: [expectation], timeout: 300)
            XCTAssertEqual(result, .completed, "Agent did not finish within 5 minutes after denial")
        }

        // The session should still be functional — chat input reappears
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

    // MARK: - Helpers

    private func readInviteURL() throws -> String {
        let path = "/tmp/oppi-e2e-invite.txt"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("No invite URL found at \(path) — run ios/scripts/e2e.sh to set up server")
        }
        let url = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            throw XCTSkip("Invite URL file is empty")
        }
        return url
    }

    private func launchAndNavigateToWorkspace() throws {
        let inviteURL = try readInviteURL()

        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["PI_E2E_INVITE_URL"] = inviteURL
        app.launch()

        // Dismiss any system alerts
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            springboard.alerts.firstMatch.buttons.element(boundBy: 1).tap()
        }

        // Wait for Workspaces tab after pairing
        let workspacesNav = app.navigationBars["Workspaces"]
        XCTAssertTrue(
            workspacesNav.waitForExistence(timeout: 30),
            "Workspaces navigation bar did not appear after pairing"
        )

        // Find and tap the e2e-workspace cell
        let workspaceCell = app.collectionViews["workspace.list"]
            .cells.containing(.staticText, identifier: "e2e-workspace").firstMatch
        if !workspaceCell.waitForExistence(timeout: 30) {
            let list = app.collectionViews["workspace.list"]
            if list.exists {
                list.swipeDown()
                sleep(3)
            }
        }
        XCTAssertTrue(
            workspaceCell.waitForExistence(timeout: 15),
            "Workspace 'e2e-workspace' cell did not appear in list"
        )
        workspaceCell.tap()
    }

    private func createAndEnterSession() throws {
        let newSessionButton = app.buttons["workspace.newSession"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 15), "New session button not found")
        newSessionButton.tap()
        sleep(3)

        // Dismiss any system alerts
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            springboard.alerts.firstMatch.buttons.element(boundBy: 1).tap()
        }

        let sessionList = app.collectionViews["workspace.sessionList"]
        let sessionCell = sessionList.cells.element(boundBy: 1)
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 15), "Session cell did not appear")
        sessionCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 30), "Chat input did not appear after entering session")
    }
}
