import Foundation
import Testing
@testable import Oppi

/// Tests for the Git panel's scoping contract:
/// - A workspace's bar (no session) lists the whole Git status, with no switch.
/// - A session in a worktree of its own opens on This worktree (every change
///   there is its, shell changes too) and can narrow to This session.
/// - A session in the main checkout opens on This session (the files its tool
///   calls touched) and can widen to All changes.
/// - This session lists every touched file; one Git does not report opens
///   the session's copy instead of a diff.
///
/// These test the display-property logic that the view relies on, extracted into
/// pure functions so we don't need a view host.
@Suite("Context bar session scoping")
struct ContextBarScopingTests {

    // MARK: - Which changes a bar lists

    @Test func workspaceBarListsEveryChangeWithNoSwitch() {
        #expect(ContextBarScoping.fileScopes(sessionId: nil, worktreeId: nil).isEmpty)
        #expect(ContextBarScoping.defaultFileScope(sessionId: nil, worktreeId: "wt-feature") == .all)
        #expect(!ContextBarScoping.filtersToSession(sessionId: nil, worktreeId: nil, fileScope: .session))
    }

    @Test func worktreeSessionOpensOnTheWorktreeAndCanNarrowToItsOwnFiles() {
        let allFiles = [
            makeFile("a.swift", added: 1, removed: 0),
            makeFile("b.swift", added: 2, removed: 1),
            makeFile("c.swift", added: 3, removed: 2),
        ]
        let gitStatus = makeDirtyGitStatus(totalFiles: 3, files: allFiles, addedLines: 6, removedLines: 3)
        // The session's edit and write calls touched only a.swift; a script
        // it ran changed the rest. All of it is the session's worktree.
        let touched = ["a.swift"]

        #expect(ContextBarScoping.fileScopes(sessionId: "session-1", worktreeId: "wt-feature") == [.worktree, .session])
        let opening = ContextBarScoping.defaultFileScope(sessionId: "session-1", worktreeId: "wt-feature")
        #expect(opening == .worktree)
        let wide = changes(gitStatus, worktreeId: "wt-feature", scope: opening, touched: touched)
        #expect(!wide.filtersToSession)
        #expect(wide.files.map(\.path) == ["a.swift", "b.swift", "c.swift"])
        #expect(wide.fileCount == 3)
        #expect(wide.addedLines == 6)

        let narrow = changes(gitStatus, worktreeId: "wt-feature", scope: .session, touched: touched)
        #expect(narrow.filtersToSession)
        #expect(narrow.files.map(\.path) == ["a.swift"])
        // All changes is the main checkout's widening; a worktree has none.
        #expect(!changes(gitStatus, worktreeId: "wt-feature", scope: .all, touched: touched).filtersToSession)
    }

    @Test func mainCheckoutSessionDefaultsToItsOwnFiles() {
        let allFiles = [
            makeFile("a.swift", added: 10, removed: 3),
            makeFile("b.swift", added: 5, removed: 1),
            makeFile("c.swift", added: 3, removed: 2),
        ]
        let gitStatus = makeDirtyGitStatus(totalFiles: 20, files: allFiles, addedLines: 200, removedLines: 80)

        // No worktree and the main worktree's id are both the main checkout.
        for worktreeId in [nil, WorkspaceWorktree.mainId] {
            #expect(ContextBarScoping.fileScopes(sessionId: "session-1", worktreeId: worktreeId) == [.session, .all])
            let opening = ContextBarScoping.defaultFileScope(sessionId: "session-1", worktreeId: worktreeId)
            #expect(opening == .session)
            let shown = changes(gitStatus, worktreeId: worktreeId, scope: opening, touched: ["a.swift", "b.swift"])
            #expect(shown.filtersToSession)
            #expect(shown.files.map(\.path) == ["a.swift", "b.swift"])
            #expect(shown.fileCount == 2)
            #expect(shown.addedLines == 15)
            #expect(shown.removedLines == 4)
        }
    }

    @Test func mainCheckoutSessionAllChangesListsEveryChange() {
        let allFiles = [
            makeFile("a.swift", added: 1, removed: 0),
            makeFile("b.swift", added: 2, removed: 1),
        ]
        let gitStatus = makeDirtyGitStatus(totalFiles: 2, files: allFiles, addedLines: 3, removedLines: 1)
        let shown = changes(gitStatus, scope: .all, touched: ["a.swift"])

        #expect(!shown.filtersToSession)
        #expect(shown.files.map(\.path) == ["a.swift", "b.swift"])
        #expect(shown.fileCount == 2)
        #expect(shown.addedLines == 3)
    }

