import SwiftUI

struct WorkspaceAdaptiveRootView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.chatReaderPayloadStore) private var chatReaderPayloadStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Window size without the keyboard. Nil until first measured, so launch
    /// never mounts the wrong shell for one frame.
    @State private var windowSize: CGSize?
    /// False until the first measured presentation has been applied.
    @State private var hasAppliedPresentation = false

    private var measured: WorkspaceNavigationPresentation? {
        windowSize.map {
            WorkspaceNavigationPresentation.resolve(
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                size: $0
            )
        }
    }

    var body: some View {
        // A locked active server covers everything under it: lists,
        // sidebar, pushed pages, and settings that follow the active host.
        ScopedLockGate(
            target: coordinator.activeServerId.map(ScopedLockTarget.server),
            title: activeServer?.name ?? String(localized: "Server")
        ) {
            LockedServerSwitchMenu()
        } content: {
            // Render the shell AppNavigation already converted its routes for,
            // never the raw measurement. A fold or rotation first converts the
            // stack path into split selection (or back) in one mutation, then the
            // new shell mounts once with matching state. Rendering the raw
            // measurement mounted the new shell against the old shell's routes for
            // a frame, then remounted the split detail when its
            // `.id(splitDetailTarget)` changed. AVKit fullscreen freezes the
            // presentation inside AppNavigation, so it needs no check here.
            if hasAppliedPresentation {
                switch navigation.workspaceNavigationPresentation {
                case .stack:
                    WorkspaceStackRootView()
                case .split:
                    WorkspaceSplitRootView()
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The shells stay inside the keyboard safe area so fields move up; only
        // this measurement ignores it. A docked keyboard on a portrait window
        // (the Duo inner display, iPad) would otherwise make it wider than tall,
        // swap to split, destroy the focused field, drop the keyboard, and
        // swap back.
        // The observer sits inside `ignoresSafeArea`, which extends its child
        // but keeps its own frame; observing outside it reads the shrunk frame.
        .background {
            Color.clear
                .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
                .ignoresSafeArea(.keyboard)
        }
        .modifier(WorkspaceCreationIntakeModifier())
        .onChange(of: measured, initial: true) { _, newValue in
            guard let newValue else { return }
            applyPresentation(newValue)
            hasAppliedPresentation = true
        }
        .onChange(of: navigation.isMediaOverlayActive) { wasActive, isActive in
            guard wasActive, !isActive, let measured else { return }
            applyPresentation(measured)
        }
    }

    private var activeServer: PairedServer? {
        coordinator.activeServerId.flatMap { serverStore.server(for: $0) }
    }

    private func applyPresentation(_ presentation: WorkspaceNavigationPresentation) {
        let measurement = windowSize.map {
            WorkspaceNavigationMeasurement(
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                windowSize: $0
            )
        }
        navigation.setWorkspaceNavigationPresentation(presentation, measurement: measurement)
        navigation.routeLegacySelectedTabIfNeeded()
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

private struct WorkspaceStackRootView: View {
    var body: some View {
        // The NavigationStack lives inside WorkspaceSessionInboxStackRootView's
        // sliding foreground layer so the nav bar, search, and bottom toolbar
        // travel as one surface with the session list when the sidebar reveals.
        WorkspaceSessionInboxStackRootView()
    }
}

private struct WorkspaceSplitRootView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.chatReaderPayloadStore) private var chatReaderPayloadStore

    var body: some View {
        @Bindable var nav = navigation

        NavigationSplitView(columnVisibility: $nav.splitColumnVisibility) {
            NavigationStack(path: $nav.workspacePath) {
                WorkspaceSplitSidebarView()
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            NavigationStack(path: $nav.splitDetailPath) {
                WorkspaceSplitDetailDestinationView(target: navigation.splitDetailTarget)
                    .navigationDestination(for: FileBrowserNavTarget.self) { target in
                        WorkspaceFileBrowserDestinationView(target: target)
                    }
                    .navigationDestination(for: WorkspaceSessionNavTarget.self) { target in
                        WorkspaceSessionScopedDestinationView(target: target)
                    }
                    .navigationDestination(for: WorkspaceLinkedFileNavTarget.self) { target in
                        WorkspaceLinkedFileDestinationView(target: target)
                    }
                    .navigationDestination(for: ChatReaderNavTarget.self) { target in
                        if let store = chatReaderPayloadStore {
                            ChatReaderDestinationView(target: target, store: store)
                        }
                    }
                    .navigationDestination(for: ServerResourceDetailNavTarget.self) { target in
                        ServerResourceDetailDestinationView(target: target)
                    }
                    .navigationDestination(for: ServerSkillBrowserNavTarget.self) { target in
                        ServerSkillBrowserScopedDestinationView(target: target)
                    }
                    .navigationDestination(for: ServerSkillFileNavTarget.self) { target in
                        ServerSkillFileScopedDestinationView(target: target)
                    }
                    .navigationDestination(for: ServerDetailsNavTarget.self) { target in
                        ServerDetailsScopedDestinationView(target: target)
                    }
                    .navigationDestination(for: ModelProvidersNavTarget.self) { target in
                        ModelProvidersScopedDestinationView(target: target)
                    }
                    .navigationDestination(for: SessionThreadNavTarget.self) { target in
                        SessionThreadDetailView(target: target)
                    }
            }
            .id(navigation.splitDetailTarget)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    WorkspaceSplitSidebarToggleButton()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
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

private struct WorkspaceSplitSidebarView: View {
    var body: some View {
        WorkspaceSidebarView()
    }
}

private struct WorkspaceSplitDetailDestinationView: View {
    @Environment(AppNavigation.self) private var navigation
    let target: WorkspaceSplitDetailTarget?

    var body: some View {
        switch target {
        case .session(let target):
            WorkspaceSessionScopedDestinationView(target: target)
        case .fileBrowser(let target):
            WorkspaceFileBrowserDestinationView(target: target)
        case .linkedFile(let target):
            WorkspaceLinkedFileDestinationView(target: target)
        case .workspaceConfiguration(let target):
            WorkspaceSplitWorkspaceConfigurationDestinationView(target: target)
        case .utility(let target):
            WorkspaceUtilityDestinationView(target: target)
        case nil:
            if let workspace = navigation.splitSelectedWorkspace {
                WorkspaceScopedDestinationView(target: workspace)
            } else {
                SessionInboxView()
            }
        }
    }
}

private struct WorkspaceSplitWorkspaceConfigurationDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    let target: WorkspaceNavTarget

    @State private var scopedConnection: ServerConnection?

    private var resolvedConnection: ServerConnection? { scopedConnection }

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
            if let connection = resolvedConnection {
                WorkspaceSettingsRootView(workspace: target.workspace)
                    .withServerScopedEnvironment(connection)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                navigation.completeWorkspaceConfiguration(target)
                            }
                            .accessibilityIdentifier("workspace.edit.done")
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
    let target: WorkspaceUtilityNavTarget

    var body: some View {
        if target.isReleaseEnabled {
            switch target {
            case .schedules:
                ScheduleManagementView()
            case .agents:
                AgentManagementView()
            case .skills:
                ServerSkillsView()
            case .extensions:
                ServerExtensionsView()
            case .mcpServers:
                McpServersView(scopeId: McpScopeSnapshot.globalId)
            case .sshTerminal:
                SSHTerminalHostListView()
            case .durableSessions:
                SessionInboxView(scope: .durable)
            case .desktopStill:
                DesktopCurrentStillViewerView()
            case .manageServers:
                ServerView()
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

private struct WorkspaceCreationIntakeModifier: ViewModifier {
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
            .sheet(item: $createSheetContext, onDismiss: handleCreateSheetDismissed) { context in
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
