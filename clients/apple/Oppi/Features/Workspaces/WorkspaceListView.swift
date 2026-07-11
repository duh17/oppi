import OSLog
import SwiftUI

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "WorkspaceList")

/// Workspace management list for a single server.
///
/// Reached from ServerDetailView. Shows the server's workspaces
/// with edit/delete and a create button.
struct WorkspaceListView: View {
    let server: PairedServer

    @Environment(ConnectionCoordinator.self) private var coordinator
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
                    WorkspaceRowView(workspace: workspace)
                }
                .accessibilityIdentifier("server.workspace.\(workspace.id)")
            }
            .onDelete { offsets in
                Task { await deleteWorkspaces(at: offsets) }
            }
        }
        .themedListSurface()
        .accessibilityIdentifier("server.workspaceList")
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("server.workspace.create")
            }
        }
        .sheet(isPresented: $showCreate) {
            WorkspaceCreateView(server: server)
        }
        .refreshable {
            if let connection = coordinator.connection(for: server.id) {
                await connection.refreshWorkspaceCatalog(force: true)
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
                logger.error("Delete failed for \(workspace.id.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Row

private struct WorkspaceRowView: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceRuntimeIcon(workspace: workspace, size: 24, frameSize: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name)
                    .font(.headline)

                if let description = workspace.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }

                Text(workspace.hostMount ?? "Server home folder")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
