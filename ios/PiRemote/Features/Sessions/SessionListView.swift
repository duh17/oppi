import SwiftUI

struct SessionListView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore

    @State private var showNewSession = false

    var body: some View {
        List {
            ForEach(sessionStore.sessions) { session in
                NavigationLink(value: session.id) {
                    SessionRowView(
                        session: session,
                        pendingCount: permissionStore.pending(for: session.id).count
                    )
                }
            }
            .onDelete { indexSet in
                Task { await deleteSessions(at: indexSet) }
            }
        }
        .navigationTitle("Sessions")
        .navigationDestination(for: String.self) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .refreshable {
            await refreshSessions()
        }
        .overlay {
            if sessionStore.sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text("Create a session to start working with pi.")
                )
            }
        }
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            Button {
                showNewSession = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.bold())
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())
            .shadow(radius: 4, y: 2)
            .padding()
        }
        .sheet(isPresented: $showNewSession) {
            WorkspacePickerView()
        }
    }

    private func refreshSessions() async {
        guard let api = connection.apiClient else { return }
        do {
            let sessions = try await api.listSessions()
            sessionStore.sessions = sessions
        } catch {
            // Keep cached list on error
        }
    }

    private func deleteSessions(at offsets: IndexSet) async {
        guard let api = connection.apiClient else { return }
        let sessionsToDelete = offsets.map { sessionStore.sessions[$0] }

        // Optimistic local remove first for responsive UX
        for session in sessionsToDelete {
            sessionStore.remove(id: session.id)
        }

        // Then delete on server
        for session in sessionsToDelete {
            do {
                try await api.deleteSession(id: session.id)
            } catch {
                // Re-add on failure — next refresh will reconcile
                print("[delete] failed for \(session.id): \(error)")
            }
        }
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let session: Session
    let pendingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(session.name ?? "Session \(session.id)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if pendingCount > 0 {
                    Label("\(pendingCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 4) {
                if let wsName = session.workspaceName {
                    Text(wsName)
                        .font(.caption.bold())
                        .foregroundStyle(.tokyoBlue)
                    Text("•")
                        .foregroundStyle(.secondary)
                }

                Text(session.status.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let model = session.model {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(model.split(separator: "/").last.map(String.init) ?? model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastMessage = session.lastMessage {
                Text(lastMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(session.lastActivity.relativeString())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch session.status {
        case .ready: return .green
        case .busy: return .yellow
        case .starting: return .blue
        case .error: return .red
        case .stopped: return .gray
        }
    }
}
