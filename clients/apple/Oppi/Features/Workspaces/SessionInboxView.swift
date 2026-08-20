import SwiftUI

private struct SessionInboxItem: Identifiable {
    let serverId: String
    let connection: ServerConnection
    let session: Session
    let workspace: Workspace?

    var id: String { "\(serverId):\(session.id)" }
}

struct SessionInboxStoppedDayGroup<Item>: Identifiable {
    let day: Date
    let items: [Item]

    var id: String { SessionInboxStoppedDayPolicy.groupID(for: day) }
}

struct SessionInboxStoppedDayPolicy {
    static let visibleDayCount = 3

    static func includesStoppedSession(_ session: Session) -> Bool {
        session.ephemeral != true
    }

    static func visibleRangeStart(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(visibleDayCount - 1), to: today) ?? today
    }

    static func groups<Item>(
        _ items: [Item],
        now: Date,
        calendar: Calendar,
        activityDate: (Item) -> Date
    ) -> [SessionInboxStoppedDayGroup<Item>] {
        let rangeStart = visibleRangeStart(now: now, calendar: calendar)
        var itemsByDay: [Date: [Item]] = [:]
        itemsByDay.reserveCapacity(visibleDayCount)

        for item in items {
            let date = activityDate(item)
            guard date >= rangeStart else { continue }
            let day = calendar.startOfDay(for: date)
            itemsByDay[day, default: []].append(item)
        }

        return itemsByDay.keys.sorted(by: >).map { day in
            SessionInboxStoppedDayGroup(day: day, items: itemsByDay[day] ?? [])
        }
    }

    static func groupID(for day: Date) -> String {
        "stopped-day-\(Int(day.timeIntervalSince1970))"
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func isExpandedByDefault(day: Date, now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(day, inSameDayAs: now)
    }
}

private typealias SessionInboxStoppedGroup = SessionInboxStoppedDayGroup<SessionInboxItem>

private struct SessionInboxViewData {
    let yourTurn: [SessionInboxItem]
    let working: [SessionInboxItem]
    let stoppedGroups: [SessionInboxStoppedGroup]
    let searchMatches: [SessionInboxItem]
    let isSearching: Bool
    let isEmpty: Bool
}

private struct SessionInboxPendingDelete: Identifiable {
    let serverId: String
    let routeScope: SessionRouteScope
    let session: Session

    var id: String { "\(serverId):\(session.id)" }
}

enum WorkspaceCatalogAvailability: Equatable {
    case loading
    case unavailable
    case empty
    case available

    init(hasWorkspaces: Bool, isLoaded: Bool, isSyncing: Bool, lastSyncFailed: Bool) {
        if hasWorkspaces {
            self = .available
        } else if isSyncing {
            self = .loading
        } else if lastSyncFailed {
            self = .unavailable
        } else if isLoaded {
            self = .empty
        } else {
            self = .loading
        }
    }
}

enum WorkspaceSidebarDisclosurePolicy {
    static let defaultExpanded = true
}

struct WorkspaceSidebarPrimaryUtilityItem: Equatable {
    let target: WorkspaceUtilityNavTarget
    let title: String
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let minimumHitHeight: CGFloat
}

enum WorkspaceSidebarPrimaryUtilities {
    static let items: [WorkspaceSidebarPrimaryUtilityItem] = [
        .init(
            target: .agents,
            title: "Agents",
            systemImage: "person.crop.circle",
            accessibilityLabel: "Agents",
            accessibilityIdentifier: "workspace.agents.open",
            minimumHitHeight: 44
        ),
        .init(
            target: .schedules,
            title: "Schedules",
            systemImage: "clock",
            accessibilityLabel: "Schedules",
            accessibilityIdentifier: "workspace.schedules.open",
            minimumHitHeight: 44
        ),
        .init(
            target: .skills,
            title: "Skills",
            systemImage: "sparkles.rectangle.stack",
            accessibilityLabel: "Open Skills",
            accessibilityIdentifier: "workspace.skills.open",
            minimumHitHeight: 44
        ),
        .init(
            target: .extensions,
            title: "Extensions",
            systemImage: "shippingbox",
            accessibilityLabel: "Open Extensions",
            accessibilityIdentifier: "workspace.extensions.open",
            minimumHitHeight: 44
        ),
    ]
}

enum SessionInboxSessionRouting {
    static func routeScope(for session: Session) -> SessionRouteScope? {
        if session.control != nil { return .control }
        guard let workspaceId = session.workspaceId, !workspaceId.isEmpty else { return nil }
        return .workspace(workspaceId)
    }

    static func allSessionsContext(for session: Session, workspaceName: String?) -> String? {
        if session.control != nil { return "Oppi Control" }
        return session.workspaceName ?? workspaceName
    }
}

