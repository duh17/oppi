import SwiftUI

/// Detail view for a workspace — shows its sessions with management actions.
///
/// Sessions are grouped into active (running/busy/ready) and stopped.
/// Supports creating new sessions, resuming stopped ones, and stopping active ones.
struct WorkspaceDetailView: View {
    let workspace: Workspace

    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore

    @State private var isCreating = false
    @State private var error: String?

    // MARK: - Computed

    private var workspaceSessions: [Session] {
        sessionStore.sessions.filter { $0.workspaceId == workspace.id }
    }

    private var activeSessions: [Session] {
        workspaceSessions
            .filter { $0.status != .stopped }
            .sorted { lhs, rhs in
                let lhsAttn = permissionStore.pending(for: lhs.id).count > 0
                let rhsAttn = permissionStore.pending(for: rhs.id).count > 0
                if lhsAttn != rhsAttn { return lhsAttn }
                return lhs.lastActivity > rhs.lastActivity
            }
    }

    private var stoppedSessions: [Session] {
        workspaceSessions
            .filter { $0.status == .stopped }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: - Body

    var body: some View {
        List {
            workspaceInfoSection

            if !activeSessions.isEmpty {
                Section("Active") {
                    ForEach(activeSessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(
                                session: session,
                                pendingCount: permissionStore.pending(for: session.id).count
                            )
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await stopSession(session) }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .tint(.orange)
                        }
                    }
                }
            }

            if !stoppedSessions.isEmpty {
                Section("Stopped") {
                    ForEach(stoppedSessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session, pendingCount: 0)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await resumeSession(session) }
                            } label: {
                                Label("Resume", systemImage: "play.fill")
                            }
                            .tint(.green)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await deleteSession(session) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if workspaceSessions.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "terminal",
                        description: Text("Tap + to start a new session in this workspace.")
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(workspace.name)
        .navigationDestination(for: String.self) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await createSession() }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(isCreating)
            }

            ToolbarItem(placement: .secondaryAction) {
                NavigationLink {
                    WorkspaceEditView(workspace: workspace)
                } label: {
                    Label("Edit Workspace", systemImage: "pencil")
                }
            }
        }
        .refreshable {
            await refreshSessions()
        }
        .overlay {
            if isCreating {
                ProgressView("Creating session...")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

    // MARK: - Workspace Info

    private var workspaceInfoSection: some View {
        Section {
            HStack(spacing: 12) {
                WorkspaceIcon(icon: workspace.icon, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    if let desc = workspace.description, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        RuntimeBadge(runtime: workspace.runtime, compact: true)
                        Text("\(workspace.skills.count) skills")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if let model = workspace.defaultModel {
                            Text(model.split(separator: "/").last.map(String.init) ?? model)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func createSession() async {
        guard let api = connection.apiClient else { return }
        isCreating = true
        error = nil

        do {
            let session = try await api.createWorkspaceSession(workspaceId: workspace.id)
            sessionStore.upsert(session)
            isCreating = false
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }

    private func stopSession(_ session: Session) async {
        guard let api = connection.apiClient else { return }
        do {
            let updated = try await api.stopWorkspaceSession(workspaceId: workspace.id, sessionId: session.id)
            sessionStore.upsert(updated)
        } catch {
            self.error = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func resumeSession(_ session: Session) async {
        guard let api = connection.apiClient else { return }
        do {
            let updated = try await api.resumeWorkspaceSession(workspaceId: workspace.id, sessionId: session.id)
            sessionStore.upsert(updated)
        } catch {
            self.error = "Resume failed: \(error.localizedDescription)"
        }
    }

    private func deleteSession(_ session: Session) async {
        guard let api = connection.apiClient else { return }
        sessionStore.remove(id: session.id)
        do {
            try await api.deleteWorkspaceSession(workspaceId: workspace.id, sessionId: session.id)
        } catch {
            self.error = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func refreshSessions() async {
        guard let api = connection.apiClient else { return }
        do {
            let sessions = try await api.listWorkspaceSessions(workspaceId: workspace.id)
            for session in sessions {
                sessionStore.upsert(session)
            }
        } catch {
            // Keep cached data
        }
    }
}