    /// A file the session wrote that Git no longer reports (committed, or
    /// outside the repository) still lists in This session, after Git's
    /// files, with no diff to open; the counts stay Git's.
    @Test func thisSessionListsTouchedFilesGitDoesNotReportAfterGitsOwn() throws {
        let gitStatus = makeDirtyGitStatus(
            totalFiles: 2,
            files: [makeFile("src/a.swift", added: 4, removed: 1), makeFile("src/b.swift", added: 2, removed: 0)]
        )
        let shown = changes(
            gitStatus,
            touched: ["/tmp/plan.md", "/repo/src/b.swift", "src/committed.swift", "/tmp/plan.md"]
        )
        let files = shown.files

        #expect(files.map(\.path) == ["src/b.swift", "/tmp/plan.md", "src/committed.swift"])
        #expect(files.map { $0.gitFile != nil } == [true, false, false])
        // The bar counts changes (the one Git reports); the header's touched
        // total counts the whole list.
        #expect(shown.fileCount == 1)
        #expect(shown.touchedCount == 3)
        #expect(shown.addedLines == 2)
    }

    /// Select picks only Git's files: a quick action sends the paths to the
    /// server, which refuses one Git does not report.
    @Test func selectOffersOnlyFilesGitReports() {
        let gitStatus = makeDirtyGitStatus(totalFiles: 2, files: [makeFile("src/a.swift", added: 1, removed: 0)])
        let files = changes(gitStatus, touched: ["/tmp/plan.md", "src/a.swift"]).files

        #expect(files.map(\.path) == ["src/a.swift", "/tmp/plan.md"])
        #expect(ContextBarScoping.selectablePaths(files) == ["src/a.swift"])
    }

    /// A capped touched list still totals the session's own count, so the
    /// header reads the same before and after the full list arrives.
    @Test func aCappedTouchedListCountsTheSessionsOwnTotal() {
        let gitStatus = makeDirtyGitStatus(totalFiles: 1, files: [makeFile("a.swift", added: 1, removed: 0)])
        // The capped list the session reports (`changeStats.changedFiles`),
        // then the full list once the host has loaded it.
        let capped = changes(gitStatus, touched: ["a.swift", "b.swift"], reported: 5)
        let full = changes(
            gitStatus,
            touched: ["a.swift", "b.swift", "c.swift", "d.swift", "e.swift"],
            reported: 5
        )
        #expect(capped.touchedCount == 5)
        #expect(full.touchedCount == 5)
        #expect(full.fileCount == 1)
    }

    /// The Git button and the panel read one list: the loaded full list only
    /// while it is this session's at its current count, else the capped one.
    @Test func theLoadedTouchedListCountsOnlyForItsSessionAndCount() {
        let stats = SessionChangeStats(mutatingToolCalls: 3, filesChanged: 3, changedFiles: ["a.swift"], changedFilesOverflow: 2)
        var list = SessionTouchedList(workspaceId: "w1", sessionId: "s1", filesChanged: 3)
        #expect(SessionTouchedList.paths(list, workspaceId: "w1", sessionId: "s1", stats: stats) == ["a.swift"])
        list.paths = ["a.swift", "b.swift", "c.swift"]
        #expect(SessionTouchedList.paths(list, workspaceId: "w1", sessionId: "s1", stats: stats) == ["a.swift", "b.swift", "c.swift"])
        #expect(SessionTouchedList.paths(list, workspaceId: "w2", sessionId: "s1", stats: stats) == ["a.swift"])
        #expect(SessionTouchedList.paths(list, workspaceId: "w1", sessionId: "s2", stats: stats) == ["a.swift"])
        var moved = stats
        moved.filesChanged = 4
        #expect(SessionTouchedList.paths(list, workspaceId: "w1", sessionId: "s1", stats: moved) == ["a.swift"])
    }

