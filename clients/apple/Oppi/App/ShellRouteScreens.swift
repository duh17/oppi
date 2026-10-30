import UIKit

// The shell's route screens. UIKit owns the stacks (`ShellRouter.swift`,
// `WorkspaceShellController.swift`); every route is a UIKit screen, built here.

/// The shell's UIKit screens: one per route, plus the covers and placeholders
/// the shell shows in their place.
@MainActor
enum ShellRouteScreens {
    static func make(
        _ route: ShellRoute,
        placement: ShellRoutePlacement,
        root: AppRootEnvironment,
        openSidebar: (() -> Void)?
    ) -> UIViewController {
        let showsSidebarToggle = placement == .splitDetailRoot
        switch route {
        case .inbox:
            return SessionInboxViewController(
                root: root,
                onOpenSidebar: openSidebar,
                showsSidebarToggle: showsSidebarToggle
            )
        case .sidebar:
            return WorkspaceSidebarViewController(root: root)
        case .workspace(let target):
            return WorkspaceDetailViewController(
                root: root,
                target: target,
                showsSidebarToggle: showsSidebarToggle
            )
        case .session(let target):
            return ChatRouteViewController(target: target, placement: placement, root: root)
        case .fileBrowser(let target):
            return FileBrowserViewController(
                root: root,
                target: target,
                showsSidebarToggle: showsSidebarToggle
            )
        case .linkedFile(let target):
            return WorkspaceLinkedFileViewController(target: target, placement: placement, root: root)
        case .chatReader(let target):
            return ChatReaderViewController(target: target, root: root)
        case .workspaceConfiguration(let target):
            let screen = WorkspaceSettingsViewController(
                serverId: target.serverId,
                workspace: target.workspace,
                root: root
            )
            configure(screen, target: target, placement: placement)
            return screen
        case .utility(let target):
            return utilityScreen(target, placement: placement, root: root)
        case .serverDetails(let target):
            return ServerSettingsRouteViewController(
                target: target,
                root: root,
                showsSidebarToggle: showsSidebarToggle
            )
        case .modelProviders(let target):
            // Keyed by the route, not the visible host: a host-pill switch
            // reloads in place and keeps a live provider sign-in.
            return ModelProvidersViewController(target: target, root: root)
        case .serverResourceDetail(let target):
            switch target.kind {
            case .skill: return ServerSkillDetailViewController(target: target, root: root)
            case .extension: return ServerExtensionDetailViewController(target: target, root: root)
            }
        case .serverSkillBrowser(let target):
            return ServerSkillBrowserViewController(target: target, root: root)
        case .serverSkillFile(let target):
            return ServerSkillFileViewController(target: target, root: root)
        }
    }

    private static func utilityScreen(
        _ target: WorkspaceUtilityNavTarget,
        placement: ShellRoutePlacement,
        root: AppRootEnvironment
    ) -> UIViewController {
        let showsSidebarToggle = placement == .splitDetailRoot
        switch target {
        case .sshTerminal:
            let screen = SSHTerminalHostListViewController(showsSidebarToggle: showsSidebarToggle)
            screen.traitOverrides.appRootEnvironment = root
            return screen
        case .schedules:
            return ScheduleListViewController(root: root, showsSidebarToggle: showsSidebarToggle)
        case .agents:
            return AgentListViewController(root: root, showsSidebarToggle: showsSidebarToggle)
        case .mcpServers:
            return McpServersViewController(
                scopeId: McpScopeSnapshot.globalId,
                root: root,
                showsSidebarToggle: showsSidebarToggle
            )
        case .skills:
            return ServerSkillsViewController(root: root, showsSidebarToggle: showsSidebarToggle)
        case .appSettings:
            return SettingsRootViewController(root: root)
        case .serverMetrics:
            return ServerMetricsViewController(root: root, showsSidebarToggle: showsSidebarToggle)
        case .extensions:
            return ServerExtensionsViewController(root: root, showsSidebarToggle: showsSidebarToggle)
        case .manageServers:
            return UsageRouteViewController(root: root, showsSidebarToggle: showsSidebarToggle)
        }
    }

    /// Newer content for the same screen (a refreshed workspace).
    static func update(
        _ screen: UIViewController,
        route: ShellRoute,
        placement: ShellRoutePlacement,
        openSidebar: (() -> Void)?
    ) {
        if let inbox = screen as? SessionInboxViewController {
            inbox.onOpenSidebar = openSidebar
            inbox.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let list = screen as? SSHTerminalHostListViewController {
            list.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let list = screen as? ScheduleListViewController {
            list.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let list = screen as? AgentListViewController {
            list.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let metrics = screen as? ServerMetricsViewController {
            metrics.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let list = screen as? ServerSkillsViewController {
            list.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let list = screen as? ServerExtensionsViewController {
            list.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let list = screen as? McpServersViewController {
            list.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let chatRoute = screen as? ChatRouteViewController {
            chatRoute.placement = placement
            return
        }
        if let serverSettings = screen as? ServerSettingsRouteViewController {
            serverSettings.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let usage = screen as? UsageRouteViewController {
            usage.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let files = screen as? FileBrowserViewController {
            files.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let linkedFile = screen as? WorkspaceLinkedFileViewController {
            linkedFile.placement = placement
            return
        }
        // The sidebar reads its own state.
        if screen is WorkspaceSidebarViewController { return }
        // A reader's payload and lock are its own state.
        if screen is ChatReaderViewController { return }
        // A Skill's page and files, an Extension's detail, and Model Providers read their own state.
        if screen is ServerSkillDetailViewController || screen is ServerSkillBrowserViewController
            || screen is ServerExtensionDetailViewController || screen is ModelProvidersViewController { return }
        if let detail = screen as? WorkspaceDetailViewController {
            if case .workspace(let target) = route {
                detail.update(workspace: target.workspace)
            }
            detail.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        if let settings = screen as? WorkspaceSettingsViewController {
            if case .workspaceConfiguration(let target) = route {
                configure(settings, target: target, placement: placement)
            }
            return
        }
    }

    /// As the split detail root, Workspace Settings carries the sidebar toggle
    /// and a Done that returns the column to the workspace's sessions.
    private static func configure(
        _ screen: WorkspaceSettingsViewController,
        target: WorkspaceNavTarget,
        placement: ShellRoutePlacement
    ) {
        let isSplitDetailRoot = placement == .splitDetailRoot
        screen.showsSidebarToggle = isSplitDetailRoot
        screen.onDone = isSplitDetailRoot ? { [navigation = screen.root.navigation] in
            navigation.completeWorkspaceConfiguration(target)
        } : nil
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
