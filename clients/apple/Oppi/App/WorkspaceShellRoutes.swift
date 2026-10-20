import SwiftUI

// The SwiftUI content of the workspace shell's routes. UIKit owns the stacks
// (`ShellRouter.swift`, `WorkspaceShellController.swift`). Most routes are a
// `ShellRouteView` hosted through `HostFactory`; All Sessions, the workspace
// sidebar, a workspace's sessions, a session's chat
// (`ChatRouteViewController`), SSH Terminal's host list, Schedules, and Agents
// are UIKit screens.

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
        if let chatRoute = screen as? ChatRouteViewController {
            chatRoute.placement = placement
            return
        }
        // The sidebar reads its own state.
        if screen is WorkspaceSidebarViewController { return }
        if let detail = screen as? WorkspaceDetailViewController {
            if case .workspace(let target) = route {
                detail.update(workspace: target.workspace)
            }
            detail.showsSidebarToggle = placement == .splitDetailRoot
            return
        }
        guard let screen = screen as? HostedScreenController else { return }
        screen.setContent {
            ShellRouteView(route: route, placement: placement, openSidebar: openSidebar)
        }
    }

    /// The workspace list beneath the compact stack.
    static func drawerSidebar(root: AppRootEnvironment, onSelect: @escaping () -> Void) -> UIViewController {
        WorkspaceSidebarViewController(root: root, onSelect: onSelect)
    }

    static func serverLockCover(serverId: String, root: AppRootEnvironment) -> UIViewController {
        HostFactory.content(ShellServerLockCover(serverId: serverId), root: root)
    }

    /// A locked session's cover in place of its chat.
    static func sessionLockCover(target: ScopedLockTarget, title: String, root: AppRootEnvironment) -> UIViewController {
        HostFactory.content(ShellSessionLockCover(target: target, title: title), root: root)
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

/// A session's lock cover; Unlock authorizes the session's scope.
private struct ShellSessionLockCover: View {
    let target: ScopedLockTarget
    let title: String

    @State private var locks = ScopedLockService.shared

    var body: some View {
        ScopedLockCoverView(title: title, isAuthenticating: locks.isAuthenticating) {
            Task { _ = await locks.authorize(target) }
        } accessory: {
            EmptyView()
        }
    }
}

/// One route's screen, with the chrome its place in the shell adds: the
/// sidebar toggle at the split detail root.
struct ShellRouteView: View {
    let route: ShellRoute
    let placement: ShellRoutePlacement
    let openSidebar: (() -> Void)?

    @Environment(\.chatReaderPayloadStore) private var chatReaderPayloadStore

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
        case .inbox, .sidebar, .workspace, .session:
            // UIKit screens (SessionInboxViewController,
            // WorkspaceSidebarViewController, WorkspaceDetailViewController,
            // ChatRouteViewController).
            mountedByUIKitScreen
        case .fileBrowser(let target):
            WorkspaceFileBrowserDestinationView(target: target)
        case .linkedFile(let target):
            WorkspaceLinkedFileDestinationView(target: target)
        case .chatReader(let target):
            if let chatReaderPayloadStore {
                ChatReaderDestinationView(target: target, store: chatReaderPayloadStore)
            }
        case .workspaceConfiguration(let target):
            WorkspaceConfigurationDestinationView(
                target: target,
                completesSplitDetail: placement == .splitDetailRoot
            )
        case .utility(let target):
            WorkspaceUtilityDestinationView(target: target)
        case .serverDetails(let target):
            ServerDetailsScopedDestinationView(target: target)
        case .modelProviders(let target):
            ModelProvidersScopedDestinationView(target: target)
        case .serverResourceDetail(let target):
            ServerResourceDetailDestinationView(target: target)
        case .serverSkillBrowser(let target):
            ServerSkillBrowserScopedDestinationView(target: target)
        case .serverSkillFile(let target):
            ServerSkillFileScopedDestinationView(target: target)
        case .sessionThread(let target):
            SessionThreadDetailView(target: target)
        }
    }
}

/// The active server's lock cover over the whole shell.
private struct ShellServerLockCover: View {
    let serverId: String

    @Environment(ServerStore.self) private var serverStore
    @State private var locks = ScopedLockService.shared

    var body: some View {
        ScopedLockCoverView(
            title: serverStore.server(for: serverId)?.name ?? String(localized: "Server"),
            isAuthenticating: locks.isAuthenticating
        ) {
            Task { _ = await locks.authorize(.server(serverId)) }
        } accessory: {
            LockedServerSwitchMenu()
        }
    }
}

