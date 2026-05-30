import SwiftUI

/// Navigation target pairing a workspace with its server for on-demand connection switching.
struct WorkspaceNavTarget: Hashable {
    let serverId: String
    let workspace: Workspace
}

/// Navigation target for opening a session directly from the workspace overview.
struct WorkspaceSessionNavTarget: Hashable {
    let serverId: String
    let sessionId: String
}

/// Utility destinations that live under the Workspaces navigation stack.
/// These are intentionally not bottom-tab destinations; they are secondary
/// management surfaces reached from the server/environment menu.
enum WorkspaceUtilityNavTarget: Hashable {
    case manageServers
    case appSettings
}

private struct WorkspaceCreateSheetContext: Identifiable {
    let server: PairedServer
    let presentation: WorkspaceCreatePresentation
    let openWorkspaceAfterCreate: Bool
    let prefillName: String?
    let prefillPath: String?

    var id: String {
        [
            server.id,
            presentation == .guidedFirstWorkspace ? "guided" : "standard",
            openWorkspaceAfterCreate ? "open" : "stay",
            prefillName ?? "",
            prefillPath ?? ""
        ].joined(separator: "|")
    }
}

private struct WorkspaceHomePendingDeleteSession: Identifiable {
    let serverId: String
    let workspaceId: String
    let session: Session

    var id: String { "\(serverId):\(workspaceId):\(session.id)" }
}

