import SwiftUI

private struct SessionInboxItem: Identifiable {
    let serverId: String
    let connection: ServerConnection
    let session: Session
    let workspace: Workspace?

    var id: String { "\(serverId):\(session.id)" }
}

private typealias SessionInboxStoppedGroup = SessionInboxStoppedDayGroup<SessionListEntry>

private struct SessionInboxViewData {
    let yourTurn: [SessionListEntry]
    let working: [SessionListEntry]
    let stoppedGroups: [SessionInboxStoppedGroup]
    let searchMatches: [SessionListEntry]
    /// Inbox items by session id, for row context and routing.
    let itemsById: [String: SessionInboxItem]
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

    init(
        hasWorkspaces: Bool,
        isLoaded: Bool,
        isSyncing: Bool,
        lastSyncFailed: Bool,
        hasAPIClient: Bool = true,
        isPreparing: Bool = false
    ) {
        if hasWorkspaces {
            self = .available
        } else if isSyncing || isPreparing {
            self = .loading
        } else if lastSyncFailed || !hasAPIClient {
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

enum SessionInboxTransportAvailability {
    static func isUnavailable(hasAPIClient: Bool, isPreparing: Bool) -> Bool {
        !hasAPIClient && !isPreparing
    }
}

struct WorkspaceSidebarPrimaryUtilityItem: Equatable {
    let target: WorkspaceUtilityNavTarget
    let title: String
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let minimumHitHeight: CGFloat
    let accessibilityHint: String?
}

enum WorkspaceSidebarPrimaryUtilities {
    static let items: [WorkspaceSidebarPrimaryUtilityItem] = [
        .init(
            target: .agents,
            title: "Agents",
            systemImage: "person.crop.circle",
            accessibilityLabel: "Agents",
            accessibilityIdentifier: "workspace.agents.open",
            minimumHitHeight: 44,
            accessibilityHint: nil
        ),
        .init(
            target: .schedules,
            title: "Schedules",
            systemImage: "clock",
            accessibilityLabel: "Schedules",
            accessibilityIdentifier: "workspace.schedules.open",
            minimumHitHeight: 44,
            accessibilityHint: nil
        ),
        .init(
            target: .skills,
            title: "Skills",
            systemImage: "sparkles.rectangle.stack",
            accessibilityLabel: "Open Skills",
            accessibilityIdentifier: "workspace.skills.open",
            minimumHitHeight: 44,
            accessibilityHint: nil
        ),
        .init(
            target: .extensions,
            title: "Extensions",
            systemImage: "shippingbox",
            accessibilityLabel: "Open Extensions",
            accessibilityIdentifier: "workspace.extensions.open",
            minimumHitHeight: 44,
            accessibilityHint: nil
        ),
        .init(
            target: .mcpServers,
            title: "MCP Servers",
            systemImage: "network",
            accessibilityLabel: "Open MCP Servers",
            accessibilityIdentifier: "workspace.mcpServers.open",
            minimumHitHeight: 44,
            accessibilityHint: nil
        ),
    ]

    static let desktopStill = WorkspaceSidebarPrimaryUtilityItem(
        target: .desktopStill,
        title: "Remote Screen",
        systemImage: "macwindow",
        accessibilityLabel: "Remote Screen",
        accessibilityIdentifier: "workspace.desktopStill.open",
        minimumHitHeight: 44,
        accessibilityHint: "Inspect the current remote screen"
    )

    static let durableSessions = WorkspaceSidebarPrimaryUtilityItem(
        target: .durableSessions,
        title: "Durable",
        systemImage: "infinity",
        accessibilityLabel: "Open Durable Sessions",
        accessibilityIdentifier: "workspace.durableSessions.open",
        minimumHitHeight: 44,
        accessibilityHint: "Lists this server's durable sessions"
    )

    /// `durableSessionsAvailable` is `DurableSessionsPlayground.isAvailable` for the shown server.
    static func items(
        for idiom: UIUserInterfaceIdiom,
        sshTerminalEnabled: Bool = AppPreferences.Experiments.sshTerminalEnabled,
        hasSSHProfile: Bool = SSHTerminalProfileStore().load()?.isConfigured == true,
        durableSessionsAvailable: Bool = false
    ) -> [WorkspaceSidebarPrimaryUtilityItem] {
        var result = items
        if sshTerminalEnabled && hasSSHProfile {
            result.append(.init(
                target: .sshTerminal, title: "Terminal", systemImage: "terminal",
                accessibilityLabel: "Open SSH Terminal", accessibilityIdentifier: "workspace.terminal.open",
                minimumHitHeight: 44, accessibilityHint: "Connect to your SSH host"
            ))
        }
        if durableSessionsAvailable { result.append(durableSessions) }
        if idiom == .phone { result.append(desktopStill) }
        return result
    }
}

/// Inbox-local search and stopped-group expansion belong to the visible host.
/// Compact host jobs stay mounted over inbox, so a host change must reset these
/// without popping to All Sessions.
enum SessionInboxHostChange {
    @MainActor
    static func reset(
        searchText _: String,
        expandedStoppedGroupIDs _: Set<String>,
        collapsedStoppedGroupIDs _: Set<String>,
        searchStore: SessionSearchStore
    ) -> (searchText: String, expandedStoppedGroupIDs: Set<String>, collapsedStoppedGroupIDs: Set<String>) {
        searchStore.clear()
        return ("", [], [])
    }
}

enum SessionInboxSessionRouting {
    static func routeScope(for session: Session) -> SessionRouteScope? {
        if session.control != nil { return .control }
        guard let workspaceId = session.workspaceId, !workspaceId.isEmpty else { return nil }
        return .workspace(workspaceId)
    }

    static func allSessionsContext(for session: Session, workspaceName: String?) -> String? {
        SessionRowPresentationBuilder.allSessionsWorkspaceContext(
            for: session,
            workspaceName: workspaceName
        )
    }
}

/// Which sessions the All Sessions surface lists.
///
/// `.durable` is the Durable Sessions playground: the same list, search, and
/// quick session bar over the active server's durable sessions, including
/// stopped history older than the All Sessions window. It hides the host
/// switcher (the playground is gated per server) and the host-wide setup
/// notices, which All Sessions already shows.
enum SessionInboxScope: Equatable {
    case all
    case durable

    var title: String {
        switch self {
        case .all: "All Sessions"
        case .durable: "Durable"
        }
    }

    /// Stopped day groups: All Sessions keeps its recent window; Durable keeps every day.
    var stoppedDayLimit: Int? {
        switch self {
        case .all: SessionInboxStoppedDayPolicy.visibleDayCount
        case .durable: nil
        }
    }

    func includes(_ session: Session) -> Bool {
        switch self {
        case .all: true
        case .durable: DurableSessionsPlayground.isListed(session)
        }
    }

    /// Context the quick session bar hands Quick Session. Durable pins the
    /// sheet to the server's durable engine and starts nothing without a server.
    enum QuickSessionLaunch: Equatable {
        case standard
        case context(QuickSessionLaunchContext)
        case unavailable
    }

    func quickSessionLaunch(serverId: String?, durableAvailable: Bool) -> QuickSessionLaunch {
        switch self {
        case .all:
            return .standard
        case .durable:
            guard durableAvailable, let serverId else { return .unavailable }
            return .context(QuickSessionLaunchContext(durableOnServer: serverId))
        }
    }
}

/// Sessions-first home surface.
///
/// The workspace sidebar owns project selection. This view keeps the main
/// content focused on session rows and uses small row context instead of a
/// workspace header card. `scope` narrows the same surface to the Durable
/// playground.
struct SessionInboxView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.chatReaderPayloadStore) private var chatReaderPayloadStore
    @Environment(\.composerDraftStore) private var composerDraftStore
    @Environment(\.theme) private var theme
    @AppStorage(AppPreferences.Experiments.durableSessionsKey) private var durableExperimentEnabled = false

    let scope: SessionInboxScope
    let onOpenSidebar: (() -> Void)?

    @State private var searchStore = SessionSearchStore()
    /// Durable scope: full-history durable sessions; the live store only holds the recent window.
    @State private var durableHistory: [Session] = []
    @State private var isLoadingDurableHistory = false
    /// Durable scope keeps its own search; All Sessions' lives in `AppNavigation`.
    @State private var scopedSearch = SessionListSearchNavigationPersistence.State()
    /// Durable scope: compact stack depth where this list sits, so deeper pushes cover it.
    @State private var scopedStackDepth: Int?
    @State private var error: String?
    @State private var failedRetryServerId: String?
    @State private var pendingDelete: SessionInboxPendingDelete?
    @State private var expandedStoppedGroupIDs: Set<String> = []
    @State private var collapsedStoppedGroupIDs: Set<String> = []
    @State private var hasAutoOpenedE2EWorkspace = false
    @State private var hasAutoOpenedE2ESession = false
    @State private var providerSetupState: ProviderSetupState = .unknown
    @FocusState private var isSearchFieldFocused: Bool
    @State private var presentsNowPlayingPlayer = false
    @State private var composeBarColumnWidth: CGFloat = 0

    init(scope: SessionInboxScope = .all, onOpenSidebar: (() -> Void)? = nil) {
        self.scope = scope
        self.onOpenSidebar = onOpenSidebar
    }

    private var activeServerId: String? {
        coordinator.activeServerId
    }

    private var activeConnection: ServerConnection? {
        activeServerId.flatMap { coordinator.connection(for: $0) }
    }

    private var isDurableAvailable: Bool {
        DurableSessionsPlayground.isAvailable(
            experimentEnabled: durableExperimentEnabled,
            serverOffersDurable: activeConnection?.durableSessionsAvailable == true
        )
    }

    private var quickSessionLaunch: SessionInboxScope.QuickSessionLaunch {
        scope.quickSessionLaunch(serverId: activeServerId, durableAvailable: isDurableAvailable)
    }

    /// All Sessions reloads per server; Durable also reloads when it becomes available.
    private var listTaskID: String? {
        scope == .all || isDurableAvailable ? activeServerId : nil
    }

    private var sessionListAudioPlayer: AudioPlayerService? {
        activeConnection?.audioPlayer
    }

    private var sessionListHasActivePlayback: Bool {
        sessionListAudioPlayer?.hasActivePlayback == true
    }

    private var sessionListToolbar: InAppNowPlayingChrome.SessionListToolbar {
        InAppNowPlayingChrome.sessionListToolbar(
            hasActivePlayback: sessionListHasActivePlayback,
            isSearchPresented: searchNavigation.isSearchPresented
        )
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

    private func refreshSearch() {
        searchStore.search(
            query: searchText,
            workspaceId: nil,
            apiClient: activeConnection?.apiClient
        )
    }

    private var searchNavigation: SessionListSearchNavigationPersistence.State {
        get { scope == .all ? navigation.inboxSessionSearch : scopedSearch }
        nonmutating set {
            if scope == .all {
                navigation.inboxSessionSearch = newValue
            } else {
                scopedSearch = newValue
            }
        }
    }

    private var searchText: String {
        searchNavigation.searchText
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { searchNavigation.searchText },
            set: {
                var next = searchNavigation
                next.searchText = $0
                searchNavigation = next
            }
        )
    }

    private var searchPresentedBinding: Binding<Bool> {
        Binding(
            get: { searchNavigation.isSearchPresented },
            set: {
                var next = searchNavigation
                next.isSearchPresented = $0
                searchNavigation = next
            }
        )
    }

    private var hasSearchQuery: Bool {
        SessionListSearchPresentation.hasQuery(searchText)
    }

    private var isSearchListCoveredByDestination: Bool {
        switch scope {
        case .all:
            return SessionListSearchNavigationPersistence.isInboxCovered(
                isSplitPresentation: navigation.workspaceNavigationPresentation == .split,
                stackDepth: navigation.workspacePath.count,
                splitDetailReplacesList: navigation.splitDetailTarget != nil
            )
        case .durable:
            // Durable is the split detail root, or a pushed compact stack entry.
            if navigation.workspaceNavigationPresentation == .split {
                return !navigation.splitDetailPath.isEmpty
            }
            return navigation.workspacePath.count > (scopedStackDepth ?? navigation.workspacePath.count)
        }
    }

    private var searchCoverageSignature: String {
        let signature = "\(navigation.workspacePath.count):\(navigation.workspaceNavigationPresentation):\(navigation.splitDetailTarget != nil)"
        return scope == .all ? signature : "\(signature):\(navigation.splitDetailPath.count)"
    }

    private var viewData: SessionInboxViewData {
        let items = sessionItems()
        var itemsById = Dictionary(uniqueKeysWithValues: items.map { ($0.session.id, $0) })
        if let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: items.map(\.session),
            query: searchText,
            extraCandidates: { session in
                [itemsById[session.id]?.workspace?.name]
            },
            serverResults: scope == .all
                ? searchStore.results
                : searchStore.results.filter { $0.session.map(scope.includes) == true },
            completedServerQuery: searchStore.completedServerQuery,
            activeServerQuery: searchStore.activeServerQuery,
            snippetsBySessionId: searchStore.snippetsBySessionId
        ) {
            let searchItems = matches.compactMap { match in
                inboxItem(for: match.session, existing: itemsById[match.session.id])
            }
            for item in searchItems { itemsById[item.session.id] = item }
            return SessionInboxViewData(
                yourTurn: [],
                working: [],
                stoppedGroups: [],
                searchMatches: SessionListEntries.flat(searchItems.map(\.session)),
                itemsById: itemsById,
                isSearching: searchStore.isSearching,
                isEmpty: searchItems.isEmpty && !searchStore.isSearching
            )
        }

        // All Sessions lists every loaded session, so every thread root is here.
        // Durable builds threads over every loaded session, durable or not.
        let sessions = items.map(\.session)
        let entries = SessionListEntries.entries(
            threadsEnabled: navigation.sessionThreadsEnabled,
            listed: sessions,
            loaded: scope == .all
                ? sessions
                : (activeConnection?.sessionStore.listProjectionSessions ?? []) + durableHistory
        )
        let grouped = SessionInboxGrouping.make(
            items: entries,
            now: Date(),
            calendar: Calendar.current,
            session: \.representative,
            attention: { $0.attention(attentionCounts(for:)) },
            sectionKind: { $0.sectionKind(attention: attentionCounts(for:)) },
            stoppedDayLimit: scope.stoppedDayLimit
        )
        return SessionInboxViewData(
            yourTurn: grouped.yourTurn,
            working: grouped.working,
            stoppedGroups: grouped.stoppedGroups,
            searchMatches: [],
            itemsById: itemsById,
            isSearching: false,
            isEmpty: grouped.isEmpty
        )
    }