/// On a locked server's cover: switch to another paired server instead of
/// unlocking this one. A locked target server asks first.
private struct LockedServerSwitchMenu: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore

    private var otherServers: [PairedServer] {
        serverStore.servers.filter { $0.id != coordinator.activeServerId }
    }

    var body: some View {
        if !otherServers.isEmpty {
            Menu {
                ForEach(otherServers) { server in
                    Button {
                        switchTo(server)
                    } label: {
                        Label(server.name, systemImage: server.resolvedBadgeIcon.symbolName)
                    }
                }
            } label: {
                Label("Switch Server", systemImage: "arrow.left.arrow.right")
            }
            .accessibilityIdentifier("scopedLock.switchServer")
        }
    }

    private func switchTo(_ server: PairedServer) {
        let coordinator = coordinator
        let perform: @MainActor () -> Void = {
            guard coordinator.restoreActiveServer(server.id) else { return }
            Task { await coordinator.prepareSelectedServerShell(for: server) }
        }
        if ScopedLockService.shared.gate(.server(server.id), onUnlock: perform) {
            perform()
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

/// Workspace settings for one workspace, on its server. As the split detail
/// root, Done returns the column to the workspace's sessions.
private struct WorkspaceConfigurationDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    let target: WorkspaceNavTarget
    let completesSplitDetail: Bool

    @State private var scopedConnection: ServerConnection?

    var body: some View {
        ScopedLockGate(
            target: .workspace(serverId: target.serverId, workspaceId: target.workspace.id),
            title: target.workspace.name
        ) {
            unlockedBody
        }
    }

    private var unlockedBody: some View {
        Group {
            if let connection = scopedConnection {
                WorkspaceSettingsRootView(workspace: target.workspace)
                    .withServerScopedEnvironment(connection)
                    .toolbar {
                        if completesSplitDetail {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
                                    navigation.completeWorkspaceConfiguration(target)
                                }
                                .accessibilityIdentifier("workspace.edit.done")
                            }
                        }
                    }
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: target.serverId) {
            guard await coordinator.switchToServerReady(target.serverId) else { return }
            scopedConnection = coordinator.connection(for: target.serverId)
        }
    }
}

private struct WorkspaceUtilityDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: WorkspaceUtilityNavTarget

    var body: some View {
        if target.isReleaseEnabled {
            switch target {
            case .schedules, .agents:
                // The shell hosts these routes as ScheduleListViewController
                // and AgentListViewController.
                EmptyView()
            case .skills:
                ServerSkillsView()
            case .extensions:
                ServerExtensionsView()
            case .mcpServers:
                McpServersView(scopeId: McpScopeSnapshot.globalId)
            case .sshTerminal:
                // The shell hosts this route as SSHTerminalHostListViewController.
                EmptyView()
            case .manageServers:
                ServerView()
            case .serverMetrics:
                ServerMetricsScreen()
            case .appSettings:
                SettingsView()
            }
        } else {
            WorkspaceSplitPlaceholder(
                title: "Unavailable",
                systemImage: "eye.slash",
                description: "This management screen is hidden in this build."
            )
        }
    }
}

/// Workspace creation the shell starts by itself: an `oppi://workspace` link,
/// or the guided first workspace after pairing a server that has none.
struct WorkspaceCreationIntakeModifier: ViewModifier {
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
                onDismiss: handleCreateSheetDismissed
            ) { context in
                WorkspaceCreateView(
                    server: context.server,
                    presentation: context.presentation,
                    prefillName: context.prefillName,
                    prefillPath: context.prefillPath,
                    onCreate: { workspace in
                        guard context.openWorkspaceAfterCreate else { return }
                        pendingCreatedWorkspaceTarget = WorkspaceNavTarget(
                            serverId: context.server.id,
                            workspace: workspace
                        )
                    }
                )
            }
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

        let server: PairedServer?
        if let fingerprint = payload.serverFingerprint {
            server = servers.first { WorkspaceDeepLink.fingerprintsMatch($0.id, fingerprint) }
        } else {
            server = selectedServer ?? servers.first
        }

        guard let server else {
            coordinator.activeConnection.extensionToast = "Server not found for this workspace link"
            return true
        }
        guard await coordinator.switchToServerReady(server) else {
            coordinator.activeConnection.extensionToast = "Could not open the server for this workspace link"
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

private struct WorkspaceSplitPlaceholder: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.themeBg)
    }
}