private struct WorkspaceScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: WorkspaceNavTarget

    @State private var scopedConnection: ServerConnection?

    private var resolvedConnection: ServerConnection? {
        scopedConnection ?? coordinator.connection(for: target.serverId)
    }

    var body: some View {
        Group {
            if let connection = resolvedConnection {
                WorkspaceDetailView(workspace: target.workspace)
                    .withServerScopedEnvironment(connection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .onAppear(perform: activateTargetServer)
        .task(id: target.serverId) {
            activateTargetServer()
        }
    }

    @MainActor
    private func activateTargetServer() {
        guard coordinator.switchToServer(target.serverId) else { return }
        scopedConnection = coordinator.connection(for: target.serverId)
    }
}

private struct WorkspaceSessionScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: WorkspaceSessionNavTarget

    @State private var scopedConnection: ServerConnection?

    private var resolvedConnection: ServerConnection? {
        scopedConnection ?? coordinator.connection(for: target.serverId)
    }

    var body: some View {
        Group {
            if let connection = resolvedConnection {
                ChatView(sessionId: target.sessionId)
                    .withServerScopedEnvironment(connection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .onAppear(perform: activateTargetServer)
        .task(id: target.serverId) {
            activateTargetServer()
        }
    }

    @MainActor
    private func activateTargetServer() {
        guard coordinator.switchToServer(target.serverId) else { return }
        scopedConnection = coordinator.connection(for: target.serverId)
    }
}

private extension View {
    func withServerScopedEnvironment(_ connection: ServerConnection) -> some View {
        self
            .environment(connection)
            .environment(\.apiClient, connection.apiClient)
            .environment(connection.chatState)
            .environment(connection.sessionStore)
            .environment(connection.workspaceStore)
            .environment(connection.permissionStore)
            .environment(connection.askRequestStore)
            .environment(connection.audioPlayer)
            .environment(connection.gitStatusStore)
            .environment(connection.fileIndexStore)
            .environment(connection.messageQueueStore)
            .environment(connection.activityStore)
    }
}

private struct WorkspaceHomeSessionPreview: Identifiable {
    let presentation: SessionRowPresentation

    var id: String { presentation.session.id }
}

enum WorkspaceHomePreviewPlanner {
    static let maxRows = 5
    static let preferredYourTurnRows = 3

    static func activeRows<T>(
        yourTurn: [T],
        working: [T],
        maxRows: Int = Self.maxRows,
        preferredYourTurnRows: Int = Self.preferredYourTurnRows
    ) -> [T] {
        guard maxRows > 0 else { return [] }

        var rows: [T] = []
        let firstYourTurnCount = min(preferredYourTurnRows, maxRows, yourTurn.count)
        rows.append(contentsOf: yourTurn.prefix(firstYourTurnCount))

        let workingCount = min(maxRows - rows.count, working.count)
        rows.append(contentsOf: working.prefix(workingCount))

        let remainingCount = maxRows - rows.count
        if remainingCount > 0 {
            rows.append(contentsOf: yourTurn.dropFirst(firstYourTurnCount).prefix(remainingCount))
        }

        return rows
    }
}

/// Tracks whether app launch metric has been recorded this process.
/// Only fires once — on the first appearance of WorkspaceHomeView.
nonisolated(unsafe) private var appLaunchMetricRecorded = false

/// Top-level workspace list — primary navigation tab.
///
/// Shows one server at a time, with a server switcher in the toolbar and
/// expandable workspace rows that preview active or recent sessions.
struct WorkspaceHomeView: View {
    static func workspaceOpenAccessibilityIdentifier(workspaceName: String) -> String {
        "workspace.open.\(workspaceName)"
    }

    static func shouldOpenWorkspaceFromRowBody(isE2EInviteMode: Bool) -> Bool {
        isE2EInviteMode
    }

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var createSheetContext: WorkspaceCreateSheetContext?
    @State private var pendingCreatedWorkspaceTarget: WorkspaceNavTarget?
    @State private var pendingDeleteSession: WorkspaceHomePendingDeleteSession?
    @State private var error: String?
    @State private var expandedWorkspaceKeys: Set<String> = []
    @State private var collapsedWorkspaceKeys: Set<String> = []
    /// Guards against re-presenting the guided create after the user dismisses it.
    @State private var guidedCreateConsumed = false
    /// Tracks whether the initial task-driven refresh has already run for this view identity.
    @State private var hasPerformedInitialRefresh = false
    @State private var hasAutoOpenedE2EWorkspace = false

    private var servers: [PairedServer] {
        serverStore.servers
    }

    private var selectedServer: PairedServer? {
        if let activeServerId = coordinator.activeServerId,
           let server = servers.first(where: { $0.id == activeServerId }) {
            return server
        }
        return servers.first
    }

    var body: some View {
        List {
            if let selectedServer {
                serverSection(for: selectedServer)
            }
        }
        .accessibilityIdentifier("workspace.list")
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let selectedServer {
                    serverSwitcher(selectedServer)
                    quickSessionButton
                }
            }
        }
        .navigationDestination(for: WorkspaceNavTarget.self) { target in
            WorkspaceScopedDestinationView(target: target)
        }
        .navigationDestination(for: WorkspaceSessionNavTarget.self) { target in
            WorkspaceSessionScopedDestinationView(target: target)
        }
        .navigationDestination(for: PairedServer.self) { server in
            ServerDetailView(server: server)
        }
        .navigationDestination(for: WorkspaceUtilityNavTarget.self) { target in
            switch target {
            case .manageServers:
                ServerView()
            case .appSettings:
                SettingsView()
            }
        }
        .sheet(item: $createSheetContext, onDismiss: handleCreateSheetDismissed) { context in
            WorkspaceCreateView(
                server: context.server,
                presentation: context.presentation,
                prefillName: context.prefillName,
                prefillPath: context.prefillPath,
                onCreate: { workspace in
                    guard context.openWorkspaceAfterCreate else { return }
                    pendingCreatedWorkspaceTarget = WorkspaceNavTarget(
                        serverId: context.server.id,
                        workspace: workspace
                    )
                }
            )
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { if !$0 { pendingDeleteSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDeleteSession {
                Button("Delete Session", role: .destructive) {
                    let context = pendingDeleteSession
                    self.pendingDeleteSession = nil
                    Task { await deletePreviewSession(context) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteSession = nil
            }
        } message: {
            if let pendingDeleteSession {
                Text(SessionDeleteConfirmationPolicy.deleteMessage(for: pendingDeleteSession.session))
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
        .refreshable {
            await refresh(force: true)
        }
        .overlay {
            if servers.isEmpty {
                ContentUnavailableView(
                    "No Servers",
                    systemImage: "server.rack",
                    description: Text("Pair with a server to get started.")
                )
            } else if allWorkspacesEmpty {
                emptyWorkspacesView
            }
        }
        .task {
            await refresh(force: false)
            consumeWorkspaceDeepLinkIfNeeded()
            triggerGuidedCreateIfNeeded()
            autoOpenE2EWorkspaceIfRequested()
        }
        .onChange(of: navigation.pendingWorkspaceDeepLink != nil) { _, hasPending in
            guard hasPending else { return }
            consumeWorkspaceDeepLinkIfNeeded()
        }
        .onChange(of: navigation.selectedTab) { _, selectedTab in
            guard selectedTab == .workspaces else { return }
            refreshIfWorkspaceHomeIsVisible()
        }
        .onChange(of: navigation.workspacePath.count) { oldCount, newCount in
            guard oldCount > 0, newCount == 0 else { return }
            refreshIfWorkspaceHomeIsVisible()
        }
        .onAppear {
            if !appLaunchMetricRecorded {
                appLaunchMetricRecorded = true
                ChatSessionTelemetry.recordAppLaunch()
            }
        }
    }

    // MARK: - Toolbar

    private func serverStatusPresentation(for server: PairedServer) -> WorkspaceServerStatusPresentation {
        let serverConn = coordinator.connection(for: server.id)
        let workspaceCatalog = workspacesForServer(server.id)
        let rawFreshness = serverConn?.workspaceStore.freshnessState(forServer: server.id) ?? .offline
        let rawFreshnessLabel = serverConn?.workspaceStore.freshnessLabel(forServer: server.id) ?? "Offline"
        return WorkspaceServerStatusPresentation.derive(
            freshnessState: rawFreshness,
            freshnessLabel: rawFreshnessLabel,
            isTransportConnected: serverConn?.isConnected == true,
            hasCachedCatalog: !workspaceCatalog.isEmpty
        )
    }

    private func serverSwitcher(_ current: PairedServer) -> some View {
        Menu {
            ForEach(servers) { server in
                Button {
                    switchVisibleServer(to: server)
                } label: {
                    Label(
                        server.name,
                        systemImage: server.id == current.id ? "checkmark.circle.fill" : server.resolvedBadgeIcon.symbolName
                    )
                }
            }

            Divider()

            Button {
                presentCreateWorkspace(on: current)
            } label: {
                Label("Create Workspace", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier("workspace.create.open")

            Button {
                navigation.workspacePath.append(WorkspaceUtilityNavTarget.manageServers)
            } label: {
                Label("Manage Servers", systemImage: "server.rack")
            }

            Button {
                navigation.workspacePath.append(WorkspaceUtilityNavTarget.appSettings)
            } label: {
                Label("App Settings", systemImage: "gear")
            }
        } label: {
            ServerSwitcherPill(
                server: current,
                status: serverStatusPresentation(for: current)
            )
        }
        .accessibilityLabel("Current server: \(current.name)")
    }

    private var quickSessionButton: some View {
        Button {
            navigation.showQuickSession = true
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .accessibilityLabel("Start Quick Session")
        .accessibilityHint("Opens the quick session composer")
        .accessibilityIdentifier("workspace.quickSession.start")
    }

    private func switchVisibleServer(to server: PairedServer) {
        guard coordinator.switchToServer(server) else { return }
        Task { @MainActor in
            await refresh(force: true)
        }
    }

    // MARK: - Server Section

    @ViewBuilder
    private func serverSection(for server: PairedServer) -> some View {
        let serverId = server.id
        let serverConn = coordinator.connection(for: serverId)
        let workspaceCatalog = workspacesForServer(serverId)
        let summaries = serverConn?.workspaceStore.workspaceSummaries(forServer: serverId) ?? [:]
        let workspaces = sortedWorkspaces(workspaceCatalog, summaries: summaries)
        let isUnreachable = serverStatusPresentation(for: server).isUnreachable

        Section {
            if workspaces.isEmpty {
                Text(isUnreachable ? "Offline — cached workspaces unavailable" : "No workspaces")
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
                    .listRowBackground(Color.themeBg)
            } else {
                ForEach(workspaces) { workspace in
                    let summary = summaryForWorkspace(workspace.id, in: summaries)
                    workspaceOverviewRows(
                        server: server,
                        connection: serverConn,
                        workspace: workspace,
                        summary: summary,
                        isUnreachable: isUnreachable
                    )
                }
            }
        }
    }

    // MARK: - Workspace Overview Rows

    @ViewBuilder
    private func workspaceOverviewRows(
        server: PairedServer,
        connection: ServerConnection?,
        workspace: Workspace,
        summary: WorkspaceListSummary,
        isUnreachable: Bool
    ) -> some View {
        let serverId = server.id
        let key = workspaceKey(serverId: serverId, workspaceId: workspace.id)
        let isExpanded = isWorkspaceExpanded(key: key, summary: summary)
        let sessionPreviews = workspaceSessionPreviews(workspaceId: workspace.id, connection: connection)
        let workspaceAccessibilityName = workspace.runtime == .sandbox ? "sandbox workspace \(workspace.name)" : workspace.name
        let opensWorkspaceFromRowBody = Self.shouldOpenWorkspaceFromRowBody(
            isE2EInviteMode: ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"] != nil
        )
        let rowBodyAction = {
            if opensWorkspaceFromRowBody {
                navigation.workspacePath.append(WorkspaceNavTarget(serverId: serverId, workspace: workspace))
            } else {
                toggleWorkspaceExpansion(key: key, summary: summary)
            }
        }
        let statusPresentation = WorkspaceHomeStatusPresentation(
            activeCount: summary.activeCount,
            stoppedCount: summary.stoppedCount,
            hasAttention: summary.hasAttention
        )

        HStack(alignment: .center, spacing: 0) {
            Button(action: rowBodyAction) {
                WorkspaceHomeRow(
                    workspace: workspace,
                    activeCount: summary.activeCount,
                    stoppedCount: summary.stoppedCount,
                    hasAttention: summary.hasAttention,
                    isExpanded: isExpanded,
                    isUnreachable: isUnreachable,
                    showsStatus: false
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)
            .accessibilityLabel(isExpanded ? "Collapse sessions for \(workspaceAccessibilityName)" : "Expand sessions for \(workspaceAccessibilityName)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides the workspace session preview")

            let target = WorkspaceNavTarget(serverId: serverId, workspace: workspace)
            Button {
                navigation.workspacePath.append(target)
            } label: {
                HStack(alignment: .center, spacing: 4) {
                    if statusPresentation.isVisible {
                        WorkspaceHomeStatusIndicator(presentation: statusPresentation)
                            .fixedSize()
                    }

                    WorkspaceHomeNavigationChevron()
                }
                .frame(minWidth: 44, minHeight: 44, maxHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
            .accessibilityIdentifier(Self.workspaceOpenAccessibilityIdentifier(workspaceName: workspace.name))
            .accessibilityLabel("Open \(workspaceAccessibilityName)")
            .accessibilityHint("Opens the workspace session list")
            .accessibilityRespondsToUserInteraction(true)
            .zIndex(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .onTapGesture {
            if opensWorkspaceFromRowBody {
                navigation.workspacePath.append(WorkspaceNavTarget(serverId: serverId, workspace: workspace))
            }
        }
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.themeGreen.opacity(0.06))
            }
        }
        .padding(.horizontal, -6)
        .listRowBackground(Color.themeBg)

        if isExpanded {
            if sessionPreviews.isEmpty {
                WorkspaceHomePreviewEmptyRow()
                    .listRowBackground(Color.themeBg)
            } else {
                ForEach(sessionPreviews) { preview in
                    Button {
                        navigation.workspacePath.append(
                            WorkspaceSessionNavTarget(serverId: serverId, sessionId: preview.presentation.session.id)
                        )
                    } label: {
                        WorkspaceHomeSessionPreviewRow(preview: preview)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.themeBg)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        previewRowSwipeAction(
                            session: preview.presentation.session,
                            serverId: serverId,
                            workspaceId: workspace.id,
                            connection: connection
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func previewRowSwipeAction(
        session: Session,
        serverId: String,
        workspaceId: String,
        connection: ServerConnection?
    ) -> some View {
        if session.status == .stopped {
            Button(role: SessionDeleteConfirmationPolicy.swipeButtonRole) {
                pendingDeleteSession = WorkspaceHomePendingDeleteSession(
                    serverId: serverId,
                    workspaceId: workspaceId,
                    session: session
                )
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("workspaceHome.session.delete.\(session.id)")
            .tint(.themeRed)
        } else {
            Button {
                Task { await stopPreviewSession(session, workspaceId: workspaceId, connection: connection) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .accessibilityIdentifier("workspaceHome.session.stop.\(session.id)")
            .tint(.themeOrange)
        }
    }

    private func workspaceKey(serverId: String, workspaceId: String) -> String {
        "\(serverId):\(workspaceId)"
    }

    private func isWorkspaceExpanded(key: String, summary: WorkspaceListSummary) -> Bool {
        if expandedWorkspaceKeys.contains(key) { return true }
        if collapsedWorkspaceKeys.contains(key) { return false }
        return summary.hasAttention || summary.activeCount > 0
    }

    private func toggleWorkspaceExpansion(key: String, summary: WorkspaceListSummary) {
        let isExpanded = isWorkspaceExpanded(key: key, summary: summary)
        withAnimation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
            if isExpanded {
                expandedWorkspaceKeys.remove(key)
                collapsedWorkspaceKeys.insert(key)
            } else {
                collapsedWorkspaceKeys.remove(key)
                expandedWorkspaceKeys.insert(key)
            }
        }
    }

    private func workspaceSessionPreviews(
        workspaceId: String,
        connection: ServerConnection?
    ) -> [WorkspaceHomeSessionPreview] {
        guard let connection else { return [] }
        let workspaceSessions = connection.sessionStore.listProjectionSessions(workspaceId: workspaceId)
        guard !workspaceSessions.isEmpty else { return [] }

        let activeSessions = workspaceSessions.filter { $0.status != .stopped }
        let activeRoots = SessionTreeHelper.rootSessions(from: activeSessions, allSessions: activeSessions)
        let activeChildIndex = SessionTreeHelper.ChildIndex(sessions: activeSessions)
        let allChildIndex = SessionTreeHelper.ChildIndex(sessions: workspaceSessions)
        var attentionBySessionId: [String: SessionListAttentionCounts] = [:]
        var yourTurn: [Session] = []
        var working: [Session] = []

        for session in activeRoots {
            let descendants = activeChildIndex.allDescendants(of: session.id)
            let attention = SessionRowPresentationBuilder.attentionCounts(
                sessionId: session.id,
                descendants: descendants,
                pendingPermissionCountForSession: { pendingPermissionCount(for: $0, connection: connection) },
                pendingAskCountForSession: { pendingAskCount(for: $0, connection: connection) }
            )
            attentionBySessionId[session.id] = attention

            let hasWorkingDescendant = descendants.contains { descendant in
                if descendant.isAwaitingFirstPrompt { return false }
                switch descendant.status {
                case .starting, .busy, .stopping: return true
                case .ready, .stopped, .error: return false
                }
            }

            switch SessionListPresentation.activeSectionKind(
                for: session,
                attention: attention,
                hasWorkingDescendant: hasWorkingDescendant
            ) {
            case .yourTurn:
                yourTurn.append(session)
            case .working:
                working.append(session)
            case nil:
                break
            }
        }

        let maxPreviewRows = WorkspaceHomePreviewPlanner.maxRows
        var previews: [WorkspaceHomeSessionPreview] = []
        let sortedYourTurn = SessionListPresentation.sortYourTurn(yourTurn) { sessionId in
            attentionBySessionId[sessionId] ?? .none
        }
        let sortedWorking = SessionListPresentation.sortWorking(working)

        let activePreviewRows = WorkspaceHomePreviewPlanner.activeRows(
            yourTurn: sortedYourTurn,
            working: sortedWorking,
            maxRows: maxPreviewRows
        ).map {
            previewRow(
                session: $0,
                attention: attentionBySessionId[$0.id] ?? .none,
                childIndex: allChildIndex,
                connection: connection
            )
        }
        previews.append(contentsOf: activePreviewRows)

        let remainingRecentSlots = max(0, maxPreviewRows - previews.count)
        if remainingRecentSlots > 0 {
            let stoppedSessions = workspaceSessions.filter { $0.status == .stopped }
            let recentStopped = SessionTreeHelper.rootSessions(from: stoppedSessions, allSessions: workspaceSessions)
                .sorted { lhs, rhs in
                    if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                    return lhs.id < rhs.id
                }
                .prefix(remainingRecentSlots)
                .map {
                    previewRow(
                        session: $0,
                        attention: .none,
                        childIndex: allChildIndex,
                        connection: connection
                    )
                }
            previews.append(contentsOf: recentStopped)
        }

        return previews
    }

    private func pendingPermissionCount(for sessionId: String, connection: ServerConnection) -> Int {
        max(
            connection.sessionStore.listPendingPermissionCount(for: sessionId),
            connection.permissionStore.pending(for: sessionId).count
        )
    }

    private func pendingAskCount(for sessionId: String, connection: ServerConnection) -> Int {
        max(
            connection.sessionStore.listPendingAskCount(for: sessionId),
            connection.askRequestStore.hasPending(for: sessionId) ? 1 : 0
        )
    }

    private func previewRow(
        session: Session,
        attention: SessionListAttentionCounts,
        childIndex: SessionTreeHelper.ChildIndex,
        connection: ServerConnection
    ) -> WorkspaceHomeSessionPreview {
        let descendants = childIndex.allDescendants(of: session.id)
        return WorkspaceHomeSessionPreview(
            presentation: SessionRowPresentationBuilder.make(
                session: session,
                descendants: descendants,
                pendingPermissionCount: attention.permissionCount,
                pendingAskCount: attention.askCount,
                pendingPermissions: connection.permissionStore.pending(for: session.id),
                pendingAsk: connection.askRequestStore.pending(for: session.id),
                activity: connection.activityStore.lastActivity(for: session.id)
            )
        )
    }

    // MARK: - Data

    private var allWorkspacesEmpty: Bool {
        coordinator.connections.values.allSatisfy { conn in
            conn.workspaceStore.workspaces.isEmpty
        }
    }

    private func workspacesForServer(_ serverId: String) -> [Workspace] {
        coordinator.connection(for: serverId)?.workspaceStore.workspaces ?? []
    }

    private func sortedWorkspaces(
        _ workspaces: [Workspace],
        summaries: [String: WorkspaceListSummary]
    ) -> [Workspace] {
        workspaces.sorted { lhs, rhs in
            let lhsSummary = summaryForWorkspace(lhs.id, in: summaries)
            let rhsSummary = summaryForWorkspace(rhs.id, in: summaries)

            if lhsSummary.hasAttention != rhsSummary.hasAttention {
                return lhsSummary.hasAttention
            }
            if (lhsSummary.activeCount > 0) != (rhsSummary.activeCount > 0) {
                return lhsSummary.activeCount > 0
            }

            let lhsLatest = lhsSummary.latestActivity ?? .distantPast
            let rhsLatest = rhsSummary.latestActivity ?? .distantPast
            if lhsLatest != rhsLatest {
                return lhsLatest > rhsLatest
            }

            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Session Helpers

    private func summaryForWorkspace(
        _ workspaceId: String,
        in summaries: [String: WorkspaceListSummary]
    ) -> WorkspaceListSummary {
        summaries[workspaceId] ?? WorkspaceListSummary(
            workspaceId: workspaceId,
            activeCount: 0,
            stoppedCount: 0,
            hasAttention: false
        )
    }

    private func refresh(force: Bool) async {
        if !force {
            guard !hasPerformedInitialRefresh else { return }
            hasPerformedInitialRefresh = true
        }

        // Unified path: coordinator handles single- and multi-server refresh.
        await coordinator.refreshAllServers()
    }

    private func refreshIfWorkspaceHomeIsVisible() {
        guard navigation.selectedTab == .workspaces else { return }
        guard navigation.workspacePath.count == 0 else { return }

        Task { @MainActor in
            await refresh(force: true)
        }
    }

    private func autoOpenE2EWorkspaceIfRequested() {
        guard !hasAutoOpenedE2EWorkspace,
              navigation.workspacePath.count == 0,
              let workspaceName = ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"],
              !workspaceName.isEmpty,
              let server = selectedServer,
              let workspace = workspacesForServer(server.id).first(where: { $0.name == workspaceName })
        else { return }

        hasAutoOpenedE2EWorkspace = true
        navigation.workspacePath.append(WorkspaceNavTarget(serverId: server.id, workspace: workspace))
    }

    // MARK: - Session Actions

    private func stopPreviewSession(
        _ session: Session,
        workspaceId: String,
        connection: ServerConnection?
    ) async {
        guard let connection, let api = connection.apiClient else {
            error = "Stop failed: server is offline"
            return
        }

        do {
            let updated = try await api.stopWorkspaceSession(workspaceId: workspaceId, sessionId: session.id)
            connection.sessionStore.upsert(updated)
            await refresh(force: true)
        } catch {
            self.error = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func deletePreviewSession(_ pending: WorkspaceHomePendingDeleteSession) async {
        guard let connection = coordinator.connection(for: pending.serverId),
              let api = connection.apiClient else {
            error = "Delete failed: server is offline"
            return
        }

        connection.sessionStore.remove(id: pending.session.id)
        do {
            try await api.deleteWorkspaceSession(
                workspaceId: pending.workspaceId,
                sessionId: pending.session.id
            )
            await refresh(force: true)
        } catch let apiError as APIError {
            if case .server(let status, _) = apiError, status == 404 {
                await refresh(force: true)
            } else {
                self.error = "Delete failed: \(apiError.localizedDescription)"
                await refresh(force: true)
            }
        } catch {
            self.error = "Delete failed: \(error.localizedDescription)"
            await refresh(force: true)
        }
    }

    // MARK: - Guided Workspace Creation

    private func presentCreateWorkspace(
        on server: PairedServer,
        presentation: WorkspaceCreatePresentation = .standard,
        openWorkspaceAfterCreate: Bool = false,
        prefillName: String? = nil,
        prefillPath: String? = nil
    ) {
        createSheetContext = WorkspaceCreateSheetContext(
            server: server,
            presentation: presentation,
            openWorkspaceAfterCreate: openWorkspaceAfterCreate,
            prefillName: prefillName,
            prefillPath: prefillPath
        )
    }

    private func handleCreateSheetDismissed() {
        guard let target = pendingCreatedWorkspaceTarget else { return }
        pendingCreatedWorkspaceTarget = nil
        navigation.selectedTab = .workspaces
        navigation.workspacePath = NavigationPath()
        navigation.workspacePath.append(target)
    }

    /// After a fresh pairing, auto-present WorkspaceCreateView if the server has no workspaces.
    private func triggerGuidedCreateIfNeeded() {
        guard createSheetContext == nil else { return }
        guard navigation.shouldGuideWorkspaceCreation, !guidedCreateConsumed else { return }
        guard allWorkspacesEmpty else {
            // Server already has workspaces — nothing to guide.
            navigation.shouldGuideWorkspaceCreation = false
            return
        }
        guard let server = selectedServer ?? servers.first else { return }

        guidedCreateConsumed = true
        navigation.shouldGuideWorkspaceCreation = false
        presentCreateWorkspace(
            on: server,
            presentation: .guidedFirstWorkspace,
            openWorkspaceAfterCreate: true
        )
    }

    /// Consume a workspace creation deep link and present the create form with
    /// the linked path/name prefilled.
    private func consumeWorkspaceDeepLinkIfNeeded() {
        guard let payload = navigation.pendingWorkspaceDeepLink else { return }
        navigation.pendingWorkspaceDeepLink = nil
        navigation.shouldGuideWorkspaceCreation = false

        let server: PairedServer?
        if let fingerprint = payload.serverFingerprint {
            server = servers.first { WorkspaceDeepLink.fingerprintsMatch($0.id, fingerprint) }
        } else {
            server = selectedServer ?? servers.first
        }

        guard let server else {
            coordinator.activeConnection.extensionToast = "Server not found for this workspace link"
            return
        }
        guard coordinator.switchToServer(server) else {
            coordinator.activeConnection.extensionToast = "Could not open the server for this workspace link"
            return
        }

        navigation.selectedTab = .workspaces
        navigation.workspacePath = NavigationPath()
        presentCreateWorkspace(
            on: server,
            prefillName: payload.name,
            prefillPath: payload.path
        )
    }

    /// Empty state shown when servers exist but all workspaces are empty.
    private var emptyWorkspacesView: some View {
        ContentUnavailableView {
            Label("No Workspaces", systemImage: "square.grid.2x2")
        } description: {
            Text("A workspace tells Oppi which folder to work in. Create your first one from a project folder, a manual path, or a blank setup.")
        } actions: {
            if let server = selectedServer ?? servers.first {
                Button("Create First Workspace") {
                    presentCreateWorkspace(on: server)
                }
                .accessibilityIdentifier("workspace.create.first.open")
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Server Switcher

private struct ServerSwitcherPill: View {
    let server: PairedServer
    let status: WorkspaceServerStatusPresentation

    var body: some View {
        HStack(spacing: 6) {
            RuntimeBadge(
                compact: true,
                icon: server.resolvedBadgeIcon,
                badgeColor: server.resolvedBadgeColor
            )

            Text(server.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
        }
        .foregroundStyle(.themeFg)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.themeComment.opacity(0.14), in: Capsule())
    }

    private var statusColor: Color {
        switch status.state {
        case .live: return .themeGreen
        case .syncing: return .themeBlue
        case .stale: return .themeOrange
        case .offline: return .themeRed
        }
    }
}

// MARK: - Workspace Header Chrome

private struct WorkspaceHomeNavigationChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .imageScale(.small)
            .foregroundStyle(.themeComment)
            .frame(width: 8, height: 44, alignment: .trailing)
            .accessibilityHidden(true)
    }
}

// MARK: - Workspace Session Preview Rows

private struct WorkspaceHomeSessionPreviewRow: View {
    let preview: WorkspaceHomeSessionPreview

    var body: some View {
        SessionRow(presentation: preview.presentation)
            .padding(.vertical, 1)
    }
}

private struct WorkspaceHomePreviewEmptyRow: View {
    var body: some View {
        Text("No sessions")
            .font(.caption)
            .foregroundStyle(.themeComment)
            .padding(.vertical, 4)
    }
}

// MARK: - Workspace Home Row

private struct WorkspaceHomeRow: View {
    let workspace: Workspace
    let activeCount: Int
    let stoppedCount: Int
    let hasAttention: Bool
    let isExpanded: Bool
    var isUnreachable: Bool = false
    var showsStatus: Bool = true

    var body: some View {
        let statusPresentation = WorkspaceHomeStatusPresentation(
            activeCount: activeCount,
            stoppedCount: stoppedCount,
            hasAttention: hasAttention
        )

        HStack(alignment: .center, spacing: 10) {
            WorkspaceRuntimeIcon(workspace: workspace, size: 30, frameSize: 34)
                .opacity(isUnreachable ? 0.55 : 1)
                .scaleEffect(isExpanded ? 1.03 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name)
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if let desc = workspace.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsStatus && statusPresentation.isVisible {
                WorkspaceHomeStatusIndicator(presentation: statusPresentation)
                    .frame(width: WorkspaceHomeStatusIndicator.columnWidth, alignment: .trailing)
                    .padding(.leading, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }
}

private struct WorkspaceHomeStatusPresentation: Equatable {
    enum Kind: Equatable {
        case attention
        case active
        case stopped
    }

    let kind: Kind?
    let activeCount: Int
    let stoppedCount: Int

    init(activeCount: Int, stoppedCount: Int, hasAttention: Bool) {
        self.activeCount = activeCount
        self.stoppedCount = stoppedCount

        if hasAttention {
            kind = .attention
        } else if activeCount > 0 {
            kind = .active
        } else if stoppedCount > 0 {
            kind = .stopped
        } else {
            kind = nil
        }
    }

    var isVisible: Bool {
        kind != nil
    }

    var tint: Color {
        switch kind {
        case .attention:
            return .themeOrange
        case .active:
            return .themeGreen
        case .stopped, nil:
            return .themeComment
        }
    }

    var accessibilityLabel: String {
        switch kind {
        case .attention:
            return "Needs attention"
        case .active:
            if stoppedCount > 0 {
                return "\(activeCount) active \(sessionWord(activeCount)), \(stoppedCount) stopped \(sessionWord(stoppedCount))"
            }
            return "\(activeCount) active \(sessionWord(activeCount))"
        case .stopped:
            return "\(stoppedCount) stopped \(sessionWord(stoppedCount))"
        case nil:
            return ""
        }
    }

    private func sessionWord(_ count: Int) -> String {
        count == 1 ? "session" : "sessions"
    }
}

private struct WorkspaceHomeStatusIndicator: View {
    static let columnWidth: CGFloat = 98

    private static let symbolWidth: CGFloat = 15
    private static let symbolCountGap: CGFloat = 4
    private static let metricGap: CGFloat = 6
    private static let activeCountMinWidth: CGFloat = 12
    private static let stoppedCountMinWidth: CGFloat = 18

    let presentation: WorkspaceHomeStatusPresentation

    var body: some View {
        ViewThatFits(in: .horizontal) {
            symbolCluster(showCounts: true)
            symbolCluster(showCounts: false)
        }
        .font(.subheadline.weight(.semibold))
        .imageScale(.medium)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func symbolCluster(showCounts: Bool) -> some View {
        HStack(alignment: .center, spacing: showCounts ? Self.metricGap : 4) {
            switch presentation.kind {
            case .attention:
                statusSymbol("exclamationmark.triangle.fill", tint: .themeOrange)

            case .active:
                if showCounts {
                    statusMetric(
                        symbol: "play.circle.fill",
                        count: presentation.activeCount,
                        tint: .themeGreen,
                        minimumCountWidth: Self.activeCountMinWidth
                    )
                    if presentation.stoppedCount > 0 {
                        statusMetric(
                            symbol: "stop.circle",
                            count: presentation.stoppedCount,
                            tint: .themeComment,
                            minimumCountWidth: Self.stoppedCountMinWidth
                        )
                    }
                } else {
                    statusSymbol("play.circle.fill", tint: .themeGreen)
                    if presentation.stoppedCount > 0 {
                        statusSymbol("stop.circle", tint: .themeComment)
                    }
                }

            case .stopped:
                if showCounts {
                    statusMetric(
                        symbol: "stop.circle",
                        count: presentation.stoppedCount,
                        tint: .themeComment,
                        minimumCountWidth: Self.stoppedCountMinWidth
                    )
                } else {
                    statusSymbol("stop.circle", tint: .themeComment)
                }

            case nil:
                EmptyView()
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func statusMetric(symbol: String, count: Int, tint: Color, minimumCountWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: Self.symbolCountGap) {
            statusSymbol(symbol, tint: tint)
            countText(count, tint: tint)
                .frame(minWidth: minimumCountWidth, alignment: .trailing)
        }
        .frame(minWidth: Self.symbolWidth + Self.symbolCountGap + minimumCountWidth, alignment: .leading)
    }

    private func statusSymbol(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .frame(width: Self.symbolWidth, alignment: .center)
    }

    private func countText(_ count: Int, tint: Color) -> some View {
        Text(SessionFormatting.compactCount(count))
            .foregroundStyle(tint)
            .lineLimit(1)
            .monospacedDigit()
            .minimumScaleFactor(0.82)
            .allowsTightening(true)
    }
}
