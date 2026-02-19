import SwiftUI

/// Navigation target pairing a workspace with its server for on-demand connection switching.
struct WorkspaceNavTarget: Hashable {
    let serverId: String
    let workspace: Workspace
}

/// Top-level workspace list — primary navigation tab.
///
/// Shows workspaces grouped by server. Each server section has a tappable header
/// with name and freshness state. Tapping a workspace connects to that server
/// on demand and navigates to the workspace detail.
struct WorkspaceHomeView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore
    @Environment(ServerStore.self) private var serverStore

    @State private var createOnServer: PairedServer?

    private var servers: [PairedServer] {
        serverStore.servers
    }

    var body: some View {
        List {
            ForEach(servers) { server in
                serverSection(for: server)
            }
        }
        .listStyle(.insetGrouped)
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
                ContentUnavailableView(
                    "No Workspaces",
                    systemImage: "square.grid.2x2",
                    description: Text("Tap + to create a workspace.")
                )
            }
        }
        .task {
            await refresh(force: false)
        }
    }

    // MARK: - Server Section

    @ViewBuilder
    private func serverSection(for server: PairedServer) -> some View {
        let serverId = server.id
        let workspaces = sortedWorkspaces(for: serverId)
        let freshness = connection.workspaceStore.freshnessState(forServer: serverId)
        let freshnessLabel = connection.workspaceStore.freshnessLabel(forServer: serverId)
        let isUnreachable = freshness == .offline

        Section {
            if workspaces.isEmpty && !isUnreachable {
                Text("No workspaces")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
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
                    .disabled(isUnreachable)
                }
            }
        } header: {
            HStack(spacing: 0) {
                NavigationLink(value: server) {
                    ServerSectionHeader(
                        server: server,
                        freshnessState: freshness,
                        freshnessLabel: freshnessLabel
                    )
                }
                .buttonStyle(.plain)

                Button {
                    createOnServer = server
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .padding(.leading, 8)
                }
                .buttonStyle(.plain)
                .disabled(isUnreachable)
            }
        }
    }

    // MARK: - Data

    private var allWorkspacesEmpty: Bool {
        connection.workspaceStore.workspacesByServer.values.allSatisfy { $0.isEmpty }
    }

    private func workspacesForServer(_ serverId: String) -> [Workspace] {
        connection.workspaceStore.workspacesByServer[serverId] ?? []
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
    /// Uses per-server session query so non-active servers show correct counts
    /// instead of always reading from the active partition.
    private func sessionsFor(_ workspaceId: String, serverId: String) -> [Session] {
        sessionStore.sessions(forServer: serverId).filter { $0.workspaceId == workspaceId }
    }

    private func activeCount(for workspaceId: String, serverId: String) -> Int {
        sessionsFor(workspaceId, serverId: serverId).filter { $0.status != .stopped }.count
    }

    private func stoppedCount(for workspaceId: String, serverId: String) -> Int {
        sessionsFor(workspaceId, serverId: serverId).filter { $0.status == .stopped }.count
    }

    private func hasAttention(for workspaceId: String, serverId: String) -> Bool {
        let serverPermissions = permissionStore.pending(forServer: serverId)
        return sessionsFor(workspaceId, serverId: serverId).contains { session in
            serverPermissions.contains { $0.sessionId == session.id }
            || session.status == .error
        }
    }

    private func latestActivity(for workspaceId: String, serverId: String) -> Date {
        sessionsFor(workspaceId, serverId: serverId).map(\.lastActivity).max() ?? .distantPast
    }

    private func refresh(force: Bool) async {
        // Unified path: coordinator handles single- and multi-server refresh
        await coordinator.refreshAllServers()
    }
}

// MARK: - Server Section Header

private struct ServerSectionHeader: View {
    let server: PairedServer
    let freshnessState: FreshnessState
    let freshnessLabel: String

    var body: some View {
        HStack(spacing: 8) {
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

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                .opacity(isUnreachable ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(workspace.name)
                        .font(.headline)
                        .foregroundStyle(isUnreachable ? .themeComment : .themeFg)

                    if hasAttention {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                HStack(spacing: 8) {
                    RuntimeBadge(compact: true, icon: badgeIcon, badgeColor: badgeColor)

                    if isUnreachable {
                        Text("Unreachable")
                            .font(.caption)
                            .foregroundStyle(.themeRed)
                    } else if activeCount > 0 {
                        Label("\(activeCount) active", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.themeGreen)
                    }

                    if stoppedCount > 0 {
                        Label("\(stoppedCount) stopped", systemImage: "stop.circle")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }

                    if !isUnreachable && activeCount == 0 && stoppedCount == 0 {
                        Text("No sessions")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let desc = workspace.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
