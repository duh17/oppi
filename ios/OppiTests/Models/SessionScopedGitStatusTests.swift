import Testing
@testable import Oppi

@Suite("SessionScopedGitStatus")
struct SessionScopedGitStatusTests {

    // MARK: - Path matching

    @Test func absoluteSessionPathMatchesRelativeGitPath() {
        let result = SessionScopedGitStatus.sessionPathMatches(
            sessionPath: "/Users/dev/project/src/App.swift",
            gitRelativePath: "src/App.swift"
        )
        #expect(result == true)
    }

    @Test func identicalRelativePathsMatch() {
        let result = SessionScopedGitStatus.sessionPathMatches(
            sessionPath: "src/App.swift",
            gitRelativePath: "src/App.swift"
        )
        #expect(result == true)
    }

    @Test func nonMatchingPathsDoNotMatch() {
        let result = SessionScopedGitStatus.sessionPathMatches(
            sessionPath: "/Users/dev/project/src/Other.swift",
            gitRelativePath: "src/App.swift"
        )
        #expect(result == false)
    }

    @Test func partialDirectoryOverlapDoesNotFalseMatch() {
        // "notasrc/foo.swift" should NOT match "src/foo.swift"
        let result = SessionScopedGitStatus.sessionPathMatches(
            sessionPath: "/Users/dev/project/notasrc/foo.swift",
            gitRelativePath: "src/foo.swift"
        )
        #expect(result == false)
    }

    @Test func rootLevelFileMatchesWithAbsolutePath() {
        let result = SessionScopedGitStatus.sessionPathMatches(
            sessionPath: "/Users/dev/project/README.md",
            gitRelativePath: "README.md"
        )
        #expect(result == true)
    }

    @Test func backslashesInSessionPathNormalized() {
        let result = SessionScopedGitStatus.sessionPathMatches(
            sessionPath: "src\\Views\\App.swift",
            gitRelativePath: "src/Views/App.swift"
        )
        #expect(result == true)
    }

    @Test func backslashesInGitPathNormalized() {
        let result = SessionScopedGitStatus.sessionPathMatches(
            sessionPath: "/Users/dev/project/src/App.swift",
            gitRelativePath: "src\\App.swift"
        )
        #expect(result == true)
    }

    // MARK: - Basic filtering

