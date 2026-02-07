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
                .listRowBackground(Color.tokyoBg)
            }
            .onDelete { indexSet in
                Task { await deleteSessions(at: indexSet) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.tokyoBg)
        .navigationTitle("Sessions")
        .navigationDestination(for: String.self) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .refreshable {
            await refreshSessions()
        }
        .overlay {
            if sessionStore.sessions.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 40))
                        .foregroundStyle(.tokyoComment)
                    Text("No Sessions")
                        .font(.title3.bold())
                        .foregroundStyle(.tokyoFg)
                    Text("Create a session to start working with pi.")
                        .font(.subheadline)
                        .foregroundStyle(.tokyoComment)
                }
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
        guard let api = connection.apiClient else {
            return
        }
        do {
            let sessions = try await api.listSessions()
            sessionStore.sessions = sessions
        } catch {
            // Keep cached list on error
        }
    }

    private func deleteSessions(at offsets: IndexSet) async {
        guard let api = connection.apiClient else {
            return
        }
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
        HStack(alignment: .top, spacing: 12) {
            // Status indicator — pulsing when busy
            Circle()
                .fill(session.status.color)
                .frame(width: 10, height: 10)
                .opacity(session.status == .busy ? 0.8 : 1)
                .animation(
                    session.status == .busy
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: session.status
                )
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                // Row 1: Name + permission badge
                HStack {
                    Text(session.name ?? shortId(session.id))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tokyoFg)
                        .lineLimit(1)
                    Spacer()
                    if pendingCount > 0 {
                        Label("\(pendingCount)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(.tokyoOrange)
                    }
                    Text(session.lastActivity.relativeString())
                        .font(.caption2)
                        .foregroundStyle(.tokyoComment)
                }

                // Row 2: workspace + model
                HStack(spacing: 4) {
                    if let wsName = session.workspaceName {
                        Text(wsName)
                            .font(.caption.bold())
                            .foregroundStyle(.tokyoBlue)
                    }

                    if let model = session.model {
                        if session.workspaceName != nil {
                            Text("·")
                                .foregroundStyle(.tokyoComment)
                        }
                        Text(model.split(separator: "/").last.map(String.init) ?? model)
                            .font(.caption)
                            .foregroundStyle(.tokyoComment)
                    }
                }

                // Row 3: last message preview
                if let lastMessage = session.lastMessage {
                    Text(lastMessage)
                        .font(.caption)
                        .foregroundStyle(.tokyoFgDim)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func shortId(_ id: String) -> String {
        "Session \(String(id.prefix(8)))"
    }
}
