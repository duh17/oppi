import SwiftUI

func workspaceListSummary(
    for workspaceId: String,
    in summaries: [String: WorkspaceListSummary]
) -> WorkspaceListSummary {
    summaries[workspaceId] ?? WorkspaceListSummary(
        workspaceId: workspaceId,
        activeCount: 0,
        stoppedCount: 0,
        hasAttention: false
    )
}

func sortedWorkspacesForList(
    _ workspaces: [Workspace],
    summaries: [String: WorkspaceListSummary]
) -> [Workspace] {
    workspaces.sorted { lhs, rhs in
        let lhsSummary = workspaceListSummary(for: lhs.id, in: summaries)
        let rhsSummary = workspaceListSummary(for: rhs.id, in: summaries)

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

/// Navigation target pairing a workspace with its server for on-demand connection switching.
struct WorkspaceNavTarget: Hashable {
    let serverId: String
    let workspace: Workspace
}

/// Navigation target for opening a session directly from the workspace overview.
struct WorkspaceSessionNavTarget: Hashable {
    let serverId: String
    let sessionId: String
    let routeScope: SessionRouteScope?

    var workspaceId: String? { routeScope?.workspaceId }

    init(
        serverId: String,
        sessionId: String,
        workspaceId: String? = nil,
        routeScope: SessionRouteScope? = nil
    ) {
        self.serverId = serverId
        self.sessionId = sessionId
        if let routeScope {
            self.routeScope = routeScope
        } else if let workspaceId = Self.normalizedWorkspaceId(workspaceId) {
            self.routeScope = .workspace(workspaceId)
        } else {
            self.routeScope = nil
        }
    }

    func withWorkspaceIdIfMissing(_ workspaceId: String?) -> WorkspaceSessionNavTarget {
        guard routeScope == nil else { return self }
        return WorkspaceSessionNavTarget(
            serverId: serverId,
            sessionId: sessionId,
            routeScope: Self.normalizedWorkspaceId(workspaceId).map(SessionRouteScope.workspace)
        )
    }

    private static func normalizedWorkspaceId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum WorkspaceLinkedFileKind: Hashable {
    case workspaceFile(path: String, fileName: String)
}

struct WorkspaceLinkedFileNavTarget: Hashable {
    let serverId: String
    let workspaceId: String
    let worktreeId: String?
    let kind: WorkspaceLinkedFileKind
    let navigationContext: FileBrowserNavigationContext?

    init(
        serverId: String,
        workspaceId: String,
        worktreeId: String? = nil,
        kind: WorkspaceLinkedFileKind,
        navigationContext: FileBrowserNavigationContext? = nil
    ) {
        self.serverId = serverId
        self.workspaceId = workspaceId
        self.worktreeId = worktreeId
        self.kind = kind
        self.navigationContext = navigationContext
    }

    static func workspaceFile(
        serverId: String,
        workspaceId: String,
        worktreeId: String? = nil,
        path: String,
        fileName: String? = nil,
        navigationContext: FileBrowserNavigationContext? = nil
    ) -> WorkspaceLinkedFileNavTarget {
        let resolvedFileName: String
        if let fileName, !fileName.isEmpty {
            resolvedFileName = fileName
        } else {
            resolvedFileName = path.split(separator: "/").last.map(String.init) ?? path
        }

        return WorkspaceLinkedFileNavTarget(
            serverId: serverId,
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            kind: .workspaceFile(path: path, fileName: resolvedFileName),
            navigationContext: navigationContext
        )
    }
}

/// Utility destinations that live under the Workspaces navigation stack.
/// These are intentionally not bottom-tab destinations; they are secondary
/// management surfaces reached from the server/environment menu.
enum WorkspaceUtilityNavTarget: Hashable {
    case schedules
    case agents
    case manageServers
    case appSettings

    var isReleaseEnabled: Bool {
        switch self {
        case .schedules, .agents:
            ReleaseFeatures.agentAndScheduleManagementEnabled
        case .manageServers, .appSettings:
            true
        }
    }
}

struct WorkspaceCreateSheetContext: Identifiable {
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

struct WorkspaceScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: WorkspaceNavTarget

    @State private var scopedConnection: ServerConnection?

    var body: some View {
        Group {
            if let connection = scopedConnection {
                WorkspaceDetailView(workspace: target.workspace)
                    .withServerScopedEnvironment(connection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: target.serverId) {
            guard await coordinator.switchToServerReady(target.serverId) else { return }
            scopedConnection = coordinator.connection(for: target.serverId)
        }
    }
}

struct WorkspaceSessionScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: WorkspaceSessionNavTarget

    @State private var scopedConnection: ServerConnection?

    var body: some View {
        Group {
            if let connection = scopedConnection {
                ChatView(
                    sessionId: target.sessionId,
                    workspaceIdHint: target.workspaceId,
                    routeScope: target.routeScope,
                    ownsWorkspacePathBackNavigation: true
                )
                .withServerScopedEnvironment(connection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: target.serverId) {
            guard await coordinator.switchToServerReady(target.serverId) else { return }
            scopedConnection = coordinator.connection(for: target.serverId)
        }
    }
}

struct WorkspaceFileBrowserDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: FileBrowserNavTarget

    @State private var scopedConnection: ServerConnection?

    private var targetServerId: String {
        target.serverId
    }

    private var resolvedConnection: ServerConnection? {
        scopedConnection
    }

    var body: some View {
        Group {
            if let connection = resolvedConnection {
                FileBrowserView(
                    serverId: targetServerId,
                    workspaceId: target.workspaceId,
                    worktreeId: target.worktreeId,
                    initialPath: target.path
                )
                .withServerScopedEnvironment(connection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: targetServerId) {
            guard await coordinator.switchToServerReady(targetServerId) else { return }
            scopedConnection = coordinator.connection(for: targetServerId)
        }
    }
}

struct WorkspaceLinkedFileDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: WorkspaceLinkedFileNavTarget

    @State private var scopedConnection: ServerConnection?

    var body: some View {
        Group {
            if let connection = scopedConnection {
                switch target.kind {
                case .workspaceFile(let path, let fileName):
                    FileBrowserContentView(
                        workspaceId: target.workspaceId,
                        worktreeId: target.worktreeId,
                        filePath: path,
                        fileName: fileName,
                        navigationContext: target.navigationContext
                    )
                    .withServerScopedEnvironment(connection)
                }
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: target.serverId) {
            guard await coordinator.switchToServerReady(target.serverId) else { return }
            scopedConnection = coordinator.connection(for: target.serverId)
        }
    }
}

extension View {
    func withServerScopedEnvironment(_ connection: ServerConnection) -> some View {
        self
            .environment(connection)
            .environment(\.apiClient, connection.apiClient)
            .environment(\.iconAssetCache, connection.iconAssetCache)
            .environment(connection.chatState)
            .environment(connection.sessionStore)
            .environment(connection.workspaceStore)
            .environment(connection.askRequestStore)
            .environment(connection.audioPlayer)
            .environment(connection.gitStatusStore)
            .environment(connection.fileIndexStore)
            .environment(connection.messageQueueStore)
    }
}

private struct WorkspaceHomeSessionPreview: Identifiable {
    let presentation: SessionRowPresentation

    var id: String { presentation.session.id }
}

enum WorkspaceHomeRowBodyAction: Equatable {
    case openWorkspace
    case toggleSessionPreviews
}

enum WorkspaceHomeListPresentationMode: Equatable {
    case compact
    case splitSidebar

    init(navigationPresentation: WorkspaceNavigationPresentation) {
        switch navigationPresentation {
        case .stack:
            self = .compact
        case .split:
            self = .splitSidebar
        }
    }

    var showsInlineSessionPreviews: Bool {
        self == .compact
    }

    func rowBodyAction(isE2EInviteMode: Bool) -> WorkspaceHomeRowBodyAction {
        switch self {
        case .compact:
            isE2EInviteMode ? .openWorkspace : .toggleSessionPreviews
        case .splitSidebar:
            .openWorkspace
        }
    }
}

enum WorkspaceHomePreviewPlanner {
    static let maxRows = 5
    static let preferredYourTurnRows = 3

    static func previewableSessions(_ sessions: [Session]) -> [Session] {
        sessions.filter { $0.status != .stopped }
    }

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
    @Environment(\.composerDraftStore) private var composerDraftStore
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
            ToolbarItem(placement: .topBarTrailing) {
                if let selectedServer {
                    serverSwitcher(selectedServer)
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if !servers.isEmpty {
                    if ReleaseFeatures.agentAndScheduleManagementEnabled {
                        schedulesButton
                        agentsButton
                    }
                    Spacer()
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
        .navigationDestination(for: WorkspaceLinkedFileNavTarget.self) { target in
            WorkspaceLinkedFileDestinationView(target: target)
        }
        .navigationDestination(for: FileBrowserNavTarget.self) { target in
            WorkspaceFileBrowserDestinationView(target: target)
        }
        .navigationDestination(for: PairedServer.self) { server in
            ServerDetailView(server: server)
        }
        .navigationDestination(for: WorkspaceUtilityNavTarget.self) { target in
            if target.isReleaseEnabled {
                switch target {
                case .schedules:
                    ScheduleManagementView()
                case .agents:
                    AgentManagementView()
                case .manageServers:
                    ServerView()
                case .appSettings:
                    SettingsView()
                }
            } else {
                EmptyView()
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
            await consumeWorkspaceDeepLinkIfNeeded()
            triggerGuidedCreateIfNeeded()
            autoOpenE2EWorkspaceIfRequested()
        }
        .onChange(of: navigation.pendingWorkspaceDeepLink != nil) { _, hasPending in
            guard hasPending else { return }
            Task { @MainActor in
                await consumeWorkspaceDeepLinkIfNeeded()
            }
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
        if let serverConn = coordinator.connection(for: server.id) {
            return WorkspaceServerStatusPresentation.derive(
                health: serverConn.serverHealth(forServer: server.id)
            )
        }

        return WorkspaceServerStatusPresentation.derive(
            health: ServerHealth.derive(
                freshnessState: .offline,
                freshnessLabel: "Offline",
                transportStates: [.disconnected],
                hasCachedCatalog: !workspacesForServer(server.id).isEmpty
            )
        )
    }

    private func serverBadgeConnectionState(for server: PairedServer) -> ServerBadgeConnectionState {
        ServerBadgeConnectionState(serverStatusPresentation(for: server))
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

            if ReleaseFeatures.agentAndScheduleManagementEnabled {
                Button {
                    navigation.openWorkspaceUtility(.schedules)
                } label: {
                    Label("Schedules", systemImage: "clock")
                }

                Button {
                    navigation.openWorkspaceUtility(.agents)
                } label: {
                    Label("Agents", systemImage: "person.crop.circle")
                }
            }

            Button {
                navigation.openWorkspaceUtility(.manageServers)
            } label: {
                Label("Manage Servers", systemImage: "server.rack")
            }

            Button {
                navigation.openWorkspaceUtility(.appSettings)
            } label: {
                Label("App Settings", systemImage: "gear")
            }
        } label: {
            ServerSwitcherPill(
                server: current,
                connectionState: serverBadgeConnectionState(for: current)
            )
        }
        .accessibilityLabel("Current server: \(current.name)")
        .accessibilityValue(serverBadgeConnectionState(for: current).title)
    }

    private var schedulesButton: some View {
        Button {
            navigation.openWorkspaceUtility(.schedules)
        } label: {
            Image(systemName: "clock")
        }
        .foregroundStyle(.themeFg)
        .accessibilityLabel("Schedules")
        .accessibilityHint("Opens schedule management")
        .accessibilityIdentifier("workspace.schedules.open")
    }

    private var agentsButton: some View {
        Button {
            navigation.openWorkspaceUtility(.agents)
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .foregroundStyle(.themeFg)
        .accessibilityLabel("Agents")
        .accessibilityHint("Opens agent management")
        .accessibilityIdentifier("workspace.agents.open")
    }

    private var quickSessionButton: some View {
        Button {
            navigation.showQuickSession = true
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .foregroundStyle(.themeFg)
        .accessibilityLabel("Start Quick Session")
        .accessibilityHint("Opens the quick session composer")
        .accessibilityIdentifier("workspace.quickSession.start")
    }

    private func switchVisibleServer(to server: PairedServer) {
        Task { @MainActor in
            guard await coordinator.switchToServerReady(server) else { return }
            navigation.clearWorkspaceSelections()
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
        let workspaces = sortedWorkspacesForList(workspaceCatalog, summaries: summaries)
        let isUnreachable = serverStatusPresentation(for: server).isUnreachable

        Section {
            if workspaces.isEmpty {
                Text(isUnreachable ? "Offline — cached workspaces unavailable" : "No workspaces")
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
                    .listRowBackground(Color.themeBg)
            } else {
                ForEach(workspaces) { workspace in
                    let summary = workspaceListSummary(for: workspace.id, in: summaries)
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
        let mode = WorkspaceHomeListPresentationMode(
            navigationPresentation: navigation.workspaceNavigationPresentation
        )
        let showsSessionPreviews = mode.showsInlineSessionPreviews
        let isExpanded = showsSessionPreviews && isWorkspaceExpanded(key: key, summary: summary)
        let sessionPreviews = workspaceSessionPreviews(workspaceId: workspace.id, connection: connection)
        let workspaceAccessibilityName = workspace.runtime == .sandbox
            ? "sandbox workspace \(workspace.name)"
            : workspace.name
        let rowBodyActionKind = mode.rowBodyAction(
            isE2EInviteMode: ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"] != nil
        )
        let rowBodyAction = {
            switch rowBodyActionKind {
            case .openWorkspace:
                navigation.openWorkspace(WorkspaceNavTarget(serverId: serverId, workspace: workspace))
            case .toggleSessionPreviews:
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
            .accessibilityLabel(
                rowBodyAccessibilityLabel(
                    action: rowBodyActionKind,
                    isExpanded: isExpanded,
                    name: workspaceAccessibilityName
                )
            )
            .accessibilityValue(
                rowBodyActionKind == .toggleSessionPreviews ? (isExpanded ? "Expanded" : "Collapsed") : ""
            )
            .accessibilityHint(rowBodyAccessibilityHint(action: rowBodyActionKind))

            let target = WorkspaceNavTarget(serverId: serverId, workspace: workspace)
            Button {
                navigation.openWorkspace(target)
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
            if rowBodyActionKind == .openWorkspace {
                navigation.openWorkspace(WorkspaceNavTarget(serverId: serverId, workspace: workspace))
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

        if showsSessionPreviews && isExpanded {
            if sessionPreviews.isEmpty {
                WorkspaceHomePreviewEmptyRow()
                    .listRowBackground(Color.themeBg)
            } else {
                ForEach(sessionPreviews) { preview in
                    Button {
                        navigation.openWorkspaceSession(
                            WorkspaceSessionNavTarget(serverId: serverId, sessionId: preview.presentation.session.id),
                            workspace: WorkspaceNavTarget(serverId: serverId, workspace: workspace)
                        )
                    } label: {
                        WorkspaceHomeSessionPreviewRow(preview: preview)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspaceHome.sessionPreview.\(preview.presentation.session.id)")
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

    private func rowBodyAccessibilityLabel(
        action: WorkspaceHomeRowBodyAction,
        isExpanded: Bool,
        name: String
    ) -> String {
        switch action {
        case .openWorkspace:
            "Open \(name)"
        case .toggleSessionPreviews:
            isExpanded ? "Collapse sessions for \(name)" : "Expand sessions for \(name)"
        }
    }

    private func rowBodyAccessibilityHint(action: WorkspaceHomeRowBodyAction) -> String {
        switch action {
        case .openWorkspace:
            "Opens the workspace session list"
        case .toggleSessionPreviews:
            "Shows or hides the workspace session preview"
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
        let previewableSessions = WorkspaceHomePreviewPlanner.previewableSessions(workspaceSessions)
        guard !previewableSessions.isEmpty else { return [] }

        var attentionBySessionId: [String: SessionListAttentionCounts] = [:]
        var yourTurn: [Session] = []
        var working: [Session] = []

        for session in previewableSessions {
            let attention = SessionRowPresentationBuilder.attentionCounts(
                sessionId: session.id,
                pendingAskCountForSession: { pendingAskCount(for: $0, connection: connection) }
            )
            attentionBySessionId[session.id] = attention

            switch SessionListPresentation.activeSectionKind(for: session, attention: attention) {
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
                connection: connection
            )
        }
        previews.append(contentsOf: activePreviewRows)

        return previews
    }

    private func pendingAskCount(for sessionId: String, connection: ServerConnection) -> Int {
        SessionListAttentionMerger.askCount(
            listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
            hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
            hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
        )
    }

    private func previewRow(
        session: Session,
        attention: SessionListAttentionCounts,
        connection: ServerConnection
    ) -> WorkspaceHomeSessionPreview {
        WorkspaceHomeSessionPreview(
            presentation: SessionRowPresentationBuilder.make(
                session: session,
                pendingAskCount: attention.askCount,
                pendingAsk: connection.askRequestStore.pending(for: session.id),
                unreadCompletionAt: connection.sessionStore.unreadCompletionDate(for: session.id)
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

    // MARK: - Session Helpers

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
        navigation.openWorkspace(WorkspaceNavTarget(serverId: server.id, workspace: workspace))
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
        await TimelineCache.shared.removeTrace(pending.session.id, serverId: pending.serverId)
        do {
            try await api.deleteWorkspaceSession(
                workspaceId: pending.workspaceId,
                sessionId: pending.session.id
            )
            clearComposerDraft(for: pending)
            await refresh(force: true)
        } catch let apiError as APIError {
            if case .server(let status, _) = apiError, status == 404 {
                clearComposerDraft(for: pending)
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

    private func clearComposerDraft(for pending: WorkspaceHomePendingDeleteSession) {
        composerDraftStore?.clearDraft(
            serverID: pending.serverId,
            workspaceID: pending.workspaceId,
            sessionID: pending.session.id
        )
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
        navigation.openWorkspace(target)
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
    private func consumeWorkspaceDeepLinkIfNeeded() async {
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
        guard await coordinator.switchToServerReady(server) else {
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

struct ServerSwitcherPill: View {
    let server: PairedServer
    let connectionState: ServerBadgeConnectionState

    var body: some View {
        HStack(spacing: 6) {
            RuntimeBadge(
                compact: true,
                icon: server.resolvedBadgeIcon,
                tint: connectionState.tintColor
            )

            Text(server.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
        }
        .foregroundStyle(.themeFg)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.themeComment.opacity(0.14), in: Capsule())
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
        Text("No active sessions")
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
