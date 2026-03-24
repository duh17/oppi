import XCTest

/// Shared base class for E2E tests.
/// Launches the app and pairs with the Docker server ONCE per test class,
/// then each test method reuses the same app instance.
///
/// XCTest creates a fresh instance per test method, but static properties
/// persist across methods within a class. When the test class changes
/// (detected via class name), the app is relaunched and re-paired.
class E2ETestCase: XCTestCase {

    /// Shared app instance — persists across test methods within a single test class.
    /// Re-created when the active test class changes.
    /// nonisolated(unsafe) is required for Swift 6 strict concurrency — XCTest
    /// guarantees sequential execution within a test class so this is safe.
    nonisolated(unsafe) private static var _app: XCUIApplication?
    nonisolated(unsafe) private static var _pairedClassName: String?

    var app: XCUIApplication {
        Self._app!
    }

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        let className = String(describing: type(of: self))
        if Self._app == nil || Self._pairedClassName != className {
            Self._app = nil
            Self._pairedClassName = nil
            try launchAndPair()
            Self._pairedClassName = className
        }

        // Navigate back to workspace detail if a previous test left the app elsewhere
        try ensureAtWorkspaceDetail()
    }

    // MARK: - Launch & Pairing (once per class)

    /// Launches the app, pairs with the Docker server, and navigates to the e2e-workspace.
    private func launchAndPair() throws {
        let inviteURL = try readInviteURL()

        let application = XCUIApplication()
        application.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        application.launchEnvironment["PI_E2E_INVITE_URL"] = inviteURL
        application.launch()
        Self._app = application

        // Dismiss springboard alerts (notification permissions, etc.)
        // 0.5s is enough to detect — no need to block 2s when no alert is present.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 0.5) {
            springboard.alerts.firstMatch.buttons.element(boundBy: 1).tap()
        }

        // Wait for pairing to complete — Workspaces tab appears
        let workspacesNav = application.navigationBars["Workspaces"]
        XCTAssertTrue(
            workspacesNav.waitForExistence(timeout: 30),
            "Workspaces navigation bar did not appear after pairing"
        )

        // Find and tap the e2e-workspace
        let workspaceCell = application.collectionViews["workspace.list"]
            .cells.containing(.staticText, identifier: "e2e-workspace").firstMatch
        if !workspaceCell.waitForExistence(timeout: 30) {
            // Pull to refresh as fallback — then poll again instead of sleeping
            let list = application.collectionViews["workspace.list"]
            if list.exists {
                list.swipeDown()
            }
        }
        XCTAssertTrue(
            workspaceCell.waitForExistence(timeout: 15),
            "Workspace 'e2e-workspace' cell did not appear in list"
        )
        workspaceCell.tap()

        // Verify we arrived at workspace detail
        let newSessionButton = application.buttons["workspace.newSession"]
        XCTAssertTrue(
            newSessionButton.waitForExistence(timeout: 15),
            "Workspace detail did not load after tapping e2e-workspace"
        )
    }

    /// Reads the invite URL written by `ios/scripts/e2e.sh`.
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

    // MARK: - State Recovery

    /// Ensures the app is at the workspace detail screen before each test.
    /// Handles recovery from chat sessions, workspace list, or unknown states.
    private func ensureAtWorkspaceDetail() throws {
        let newSessionButton = app.buttons["workspace.newSession"]
        if newSessionButton.waitForExistence(timeout: 3) {
            return
        }

        // Might be inside a chat session — try the back button
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.exists && backButton.isHittable {
            backButton.tap()
            if newSessionButton.waitForExistence(timeout: 10) {
                return
            }
        }

        // Might be at the workspace list — tap e2e-workspace
        let workspaceCell = app.collectionViews["workspace.list"]
            .cells.containing(.staticText, identifier: "e2e-workspace").firstMatch
        if workspaceCell.waitForExistence(timeout: 5) {
            workspaceCell.tap()
            if newSessionButton.waitForExistence(timeout: 15) {
                return
            }
        }

        // Unknown state — force relaunch
        Self._app = nil
        Self._pairedClassName = nil
        try launchAndPair()
        Self._pairedClassName = String(describing: type(of: self))
    }

    // MARK: - Session Helpers

    /// Creates a new session by tapping the + button and polling for the session cell to appear.
    /// Does NOT enter the session — call `enterLatestSession()` or `enterSession(at:)` after.
    func createSession() {
        let sessionList = app.collectionViews["workspace.sessionList"]
        let cellCountBefore = sessionList.cells.count

        let newSessionButton = app.buttons["workspace.newSession"]
        XCTAssertTrue(
            newSessionButton.waitForExistence(timeout: 10),
            "New session button not found"
        )
        newSessionButton.tap()

        // Poll for the new session cell at the next index.
        // max(cellCountBefore, 1) handles both empty lists (0 cells → wait for index 1
        // after the section header) and populated lists (N cells → wait for index N).
        let targetIndex = max(cellCountBefore, 1)
        let newCell = sessionList.cells.element(boundBy: targetIndex)
        XCTAssertTrue(
            newCell.waitForExistence(timeout: 15),
            "Session cell did not appear after creation"
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
        sessionCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 30),
            "Chat input did not appear after entering session at index \(index)"
        )
    }

    /// Creates a new session and enters it.
    /// Convenience for `createSession()` followed by `enterLatestSession()`.
    func createAndEnterSession() {
        createSession()
        enterLatestSession()
    }

    /// Navigates back from a chat session to the workspace detail screen.
    func navigateBackToWorkspace() {
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.exists && backButton.isHittable {
            backButton.tap()
        }

        let sessionList = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(
            sessionList.waitForExistence(timeout: 10),
            "Session list did not reappear after navigating back"
        )
    }

    // MARK: - Messaging

    /// Types a message, sends it, and waits for the full round-trip to complete
    /// (stop button appears then disappears, chat input reappears).
    func sendMessageAndWaitForResponse(_ message: String, timeout: TimeInterval = 300) {
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 15),
            "Chat input not available before sending"
        )
        chatInput.tap()
        chatInput.typeText(message)

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3), "Send button not found")
        sendButton.tap()

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
