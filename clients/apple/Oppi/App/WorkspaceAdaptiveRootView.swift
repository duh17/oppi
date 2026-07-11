import SwiftUI

struct WorkspaceAdaptiveRootView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let minimumSplitWidth: CGFloat = 980

    var body: some View {
        GeometryReader { proxy in
            let presentation = presentation(for: proxy.size)

            Group {
                switch presentation {
                case .stack:
                    WorkspaceStackRootView()
                case .split:
                    WorkspaceSplitRootView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(WorkspaceCreationIntakeModifier())
            .onAppear {
                applyPresentation(presentation)
            }
            .onChange(of: presentation) { _, newValue in
                applyPresentation(newValue)
            }
        }
    }

    private func presentation(for size: CGSize) -> WorkspaceNavigationPresentation {
        guard horizontalSizeClass == .regular else { return .stack }
        guard size.width >= minimumSplitWidth else { return .stack }
        return size.width >= size.height ? .split : .stack
    }

    private func applyPresentation(_ presentation: WorkspaceNavigationPresentation) {
        navigation.setWorkspaceNavigationPresentation(presentation)
        navigation.routeLegacySelectedTabIfNeeded()
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
                        WorkspaceSplitFileBrowserDestinationView(target: target)
                    }
                    .navigationDestination(for: WorkspaceLinkedFileNavTarget.self) { target in
                        WorkspaceLinkedFileDestinationView(target: target)
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
            Image(systemName: "sidebar.left")
        }
        .accessibilityLabel(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
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
            WorkspaceSplitFileBrowserDestinationView(target: target)
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

private struct WorkspaceSplitFileBrowserDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    let target: FileBrowserNavTarget

    @State private var scopedConnection: ServerConnection?

    private var targetServerId: String {
        target.serverId
    }

    private var resolvedConnection: ServerConnection? {
        scopedConnection ?? coordinator.connection(for: targetServerId)
    }

    var body: some View {
        Group {
            if let connection = resolvedConnection {
                FileBrowserView(
                    serverId: targetServerId,
                    workspaceId: target.workspaceId,
                    worktreeId: target.worktreeId,
                    initialPath: target.path
                )
                .withServerScopedEnvironment(connection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .onAppear(perform: activateTargetServer)
        .task(id: targetServerId) {
            activateTargetServer()
        }
    }

    @MainActor
    private func activateTargetServer() {
        guard coordinator.switchToServer(targetServerId) else { return }
        scopedConnection = coordinator.connection(for: targetServerId)
    }
}

private struct WorkspaceSplitWorkspaceConfigurationDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    let target: WorkspaceNavTarget

    @State private var scopedConnection: ServerConnection?

    private var resolvedConnection: ServerConnection? {
        scopedConnection ?? coordinator.connection(for: target.serverId)
    }

    var body: some View {
        Group {
            if let connection = resolvedConnection {
                WorkspaceEditView(workspace: target.workspace) {
                    navigation.completeWorkspaceConfiguration(target)
                }
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
        .onAppear(perform: activateTargetServer)
        .task(id: target.serverId) {
            activateTargetServer()
        }
    }

    @MainActor
    private func activateTargetServer() {
        guard coordinator.switchToServer(target.serverId) else { return }
        scopedConnection = coordinator.connection(for: target.serverId)
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
                consumeWorkspaceDeepLinkIfNeeded()
            }
            .onChange(of: navigation.shouldGuideWorkspaceCreation) { _, shouldGuide in
                guard shouldGuide else { return }
                Task { await presentGuidedWorkspaceCreationIfNeeded() }
            }
    }

    @MainActor
    private func processWorkspaceCreationIntake() async {
        if consumeWorkspaceDeepLinkIfNeeded() {
            return
        }
        await presentGuidedWorkspaceCreationIfNeeded()
    }

    @MainActor
    @discardableResult
    private func consumeWorkspaceDeepLinkIfNeeded() -> Bool {
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
        guard coordinator.switchToServer(server) else {
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
        .background(Color.themeBg)
    }
}
