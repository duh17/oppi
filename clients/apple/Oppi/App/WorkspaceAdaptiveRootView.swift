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
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var nav = navigation

        NavigationStack(path: $nav.workspacePath) {
            WorkspaceHomeView()
        }
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
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        if let target = navigation.splitSelectedWorkspace {
            WorkspaceScopedDestinationView(target: target)
                .id(target)
        } else {
            WorkspaceHomeView()
        }
    }
}

private struct WorkspaceSplitDetailDestinationView: View {
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
            WorkspaceSplitPlaceholder(
                title: "Select a Session",
                systemImage: "text.bubble",
                description: "Open a session, Files, Server, or Settings from the workspace columns."
            )
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
                FileBrowserView(serverId: targetServerId, workspaceId: target.workspaceId, initialPath: target.path)
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
