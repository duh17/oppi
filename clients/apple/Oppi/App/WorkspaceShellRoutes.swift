import SwiftUI

// The SwiftUI content of the workspace shell's routes. UIKit owns the stacks
// (`ShellRouter.swift`, `WorkspaceShellController.swift`). Most routes are a
// `ShellRouteView` hosted through `HostFactory`; All Sessions, the workspace
// sidebar, a workspace's sessions, a session's chat
// (`ChatRouteViewController`), a chat reader (`ChatReaderViewController`), Files (`FileBrowserViewController`), a linked
// file (`WorkspaceLinkedFileViewController`), a Skill file
// (`ServerSkillFileViewController`), Skills (`ServerSkillsViewController`) with
// a Skill's page (`ServerSkillDetailViewController`) and its file browser
// (`ServerSkillBrowserViewController`), Extensions
// (`ServerExtensionsViewController`) and an Extension's detail
// (`ServerExtensionDetailViewController`), SSH Terminal's host list,
// Schedules, Agents, MCP Servers (`McpServersViewController`), App Settings
// (`SettingsRootViewController`), Workspace Settings
// (`WorkspaceSettingsViewController`), Model Providers
// (`ModelProvidersViewController`), Server Settings
// (`ServerSettingsRouteViewController`), Usage (`UsageRouteViewController`), and Server Metrics
// (`ServerMetricsViewController`) are UIKit screens.

