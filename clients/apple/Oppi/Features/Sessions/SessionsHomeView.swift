import SwiftUI

private struct SessionsHomeRoute: Hashable {
    let serverId: String
    let sessionId: String
}

private struct SessionsHomeSessionRow: Identifiable, Equatable {
    var id: String { "\(serverId):\(session.id)" }
    let serverId: String
    let serverLabel: String?
    let workspaceId: String?
    let session: Session
    let pendingPermissionCount: Int
    let pendingAskCount: Int
    let activeSectionKind: SessionListActiveSectionKind?
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
    @State private var actionError: String?
    @State private var pendingDeleteRow: SessionsHomeSessionRow?
    @State private var hasLoadedOnce = false

    var body: some View {
        let yourTurnRows = activeYourTurnRows
        let workingRows = activeWorkingRows
        let activeRowIds = Set((yourTurnRows + workingRows).map(\.id))
        let visibleRecentRows = recentRows.filter { !activeRowIds.contains($0.id) }

        NavigationStack(path: $path) {
            List {
                if !yourTurnRows.isEmpty {
                    activeRowsSection("Your Turn", rows: yourTurnRows)
                }

                if !workingRows.isEmpty {
                    activeRowsSection("Working", rows: workingRows)
                }

                if !visibleRecentRows.isEmpty {
                    recentSection(rows: visibleRecentRows)
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
                if yourTurnRows.isEmpty, workingRows.isEmpty, visibleRecentRows.isEmpty, !isRefreshing {
                    emptyState
                }
            }
            .refreshable {
                await refresh(force: true)
            }
            .task(id: refreshTaskId) {
                await refresh(force: false)
                await runRefreshPolling()
            }
            .navigationDestination(for: SessionsHomeRoute.self) { route in
                serverScopedChatDestination(route)
            }
            .confirmationDialog(
                "Delete Session?",
                isPresented: isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                if let row = pendingDeleteRow {
                    Button("Delete Session", role: .destructive) {
                        SessionDeleteConfirmationPolicy.confirm(
                            session: row.session,
                            clearPending: { pendingDeleteRow = nil },
                            performDelete: { _ in
                                Task { await deleteSession(row) }
                            }
                        )
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteRow = nil
                }
            } message: {
                if let session = pendingDeleteRow?.session {
                    Text(SessionDeleteConfirmationPolicy.deleteMessage(for: session))
                }
            }
            .alert("Error", isPresented: actionErrorPresented) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    private var refreshTaskId: String {
        coordinator.connections.keys.sorted().joined(separator: "|")
    }

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteRow != nil },
            set: { newValue in
                if !newValue { pendingDeleteRow = nil }
            }
        )
    }

    private var actionErrorPresented: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { newValue in
                if !newValue { actionError = nil }
            }
        )
    }

    private var activeRows: [SessionsHomeSessionRow] {
        let apiRowsByKey = Dictionary(uniqueKeysWithValues: activeGroups.flatMap { group in
            group.sessions.map { row in (row.id, row) }
        })

        return coordinator.connections
            .sorted { $0.key < $1.key }
            .flatMap { serverId, conn in
                activeRows(
                    serverId: serverId,
                    connection: conn,
                    apiRowsByKey: apiRowsByKey
                )
            }
    }

    private var activeYourTurnRows: [SessionsHomeSessionRow] {
        activeRows
            .filter { activeSectionKind(for: $0) == .yourTurn }
            .sorted { lhs, rhs in
                SessionListPresentation.compareYourTurn(
                    lhs.session,
                    lhsAttention: attentionCounts(for: lhs),
                    rhs.session,
                    rhsAttention: attentionCounts(for: rhs)
                )
            }
    }

    private var activeWorkingRows: [SessionsHomeSessionRow] {
        activeRows
            .filter { activeSectionKind(for: $0) == .working }
            .sorted { lhs, rhs in
                if SessionListPresentation.compareWorking(lhs.session, rhs.session) { return true }
                if SessionListPresentation.compareWorking(rhs.session, lhs.session) { return false }
                return lhs.id < rhs.id
            }
    }

    private func activeRows(
        serverId: String,
        connection conn: ServerConnection,
        apiRowsByKey: [String: SessionsHomeSessionRow]
    ) -> [SessionsHomeSessionRow] {
        let liveSessions = conn.sessionStore.listProjectionSessions
        let liveById = Dictionary(uniqueKeysWithValues: liveSessions.map { ($0.id, $0) })
        let liveActiveSessions = liveSessions.filter { $0.status != .stopped }
        let apiFallbackSessions = apiRowsByKey.values
            .filter { row in
                row.serverId == serverId && liveById[row.session.id] == nil && row.session.status != .stopped
            }
            .map(\.session)
        let candidateSessions = liveActiveSessions + apiFallbackSessions
        let candidateIds = Set(candidateSessions.map(\.id))
        let childIndex = SessionTreeHelper.ChildIndex(sessions: candidateSessions)

        let roots = candidateSessions.filter { session in
            guard let parentSessionId = session.parentSessionId else { return true }
            return !candidateIds.contains(parentSessionId)
        }

        return roots.compactMap { session in
            let descendantIds = childIndex.allDescendants(of: session.id).map(\.id)
            let attention = attentionCounts(
                sessionId: session.id,
                descendantIds: descendantIds,
                serverId: serverId,
                connection: conn,
                apiRowsByKey: apiRowsByKey
            )
            let hasWorkingDescendant = childIndex.allDescendants(of: session.id).contains {
                if $0.isAwaitingFirstPrompt { return false }
                switch $0.status {
                case .starting, .busy, .stopping: return true
                default: return false
                }
            }
            guard let sectionKind = SessionListPresentation.activeSectionKind(
                for: session,
                attention: attention,
                hasWorkingDescendant: hasWorkingDescendant
            ) else {
                return nil
            }

            let apiRow = apiRowsByKey["\(serverId):\(session.id)"]
            return SessionsHomeSessionRow(
                serverId: serverId,
                serverLabel: apiRow?.serverLabel,
                workspaceId: session.workspaceId,
                session: session,
                pendingPermissionCount: attention.permissionCount,
                pendingAskCount: attention.askCount,
                activeSectionKind: sectionKind
            )
        }
    }

    private func activeSectionKind(for row: SessionsHomeSessionRow) -> SessionListActiveSectionKind? {
        row.activeSectionKind ?? SessionListPresentation.activeSectionKind(
            for: row.session,
            attention: attentionCounts(for: row)
        )
    }

    private func attentionCounts(for row: SessionsHomeSessionRow) -> SessionListAttentionCounts {
        SessionListAttentionCounts(
            permissionCount: row.pendingPermissionCount,
            askCount: row.pendingAskCount
        )
    }

    private func attentionCounts(
        sessionId: String,
        descendantIds: [String],
        serverId: String,
        connection conn: ServerConnection,
        apiRowsByKey: [String: SessionsHomeSessionRow]
    ) -> SessionListAttentionCounts {
        let relevantIds = [sessionId] + descendantIds
        let livePermissionCount = relevantIds.reduce(0) { total, id in
            total + conn.permissionStore.pending(for: id).count
        }
        let liveAskCount = relevantIds.reduce(0) { total, id in
            total + (conn.askRequestStore.hasPending(for: id) ? 1 : 0)
        }
        let apiPermissionCount = relevantIds.reduce(0) { total, id in
            total + (apiRowsByKey["\(serverId):\(id)"]?.pendingPermissionCount ?? 0)
        }
        let apiAskCount = relevantIds.reduce(0) { total, id in
            total + (apiRowsByKey["\(serverId):\(id)"]?.pendingAskCount ?? 0)
        }

        return SessionListAttentionCounts(
            permissionCount: max(livePermissionCount, apiPermissionCount),
            askCount: max(liveAskCount, apiAskCount)
        )
    }

    private func activeRowsSection(_ title: String, rows: [SessionsHomeSessionRow]) -> some View {
        Section(title) {
            ForEach(rows) { row in
                sessionButton(row: row, workspace: nil, showWorkspaceContext: true)
            }
        }
    }

    private func recentSection(rows: [SessionsHomeSessionRow]) -> some View {
        Section {
            ForEach(rows) { row in
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
                    HStack(spacing: 6) {
                        Text(row.session.workspaceName ?? workspace?.name ?? "Workspace")
                            .textCase(.uppercase)

                        if coordinator.connections.count > 1 {
                            Text(serverLabel(for: row))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.themeComment.opacity(0.1), in: Capsule())
                        }
                    }
                    .font(.caption2.monospaced().weight(.medium))
                    .foregroundStyle(.themeComment)
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
        .swipeActions(edge: .trailing, allowsFullSwipe: row.session.status == .stopped) {
            if row.session.status == .stopped {
                Button(role: SessionDeleteConfirmationPolicy.swipeButtonRole) {
                    pendingDeleteRow = row
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.themeRed)
            } else {
                Button {
                    Task { await stopSession(row) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(.themeOrange)
            }
        }
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

    private func stopSession(_ row: SessionsHomeSessionRow) async {
        guard let workspaceId = row.workspaceId, !workspaceId.isEmpty else {
            actionError = "Stop failed: missing workspace for this session."
            return
        }
        guard let conn = coordinator.connection(for: row.serverId), let api = conn.apiClient else {
            actionError = "Stop failed: server is offline."
            return
        }

        do {
            let updated = try await api.stopWorkspaceSession(workspaceId: workspaceId, sessionId: row.session.id)
            conn.sessionStore.upsert(updated)
            await refresh(force: true)
        } catch {
            actionError = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func deleteSession(_ row: SessionsHomeSessionRow) async {
        guard let workspaceId = row.workspaceId, !workspaceId.isEmpty else {
            actionError = "Delete failed: missing workspace for this session."
            return
        }
        guard let conn = coordinator.connection(for: row.serverId), let api = conn.apiClient else {
            actionError = "Delete failed: server is offline."
            return
        }

        conn.sessionStore.remove(id: row.session.id)
        removeRowLocally(row)

        do {
            try await api.deleteWorkspaceSession(workspaceId: workspaceId, sessionId: row.session.id)
        } catch let apiError as APIError {
            // 404 means already deleted server-side — local removal above is sufficient.
            if case .server(let status, _) = apiError, status == 404 { /* ok */ } else {
                actionError = "Delete failed: \(apiError.localizedDescription)"
            }
        } catch {
            actionError = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func removeRowLocally(_ row: SessionsHomeSessionRow) {
        recentRows.removeAll { $0.id == row.id }
        activeGroups = activeGroups.compactMap { group in
            let sessions = group.sessions.filter { $0.id != row.id }
            guard !sessions.isEmpty else { return nil }
            return SessionsHomeWorkspaceGroup(
                serverId: group.serverId,
                workspace: group.workspace,
                sessions: sessions
            )
        }
    }

    private func runRefreshPolling() async {
        var policy = SessionListRefreshPollingPolicy()

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Int.random(in: 10...15)))
            guard !Task.isCancelled else { break }

            let state = pollingState()
            guard policy.shouldRefresh(
                hasActiveWork: state.hasActiveWork,
                hasAttention: state.hasAttention
            ) else {
                continue
            }

            await refresh(force: true)
        }
    }

    private func pollingState() -> (hasActiveWork: Bool, hasAttention: Bool) {
        var hasActiveWork = false
        var hasAttention = false

        for conn in coordinator.connections.values {
            let sessions = conn.sessionStore.listProjectionSessions
            let activeSessionIds = Set(sessions.filter { $0.status != .stopped }.map(\.id))

            if sessions.contains(where: { session in
                switch session.status {
                case .starting, .busy, .stopping:
                    return true
                case .ready, .stopped, .error:
                    return false
                }
            }) {
                hasActiveWork = true
            }

            if conn.permissionStore.pending.contains(where: { activeSessionIds.contains($0.sessionId) }) ||
                conn.askRequestStore.pending.values.contains(where: { activeSessionIds.contains($0.sessionId) }) {
                hasAttention = true
            }
        }

        for row in activeRows {
            if row.pendingPermissionCount > 0 || row.pendingAskCount > 0 {
                hasAttention = true
            }
            switch row.session.status {
            case .starting, .busy, .stopping:
                hasActiveWork = true
            case .ready, .stopped, .error:
                break
            }
        }

        return (hasActiveWork, hasAttention)
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

            let runtimeServerLabel = await fetchRuntimeServerLabel(api: api)

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
                                serverLabel: runtimeServerLabel,
                                workspaceId: group.workspace.id,
                                session: row.summary.session,
                                pendingPermissionCount: row.pendingPermissionCount,
                                pendingAskCount: row.pendingAskCount,
                                activeSectionKind: nil
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
                            serverLabel: runtimeServerLabel,
                            workspaceId: summary.workspaceId ?? summary.session.workspaceId,
                            session: summary.session,
                            pendingPermissionCount: 0,
                            pendingAskCount: 0,
                            activeSectionKind: nil
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
                    serverLabel: nil,
                    workspaceId: workspace.id,
                    session: session,
                    pendingPermissionCount: conn.permissionStore.pending(for: session.id).count,
                    pendingAskCount: conn.askRequestStore.hasPending(for: session.id) ? 1 : 0,
                    activeSectionKind: nil
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
                    serverLabel: nil,
                    workspaceId: session.workspaceId,
                    session: session,
                    pendingPermissionCount: 0,
                    pendingAskCount: 0,
                    activeSectionKind: nil
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

    private func fetchRuntimeServerLabel(api: APIClient) async -> String? {
        do {
            let info = try await api.serverInfo()
            return SessionsHomeServerLabel.runtimeLabel(from: info.hostname)
                ?? SessionsHomeServerLabel.runtimeLabel(from: info.name)
        } catch {
            return nil
        }
    }

    private func serverLabel(for row: SessionsHomeSessionRow) -> String {
        SessionsHomeServerLabel.displayLabel(
            runtimeLabel: row.serverLabel,
            pairedLabel: coordinator.serverStore.server(for: row.serverId)?.name,
            fallbackServerId: row.serverId
        )
    }
}
