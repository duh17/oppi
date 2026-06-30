import XCTest

private let worktreeWorkspaceName = "Worktree Navigation Lab"
private let worktreeBranchName = "feature/native-worktree-e2e"

/// Paired-server proof for native worktree navigation.
///
/// The fixture is a real git repository with a linked git worktree created by
/// the E2E server, so the app exercises the production worktree discovery API
/// instead of screenshot-preview mocks.
@MainActor
final class WorkspaceWorktreeE2ETests: E2ETestCase {
    nonisolated(unsafe) private static var workspaceId: String?

    override var e2eLaunchesWorkspaceHomeOnly: Bool {
        true
    }

    override func seedE2EFixtures() throws {
        let fixture = try createLabGitWorktreeFixture(
            directoryName: "native-worktree-e2e",
            branchName: worktreeBranchName
        )
        Self.workspaceId = try createLabWorkspace(
            named: worktreeWorkspaceName,
            hostMount: fixture.hostMount
        )
    }

    func testWorktreeSelectionCreatesSessionInLinkedWorktree() throws {
        let workspaceId = try XCTUnwrap(Self.workspaceId, "Worktree fixture workspace was not seeded")
        let workspaceList = app.collectionViews["workspace.list"]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 10), "Workspace home list not visible")
        dismissExtensionSheetIfNeeded(timeout: 3)
        workspaceList.swipeDown()

        XCTAssertTrue(
            revealWorkspace(named: worktreeWorkspaceName, timeout: 25),
            "Worktree fixture workspace did not appear after refresh"
        )

        let openWorkspaceButton = app.buttons["workspace.open.\(worktreeWorkspaceName)"]
        XCTAssertTrue(
            openWorkspaceButton.waitForExistence(timeout: 10),
            "Worktree fixture workspace open button did not appear"
        )
        openWorkspaceButton.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()

        let sessionList = app.collectionViews["workspace.sessionList"]
        if !sessionList.waitForExistence(timeout: 8) {
            // In the full release suite this test can run after another UI test
            // has just recovered from a sheet or navigation reset. The row body
            // also opens workspaces in E2E invite mode, so tap the stable title
            // as a fallback when the trailing affordance tap is swallowed.
            app.staticTexts[worktreeWorkspaceName].tap()
        }
        XCTAssertTrue(sessionList.waitForExistence(timeout: 15), "Workspace detail did not load")

        let linkedWorktreeId = try linkedWorktreeId(workspaceId: workspaceId)
        let worktreeMenu = app.buttons["workspace.worktree.menu"]
        XCTAssertTrue(
            worktreeMenu.waitForExistence(timeout: 10),
            "Worktree title menu did not appear"
        )
        try saveLabScreenshot(name: "workspace-worktrees-compact-title-main-e2e")

        tap(worktreeMenu, named: "worktree title menu")
        let linkedWorktreeButton = app.buttons["workspace.worktree.\(linkedWorktreeId)"]
        XCTAssertTrue(
            linkedWorktreeButton.waitForExistence(timeout: 10),
            "Linked worktree menu item did not appear"
        )
        try saveLabScreenshot(name: "workspace-worktrees-title-menu-e2e")

        tap(linkedWorktreeButton, named: "linked worktree menu item")
        try saveLabScreenshot(name: "workspace-worktrees-compact-title-feature-e2e")

        tap(app.buttons["workspace.newSession"], named: "new session button")
        XCTAssertTrue(
            app.textViews["chat.input"].waitForExistence(timeout: 30),
            "Chat input did not appear after creating a session in the linked worktree"
        )
        let sessionId = try waitForSessionInWorktree(
            workspaceId: workspaceId,
            worktreeId: linkedWorktreeId,
            timeout: 20
        )
        XCTAssertFalse(sessionId.isEmpty, "Created session id should not be empty")
        try saveLabScreenshot(name: "workspace-worktrees-feature-session-e2e")
    }

    private func linkedWorktreeId(workspaceId: String) throws -> String {
        let response = try e2eLabAPIJSON(method: "GET", path: "/workspaces/\(workspaceId)/worktrees")
        let worktrees = try XCTUnwrap(response["worktrees"] as? [[String: Any]], "Worktrees response missing rows")
        let linked = try XCTUnwrap(
            worktrees.first { row in
                (row["branch"] as? String) == worktreeBranchName && (row["isMain"] as? Bool) == false
            },
            "Linked worktree branch \(worktreeBranchName) was not discovered"
        )
        return try XCTUnwrap(linked["id"] as? String, "Linked worktree row missing id")
    }

    private func waitForSessionInWorktree(
        workspaceId: String,
        worktreeId: String,
        timeout: TimeInterval
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latestRowsDescription = "[]"
        while Date() < deadline {
            let response = try e2eLabAPIJSON(
                method: "GET",
                path: "/workspaces/\(workspaceId)/sessions?status=active&worktreeId=\(worktreeId)"
            )
            let activeRows = response["active"] as? [[String: Any]] ?? []
            latestRowsDescription = String(describing: activeRows)
            if let row = activeRows.first(where: { ($0["worktreeId"] as? String) == worktreeId }),
               let sessionId = row["id"] as? String {
                return sessionId
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        XCTFail("No active session appeared in worktree \(worktreeId). Latest active rows: \(latestRowsDescription)")
        return ""
    }
}
