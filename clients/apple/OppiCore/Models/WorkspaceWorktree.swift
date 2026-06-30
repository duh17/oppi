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
    let sessionCount: Int?

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

enum WorkspaceWorktreeMenuFormatting {
    static func title(for worktree: WorkspaceWorktree) -> String {
        worktree.displayName
    }

    static func sessionCountText(for worktree: WorkspaceWorktree) -> String? {
        guard let count = worktree.sessionCount else { return nil }
        guard count >= 1_000 else { return "\(count)" }

        let roundedTenths = (count + 50) / 100
        let whole = roundedTenths / 10
        let fraction = roundedTenths % 10
        return fraction == 0 ? "\(whole)k" : "\(whole).\(fraction)k"
    }

    static func accessibilityLabel(for worktree: WorkspaceWorktree) -> String {
        let title = title(for: worktree)
        guard let count = worktree.sessionCount else { return title }
        let noun = count == 1 ? "session" : "sessions"
        return "\(title), \(count) \(noun)"
    }
}
