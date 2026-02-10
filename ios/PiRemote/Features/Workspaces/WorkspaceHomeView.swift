import SwiftUI

/// Top-level workspace list — primary navigation tab.
///
/// Shows all workspaces with running/stopped session counts and attention indicators.
/// Tapping a workspace navigates to its detail view with session management.
struct WorkspaceHomeView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore

    @State private var showNewWorkspace = false

    private var workspaces: [Workspace] {
        connection.workspaceStore.workspaces
    }

    /// Workspaces sorted: those with active sessions first, then by most recent activity.
    private var sortedWorkspaces: [Workspace] {
        workspaces.sorted { lhs, rhs in
            let lhsActive = activeCount(for: lhs.id)
            let rhsActive = activeCount(for: rhs.id)

            let lhsAttn = hasAttention(for: lhs.id)
            let rhsAttn = hasAttention(for: rhs.id)

            // Attention first
            if lhsAttn != rhsAttn { return lhsAttn }
            // Then workspaces with active sessions
            if (lhsActive > 0) != (rhsActive > 0) { return lhsActive > 0 }
            // Then by most recent activity
            return latestActivity(for: lhs.id) > latestActivity(for: rhs.id)
        }
    }

    var body: some View {
        List {
            ForEach(sortedWorkspaces) { workspace in
                NavigationLink(value: workspace) {
                    WorkspaceHomeRow(
                        workspace: workspace,
                        activeCount: activeCount(for: workspace.id),
                        stoppedCount: stoppedCount(for: workspace.id),
                        hasAttention: hasAttention(for: workspace.id)
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Workspaces")
        .navigationDestination(for: Workspace.self) { workspace in
            WorkspaceDetailView(workspace: workspace)
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
            await refresh()
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
        .task {
            await refresh()
        }
    }

    // MARK: - Helpers

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
            permissionStore.pending(for: session.id).count > 0
            || session.status == .error
        }
    }

    private func latestActivity(for workspaceId: String) -> Date {
        sessionsFor(workspaceId).map(\.lastActivity).max() ?? .distantPast
    }

    private func refresh() async {
        guard let api = connection.apiClient else { return }
        await connection.workspaceStore.load(api: api)
        do {
            let sessions = try await api.listSessions()
            sessionStore.sessions = sessions
        } catch {
            // Keep cached data
        }
    }
}

// MARK: - Workspace Home Row

private struct WorkspaceHomeRow: View {
    let workspace: Workspace
    let activeCount: Int
    let stoppedCount: Int
    let hasAttention: Bool

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceIcon(icon: workspace.icon, size: 28)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(workspace.name)
                        .font(.headline)

                    if hasAttention {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                HStack(spacing: 8) {
                    RuntimeBadge(runtime: workspace.runtime, compact: true)

                    if activeCount > 0 {
                        Label("\(activeCount) active", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if stoppedCount > 0 {
                        Label("\(stoppedCount) stopped", systemImage: "stop.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if activeCount == 0 && stoppedCount == 0 {
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