/// Hosted screens for the shell's UIKit controllers.
@MainActor
enum ShellRouteScreens {
    static func make(
        _ route: ShellRoute,
        placement: ShellRoutePlacement,
        root: AppRootEnvironment,
        openSidebar: (() -> Void)?
    ) -> UIViewController {
        if route == .inbox {
            return SessionInboxViewController(
                root: root,
                onOpenSidebar: openSidebar,
                showsSidebarToggle: placement == .splitDetailRoot
            )
        }
        if case .utility(.sshTerminal) = route {
            let screen = SSHTerminalHostListViewController(showsSidebarToggle: placement == .splitDetailRoot)
            screen.traitOverrides.appRootEnvironment = root
            return screen
        }
        if case .utility(.schedules) = route {
            return ScheduleListViewController(root: root, showsSidebarToggle: placement == .splitDetailRoot)
        }
        if case .utility(.agents) = route {
            return AgentListViewController(root: root, showsSidebarToggle: placement == .splitDetailRoot)
        }
        if case .utility(.mcpServers) = route {
            return McpServersViewController(
                scopeId: McpScopeSnapshot.globalId,
                root: root,
                showsSidebarToggle: placement == .splitDetailRoot
            )
        }
        if case .utility(.skills) = route {
            return ServerSkillsViewController(root: root, showsSidebarToggle: placement == .splitDetailRoot)
        }
        if case .utility(.appSettings) = route {
            return SettingsRootViewController(root: root)
        }
        if case .utility(.serverMetrics) = route {
            return ServerMetricsViewController(root: root, showsSidebarToggle: placement == .splitDetailRoot)
        }
        if case .utility(.extensions) = route {
            return ServerExtensionsViewController(root: root, showsSidebarToggle: placement == .splitDetailRoot)
        }
        if case .utility(.manageServers) = route {
            return UsageRouteViewController(root: root, showsSidebarToggle: placement == .splitDetailRoot)
        }
        if case .sidebar = route {
            return WorkspaceSidebarViewController(root: root)
        }
        if case .workspace(let target) = route {
            return WorkspaceDetailViewController(
                root: root,
                target: target,
                showsSidebarToggle: placement == .splitDetailRoot
            )
        }
        if case .session(let target) = route {
            return ChatRouteViewController(target: target, placement: placement, root: root)
        }
        if case .fileBrowser(let target) = route {
            return FileBrowserViewController(
                root: root,
                target: target,
                showsSidebarToggle: placement == .splitDetailRoot
            )
        }
        if case .linkedFile(let target) = route {
            return WorkspaceLinkedFileViewController(target: target, placement: placement, root: root)
        }
        if case .serverSkillFile(let target) = route {
            return ServerSkillFileViewController(target: target, root: root)
        }
        if case .chatReader(let target) = route {
            return ChatReaderViewController(target: target, root: root)
        }
        if case .serverResourceDetail(let target) = route {
            switch target.kind {
            case .skill: return ServerSkillDetailViewController(target: target, root: root)
            case .extension: return ServerExtensionDetailViewController(target: target, root: root)
            }
        }
        if case .serverSkillBrowser(let target) = route {
            return ServerSkillBrowserViewController(target: target, root: root)
        }
        if case .modelProviders(let target) = route {
            // Keyed by the route, not the visible host: a host-pill switch
            // reloads in place and keeps a live provider sign-in.
            return ModelProvidersViewController(target: target, root: root)
        }
        if case .serverDetails(let target) = route {
            return ServerSettingsRouteViewController(
                target: target,
                root: root,
                showsSidebarToggle: placement == .splitDetailRoot
            )
        }
        if case .workspaceConfiguration(let target) = route {
            let screen = WorkspaceSettingsViewController(
                serverId: target.serverId,
                workspace: target.workspace,
                root: root
            )
            configure(screen, target: target, placement: placement)
            return screen
        }
        return HostFactory.screen(root: root, bars: route.bars) {
            ShellRouteView(route: route, placement: placement, openSidebar: openSidebar)
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
        guard let screen = screen as? HostedScreenController else { return }
        screen.setContent {
            ShellRouteView(route: route, placement: placement, openSidebar: openSidebar)
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
        ScopedLockCoverViewController(
            target: .server(serverId),
            title: root.coordinator.serverStore.server(for: serverId)?.name ?? String(localized: "Server"),
            accessory: LockedServerSwitchButton(root: root)
        )
    }

    /// A locked session's cover in place of its chat.
    static func sessionLockCover(target: ScopedLockTarget, title: String) -> UIViewController {
        ScopedLockCoverViewController(target: target, title: title)
    }

    /// A session route waiting for its server.
    static func connecting(root: AppRootEnvironment) -> UIViewController {
        HostFactory.content(
            ProgressView("Connecting\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.themeBg),
            root: root
        )
    }
}

/// One route's screen, with the chrome its place in the shell adds: the
/// sidebar toggle at the split detail root.
struct ShellRouteView: View {
    let route: ShellRoute
    let placement: ShellRoutePlacement
    let openSidebar: (() -> Void)?

    var body: some View {
        if placement == .splitDetailRoot {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        WorkspaceSplitSidebarToggleButton()
                    }
                }
        } else {
            content
        }
    }

    private var mountedByUIKitScreen: EmptyView {
        preconditionFailure("mounted by ShellRouteScreens.make")
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .inbox, .sidebar, .workspace, .session, .fileBrowser, .linkedFile, .serverSkillFile,
             .workspaceConfiguration, .modelProviders, .serverResourceDetail, .serverSkillBrowser,
             .serverDetails, .chatReader:
            // UIKit screens (SessionInboxViewController,
            // WorkspaceSidebarViewController, WorkspaceDetailViewController,
            // ChatRouteViewController, FileBrowserViewController,
            // WorkspaceLinkedFileViewController, ServerSkillFileViewController,
            // WorkspaceSettingsViewController, ModelProvidersViewController,
            // ServerSkillDetailViewController, ServerExtensionDetailViewController,
            // ServerSkillBrowserViewController, ServerSettingsRouteViewController,
            // ChatReaderViewController).
            mountedByUIKitScreen
        case .utility(let target):
            WorkspaceUtilityDestinationView(target: target)
        case .sessionThread(let target):
            SessionThreadDetailView(target: target)
        }
    }
}

private struct WorkspaceSplitSidebarToggleButton: View {
    @Environment(AppNavigation.self) private var navigation

    private var isSidebarVisible: Bool {
        navigation.splitColumnVisibility != .detailOnly
    }

    var body: some View {
        Button {
            navigation.splitColumnVisibility = isSidebarVisible ? .detailOnly : .all
        } label: {
            // Title plus symbol so the toolbar can render it on the Duo's
            // vertical rail and in overflow menus.
            Label(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.leading")
        }
        .foregroundStyle(.themeFg)
        .accessibilityIdentifier("workspace.split.sidebarToggle")
    }
}

private struct WorkspaceUtilityDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: WorkspaceUtilityNavTarget

    var body: some View {
        switch target {
        case .schedules, .agents, .skills, .extensions:
            // The shell hosts these routes as ScheduleListViewController,
            // AgentListViewController, ServerSkillsViewController, and
            // ServerExtensionsViewController.
            EmptyView()
        case .mcpServers:
            // The shell hosts this route as McpServersViewController.
            EmptyView()
        case .sshTerminal:
            // The shell hosts this route as SSHTerminalHostListViewController.
            EmptyView()
        case .manageServers:
            // The shell hosts this route as UsageRouteViewController.
            EmptyView()
        case .serverMetrics:
            // The shell hosts this route as ServerMetricsViewController.
            EmptyView()
        case .appSettings:
            // The shell hosts this route as SettingsRootViewController.
            EmptyView()
        }
    }
}

