import Testing
@testable import Oppi

/// Tests for the WorkspaceContextBar session-scoping contract:
/// - When `sessionId` is set, the bar only shows content from that session's changed files.
/// - When `sessionId` is nil (workspace view), the bar shows full workspace git status.
///
/// These test the display-property logic that the view relies on, extracted into
/// pure functions so we don't need a SwiftUI host.
@Suite("Context bar session scoping")
struct ContextBarScopingTests {

    // MARK: - hasContent

    @Test func workspaceViewShowsBarWhenRepoDirty() {
        let hasContent = ContextBarScoping.hasContent(
            gitStatus: makeDirtyGitStatus(),
            sessionId: nil,
            sessionScope: nil
        )
        #expect(hasContent == true)
    }

    @Test func workspaceViewHidesBarWhenRepoClean() {
        let hasContent = ContextBarScoping.hasContent(
            gitStatus: makeCleanGitStatus(),
            sessionId: nil,
            sessionScope: nil
        )
        #expect(hasContent == false)
    }

    @Test func sessionViewHidesBarWhenNoSessionChanges() {
        let hasContent = ContextBarScoping.hasContent(
            gitStatus: makeDirtyGitStatus(),
            sessionId: "session-1",
            sessionScope: nil
        )
        #expect(hasContent == false)
    }

    @Test func sessionViewShowsBarWhenSessionHasChanges() {
        let scope = makeScope(sessionFiles: [makeFile("a.swift", added: 5, removed: 2)])
        let hasContent = ContextBarScoping.hasContent(
            gitStatus: makeDirtyGitStatus(),
            sessionId: "session-1",
            sessionScope: scope
        )
        #expect(hasContent == true)
    }

    @Test func sessionViewHidesBarWhenGitStatusNil() {
        let hasContent = ContextBarScoping.hasContent(
            gitStatus: nil,
            sessionId: "session-1",
            sessionScope: nil
        )
        #expect(hasContent == false)
    }

    @Test func sessionViewHidesBarWhenNotGitRepo() {
        let hasContent = ContextBarScoping.hasContent(
            gitStatus: makeNonGitStatus(),
            sessionId: "session-1",
            sessionScope: nil
        )
        #expect(hasContent == false)
    }

    // MARK: - displayFileCount

    @Test func workspaceViewShowsTotalUncommittedCount() {
        let count = ContextBarScoping.displayFileCount(
            gitStatus: makeDirtyGitStatus(totalFiles: 12),
            sessionId: nil,
            sessionScope: nil
        )
        #expect(count == 12)
    }

    @Test func sessionViewShowsOnlySessionFileCount() {
        let scope = makeScope(sessionFiles: [
            makeFile("a.swift", added: 1, removed: 0),
            makeFile("b.swift", added: 2, removed: 1),
        ])
        let count = ContextBarScoping.displayFileCount(
            gitStatus: makeDirtyGitStatus(totalFiles: 20),
            sessionId: "session-1",
            sessionScope: scope
        )
        #expect(count == 2)
    }

    @Test func sessionViewReturnsZeroWhenNoScope() {
        let count = ContextBarScoping.displayFileCount(
            gitStatus: makeDirtyGitStatus(totalFiles: 20),
            sessionId: "session-1",
            sessionScope: nil
        )
        #expect(count == 0)
    }

    // MARK: - displayAddedLines / displayRemovedLines

    @Test func workspaceViewShowsTotalLineStats() {
        let gitStatus = makeDirtyGitStatus(addedLines: 100, removedLines: 50)
        let added = ContextBarScoping.displayAddedLines(
            gitStatus: gitStatus, sessionId: nil, sessionScope: nil
        )
        let removed = ContextBarScoping.displayRemovedLines(
            gitStatus: gitStatus, sessionId: nil, sessionScope: nil
        )
        #expect(added == 100)
        #expect(removed == 50)
    }

