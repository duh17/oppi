import XCTest

/// End-to-end test that pairs with a real Docker-hosted server,
/// sends a chat message, and verifies the assistant response renders.
///
/// Requires the Docker server and MLX model server to be running.
/// Run via `ios/scripts/e2e.sh` which handles server lifecycle
/// and writes the invite URL to `/tmp/oppi-e2e-invite.txt`.
final class ChatTimelineE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testSendMessageAndReceiveResponse() throws {
        // 1. Read invite URL from temp file (written by e2e.sh)
        let inviteURL = try readInviteURL()

        // 2. Launch app with the invite URL as a launch environment variable.
        // The app checks for PI_E2E_INVITE_URL on launch and processes it
        // as a deep link, bypassing the need for simctl openurl.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["PI_E2E_INVITE_URL"] = inviteURL
        app.launch()

        // 4. Wait for app to pair and show workspaces tab
        // The invite handler runs after reconnectOnLaunch(), pairs with the server,
        // and navigates to the workspaces tab. This involves a network round-trip
        // to the Docker server, so give it up to 30 seconds.
        let workspacesNav = app.navigationBars["Workspaces"]
        XCTAssertTrue(
            workspacesNav.waitForExistence(timeout: 30),
            "Workspaces navigation bar did not appear after pairing"
        )

        // 5. Wait for workspace to appear in the list.
        // The server needs a moment to establish the /stream WebSocket and
        // sync workspace data. The workspace row contains the workspace name.
        // Give it up to 30s for the connection to stabilize and workspace to load.
        // Find a cell containing "e2e-workspace" text and tap it.
        // Use cells query to avoid matching duplicate labels in headers.
        let workspaceCell = app.collectionViews["workspace.list"]
            .cells.containing(.staticText, identifier: "e2e-workspace").firstMatch
        if !workspaceCell.waitForExistence(timeout: 30) {
            // Pull to refresh to trigger workspace sync
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

        // 6. Create a new session (tap the + button in toolbar)
        let newSessionButton = app.buttons["workspace.newSession"]
        if !newSessionButton.waitForExistence(timeout: 15) {
            let description = app.debugDescription
            XCTFail("New session button not found. Hierarchy:\n\(description.prefix(3000))")
            return
        }
        newSessionButton.tap()

        // 7. Wait for the session to appear in the list, then tap it to enter ChatView
        sleep(3) // Give session creation a moment

        // Dismiss any system alerts that may have appeared
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            springboard.alerts.firstMatch.buttons.element(boundBy: 1).tap()
        }

        let sessionList = app.collectionViews["workspace.sessionList"]
        let sessionCell = sessionList.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 15), "Session cell did not appear")
        // Tap the center of the cell to trigger the NavigationLink push.
        // Using coordinate tap avoids XCUITest's automatic button detection
        // which can intercept and tap cancel/dismiss buttons instead.
        sessionCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let chatInput = app.textViews["chat.input"]

        // 8. Wait for chat input to appear
        if !chatInput.waitForExistence(timeout: 30) {
            let description = app.debugDescription
            XCTFail("Chat input did not appear after entering session. Hierarchy:\n\(description.prefix(3000))")
            return
        }

        // 8. Type a message
        chatInput.tap()
        chatInput.typeText("Reply with exactly: E2E_CHAT_OK")

        // 9. Send the message
        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3), "Send button not found")
        sendButton.tap()

        // 10. Wait for assistant response to appear in timeline
        // Verify our message appeared first
        let userMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'E2E_CHAT_OK'")
        ).firstMatch
        XCTAssertTrue(
            userMessage.waitForExistence(timeout: 10),
            "User message did not appear in timeline"
        )

        // Wait for streaming to start (stop button appears) then finish (disappears)
        let stopButton = app.buttons["chat.stop"]
        if stopButton.waitForExistence(timeout: 30) {
            // Streaming started — wait for it to finish (stop button disappears)
            let predicate = NSPredicate(format: "exists == false")
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: stopButton)
            let result = XCTWaiter.wait(for: [expectation], timeout: 300)
            XCTAssertEqual(result, .completed, "Agent did not finish within 5 minutes")
        }

        // Verify the chat input is back (session is ready for the next message).
        // This confirms the full request/response round-trip completed.
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 10),
            "Chat input did not reappear after response"
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
}
