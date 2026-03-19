/// Filtered view of `GitStatus` scoped to files touched by a specific session.
///
/// The server tracks per-session changed files via `session.changeStats.changedFiles`
/// (absolute paths from edit/write tool calls). This struct cross-references those
/// against the workspace's git status (repo-relative paths) to produce a subset
/// showing only what the current session modified.
struct SessionScopedGitStatus: Sendable, Equatable {

    /// The original unfiltered git status.
    let gitStatus: GitStatus

    /// Files from `gitStatus.files` that were touched by the session.
    let sessionFiles: [GitFileStatus]

    /// Count of session-touched files present in the git status.
    let sessionFileCount: Int

    /// Sum of added lines across session-touched files only.
    let sessionAddedLines: Int

    /// Sum of removed lines across session-touched files only.
    let sessionRemovedLines: Int

    /// Total changed file count from the full git status (for "X of Y" display).
    let totalFileCount: Int

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
                gitStatus: gitStatus,
                sessionFiles: [],
                sessionFileCount: 0,
                sessionAddedLines: 0,
                sessionRemovedLines: 0,
                totalFileCount: gitStatus.totalFiles
            )
        }

        // Normalize session paths once for O(n*m) matching below
        let normalizedSessionPaths = Set(sessionChangedFiles.map { $0.replacing("\\", with: "/") })

        let filtered = gitStatus.files.filter { file in
            normalizedSessionPaths.contains { sessionPath in
                sessionPathMatches(sessionPath: sessionPath, gitRelativePath: file.path)
            }
        }

        let addedLines = filtered.compactMap(\.addedLines).reduce(0, +)
        let removedLines = filtered.compactMap(\.removedLines).reduce(0, +)

        return Self(
            gitStatus: gitStatus,
            sessionFiles: filtered,
            sessionFileCount: filtered.count,
            sessionAddedLines: addedLines,
            sessionRemovedLines: removedLines,
            totalFileCount: gitStatus.totalFiles
        )
    }

    // MARK: - Path matching

    /// Check whether a session-tracked path (typically absolute) matches a git-relative path.
    ///
    /// Handles two cases:
    /// - Exact match (both relative)
    /// - Suffix match with path separator (session path is absolute, git path is relative)
    static func sessionPathMatches(sessionPath: String, gitRelativePath: String) -> Bool {
        let normalizedSession = sessionPath.replacing("\\", with: "/")
        let normalizedGit = gitRelativePath.replacing("\\", with: "/")

        if normalizedSession == normalizedGit { return true }
        if normalizedSession.hasSuffix("/\(normalizedGit)") { return true }
        return false
    }
}
