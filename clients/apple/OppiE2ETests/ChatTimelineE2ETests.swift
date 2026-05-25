import XCTest

/// E2E test that pairs with a real E2E server,
/// sends a chat message, and verifies the timeline renders.
///
/// Requires the E2E server and local model endpoint to be running.
/// The E2E server harness writes the invite URL to `/tmp/oppi-e2e-invite.txt`.
final class ChatTimelineE2ETests: E2ETestCase {

    func testSendMessageAndReceiveResponse() throws {
        createAndEnterSession()

        sendMessageAndWaitForResponse(localEchoPrompt("E2E_CHAT_OK"))

        XCTAssertTrue(
            waitForTimelineTextContaining("E2E_CHAT_OK"),
            "E2E_CHAT_OK did not appear in timeline"
        )
    }
}
