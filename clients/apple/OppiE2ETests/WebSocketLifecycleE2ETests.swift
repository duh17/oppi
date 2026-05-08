import XCTest

/// E2E coverage for the split workspace/session stream lifecycle.
///
/// These tests assert through DEBUG/E2E diagnostics exposed by the app,
/// rather than inferring transport state from incidental UI.
final class WebSocketLifecycleE2ETests: E2ETestCase {

    func testNavigationKeepsWorkspaceStreamAndUsesBoundSessionStreams() throws {
        waitForRequiredSplitStreamCapabilities()
        waitForWorkspaceStreamConnected()

        createSession()
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()
        waitForWorkspaceStreamConnected()
        let sessionA = waitForFocusedSessionId()
        waitForDesiredSubscription(sessionId: sessionA, level: "full")
        waitForAckedSubscription(sessionId: sessionA, level: "full")

        navigateBackToWorkspace()
        waitForWorkspaceStreamConnected()
        waitForNoDesiredSubscription(sessionId: sessionA)
        waitForNoAckedSubscription(sessionId: sessionA)

        createSession()
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()
        waitForWorkspaceStreamConnected()
        let sessionB = waitForFocusedSessionId(excluding: sessionA)
        waitForDesiredSubscription(sessionId: sessionB, level: "full")
        waitForAckedSubscription(sessionId: sessionB, level: "full")
        waitForNoDesiredSubscription(sessionId: sessionA)

        navigateBackToWorkspace()
        waitForWorkspaceStreamConnected()
        enterSession(id: sessionA)
        waitForSessionStreamEndpoint()
        XCTAssertEqual(waitForFocusedSessionId(sessionA), sessionA)
        waitForDesiredSubscription(sessionId: sessionA, level: "full")
        waitForAckedSubscription(sessionId: sessionA, level: "full")
        waitForNoDesiredSubscription(sessionId: sessionB)
    }

    func testRapidSessionSwitchingKeepsOnlyFocusedSessionOnFullStream() throws {
        waitForRequiredSplitStreamCapabilities()
        waitForWorkspaceStreamConnected()

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
            waitForWorkspaceStreamConnected()
            enterSession(id: sessionA)
            waitForSessionStreamEndpoint()
            XCTAssertEqual(waitForFocusedSessionId(sessionA), sessionA)
            waitForDesiredSubscription(sessionId: sessionA, level: "full")
            waitForAckedSubscription(sessionId: sessionA, level: "full")
            waitForNoDesiredSubscription(sessionId: sessionB)

            navigateBackToWorkspace()
            waitForWorkspaceStreamConnected()
            enterSession(id: sessionB)
            waitForSessionStreamEndpoint()
            XCTAssertEqual(waitForFocusedSessionId(sessionB), sessionB)
            waitForDesiredSubscription(sessionId: sessionB, level: "full")
            waitForAckedSubscription(sessionId: sessionB, level: "full")
            waitForNoDesiredSubscription(sessionId: sessionA)
        }
    }
}
