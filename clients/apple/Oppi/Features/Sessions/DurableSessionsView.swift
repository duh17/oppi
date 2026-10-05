import SwiftUI

/// Durable Sessions experiment: the active server's durable sessions and a
/// way to start one. Rows and chats are the normal ones; All Sessions and
/// workspace lists still show these sessions too.
struct DurableSessionsView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.theme) private var theme
    @AppStorage(AppPreferences.Experiments.durableSessionsKey) private var experimentEnabled = false

    @State private var error: String?

    private var activeServerId: String? { coordinator.activeServerId }

    private var connection: ServerConnection? {
        activeServerId.flatMap { coordinator.connection(for: $0) }
    }

    private var isAvailable: Bool {
        DurableSessionsPlayground.isAvailable(
            experimentEnabled: experimentEnabled,
            serverOffersDurable: connection?.durableSessionsAvailable == true
        )
    }

    private var sessions: [Session] {
        DurableSessionsPlayground.sessions(from: connection?.sessionStore.listProjectionSessions ?? [])
    }

    var body: some View {
        List {
            if !isAvailable {
                Section {
                    ContentUnavailableView(
                        "Durable Sessions Unavailable",
                        systemImage: "infinity",
                        description: Text(experimentEnabled
                            ? "This server does not offer durable sessions. Turn on experimental.serverDurable on the server and restart it."
                            : "Turn on Settings → Experiments → Durable Sessions.")
                    )
                    .listRowBackground(theme.bg.primary)
                }
            } else if sessions.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Durable Sessions",
                        systemImage: "infinity",
                        description: Text("Start a durable session to try the server's durable engine.")
                    )
                    .listRowBackground(theme.bg.primary)
                }
            } else {
                Section {
                    ForEach(SessionListEntries.flat(sessions)) { entry in
                        row(entry)
                    }
                    Text("Durable sessions also appear in All Sessions and their workspace.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                        .listRowBackground(theme.bg.primary)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .accessibilityIdentifier("durableSessions.list")
        .listStyle(.plain)
        .themedListSurface()
        .navigationTitle("Durable")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startDurableSession()
                } label: {
                    Label("New durable session", systemImage: "square.and.pencil")
                }
                .disabled(!isAvailable || activeServerId == nil)
                .accessibilityIdentifier("durableSessions.new")
            }
        }
        .refreshable {
            guard let activeServerId else { return }
            await coordinator.refreshServer(activeServerId, force: true)
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

    private func row(_ entry: SessionListEntry) -> some View {
        SessionListEntryRow(
            entry: entry,
            presentation: presentation,
            hasPendingAsk: { pendingAskCount(for: $0.id) > 0 },
            foreignWorkspaceName: { _ in nil },
            actions: SessionListRowActions(
                open: open,
                // Flat entries carry no Thread strip or link.
                openThread: { _ in },
                stop: { session in Task { await stop(session) } },
                resume: { session in Task { await resume(session) } },
                delete: { _ in nil }
            )
        )
        .listRowBackground(theme.bg.primary)
    }

    private func workspace(for session: Session) -> Workspace? {
        guard let workspaceId = session.workspaceId else { return nil }
        return connection?.workspaceStore.workspaces.first { $0.id == workspaceId }
    }

    private func pendingAskCount(for sessionId: String) -> Int {
        guard let connection else { return 0 }
        return SessionListAttentionMerger.askCount(
            listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
            hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
            hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
        )
    }

    private func presentation(for session: Session) -> SessionRowPresentation {
        SessionRowPresentationBuilder.make(
            session: session,
            pendingAskCount: pendingAskCount(for: session.id),
            pendingAsk: connection?.askRequestStore.pending(for: session.id),
            workspaceContext: SessionInboxSessionRouting.allSessionsContext(
                for: session,
                workspaceName: workspace(for: session)?.name
            ),
            unreadCompletionAt: connection?.sessionStore.unreadCompletionDate(for: session.id),
            catalogModels: connection?.chatState.cachedModels ?? []
        )
    }

    private func open(_ session: Session) {
        guard let activeServerId, let connection,
              let routeScope = SessionInboxSessionRouting.routeScope(for: session) else {
            error = "Session route is unavailable"
            return
        }
        connection.sessionStore.cacheSessionForNavigation(session)
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: activeServerId, sessionId: session.id, routeScope: routeScope),
            workspace: workspace(for: session).map { WorkspaceNavTarget(serverId: activeServerId, workspace: $0) }
        )
    }

    private func stop(_ session: Session) async {
        guard let connection, let api = connection.apiClient,
              let routeScope = SessionInboxSessionRouting.routeScope(for: session) else { return }
        do {
            connection.sessionStore.upsert(try await api.stopSession(scope: routeScope, sessionId: session.id))
        } catch {
            self.error = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func resume(_ session: Session) async {
        guard let connection, let api = connection.apiClient,
              let routeScope = SessionInboxSessionRouting.routeScope(for: session) else { return }
        do {
            connection.sessionStore.upsert(try await api.resumeSession(scope: routeScope, sessionId: session.id))
        } catch {
            self.error = "Resume failed: \(error.localizedDescription)"
        }
    }

    /// Reuses Quick Session (workspace pick + prompt) with the durable engine.
    private func startDurableSession() {
        guard let activeServerId else { return }
        navigation.pendingQuickSessionLaunchContext = QuickSessionLaunchContext(durableOnServer: activeServerId)
        navigation.showQuickSession = true
    }
}