    @Test func sessionViewShowsOnlySessionLineStats() {
        let scope = makeScope(sessionFiles: [
            makeFile("a.swift", added: 10, removed: 3),
            makeFile("b.swift", added: 5, removed: 1),
        ])
        let gitStatus = makeDirtyGitStatus(addedLines: 200, removedLines: 80)
        let added = ContextBarScoping.displayAddedLines(
            gitStatus: gitStatus, sessionId: "session-1", sessionScope: scope
        )
        let removed = ContextBarScoping.displayRemovedLines(
            gitStatus: gitStatus, sessionId: "session-1", sessionScope: scope
        )
        #expect(added == 15)
        #expect(removed == 4)
    }

    @Test func sessionViewReturnsZeroLinesWhenNoScope() {
        let gitStatus = makeDirtyGitStatus(addedLines: 200, removedLines: 80)
        let added = ContextBarScoping.displayAddedLines(
            gitStatus: gitStatus, sessionId: "session-1", sessionScope: nil
        )
        let removed = ContextBarScoping.displayRemovedLines(
            gitStatus: gitStatus, sessionId: "session-1", sessionScope: nil
        )
        #expect(added == 0)
        #expect(removed == 0)
    }

    // MARK: - displayFiles

    @Test func workspaceViewShowsAllFiles() {
        let files = [makeFile("a.swift", added: 1, removed: 0), makeFile("b.swift", added: 2, removed: 1)]
        let gitStatus = makeDirtyGitStatus(files: files)
        let display = ContextBarScoping.displayFiles(
            gitStatus: gitStatus, sessionId: nil, sessionScope: nil
        )
        #expect(display.count == 2)
    }

    @Test func sessionViewShowsOnlySessionFiles() {
        let sessionFiles = [makeFile("a.swift", added: 1, removed: 0)]
        let scope = makeScope(sessionFiles: sessionFiles)
        let allFiles = [
            makeFile("a.swift", added: 1, removed: 0),
            makeFile("b.swift", added: 2, removed: 1),
            makeFile("c.swift", added: 3, removed: 2),
        ]
        let display = ContextBarScoping.displayFiles(
            gitStatus: makeDirtyGitStatus(files: allFiles),
            sessionId: "session-1",
            sessionScope: scope
        )
        #expect(display.count == 1)
        #expect(display[0].path == "a.swift")
    }

    @Test func sessionViewReturnsEmptyWhenNoScope() {
        let allFiles = [makeFile("a.swift", added: 1, removed: 0)]
        let display = ContextBarScoping.displayFiles(
            gitStatus: makeDirtyGitStatus(files: allFiles),
            sessionId: "session-1",
            sessionScope: nil
        )
        #expect(display.isEmpty)
    }

    // MARK: - Dirty workspace does not leak into session

    @Test func dirtyWorkspaceDoesNotLeakIntoSessionWithNoChanges() {
        let gitStatus = makeDirtyGitStatus(
            totalFiles: 15,
            files: (0..<15).map { makeFile("file\($0).swift", added: 10, removed: 5) },
            addedLines: 150,
            removedLines: 75
        )

        // Session exists but hasn't touched any files
        let hasContent = ContextBarScoping.hasContent(
            gitStatus: gitStatus, sessionId: "session-1", sessionScope: nil
        )
        let fileCount = ContextBarScoping.displayFileCount(
            gitStatus: gitStatus, sessionId: "session-1", sessionScope: nil
        )
        let added = ContextBarScoping.displayAddedLines(
            gitStatus: gitStatus, sessionId: "session-1", sessionScope: nil
        )
        let removed = ContextBarScoping.displayRemovedLines(
            gitStatus: gitStatus, sessionId: "session-1", sessionScope: nil
        )
        let files = ContextBarScoping.displayFiles(
            gitStatus: gitStatus, sessionId: "session-1", sessionScope: nil
        )

        #expect(hasContent == false)
        #expect(fileCount == 0)
        #expect(added == 0)
        #expect(removed == 0)
        #expect(files.isEmpty)
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
            gitStatus: makeDirtyGitStatus(),
            sessionFiles: sessionFiles,
            sessionFileCount: sessionFiles.count,
            sessionAddedLines: added,
            sessionRemovedLines: removed,
            totalFileCount: 10
        )
    }
}
