import UIKit

// The shell's route screens. UIKit owns the stacks (`ShellRouter.swift`,
// `WorkspaceShellController.swift`); every route is a UIKit screen, built here.

/// The shell's UIKit screens: one per route, plus the covers and placeholders
/// the shell shows in their place.
@MainActor
enum ShellRouteScreens {
    static func make(_ route: ShellRoute, root: AppRootEnvironment) -> UIViewController {
        switch route {
        case .inbox:
            return SessionInboxViewController(root: root)
        case .sidebar:
            return WorkspaceSidebarViewController(root: root)
        case .workspace(let target):
            return WorkspaceDetailViewController(root: root, target: target)
        case .session(let target):
            return ChatRouteViewController(target: target, root: root)
        case .fileBrowser(let target):
            return FileBrowserViewController(root: root, target: target)
        case .linkedFile(let target):
            return WorkspaceLinkedFileViewController(target: target, root: root)
        case .chatReader(let target):
            return ChatReaderViewController(target: target, root: root)
        case .workspaceConfiguration(let target):
            return WorkspaceSettingsViewController(serverId: target.serverId, workspace: target.workspace, root: root)
        case .utility(let target):
            return utilityScreen(target, root: root)
        case .serverDetails(let target):
            return ServerSettingsRouteViewController(target: target, root: root)
        case .modelProviders(let target):
            // Keyed by the route, not the visible host: a host-pill switch
            // reloads in place and keeps a live provider sign-in.
            return ModelProvidersViewController(target: target, root: root)
        case .serverResourceDetail(let target):
            return ServerExtensionDetailViewController(target: target, root: root)
        case .paneEntry(let entry):
            // A game states its own server and project (a Godot link on a
            // compact window, or with no room for a pane beside).
            if case .godot(let project) = entry.route {
                return GodotPaneViewController(serverId: entry.serverId, project: project, restored: false, root: root)
            }
            // A workspace's Git or a commit, pushed (a link on a compact window,
            // or with no room for a pane beside); its close pops it.
            weak var pushed: UIViewController?
            if let git = PaneGitScreens.screen(for: entry, root: root, inPane: false, close: { if let pushed { Router.finish(pushed) } }) {
                pushed = git
                return git
            }
            return PaneLeafStateViewController(entry: entry, root: root)
        case .terminal(let target):
            let screen = target.screen
            if screen.traitOverrides.appRootEnvironment == nil {
                screen.traitOverrides.appRootEnvironment = root
            }
            return screen
        }
    }

    private static func utilityScreen(_ target: WorkspaceUtilityNavTarget, root: AppRootEnvironment) -> UIViewController {
        switch target {
        case .pinned:
            return PinnedViewController(root: root)
        case .sshTerminal:
            let screen = SSHTerminalHostListViewController()
            screen.traitOverrides.appRootEnvironment = root
            return screen
        case .rex:
            return PaneSplitScreens.rex(root: root)
        case .schedules:
            return SchedulesViewController(root: root)
        case .agents:
            return AgentListViewController(root: root)
        case .pluginScreen(let entry):
            let title = root.windowConnection?.serverCapabilities?.pluginSidebar?.first { $0.id == entry }?.title
            return PluginScreenViewController(entry: entry, page: "list", title: title ?? "", root: root, showsHost: true)
        case .appSettings:
            return SettingsRootViewController(root: root)
        case .serverMetrics:
            return ServerMetricsViewController(root: root)
        case .extensions:
            return ServerExtensionsViewController(root: root)
        case .manageServers:
            return UsageRouteViewController(root: root)
        }
    }

    /// Newer content for the same screen (a refreshed workspace). The main
    /// pane's sidebar button is the stack's, not the screen's.
    static func update(_ screen: UIViewController, route: ShellRoute) {
        if let detail = screen as? WorkspaceDetailViewController, case .workspace(let target) = route {
            detail.update(workspace: target.workspace)
        }
    }

    /// The workspace list beneath the compact stack.
    static func drawerSidebar(root: AppRootEnvironment, onSelect: @escaping () -> Void) -> UIViewController {
        WorkspaceSidebarViewController(root: root, onSelect: onSelect)
    }

    static func serverLockCover(serverId: String, root: AppRootEnvironment) -> UIViewController {
        let serverStore = root.coordinator.serverStore
        return ScopedLockCoverViewController(
            target: .server(serverId),
            titleSource: { serverStore.server(for: serverId)?.name ?? String(localized: "Server") },
            accessory: LockedServerSwitchButton(root: root)
        )
    }

    /// A locked session's cover in place of its chat.
    static func sessionLockCover(target: ScopedLockTarget, title: String) -> UIViewController {
        ScopedLockCoverViewController(target: target, title: title)
    }

    /// A session route waiting for its server.
    static func connecting(root: AppRootEnvironment) -> UIViewController {
        ConnectingViewController(root: root)
    }
}

/// "Connecting…" on the theme's page background, until the route's server is up.
private final class ConnectingViewController: UIViewController {
    private let root: AppRootEnvironment

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme changes.
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
            .connecting,
            palette: ThemeRuntimeState.currentPalette(),
            background: root.themeStore.backgroundColor
        )
    }
}
