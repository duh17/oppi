import XCTest

/// Shared base class for E2E tests.
/// Launches the app and pairs with the E2E server once per test process,
/// then each test method reuses the same app instance.
///
/// Pairing invite tokens are single-use, so relaunching and re-pairing for
/// each test class makes later classes fail with an already-consumed invite.
class E2ETestCase: XCTestCase {

    /// Shared app instance — persists across E2E test classes.
    /// nonisolated(unsafe) is required for Swift 6 strict concurrency — XCTest
    /// runs these UI tests serially in the harness.
    nonisolated(unsafe) private static var _app: XCUIApplication?

    var app: XCUIApplication {
        Self._app!
    }

    /// Override in focused labs that need the paired workspace list itself,
    /// not the default workspace-detail starting point used by interaction E2Es.
    var e2eLaunchesWorkspaceHomeOnly: Bool {
        false
    }

    /// Override in labs that need server-side fixtures before the app refreshes.
    func seedE2EFixtures() throws {}

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        try seedE2EFixtures()

        if Self._app == nil {
            try launchAndPair()
        }
        dismissExtensionSheetIfNeeded(timeout: 2)

        if e2eLaunchesWorkspaceHomeOnly {
            try ensureAtWorkspaceHome()
        } else {
            // Navigate back to workspace detail if a previous test left the app elsewhere.
            try ensureAtWorkspaceDetail()
        }
    }

    // MARK: - Launch & Pairing (once per class)

    /// Launches the app, pairs with the E2E server, and navigates to the e2e-workspace.
    private func launchAndPair() throws {
        let inviteURL = try readInviteURL()

        let application = XCUIApplication()
        application.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        application.launchEnvironment["PI_E2E_INVITE_URL"] = inviteURL
        if let deviceToken = try? readDeviceToken() {
            application.launchEnvironment["OPPI_E2E_DEVICE_TOKEN"] = deviceToken
        }
        if !e2eLaunchesWorkspaceHomeOnly {
            application.launchEnvironment["OPPI_E2E_AUTO_OPEN_WORKSPACE"] = "e2e-workspace"
            application.launchEnvironment["OPPI_E2E_AUTO_CREATE_SESSION"] = "1"
        }
        application.launch()
        Self._app = application

        // Dismiss springboard alerts (notification permissions, etc.)
        // 0.5s is enough to detect — no need to block 2s when no alert is present.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 0.5) {
            tap(springboard.alerts.firstMatch.buttons.element(boundBy: 1), named: "SpringBoard alert default button")
        }

        dismissInitialExtensionSheet(in: application)
        revealSplitSidebarIfNeeded(in: application)

        // Wait for pairing to complete — workspace list appears. Use the
        // collection identifier instead of the navigation title; chrome changes
        // can hide or rename the bar without changing readiness.
        let workspaceList = application.collectionViews["workspace.list"]
        let newSessionButton = application.buttons["workspace.newSession"]
        let chatInput = application.textViews["chat.input"]
        let pairedDeadline = Date().addingTimeInterval(30)
        var paired = workspaceList.exists || newSessionButton.exists || chatInput.exists
        while !paired && Date() < pairedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            paired = workspaceList.exists || newSessionButton.exists || chatInput.exists
        }
        if e2eLaunchesWorkspaceHomeOnly {
            XCTAssertTrue(
                workspaceList.waitForExistence(timeout: 15),
                "Workspace list did not appear after pairing"
            )
            return
        }
        if !paired || newSessionButton.waitForExistence(timeout: 2) || chatInput.exists {
            return
        }

        // Find and open the e2e-workspace. The row body expands previews; the
        // trailing open affordance navigates to workspace detail.
        let openWorkspaceButton = application.buttons["workspace.open.e2e-workspace"]
        if !openWorkspaceButton.waitForExistence(timeout: 30) {
            // Pull to refresh as fallback — then poll again instead of sleeping.
            workspaceList.swipeDown()
        }
        XCTAssertTrue(
            openWorkspaceButton.waitForExistence(timeout: 15),
            "Workspace 'e2e-workspace' open button did not appear in list"
        )
        // The workspace row has an expanding row-body button next to the open
        // affordance. Tap the trailing edge of the open control so XCTest does
        // not synthesize the event into the neighboring disclosure button.
        openWorkspaceButton.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()

        // Verify we arrived at workspace detail
        XCTAssertTrue(
            newSessionButton.waitForExistence(timeout: 15),
            "Workspace detail did not load after tapping e2e-workspace"
        )
    }

    private func dismissInitialExtensionSheet(in application: XCUIApplication) {
        let doneButton = application.buttons["Done"]
        guard doneButton.waitForExistence(timeout: 3) else { return }

        if doneButton.isHittable {
            doneButton.tap()
        } else {
            doneButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    func revealSplitSidebarIfNeeded(in application: XCUIApplication) {
        guard !application.collectionViews["workspace.list"].waitForExistence(timeout: 1) else { return }

        let showSidebarButton = application.buttons["Show Sidebar"]
        guard showSidebarButton.waitForExistence(timeout: 2) else { return }

        if showSidebarButton.isHittable {
            showSidebarButton.tap()
        } else {
            showSidebarButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func readDeviceToken() throws -> String {
        let path = "/tmp/oppi-e2e-device-token.txt"
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        return try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads the invite URL written by the E2E server harness.
    private func readInviteURL() throws -> String {
        let path = "/tmp/oppi-e2e-invite.txt"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("No invite URL found at \(path) — run the Oppi E2E server harness to set up pairing")
        }
        let url = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            throw XCTSkip("Invite URL file is empty")
        }
        return url
    }

    // MARK: - State Recovery

    /// Ensures the app is at the workspace home screen before each test.
    /// Handles recovery from chat sessions, workspace detail, or modal sheets.
    private func ensureAtWorkspaceHome() throws {
        let workspaceList = app.collectionViews["workspace.list"]
        if workspaceList.waitForExistence(timeout: 3) {
            return
        }

        dismissExtensionSheetIfNeeded(timeout: 1)

        for _ in 0..<5 {
            if workspaceList.waitForExistence(timeout: 0.5) {
                return
            }
            let backButton = app.navigationBars.buttons.firstMatch
            guard backButton.exists else { break }
            tap(backButton, named: "navigation back button", timeout: 1)
        }

        XCTAssertTrue(workspaceList.waitForExistence(timeout: 10), "Workspace home list not reachable")
    }

    /// Ensures the app is at the workspace detail screen before each test.
    /// Handles recovery from chat sessions, workspace list, or unknown states.
    private func ensureAtWorkspaceDetail() throws {
        dismissExtensionSheetIfNeeded(timeout: 1)

        let newSessionButton = app.buttons["workspace.newSession"]
        if newSessionButton.waitForExistence(timeout: 3) {
            return
        }

        // Might be inside a chat session — try the back button
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.exists && backButton.isHittable {
            tap(backButton, named: "navigation back button")
            if newSessionButton.waitForExistence(timeout: 10) {
                return
            }
        }

        // Might be at the workspace list — open e2e-workspace
        let openWorkspaceButton = app.buttons["workspace.open.e2e-workspace"]
        if openWorkspaceButton.waitForExistence(timeout: 5) {
            tap(openWorkspaceButton, named: "e2e-workspace open button")
            if newSessionButton.waitForExistence(timeout: 15) {
                return
            }
        }

        // Unknown state — force relaunch
        Self._app = nil
        try launchAndPair()
    }

    func dismissExtensionSheetIfNeeded(timeout: TimeInterval = 1) {
        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: timeout) {
            tap(doneButton, named: "dismiss extension sheet", timeout: 1)
        }
    }

    func tap(_ element: XCUIElement, named name: String, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(name) did not appear")
        XCTAssertTrue(element.isEnabled, "\(name) is disabled")

        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    // MARK: - Session Helpers

    /// Creates a new session by tapping the + button and waits for the app to open it.
    func createSession() {
        let chatInput = app.textViews["chat.input"]
        if chatInput.waitForExistence(timeout: 3) {
            return
        }

        let newSessionButton = app.buttons["workspace.newSession"]
        XCTAssertTrue(
            newSessionButton.waitForExistence(timeout: 10),
            "New session button not found"
        )
        tap(newSessionButton, named: "new session button")

        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 30),
            "Chat input did not appear after creating session"
        )
    }

    /// Taps the most recent session (first row after the section header) and waits for chat input.
    func enterLatestSession() {
        enterSession(at: 1)
    }

    /// Taps the session at the given cell index and waits for chat input.
    /// Index 0 is the section header; index 1 is the most recent session.
    func enterSession(at index: Int) {
        let sessionList = app.collectionViews["workspace.sessionList"]
        let sessionCell = sessionList.cells.element(boundBy: index)
        XCTAssertTrue(
            sessionCell.waitForExistence(timeout: 10),
            "Session cell at index \(index) did not appear"
        )
        tap(sessionCell, named: "session cell at index \(index)")

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 30),
            "Chat input did not appear after entering session at index \(index)"
        )
    }

    /// Taps a specific session row by stable session id and waits for chat input.
    func enterSession(id sessionId: String) {
        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(
            sessionList.waitForExistence(timeout: 10),
            "Session list did not appear before entering session \(sessionId)"
        )

        let rowTitle = app.staticTexts["Session \(sessionId)"]
        if !rowTitle.waitForExistence(timeout: 5) {
            sessionList.swipeUp()
        }
        XCTAssertTrue(
            rowTitle.waitForExistence(timeout: 10),
            "Session row \(sessionId) did not appear"
        )
        tap(rowTitle, named: "session row \(sessionId)")

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 30),
            "Chat input did not appear after entering session \(sessionId)"
        )
    }

    /// Creates a new session and enters it.
    func createAndEnterSession() {
        createSession()
    }

    /// Navigates back from a chat session to the workspace detail screen.
    func navigateBackToWorkspace() {
        dismissExtensionSheetIfNeeded(timeout: 1)

        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.exists && backButton.isHittable {
            tap(backButton, named: "navigation back button")
        }

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(
            sessionList.waitForExistence(timeout: 10),
            "Session list did not reappear after navigating back"
        )
    }

    // MARK: - Messaging

    func localEchoPrompt(_ marker: String) -> String {
        "Reply with exactly this token and nothing else: \(marker). No markdown. No explanation."
    }

    func waitForTimelineTextContaining(_ text: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            text,
            text
        )
        let match = app.descendants(matching: .any).matching(predicate).firstMatch
        if match.waitForExistence(timeout: timeout) {
            return true
        }

        let jumpToBottom = app.buttons["chat.jumpToBottom"]
        if jumpToBottom.exists && jumpToBottom.isHittable {
            tap(jumpToBottom, named: "jump to bottom button")
            if match.waitForExistence(timeout: 3) {
                return true
            }
        }
        return false
    }

    // MARK: - E2E Diagnostics

    @discardableResult
    func waitForE2EDiagnostic(
        _ identifier: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line,
        matching predicate: (String) -> Bool
    ) -> String {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(
            element.waitForExistence(timeout: 10),
            "E2E diagnostic \(identifier) did not appear",
            file: file,
            line: line
        )

        let deadline = Date().addingTimeInterval(timeout)
        var latest = element.label
        while Date() < deadline {
            latest = element.label
            if predicate(latest) {
                return latest
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail(
            "Diagnostic \(identifier) never matched. Last value: \(latest)",
            file: file,
            line: line
        )
        return latest
    }

    @discardableResult
    func waitForWebSocketConnected(timeout: TimeInterval = 20) -> String {
        waitForE2EDiagnostic("e2e.ws.status", timeout: timeout) { $0 == "connected" }
    }

    @discardableResult
    func waitForRequiredSplitStreamCapabilities(timeout: TimeInterval = 20) -> String {
        waitForE2EDiagnostic("e2e.stream.requiredCapabilities", timeout: timeout) { $0 == "ready" }
    }

    @discardableResult
    func waitForSessionStreamEndpoint(_ expected: String = "split_session", timeout: TimeInterval = 20) -> String {
        waitForE2EDiagnostic("e2e.stream.sessionEndpoint", timeout: timeout) { $0 == expected }
    }

    @discardableResult
    func waitForNoDesiredSubscription(sessionId: String, timeout: TimeInterval = 20) -> String {
        waitForE2EDiagnostic("e2e.ws.desiredSubscriptions", timeout: timeout) { value in
            !hasAnySubscription(value, sessionId: sessionId)
        }
    }

    @discardableResult
    func waitForNoAckedSubscription(sessionId: String, timeout: TimeInterval = 20) -> String {
        waitForE2EDiagnostic("e2e.ws.ackedSubscriptions", timeout: timeout) { value in
            !hasAnySubscription(value, sessionId: sessionId)
        }
    }

    @discardableResult
    func waitForFocusedSessionId(
        _ expected: String? = nil,
        excluding excluded: String? = nil,
        timeout: TimeInterval = 15
    ) -> String {
        waitForE2EDiagnostic("e2e.ws.focusedSession", timeout: timeout) { value in
            value != "none"
                && !value.isEmpty
                && (expected.map { value == $0 } ?? true)
                && (excluded.map { value != $0 } ?? true)
        }
    }

    @discardableResult
    func waitForDesiredSubscription(
        sessionId: String,
        level: String,
        timeout: TimeInterval = 20
    ) -> String {
        waitForE2EDiagnostic("e2e.ws.desiredSubscriptions", timeout: timeout) { value in
            hasSubscription(value, sessionId: sessionId, level: level)
        }
    }

    @discardableResult
    func waitForAckedSubscription(
        sessionId: String,
        level: String,
        timeout: TimeInterval = 20
    ) -> String {
        waitForE2EDiagnostic("e2e.ws.ackedSubscriptions", timeout: timeout) { value in
            hasSubscription(value, sessionId: sessionId, level: level)
        }
    }

    private func hasSubscription(_ value: String, sessionId: String, level: String) -> Bool {
        value
            .split(separator: ",")
            .contains { $0 == "\(sessionId):\(level)" }
    }

    private func hasAnySubscription(_ value: String, sessionId: String) -> Bool {
        value
            .split(separator: ",")
            .contains { $0.hasPrefix("\(sessionId):") }
    }

    /// Types a message, sends it, and waits for the full round-trip to complete
    /// (stop button appears then disappears, chat input reappears).
    func sendMessageAndWaitForResponse(_ message: String, timeout: TimeInterval = 300) {
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 15),
            "Chat input not available before sending"
        )
        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 1) {
            tap(doneButton, named: "extension sheet done", timeout: 1)
        }
        chatInput.tap()
        let focusPredicate = NSPredicate(format: "hasKeyboardFocus == true")
        if !focusPredicate.evaluate(with: chatInput) {
            chatInput.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        }
        let focusDeadline = Date().addingTimeInterval(5)
        while !focusPredicate.evaluate(with: chatInput) && Date() < focusDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(focusPredicate.evaluate(with: chatInput), "Chat input did not gain keyboard focus")
        chatInput.typeText(message)

        let sendButton = app.buttons["chat.send"]
        tap(sendButton, named: "send button", timeout: 3)

        // Wait for streaming to start then finish
        let stopButton = app.buttons["chat.stop"]
        if stopButton.waitForExistence(timeout: 30) {
            let predicate = NSPredicate(format: "exists == false")
            let exp = XCTNSPredicateExpectation(predicate: predicate, object: stopButton)
            XCTAssertEqual(
                XCTWaiter.wait(for: [exp], timeout: timeout), .completed,
                "Agent did not finish responding within \(Int(timeout))s"
            )
        }

        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 15),
            "Chat input did not reappear after response"
        )
    }
}