    var body: some View {
        let data = viewData

        List {
            if showsMinimumServerVersionNotice, let selectedServer {
                ProviderSetupPromptListSection {
                    ServerVersionPromptCard {
                        navigation.openHostSwitcherDestination(
                            .serverSettings,
                            serverId: selectedServer.id
                        )
                    }
                }
            } else if showsProviderSetupPrompt, let selectedServer {
                ProviderSetupPromptListSection {
                    providerSetupPrompt(for: selectedServer)
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
                    entrySection("Results", entries: data.searchMatches, itemsById: data.itemsById)
                }
            } else {
                if !data.yourTurn.isEmpty {
                    entrySection(SessionInboxSectionTitle.yourTurn, entries: data.yourTurn, itemsById: data.itemsById)
                }
                if !data.working.isEmpty {
                    entrySection(SessionInboxSectionTitle.working, entries: data.working, itemsById: data.itemsById)
                }
                ForEach(data.stoppedGroups) { group in
                    stoppedSection(group, itemsById: data.itemsById)
                }

                if ProviderSetupPromptPolicy.shouldShowInboxEmptyState(
                    isEmpty: data.isEmpty,
                    showsProviderSetup: showsProviderSetupPrompt || showsMinimumServerVersionNotice
                ) {
                    Section {
                        emptyState
                            .listRowBackground(theme.bg.primary)
                    }
                }
            }
        }
        .accessibilityIdentifier(scope == .all ? "workspace.sessionList" : "durableSessions.list")
        .listStyle(.plain)
        .themedListSurface()
        .navigationTitle(scope.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: searchTextBinding,
            isPresented: searchPresentedBinding,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search sessions"
        )
        .searchFocused($isSearchFieldFocused)
        .searchPresentationToolbarBehavior(
            sessionListToolbar.avoidsHidingContentWhileSearching ? .avoidHidingContent : .automatic
        )
        .fullScreenCover(isPresented: $presentsNowPlayingPlayer) {
            if let player = sessionListAudioPlayer {
                InAppNowPlayingPlayerScreen(audioPlayer: player)
            }
        }
        .onChange(of: searchText) { _, newValue in
            applySearchNavigation(.searchTextChanged(newValue))
            refreshSearch()
        }
        .onChange(of: searchNavigation.isSearchPresented) { _, presented in
            applySearchNavigation(.searchPresentationChanged(presented))
            if !presented {
                isSearchFieldFocused = false
            }
        }
        .onChange(of: searchCoverageSignature) { _, _ in
            restoreSearchAfterCoverageChange()
        }
        .onChange(of: activeServerId) { _, _ in
            resetLocalHostState()
        }
        .toolbar { toolbarContent }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { composeBarColumnWidth = $0 }
        .refreshable {
            async let refresh: () = refreshVisibleServer()
            async let providers: () = loadProviderSetupState()
            async let history: () = loadDurableHistory()
            _ = await (refresh, providers, history)
        }
        .onAppear {
            if scope == .durable, scopedStackDepth == nil {
                scopedStackDepth = navigation.workspacePath.count
            }
        }
        .task(id: listTaskID) {
            if hasSearchQuery {
                refreshSearch()
            }
            switch scope {
            case .all:
                providerSetupState = .unknown
                async let refresh: () = refreshVisibleServer()
                async let providers: () = loadProviderSetupState()
                _ = await (refresh, providers)
                applyE2ELaunchHintsIfNeeded()
            case .durable:
                durableHistory = []
                await loadDurableHistory()
            }
        }
        .onChange(of: navigation.workspacePath.count) { oldCount, newCount in
            guard newCount < oldCount else { return }
            Task { await loadProviderSetupState() }
        }
        .onChange(of: navigation.splitDetailPath.count) { oldCount, newCount in
            guard newCount < oldCount else { return }
            Task { await loadProviderSetupState() }
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
        .navigationDestination(for: ChatReaderNavTarget.self) { target in
            if let store = chatReaderPayloadStore {
                ChatReaderDestinationView(target: target, store: store)
            }
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
                case .mcpServers:
                    McpServersView(scopeId: McpScopeSnapshot.globalId)
                case .sshTerminal:
                    SSHTerminalSetupView()
                case .durableSessions:
                    SessionInboxView(scope: .durable)
                case .desktopStill:
                    DesktopCurrentStillViewerView()
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
        .navigationDestination(for: SessionThreadNavTarget.self) { target in
            SessionThreadDetailView(target: target)
        }
    }

    /// Host-wide notices belong to All Sessions; the Durable scope does not repeat them.
    private var showsMinimumServerVersionNotice: Bool {
        scope == .all
            && selectedServer != nil
            && ServerReleaseVersion.isBelowMinimum(activeConnection?.connectedServerVersion)
    }

    private var showsProviderSetupPrompt: Bool {
        scope == .all
            && ProviderSetupPromptPolicy.shouldShow(for: providerSetupState)
            && selectedServer != nil
            && !showsMinimumServerVersionNotice
    }

    private var inboxTitle: some View {
        Text(scope.title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.themeFg)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(scope.title)
            .accessibilityIdentifier(scope == .all ? "workspace.inbox.title" : "durableSessions.title")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            inboxTitle
        }

        ToolbarItem(placement: .topBarLeading) {
            if let onOpenSidebar {
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
            // Switching hosts would leave the per-server Durable scope.
            if scope == .all, let selectedServer {
                serverSwitcher(selectedServer)
            }
        }

        ToolbarItem(placement: .bottomBar) {
            compactQuickSessionBar
        }
        if sessionListToolbar.showsNowPlayingPill {
            ToolbarSpacer(
                sessionListToolbar.parksNowPlayingNextToCompose ? .fixed : .flexible,
                placement: .bottomBar
            )
            ToolbarItem(placement: .bottomBar) {
                if let player = sessionListAudioPlayer {
                    InAppNowPlayingPill(
                        audioPlayer: player,
                        accessibilityPrefix: "sessionList.nowPlaying",
                        density: sessionListToolbar.pillDensity,
                        onOpen: { presentsNowPlayingPlayer = true }
                    )
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
        } else {
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }

        ToolbarItem(placement: .bottomBar) {
            inboxFolderButton
        }
    }

    private func serverSwitcher(_ current: PairedServer) -> some View {
        HostSwitcherMenu(
            current: current,
            destination: .inbox,
            onSwitch: { _ in
                switchVisibleServer()
            }
        )
    }

    private func providerSetupPrompt(for server: PairedServer) -> some View {
        ProviderSetupPromptCard(
            message: "Connect a model provider before starting a session on \(server.name).",
            openAccessibilityIdentifier: "workspace.providerSetup.open"
        ) {
            navigation.openModelProviders(ModelProvidersNavTarget(serverId: server.id))
        }
    }

    private func loadProviderSetupState() async {
        guard scope == .all else { return }
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

    private func resetLocalHostState() {
        applySearchNavigation(.reset)
        navigation.workspaceSessionSearchByID = [:]
        isSearchFieldFocused = false
        let reset = SessionInboxHostChange.reset(
            searchText: searchText,
            expandedStoppedGroupIDs: expandedStoppedGroupIDs,
            collapsedStoppedGroupIDs: collapsedStoppedGroupIDs,
            searchStore: searchStore
        )
        expandedStoppedGroupIDs = reset.expandedStoppedGroupIDs
        collapsedStoppedGroupIDs = reset.collapsedStoppedGroupIDs
    }

    private func applySearchNavigation(_ event: SessionListSearchNavigationPersistence.Event) {
        searchNavigation = SessionListSearchNavigationPersistence.reduce(
            searchNavigation,
            event: event,
            isCoveredByDestination: isSearchListCoveredByDestination
        )
    }

    private func restoreSearchAfterCoverageChange() {
        applySearchNavigation(.coverageChanged(isCovered: isSearchListCoveredByDestination))
        if !isSearchListCoveredByDestination {
            isSearchFieldFocused = false
        }
    }

    private func switchVisibleServer() {
        error = nil
        navigation.showAllWorkspaceSessions()
    }

    private func refreshVisibleServer() async {
        guard let activeServerId else { return }
        await coordinator.refreshServer(activeServerId, force: true)
    }

    /// Durable scope: every durable session on the server (`recentDays=0`),
    /// merged with the live store in `sessionItems()`.
    private func loadDurableHistory() async {
        guard scope == .durable, isDurableAvailable, let api = activeConnection?.apiClient else { return }
        isLoadingDurableHistory = true
        defer { isLoadingDurableHistory = false }
        do {
            durableHistory = try await api.listDurableSessions()
        } catch {
            // Leaving the screen or switching servers cancels the load.
            guard !Task.isCancelled else { return }
            self.error = "Loading durable sessions failed: \(error.localizedDescription)"
        }
    }

    private func retryVisibleServer() async {
        guard let activeServerId else { return }
        failedRetryServerId = nil
        if activeConnection?.apiClient == nil {
            await coordinator.retryServerConnection(activeServerId)
        } else {
            await refreshVisibleServer()
        }
        if self.activeServerId == activeServerId {
            failedRetryServerId = selectedServerRefreshFailed || selectedServerTransportUnavailable
                ? activeServerId : nil
        }
    }

    private var selectedServerRefreshFailed: Bool {
        guard let activeConnection else { return false }
        return activeConnection.workspaceStore.lastSyncFailed
            || activeConnection.sessionStore.lastSyncFailed
    }

    private var selectedServerTransportUnavailable: Bool {
        guard let activeServerId, let activeConnection else { return false }
        return SessionInboxTransportAvailability.isUnavailable(
            hasAPIClient: activeConnection.apiClient != nil,
            isPreparing: coordinator.preparingServerIds.contains(activeServerId)
        )
    }

    private var selectedServerIsSyncing: Bool {
        (activeServerId.map { coordinator.preparingServerIds.contains($0) } ?? false)
            || activeConnection?.workspaceStore.isSyncing == true
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
        } else if scope == .durable, !isDurableAvailable {
            ContentUnavailableView(
                "Durable Sessions Unavailable",
                systemImage: "infinity",
                description: Text(durableExperimentEnabled
                    ? "This server does not offer durable sessions. Turn on experimental.serverDurable on the server and restart it."
                    : "Turn on Settings → Experiments → Durable Sessions.")
            )
        } else if selectedServerIsSyncing || isLoadingDurableHistory, let selectedServer {
            ContentUnavailableView(
                "Loading Sessions",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text("Refreshing \(selectedServer.name)…")
            )
        } else if (selectedServerRefreshFailed || selectedServerTransportUnavailable), let selectedServer {
            ContentUnavailableView {
                Label("Server Data Unavailable", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(failedRetryServerId == activeServerId
                    ? "\(selectedServer.name) is still unavailable after retry."
                    : "\(selectedServer.name)'s workspace and session data are unavailable.")
            } actions: {
                Button("Retry") {
                    Task { await retryVisibleServer() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if scope == .durable {
            ContentUnavailableView(
                "No Durable Sessions",
                systemImage: "infinity",
                description: Text("Start a quick session here to run it on \(selectedServer?.name ?? "this server")'s durable engine.")
            )
        } else {
            ContentUnavailableView(
                "No Active Sessions",
                systemImage: "text.bubble",
                description: Text("No active sessions on \(selectedServer?.name ?? "this server"). Start a quick session or choose a workspace from the sidebar.")
            )
        }
    }

    private func entrySection(
        _ title: String,
        entries: [SessionListEntry],
        itemsById: [String: SessionInboxItem]
    ) -> some View {
        Section(title) {
            ForEach(entries) { entry in
                entryRow(entry, itemsById: itemsById)
            }
        }
    }

    private func stoppedSection(
        _ group: SessionInboxStoppedGroup,
        itemsById: [String: SessionInboxItem]
    ) -> some View {
        Section {
            if isStoppedDayExpanded(group.id, day: group.day) {
                ForEach(group.items, id: \.stoppedListID) { entry in
                    entryRow(entry, itemsById: itemsById)
                }
            }
        } header: {
            Button {
                toggleStoppedDayExpansion(group.id, day: group.day)
            } label: {
                HStack(spacing: 8) {
                    Text(SessionInboxSectionTitle.stopped(day: group.day, now: Date(), calendar: Calendar.current))
                    Spacer()
                    Image(systemName: isStoppedDayExpanded(group.id, day: group.day) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeComment)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.sessionList.\(group.id)")
            .accessibilityValue(isStoppedDayExpanded(group.id, day: group.day) ? "Expanded" : "Collapsed")
        }
    }

    private func entryRow(_ entry: SessionListEntry, itemsById: [String: SessionInboxItem]) -> some View {
        SessionListEntryRow(
            entry: entry,
            presentation: { session in
                guard let item = itemsById[session.id] ?? inboxItem(for: session, existing: nil) else {
                    return SessionRowPresentationBuilder.make(session: session)
                }
                return rowPresentation(for: item)
            },
            hasPendingAsk: { pendingAskCount(for: $0.id) > 0 },
            // Every All Sessions row already names its workspace.
            foreignWorkspaceName: { _ in nil },
            actions: rowActions(itemsById: itemsById)
        )
        .listRowBackground(theme.bg.primary)
    }

    private func rowActions(itemsById: [String: SessionInboxItem]) -> SessionListRowActions {
        let item = { (session: Session) in itemsById[session.id] ?? inboxItem(for: session, existing: nil) }
        return SessionListRowActions(
            open: { session in item(session).map(openSession) },
            openThread: { root in
                guard let activeServerId else { return }
                applySearchNavigation(.willOpenDestination)
                navigation.openSessionThread(SessionThreadNavTarget(serverId: activeServerId, rootSessionId: root.id))
            },
            stop: { session in
                guard let item = item(session) else { return }
                Task { await stopSession(item) }
            },
            resume: { session in
                guard let item = item(session) else { return }
                Task { await resumeSession(item) }
            },
            delete: { session in
                guard let item = item(session), let routeScope = routeScope(for: session) else { return nil }
                return {
                    pendingDelete = SessionInboxPendingDelete(
                        serverId: item.serverId,
                        routeScope: routeScope,
                        session: session
                    )
                }
            }
        )
    }

    private func isStoppedDayExpanded(_ groupID: String, day: Date) -> Bool {
        if expandedStoppedGroupIDs.contains(groupID) {
            return true
        }
        if collapsedStoppedGroupIDs.contains(groupID) {
            return false
        }
        return SessionInboxStoppedDayPolicy.isExpandedByDefault(
            day: day,
            now: Date(),
            calendar: Calendar.current
        )
    }

    private func toggleStoppedDayExpansion(_ groupID: String, day: Date) {
        if isStoppedDayExpanded(groupID, day: day) {
            expandedStoppedGroupIDs.remove(groupID)
            collapsedStoppedGroupIDs.insert(groupID)
        } else {
            collapsedStoppedGroupIDs.remove(groupID)
            expandedStoppedGroupIDs.insert(groupID)
        }
    }

    private func sessionItems() -> [SessionInboxItem] {
        guard let activeServerId,
              let connection = activeConnection else { return [] }

        let sessions: [Session] = switch scope {
        case .all:
            connection.sessionStore.listProjectionSessions
        case .durable:
            isDurableAvailable
                ? DurableSessionsPlayground.sessions(
                    history: durableHistory,
                    live: connection.sessionStore.listProjectionSessions
                )
                : []
        }
        return sessions.map { session in
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

    private func attentionCounts(for session: Session) -> SessionListAttentionCounts {
        SessionRowPresentationBuilder.attentionCounts(
            sessionId: session.id,
            pendingAskCountForSession: { pendingAskCount(for: $0) }
        )
    }

    /// All Sessions shows one server, so every row reads the active connection.
    private func pendingAskCount(for sessionId: String) -> Int {
        guard let connection = activeConnection else { return 0 }
        return SessionListAttentionMerger.askCount(
            listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
            hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
            hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
        )
    }

    private func rowPresentation(for item: SessionInboxItem) -> SessionRowPresentation {
        let attention = attentionCounts(for: item.session)
        return SessionRowPresentationBuilder.make(
            session: item.session,
            pendingAskCount: attention.askCount,
            pendingAsk: item.connection.askRequestStore.pending(for: item.session.id),
            workspaceContext: SessionInboxSessionRouting.allSessionsContext(
                for: item.session,
                workspaceName: item.workspace?.name
            ),
            unreadCompletionAt: item.connection.sessionStore.unreadCompletionDate(for: item.session.id),
            searchSnippet: searchStore.snippetsBySessionId[item.session.id],
            catalogModels: item.connection.chatState.cachedModels
        )
    }

    private func openSession(_ item: SessionInboxItem) {
        var normalized = item.session
        if normalized.control == nil,
           normalized.workspaceId == nil || normalized.workspaceId?.isEmpty == true {
            normalized.workspaceId = item.workspace?.id
        }
        if normalized.workspaceName == nil || normalized.workspaceName?.isEmpty == true {
            normalized.workspaceName = item.workspace?.name
        }
        guard let routeScope = SessionInboxSessionRouting.routeScope(for: normalized) else {
            error = "Session route is unavailable"
            return
        }
        applySearchNavigation(.willOpenDestination)
        item.connection.sessionStore.cacheSessionForNavigation(normalized)

        let workspaceTarget = item.workspace.map { WorkspaceNavTarget(serverId: item.serverId, workspace: $0) }
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
        durableHistory.removeAll { $0.id == pending.session.id }
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

    private var compactQuickSessionBar: some View {
        SessionInboxCompactComposeBar(
            showsDictation: SessionInboxComposeChrome.showsDictationShortcut(
                voiceInputEnabled: ReleaseFeatures.voiceInputEnabled,
                hasActivePlayback: sessionListHasActivePlayback
            ),
            hasActivePlayback: sessionListHasActivePlayback,
            columnWidth: composeBarColumnWidth,
            onIncognito: nil,
            onStart: {
                startQuickSession(dictate: false)
            },
            onDictate: {
                startQuickSession(dictate: true)
            }
        )
        .disabled(quickSessionLaunch == .unavailable)
    }

    private func startQuickSession(dictate: Bool) {
        switch quickSessionLaunch {
        case .standard:
            break
        case .context(let context):
            navigation.pendingQuickSessionLaunchContext = context
        case .unavailable:
            return
        }
        if dictate {
            navigation.pendingQuickSessionStartDictation = true
        }
        navigation.showQuickSession = true
    }

    private func applyE2ELaunchHintsIfNeeded() {
        autoOpenE2EWorkspaceIfRequested()
        autoOpenE2ESessionIfRequested()
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
              // A requested workspace opens the session from its own list instead.
              ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"] == nil,
              let item = sessionItems().first(where: { $0.session.id == sessionId })
        else { return }

        hasAutoOpenedE2ESession = true
        openSession(item)
    }

    private var inboxFolderButton: some View {
        SessionInboxFolderToolbarButton(
            isEnabled: SessionInboxComposeChrome.canOpenFiles(hasServer: activeServerId != nil),
            accessibilityLabel: "Open server files",
            onOpen: openInboxFiles
        )
    }

    private func openInboxFiles() {
        guard let activeServerId else { return }
        navigation.openWorkspaceFileBrowser(FileBrowserNavTarget.hostHome(serverId: activeServerId))
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
    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var sshTerminalEnabled = false
    @AppStorage(AppPreferences.Experiments.durableSessionsKey) private var durableSessionsEnabled = false
    @AppStorage(SSHTerminalProfileStore.storageKey) private var sshProfileData = Data()
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
                        WorkspaceSidebarPrimaryUtilities.items(
                            for: UIDevice.current.userInterfaceIdiom,
                            sshTerminalEnabled: sshTerminalEnabled,
                            hasSSHProfile: (try? JSONDecoder().decode(SSHTerminalProfile.self, from: sshProfileData))?.isConfigured == true,
                            durableSessionsAvailable: DurableSessionsPlayground.isAvailable(
                                experimentEnabled: durableSessionsEnabled,
                                serverOffersDurable: selectedServer
                                    .flatMap { coordinator.connection(for: $0.id) }?
                                    .durableSessionsAvailable == true
                            )
                        )
                            .filter { $0.target.isReleaseEnabled },
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
                            lastSyncFailed: workspaceStore?.lastSyncFailed ?? false,
                            hasAPIClient: connection?.apiClient != nil,
                            isPreparing: coordinator.preparingServerIds.contains(serverId)
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
                                    Task {
                                        if connection?.apiClient == nil {
                                            await coordinator.retryServerConnection(serverId)
                                        } else {
                                            await coordinator.refreshServer(serverId, force: true)
                                        }
                                    }
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
                            if connection == nil
                                || connection?.serverHealth(forServer: serverId).transportState == .disconnected
                                || workspaceStore?.lastSyncFailed == true {
                                Label("Saved workspaces may be out of date", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                    .font(.subheadline)
                                    .foregroundStyle(.themeOrange)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 8)
                            }
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
            minimumHitHeight: item.minimumHitHeight,
            accessibilityHint: item.accessibilityHint
        )
    }

    private func sidebarUtilityRow(
        _ target: WorkspaceUtilityNavTarget,
        title: String,
        systemImage: String,
        accessibilityLabel: String? = nil,
        accessibilityIdentifier: String? = nil,
        minimumHitHeight: CGFloat = 44,
        accessibilityHint: String? = nil
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
        .accessibilityHint(accessibilityHint ?? "Opens \(title.lowercased()) management")
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
    @Environment(\.themeID) private var themeID

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
        .id(themeID)
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
        tint: ThemeShapeStyle,
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

    private func metric(symbol: String, count: Int, tint: ThemeShapeStyle) -> some View {
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
