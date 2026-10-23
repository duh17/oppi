import Foundation

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
}
