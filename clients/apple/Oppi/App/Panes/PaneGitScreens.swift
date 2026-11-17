import UIKit

/// The screens of a `git` and a `commit` route (an `oppi://git` link, a pin):
/// a workspace's Git panel (its branch, changes, and commit graph, as
/// Workspace Detail's Git button shows it) and one commit's detail. A pane
/// shows them as its root; a compact window pushes them.
@MainActor
enum PaneGitScreens {
    /// The screen for `entry`, or nil for another route or a server this
    /// device has no connection for. `close` closes the pane or pops the
    /// pushed screen.
    static func screen(
        for entry: PaneStackEntry,
        root: AppRootEnvironment,
        inPane: Bool,
        close: @escaping () -> Void
    ) -> UIViewController? {
        guard let connection = PaneEntries.connection(entry.serverId, root.coordinator) else { return nil }
        switch entry.route {
        case .git(let workspaceId, let worktreeId):
            return git(workspaceId: workspaceId, worktreeId: worktreeId, serverId: entry.serverId, connection: connection, root: root, close: close)
        case .commit(let workspaceId, let sha):
            let commit = CommitDetailViewController(
                configuration: .init(workspaceId: workspaceId, sha: sha, closeAccessibilityIdentifier: "git.commit.close"),
                connection: connection,
                apiClient: connection.apiClient,
                navigation: root.navigation,
                hostedInPanel: inPane
            )
            // Pushed, the stack's Back closes it.
            if inPane { commit.onClose = close }
            return commit
        default:
            return nil
        }
    }

    /// The workspace's Git panel, reading the connection's Git status live
    /// for that checkout (the main one when `worktreeId` is nil).
    private static func git(
        workspaceId: String,
        worktreeId: String?,
        serverId: String,
        connection: ServerConnection,
        root: AppRootEnvironment,
        close: @escaping () -> Void
    ) -> GitPanelViewController {
        let store = connection.gitStatusStore
        if let api = connection.apiClient {
            let workspace = connection.workspaceStore.workspaces.first { $0.id == workspaceId }
            store.loadInitial(
                workspaceId: workspaceId,
                worktreeId: worktreeId,
                apiClient: api,
                gitStatusEnabled: workspace?.gitStatusEnabled ?? true
            )
        }
        let panel = GitPanelViewController(
            context: {
                WorkspaceContextBarView.Context(
                    gitStatus: store.status(workspaceId: workspaceId, worktreeId: worktreeId),
                    isLoading: store.isAwaitingStatus(workspaceId: workspaceId, worktreeId: worktreeId),
                    workspaceId: workspaceId,
                    worktreeId: worktreeId,
                    serverId: serverId
                )
            },
            options: .init(),
            connection: connection,
            apiClient: connection.apiClient,
            navigation: root.navigation,
            onClose: close
        )
        panel.view.accessibilityIdentifier = "git.pane"
        return panel
    }
}
