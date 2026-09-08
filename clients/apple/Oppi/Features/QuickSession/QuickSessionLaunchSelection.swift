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
