import SwiftUI

/// Workspace management list for a single server.
///
/// Reached from ServerDetailView. Shows the server's workspaces
/// with edit/delete and a create button.
struct WorkspaceListView: View {
    let server: PairedServer

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerConnection.self) private var connection
    @State private var showCreate = false

    private var workspaces: [Workspace] {
        coordinator.connection(for: server.id)?.workspaceStore.workspaces ?? []
    }

    var body: some View {
        List {
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
                Task { await deleteWorkspaces(at: offsets) }
            }
        }
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            WorkspaceCreateView(server: server)
        }
        .refreshable {
            if let conn = coordinator.connection(for: server.id),
               let api = conn.apiClient {
                await conn.workspaceStore.loadServer(serverId: server.id, api: api)
            }
        }
        .overlay {
            if workspaces.isEmpty {
                ContentUnavailableView(
                    "No Workspaces",
                    systemImage: "square.grid.2x2",
                    description: Text("Tap + to create one.")
                )
            }
        }
    }

    private func deleteWorkspaces(at offsets: IndexSet) async {
        guard let conn = coordinator.connection(for: server.id) else { return }
        guard let api = conn.apiClient else { return }
        let toDelete = offsets.map { workspaces[$0] }

        // Optimistic removal
        for workspace in toDelete {
            conn.workspaceStore.remove(id: workspace.id, serverId: server.id)
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
