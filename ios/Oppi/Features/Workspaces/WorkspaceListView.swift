import SwiftUI

/// Workspace management list, grouped by server.
///
/// Reached from Settings or workspace picker. Each server section shows
/// its workspaces with edit/delete and a per-server create button.
struct WorkspaceListView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerConnection.self) private var connection
    @Environment(ServerStore.self) private var serverStore
    @State private var createOnServer: PairedServer?

    var body: some View {
        List {
            ForEach(serverStore.servers) { server in
                Section(server.name) {
                    let workspaces = connection.workspaceStore.workspacesByServer[server.id] ?? []
                    if workspaces.isEmpty {
                        Text("No workspaces")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(workspaces) { workspace in
                            NavigationLink {
                                WorkspaceEditView(workspace: workspace)
                                    .onAppear { coordinator.switchToServer(server) }
                            } label: {
                                WorkspaceRowView(
                                    workspace: workspace,
                                    badgeIcon: server.resolvedBadgeIcon,
                                    badgeColor: server.resolvedBadgeColor
                                )
                            }
                        }
                        .onDelete { offsets in
                            Task { await deleteWorkspaces(at: offsets, serverId: server.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Workspaces")
        .sheet(item: $createOnServer) { server in
            WorkspaceCreateView(server: server)
        }
        .refreshable {
            await coordinator.refreshAllServers()
        }
        .overlay {
            if serverStore.servers.allSatisfy({ (connection.workspaceStore.workspacesByServer[$0.id] ?? []).isEmpty }) {
                ContentUnavailableView(
                    "No Workspaces",
                    systemImage: "square.grid.2x2",
                    description: Text("Tap + on a server section to create one.")
                )
            }
        }
    }

    private func deleteWorkspaces(at offsets: IndexSet, serverId: String) async {
        let workspaces = connection.workspaceStore.workspacesByServer[serverId] ?? []
        guard let api = coordinator.apiClient(for: serverId) else { return }
        let toDelete = offsets.map { workspaces[$0] }

        // Optimistic removal
        for workspace in toDelete {
            connection.workspaceStore.remove(id: workspace.id, serverId: serverId)
            connection.workspaceStore.remove(id: workspace.id)
        }

        // Server-side delete
        for workspace in toDelete {
            do {
                try await api.deleteWorkspace(id: workspace.id)
            } catch {
                // Re-add on failure — next refresh reconciles
                print("[workspace] delete failed for \(workspace.id): \(error)")
            }
        }
    }
}

// MARK: - Row

private struct WorkspaceRowView: View {
    let workspace: Workspace
    var badgeIcon: ServerBadgeIcon = .defaultValue
    var badgeColor: ServerBadgeColor = .defaultValue

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceIcon(icon: workspace.icon, size: 24)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(workspace.name)
                        .font(.headline)
                    RuntimeBadge(compact: true, icon: badgeIcon, badgeColor: badgeColor)
                }

                if let description = workspace.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }

                Text("\(workspace.skills.count) skills")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
