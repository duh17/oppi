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
        let sessionTouched = ContextBarScoping.sessionScope(gitStatus: gitStatus, changedFiles: ["a.swift"])

        #expect(ContextBarScoping.fileScopes(sessionId: "session-1", worktreeId: "wt-feature") == [.worktree, .session])
        let opening = ContextBarScoping.defaultFileScope(sessionId: "session-1", worktreeId: "wt-feature")
        #expect(opening == .worktree)
        let wide = ContextBarScoping.filtersToSession(sessionId: "session-1", worktreeId: "wt-feature", fileScope: opening)
        #expect(!wide)
        #expect(ContextBarScoping.displayFiles(
            gitStatus: gitStatus, filtersToSession: wide, sessionScope: sessionTouched
        ).map(\.path) == ["a.swift", "b.swift", "c.swift"])
        #expect(ContextBarScoping.displayFileCount(gitStatus: gitStatus, filtersToSession: wide, sessionScope: sessionTouched) == 3)
        #expect(ContextBarScoping.displayAddedLines(gitStatus: gitStatus, filtersToSession: wide, sessionScope: sessionTouched) == 6)

        let narrow = ContextBarScoping.filtersToSession(sessionId: "session-1", worktreeId: "wt-feature", fileScope: .session)
        #expect(narrow)
        #expect(ContextBarScoping.displayFiles(
            gitStatus: gitStatus, filtersToSession: narrow, sessionScope: sessionTouched
        ).map(\.path) == ["a.swift"])
        // All changes is the main checkout's widening; a worktree has none.
        #expect(!ContextBarScoping.filtersToSession(sessionId: "session-1", worktreeId: "wt-feature", fileScope: .all))
    }

    @Test func mainCheckoutSessionDefaultsToItsOwnFiles() {
        let allFiles = [
            makeFile("a.swift", added: 10, removed: 3),
            makeFile("b.swift", added: 5, removed: 1),
            makeFile("c.swift", added: 3, removed: 2),
        ]
        let gitStatus = makeDirtyGitStatus(totalFiles: 20, files: allFiles, addedLines: 200, removedLines: 80)
        let scope = ContextBarScoping.sessionScope(gitStatus: gitStatus, changedFiles: ["a.swift", "b.swift"])

        // No worktree and the main worktree's id are both the main checkout.
        for worktreeId in [nil, WorkspaceWorktree.mainId] {
            #expect(ContextBarScoping.fileScopes(sessionId: "session-1", worktreeId: worktreeId) == [.session, .all])
            let opening = ContextBarScoping.defaultFileScope(sessionId: "session-1", worktreeId: worktreeId)
            #expect(opening == .session)
            let filters = ContextBarScoping.filtersToSession(
                sessionId: "session-1", worktreeId: worktreeId, fileScope: opening
            )
            #expect(filters)
            #expect(ContextBarScoping.displayFiles(
                gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope
            ).map(\.path) == ["a.swift", "b.swift"])
            #expect(ContextBarScoping.displayFileCount(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope) == 2)
            #expect(ContextBarScoping.displayAddedLines(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope) == 15)
            #expect(ContextBarScoping.displayRemovedLines(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope) == 4)
        }
    }

    @Test func mainCheckoutSessionAllChangesListsEveryChange() {
        let allFiles = [
            makeFile("a.swift", added: 1, removed: 0),
            makeFile("b.swift", added: 2, removed: 1),
        ]
        let gitStatus = makeDirtyGitStatus(totalFiles: 2, files: allFiles, addedLines: 3, removedLines: 1)
        let scope = ContextBarScoping.sessionScope(gitStatus: gitStatus, changedFiles: ["a.swift"])
        let filters = ContextBarScoping.filtersToSession(sessionId: "session-1", worktreeId: nil, fileScope: .all)

        #expect(!filters)
        #expect(ContextBarScoping.displayFiles(
            gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope
        ).map(\.path) == ["a.swift", "b.swift"])
        #expect(ContextBarScoping.displayFileCount(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope) == 2)
        #expect(ContextBarScoping.displayAddedLines(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope) == 3)
    }

    /// A file the session wrote that Git no longer reports (committed, or
    /// outside the repository) still lists in This session, after Git's
    /// files, with no diff to open; the counts stay Git's.
    @Test func thisSessionListsTouchedFilesGitDoesNotReportAfterGitsOwn() throws {
        let gitStatus = makeDirtyGitStatus(
            totalFiles: 2,
            files: [makeFile("src/a.swift", added: 4, removed: 1), makeFile("src/b.swift", added: 2, removed: 0)]
        )
        let scope = ContextBarScoping.sessionScope(
            gitStatus: gitStatus,
            changedFiles: ["/tmp/plan.md", "/repo/src/b.swift", "src/committed.swift", "/tmp/plan.md"]
        )
        let files = ContextBarScoping.displayFiles(gitStatus: gitStatus, filtersToSession: true, sessionScope: scope)

        #expect(files.map(\.path) == ["src/b.swift", "/tmp/plan.md", "src/committed.swift"])
        #expect(files.map { $0.gitFile != nil } == [true, false, false])
        // The bar counts changes (the one Git reports); the header's touched
        // total counts the whole list.
        #expect(ContextBarScoping.displayFileCount(gitStatus: gitStatus, filtersToSession: true, sessionScope: scope) == 1)
        #expect(scope?.touchedCount == 3)
        #expect(ContextBarScoping.displayAddedLines(gitStatus: gitStatus, filtersToSession: true, sessionScope: scope) == 2)
    }

    /// Select picks only Git's files: a quick action sends the paths to the
    /// server, which refuses one Git does not report.
    @Test func selectOffersOnlyFilesGitReports() {
        let gitStatus = makeDirtyGitStatus(totalFiles: 2, files: [makeFile("src/a.swift", added: 1, removed: 0)])
        let scope = ContextBarScoping.sessionScope(gitStatus: gitStatus, changedFiles: ["/tmp/plan.md", "src/a.swift"])
        let files = ContextBarScoping.displayFiles(gitStatus: gitStatus, filtersToSession: true, sessionScope: scope)

        #expect(files.map(\.path) == ["src/a.swift", "/tmp/plan.md"])
        #expect(ContextBarScoping.selectablePaths(files) == ["src/a.swift"])
    }

    /// A capped touched list still totals the session's own count, so the
    /// header reads the same before and after the full list arrives.
    @Test func aCappedTouchedListCountsTheSessionsOwnTotal() {
        let gitStatus = makeDirtyGitStatus(totalFiles: 1, files: [makeFile("a.swift", added: 1, removed: 0)])
        let stats = SessionChangeStats(
            mutatingToolCalls: 9,
            filesChanged: 5,
            changedFiles: ["a.swift", "b.swift"],
            changedFilesOverflow: 3
        )
        let capped = ContextBarScoping.sessionScope(gitStatus: gitStatus, stats: stats)
        let full = ContextBarScoping.sessionScope(
            gitStatus: gitStatus,
            changedFiles: ["a.swift", "b.swift", "c.swift", "d.swift", "e.swift"],
            stats: stats
        )
        #expect(capped?.touchedCount == 5)
        #expect(full?.touchedCount == 5)
        #expect(ContextBarScoping.displayFileCount(gitStatus: gitStatus, filtersToSession: true, sessionScope: full) == 1)
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
        let scope = ContextBarScoping.sessionScope(gitStatus: gitStatus, changedFiles: [])
        let filters = ContextBarScoping.filtersToSession(sessionId: "session-1", worktreeId: nil, fileScope: .session)

        #expect(scope == nil)
        #expect(ContextBarScoping.displayFiles(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope).isEmpty)
        #expect(ContextBarScoping.displayFileCount(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope) == 0)
        #expect(ContextBarScoping.displayAddedLines(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope) == 0)
        #expect(ContextBarScoping.displayRemovedLines(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope) == 0)
    }

    @Test func sessionScopeMatchesTheSessionsAbsolutePathsToGitPaths() {
        let gitStatus = makeDirtyGitStatus(
            totalFiles: 2,
            files: [makeFile("src/a.swift", added: 4, removed: 1), makeFile("src/b.swift", added: 2, removed: 0)]
        )
        let scope = ContextBarScoping.sessionScope(gitStatus: gitStatus, changedFiles: ["/repo/src/a.swift"])
        #expect(scope?.touchedFiles.map(\.path) == ["src/a.swift"])
        #expect(scope?.touchedFiles.first?.gitFile != nil)
        #expect(ContextBarScoping.sessionScope(gitStatus: nil, changedFiles: ["/repo/src/a.swift"]) == nil)
        #expect(ContextBarScoping.sessionScope(gitStatus: gitStatus, changedFiles: nil) == nil)
    }

    // MARK: - Workspace totals

    @Test func workspaceViewShowsTotalUncommittedCountAndLines() {
        let gitStatus = makeDirtyGitStatus(totalFiles: 12, addedLines: 100, removedLines: 50)
        #expect(ContextBarScoping.displayFileCount(gitStatus: gitStatus, filtersToSession: false, sessionScope: nil) == 12)
        #expect(ContextBarScoping.displayAddedLines(gitStatus: gitStatus, filtersToSession: false, sessionScope: nil) == 100)
        #expect(ContextBarScoping.displayRemovedLines(gitStatus: gitStatus, filtersToSession: false, sessionScope: nil) == 50)
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
