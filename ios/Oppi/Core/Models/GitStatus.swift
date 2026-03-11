import Foundation

/// Git repository status for a workspace directory.
///
/// Mirrors the server's `GitStatus` type from `git-status.ts`.
/// Polled periodically to show branch, dirty files, and commit info.
struct GitStatus: Codable, Sendable, Equatable {
    /// Whether the directory is a git repo
    var isGitRepo: Bool

    /// Current branch name (nil if detached HEAD)
    var branch: String?

    /// Short SHA of HEAD
    var headSha: String?

    /// Commits ahead of upstream (nil if no upstream)
    var ahead: Int?

    /// Commits behind upstream (nil if no upstream)
    var behind: Int?

    /// Number of dirty (working tree modified) files
    var dirtyCount: Int

    /// Number of untracked files
    var untrackedCount: Int

    /// Number of staged files
    var stagedCount: Int

    /// Individual file statuses (capped at 500 by server)
    var files: [GitFileStatus]

    /// Total count of all non-clean files
    var totalFiles: Int

    /// Total lines added vs HEAD (tracked files only)
    var addedLines: Int

    /// Total lines removed vs HEAD (tracked files only)
    var removedLines: Int

    /// Number of stash entries
    var stashCount: Int

    /// Most recent commit subject line
    var lastCommitMessage: String?

    /// ISO timestamp of most recent commit
    var lastCommitDate: String?

    /// Recent commits (newest first, capped at 5 by server)
    var recentCommits: [GitCommitSummary]

    /// Total uncommitted files (dirty + untracked + staged).
    var uncommittedCount: Int {
        totalFiles
    }

    /// True when the working tree has no uncommitted changes.
    var isClean: Bool {
        totalFiles == 0
    }

    // periphery:ignore - API surface for empty/default git state
    static let empty = Self(
        isGitRepo: false,
        branch: nil,
        headSha: nil,
        ahead: nil,
        behind: nil,
        dirtyCount: 0,
        untrackedCount: 0,
        stagedCount: 0,
        files: [],
        totalFiles: 0,
        addedLines: 0,
        removedLines: 0,
        stashCount: 0,
        lastCommitMessage: nil,
        lastCommitDate: nil,
        recentCommits: []
    )
}

/// Summary of a single git commit, included in `GitStatus.recentCommits`.
struct GitCommitSummary: Codable, Sendable, Equatable, Identifiable {
    /// Short SHA (7-char)
    var sha: String

    /// Commit subject line
    var message: String

    /// ISO timestamp
    var date: String

    var id: String { sha }
}

/// Individual file status from `git status --porcelain`.
struct GitFileStatus: Codable, Sendable, Equatable, Identifiable {
    /// Two-char status code (e.g. " M", "??", "A ")
    var status: String

    /// File path relative to repo root
    var path: String

    /// Lines added vs HEAD (nil for binary/untracked)
    var addedLines: Int?

    /// Lines removed vs HEAD (nil for binary/untracked)
    var removedLines: Int?

    var id: String { path }

    /// Convert to a `WorkspaceReviewFile` for use with the review detail view.
    /// Derives staged/unstaged/untracked from the two-char porcelain status code.
    func toReviewFile() -> WorkspaceReviewFile {
        let trimmed = status.trimmingCharacters(in: .whitespaces)
        let indexChar = status.first ?? " "
        let workChar = status.dropFirst().first ?? " "

        return WorkspaceReviewFile(
            path: path,
            status: trimmed,
            addedLines: addedLines,
            removedLines: removedLines,
            isStaged: indexChar != " " && indexChar != "?",
            isUnstaged: workChar != " " && trimmed != "??",
            isUntracked: trimmed == "??",
            selectedSessionTouched: false
        )
    }

    // periphery:ignore - API surface for git status display UI
    /// Human-readable status label.
    var label: String {
        switch status.trimmingCharacters(in: .whitespaces) {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "??": return "Untracked"
        case "!!": return "Ignored"
        case "UU", "AA", "DD": return "Conflict"
        default: return "Changed"
        }
    }
}
