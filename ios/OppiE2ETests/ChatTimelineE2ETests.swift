import XCTest

/// E2E test that pairs with a real Docker-hosted server,
/// sends a chat message, and verifies the assistant response renders.
///
/// Requires the Docker server and MLX model server to be running.
/// Run via `ios/scripts/e2e.sh` which handles server lifecycle
/// and writes the invite URL to `/tmp/oppi-e2e-invite.txt`.
final class ChatTimelineE2ETests: E2ETestCase {

    func testSendMessageAndReceiveResponse() throws {
        createAndEnterSession()

        sendMessageAndWaitForResponse("Reply with exactly: E2E_CHAT_OK")

        // Verify user message appeared in timeline
        let userMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'E2E_CHAT_OK'")
        ).firstMatch
        XCTAssertTrue(
            userMessage.waitForExistence(timeout: 10),
            "User message did not appear in timeline"
        )
    }
}
