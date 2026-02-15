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
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore
    @Environment(ServerStore.self) private var serverStore

    @State private var showNewWorkspace = false

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
                    if let server = serverStore.server(for: target.serverId) {
                        connection.switchServer(to: server)
                    }
                }
        }
        .navigationDestination(for: PairedServer.self) { server in
            ServerDetailView(server: server)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewWorkspace = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewWorkspace) {
            WorkspaceCreateView()
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
        let workspaces = sortedWorkspaces(for: server.id)
        let freshness = connection.workspaceStore.freshnessState(forServer: server.id)
        let freshnessLabel = connection.workspaceStore.freshnessLabel(forServer: server.id)
        let isUnreachable = freshness == .offline

        Section {
            if workspaces.isEmpty && !isUnreachable {
                Text("No workspaces")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(workspaces) { workspace in
                    NavigationLink(value: WorkspaceNavTarget(serverId: server.id, workspace: workspace)) {
                        WorkspaceHomeRow(
                            workspace: workspace,
                            activeCount: activeCount(for: workspace.id),
                            stoppedCount: stoppedCount(for: workspace.id),
                            hasAttention: hasAttention(for: workspace.id),
                            isUnreachable: isUnreachable
                        )
                    }
                    .disabled(isUnreachable)
                }
            }
        } header: {
            NavigationLink(value: server) {
                ServerSectionHeader(
                    server: server,
                    freshnessState: freshness,
                    freshnessLabel: freshnessLabel
                )
            }
            .buttonStyle(.plain)
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
            let lhsActive = activeCount(for: lhs.id)
            let rhsActive = activeCount(for: rhs.id)
            let lhsAttn = hasAttention(for: lhs.id)
            let rhsAttn = hasAttention(for: rhs.id)

            if lhsAttn != rhsAttn { return lhsAttn }
            if (lhsActive > 0) != (rhsActive > 0) { return lhsActive > 0 }
            return latestActivity(for: lhs.id) > latestActivity(for: rhs.id)
        }
    }

    // MARK: - Session Helpers

    private func sessionsFor(_ workspaceId: String) -> [Session] {
        sessionStore.sessions.filter { $0.workspaceId == workspaceId }
    }

    private func activeCount(for workspaceId: String) -> Int {
        sessionsFor(workspaceId).filter { $0.status != .stopped }.count
    }

    private func stoppedCount(for workspaceId: String) -> Int {
        sessionsFor(workspaceId).filter { $0.status == .stopped }.count
    }

    private func hasAttention(for workspaceId: String) -> Bool {
        sessionsFor(workspaceId).contains { session in
            !permissionStore.pending(for: session.id).isEmpty
            || session.status == .error
        }
    }

    private func latestActivity(for workspaceId: String) -> Date {
        sessionsFor(workspaceId).map(\.lastActivity).max() ?? .distantPast
    }

    private func refresh(force: Bool) async {
        if serverStore.servers.count > 1 {
            await connection.workspaceStore.loadAll(servers: serverStore.servers)
        } else {
            await connection.refreshWorkspaceAndSessionLists(force: force)
            // Sync per-server data from flat lists
            if let serverId = connection.currentServerId {
                connection.workspaceStore.workspacesByServer[serverId] = connection.workspaceStore.workspaces
                connection.workspaceStore.skillsByServer[serverId] = connection.workspaceStore.skills
                if !connection.workspaceStore.serverOrder.contains(serverId) {
                    connection.workspaceStore.serverOrder = [serverId]
                }
                connection.workspaceStore.serverFreshness[serverId] = ServerSyncState()
                connection.workspaceStore.serverFreshness[serverId]?.markSyncSucceeded()
            }
        }
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
                Image(systemName: "server.rack")
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                Text(server.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            FreshnessChip(state: freshnessState, label: freshnessLabel)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch freshnessState {
        case .live: return .green
        case .syncing: return .blue
        case .stale: return .orange
        case .offline: return .red
        }
    }
}

// MARK: - Workspace Home Row

private struct WorkspaceHomeRow: View {
    let workspace: Workspace
    let activeCount: Int
    let stoppedCount: Int
    let hasAttention: Bool
    var isUnreachable: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceIcon(icon: workspace.icon, size: 28)
                .frame(width: 40, height: 40)
                .opacity(isUnreachable ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(workspace.name)
                        .font(.headline)
                        .foregroundStyle(isUnreachable ? .secondary : .primary)

                    if hasAttention {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                HStack(spacing: 8) {
                    RuntimeBadge(runtime: workspace.runtime, compact: true)

                    if isUnreachable {
                        Text("Unreachable")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if activeCount > 0 {
                        Label("\(activeCount) active", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if stoppedCount > 0 {
                        Label("\(stoppedCount) stopped", systemImage: "stop.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
