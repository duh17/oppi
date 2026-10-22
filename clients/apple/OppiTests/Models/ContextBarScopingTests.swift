import Foundation
import Testing
@testable import Oppi

/// Tests for the context bar's scoping contract:
/// - A workspace's bar (no session) lists the whole Git status.
/// - A session in a worktree of its own lists the whole Git status: every
///   change there is its, including ones its shell commands made.
/// - A session in the main checkout lists only its own files ("This session")
///   until the switch asks for "All changes".
///
/// These test the display-property logic that the view relies on, extracted into
/// pure functions so we don't need a view host.
@Suite("Context bar session scoping")
struct ContextBarScopingTests {

    // MARK: - hasContent

    @Test func workspaceViewShowsBarWhenRepoDirty() {
        #expect(ContextBarScoping.hasContent(gitStatus: makeDirtyGitStatus()))
    }

    @Test func workspaceViewHidesBarWhenRepoClean() {
        #expect(!ContextBarScoping.hasContent(gitStatus: makeCleanGitStatus()))
    }

    @Test func workspaceSessionListCanShowBarWhenRepoClean() {
        #expect(ContextBarScoping.hasContent(gitStatus: makeCleanGitStatus(), showCleanWorkspace: true))
    }

    @Test func barHasNoContentOutsideGit() {
        #expect(!ContextBarScoping.hasContent(gitStatus: nil, showCleanWorkspace: true))
        #expect(!ContextBarScoping.hasContent(gitStatus: makeNonGitStatus(), showCleanWorkspace: true))
    }

    // MARK: - Which changes a bar lists

    @Test func workspaceBarListsEveryChange() {
        #expect(!ContextBarScoping.offersFileScope(sessionId: nil, worktreeId: nil))
        #expect(!ContextBarScoping.filtersToSession(sessionId: nil, worktreeId: nil, fileScope: .session))
    }

    @Test func worktreeSessionListsEveryChangeWithNoSwitch() {
        let allFiles = [
            makeFile("a.swift", added: 1, removed: 0),
            makeFile("b.swift", added: 2, removed: 1),
            makeFile("c.swift", added: 3, removed: 2),
        ]
        let gitStatus = makeDirtyGitStatus(totalFiles: 3, files: allFiles, addedLines: 6, removedLines: 3)
        // The session's edit and write calls touched only a.swift; a script
        // it ran changed the rest. All of it is the session's worktree.
        let sessionTouched = makeScope(sessionFiles: [allFiles[0]])

        #expect(!ContextBarScoping.offersFileScope(sessionId: "session-1", worktreeId: "wt-feature"))
        for scope in [ContextBarScoping.FileScope.session, .all] {
            let filters = ContextBarScoping.filtersToSession(
                sessionId: "session-1", worktreeId: "wt-feature", fileScope: scope
            )
            #expect(!filters)
            #expect(ContextBarScoping.displayFiles(
                gitStatus: gitStatus, filtersToSession: filters, sessionScope: sessionTouched
            ).map(\.path) == ["a.swift", "b.swift", "c.swift"])
            #expect(ContextBarScoping.displayFileCount(
                gitStatus: gitStatus, filtersToSession: filters, sessionScope: sessionTouched
            ) == 3)
            #expect(ContextBarScoping.displayAddedLines(
                gitStatus: gitStatus, filtersToSession: filters, sessionScope: sessionTouched
            ) == 6)
            #expect(ContextBarScoping.displayRemovedLines(
                gitStatus: gitStatus, filtersToSession: filters, sessionScope: sessionTouched
            ) == 3)
        }
    }

    @Test func mainCheckoutSessionDefaultsToItsOwnFiles() {
        let allFiles = [
            makeFile("a.swift", added: 10, removed: 3),
            makeFile("b.swift", added: 5, removed: 1),
            makeFile("c.swift", added: 3, removed: 2),
        ]
        let gitStatus = makeDirtyGitStatus(totalFiles: 20, files: allFiles, addedLines: 200, removedLines: 80)
        let scope = makeScope(sessionFiles: Array(allFiles.prefix(2)))

        // No worktree and the main worktree's id are both the main checkout.
        for worktreeId in [nil, WorkspaceWorktree.mainId] {
            #expect(ContextBarScoping.offersFileScope(sessionId: "session-1", worktreeId: worktreeId))
            let filters = ContextBarScoping.filtersToSession(
                sessionId: "session-1", worktreeId: worktreeId, fileScope: .session
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
        let scope = makeScope(sessionFiles: [allFiles[0]])
        let filters = ContextBarScoping.filtersToSession(sessionId: "session-1", worktreeId: nil, fileScope: .all)

        #expect(!filters)
        #expect(ContextBarScoping.displayFiles(
            gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope
        ).map(\.path) == ["a.swift", "b.swift"])
        #expect(ContextBarScoping.displayFileCount(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope) == 2)
        #expect(ContextBarScoping.displayAddedLines(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope) == 3)
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
        #expect(ContextBarScoping.hasContent(gitStatus: gitStatus, showCleanWorkspace: true))
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
        #expect(scope?.sessionFiles.map(\.path) == ["src/a.swift"])
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

    private func makeCleanGitStatus() -> GitStatus {
        GitStatus(
            isGitRepo: true, branch: "main", headSha: "abc1234",
            ahead: 0, behind: 0, dirtyCount: 0, untrackedCount: 0, stagedCount: 0,
            files: [], totalFiles: 0,
            addedLines: 0, removedLines: 0,
            stashCount: 0, lastCommitMessage: "test", lastCommitDate: nil, recentCommits: []
        )
    }

    private func makeNonGitStatus() -> GitStatus {
        GitStatus(
            isGitRepo: false, branch: nil, headSha: nil,
            ahead: nil, behind: nil, dirtyCount: 0, untrackedCount: 0, stagedCount: 0,
            files: [], totalFiles: 0,
            addedLines: 0, removedLines: 0,
            stashCount: 0, lastCommitMessage: nil, lastCommitDate: nil, recentCommits: []
        )
    }

    private func makeScope(sessionFiles: [GitFileStatus]) -> SessionScopedGitStatus {
        let added = sessionFiles.compactMap(\.addedLines).reduce(0, +)
        let removed = sessionFiles.compactMap(\.removedLines).reduce(0, +)
        return SessionScopedGitStatus(
            sessionFiles: sessionFiles,
            sessionFileCount: sessionFiles.count,
            sessionAddedLines: added,
            sessionRemovedLines: removed
        )
    }
}
