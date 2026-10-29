/// A file the Git panel lists: Git's change, or a file the session touched
/// that Git does not report (committed and clean, outside the repository,
/// or in a worktree that is gone). A Git file opens its diff; any other
/// opens the session's copy.
struct GitPanelFile: Sendable, Equatable {
    /// Git's path for a Git file; otherwise the path the session's tool
    /// calls used, which the session's file reader resolves.
    let path: String
    let gitFile: GitFileStatus?

    init(_ gitFile: GitFileStatus) {
        path = gitFile.path
        self.gitFile = gitFile
    }

    init(sessionPath: String) {
        path = sessionPath
        gitFile = nil
    }

    /// Select may pick it: Git reports it, so a quick action the server
    /// runs on it can read it. The server refuses any other path.
    var isSelectable: Bool { gitFile != nil }
}

/// The Git status scoped to the files a session touched.
///
/// The server tracks per-session changed files via `session.changeStats.changedFiles`
/// (absolute paths from edit/write tool calls). This struct cross-references those
/// against the workspace's git status (repo-relative paths): the touched files
/// Git reports carry its status and counts; the rest are listed without.
struct SessionScopedGitStatus: Sendable, Equatable {

    /// Every file the session touched: its Git files in Git's order, then
    /// the touched files Git does not report, in the session's order.
    let touchedFiles: [GitPanelFile]

    /// How many files the session touched: the listed ones, or the
    /// session's own count when its list is capped (`changeStats.filesChanged`),
    /// so a capped and a full list count the same.
    let touchedCount: Int

    /// Count of session-touched files present in the git status.
    let sessionFileCount: Int

    /// Sum of added lines across session-touched files only.
    let sessionAddedLines: Int

    /// Sum of removed lines across session-touched files only.
    let sessionRemovedLines: Int

    // MARK: - Filtering

    /// Build a session-scoped view by filtering git status to session-touched files.
    ///
    /// - Parameters:
    ///   - gitStatus: Full workspace git status with repo-relative paths.
    ///   - sessionChangedFiles: Absolute (or relative) file paths from `session.changeStats.changedFiles`.
    /// - Returns: A scoped status containing only files the session touched.
    static func filter(
        gitStatus: GitStatus,
        sessionChangedFiles: [String],
        reportedTouchedCount: Int = 0
    ) -> Self {
        guard !sessionChangedFiles.isEmpty else {
            return Self(
                touchedFiles: [],
                touchedCount: reportedTouchedCount,
                sessionFileCount: 0,
                sessionAddedLines: 0,
                sessionRemovedLines: 0
            )
        }

        // The context bar reads this on every render, and every session list
        // update re-renders it, so matching must not compare every git file
        // with every session file. Group git files by file name; a session
        // path only checks the git files that share its name.
        let gitPaths = gitStatus.files.map { normalized($0.path) }
        var gitIndicesByName: [Substring: [Int]] = [:]
        for (index, path) in gitPaths.enumerated() {
            gitIndicesByName[fileName(of: path), default: []].append(index)
        }
        var matched = Set<Int>()
        var outsideGit: [String] = []
        var seenOutsideGit = Set<String>()
        for sessionChangedFile in sessionChangedFiles {
            let sessionPath = normalized(sessionChangedFile)
            var found = false
            for index in gitIndicesByName[fileName(of: sessionPath)] ?? []
            where sessionPathMatches(sessionPath: sessionPath, gitRelativePath: gitPaths[index]) {
                matched.insert(index)
                found = true
            }
            if !found, seenOutsideGit.insert(sessionChangedFile).inserted {
                outsideGit.append(sessionChangedFile)
            }
        }
        let filtered = gitStatus.files.indices.filter(matched.contains).map { gitStatus.files[$0] }

        let addedLines = filtered.compactMap(\.addedLines).reduce(0, +)
        let removedLines = filtered.compactMap(\.removedLines).reduce(0, +)

        let touched = filtered.map(GitPanelFile.init) + outsideGit.map(GitPanelFile.init(sessionPath:))
        return Self(
            touchedFiles: touched,
            touchedCount: max(touched.count, reportedTouchedCount),
            sessionFileCount: filtered.count,
            sessionAddedLines: addedLines,
            sessionRemovedLines: removedLines
        )
    }

    // MARK: - Path matching

    /// A session-tracked path (typically absolute) matches a git-relative path
    /// when they are equal or the git path is a suffix that starts right after
    /// a separator, so `notasrc/foo.swift` does not match `src/foo.swift`.
    /// Both paths are already normalized. Paths compare as bytes, like git;
    /// UTF-8 views also skip the grapheme breaking that made `Character`
    /// scans the main cost of a render.
    private static func sessionPathMatches(sessionPath: Substring, gitRelativePath: Substring) -> Bool {
        let session = sessionPath.utf8
        let git = gitRelativePath.utf8
        guard session.count >= git.count else { return false }
        let start = session.index(session.endIndex, offsetBy: -git.count)
        guard session[start...].elementsEqual(git) else { return false }
        return start == session.startIndex || session[session.index(before: start)] == UInt8(ascii: "/")
    }

    private static func fileName(of path: Substring) -> Substring {
        guard let separator = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return path }
        return path[path.utf8.index(after: separator)...]
    }

    private static func normalized(_ path: String) -> Substring {
        path.utf8.contains(UInt8(ascii: "\\")) ? path.replacing("\\", with: "/")[...] : path[...]
    }
}
