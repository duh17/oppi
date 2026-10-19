import Foundation

/// Initial workspace/worktree for Quick Session, including inbox preselection.
/// iOS orchestration: depends on `QuickSessionLaunchContext` and
/// `AppPreferences.QuickSession`. Neutral routing stays in OppiCore.
enum QuickSessionLaunchSelection {
    struct Candidate: Equatable, Sendable {
        var serverId: String
        var workspaceId: String
        var name: String
    }

    struct WorkspacePick: Equatable, Sendable {
        var serverId: String
        var workspaceId: String
        var source: String
        var worktreeId: String?
    }

    static func initialWorkspace(
        launchContext: QuickSessionLaunchContext?,
        workspaces: [Candidate],
        preferred: AppPreferences.QuickSession.PreferredWorkspaceSelection?
    ) -> WorkspacePick? {
        if let launchContext {
            let onServer = workspaces.filter { $0.serverId == launchContext.serverId }
            if let workspaceId = launchContext.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceId.isEmpty {
                let match = onServer.first(where: { $0.workspaceId == workspaceId })
                    ?? workspaces.first(where: { $0.workspaceId == workspaceId })
                if let match {
                    return WorkspacePick(
                        serverId: match.serverId,
                        workspaceId: match.workspaceId,
                        source: "inbox_workspace",
                        worktreeId: launchContext.worktreeId
                    )
                }
            }

            let pool = onServer.isEmpty ? workspaces : onServer
            return pickPreferred(in: pool, preferred: preferred)
        }

        return pickPreferred(in: workspaces, preferred: preferred)
    }

    /// Whether `pick` is what the start asked for, so a session may start without the user
    /// seeing the choice: the named workspace, or, when none was named, the remembered
    /// (last-used or default) workspace on the requested server. A first-available fallback
    /// counts only as the only workspace on a requested server; with no server requested,
    /// the remembered workspace may sit on a server that has not loaded yet.
    static func isRequestedTarget(
        _ pick: WorkspacePick?,
        launchContext: QuickSessionLaunchContext?,
        workspaces: [Candidate]
    ) -> Bool {
        guard let pick else { return false }
        if let launchContext {
            guard pick.serverId == launchContext.serverId else { return false }
            if let workspaceId = launchContext.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceId.isEmpty {
                return pick.workspaceId == workspaceId
            }
        }
        if pick.source == "first_available" {
            return launchContext != nil && workspaces.filter { $0.serverId == pick.serverId }.count == 1
        }
        return true
    }

    private static func pickPreferred(
        in workspaces: [Candidate],
        preferred: AppPreferences.QuickSession.PreferredWorkspaceSelection?
    ) -> WorkspacePick? {
        let resolved = preferred ?? AppPreferences.QuickSession.preferredWorkspaceSelection(
            in: workspaces.map { (id: $0.workspaceId, name: $0.name) }
        )
        if let resolved,
           let match = workspaces.first(where: { $0.workspaceId == resolved.id }) {
            return WorkspacePick(
                serverId: match.serverId,
                workspaceId: match.workspaceId,
                source: resolved.source,
                worktreeId: nil
            )
        }
        guard let first = workspaces.first else { return nil }
        return WorkspacePick(
            serverId: first.serverId,
            workspaceId: first.workspaceId,
            source: "first_available",
            worktreeId: nil
        )
    }
}
