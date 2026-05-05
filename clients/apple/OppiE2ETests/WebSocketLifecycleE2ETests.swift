import XCTest

/// E2E coverage for the app-visible `/stream` lifecycle.
///
/// These tests intentionally assert through DEBUG/E2E diagnostics exposed by
/// the app, rather than inferring subscription state from incidental UI.
final class WebSocketLifecycleE2ETests: E2ETestCase {

    func testNavigationDowngradesHiddenSessionsAndRestoresFocusedFullSubscription() throws {
        createSession()
        waitForWebSocketConnected()
        let sessionA = waitForFocusedSessionId()
        waitForDesiredSubscription(sessionId: sessionA, level: "full")
        waitForAckedSubscription(sessionId: sessionA, level: "full")

        navigateBackToWorkspace()
        waitForDesiredSubscription(sessionId: sessionA, level: "notifications")
        waitForAckedSubscription(sessionId: sessionA, level: "notifications")

        createSession()
        waitForWebSocketConnected()
        let sessionB = waitForFocusedSessionId(excluding: sessionA)
        waitForDesiredSubscription(sessionId: sessionB, level: "full")
        waitForAckedSubscription(sessionId: sessionB, level: "full")
        waitForDesiredSubscription(sessionId: sessionA, level: "notifications")

        navigateBackToWorkspace()
        enterSession(id: sessionA)
        XCTAssertEqual(waitForFocusedSessionId(sessionA), sessionA)
        waitForDesiredSubscription(sessionId: sessionA, level: "full")
        waitForAckedSubscription(sessionId: sessionA, level: "full")
        waitForDesiredSubscription(sessionId: sessionB, level: "notifications")
    }

    func testRapidSessionSwitchingKeepsFocusedSessionFullySubscribed() throws {
        createSession()
        waitForWebSocketConnected()
        let sessionA = waitForFocusedSessionId()
        waitForAckedSubscription(sessionId: sessionA, level: "full")

        navigateBackToWorkspace()
        createSession()
        waitForWebSocketConnected()
        let sessionB = waitForFocusedSessionId(excluding: sessionA)
        waitForAckedSubscription(sessionId: sessionB, level: "full")
        waitForDesiredSubscription(sessionId: sessionA, level: "notifications")

        for _ in 0..<3 {
            navigateBackToWorkspace()
            enterSession(id: sessionA)
            XCTAssertEqual(waitForFocusedSessionId(sessionA), sessionA)
            waitForDesiredSubscription(sessionId: sessionA, level: "full")
            waitForAckedSubscription(sessionId: sessionA, level: "full")
            waitForDesiredSubscription(sessionId: sessionB, level: "notifications")

            navigateBackToWorkspace()
            enterSession(id: sessionB)
            XCTAssertEqual(waitForFocusedSessionId(sessionB), sessionB)
            waitForDesiredSubscription(sessionId: sessionB, level: "full")
            waitForAckedSubscription(sessionId: sessionB, level: "full")
            waitForDesiredSubscription(sessionId: sessionA, level: "notifications")
        }
    }
}
