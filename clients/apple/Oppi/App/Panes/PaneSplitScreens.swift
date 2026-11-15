import UIKit

/// The screens a split leaf shows that have no link (`PaneRoute.local`), so a
/// relaunch does not bring them back: the launcher a fresh split opens, a
/// folder terminal, a web page still waiting for its address (it becomes
/// a `.browser` entry once it loads one), and the server's game projects
/// (a pick becomes a `.godot` entry). The token carries the workspace each
/// one works in.
enum PaneLocalScreen: Equatable {
    /// Sessions, Files, Terminal and Web Page as large choices.
    case launcher(workspaceId: String?)
    /// The folder terminal for a workspace's root.
    case terminal(workspaceId: String)
    /// A browser with its address field up and no page yet.
    case browser
    /// The Godot projects the server discovered, to pick one to play.
    case godot

    init?(_ token: PaneLocalToken) {
        let parts = token.raw.split(separator: "/", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("launcher", 1): self = .launcher(workspaceId: nil)
        case ("launcher", 2): self = .launcher(workspaceId: parts[1])
        case ("terminal", 2): self = .terminal(workspaceId: parts[1])
        case ("browser", 1): self = .browser
        case ("godot", 1): self = .godot
        default: return nil
        }
    }

    var token: PaneLocalToken {
        switch self {
        case .launcher(let workspaceId?): PaneLocalToken(raw: "launcher/\(workspaceId)")
        case .launcher(nil): PaneLocalToken(raw: "launcher")
        case .terminal(let workspaceId): PaneLocalToken(raw: "terminal/\(workspaceId)")
        case .browser: PaneLocalToken(raw: "browser")
        case .godot: PaneLocalToken(raw: "godot")
        }
    }

    var workspaceId: String? {
        switch self {
        case .launcher(let workspaceId): workspaceId
        case .terminal(let workspaceId): workspaceId
        case .browser, .godot: nil
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
        /// The leaf's screen moved on to `entry` by itself (a browser
        /// followed a link): the tree records it, the screen stays.
        var follow: (PaneStackEntry) -> Void = { _ in }
    }

    /// `restored`: the leaf came back with a relaunch and mounts for the
    /// first time, so a web page waits for a tap before it loads.
    static func make(_ entry: PaneStackEntry, root: AppRootEnvironment?, restored: Bool = false, actions: Actions) -> UIViewController {
        if case .browser(let url) = entry.route {
            return browser(url, serverId: entry.serverId, paused: restored, root: root, actions: actions)
        }
        if case .godot(let project) = entry.route {
            // States its own server and project; a restored game waits for Play.
            return GodotPaneViewController(serverId: entry.serverId, project: project, restored: restored, root: root)
        }
        if case .local(let token) = entry.route, let screen = PaneLocalScreen(token) {
            switch screen {
            case .launcher(let workspaceId):
                return PaneLauncherViewController(serverId: entry.serverId, workspaceId: workspaceId, root: root, choose: actions.show)
            case .terminal(let workspaceId):
                return terminal(serverId: entry.serverId, workspaceId: workspaceId, root: root)
            case .browser:
                return browser(nil, serverId: entry.serverId, paused: false, root: root, actions: actions)
            case .godot:
                return GodotProjectListViewController(serverId: entry.serverId, root: root, choose: actions.show)
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

    /// A web page needs no server: it shows whatever its server's state. The
    /// page it moves to, by a link or a typed address, becomes the leaf's
    /// entry without rebuilding it.
    private static func browser(
        _ url: URL?, serverId: String, paused: Bool, root: AppRootEnvironment?, actions: Actions
    ) -> BrowserPaneViewController {
        let browser = BrowserPaneViewController(url: url, paused: paused, root: root)
        browser.onNavigate = { url in actions.follow(PaneStackEntry(serverId: serverId, route: .browser(url))) }
        return browser
    }

    /// The screen the shell would show for `element`, as a leaf's root.
    static func screen(for element: WorkspaceStackRouteElement, root: AppRootEnvironment) -> UIViewController {
        ShellRouteScreens.make(ShellRoute(element), placement: .pushed, root: root, openSidebar: nil)
    }

    /// The workspace's folder terminal on the saved SSH host that serves its
    /// server, as the chat's Terminal button opens it; Add Host when no saved
    /// host serves it, and the host list when the workspace has no folder.
    private static func terminal(serverId: String, workspaceId: String, root: AppRootEnvironment?) -> UIViewController {
        if let root, let (workspace, host) = PaneEntries.workspace(workspaceId, serverId: serverId, coordinator: root.coordinator),
           let folder = SSHTerminalFolderTarget.workspace(workspace) {
            let target = SSHTerminalFolderTarget(
                serverHost: host, folder: folder, label: workspace.name,
                serverOffers: .offered(by: serverId, coordinator: root.coordinator)
            )
            if let screen = SSHTerminalFolderEntry.screen(for: target) { return screen }
        }
        let list = SSHTerminalHostListViewController(showsSidebarToggle: false)
        if let root { list.traitOverrides.appRootEnvironment = root }
        return list
    }
}
