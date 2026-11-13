import UIKit

/// The screens a split leaf shows that have no link (`PaneRoute.local`), so a
/// relaunch does not bring them back: the launcher a fresh split opens, and a
/// folder terminal. The token carries the workspace each one works in.
enum PaneLocalScreen: Equatable {
    /// Sessions, Files and Terminal as large choices.
    case launcher(workspaceId: String?)
    /// The folder terminal for a workspace's root.
    case terminal(workspaceId: String)

    init?(_ token: PaneLocalToken) {
        let parts = token.raw.split(separator: "/", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("launcher", 1): self = .launcher(workspaceId: nil)
        case ("launcher", 2): self = .launcher(workspaceId: parts[1])
        case ("terminal", 2): self = .terminal(workspaceId: parts[1])
        default: return nil
        }
    }

    var token: PaneLocalToken {
        switch self {
        case .launcher(let workspaceId?): PaneLocalToken(raw: "launcher/\(workspaceId)")
        case .launcher(nil): PaneLocalToken(raw: "launcher")
        case .terminal(let workspaceId): PaneLocalToken(raw: "terminal/\(workspaceId)")
        }
    }

    var workspaceId: String? {
        switch self {
        case .launcher(let workspaceId): workspaceId
        case .terminal(let workspaceId): workspaceId
        }
    }
}

/// Builds the root screen of a split leaf from its stack's top entry. A
/// linked entry opens as the shell would open it; one whose content is not
/// there yet shows its leaf state and opens in this leaf once it can.
@MainActor
enum PaneSplitScreens {
    struct Actions {
        /// The leaf shows another entry (a launcher choice).
        var show: (PaneStackEntry) -> Void
        /// The leaf's screen is ready in place of a leaf state.
        var replaceRoot: (UIViewController) -> Void
        var close: () -> Void
    }

    static func make(_ entry: PaneStackEntry, root: AppRootEnvironment?, actions: Actions) -> UIViewController {
        if case .local(let token) = entry.route, let screen = PaneLocalScreen(token) {
            switch screen {
            case .launcher(let workspaceId):
                return PaneLauncherViewController(serverId: entry.serverId, workspaceId: workspaceId, root: root, choose: actions.show)
            case .terminal(let workspaceId):
                return terminal(serverId: entry.serverId, workspaceId: workspaceId, root: root)
            }
        }
        guard let root else { return PaneLauncherViewController(serverId: entry.serverId, workspaceId: nil, root: nil, choose: actions.show) }
        if case .sessions(nil) = entry.route {
            return SessionInboxViewController(root: root, onOpenSidebar: nil, showsSidebarToggle: false)
        }
        if let element = PaneEntries.element(for: entry, coordinator: root.coordinator) {
            return screen(for: element, root: root)
        }
        let state = PaneLeafStateViewController(entry: entry, root: root)
        state.onOpen = { element in actions.replaceRoot(screen(for: element, root: root)) }
        state.onClose = actions.close
        return state
    }

    private static func screen(for element: WorkspaceStackRouteElement, root: AppRootEnvironment) -> UIViewController {
        ShellRouteScreens.make(ShellRoute(element), placement: .pushed, root: root, openSidebar: nil)
    }

    /// The workspace's folder terminal on the saved SSH host that serves its
    /// server, as the chat's Terminal button opens it; Add Host when no saved
    /// host serves it, and the host list when the workspace has no folder.
    private static func terminal(serverId: String, workspaceId: String, root: AppRootEnvironment?) -> UIViewController {
        if let root, let (workspace, host) = PaneEntries.workspace(workspaceId, serverId: serverId, coordinator: root.coordinator),
           let folder = SSHTerminalFolderTarget.workspace(workspace) {
            let target = SSHTerminalFolderTarget(serverHost: host, folder: folder, label: workspace.name)
            if target.isUsable {
                if let profile = SSHTerminalHostMatch.bestMatch(in: SSHTerminalProfileStore().load(), serverHost: host) {
                    return SSHTerminalFolderViewController(profile: profile, target: target)
                }
                return SSHTerminalSetupViewController(profileID: nil, host: host, folderTerminal: target)
            }
        }
        let list = SSHTerminalHostListViewController(showsSidebarToggle: false)
        if let root { list.traitOverrides.appRootEnvironment = root }
        return list
    }
}
