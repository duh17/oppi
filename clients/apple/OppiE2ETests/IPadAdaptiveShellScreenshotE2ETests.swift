import XCTest

/// iPad screenshot lab for the adaptive split shell.
///
/// Runs against the real paired E2E server so the captured view includes the
/// production pairing, workspace refresh, session creation, and chat timeline
/// path instead of preview-only fixtures.
final class IPadAdaptiveShellScreenshotE2ETests: E2ETestCase {
    private let anchorWorkspaceName = "iPad Layout Workspace"

    override var e2eLaunchesWorkspaceHomeOnly: Bool {
        true
    }

    override func seedE2EFixtures() throws {
        let defaultModel = ProcessInfo.processInfo.environment["E2E_MODEL"] ?? "omlx/Qwen3.6-27B-8bit"
        let workspaceId = try createLabWorkspace(named: anchorWorkspaceName, defaultModel: defaultModel)
        try createLabSessions(count: 1, workspaceId: workspaceId, stopAfterCreate: false)
        try createLabSessions(count: 2, workspaceId: workspaceId, stopAfterCreate: true)

        try seedLabWorkspaces([
            E2ELabWorkspaceFixture("Long iPad Sidebar Workspace Name", stoppedSessionCount: 3),
            E2ELabWorkspaceFixture("Sandbox Review Queue", activeSessionCount: 1),
        ])
    }

    func testIPadMainAndChatTimelineScreenshots() throws {
        let workspaceList = app.collectionViews["workspace.list"]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 15), "Workspace home list not visible")
        dismissExtensionSheetIfNeeded(timeout: 3)
        workspaceList.swipeDown()

        XCTAssertTrue(
            app.staticTexts[anchorWorkspaceName].waitForExistence(timeout: 20),
            "Seeded iPad workspace did not appear after refresh"
        )

        try saveLabScreenshot(name: "ipad-main-workspace-home")

        let openWorkspaceButton = app.buttons["workspace.open.\(anchorWorkspaceName)"]
        XCTAssertTrue(openWorkspaceButton.waitForExistence(timeout: 10), "iPad workspace open button missing")
        openWorkspaceButton.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()

        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 15),
            "Workspace session-list column did not appear after selecting workspace"
        )

        createSession()
        sendMessageAndWaitForResponse(localEchoPrompt("IPAD_CHAT_TIMELINE_OK"), timeout: 240)

        XCTAssertTrue(
            waitForTimelineTextContaining("IPAD_CHAT_TIMELINE_OK", timeout: 20),
            "IPAD_CHAT_TIMELINE_OK did not appear in the timeline"
        )

        dismissKeyboardIfNeeded()
        try saveLabScreenshot(name: "ipad-chat-timeline")

        let filesButton = app.buttons["workspace.files.open"]
        XCTAssertTrue(filesButton.waitForExistence(timeout: 10), "Workspace files button missing")
        tap(filesButton, named: "workspace files button")
        XCTAssertTrue(
            app.navigationBars["Files"].waitForExistence(timeout: 10),
            "File browser did not open in the iPad detail column"
        )
        try saveLabScreenshot(name: "ipad-file-browser")

        openServerMenuItem("App Settings")
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10)
                || app.staticTexts["Appearance"].waitForExistence(timeout: 2),
            "Settings did not open in the iPad detail column"
        )
        try saveLabScreenshot(name: "ipad-settings-detail")

        openServerMenuItem("Manage Servers")
        XCTAssertTrue(
            app.buttons["7d"].waitForExistence(timeout: 10)
                || app.staticTexts["No Servers"].waitForExistence(timeout: 2),
            "Server view did not open in the iPad detail column"
        )
        try saveLabScreenshot(name: "ipad-server-detail")
    }

    private func dismissKeyboardIfNeeded() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }

        let hideKeyboardButton = app.buttons["Hide keyboard"]
        if hideKeyboardButton.waitForExistence(timeout: 2) {
            tap(hideKeyboardButton, named: "hide keyboard", timeout: 1)
            return
        }

        let workspaceNavigationBar = app.navigationBars[anchorWorkspaceName]
        if workspaceNavigationBar.waitForExistence(timeout: 2) {
            workspaceNavigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func openServerMenuItem(_ label: String) {
        revealSplitSidebarIfNeeded(in: app)

        let currentServerButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Current server:")
        ).firstMatch
        XCTAssertTrue(currentServerButton.waitForExistence(timeout: 10), "Current server menu missing")
        tap(currentServerButton, named: "current server menu")

        let button = app.buttons[label]
        if button.waitForExistence(timeout: 5) {
            tap(button, named: label, timeout: 1)
            return
        }

        let menuItem = app.menuItems[label]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Menu item \(label) missing")
        tap(menuItem, named: label, timeout: 1)
    }

}