    /// A dirty checkout the session has not touched: "This session" lists
    /// nothing and counts nothing, but the bar still has its branch, commits,
    /// and the switch to every change.
    @Test func mainCheckoutSessionWithNoOwnChangesKeepsTheBarButListsNothing() {
        let gitStatus = makeDirtyGitStatus(
            totalFiles: 15,
            files: (0..<15).map { makeFile("file\($0).swift", added: 10, removed: 5) },
            addedLines: 150,
            removedLines: 75
        )
        let shown = changes(gitStatus, touched: [])

        #expect(shown.sessionScope == nil)
        #expect(shown.files.isEmpty)
        #expect(shown.fileCount == 0)
        #expect(shown.addedLines == 0)
        #expect(shown.removedLines == 0)
    }

    /// The session's tool calls name absolute paths; Git's are repo-relative.
    @Test func sessionScopeMatchesTheSessionsAbsolutePathsToGitPaths() {
        let gitStatus = makeDirtyGitStatus(
            totalFiles: 2,
            files: [makeFile("src/a.swift", added: 4, removed: 1), makeFile("src/b.swift", added: 2, removed: 0)]
        )
        let scope = changes(gitStatus, touched: ["/repo/src/a.swift"]).sessionScope
        #expect(scope?.touchedFiles.map(\.path) == ["src/a.swift"])
        #expect(scope?.touchedFiles.first?.gitFile != nil)
        #expect(changes(nil, touched: ["/repo/src/a.swift"]).sessionScope == nil)
        #expect(changes(gitStatus, touched: nil).sessionScope == nil)
    }

    // MARK: - Workspace totals

    @Test func workspaceViewShowsTotalUncommittedCountAndLines() {
        let gitStatus = makeDirtyGitStatus(totalFiles: 12, addedLines: 100, removedLines: 50)
        let shown = changes(gitStatus, sessionId: nil, scope: .all, touched: nil)
        #expect(shown.fileCount == 12)
        #expect(shown.addedLines == 100)
        #expect(shown.removedLines == 50)
    }

    // MARK: - Quick action routing

    @Test func quickActionTapInSessionUsesCurrentSessionByDefault() {
        let route = ContextBarQuickActionRouting.defaultTapRoute(
            sessionId: "session-1",
            canReviewInCurrentSession: true
        )

        #expect(route == .currentSession)
    }

    @Test func quickActionTapInWorkspaceStartsNewSessionByDefault() {
        let route = ContextBarQuickActionRouting.defaultTapRoute(
            sessionId: nil,
            canReviewInCurrentSession: false
        )

        #expect(route == .newSession)
    }

    @Test func quickActionTapInSessionFallsBackToNewSessionWithoutCurrentSessionHandler() {
        let route = ContextBarQuickActionRouting.defaultTapRoute(
            sessionId: "session-1",
            canReviewInCurrentSession: false
        )

        #expect(route == .newSession)
    }

    // MARK: - Helpers

    /// The real entry the Git button and the panel share. Defaults: a main
    /// checkout session on This session.
    private func changes(
        _ gitStatus: GitStatus?,
        sessionId: String? = "session-1",
        worktreeId: String? = nil,
        scope: ContextBarScoping.FileScope = .session,
        touched: [String]?,
        reported: Int = 0
    ) -> ContextBarScoping.DisplayedChanges {
        ContextBarScoping.displayedChanges(
            gitStatus: gitStatus,
            sessionId: sessionId,
            worktreeId: worktreeId,
            fileScope: scope,
            touchedPaths: touched,
            reportedTouchedCount: reported
        )
    }

    private func makeFile(_ path: String, added: Int, removed: Int) -> GitFileStatus {
        GitFileStatus(status: " M", path: path, addedLines: added, removedLines: removed)
    }

    private func makeDirtyGitStatus(
        totalFiles: Int = 5,
        files: [GitFileStatus]? = nil,
        addedLines: Int = 30,
        removedLines: Int = 10
    ) -> GitStatus {
        let resolvedFiles = files ?? (0..<totalFiles).map {
            makeFile("file\($0).swift", added: addedLines / max(totalFiles, 1), removed: removedLines / max(totalFiles, 1))
        }
        return GitStatus(
            isGitRepo: true, branch: "main", headSha: "abc1234",
            ahead: 0, behind: 0, dirtyCount: totalFiles, untrackedCount: 0, stagedCount: 0,
            files: resolvedFiles, totalFiles: totalFiles,
            addedLines: addedLines, removedLines: removedLines,
            stashCount: 0, lastCommitMessage: "test", lastCommitDate: nil, recentCommits: []
        )
    }
}
