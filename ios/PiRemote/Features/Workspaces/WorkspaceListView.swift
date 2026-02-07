import SwiftUI

/// Workspace management list. Reached from Settings or workspace picker.
struct WorkspaceListView: View {
    @Environment(ServerConnection.self) private var connection
    @State private var showNewWorkspace = false

    private var workspaces: [Workspace] {
        connection.workspaceStore.workspaces
    }

    var body: some View {
        List {
            ForEach(workspaces) { workspace in
                NavigationLink {
                    WorkspaceEditView(workspace: workspace)
                } label: {
                    WorkspaceRowView(workspace: workspace)
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
            guard let api = connection.apiClient else { return }
            await connection.workspaceStore.load(api: api)
        }
        .overlay {
            if workspaces.isEmpty {
                ContentUnavailableView(
                    "No Workspaces",
                    systemImage: "square.grid.2x2",
                    description: Text("Tap + to create a workspace.")
                )
            }
        }
    }

    private func deleteWorkspaces(at offsets: IndexSet) async {
        guard let api = connection.apiClient else { return }
        let toDelete = offsets.map { workspaces[$0] }

        for workspace in toDelete {
            connection.workspaceStore.remove(id: workspace.id)
        }

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

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceIcon(icon: workspace.icon, size: 24)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.headline)

                if let description = workspace.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Text("\(workspace.skills.count) skills")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text("•")
                        .foregroundStyle(.tertiary)

                    Text(workspace.policyPreset)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