/// Workspace creation the shell starts by itself: an `oppi://workspace` link,
/// or the guided first workspace after pairing a server that has none.
struct WorkspaceCreationIntakeModifier: ViewModifier {
    let root: AppRootEnvironment

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation

    @State private var createSheetContext: WorkspaceCreateSheetContext?
    @State private var pendingCreatedWorkspaceTarget: WorkspaceNavTarget?
    @State private var guidedCreateConsumed = false

    private var servers: [PairedServer] {
        serverStore.servers
    }

    private var selectedServer: PairedServer? {
        if let activeServerId = coordinator.activeServerId,
           let server = servers.first(where: { $0.id == activeServerId }) {
            return server
        }
        return servers.first
    }

    func body(content: Content) -> some View {
        content
            .routerModal(
                item: $createSheetContext,
                presentation: .sheet.inNavigation(),
                onDismiss: handleCreateSheetDismissed,
                screen: { context in
                    .controller {
                        context.makeScreen(root: root) { workspace in
                            guard context.openWorkspaceAfterCreate else { return }
                            pendingCreatedWorkspaceTarget = WorkspaceNavTarget(
                                serverId: context.server.id,
                                workspace: workspace
                            )
                        }
                    }
                }
            )
            .task(id: coordinator.activeServerId) {
                await processWorkspaceCreationIntake()
            }
            .onChange(of: navigation.pendingWorkspaceDeepLink != nil) { _, hasPending in
                guard hasPending else { return }
                Task { await consumeWorkspaceDeepLinkIfNeeded() }
            }
            .onChange(of: navigation.shouldGuideWorkspaceCreation) { _, shouldGuide in
                guard shouldGuide else { return }
                Task { await presentGuidedWorkspaceCreationIfNeeded() }
            }
    }

    @MainActor
    private func processWorkspaceCreationIntake() async {
        if await consumeWorkspaceDeepLinkIfNeeded() {
            return
        }
        await presentGuidedWorkspaceCreationIfNeeded()
    }

    @MainActor
    @discardableResult
    private func consumeWorkspaceDeepLinkIfNeeded() async -> Bool {
        guard let payload = navigation.pendingWorkspaceDeepLink else { return false }
        navigation.pendingWorkspaceDeepLink = nil
        navigation.shouldGuideWorkspaceCreation = false

        // AppOpener resolved the server and switched to it before parking this
        // payload. Do not resolve or switch again with different rules.
        guard let serverId = payload.resolvedServerId,
              let server = servers.first(where: { $0.id == serverId }) else {
            coordinator.activeConnection.extensionToast = "Server not found for this workspace link"
            return true
        }

        navigation.showAllWorkspaceSessions()
        createSheetContext = WorkspaceCreateSheetContext(
            server: server,
            presentation: .standard,
            openWorkspaceAfterCreate: false,
            prefillName: payload.name,
            prefillPath: payload.path
        )
        return true
    }

    @MainActor
    private func presentGuidedWorkspaceCreationIfNeeded() async {
        guard navigation.shouldGuideWorkspaceCreation, !guidedCreateConsumed else { return }
        guard let server = selectedServer else { return }

        await coordinator.refreshServer(server.id, force: true)

        guard navigation.shouldGuideWorkspaceCreation, !guidedCreateConsumed else { return }
        guard coordinator.activeServerId == server.id else { return }
        guard let connection = coordinator.connection(for: server.id),
              !connection.workspaceStore.lastSyncFailed else { return }
        let workspaces = connection.workspaceStore.workspaces
        guard workspaces.isEmpty else {
            navigation.shouldGuideWorkspaceCreation = false
            return
        }

        guidedCreateConsumed = true
        navigation.shouldGuideWorkspaceCreation = false
        navigation.showAllWorkspaceSessions()
        createSheetContext = WorkspaceCreateSheetContext(
            server: server,
            presentation: .guidedFirstWorkspace,
            openWorkspaceAfterCreate: true,
            prefillName: nil,
            prefillPath: nil
        )
    }

    private func handleCreateSheetDismissed() {
        guard let target = pendingCreatedWorkspaceTarget else { return }
        pendingCreatedWorkspaceTarget = nil
        navigation.openWorkspace(target)
    }
}
