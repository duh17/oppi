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

        if navigation.splitSelectedWorkspace == nil, navigation.splitSelectedSession == nil {
            WorkspaceStackRootView()
        } else {
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
                if let target = navigation.splitSelectedSession {
                    NavigationStack {
                        WorkspaceSessionScopedDestinationView(target: target)
                    }
                    .id(target)
                } else {
                    WorkspaceSplitPlaceholder(
                        title: "Select a Session",
                        systemImage: "text.bubble",
                        description: "Choose a session to supervise the agent."
                    )
                }
            }
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
