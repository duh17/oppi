import SwiftUI

struct WorkspaceAdaptiveRootView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var presentation: WorkspaceNavigationPresentation {
        horizontalSizeClass == .regular ? .split : .stack
    }

    var body: some View {
        Group {
            switch presentation {
            case .stack:
                WorkspaceStackRootView()
            case .split:
                WorkspaceSplitRootView()
            }
        }
        .onAppear {
            applyPresentation(presentation)
        }
        .onChange(of: presentation) { _, newValue in
            applyPresentation(newValue)
        }
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
                WorkspaceHomeView()
            }
        } content: {
            if let target = navigation.splitSelectedWorkspace {
                NavigationStack {
                    WorkspaceScopedDestinationView(target: target)
                }
                .id(target)
            } else {
                WorkspaceSplitPlaceholder(
                    title: "Select a Workspace",
                    systemImage: "square.grid.2x2",
                    description: "Choose a workspace from the sidebar to review sessions."
                )
            }
        } detail: {
            NavigationStack(path: $nav.splitDetailPath) {
                WorkspaceSplitDetailDestinationView(target: navigation.splitDetailTarget)
                    .navigationDestination(for: FileBrowserNavTarget.self) { target in
                        WorkspaceSplitFileBrowserDestinationView(target: target)
                    }
            }
            .id(navigation.splitDetailTarget)
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

    private var targetServerId: String? {
        navigation.splitSelectedWorkspace?.serverId ?? coordinator.activeServerId
    }

    private var resolvedConnection: ServerConnection? {
        if let scopedConnection { return scopedConnection }
        guard let targetServerId else { return nil }
        return coordinator.connection(for: targetServerId)
    }

    var body: some View {
        Group {
            if let connection = resolvedConnection {
                FileBrowserView(workspaceId: target.workspaceId, initialPath: target.path)
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
        guard let targetServerId else { return }
        guard coordinator.switchToServer(targetServerId) else { return }
        scopedConnection = coordinator.connection(for: targetServerId)
    }
}

private struct WorkspaceUtilityDestinationView: View {
    let target: WorkspaceUtilityNavTarget

    var body: some View {
        switch target {
        case .manageServers:
            ServerView()
        case .appSettings:
            SettingsView()
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