    @Test func filtersToSessionTouchedFilesOnly() {
        let gitStatus = makeGitStatus(files: [
            makeFile("src/App.swift", added: 10, removed: 5),
            makeFile("src/Utils.swift", added: 20, removed: 3),
            makeFile("README.md", added: 2, removed: 0),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: ["/workspace/project/src/App.swift"]
        )

        #expect(scoped.sessionFiles.count == 1)
        #expect(scoped.sessionFiles[0].path == "src/App.swift")
    }

    @Test func multipleSessionFilesFiltered() {
        let gitStatus = makeGitStatus(files: [
            makeFile("src/App.swift", added: 10, removed: 5),
            makeFile("src/Utils.swift", added: 20, removed: 3),
            makeFile("README.md", added: 2, removed: 0),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: [
                "/workspace/project/src/App.swift",
                "/workspace/project/README.md",
            ]
        )

        #expect(scoped.sessionFiles.count == 2)
        #expect(scoped.sessionFiles.map(\.path) == ["src/App.swift", "README.md"])
    }

    @Test func preservesOriginalFileOrder() {
        let gitStatus = makeGitStatus(files: [
            makeFile("c.swift", added: 1, removed: 0),
            makeFile("a.swift", added: 1, removed: 0),
            makeFile("b.swift", added: 1, removed: 0),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: ["/project/b.swift", "/project/a.swift", "/project/c.swift"]
        )

        // Should follow git status order, not session changedFiles order
        #expect(scoped.sessionFiles.map(\.path) == ["c.swift", "a.swift", "b.swift"])
    }

    // MARK: - Summary stats

    @Test func recalculatesAddedAndRemovedLines() {
        let gitStatus = makeGitStatus(files: [
            makeFile("src/App.swift", added: 10, removed: 5),
            makeFile("src/Utils.swift", added: 20, removed: 3),
            makeFile("README.md", added: 2, removed: 0),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: ["/workspace/project/src/App.swift"]
        )

        #expect(scoped.sessionAddedLines == 10)
        #expect(scoped.sessionRemovedLines == 5)
    }

    @Test func sumsLinesAcrossMultipleSessionFiles() {
        let gitStatus = makeGitStatus(files: [
            makeFile("a.swift", added: 10, removed: 5),
            makeFile("b.swift", added: 20, removed: 3),
            makeFile("c.swift", added: 100, removed: 50),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: ["/project/a.swift", "/project/b.swift"]
        )

        #expect(scoped.sessionAddedLines == 30)
        #expect(scoped.sessionRemovedLines == 8)
    }

    @Test func filesWithNilLineStatsContributeZero() {
        let gitStatus = makeGitStatus(files: [
            GitFileStatus(status: "??", path: "binary.png", addedLines: nil, removedLines: nil),
            makeFile("src/App.swift", added: 5, removed: 2),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: ["/project/binary.png", "/project/src/App.swift"]
        )

        #expect(scoped.sessionFiles.count == 2)
        #expect(scoped.sessionAddedLines == 5)
        #expect(scoped.sessionRemovedLines == 2)
    }

    @Test func totalFileCountReflectsFullGitStatus() {
        let gitStatus = makeGitStatus(files: [
            makeFile("a.swift", added: 1, removed: 0),
            makeFile("b.swift", added: 1, removed: 0),
            makeFile("c.swift", added: 1, removed: 0),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: ["/project/a.swift"]
        )

        #expect(scoped.sessionFileCount == 1)
        #expect(scoped.totalFileCount == 3)
    }

    // MARK: - Edge cases

    @Test func emptySessionChangedFilesProducesEmptyResult() {
        let gitStatus = makeGitStatus(files: [
            makeFile("src/App.swift", added: 10, removed: 5),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: []
        )

        #expect(scoped.sessionFiles.isEmpty)
        #expect(scoped.sessionFileCount == 0)
        #expect(scoped.sessionAddedLines == 0)
        #expect(scoped.sessionRemovedLines == 0)
    }

    @Test func sessionFilesNotInGitStatusAreIgnored() {
        let gitStatus = makeGitStatus(files: [
            makeFile("src/App.swift", added: 10, removed: 5),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: [
                "/project/src/App.swift",
                "/project/src/AlreadyCommitted.swift",
            ]
        )

        // Only the file still in git status shows up
        #expect(scoped.sessionFiles.count == 1)
        #expect(scoped.sessionFiles[0].path == "src/App.swift")
    }

    @Test func allFilesMatchedWhenSessionTouchedEverything() {
        let gitStatus = makeGitStatus(files: [
            makeFile("a.swift", added: 1, removed: 0),
            makeFile("b.swift", added: 2, removed: 1),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: ["/project/a.swift", "/project/b.swift"]
        )

        #expect(scoped.sessionFileCount == 2)
        #expect(scoped.totalFileCount == 2)
        #expect(scoped.sessionAddedLines == 3)
        #expect(scoped.sessionRemovedLines == 1)
    }

    @Test func emptyGitStatusFilesProducesEmptyResult() {
        let gitStatus = makeGitStatus(files: [])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: ["/project/src/App.swift"]
        )

        #expect(scoped.sessionFiles.isEmpty)
        #expect(scoped.sessionFileCount == 0)
    }

    @Test func duplicateSessionPathsDoNotDoubleCound() {
        let gitStatus = makeGitStatus(files: [
            makeFile("src/App.swift", added: 10, removed: 5),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: [
                "/project/src/App.swift",
                "/project/src/App.swift",
            ]
        )

        #expect(scoped.sessionFiles.count == 1)
        #expect(scoped.sessionAddedLines == 10)
    }

    @Test func deeplyNestedPathsMatchCorrectly() {
        let gitStatus = makeGitStatus(files: [
            makeFile("ios/Oppi/Core/Views/Chat/Support/WorkspaceContextBar.swift", added: 30, removed: 10),
        ])

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: [
                "/Users/chenda/workspace/oppi/ios/Oppi/Core/Views/Chat/Support/WorkspaceContextBar.swift"
            ]
        )

        #expect(scoped.sessionFiles.count == 1)
    }

    @Test func originalGitStatusPassedThrough() {
        let gitStatus = makeGitStatus(
            branch: "feature/scoping",
            files: [
                makeFile("a.swift", added: 1, removed: 0),
            ]
        )

        let scoped = SessionScopedGitStatus.filter(
            gitStatus: gitStatus,
            sessionChangedFiles: []
        )

        #expect(scoped.gitStatus.branch == "feature/scoping")
        #expect(scoped.gitStatus.isGitRepo == true)
    }

    // MARK: - Helpers

    private func makeGitStatus(
        branch: String = "main",
        files: [GitFileStatus]
    ) -> GitStatus {
        let totalAdded = files.compactMap(\.addedLines).reduce(0, +)
        let totalRemoved = files.compactMap(\.removedLines).reduce(0, +)
        return GitStatus(
            isGitRepo: true,
            branch: branch,
            headSha: "abc1234",
            ahead: 0,
            behind: 0,
            dirtyCount: files.count,
            untrackedCount: 0,
            stagedCount: 0,
            files: files,
            totalFiles: files.count,
            addedLines: totalAdded,
            removedLines: totalRemoved,
            stashCount: 0,
            lastCommitMessage: "test commit",
            lastCommitDate: nil,
            recentCommits: []
        )
    }

    private func makeFile(_ path: String, added: Int, removed: Int) -> GitFileStatus {
        GitFileStatus(status: " M", path: path, addedLines: added, removedLines: removed)
    }
}
