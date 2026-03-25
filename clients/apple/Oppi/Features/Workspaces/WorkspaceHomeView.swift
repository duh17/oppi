import SwiftUI

/// Navigation target pairing a workspace with its server for on-demand connection switching.
struct WorkspaceNavTarget: Hashable {
    let serverId: String
    let workspace: Workspace
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

    @State private var createOnServer: PairedServer?
    @State private var collapsedServerIds: Set<String> = []
    /// Guards against re-presenting the guided create after the user dismisses it.
    @State private var guidedCreateConsumed = false

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
        .sheet(item: $createOnServer) { server in
            WorkspaceCreateView(server: server)
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
        .onAppear {
            if !appLaunchMetricRecorded {
                appLaunchMetricRecorded = true
                let processStartDate = ProcessInfo.processInfo.processStartDate
                let launchMs = Int64(max(0, Date().timeIntervalSince(processStartDate) * 1_000))
                ChatSessionTelemetry.recordAppLaunch(durationMs: launchMs)
            }
            Task { await refresh(force: false) }
        }
    }

    // MARK: - Server Section

    @ViewBuilder
    private func serverSection(for server: PairedServer) -> some View {
        let serverId = server.id
        let workspaces = sortedWorkspaces(for: serverId)
        let serverConn = coordinator.connection(for: serverId)
        let freshness = serverConn?.workspaceStore.freshnessState(forServer: serverId) ?? .offline
        let freshnessLabel = serverConn?.workspaceStore.freshnessLabel(forServer: serverId) ?? "Offline"
        let isUnreachable = freshness == .offline
        let isCollapsed = collapsedServerIds.contains(serverId)

        Section {
            if !isCollapsed {
                if workspaces.isEmpty {
                    Text(isUnreachable ? "Offline — cached workspaces unavailable" : "No workspaces")
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(workspaces) { workspace in
                        NavigationLink(value: WorkspaceNavTarget(serverId: serverId, workspace: workspace)) {
                            WorkspaceHomeRow(
                                workspace: workspace,
                                activeCount: activeCount(for: workspace.id, serverId: serverId),
                                stoppedCount: stoppedCount(for: workspace.id, serverId: serverId),
                                hasAttention: hasAttention(for: workspace.id, serverId: serverId),
                                isUnreachable: isUnreachable,
                                badgeIcon: server.resolvedBadgeIcon,
                                badgeColor: server.resolvedBadgeColor
                            )
                        }
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
                    createOnServer = server
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

    private func sortedWorkspaces(for serverId: String) -> [Workspace] {
        workspacesForServer(serverId).sorted { lhs, rhs in
            let lhsActive = activeCount(for: lhs.id, serverId: serverId)
            let rhsActive = activeCount(for: rhs.id, serverId: serverId)
            let lhsAttn = hasAttention(for: lhs.id, serverId: serverId)
            let rhsAttn = hasAttention(for: rhs.id, serverId: serverId)

            if lhsAttn != rhsAttn { return lhsAttn }
            if (lhsActive > 0) != (rhsActive > 0) { return lhsActive > 0 }
            return latestActivity(for: lhs.id, serverId: serverId) > latestActivity(for: rhs.id, serverId: serverId)
        }
    }

    // MARK: - Session Helpers

    /// Sessions for a workspace on a specific server.
    ///
    /// Routes to the server's own SessionStore (per-server connections).
    private func sessionsFor(_ workspaceId: String, serverId: String) -> [Session] {
        let conn = coordinator.connection(for: serverId)
        return (conn?.sessionStore.sessions ?? []).filter { $0.workspaceId == workspaceId }
    }

    private func activeCount(for workspaceId: String, serverId: String) -> Int {
        sessionsFor(workspaceId, serverId: serverId).filter { $0.status != .stopped }.count
    }

    private func stoppedCount(for workspaceId: String, serverId: String) -> Int {
        sessionsFor(workspaceId, serverId: serverId).filter { $0.status == .stopped }.count
    }

    private func hasAttention(for workspaceId: String, serverId: String) -> Bool {
        let conn = coordinator.connection(for: serverId)
        let serverPermissions = conn?.permissionStore.pending ?? []
        return sessionsFor(workspaceId, serverId: serverId).contains { session in
            serverPermissions.contains { $0.sessionId == session.id }
            || session.status == .error
        }
    }

    private func latestActivity(for workspaceId: String, serverId: String) -> Date {
        sessionsFor(workspaceId, serverId: serverId).map(\.lastActivity).max() ?? .distantPast
    }

    private func toggleServerExpansion(for serverId: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if collapsedServerIds.contains(serverId) {
                collapsedServerIds.remove(serverId)
            } else {
                collapsedServerIds.insert(serverId)
            }
        }
    }

    // periphery:ignore:parameters force
    private func refresh(force: Bool) async {
        // Unified path: coordinator handles single- and multi-server refresh
        await coordinator.refreshAllServers()
    }

    // MARK: - Guided Workspace Creation

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
        createOnServer = server
    }

    /// Empty state shown when servers exist but all workspaces are empty.
    private var emptyWorkspacesView: some View {
        ContentUnavailableView {
            Label("No Workspaces", systemImage: "square.grid.2x2")
        } description: {
            Text("Create a workspace to start coding with your agent.")
        } actions: {
            if let server = servers.first {
                Button("Create Workspace") {
                    createOnServer = server
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .animation(.easeInOut(duration: 0.2), value: isCollapsed)

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
