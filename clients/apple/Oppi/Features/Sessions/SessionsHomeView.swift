import SwiftUI

private struct SessionsHomeRoute: Hashable {
    let serverId: String
    let sessionId: String
}

private struct SessionsHomeSessionRow: Identifiable, Equatable {
    var id: String { "\(serverId):\(session.id)" }
    let serverId: String
    let session: Session
    let pendingPermissionCount: Int
    let pendingAskCount: Int
}

private struct SessionsHomeWorkspaceGroup: Identifiable, Equatable {
    var id: String { "\(serverId):\(workspace.id)" }
    let serverId: String
    let workspace: Workspace
    let sessions: [SessionsHomeSessionRow]

    var pendingAttentionCount: Int {
        sessions.reduce(0) { total, row in
            total + row.pendingPermissionCount + row.pendingAskCount
        }
    }

    var latestActivity: Date {
        sessions.map(\.session.lastActivity).max() ?? .distantPast
    }
}

/// Top-level session-first home.
///
/// Shows the active cross-workspace feed first, then a small recent stopped
/// fallback. Workspaces remain available as the drill-down tab.
struct SessionsHomeView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation

    @State private var path = NavigationPath()
    @State private var activeGroups: [SessionsHomeWorkspaceGroup] = []
    @State private var recentRows: [SessionsHomeSessionRow] = []
    @State private var isRefreshing = false
    @State private var errorText: String?
    @State private var hasLoadedOnce = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !activeGroups.isEmpty {
                    activeSection
                }

                if !recentRows.isEmpty {
                    recentSection
                }
            }
            .accessibilityIdentifier("sessions.home.list")
            .listStyle(.insetGrouped)
            .themedListSurface()
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigation.showQuickSession = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Start Quick Session")
                }
            }
            .overlay {
                if activeGroups.isEmpty, recentRows.isEmpty, !isRefreshing {
                    emptyState
                }
            }
            .refreshable {
                await refresh(force: true)
            }
            .task {
                await refresh(force: false)
            }
            .navigationDestination(for: SessionsHomeRoute.self) { route in
                serverScopedChatDestination(route)
            }
        }
    }

    private var activeSection: some View {
        ForEach(activeGroups) { group in
            Section {
                ForEach(group.sessions) { row in
                    sessionButton(row: row, workspace: group.workspace, showWorkspaceContext: false)
                }
            } header: {
                workspaceHeader(group)
            }
        }
    }

    private var recentSection: some View {
        Section {
            ForEach(recentRows) { row in
                sessionButton(row: row, workspace: nil, showWorkspaceContext: true)
            }
        } header: {
            Text("Recent")
        }
    }

    @ViewBuilder
    private func serverScopedChatDestination(_ route: SessionsHomeRoute) -> some View {
        if let conn = coordinator.connection(for: route.serverId) {
            ChatView(sessionId: route.sessionId)
                .environment(conn)
                .environment(\.apiClient, conn.apiClient)
                .environment(conn.chatState)
                .environment(conn.sessionStore)
                .environment(conn.workspaceStore)
                .environment(conn.permissionStore)
                .environment(conn.askRequestStore)
                .environment(conn.audioPlayer)
                .environment(conn.gitStatusStore)
                .environment(conn.fileIndexStore)
                .environment(conn.messageQueueStore)
                .environment(conn.activityStore)
                .onAppear {
                    _ = coordinator.switchToServer(route.serverId)
                }
        } else {
            ContentUnavailableView(
                "Server Offline",
                systemImage: "wifi.slash",
                description: Text("Reconnect to open this session.")
            )
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Sessions", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text(errorText ?? "Start a quick session or open a workspace to begin.")
        } actions: {
            Button("Start Quick Session") {
                navigation.showQuickSession = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func workspaceHeader(_ group: SessionsHomeWorkspaceGroup) -> some View {
        HStack(spacing: 6) {
            if let icon = group.workspace.icon {
                Text(icon)
                    .font(.caption)
            }
            Text(group.workspace.name.uppercased())
                .font(.caption2.monospaced().weight(.semibold))
                .tracking(0.8)

            if coordinator.connections.count > 1 {
                Text(serverLabel(for: group.serverId))
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.themeComment.opacity(0.1), in: Capsule())
            }
        }
        .foregroundStyle(.themeComment)
    }

    private func sessionButton(
        row: SessionsHomeSessionRow,
        workspace: Workspace?,
        showWorkspaceContext: Bool
    ) -> some View {
        Button {
            open(row)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if showWorkspaceContext {
                    Text(row.session.workspaceName ?? workspace?.name ?? "Workspace")
                        .font(.caption2.monospaced().weight(.medium))
                        .foregroundStyle(.themeComment)
                        .textCase(.uppercase)
                }

                SessionRow(
                    session: row.session,
                    pendingCount: row.pendingPermissionCount,
                    pendingAskCount: row.pendingAskCount,
                    activitySummary: activitySummary(for: row)
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.themeBg)
    }

    private func activitySummary(for row: SessionsHomeSessionRow) -> String? {
        guard let conn = coordinator.connection(for: row.serverId) else { return nil }
        let permissions = conn.permissionStore.pending(for: row.session.id)
        return SessionActivitySummary.text(
            session: row.session,
            pendingCount: max(permissions.count, row.pendingPermissionCount),
            pendingPermissions: permissions,
            pendingAsk: conn.askRequestStore.pending(for: row.session.id),
            activity: conn.activityStore.lastActivity(for: row.session.id)
        )
    }

    private func open(_ row: SessionsHomeSessionRow) {
        guard coordinator.switchToServer(row.serverId) else { return }
        path.append(SessionsHomeRoute(serverId: row.serverId, sessionId: row.session.id))
    }

    private func refresh(force: Bool) async {
        guard force || !hasLoadedOnce else { return }
        hasLoadedOnce = true
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        var nextActiveGroups: [SessionsHomeWorkspaceGroup] = []
        var nextRecentRows: [SessionsHomeSessionRow] = []
        var sawSuccess = false

        for (serverId, conn) in coordinator.connections.sorted(by: { $0.key < $1.key }) {
            guard let api = conn.apiClient else {
                nextActiveGroups.append(contentsOf: fallbackActiveGroups(serverId: serverId, connection: conn))
                nextRecentRows.append(contentsOf: fallbackRecentRows(serverId: serverId, connection: conn))
                continue
            }

            do {
                let response = try await api.listGlobalActiveSessionGroups()
                sawSuccess = true
                let summaries = response.workspaces.flatMap { group in
                    group.sessions.map(\.summary)
                }
                conn.sessionStore.upsertManySummaries(summaries)
                nextActiveGroups.append(contentsOf: response.workspaces.map { group in
                    SessionsHomeWorkspaceGroup(
                        serverId: serverId,
                        workspace: group.workspace,
                        sessions: group.sessions.map { row in
                            SessionsHomeSessionRow(
                                serverId: serverId,
                                session: row.summary.session,
                                pendingPermissionCount: row.pendingPermissionCount,
                                pendingAskCount: row.pendingAskCount
                            )
                        }
                    )
                })
            } catch {
                nextActiveGroups.append(contentsOf: fallbackActiveGroups(serverId: serverId, connection: conn))
                errorText = error.localizedDescription
            }

            do {
                let summaries = try await api.listRecentWorkspaceSessionSummaries(recentDays: 3)
                sawSuccess = true
                conn.sessionStore.upsertManySummaries(summaries)
                nextRecentRows.append(contentsOf: summaries
                    .filter { $0.status == .stopped }
                    .map { summary in
                        SessionsHomeSessionRow(
                            serverId: serverId,
                            session: summary.session,
                            pendingPermissionCount: 0,
                            pendingAskCount: 0
                        )
                    })
            } catch {
                nextRecentRows.append(contentsOf: fallbackRecentRows(serverId: serverId, connection: conn))
                errorText = error.localizedDescription
            }
        }

        activeGroups = sortWorkspaceGroups(nextActiveGroups.filter { !$0.sessions.isEmpty })
        recentRows = sortRecentRows(nextRecentRows)
        if sawSuccess {
            errorText = nil
        }
    }

    private func fallbackActiveGroups(
        serverId: String,
        connection conn: ServerConnection
    ) -> [SessionsHomeWorkspaceGroup] {
        let activeSessions = conn.sessionStore.listProjectionSessions.filter { session in
            session.status != .stopped
        }
        let grouped = Dictionary(grouping: activeSessions) { $0.workspaceId ?? "" }

        return grouped.compactMap { workspaceId, sessions in
            guard let workspace = conn.workspaceStore.workspaces.first(where: { $0.id == workspaceId }) else {
                return nil
            }
            let rows = quickSessionSorted(
                sessions,
                hasPermission: { !conn.permissionStore.pending(for: $0).isEmpty },
                hasAsk: { conn.askRequestStore.hasPending(for: $0) }
            ).map { session in
                SessionsHomeSessionRow(
                    serverId: serverId,
                    session: session,
                    pendingPermissionCount: conn.permissionStore.pending(for: session.id).count,
                    pendingAskCount: conn.askRequestStore.hasPending(for: session.id) ? 1 : 0
                )
            }
            return SessionsHomeWorkspaceGroup(serverId: serverId, workspace: workspace, sessions: rows)
        }
    }

    private func fallbackRecentRows(
        serverId: String,
        connection conn: ServerConnection
    ) -> [SessionsHomeSessionRow] {
        conn.sessionStore.listProjectionSessions
            .filter { $0.status == .stopped }
            .map { session in
                SessionsHomeSessionRow(
                    serverId: serverId,
                    session: session,
                    pendingPermissionCount: 0,
                    pendingAskCount: 0
                )
            }
    }

    private func sortWorkspaceGroups(
        _ groups: [SessionsHomeWorkspaceGroup]
    ) -> [SessionsHomeWorkspaceGroup] {
        groups.sorted { lhs, rhs in
            let lhsHasAttention = lhs.pendingAttentionCount > 0
            let rhsHasAttention = rhs.pendingAttentionCount > 0
            if lhsHasAttention != rhsHasAttention { return lhsHasAttention }
            if lhs.latestActivity != rhs.latestActivity { return lhs.latestActivity > rhs.latestActivity }
            let nameCompare = lhs.workspace.name.localizedCaseInsensitiveCompare(rhs.workspace.name)
            if nameCompare != .orderedSame { return nameCompare == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private func sortRecentRows(_ rows: [SessionsHomeSessionRow]) -> [SessionsHomeSessionRow] {
        Array(rows
            .sorted { lhs, rhs in
                if lhs.session.lastActivity != rhs.session.lastActivity {
                    return lhs.session.lastActivity > rhs.session.lastActivity
                }
                return lhs.id < rhs.id
            }
            .prefix(50))
    }

    private func serverLabel(for serverId: String) -> String {
        coordinator.serverStore.server(for: serverId)?.name ?? String(serverId.prefix(8))
    }
}
