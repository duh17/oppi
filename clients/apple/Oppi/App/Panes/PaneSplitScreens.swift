import UIKit

/// The screens a side leaf shows that have no link of their own (`PaneRoute.local`),
/// so a relaunch does not bring them back: the launcher a fresh split opens, a
/// folder terminal, the Rex list, a web page still waiting for its address (it
/// becomes a `.browser` entry once it loads one), and the server's game projects
/// (a pick becomes a `.godot` entry). The token carries the workspace each
/// one works in.
enum PaneLocalScreen: Equatable {
    /// Sessions, Files, Terminal and Web Page as large choices.
    case launcher(workspaceId: String?)
    /// The folder terminal for a workspace's root.
    case terminal(workspaceId: String)
    /// The Rex screen (`RexListViewController`): a tapped session's terminal
    /// opens inside the pane.
    case rex
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
        case ("rex", 1): self = .rex
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
        case .rex: PaneLocalToken(raw: "rex")
        case .browser: PaneLocalToken(raw: "browser")
        case .godot: PaneLocalToken(raw: "godot")
        }
    }

    var workspaceId: String? {
        switch self {
        case .launcher(let workspaceId): workspaceId
        case .terminal(let workspaceId): workspaceId
        case .rex, .browser, .godot: nil
        }
    }
}

/// Builds a side leaf's bottom screen from its route's `.entry`: a launcher, a
/// browser, a terminal, Rex, a game or its project list, a workspace's Git, a
/// session list, a linked screen, or an entry's leaf state until its content
/// can open.
@MainActor
enum PaneSplitScreens {
    /// What a side leaf's own screens report back into its route.
    struct Actions {
        /// The leaf shows another entry in place of all it shows (a launcher's
        /// choice, a game project picked).
        var show: (PaneStackEntry) -> Void
        /// The entry's content can open: its screen takes that entry's place,
        /// and the pages over and under it stay.
        var replaceRoot: (PaneStackEntry, WorkspaceStackRouteElement) -> Void
        /// Close Pane on `entry`: a page over the leaf's root pops, a root
        /// closes the pane.
        var close: (PaneStackEntry) -> Void
        /// The leaf's screen moved on to `entry` by itself (a browser followed
        /// a link): the route records it and the screen stays.
        var follow: (PaneStackEntry) -> Void
        /// The leaf came back with a relaunch and mounts for the first time, so
        /// a web page waits for a tap before it loads.
        var restored: () -> Bool
    }

    static func make(_ entry: PaneStackEntry, root: AppRootEnvironment?, actions: Actions) -> UIViewController {
        if case .browser(let url) = entry.route {
            return browser(url, serverId: entry.serverId, paused: actions.restored(), root: root, actions: actions)
        }
        if case .godot(let project) = entry.route {
            // States its own server and project; a restored game waits for Play.
            return GodotPaneViewController(
                serverId: entry.serverId, project: project, restored: actions.restored(), root: root
            )
        }
        if case .local(let token) = entry.route, let screen = PaneLocalScreen(token) {
            switch screen {
            case .launcher(let workspaceId):
                return PaneLauncherViewController(serverId: entry.serverId, workspaceId: workspaceId, root: root, choose: actions.show)
            case .terminal(let workspaceId):
                return terminal(serverId: entry.serverId, workspaceId: workspaceId, root: root)
            case .rex:
                return rex(root: root)
            case .browser:
                return browser(nil, serverId: entry.serverId, paused: false, root: root, actions: actions)
            case .godot:
                return GodotProjectListViewController(serverId: entry.serverId, root: root, choose: actions.show)
            }
        }
        guard let root else { return PaneLauncherViewController(serverId: entry.serverId, workspaceId: nil, root: nil, choose: actions.show) }
        if let git = PaneGitScreens.screen(for: entry, root: root, inPane: true, close: { actions.close(entry) }) {
            return git
        }
        if case .sessions(nil) = entry.route {
            return SessionInboxViewController(root: root)
        }
        if let element = PaneEntries.element(for: entry, coordinator: root.coordinator) {
            return ShellRouteScreens.make(element, root: root)
        }
        let state = PaneLeafStateViewController(entry: entry, root: root)
        state.onOpen = { element in actions.replaceRoot(entry, element) }
        state.onClose = { actions.close(entry) }
        return state
    }

    /// `entry` as a page pushed onto a pane's own stack (a place a panel pane's
    /// tile opens): the screen a split leaf would show for it, with Back to the
    /// screen under it. Its leaf state hands the page's place to the content
    /// once it can open, and its Close Pane pops it.
    static func page(_ entry: PaneStackEntry, root: AppRootEnvironment) -> UIViewController {
        weak var page: UIViewController?
        let replace: (UIViewController) -> Void = { screen in
            guard let page, let navigation = page.navigationController,
                  let index = navigation.viewControllers.firstIndex(of: page) else { return }
            var screens = navigation.viewControllers
            screens[index] = screen
            navigation.setViewControllers(screens, animated: false)
        }
        let actions = Actions(
            show: { replace(Self.page($0, root: root)) },
            replaceRoot: { _, element in replace(ShellRouteScreens.make(element, root: root)) },
            close: { _ in if let page { Router.finish(page) } },
            follow: { _ in },
            restored: { false }
        )
        let screen = make(entry, root: root, actions: actions)
        page = screen
        return screen
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
        let list = SSHTerminalHostListViewController()
        if let root { list.traitOverrides.appRootEnvironment = root }
        return list
    }

    /// The Rex screen, as a pane or the sidebar's place: Rex reached over
    /// Tailscale with no SSH, then the saved hosts' Rex over SSH.
    static func rex(root: AppRootEnvironment?) -> UIViewController {
        #if DEBUG
        let list = _rexListForTesting?() ?? RexListViewController()
        #else
        let list = RexListViewController()
        #endif
        if let root { list.traitOverrides.appRootEnvironment = root }
        return list
    }

    #if DEBUG
    /// The debug harness's Rex list, over a stand-in Rex the simulator can reach.
    static var _rexListForTesting: (() -> RexListViewController)?
    #endif
}
