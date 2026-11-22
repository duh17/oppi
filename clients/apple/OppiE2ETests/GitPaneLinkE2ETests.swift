import Foundation
import XCTest

/// A linked Git against the real server: a linked worktree with commits and
/// uncommitted changes, opened from its `oppi://git` link. Its pane loads the
/// worktree's status on its own, a changed file and a commit's file each push
/// onto the pane's stack with Back, opening the workspace beside it (another
/// checkout) leaves its status alone, and after a relaunch the link loads it
/// again with no chat or other screen asking for it. Run
/// through `clients/apple/scripts/e2e.sh --native` (iPad:
/// `OPPI_SIM_DEVICE_PROFILE=ipad`).
@MainActor
final class GitPaneLinkE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceName = ""
    nonisolated(unsafe) private var gitLink: URL?

    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchArguments += [
            "-dev.chenda.Oppi.theme.mode", "manual",
            "-dev.chenda.Oppi.theme.id", "dark",
        ]
    }

    override func seedE2EFixtures() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let fixture = try createLabGitWorktreeFixture(
            directoryName: "git-pane-link-\(suffix)", branchName: "feature/git-pane", withChanges: true
        )
        workspaceName = "Git Pane Lab \(suffix)"
        let workspaceId = try createLabWorkspace(named: workspaceName, hostMount: fixture.hostMount)
        let worktrees = try XCTUnwrap(
            e2eLabAPIJSON(method: "GET", path: "/workspaces/\(workspaceId)/worktrees")["worktrees"] as? [[String: Any]],
            "Worktrees response missing rows"
        )
        let linked = try XCTUnwrap(
            worktrees.first { ($0["isMain"] as? Bool) == false }?["id"] as? String,
            "The linked worktree was not discovered"
        )
        var link = URLComponents(string: "oppi://git")
        link?.queryItems = [URLQueryItem(name: "workspace", value: workspaceId), URLQueryItem(name: "worktree", value: linked)]
        gitLink = try XCTUnwrap(link?.url)
    }

    func testLinkedGitPaneRowsPushWithBack() throws {
        let (pane, changed) = try openLinkedGit()
        beat()
        try saveLabScreenshot(name: "git-pane-link-opened")

        // A changed file pushes its review with Back.
        tap(changed, named: "changed App.swift")
        let review = app.navigationBars["App.swift"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), "The file's review opened")
        XCTAssertTrue(review.buttons["BackButton"].exists, "The review has the stack's Back")
        beat()
        try saveLabScreenshot(name: "git-pane-link-diff")
        tap(review.buttons["BackButton"], named: "review Back")
        XCTAssertTrue(changed.waitForExistence(timeout: 5), "Back returns to the Git list")

        // A commit, then its file: two pushes, two Backs.
        let commitRow = pane.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Describe the routes")).firstMatch
        XCTAssertTrue(commitRow.waitForExistence(timeout: 10), "The Git pane lists the worktree's commits")
        tap(commitRow, named: "commit row")
        let commit = app.navigationBars["Commit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 10), "The commit opened")
        let commitFile = app.buttons["commit-detail.file"].firstMatch
        XCTAssertTrue(commitFile.waitForExistence(timeout: 10), "The commit lists its file")
        tap(commitFile, named: "commit file")
        let diff = app.navigationBars["README.md"]
        XCTAssertTrue(diff.waitForExistence(timeout: 10), "The commit's file diff opened")
        XCTAssertTrue(diff.buttons["BackButton"].exists, "The commit's diff has the stack's Back")
        beat()
        try saveLabScreenshot(name: "git-pane-link-commit-diff")
        tap(diff.buttons["BackButton"], named: "diff Back")
        XCTAssertTrue(commit.waitForExistence(timeout: 5), "Back returns to the commit")
        tap(commit.buttons["BackButton"], named: "commit Back")
        XCTAssertTrue(changed.waitForExistence(timeout: 5), "Back again returns to the Git list")
    }

    func testLinkedGitPaneKeepsItsStatusAndLoadsAfterRelaunch() throws {
        let (_, changed) = try openLinkedGit()

        // A compact window covers the main pane with the link's Git panel, so
        // only an iPad has a sidebar beside the pane to open another checkout
        // from.
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Another screen loading another checkout of the same workspace (its
            // Workspace Detail reads the main checkout) leaves the pane's alone.
            openSidebar()
            tap(app.descendants(matching: .any)["workspace.open.\(workspaceName)"].firstMatch, named: "the workspace in the sidebar", timeout: 10)
            XCTAssertTrue(app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 15), "The workspace opened")
            beat(4)
            XCTAssertTrue(changed.exists, "The Git pane kept its worktree's status after another checkout loaded: \(stateValue)")
            try saveLabScreenshot(name: "git-pane-link-beside-workspace")
        }

        // Cold: a relaunch, then the link, with nothing else asking for its status.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 20), "The relaunch showed All Sessions")
        app.open(try XCTUnwrap(gitLink))
        let cold = app.descendants(matching: .any)["git.pane"]
        XCTAssertTrue(cold.waitForExistence(timeout: 10), "The linked Git opened after the relaunch")
        let started = Date()
        XCTAssertTrue(changedRow(in: cold).waitForExistence(timeout: 15),
                      "The Git pane loaded on its own after a relaunch: \(stateValue)")
        let note = XCTAttachment(string: String(format: "After relaunch the Git pane listed its changes %.1f s after it appeared", Date().timeIntervalSince(started)))
        note.name = "git-pane-cold-load-time"
        note.lifetime = .keepAlways
        add(note)
        beat()
        try saveLabScreenshot(name: "git-pane-link-after-relaunch")
    }

    // MARK: Helpers

    /// Opens the worktree's Git from its link and waits for its changes.
    private func openLinkedGit() throws -> (pane: XCUIElement, changed: XCUIElement) {
        XCTAssertTrue(app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 20), "All Sessions did not appear")
        app.open(try XCTUnwrap(gitLink))
        let pane = app.descendants(matching: .any)["git.pane"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "The linked Git opened")
        let changed = changedRow(in: pane)
        XCTAssertTrue(changed.waitForExistence(timeout: 10), "The Git pane loaded the worktree's changes: \(stateValue)")
        return (pane, changed)
    }

    private func changedRow(in pane: XCUIElement) -> XCUIElement {
        pane.buttons.matching(NSPredicate(format: "label CONTAINS %@", "App.swift")).firstMatch
    }

    /// The panel's state view's kind (loading, connecting, failed, empty), for failures.
    private var stateValue: String {
        let state = app.descendants(matching: .any)["git.panel.status"]
        return state.exists ? "state \(state.value as? String ?? "?")" : "no state view"
    }

    private func openSidebar() {
        let row = app.buttons["workspace.pinned.open"]
        if !(row.exists && row.isHittable) {
            let drawer = app.buttons["workspace.sidebar.open"]
            if drawer.waitForExistence(timeout: 3) {
                tap(drawer, named: "workspace drawer")
            } else {
                revealSplitSidebarIfNeeded(in: app)
            }
        }
    }

    private func beat(_ seconds: TimeInterval = 1.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
