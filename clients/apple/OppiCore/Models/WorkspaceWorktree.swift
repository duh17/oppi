import Foundation

/// A git checkout available inside a workspace.
///
/// Sessions bind to a worktree at creation time. Older sessions without a
/// `worktreeId` use the implicit main checkout.
struct WorkspaceWorktree: Identifiable, Codable, Sendable, Equatable, Hashable {
    let id: String
    let name: String
    let path: String
    let branch: String?
    let headSha: String?
    let isMain: Bool
    let isGitRepo: Bool

    var displayName: String {
        if isMain { return "Main" }
        if let branch, !branch.isEmpty { return branch }
        return name
    }

    var subtitle: String {
        if let branch, let headSha, !branch.isEmpty, !headSha.isEmpty {
            return "\(branch) · \(headSha)"
        }
        if let branch, !branch.isEmpty { return branch }
        if let headSha, !headSha.isEmpty { return headSha }
        return path
    }
}

extension WorkspaceWorktree {
    static let mainId = "main"
}
