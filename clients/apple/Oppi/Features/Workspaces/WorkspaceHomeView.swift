import SwiftUI

/// Navigation target pairing a workspace with its server for on-demand connection switching.
struct WorkspaceNavTarget: Hashable {
    let serverId: String
    let workspace: Workspace
}

private struct WorkspaceCreateSheetContext: Identifiable {
    let server: PairedServer
    let presentation: WorkspaceCreatePresentation
    let openWorkspaceAfterCreate: Bool

    var id: String {
        [
            server.id,
            presentation == .guidedFirstWorkspace ? "guided" : "standard",
            openWorkspaceAfterCreate ? "open" : "stay"
        ].joined(separator: "|")
    }
}

/// Tracks whether app launch metric has been recorded this process.
/// Only fires once — on the first appearance of WorkspaceHomeView.
nonisolated(unsafe) private var appLaunchMetricRecorded = false

/// Top-level workspace list — primary navigation tab.
///
/// Shows workspaces grouped by server. Each server section has a tappable header
/// with name and freshness state. Tapping a workspace connects to that server
/// on demand and navigates to the workspace detail.
struct WorkspaceHomeView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var createSheetContext: WorkspaceCreateSheetContext?
    @State private var pendingCreatedWorkspaceTarget: WorkspaceNavTarget?
    @State private var collapsedServerIds: Set<String> = []
    /// Guards against re-presenting the guided create after the user dismisses it.
    @State private var guidedCreateConsumed = false
    /// Tracks whether the initial task-driven refresh has already run for this view identity.
    @State private var hasPerformedInitialRefresh = false

    private var servers: [PairedServer] {
        serverStore.servers
    }

    var body: some View {
        List {
            ForEach(servers) { server in
                serverSection(for: server)
            }
        }
        .accessibilityIdentifier("workspace.list")
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("Workspaces")
        .navigationDestination(for: WorkspaceNavTarget.self) { target in
            WorkspaceDetailView(workspace: target.workspace)
                .onAppear {
                    coordinator.switchToServer(target.serverId)
                }
        }
        .navigationDestination(for: PairedServer.self) { server in
            ServerDetailView(server: server)
        }
        .sheet(item: $createSheetContext, onDismiss: handleCreateSheetDismissed) { context in
            WorkspaceCreateView(
                server: context.server,
                presentation: context.presentation,
                onCreate: { workspace in
                    guard context.openWorkspaceAfterCreate else { return }
                    pendingCreatedWorkspaceTarget = WorkspaceNavTarget(
                        serverId: context.server.id,
                        workspace: workspace
                    )
                }
            )
        }
        .refreshable {
            await refresh(force: true)
        }
        .overlay {
            if servers.isEmpty {
                ContentUnavailableView(
                    "No Servers",
                    systemImage: "server.rack",
                    description: Text("Pair with a server to get started.")
                )
            } else if allWorkspacesEmpty {
                emptyWorkspacesView
            }
        }
        .task {
            await refresh(force: false)
            triggerGuidedCreateIfNeeded()
        }
        .onChange(of: navigation.selectedTab) { _, selectedTab in
            guard selectedTab == .workspaces else { return }
            refreshIfWorkspaceHomeIsVisible()
        }
        .onChange(of: navigation.workspacePath.count) { oldCount, newCount in
            guard oldCount > 0, newCount == 0 else { return }
            refreshIfWorkspaceHomeIsVisible()
        }
        .onAppear {
            if !appLaunchMetricRecorded {
                appLaunchMetricRecorded = true
                ChatSessionTelemetry.recordAppLaunch()
            }
        }
    }

    // MARK: - Server Section

    @ViewBuilder
    private func serverSection(for server: PairedServer) -> some View {
        let serverId = server.id
        let serverConn = coordinator.connection(for: serverId)
        let workspaceCatalog = workspacesForServer(serverId)
        let isCollapsed = collapsedServerIds.contains(serverId)
        let summaries = serverConn?.workspaceStore.workspaceSummaries(forServer: serverId) ?? [:]
        let workspaces = isCollapsed ? workspaceCatalog : sortedWorkspaces(workspaceCatalog, summaries: summaries)
        let rawFreshness = serverConn?.workspaceStore.freshnessState(forServer: serverId) ?? .offline
        let rawFreshnessLabel = serverConn?.workspaceStore.freshnessLabel(forServer: serverId) ?? "Offline"
        let statusPresentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: rawFreshness,
            freshnessLabel: rawFreshnessLabel,
            isTransportConnected: serverConn?.isConnected == true,
            hasCachedCatalog: !workspaceCatalog.isEmpty
        )
        let freshness = statusPresentation.state
        let freshnessLabel = statusPresentation.label
        let isUnreachable = statusPresentation.isUnreachable

        Section {
            if !isCollapsed {
                if workspaces.isEmpty {
                    Text(isUnreachable ? "Offline — cached workspaces unavailable" : "No workspaces")
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                        .listRowBackground(Color.themeBg)
                } else {
                    ForEach(workspaces) { workspace in
                        let summary = summaryForWorkspace(workspace.id, in: summaries)
                        NavigationLink(value: WorkspaceNavTarget(serverId: serverId, workspace: workspace)) {
                            WorkspaceHomeRow(
                                workspace: workspace,
                                activeCount: summary.activeCount,
                                stoppedCount: summary.stoppedCount,
                                hasAttention: summary.hasAttention,
                                isUnreachable: isUnreachable,
                                badgeIcon: server.resolvedBadgeIcon,
                                badgeColor: server.resolvedBadgeColor
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.themeBg)
                        // Never disable read-only navigation — cached data
                        // should always be browsable even when the server
                        // is unreachable (e.g. phone on cellular after a run).
                    }
                }
            }
        } header: {
            HStack(spacing: 8) {
                Button {
                    toggleServerExpansion(for: serverId)
                } label: {
                    ServerSectionHeader(
                        server: server,
                        freshnessState: freshness,
                        freshnessLabel: freshnessLabel,
                        isCollapsed: isCollapsed
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                NavigationLink(value: server) {
                    Image(systemName: "chevron.right")
                        .font(.appCaption)
                        .foregroundStyle(.themeComment)
                        .frame(width: 30, height: 30)
                        .background(.themeComment.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Server settings for \(server.name)")

                Button {
                    presentCreateWorkspace(on: server)
                } label: {
                    Image(systemName: "plus")
                        .font(.appButton)
                        .foregroundStyle(.themeBlue)
                        .frame(width: 32, height: 32)
                        .background(.themeComment.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Create workspace on \(server.name)")
                .disabled(isUnreachable)
                .opacity(isUnreachable ? 0.5 : 1)
            }
        }
    }

    // MARK: - Data

    private var allWorkspacesEmpty: Bool {
        coordinator.connections.values.allSatisfy { conn in
            conn.workspaceStore.workspaces.isEmpty
        }
    }

    private func workspacesForServer(_ serverId: String) -> [Workspace] {
        coordinator.connection(for: serverId)?.workspaceStore.workspaces ?? []
    }

    private func sortedWorkspaces(
        _ workspaces: [Workspace],
        summaries: [String: WorkspaceListSummary]
    ) -> [Workspace] {
        workspaces.sorted { lhs, rhs in
            let lhsSummary = summaryForWorkspace(lhs.id, in: summaries)
            let rhsSummary = summaryForWorkspace(rhs.id, in: summaries)

            if lhsSummary.hasAttention != rhsSummary.hasAttention {
                return lhsSummary.hasAttention
            }
            if (lhsSummary.activeCount > 0) != (rhsSummary.activeCount > 0) {
                return lhsSummary.activeCount > 0
            }
            return (lhsSummary.latestActivity ?? .distantPast) > (rhsSummary.latestActivity ?? .distantPast)
        }
    }

    // MARK: - Session Helpers

    private func summaryForWorkspace(
        _ workspaceId: String,
        in summaries: [String: WorkspaceListSummary]
    ) -> WorkspaceListSummary {
        summaries[workspaceId] ?? WorkspaceListSummary(
            workspaceId: workspaceId,
            activeCount: 0,
            stoppedCount: 0,
            hasAttention: false
        )
    }

    private func toggleServerExpansion(for serverId: String) {
        withAnimation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
            if collapsedServerIds.contains(serverId) {
                collapsedServerIds.remove(serverId)
            } else {
                collapsedServerIds.insert(serverId)
            }
        }
    }

    private func refresh(force: Bool) async {
        if !force {
            guard !hasPerformedInitialRefresh else { return }
            hasPerformedInitialRefresh = true
        }

        // Unified path: coordinator handles single- and multi-server refresh.
        await coordinator.refreshAllServers()
    }

    private func refreshIfWorkspaceHomeIsVisible() {
        guard navigation.selectedTab == .workspaces else { return }
        guard navigation.workspacePath.count == 0 else { return }

        Task { @MainActor in
            await refresh(force: true)
        }
    }

    // MARK: - Guided Workspace Creation

    private func presentCreateWorkspace(
        on server: PairedServer,
        presentation: WorkspaceCreatePresentation = .standard,
        openWorkspaceAfterCreate: Bool = false
    ) {
        createSheetContext = WorkspaceCreateSheetContext(
            server: server,
            presentation: presentation,
            openWorkspaceAfterCreate: openWorkspaceAfterCreate
        )
    }

    private func handleCreateSheetDismissed() {
        guard let target = pendingCreatedWorkspaceTarget else { return }
        pendingCreatedWorkspaceTarget = nil
        navigation.selectedTab = .workspaces
        navigation.workspacePath = NavigationPath()
        navigation.workspacePath.append(target)
    }

    /// After a fresh pairing, auto-present WorkspaceCreateView if the server has no workspaces.
    private func triggerGuidedCreateIfNeeded() {
        guard navigation.shouldGuideWorkspaceCreation, !guidedCreateConsumed else { return }
        guard allWorkspacesEmpty else {
            // Server already has workspaces — nothing to guide.
            navigation.shouldGuideWorkspaceCreation = false
            return
        }
        guard let server = servers.first else { return }

        guidedCreateConsumed = true
        navigation.shouldGuideWorkspaceCreation = false
        presentCreateWorkspace(
            on: server,
            presentation: .guidedFirstWorkspace,
            openWorkspaceAfterCreate: true
        )
    }

    /// Empty state shown when servers exist but all workspaces are empty.
    private var emptyWorkspacesView: some View {
        ContentUnavailableView {
            Label("No Workspaces", systemImage: "square.grid.2x2")
        } description: {
            Text("A workspace tells Oppi which folder to work in. Create your first one from a project folder, a manual path, or a blank setup.")
        } actions: {
            if let server = servers.first {
                Button("Create First Workspace") {
                    presentCreateWorkspace(on: server)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Server Section Header

private struct ServerSectionHeader: View {
    let server: PairedServer
    let freshnessState: FreshnessState
    let freshnessLabel: String
    let isCollapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .animation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion), value: isCollapsed)

            HStack(spacing: 6) {
                RuntimeBadge(
                    compact: true,
                    icon: server.resolvedBadgeIcon,
                    badgeColor: server.resolvedBadgeColor
                )
                Text(server.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)
            }

            Spacer()

            FreshnessChip(state: freshnessState, label: freshnessLabel)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Workspace Home Row

private struct WorkspaceHomeRow: View {
    let workspace: Workspace
    let activeCount: Int
    let stoppedCount: Int
    let hasAttention: Bool
    var isUnreachable: Bool = false
    var badgeIcon: ServerBadgeIcon = .defaultValue
    var badgeColor: ServerBadgeColor = .defaultValue

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceIcon(icon: workspace.icon, size: 28)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(workspace.name)
                        .font(.headline)
                        .foregroundStyle(.themeFg)

                    if workspace.runtime == .sandbox {
                        Text("SANDBOX")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.themeOrange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.themeOrange.opacity(0.15), in: Capsule())
                    }

                    if hasAttention {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.themeOrange)
                            .font(.caption)
                    }
                }

                HStack(spacing: 8) {
                    RuntimeBadge(compact: true, icon: badgeIcon, badgeColor: badgeColor)

                    if isUnreachable {
                        Label("Offline", systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }

                    if activeCount > 0 {
                        Label("\(activeCount) active", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(isUnreachable ? .themeComment : .themeGreen)
                    }

                    if stoppedCount > 0 {
                        Label("\(stoppedCount) stopped", systemImage: "stop.circle")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }

                    if !isUnreachable && activeCount == 0 && stoppedCount == 0 {
                        Text("No sessions")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }

                if let desc = workspace.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
