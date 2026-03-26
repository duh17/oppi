import Foundation

/// Response from GET /workspaces/:id/git/commits (paginated)
struct GitCommitLogResponse: Codable, Sendable {
    let commits: [GitCommitSummary]
    let total: Int
    let hasMore: Bool
}

/// Detailed view of a single commit with changed files.
struct GitCommitDetail: Codable, Sendable, Equatable {
    let sha: String
    let message: String
    let date: String
    let author: String
    let files: [GitCommitFileInfo]
    let addedLines: Int
    let removedLines: Int
}

/// A file changed in a specific commit.
struct GitCommitFileInfo: Codable, Sendable, Equatable, Identifiable {
    let path: String
    let status: String
    let addedLines: Int?
    let removedLines: Int?

    var id: String { path }

    /// Convert to WorkspaceReviewFile for reuse with existing review components.
    func toReviewFile() -> WorkspaceReviewFile {
        WorkspaceReviewFile(
            path: path,
            status: status,
            addedLines: addedLines,
            removedLines: removedLines,
            isStaged: false,
            isUnstaged: false,
            isUntracked: status == "A",
            selectedSessionTouched: false
        )
    }
}
