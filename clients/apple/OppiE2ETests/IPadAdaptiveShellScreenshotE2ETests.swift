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
            "Workspace detail column did not appear after selecting workspace"
        )

        createSession()
        sendMessageAndWaitForResponse(localEchoPrompt("IPAD_CHAT_TIMELINE_OK"), timeout: 240)

        XCTAssertTrue(
            waitForTimelineTextContaining("IPAD_CHAT_TIMELINE_OK", timeout: 20),
            "IPAD_CHAT_TIMELINE_OK did not appear in the timeline"
        )

        try saveLabScreenshot(name: "ipad-chat-timeline")
    }
}
