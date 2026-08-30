import Foundation

/// Identity for `WorkspaceShellDetail`'s session `.task(id:)` so changing the
/// worktree picker refetches that checkout. Omitting `worktreeId` on the
/// collection request is main-only, not all worktrees.
struct MacWorkspaceWorktreeSessionScope: Hashable, Sendable {
    let workspaceId: String
    let worktreeId: String
}

/// Mac workspace checkout switching. Parses `WorkspaceWorktree` from OppiCore
/// and filters the workspace session list the same way iOS does: bind new
/// sessions to the selected checkout, treat a missing session `worktreeId` as
/// main, and do not create git worktrees.
enum MacWorkspaceWorktreePresentation {
    static func sessionScope(
        workspaceId: String,
        selectedWorktreeId: String
    ) -> MacWorkspaceWorktreeSessionScope {
        MacWorkspaceWorktreeSessionScope(
            workspaceId: workspaceId,
            worktreeId: selectedWorktreeId
        )
    }

    static func visibleWorktrees(
        fetched: [WorkspaceWorktree],
        hostMount: String?
    ) -> [WorkspaceWorktree] {
        if fetched.isEmpty {
            return [
                WorkspaceWorktree(
                    id: WorkspaceWorktree.mainId,
                    name: "Main checkout",
                    path: hostMount ?? "",
                    branch: nil,
                    headSha: nil,
                    isMain: true,
                    isGitRepo: false,
                    sessionCount: nil
                ),
            ]
        }
        return fetched
    }

    static func canSwitch(visibleWorktrees: [WorkspaceWorktree], isLoading: Bool) -> Bool {
        !isLoading && visibleWorktrees.count > 1
    }

    static func resolvedSelectedId(_ current: String, in fetched: [WorkspaceWorktree]) -> String {
        if fetched.contains(where: { $0.id == current }) {
            return current
        }
        return fetched.first?.id ?? WorkspaceWorktree.mainId
    }

    static func matchesSession(worktreeId: String?, selectedId: String) -> Bool {
        (worktreeId ?? WorkspaceWorktree.mainId) == selectedId
    }

    static func filterSessions(
        _ sessions: [SessionSummary],
        selectedId: String
    ) -> [SessionSummary] {
        sessions.filter { matchesSession(worktreeId: $0.worktreeId, selectedId: selectedId) }
    }

    static func menuTitle(for worktree: WorkspaceWorktree) -> String {
        let title = WorkspaceWorktreeMenuFormatting.title(for: worktree)
        guard let sessionCount = WorkspaceWorktreeMenuFormatting.sessionCountText(for: worktree) else {
            return title
        }
        return "\(title) · \(sessionCount)"
    }
}
