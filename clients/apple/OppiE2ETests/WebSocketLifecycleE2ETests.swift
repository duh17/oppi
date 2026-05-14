import XCTest

/// E2E coverage for HTTP workspace list state and split session stream lifecycle.
///
/// These tests assert through DEBUG/E2E diagnostics exposed by the app,
/// rather than inferring transport state from incidental UI.
final class WebSocketLifecycleE2ETests: E2ETestCase {

    func testNavigationKeepsWorkspaceListOnHTTPAndUsesBoundSessionStreams() throws {
        waitForRequiredSplitStreamCapabilities()

        createSession()
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()
        let sessionA = waitForFocusedSessionId()
        waitForDesiredSubscription(sessionId: sessionA, level: "full")
        waitForAckedSubscription(sessionId: sessionA, level: "full")

        navigateBackToWorkspace()
        waitForNoDesiredSubscription(sessionId: sessionA)
        waitForNoAckedSubscription(sessionId: sessionA)

        createSession()
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()
        let sessionB = waitForFocusedSessionId(excluding: sessionA)
        waitForDesiredSubscription(sessionId: sessionB, level: "full")
        waitForAckedSubscription(sessionId: sessionB, level: "full")
        waitForNoDesiredSubscription(sessionId: sessionA)

        navigateBackToWorkspace()
        enterSession(id: sessionA)
        waitForSessionStreamEndpoint()
        XCTAssertEqual(waitForFocusedSessionId(sessionA), sessionA)
        waitForDesiredSubscription(sessionId: sessionA, level: "full")
        waitForAckedSubscription(sessionId: sessionA, level: "full")
        waitForNoDesiredSubscription(sessionId: sessionB)
    }

    func testRapidSessionSwitchingKeepsOnlyFocusedSessionOnFullStream() throws {
        waitForRequiredSplitStreamCapabilities()

        createSession()
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()
        let sessionA = waitForFocusedSessionId()
        waitForAckedSubscription(sessionId: sessionA, level: "full")

        navigateBackToWorkspace()
        waitForNoDesiredSubscription(sessionId: sessionA)

        createSession()
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()
        let sessionB = waitForFocusedSessionId(excluding: sessionA)
        waitForAckedSubscription(sessionId: sessionB, level: "full")
        waitForNoDesiredSubscription(sessionId: sessionA)

        for _ in 0..<3 {
            navigateBackToWorkspace()
            enterSession(id: sessionA)
            waitForSessionStreamEndpoint()
            XCTAssertEqual(waitForFocusedSessionId(sessionA), sessionA)
            waitForDesiredSubscription(sessionId: sessionA, level: "full")
            waitForAckedSubscription(sessionId: sessionA, level: "full")
            waitForNoDesiredSubscription(sessionId: sessionB)

            navigateBackToWorkspace()
            enterSession(id: sessionB)
            waitForSessionStreamEndpoint()
            XCTAssertEqual(waitForFocusedSessionId(sessionB), sessionB)
            waitForDesiredSubscription(sessionId: sessionB, level: "full")
            waitForAckedSubscription(sessionId: sessionB, level: "full")
            waitForNoDesiredSubscription(sessionId: sessionA)
        }
    }
}
