/// Filtered view of `GitStatus` scoped to files touched by a specific session.
///
/// The server tracks per-session changed files via `session.changeStats.changedFiles`
/// (absolute paths from edit/write tool calls). This struct cross-references those
/// against the workspace's git status (repo-relative paths) to produce a subset
/// showing only what the current session modified.
struct SessionScopedGitStatus: Sendable, Equatable {

    /// Files from `gitStatus.files` that were touched by the session.
    let sessionFiles: [GitFileStatus]

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
        sessionChangedFiles: [String]
    ) -> Self {
        guard !sessionChangedFiles.isEmpty else {
            return Self(
                sessionFiles: [],
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
        for sessionChangedFile in sessionChangedFiles {
            let sessionPath = normalized(sessionChangedFile)
            for index in gitIndicesByName[fileName(of: sessionPath)] ?? []
            where sessionPathMatches(sessionPath: sessionPath, gitRelativePath: gitPaths[index]) {
                matched.insert(index)
            }
        }
        let filtered = gitStatus.files.indices.filter(matched.contains).map { gitStatus.files[$0] }

        let addedLines = filtered.compactMap(\.addedLines).reduce(0, +)
        let removedLines = filtered.compactMap(\.removedLines).reduce(0, +)

        return Self(
            sessionFiles: filtered,
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
