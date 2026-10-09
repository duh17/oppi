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

    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    /// The fixture is created in setUp. Relaunch so the catalog includes it.
    /// The old `workspace.list` home is gone; the launch hint opens this workspace
    /// the same way other paired labs do. Sidebar row taps currently dismiss the
    /// drawer without running the row action, so they are not the setup path.
    override var e2eRequiresFreshLaunch: Bool { true }
    override var e2eSkipsLaunchNavigation: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchEnvironment["OPPI_E2E_AUTO_OPEN_WORKSPACE"] = worktreeWorkspaceName
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
        dismissExtensionSheetIfNeeded(timeout: 3)
        XCTAssertTrue(
            app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 20),
            "Fixture workspace detail did not open"
        )
        XCTAssertTrue(
            app.staticTexts[worktreeWorkspaceName].waitForExistence(timeout: 10),
            "Fixture workspace title did not appear"
        )

        let linkedWorktreeId = try linkedWorktreeId(workspaceId: workspaceId)
        let worktreeMenu = app.buttons["workspace.worktree.menu"]
        XCTAssertTrue(
            worktreeMenu.waitForExistence(timeout: 10),
            "Worktree title menu did not appear"
        )
        try saveLabScreenshot(name: "workspace-worktrees-compact-title-main-e2e")

        // Accessibility activate does not open this menu. A touch does.
        // The row's identifier is the checkout path, longer than XCUITest's
        // 128-character subscript limit, so match the branch the menu shows.
        worktreeMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let linkedWorktreeButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", worktreeBranchName)
        ).firstMatch
        XCTAssertTrue(
            linkedWorktreeButton.waitForExistence(timeout: 10),
            "Linked worktree menu item did not appear"
        )
        try saveLabScreenshot(name: "workspace-worktrees-title-menu-e2e")

        linkedWorktreeButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try saveLabScreenshot(name: "workspace-worktrees-compact-title-feature-e2e")

        tap(app.buttons["workspace.quickSession.start"], named: "quick session compose capsule")
        let input = app.textViews["chat.input"]
        XCTAssertTrue(
            input.waitForExistence(timeout: 30),
            "Quick Session input did not appear from the workspace list"
        )
        tap(input, named: "quick session input", timeout: 5)
        input.typeText("E2E_WORKTREE_QUICK_SESSION")
        tap(app.buttons["chat.send"], named: "quick session send button", timeout: 5)
        XCTAssertTrue(
            app.buttons["chat.toolbar.files"].waitForExistence(timeout: 30),
            "Chat session did not open after sending from the worktree-preselected Quick Session"
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