/// Sessions-first home surface.
///
/// The workspace sidebar owns project selection. This view keeps the main
/// content focused on session rows and uses small row context instead of a
/// workspace header card.
struct SessionInboxView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.composerDraftStore) private var composerDraftStore
    @Environment(\.theme) private var theme

    let onOpenSidebar: (() -> Void)?

    @State private var searchText = ""
    @State private var searchStore = SessionSearchStore()
    @State private var error: String?
    @State private var isCreating = false
    @State private var pendingDelete: SessionInboxPendingDelete?
    @State private var expandedStoppedGroupIDs: Set<String> = []
    @State private var collapsedStoppedGroupIDs: Set<String> = []
    @State private var hasAutoOpenedE2EWorkspace = false
    @State private var hasAutoCreatedE2ESession = false
    @State private var hasAutoOpenedE2ESession = false
    @State private var providerSetupState: ProviderSetupState = .unknown

    init(onOpenSidebar: (() -> Void)? = nil) {
        self.onOpenSidebar = onOpenSidebar
    }

    private var activeServerId: String? {
        coordinator.activeServerId
    }

    private var activeConnection: ServerConnection? {
        activeServerId.flatMap { coordinator.connection(for: $0) }
    }

    private var selectedWorkspace: WorkspaceNavTarget? {
        guard navigation.workspaceNavigationPresentation == .split,
              let activeServerId,
              let filter = navigation.selectedWorkspaceFilter,
              filter.serverId == activeServerId else { return nil }
        return filter
    }

    private var servers: [PairedServer] {
        serverStore.servers
    }

    private var selectedServer: PairedServer? {
        if let activeServerId,
           let server = servers.first(where: { $0.id == activeServerId }) {
            return server
        }
        return servers.first
    }

    private var hasSearchQuery: Bool {
        SessionListSearchPresentation.hasQuery(searchText)
    }

    private var viewData: SessionInboxViewData {
        let items = sessionItems()
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.session.id, $0) })
        if let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: items.map(\.session),
            query: searchText,
            extraCandidates: { session in
                [itemsByID[session.id]?.workspace?.name]
            },
            serverResults: searchStore.results,
            completedServerQuery: searchStore.completedServerQuery,
            activeServerQuery: searchStore.activeServerQuery,
            snippetsBySessionId: searchStore.snippetsBySessionId
        ) {
            let searchItems = matches.compactMap { match in
                inboxItem(for: match.session, existing: itemsByID[match.session.id])
            }
            return SessionInboxViewData(
                yourTurn: [],
                working: [],
                stoppedGroups: [],
                searchMatches: searchItems,
                isSearching: searchStore.isSearching,
                isEmpty: searchItems.isEmpty && !searchStore.isSearching
            )
        }

        var yourTurn: [SessionInboxItem] = []
        var working: [SessionInboxItem] = []
        var stopped: [SessionInboxItem] = []

        for item in items {
            let attention = attentionCounts(for: item)
            switch SessionListPresentation.activeSectionKind(for: item.session, attention: attention) {
            case .yourTurn:
                yourTurn.append(item)
            case .working:
                working.append(item)
            case nil:
                if SessionInboxStoppedDayPolicy.includesStoppedSession(item.session) {
                    stopped.append(item)
                }
            }
        }

        yourTurn.sort { lhs, rhs in
            SessionListPresentation.compareYourTurn(
                lhs.session,
                lhsAttention: attentionCounts(for: lhs),
                rhs.session,
                rhsAttention: attentionCounts(for: rhs)
            )
        }
        working.sort { SessionListPresentation.compareWorking($0.session, $1.session) }
        stopped.sort {
            if $0.session.lastActivity != $1.session.lastActivity {
                return $0.session.lastActivity > $1.session.lastActivity
            }
            return $0.session.id < $1.session.id
        }

        let stoppedGroups = recentStoppedGroups(stopped)
        return SessionInboxViewData(
            yourTurn: yourTurn,
            working: working,
            stoppedGroups: stoppedGroups,
            searchMatches: [],
            isSearching: false,
            isEmpty: yourTurn.isEmpty && working.isEmpty && stoppedGroups.isEmpty
        )
    }

    var body: some View {
        let data = viewData

        List {
            if selectedWorkspace == nil,
               ProviderSetupPromptPolicy.shouldShow(for: providerSetupState),
               let selectedServer {
                Section {
                    providerSetupPrompt(for: selectedServer)
                        .listRowBackground(theme.bg.primary)
                }
            }

            if selectedServerRefreshFailed, !data.isEmpty, let selectedServer {
                Section {
                    Label(
                        "Showing cached server data for \(selectedServer.name). Pull to retry.",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.themeOrange)
                    .listRowBackground(theme.bg.primary)
                    .accessibilityIdentifier("workspace.sessionList.cachedWarning")
                }
            }

            if hasSearchQuery {
                if data.isSearching && data.searchMatches.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Searching sessions…")
                            Spacer()
                        }
                        .frame(minHeight: 88)
                        .listRowBackground(theme.bg.primary)
                    }
                } else if data.searchMatches.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Matching Sessions",
                            systemImage: "magnifyingglass",
                            description: Text("No sessions match “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                        )
                        .listRowBackground(theme.bg.primary)
                    }
                } else {
                    sessionSection("Results", items: data.searchMatches)
                }
            } else {
                if !data.yourTurn.isEmpty {
                    sessionSection("Your Turn", items: data.yourTurn)
                }

                if !data.working.isEmpty {
                    sessionSection("Working", items: data.working)
                }

                ForEach(data.stoppedGroups) { group in
                    stoppedSessionSection(group)
                }

                if data.isEmpty {
                    Section {
                        emptyState
                            .listRowBackground(theme.bg.primary)
                    }
                }
            }
        }
        .accessibilityIdentifier("workspace.sessionList")
        .listStyle(.plain)
        .themedListSurface()
        .navigationTitle(inboxNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search sessions")
        .onChange(of: searchText) { _, newValue in
            searchStore.search(
                query: newValue,
                workspaceId: selectedWorkspace?.workspace.id,
                apiClient: activeConnection?.apiClient
            )
        }
        .toolbar { toolbarContent }
        .refreshable {
            async let refresh: () = refreshVisibleServer()
            async let providers: () = loadProviderSetupState()
            _ = await (refresh, providers)
        }
        .task(id: activeServerId) {
            providerSetupState = .unknown
            async let refresh: () = refreshVisibleServer()
            async let providers: () = loadProviderSetupState()
            _ = await (refresh, providers)
            await applyE2ELaunchHintsIfNeeded()
        }
        .task(id: selectedWorkspace?.workspace.id) {
            await applyE2ELaunchHintsIfNeeded()
        }
        .onChange(of: navigation.workspacePath.count) { oldCount, newCount in
            guard newCount < oldCount else { return }
            Task { await loadProviderSetupState() }
        }
        .onChange(of: navigation.splitDetailPath.count) { oldCount, newCount in
            guard newCount < oldCount else { return }
            Task { await loadProviderSetupState() }
        }
        .overlay {
            if isCreating {
                ProgressView("Creating session…")
                    .tint(.themeCyan)
                    .foregroundStyle(.themeFg)
                    .padding()
                    .themedFloatingPanel()
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
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDelete {
                Button("Delete Session", role: .destructive) {
                    let context = pendingDelete
                    self.pendingDelete = nil
                    Task { await deleteSession(context) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            if let pendingDelete {
                Text(SessionDeleteConfirmationPolicy.deleteMessage(for: pendingDelete.session))
            }
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
        .navigationDestination(for: WorkspaceConfigurationNavTarget.self) { target in
            WorkspaceConfigurationScopedDestinationView(target: target.workspaceTarget)
        }
        .navigationDestination(for: WorkspaceUtilityNavTarget.self) { target in
            if target.isReleaseEnabled {
                switch target {
                case .schedules:
                    ScheduleManagementView()
                case .agents:
                    AgentManagementView()
                case .skills:
                    ServerSkillsView()
                case .extensions:
                    ServerExtensionsView()
                case .manageServers:
                    ServerView()
                case .appSettings:
                    SettingsView()
                }
            } else {
                EmptyView()
            }
        }
        .navigationDestination(for: ServerResourceDetailNavTarget.self) { target in
            ServerResourceDetailDestinationView(target: target)
        }
        .navigationDestination(for: ServerSkillBrowserNavTarget.self) { target in
            ServerSkillBrowserScopedDestinationView(target: target)
        }
        .navigationDestination(for: ServerSkillFileNavTarget.self) { target in
            ServerSkillFileScopedDestinationView(target: target)
        }
        .navigationDestination(for: ServerDetailsNavTarget.self) { target in
            ServerDetailsScopedDestinationView(target: target)
        }
        .navigationDestination(for: ModelProvidersNavTarget.self) { target in
            ModelProvidersScopedDestinationView(target: target)
        }
    }

    private var inboxNavigationTitle: String {
        selectedWorkspace?.workspace.name ?? "All Sessions"
    }

    @ViewBuilder
    private var inboxTitle: some View {
        if let selectedWorkspace {
            HStack(spacing: 7) {
                WorkspaceRuntimeIcon(workspace: selectedWorkspace.workspace, size: 17, frameSize: 22)
                Text(selectedWorkspace.workspace.name)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(.themeFg)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Workspace sessions: \(selectedWorkspace.workspace.name)")
            .accessibilityIdentifier("workspace.inbox.title")
        } else {
            Text("All Sessions")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("All Sessions")
                .accessibilityIdentifier("workspace.inbox.title")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            inboxTitle
        }

        ToolbarItem(placement: .topBarLeading) {
            if selectedWorkspace == nil, let onOpenSidebar {
                Button {
                    onOpenSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .foregroundStyle(.themeFg)
                .accessibilityLabel("Show workspaces")
                .accessibilityIdentifier("workspace.sidebar.open")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if let selectedWorkspace {
                workspaceConfigurationButton(selectedWorkspace)
            } else if let selectedServer {
                serverSwitcher(selectedServer)
            }
        }

        if let selectedWorkspace {
            ToolbarItem(placement: .bottomBar) {
                workspaceFilesButton(selectedWorkspace)
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
        }

        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            newSessionButton
        }
    }

    private func serverSwitcher(_ current: PairedServer) -> some View {
        Menu {
            ForEach(servers) { server in
                Button {
                    Task { await switchVisibleServer(to: server) }
                } label: {
                    Label(
                        serverMenuTitle(server),
                        systemImage: server.id == current.id ? "checkmark.circle.fill" : server.resolvedBadgeIcon.symbolName
                    )
                }
                .accessibilityValue(serverBadgeConnectionState(for: server).title)
            }

            Section("Connection") {
                let state = serverBadgeConnectionState(for: current)
                Label(
                    ServerConnectionLanePresentation.title(
                        server: current,
                        connection: coordinator.connection(for: current.id),
                        state: state,
                        isPreparing: coordinator.preparingServerIds.contains(current.id)
                    ),
                    systemImage: state.systemImage
                )

                if state != .connected {
                    Button {
                        Task { await coordinator.retryServerConnection(current.id) }
                    } label: {
                        Label("Retry Connection", systemImage: "arrow.clockwise")
                    }
                }
            }

            Divider()

            Button {
                navigation.openModelProviders(ModelProvidersNavTarget(serverId: current.id))
            } label: {
                Label("Model Providers", systemImage: "cpu")
            }
            .accessibilityIdentifier("workspace.modelProviders.open")

            Button {
                navigation.openWorkspaceUtility(.manageServers)
            } label: {
                Label("Manage Servers", systemImage: "server.rack")
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

    private func providerSetupPrompt(for server: PairedServer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Finish server setup", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(.themeFg)

            Text("Connect a model provider before starting a session on \(server.name).")
                .font(.subheadline)
                .foregroundStyle(.themeComment)

            Button {
                navigation.openModelProviders(ModelProvidersNavTarget(serverId: server.id))
            } label: {
                Label("Configure Model Provider", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("workspace.providerSetup.open")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func loadProviderSetupState() async {
        guard let requestedServerId = activeServerId else {
            providerSetupState = .unavailable
            return
        }
        guard let client = await coordinator.apiClientReady(for: requestedServerId) else {
            guard requestedServerId == coordinator.activeServerId else { return }
            providerSetupState = .unavailable
            return
        }

        do {
            let statuses = try await client.listProviderAuthStatus()
            guard requestedServerId == coordinator.activeServerId else { return }
            providerSetupState = ProviderSetupState(providerStatuses: statuses)
        } catch {
            guard requestedServerId == coordinator.activeServerId else { return }
            providerSetupState = .unavailable
        }
    }

    private func switchVisibleServer(to server: PairedServer) async {
        guard await coordinator.switchToServerReady(server) else { return }
        searchText = ""
        searchStore.clear()
        error = nil
        expandedStoppedGroupIDs.removeAll()
        collapsedStoppedGroupIDs.removeAll()
        navigation.showAllWorkspaceSessions()
    }

    private func refreshVisibleServer() async {
        guard let activeServerId else { return }
        await coordinator.refreshServer(activeServerId, force: true)
    }

    private func serverMenuTitle(_ server: PairedServer) -> String {
        let state = serverBadgeConnectionState(for: server)
        guard state != .connected else { return server.name }
        return "\(server.name) — \(state.title)"
    }

    private func serverBadgeConnectionState(for server: PairedServer) -> ServerBadgeConnectionState {
        guard let connection = coordinator.connection(for: server.id) else {
            return ServerBadgeConnectionState(
                serverStatusPresentation(for: server),
                isPreparing: coordinator.preparingServerIds.contains(server.id)
            )
        }
        return ServerBadgeConnectionState(
            serverStatusPresentation(for: server),
            hasSyncFailure: connection.workspaceStore.lastSyncFailed
                || connection.sessionStore.lastSyncFailed,
            isPreparing: coordinator.preparingServerIds.contains(server.id)
        )
    }

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
                hasCachedCatalog: !(coordinator.connection(for: server.id)?.workspaceStore.workspaces ?? []).isEmpty
            )
        )
    }

    private var selectedServerRefreshFailed: Bool {
        guard let activeConnection else { return false }
        return activeConnection.workspaceStore.lastSyncFailed
            || activeConnection.sessionStore.lastSyncFailed
    }

    private var selectedServerIsSyncing: Bool {
        activeConnection?.workspaceStore.isSyncing == true
            || activeConnection?.sessionStore.isSyncing == true
    }

    @ViewBuilder
    private var emptyState: some View {
        if activeServerId == nil {
            ContentUnavailableView(
                "No Servers",
                systemImage: "server.rack",
                description: Text("Pair with a server to get started.")
            )
        } else if selectedServerIsSyncing, let selectedServer {
            ContentUnavailableView(
                "Loading Sessions",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text("Refreshing \(selectedServer.name)…")
            )
        } else if selectedServerRefreshFailed, let selectedServer {
            ContentUnavailableView {
                Label("Server Data Unavailable", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text("\(selectedServer.name) couldn't refresh its workspace or session data.")
            } actions: {
                Button("Retry") {
                    Task { await refreshVisibleServer() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let selectedWorkspace {
            ContentUnavailableView(
                "No Sessions",
                systemImage: "terminal",
                description: Text("Start a new session in \(selectedWorkspace.workspace.name).")
            )
        } else {
            ContentUnavailableView(
                "No Active Sessions",
                systemImage: "text.bubble",
                description: Text("No active sessions on \(selectedServer?.name ?? "this server"). Start a quick session or choose a workspace from the sidebar.")
            )
        }
    }

    private func sessionSection(_ title: String, items: [SessionInboxItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                sessionRow(item)
            }
        }
    }

    private func stoppedSessionSection(_ group: SessionInboxStoppedGroup) -> some View {
        Section {
            if isStoppedGroupExpanded(group) {
                ForEach(group.items) { item in
                    sessionRow(item)
                }
            }
        } header: {
            Button {
                toggleStoppedGroupExpansion(group)
            } label: {
                HStack(spacing: 8) {
                    Text("Stopped · \(stoppedGroupTitle(group))")
                    Spacer()
                    Image(systemName: isStoppedGroupExpanded(group) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeComment)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.sessionList.\(group.id)")
            .accessibilityValue(isStoppedGroupExpanded(group) ? "Expanded" : "Collapsed")
        }
    }

    private func sessionRow(_ item: SessionInboxItem) -> some View {
        SessionRow(presentation: rowPresentation(for: item))
            .contentShape(Rectangle())
            // A plain Button can still commit after a horizontal drag loses to
            // the List's swipe recognizer. Use an actual tap recognizer so row
            // navigation fails as soon as either swipe direction becomes a drag.
            .onTapGesture {
                openSession(item)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                openSession(item)
            }
            .accessibilityIdentifier("session.nav.\(item.session.id)")
            .accessibilityValue(sessionRowAccessibilityValue(for: item))
            .listRowBackground(theme.bg.primary)
            .swipeActions(edge: .trailing) {
                sessionSwipeActions(for: item)
            }
    }

    private func recentStoppedGroups(_ items: [SessionInboxItem]) -> [SessionInboxStoppedGroup] {
        SessionInboxStoppedDayPolicy.groups(
            items,
            now: Date(),
            calendar: Calendar.current,
            activityDate: { $0.session.lastActivity }
        )
    }

    private func stoppedGroupTitle(_ group: SessionInboxStoppedGroup) -> String {
        SessionInboxStoppedDayPolicy.title(
            for: group.day,
            now: Date(),
            calendar: Calendar.current
        )
    }

    private func isStoppedGroupExpanded(_ group: SessionInboxStoppedGroup) -> Bool {
        if expandedStoppedGroupIDs.contains(group.id) {
            return true
        }
        if collapsedStoppedGroupIDs.contains(group.id) {
            return false
        }
        return SessionInboxStoppedDayPolicy.isExpandedByDefault(
            day: group.day,
            now: Date(),
            calendar: Calendar.current
        )
    }

    private func toggleStoppedGroupExpansion(_ group: SessionInboxStoppedGroup) {
        if isStoppedGroupExpanded(group) {
            expandedStoppedGroupIDs.remove(group.id)
            collapsedStoppedGroupIDs.insert(group.id)
        } else {
            collapsedStoppedGroupIDs.remove(group.id)
            expandedStoppedGroupIDs.insert(group.id)
        }
    }

    @ViewBuilder
    private func sessionSwipeActions(for item: SessionInboxItem) -> some View {
        if item.session.status == .stopped {
            Button {
                Task { await resumeSession(item) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .tint(.themeGreen)
            .accessibilityIdentifier("session.resume.\(item.session.id)")

            if let routeScope = routeScope(for: item.session) {
                Button(role: SessionDeleteConfirmationPolicy.swipeButtonRole) {
                    pendingDelete = SessionInboxPendingDelete(
                        serverId: item.serverId,
                        routeScope: routeScope,
                        session: item.session
                    )
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.themeRed)
                .accessibilityIdentifier("session.delete.\(item.session.id)")
            }
        } else {
            Button {
                Task { await stopSession(item) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .tint(.themeOrange)
            .accessibilityIdentifier("session.stop.\(item.session.id)")
        }
    }

    private func sessionItems() -> [SessionInboxItem] {
        guard let activeServerId,
              let connection = activeConnection else { return [] }

        let workspaceFilterId = selectedWorkspace?.workspace.id
        return connection.sessionStore.listProjectionSessions.compactMap { session in
            if let workspaceFilterId, session.workspaceId != workspaceFilterId {
                return nil
            }

            let workspace = session.workspaceId.flatMap { workspaceId in
                connection.workspaceStore.workspaces.first { $0.id == workspaceId }
            }
            return SessionInboxItem(
                serverId: activeServerId,
                connection: connection,
                session: session,
                workspace: workspace
            )
        }
    }

    private func inboxItem(for session: Session, existing: SessionInboxItem?) -> SessionInboxItem? {
        if let existing {
            return existing
        }
        guard let activeServerId, let connection = activeConnection else { return nil }
        let workspace = session.workspaceId.flatMap { workspaceId in
            connection.workspaceStore.workspaces.first { $0.id == workspaceId }
        }
        return SessionInboxItem(
            serverId: activeServerId,
            connection: connection,
            session: session,
            workspace: workspace
        )
    }

    private func attentionCounts(for item: SessionInboxItem) -> SessionListAttentionCounts {
        SessionRowPresentationBuilder.attentionCounts(
            sessionId: item.session.id,
            pendingAskCountForSession: { pendingAskCount(for: $0, connection: item.connection) }
        )
    }

    private func pendingAskCount(for sessionId: String, connection: ServerConnection) -> Int {
        SessionListAttentionMerger.askCount(
            listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
            hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
            hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
        )
    }

    private func rowPresentation(for item: SessionInboxItem) -> SessionRowPresentation {
        let attention = attentionCounts(for: item)
        return SessionRowPresentationBuilder.make(
            session: item.session,
            pendingAskCount: attention.askCount,
            pendingAsk: item.connection.askRequestStore.pending(for: item.session.id),
            workspaceContext: workspaceContext(for: item),
            unreadCompletionAt: item.connection.sessionStore.unreadCompletionDate(for: item.session.id),
            searchSnippet: searchStore.snippetsBySessionId[item.session.id]
        )
    }

    private func workspaceContext(for item: SessionInboxItem) -> String? {
        guard selectedWorkspace == nil else { return nil }
        return SessionInboxSessionRouting.allSessionsContext(
            for: item.session,
            workspaceName: item.workspace?.name
        )
    }

    private func sessionRowAccessibilityValue(for item: SessionInboxItem) -> String {
        pendingAskCount(for: item.session.id, connection: item.connection) > 0 ? "Question pending" : ""
    }

    private func openSession(_ item: SessionInboxItem) {
        var normalized = item.session
        if normalized.control == nil,
           normalized.workspaceId == nil || normalized.workspaceId?.isEmpty == true {
            normalized.workspaceId = item.workspace?.id ?? selectedWorkspace?.workspace.id
        }
        if normalized.workspaceName == nil || normalized.workspaceName?.isEmpty == true {
            normalized.workspaceName = item.workspace?.name ?? selectedWorkspace?.workspace.name
        }
        guard let routeScope = SessionInboxSessionRouting.routeScope(for: normalized) else {
            error = "Session route is unavailable"
            return
        }
        item.connection.sessionStore.cacheSessionForNavigation(normalized)

        let workspaceTarget = item.workspace.map { WorkspaceNavTarget(serverId: item.serverId, workspace: $0) }
            ?? selectedWorkspace
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: item.serverId,
                sessionId: item.session.id,
                routeScope: routeScope
            ),
            workspace: workspaceTarget
        )
    }

    private func stopSession(_ item: SessionInboxItem) async {
        guard let api = item.connection.apiClient,
              let routeScope = routeScope(for: item.session) else { return }
        do {
            let updated = try await api.stopSession(scope: routeScope, sessionId: item.session.id)
            item.connection.sessionStore.upsert(updated)
        } catch {
            self.error = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func resumeSession(_ item: SessionInboxItem) async {
        guard let api = item.connection.apiClient,
              let routeScope = routeScope(for: item.session) else { return }
        do {
            let updated = try await api.resumeSession(scope: routeScope, sessionId: item.session.id)
            item.connection.sessionStore.upsert(updated)
        } catch {
            self.error = "Resume failed: \(error.localizedDescription)"
        }
    }

    private func deleteSession(_ pending: SessionInboxPendingDelete) async {
        guard let connection = coordinator.connection(for: pending.serverId),
              let api = connection.apiClient else { return }
        connection.sessionStore.remove(id: pending.session.id)
        await TimelineCache.shared.removeTrace(pending.session.id, serverId: pending.serverId)
        do {
            try await api.deleteSession(scope: pending.routeScope, sessionId: pending.session.id)
            clearComposerDraft(for: pending)
        } catch let apiError as APIError {
            if case .server(let status, _) = apiError, status == 404 {
                clearComposerDraft(for: pending)
            } else {
                self.error = "Delete failed: \(apiError.localizedDescription)"
            }
        } catch {
            self.error = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func routeScope(for session: Session) -> SessionRouteScope? {
        SessionInboxSessionRouting.routeScope(for: session)
    }

    private func clearComposerDraft(for pending: SessionInboxPendingDelete) {
        composerDraftStore?.clearDraft(
            serverID: pending.serverId,
            workspaceID: pending.routeScope.composerDraftScopeID,
            sessionID: pending.session.id
        )
    }

    private var newSessionButton: some View {
        Button {
            if let selectedWorkspace {
                Task { await createSession(in: selectedWorkspace) }
            } else {
                navigation.showQuickSession = true
            }
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .foregroundStyle(.themeFg)
        .accessibilityLabel(selectedWorkspace == nil ? "Start Quick Session" : "New Session")
        .accessibilityIdentifier(selectedWorkspace == nil ? "workspace.quickSession.start" : "workspace.newSession")
        .disabled(isCreating)
        .opacity(isCreating ? 0.55 : 1)
    }

    private func applyE2ELaunchHintsIfNeeded() async {
        autoOpenE2EWorkspaceIfRequested()
        autoOpenE2ESessionIfRequested()
        await autoCreateE2ESessionIfRequested()
    }

    private func autoOpenE2EWorkspaceIfRequested() {
        guard !hasAutoOpenedE2EWorkspace,
              navigation.workspacePath.count == 0,
              let workspaceName = ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"],
              !workspaceName.isEmpty,
              let activeServerId,
              let connection = activeConnection,
              let workspace = connection.workspaceStore.workspaces.first(where: { $0.name == workspaceName })
        else { return }

        hasAutoOpenedE2EWorkspace = true
        navigation.openWorkspace(WorkspaceNavTarget(serverId: activeServerId, workspace: workspace))
    }

    private func autoOpenE2ESessionIfRequested() {
        guard !hasAutoOpenedE2ESession,
              let sessionId = ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"],
              !sessionId.isEmpty,
              selectedWorkspace?.workspace.name == ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"],
              let item = sessionItems().first(where: { $0.session.id == sessionId })
        else { return }

        hasAutoOpenedE2ESession = true
        openSession(item)
    }

    private func autoCreateE2ESessionIfRequested() async {
        guard !hasAutoCreatedE2ESession,
              (ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"] ?? "").isEmpty,
              ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_CREATE_SESSION"] == "1",
              selectedWorkspace?.workspace.name == ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"],
              let selectedWorkspace
        else { return }

        hasAutoCreatedE2ESession = true
        await createSession(in: selectedWorkspace)
    }

    private func createSession(in workspaceTarget: WorkspaceNavTarget) async {
        guard let connection = coordinator.connection(for: workspaceTarget.serverId),
              let api = connection.apiClient else {
            error = "Server is offline — reconnecting in background"
            return
        }

        isCreating = true
        error = nil
        do {
            let response = try await api.createWorkspaceSession(workspaceId: workspaceTarget.workspace.id)
            connection.sessionStore.upsert(response.session)
            isCreating = false
            navigation.openWorkspaceSession(
                WorkspaceSessionNavTarget(
                    serverId: workspaceTarget.serverId,
                    sessionId: response.session.id,
                    workspaceId: workspaceTarget.workspace.id
                ),
                workspace: workspaceTarget
            )
        } catch {
            isCreating = false
            self.error = error.localizedDescription
        }
    }

    private func workspaceFilesButton(_ workspaceTarget: WorkspaceNavTarget) -> some View {
        let target = FileBrowserNavTarget(
            serverId: workspaceTarget.serverId,
            workspaceId: workspaceTarget.workspace.id,
            path: ""
        )

        return Button {
            navigation.openWorkspaceFileBrowser(target, workspace: workspaceTarget)
        } label: {
            Image(systemName: "folder")
        }
        .foregroundStyle(.themeFg)
        .accessibilityIdentifier("workspace.files.open")
        .accessibilityLabel("Open workspace files")
    }

    private func workspaceConfigurationButton(_ workspaceTarget: WorkspaceNavTarget) -> some View {
        Button {
            navigation.openWorkspaceConfiguration(workspaceTarget)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .symbolRenderingMode(.monochrome)
        }
        .foregroundStyle(.themeFg)
        .accessibilityLabel("Edit workspace")
        .accessibilityIdentifier("workspace.edit.open")
    }
}

private struct WorkspaceConfigurationScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    let target: WorkspaceNavTarget

    @State private var scopedConnection: ServerConnection?

    private var resolvedConnection: ServerConnection? {
        scopedConnection
    }

    var body: some View {
        Group {
            if let connection = resolvedConnection {
                WorkspaceEditView(workspace: target.workspace) {
                    dismissConfiguration()
                }
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

    private func dismissConfiguration() {
        guard navigation.workspacePath.count > 0 else { return }
        navigation.workspacePath.removeLast()
    }
}

private struct WorkspaceSidebarDragState {
    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis?
    var horizontalTranslation: CGFloat = 0
}

/// Compact-drawer scroll ownership for the inbox `List`.
///
/// The leading-edge reveal is a `simultaneousGesture`, so the inbox collection
/// view stays tracking unless we disable it after horizontal intent. UIKit then
/// draws the trailing indicator on the peeking sliver. Hide that indicator for
/// the whole `progress > 0` window, including the settled peek.
enum WorkspaceInboxSidebarScrollPolicy {
    static func shouldDisableInboxScrolling(
        isHorizontalReveal: Bool,
        sidebarProgress: CGFloat
    ) -> Bool {
        isHorizontalReveal || sidebarProgress > 0
    }

    static func shouldHideInboxScrollIndicators(sidebarProgress: CGFloat) -> Bool {
        sidebarProgress > 0
    }
}

/// Sessions-first home surface for compact widths.
///
/// Layout: the workspace sidebar sits *beneath* the session layer. The session
/// layer — a `NavigationStack` wrapping `SessionInboxView` — slides right to
/// reveal the sidebar, tracks the drag 1:1, and settles with a spring. Because
/// the nav bar, search, and bottom toolbar all live inside that sliding
/// `NavigationStack`, they travel as one surface with the list (no detached
/// "card" sliding under static bars). The sidebar layer itself owns no bars.
///
/// Edge reveal: instead of a full-height `Color.clear` strip (which covers the
/// leading toolbar toggle and steals its taps), the reveal drag is a
/// `simultaneousGesture` on the foreground layer that only engages for drags
/// starting within ~32pt of the leading edge. It is disabled entirely once a
/// destination is pushed so it never fights the interactive back-swipe.
struct WorkspaceSessionInboxStackRootView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @State private var sidebarRestingProgress: CGFloat = 0
    @State private var isSidebarPresented = false
    @GestureState private var sidebarDrag = WorkspaceSidebarDragState()

    private static let edgePanWidth: CGFloat = 32
    private static let foregroundCornerRadius: CGFloat = 40
    private static let foregroundShadowOpacity = 0.14
    private static let foregroundShadowRadius: CGFloat = 22
    private static let foregroundShadowOffsetX: CGFloat = -5

    var body: some View {
        @Bindable var nav = navigation

        GeometryReader { proxy in
            let sidebarWidth = min(proxy.size.width * 0.80, 320)
            let dragProgress = sidebarDrag.horizontalTranslation / sidebarWidth
            let sidebarProgress = min(1, max(0, sidebarRestingProgress + dragProgress))
            let sidebarOffset = sidebarWidth * sidebarProgress
            let interceptsForegroundTouches = isSidebarPresented || sidebarRestingProgress > 0
            // The edge-pan fights the interactive back-swipe once a destination
            // is pushed, so only arm it at the stack root.
            let edgePanEnabled = nav.workspacePath.isEmpty && !isSidebarPresented
            let disableInboxScrolling = WorkspaceInboxSidebarScrollPolicy.shouldDisableInboxScrolling(
                isHorizontalReveal: sidebarDrag.axis == .horizontal,
                sidebarProgress: sidebarProgress
            )
            let hideInboxIndicators = WorkspaceInboxSidebarScrollPolicy.shouldHideInboxScrollIndicators(
                sidebarProgress: sidebarProgress
            )

            ZStack(alignment: .topLeading) {
                // Base backdrop: the corner cutouts and safe-area strips revealed
                // by the foreground mask must show theme color, never the bare
                // white window background.
                theme.bg.primary
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                WorkspaceSidebarView(
                    onSelect: { settleSidebar(open: false) }
                )
                .frame(width: sidebarWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(isSidebarPresented)
                .accessibilityHidden(!isSidebarPresented)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { settleSidebar(open: false) }
                .accessibilityAction(named: "Close workspaces") { settleSidebar(open: false) }
                .zIndex(0)

                NavigationStack(path: $nav.workspacePath) {
                    SessionInboxView(
                        onOpenSidebar: { settleSidebar(open: true) }
                    )
                    // Keep these on the inbox root only. Applying them to the
                    // NavigationStack would leak into pushed chat.
                    .scrollDisabled(disableInboxScrolling)
                    .scrollIndicators(hideInboxIndicators ? .hidden : .automatic, axes: .vertical)
                    .navigationDestination(for: WorkspaceNavTarget.self) { target in
                        WorkspaceScopedDestinationView(target: target)
                    }
                }
                .background(theme.bg.primary)
                // Mask in screen space, not the safe-area frame: `.clipShape`
                // sizes to the layout bounds, which puts the rounded corners
                // under the status bar / home indicator and amputates the nav
                // bar's safe-area bleed. `ignoresSafeArea` extends the mask to
                // the device corners so the rounding is concentric with the
                // bezel, like the system drawer look this mimics.
                .mask {
                    RoundedRectangle(
                        cornerRadius: Self.foregroundCornerRadius * sidebarProgress,
                        style: .continuous
                    )
                    .ignoresSafeArea()
                }
                .shadow(
                    color: .black.opacity(Self.foregroundShadowOpacity * Double(sidebarProgress)),
                    radius: Self.foregroundShadowRadius * sidebarProgress,
                    x: Self.foregroundShadowOffsetX * sidebarProgress
                )
                .offset(x: sidebarOffset)
                .accessibilityHidden(isSidebarPresented)
                .simultaneousGesture(
                    edgePanEnabled ? sidebarRevealGesture(sidebarWidth: sidebarWidth) : nil
                )
                .zIndex(1)

                // Scrim over the revealed foreground: only present while the
                // sidebar is intercepting (open or mid-drag). When closed it is
                // absent so it never steals taps from the session surface.
                if interceptsForegroundTouches {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .offset(x: sidebarOffset)
                        .gesture(sidebarDragGesture(sidebarWidth: sidebarWidth, minimumDistance: 0, tapCloses: true))
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("workspace.sidebar.scrim")
                        .zIndex(2)
                }
            }
        }
    }

    /// Edge-originated reveal drag attached as a `simultaneousGesture` on the
    /// foreground. No covering view, so the leading toolbar toggle and list
    /// rows keep working. Only drags beginning within `edgePanWidth` of the
    /// leading edge actually move the sidebar.
    private func sidebarRevealGesture(sidebarWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .updating($sidebarDrag) { value, state, transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true

                if state.axis == nil {
                    guard value.startLocation.x <= Self.edgePanWidth else { return }
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard max(horizontal, vertical) >= 2 else { return }
                    state.axis = horizontal >= vertical ? .horizontal : .vertical
                }

                guard state.axis == .horizontal else { return }
                state.horizontalTranslation = value.translation.width
            }
            .onEnded { value in
                guard value.startLocation.x <= Self.edgePanWidth else { return }
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                guard max(horizontal, vertical) >= 2 else { return }
                guard horizontal >= vertical else { return }

                let projectedProgress = sidebarRestingProgress
                    + value.predictedEndTranslation.width / sidebarWidth
                settleSidebar(open: projectedProgress >= 0.5)
            }
    }

    private func sidebarDragGesture(
        sidebarWidth: CGFloat,
        minimumDistance: CGFloat,
        tapCloses: Bool = false
    ) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .local)
            .updating($sidebarDrag) { value, state, transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true

                if state.axis == nil {
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard max(horizontal, vertical) >= 2 else { return }
                    state.axis = horizontal >= vertical ? .horizontal : .vertical
                }

                guard state.axis == .horizontal else { return }
                state.horizontalTranslation = value.translation.width
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                guard max(horizontal, vertical) >= 2 else {
                    if tapCloses {
                        settleSidebar(open: false)
                    }
                    return
                }
                guard horizontal >= vertical else { return }

                let projectedProgress = sidebarRestingProgress
                    + value.predictedEndTranslation.width / sidebarWidth
                settleSidebar(open: projectedProgress >= 0.5)
            }
    }

    private func settleSidebar(open: Bool) {
        // One light open tap when the drawer lands open — edge swipe and the
        // toolbar toggle both settle here. A couple notches above toolbarExpansion
        // so the drawer open is easier to feel without a heavier style.
        if open && !isSidebarPresented {
            AppHaptics.impact(style: .light, intensity: 0.65)
        }
        isSidebarPresented = open
        withAnimation(
            ThemeMotion.animation(
                .spring(duration: 0.28, bounce: 0.06),
                reduceMotion: reduceMotion
            )
        ) {
            sidebarRestingProgress = open ? 1 : 0
        }
    }
}

struct WorkspaceSidebarView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.theme) private var theme

    var onSelect: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var createSheetContext: WorkspaceCreateSheetContext?
    @State private var pendingCreatedWorkspaceTarget: WorkspaceNavTarget?
    @AppStorage(AppIdentifiers.workspaceSidebarExpandedKey)
    private var workspacesExpanded = WorkspaceSidebarDisclosurePolicy.defaultExpanded

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
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 2) {
                    ForEach(
                        WorkspaceSidebarPrimaryUtilities.items.filter { $0.target.isReleaseEnabled },
                        id: \.target
                    ) { item in
                        sidebarUtilityRow(item)
                    }

                    Button {
                        workspacesExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Workspaces")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 8)
                            Image(systemName: workspacesExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.themeComment)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .accessibilityLabel("Workspaces")
                    .accessibilityValue(workspacesExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint(workspacesExpanded ? "Hides workspace rows" : "Shows workspace rows")
                    .accessibilityIdentifier("workspace.sidebar.disclosure")

                    if workspacesExpanded, let selectedServer {
                        let serverId = selectedServer.id
                        let connection = coordinator.connection(for: serverId)
                        let workspaceStore = connection?.workspaceStore
                        let summaries = workspaceStore?.workspaceSummaries(forServer: serverId) ?? [:]
                        let workspaces = sortedWorkspacesForList(
                            workspacesForServer(serverId),
                            summaries: summaries
                        )
                        let availability = WorkspaceCatalogAvailability(
                            hasWorkspaces: !workspaces.isEmpty,
                            isLoaded: workspaceStore?.isLoaded ?? false,
                            isSyncing: workspaceStore?.isSyncing ?? false,
                            lastSyncFailed: workspaceStore?.lastSyncFailed ?? false
                        )

                        switch availability {
                        case .loading:
                            Label("Loading workspaces…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline)
                                .foregroundStyle(.themeComment)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 8)

                        case .unavailable:
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Workspaces unavailable", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.themeOrange)
                                Button("Retry") {
                                    Task { await coordinator.refreshServer(serverId, force: true) }
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)

                        case .empty:
                            Text("No workspaces")
                                .font(.subheadline)
                                .foregroundStyle(.themeComment)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 8)

                        case .available:
                            ForEach(workspaces) { workspace in
                                let target = WorkspaceNavTarget(serverId: serverId, workspace: workspace)
                                let status = workspaceSessionStatus(
                                    workspaceId: workspace.id,
                                    connection: connection
                                )
                                let gitSummary = workspaceGitSummary(
                                    summaries[workspace.id]?.gitSummary
                                )
                                Button {
                                    navigation.openWorkspace(target)
                                    onSelect?()
                                } label: {
                                    WorkspaceSidebarRow(
                                        workspace: workspace,
                                        status: status,
                                        gitSummary: gitSummary,
                                        isSelected: navigation.selectedWorkspaceFilter == target
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(WorkspaceHomeView.workspaceOpenAccessibilityIdentifier(workspaceName: workspace.name))
                                .accessibilityLabel("Open \(workspace.name)")
                                .accessibilityValue(workspaceAccessibilityValue(status: status, gitSummary: gitSummary))
                                .accessibilityAddTraits(
                                    navigation.selectedWorkspaceFilter == target ? .isSelected : []
                                )
                            }
                        }
                    } else if workspacesExpanded {
                        Text("No server selected")
                            .font(.subheadline)
                            .foregroundStyle(.themeComment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("workspace.sidebar.scroll")

            if let selectedServer {
                Divider()

                newWorkspaceButton(selectedServer)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            sidebarUtilityRow(.appSettings, title: "App Settings", systemImage: "gear")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg.primary.ignoresSafeArea())
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
    }

    private var sidebarHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Oppi")
                .font(.title2.weight(.bold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeFg)
                .accessibilityLabel("Close workspaces")
                .accessibilityIdentifier("workspace.sidebar.close")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func sidebarUtilityRow(_ item: WorkspaceSidebarPrimaryUtilityItem) -> some View {
        sidebarUtilityRow(
            item.target,
            title: item.title,
            systemImage: item.systemImage,
            accessibilityLabel: item.accessibilityLabel,
            accessibilityIdentifier: item.accessibilityIdentifier,
            minimumHitHeight: item.minimumHitHeight
        )
    }

    private func sidebarUtilityRow(
        _ target: WorkspaceUtilityNavTarget,
        title: String,
        systemImage: String,
        accessibilityLabel: String? = nil,
        accessibilityIdentifier: String? = nil,
        minimumHitHeight: CGFloat = 44
    ) -> some View {
        let isSelected = navigation.workspaceNavigationPresentation == .split
            && navigation.splitDetailTarget == .utility(target)

        return Button {
            navigation.openWorkspaceUtility(target)
            onSelect?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .themeBlue : .themeFg)
                    .frame(width: 32, height: 32)

                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? .themeBlue : .themeFg)

                Spacer(minLength: 8)
            }
            .frame(minHeight: minimumHitHeight)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.text.primary.opacity(0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityHint("Opens \(title.lowercased()) management")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(
            accessibilityIdentifier
                ?? (target == .appSettings ? "workspace.settings.open" : "workspace.\(title.lowercased()).open")
        )
    }

    private func newWorkspaceButton(_ selectedServer: PairedServer) -> some View {
        Button {
            presentCreateWorkspace(on: selectedServer)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.themeFg)

                Text("New Workspace")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Spacer(minLength: 8)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.create.sidebar.open")
        .accessibilityLabel("Create New Workspace")
    }

    private func workspacesForServer(_ serverId: String) -> [Workspace] {
        coordinator.connection(for: serverId)?.workspaceStore.workspaces ?? []
    }

    private func workspaceSessionStatus(
        workspaceId: String,
        connection: ServerConnection?
    ) -> WorkspaceSidebarSessionStatus {
        guard let connection else {
            return WorkspaceSidebarSessionStatus(sessions: [])
        }

        return WorkspaceSidebarSessionStatus(
            sessions: connection.sessionStore.listProjectionSessions(workspaceId: workspaceId),
            pendingAskCountForSession: { sessionId in
                SessionListAttentionMerger.askCount(
                    listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
                    hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
                    hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
                )
            }
        )
    }

    private func workspaceGitSummary(_ summary: WorkspaceGitSummary?) -> WorkspaceSidebarGitSummary? {
        guard let summary, summary.isGitRepo else { return nil }
        let sidebarSummary = WorkspaceSidebarGitSummary(
            changedCount: summary.changedCount,
            aheadCount: summary.ahead ?? 0,
            behindCount: summary.behind ?? 0
        )
        return sidebarSummary.isVisible ? sidebarSummary : nil
    }

    private func workspaceAccessibilityValue(
        status: WorkspaceSidebarSessionStatus,
        gitSummary: WorkspaceSidebarGitSummary?
    ) -> String {
        [status.accessibilityValue, gitSummary?.accessibilityValue]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
    }

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
        onSelect?()
    }
}

/// Compact workspace aggregate using the same attention and status semantics as session rows.
struct WorkspaceSidebarSessionStatus: Equatable {
    let questionCount: Int
    let errorCount: Int
    let workingCount: Int
    let doneCount: Int

    init(
        questionCount: Int = 0,
        errorCount: Int = 0,
        workingCount: Int = 0,
        doneCount: Int = 0
    ) {
        self.questionCount = questionCount
        self.errorCount = errorCount
        self.workingCount = workingCount
        self.doneCount = doneCount
    }

    init(
        sessions: [Session],
        pendingAskCountForSession: (String) -> Int = { _ in 0 }
    ) {
        var questionCount = 0
        var errorCount = 0
        var workingCount = 0
        var doneCount = 0

        for session in sessions {
            switch SessionPillVariant.from(
                session: session,
                pendingAskCount: pendingAskCountForSession(session.id)
            ) {
            case .question:
                questionCount += 1
            case .error:
                errorCount += 1
            case .working:
                workingCount += 1
            case .done:
                doneCount += 1
            case .idle, .stopped:
                break
            }
        }

        self.questionCount = questionCount
        self.errorCount = errorCount
        self.workingCount = workingCount
        self.doneCount = doneCount
    }

    var attentionCount: Int {
        questionCount + errorCount
    }

    var isVisible: Bool {
        attentionCount > 0 || workingCount > 0 || doneCount > 0
    }

    /// Attention replaces Done visually to keep the trailing cluster compact.
    var showsDone: Bool {
        attentionCount == 0 && doneCount > 0
    }

    var accessibilityValue: String {
        [
            sessionAttentionLabel(errorCount, state: "has an error", pluralState: "have errors"),
            sessionAttentionLabel(questionCount, state: "needs attention", pluralState: "need attention"),
            sessionCountLabel(workingCount, state: "working"),
            sessionCountLabel(doneCount, state: "done"),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func sessionAttentionLabel(
        _ count: Int,
        state: String,
        pluralState: String
    ) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 session \(state)" : "\(count) sessions \(pluralState)"
    }

    private func sessionCountLabel(_ count: Int, state: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(state) \(count == 1 ? "session" : "sessions")"
    }
}

/// Compact git state for a workspace catalog row.
struct WorkspaceSidebarGitSummary: Equatable {
    let changedCount: Int
    let aheadCount: Int
    let behindCount: Int

    var isVisible: Bool {
        changedCount > 0 || aheadCount > 0 || behindCount > 0
    }

    var accessibilityValue: String {
        [
            countLabel(changedCount, singular: "changed file", plural: "changed files"),
            countLabel(aheadCount, singular: "commit not pushed", plural: "commits not pushed"),
            countLabel(behindCount, singular: "commit behind", plural: "commits behind"),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func countLabel(_ count: Int, singular: String, plural: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }
}

struct WorkspaceSidebarRow: View {
    @Environment(\.theme) private var theme

    let workspace: Workspace
    let status: WorkspaceSidebarSessionStatus
    let gitSummary: WorkspaceSidebarGitSummary?
    let isSelected: Bool

    init(
        workspace: Workspace,
        status: WorkspaceSidebarSessionStatus,
        gitSummary: WorkspaceSidebarGitSummary? = nil,
        isSelected: Bool
    ) {
        self.workspace = workspace
        self.status = status
        self.gitSummary = gitSummary
        self.isSelected = isSelected
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WorkspaceRuntimeIcon(workspace: workspace, size: 26, frameSize: 32)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspace.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if status.isVisible {
                        WorkspaceSidebarSessionStatusIndicator(status: status)
                    }
                }

                if let description = workspace.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let gitSummary, gitSummary.isVisible {
                    WorkspaceSidebarGitStatusLine(summary: gitSummary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.text.primary.opacity(0.08))
            }
        }
        .contentShape(Rectangle())
    }
}

struct WorkspaceSidebarGitStatusLine: View {
    let summary: WorkspaceSidebarGitSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if summary.changedCount > 0 {
                metric(
                    text: "\(SessionFormatting.compactCount(summary.changedCount)) changes",
                    symbol: "circle.fill",
                    tint: .themeOrange,
                    symbolScale: .small
                )
            }

            if summary.aheadCount > 0 {
                metric(
                    text: "\(SessionFormatting.compactCount(summary.aheadCount))",
                    symbol: "arrow.up",
                    tint: .themeBlue
                )
            }

            if summary.behindCount > 0 {
                metric(
                    text: "\(SessionFormatting.compactCount(summary.behindCount))",
                    symbol: "arrow.down",
                    tint: .themeOrange
                )
            }
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityValue)
    }

    private func metric(
        text: String,
        symbol: String,
        tint: Color,
        symbolScale: Image.Scale = .medium
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .imageScale(symbolScale)
            Text(text)
                .monospacedDigit()
        }
        .foregroundStyle(tint)
    }
}

struct WorkspaceSidebarSessionStatusIndicator: View {
    let status: WorkspaceSidebarSessionStatus

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            if status.attentionCount > 0 {
                metric(
                    symbol: "exclamationmark.triangle.fill",
                    count: status.attentionCount,
                    tint: status.errorCount > 0 ? .themeRed : .themeOrange
                )
            }

            if status.workingCount > 0 {
                metric(symbol: "bolt.fill", count: status.workingCount, tint: .themeBlue)
            }

            if status.showsDone {
                metric(symbol: "checkmark", count: status.doneCount, tint: .themeGreen)
            }
        }
        .font(.caption2.weight(.semibold))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }

    private func metric(symbol: String, count: Int, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 2) {
            Image(systemName: symbol)
                .imageScale(.small)

            Text(SessionFormatting.compactCount(count))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .lineLimit(1)
    }
}
