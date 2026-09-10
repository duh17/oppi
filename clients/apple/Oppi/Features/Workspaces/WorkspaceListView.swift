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
    @Environment(AppNavigation.self) private var navigation
    @State private var showCreate = false
    @State private var pendingDelete: Workspace?
    @State private var error: String?
    @State private var isDeleting = false

    private var workspaces: [Workspace] {
        coordinator.connection(for: server.id)?.workspaceStore.workspaces ?? []
    }

    var body: some View {
        List {
            ForEach(workspaces) { workspace in
                NavigationLink {
                    WorkspaceEditScopedDestinationView(server: server, workspace: workspace)
                } label: {
                    WorkspaceRowView(workspace: workspace)
                }
                .accessibilityIdentifier("server.workspace.\(workspace.id)")
                .swipeActions(edge: .trailing) {
                    Button(role: WorkspaceDeleteConfirmationPolicy.swipeButtonRole) {
                        pendingDelete = workspace
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.themeRed)
                    .disabled(isDeleting)
                }
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
            guard await coordinator.apiClientReady(for: server.id) != nil,
                  let connection = coordinator.connection(for: server.id) else { return }
            await connection.refreshWorkspaceCatalog(force: true)
        }
        .task {
            guard await coordinator.apiClientReady(for: server.id) != nil,
                  let connection = coordinator.connection(for: server.id) else { return }
            await connection.refreshWorkspaceCatalog(force: false)
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
        .confirmationDialog(
            "Delete Workspace?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDelete {
                Button("Delete Workspace", role: .destructive) {
                    WorkspaceDeleteConfirmationPolicy.confirm(
                        workspace: pendingDelete,
                        clearPending: { self.pendingDelete = nil },
                        performDelete: { workspace in
                            Task { await deleteWorkspace(workspace) }
                        }
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            if let pendingDelete {
                Text(WorkspaceDeleteConfirmationPolicy.deleteMessage(for: pendingDelete))
            }
        }
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func deleteWorkspace(_ workspace: Workspace) async {
        guard !isDeleting else { return }
        guard let conn = coordinator.connection(for: server.id) else { return }
        guard let api = conn.apiClient else {
            error = "Server is offline"
            return
        }

        isDeleting = true
        error = nil
        defer { isDeleting = false }

        do {
            try await api.deleteWorkspace(id: workspace.id)
            conn.workspaceStore.remove(id: workspace.id, serverId: server.id)
            navigation.leaveDeletedWorkspace(serverId: server.id, workspaceId: workspace.id)
        } catch {
            logger.error("Delete failed for \(workspace.id.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }
}

/// Defers WorkspaceEditView construction until the target transport and
/// server-scoped environment are ready. This prevents its initial `.task` and
/// `.onAppear` work from capturing the previously active server.
struct WorkspaceEditScopedDestinationView: View {
    let server: PairedServer
    let workspace: Workspace

    @Environment(ConnectionCoordinator.self) private var coordinator
    @State private var scopedConnection: ServerConnection?

    var body: some View {
        Group {
            if let scopedConnection {
                WorkspaceEditView(workspace: workspace)
                    .withServerScopedEnvironment(scopedConnection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: server.id) {
            guard await coordinator.switchToServerReady(server) else { return }
            scopedConnection = coordinator.connection(for: server.id)
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
