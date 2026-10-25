import UIKit

/// All Sessions: the active server's sessions, the compact stack's root and
/// the split detail root when nothing is selected.
///
/// The workspace sidebar owns project selection. This screen keeps the main
/// content focused on session rows and uses small row context instead of a
/// workspace header card. It reads the app's stores in `updateProperties()`,
/// builds a value per row, and applies a diffable snapshot keyed by session
/// id to its `SessionListCollection`, which owns the cells, taps, swipes, and
/// long-press menu.
final class SessionInboxViewController: UIViewController {
    /// Opens the workspace drawer; set only at the compact root.
    var onOpenSidebar: (() -> Void)? {
        didSet { setNeedsUpdateProperties() }
    }

    /// The split detail root carries the sidebar toggle.
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    private let root: AppRootEnvironment
    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var navigation: AppNavigation { root.navigation }

    private typealias List = SessionListCollection<Section, Item, Row, StoppedDay>
    private lazy var list = List(
        root: root,
        appearance: .plain,
        actions: rowActions,
        iconAssetCache: { [weak self] in self?.coordinator.activeConnection.iconAssetCache },
        configureRow: { [weak self] cell, row in self?.configure(cell, row: row) },
        onToggle: { [weak self] day in self?.toggleStoppedDayExpansion(day.groupID, day: day.day) }
    )
    private let search = ScreenSearchController(prompt: String(localized: "Search sessions"))
    private let searchStore = SessionSearchStore()
    private let titleLabel = UILabel()
    private let hiddenSystemTitle = UIView()

    // Screen-local state (the SwiftUI screen's @State).
    private var failedRetryServerId: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var expandedStoppedGroupIDs: Set<String> = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var collapsedStoppedGroupIDs: Set<String> = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var providerSetupState: ProviderSetupState = .unknown {
        didSet { setNeedsUpdateProperties() }
    }
    /// The push discovery card's own progress: the relay disclosure was accepted and
    /// registration is running, or it failed.
    private var pushDiscoveryProgress: PushDiscoveryProgress? {
        didSet { setNeedsUpdateProperties() }
    }
    private var hasAutoOpenedE2EWorkspace = false
    private var hasAutoOpenedE2ESession = false
    private var pendingError: String?
    private var columnWidth: CGFloat = 0 {
        didSet { if columnWidth != oldValue { setNeedsUpdateProperties() } }
    }

    /// Between `viewIsAppearing` and `viewDidDisappear`. A covered screen
    /// neither renders nor reacts, the way a hosted SwiftUI screen stops.
    private var isOnScreen = false
    /// Values whose changes this screen reacts to; nil until it first shows.
    private var observed: Observed?
    /// The active server's refresh, run on appearance and server change and
    /// cancelled when the screen leaves (SwiftUI `.task(id:)`).
    private var serverTask: Task<Void, Never>?
    private var serverTaskServerId: String??

    /// The listed sessions' context and routing, by session id.
    private var itemsById: [String: InboxItem] = [:]
    private var lastThemeID: ThemeID?

    // Bars.
    private var barState: BarState?
    private lazy var bottomBar = SessionListBottomBar(
        root: root,
        onStart: { [weak self] in self?.startQuickSession(dictate: false) },
        onDictate: { [weak self] in self?.startQuickSession(dictate: true) },
        onNowPlaying: { [weak self] in self?.openNowPlaying() }
    )
    private var switcher: SessionListServerSwitcher?
    private var switcherServerId: String?
    private var sidebarToggle: UIBarButtonItem?

    private lazy var rowActions = SessionListRowActions(
        open: { [weak self] session in
            guard let self, let item = item(for: session) else { return }
            open(item)
        },
        openThread: { [weak self] rootSession in
            self?.openThread(rootSession)
        },
        stop: { [weak self] session in
            guard let self, let item = item(for: session) else { return }
            Task { await self.setRunning(false, item) }
        },
        resume: { [weak self] session in
            guard let self, let item = item(for: session) else { return }
            Task { await self.setRunning(true, item) }
        },
        delete: { [weak self] session in
            guard let self, let item = item(for: session),
                  let routeScope = SessionInboxSessionRouting.routeScope(for: session) else { return nil }
            let pending = PendingDelete(serverId: item.serverId, routeScope: routeScope, session: session)
            return { [weak self] in self?.confirmDelete(pending) }
        },
        lockTarget: { [weak self] session in
            self?.coordinator.activeServerId.map { ScopedLockTarget.session(session, serverId: $0) }
        }
    )

    init(root: AppRootEnvironment, onOpenSidebar: (() -> Void)? = nil, showsSidebarToggle: Bool = false) {
        self.root = root
        self.onOpenSidebar = onOpenSidebar
        self.showsSidebarToggle = showsSidebarToggle
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = String(localized: "All Sessions")
        navigationItem.largeTitleDisplayMode = .never
        // Pushed screens show a bare chevron (the shell's `.minimal` Back) that
        // speaks "All Sessions". A UIKit item's minimal Back otherwise speaks
        // "Back"; the hosted SwiftUI screen spoke its title.
        let back = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
        back.accessibilityLabel = String(localized: "All Sessions")
        navigationItem.backBarButtonItem = back
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        serverTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        let collectionView = list.collectionView
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        list.refreshControl.addAction(UIAction { [weak self] _ in self?.pullToRefresh() }, for: .valueChanged)

        titleLabel.text = String(localized: "All Sessions")
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75
        titleLabel.accessibilityLabel = String(localized: "All Sessions")
        titleLabel.accessibilityIdentifier = "workspace.inbox.title"

        search.install(on: self, alwaysVisible: false)
        search.bind(
            get: { [weak self] in self?.navigation.inboxSessionSearch ?? .init() },
            set: { [weak self] in self?.navigation.inboxSessionSearch = $0 }
        )
        SessionListBarItems.updatesWithVerticalBarEdge(self)
        // The card's stage lives in UserDefaults: a first finished session, a dismissal, or
        // turning push on elsewhere changes whether it shows.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pushDiscoveryDidChange),
            name: PushDiscovery.didChangeNotification,
            object: nil
        )
    }

    @objc private func pushDiscoveryDidChange() {
        setNeedsUpdateProperties()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        // Like SwiftUI `.task(id:)`, the refresh starts again each time the
        // screen shows. The vertical bar edge is known only in the window.
        startServerTask(for: coordinator.activeServerId)
        setNeedsUpdateProperties()
        updatePropertiesIfNeeded()
        navigationController?.setToolbarHidden(toolbarItems?.isEmpty ?? true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.hostDidAppear(self)
        // A search asked for while covered starts on return.
        search.setPresented(navigation.inboxSessionSearch.isSearchPresented)
        presentPendingError()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        recordCoverageBeforeGoingQuiet()
        isOnScreen = false
        serverTask?.cancel()
        serverTask = nil
        serverTaskServerId = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The bottom bar lays out inside the safe area; see WorkspaceDetailViewController.
        columnWidth = view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
    }

    override func updateProperties() {
        super.updateProperties()
        let themeStore = root.themeStore
        overrideUserInterfaceStyle = themeStore.userInterfaceStyle
        guard isOnScreen else { return }

        reactToChanges()

        let themeID = themeStore.activeThemeID
        if lastThemeID != themeID {
            lastThemeID = themeID
            view.backgroundColor = themeStore.backgroundColor
            list.collectionView.backgroundColor = themeStore.backgroundColor
            titleLabel.textColor = UIColor(themeID.palette.fg)
        }

        let state = readState()
        search.show(state.search, toolbar: state.toolbar)
        applySnapshot(state)
        syncBars(state)
    }

    // MARK: State

    /// What the screen shows, read from the stores. Reads here are tracked,
    /// so a store change runs `updateProperties()` again.
    private func readState() -> InboxState {
        let activeServerId = coordinator.activeServerId
        let connection = activeServerId.flatMap { coordinator.connection(for: $0) }
        let servers = coordinator.serverStore.servers
        let selectedServer = activeServerId.flatMap { id in servers.first { $0.id == id } } ?? servers.first
        let searchState = navigation.inboxSessionSearch
        let hasActivePlayback = connection?.audioPlayer.hasActivePlayback == true
        let showsVersionNotice = selectedServer != nil
            && ServerReleaseVersion.isBelowMinimum(connection?.connectedServerVersion)
        let showsProviderPrompt = ProviderSetupPromptPolicy.shouldShow(for: providerSetupState)
            && selectedServer != nil
            && !showsVersionNotice
        // One setup card at a time: the push card waits behind the version and provider prompts.
        // A turn-on in progress keeps its card, though push is already marked on, so the
        // progress and a failure stay visible.
        let showsPushDiscovery = !showsVersionNotice && !showsProviderPrompt
            && activeServerId.map { serverId in
                PushDiscoveryProgress.status(of: pushDiscoveryProgress, for: serverId) != .idle || PushDiscovery.shouldShow(
                    stage: PushDiscovery.stage(serverId: serverId),
                    pushAvailable: PushDiscovery.isPushAvailable(relay: connection?.pushRelay),
                    pushEnabled: PushRegistration.isEnabled(serverId: serverId)
                )
            } == true
        return InboxState(
            activeServerId: activeServerId,
            connection: connection,
            selectedServer: selectedServer,
            search: searchState,
            hasSearchQuery: SessionListSearchPresentation.hasQuery(searchState.searchText),
            hasActivePlayback: hasActivePlayback,
            toolbar: InAppNowPlayingChrome.sessionListToolbar(
                hasActivePlayback: hasActivePlayback,
                isSearchPresented: searchState.isSearchPresented
            ),
            showsVersionNotice: showsVersionNotice,
            showsProviderPrompt: showsProviderPrompt,
            showsPushDiscovery: showsPushDiscovery,
            refreshFailed: connection.map { $0.workspaceStore.lastSyncFailed || $0.sessionStore.lastSyncFailed } ?? false,
            transportUnavailable: activeServerId.flatMap { id in
                connection.map { connection in
                    SessionInboxTransportAvailability.isUnavailable(
                        hasAPIClient: connection.apiClient != nil,
                        isPreparing: coordinator.preparingServerIds.contains(id)
                    )
                }
            } ?? false,
            isSyncing: (activeServerId.map { coordinator.preparingServerIds.contains($0) } ?? false)
                || connection?.workspaceStore.isSyncing == true
                || connection?.sessionStore.isSyncing == true
        )
    }

    private func viewData(_ state: InboxState) -> ViewData {
        let items = sessionItems(serverId: state.activeServerId, connection: state.connection)
        var itemsById = Dictionary(items.map { ($0.session.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let matches = searchStore.sessionListMatches(
            localSessions: items.map(\.session),
            query: state.search.searchText,
            serverId: state.activeServerId,
            extraCandidates: { session in [itemsById[session.id]?.workspace?.name] }
        ) {
            let searchItems = matches.compactMap { match in
                itemsById[match.session.id] ?? inboxItem(for: match.session, state: state)
            }
            for item in searchItems { itemsById[item.session.id] = item }
            return ViewData(
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
        let sessions = items.map(\.session)
        let entries = SessionListEntries.entries(
            threadsEnabled: navigation.sessionThreadsEnabled,
            listed: sessions,
            loaded: sessions
        )
        let connection = state.connection
        let attention = { (session: Session) in
            SessionListAttentionCounts(askCount: connection?.sessionListAskCount(for: session.id) ?? 0)
        }
        let grouped = SessionInboxGrouping.make(
            items: entries,
            now: Date(),
            calendar: Calendar.current,
            session: \.representative,
            attention: { attention($0.session) },
            sectionKind: { $0.sectionKind(attention: attention) },
            isBlocked: { $0.isBlocked(attention: attention) }
        )
        return ViewData(
            yourTurn: grouped.yourTurn,
            working: grouped.working,
            stoppedGroups: grouped.stoppedGroups,
            searchMatches: [],
            itemsById: itemsById,
            isSearching: false,
            isEmpty: grouped.isEmpty
        )
    }

    private func sessionItems(serverId: String?, connection: ServerConnection?) -> [InboxItem] {
        guard let serverId, let connection else { return [] }
        let workspaces = Dictionary(
            connection.workspaceStore.workspaces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return connection.sessionStore.listProjectionSessions.map { session in
            InboxItem(
                serverId: serverId,
                connection: connection,
                session: session,
                workspace: session.workspaceId.flatMap { workspaces[$0] }
            )
        }
    }

    private func inboxItem(for session: Session, state: InboxState) -> InboxItem? {
        guard let serverId = state.activeServerId, let connection = state.connection else { return nil }
        return InboxItem(
            serverId: serverId,
            connection: connection,
            session: session,
            workspace: session.workspaceId.flatMap { workspaceId in
                connection.workspaceStore.workspaces.first { $0.id == workspaceId }
            }
        )
    }

    /// The row's context and routing; a session no longer listed (a search
    /// match, a row acted on after a refresh) resolves against the active server.
    private func item(for session: Session) -> InboxItem? {
        if let item = itemsById[session.id] { return item }
        guard let serverId = coordinator.activeServerId, let connection = coordinator.connection(for: serverId) else {
            return nil
        }
        return InboxItem(
            serverId: serverId,
            connection: connection,
            session: session,
            workspace: session.workspaceId.flatMap { workspaceId in
                connection.workspaceStore.workspaces.first { $0.id == workspaceId }
            }
        )
    }

    /// Every listed entry has its item, which names the row's workspace
    /// (every All Sessions row does) and carries the active connection.
    private func rowContent(for entry: SessionListEntry, data: ViewData) -> SessionListRowContent? {
        guard let item = data.itemsById[entry.session.id] else { return nil }
        return SessionListRowContent.make(
            entry: entry,
            connection: item.connection,
            workspaceContext: SessionInboxSessionRouting.allSessionsContext(
                for: item.session,
                workspaceName: item.workspace?.name
            ),
            searchSnippet: searchStore.snippetsBySessionId[item.session.id],
            lockTarget: rowActions.lockTarget,
            callBadge: root.liveVoiceCalls.rowBadge(serverId: item.serverId, sessionId: item.session.id)
        )
    }

    private func isStoppedDayExpanded(_ groupID: String, day: Date) -> Bool {
        if expandedStoppedGroupIDs.contains(groupID) {
            return true
        }
        if collapsedStoppedGroupIDs.contains(groupID) {
            return false
        }
        return SessionInboxStoppedDayPolicy.isExpandedByDefault(day: day, now: Date(), calendar: Calendar.current)
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

    // MARK: Reactions

    /// Side effects of state changes, in the order the SwiftUI screen
    /// declared them. They run before this pass reads state; a change they
    /// make runs another pass.
    private func reactToChanges() {
        let current = Observed(
            searchText: navigation.inboxSessionSearch.searchText,
            isSearchPresented: navigation.inboxSessionSearch.isSearchPresented,
            coverage: currentCoverageKey,
            activeServerId: coordinator.activeServerId,
            stackCount: navigation.workspaceStackRouteElements.count,
            splitPathCount: navigation.splitDetailPathElements.count
        )
        guard let previous = observed else {
            observed = current
            return
        }
        guard previous != current else { return }
        observed = current
        if previous.searchText != current.searchText {
            applySearchNavigation(.searchTextChanged(current.searchText))
            refreshSearch()
        }
        if previous.isSearchPresented != current.isSearchPresented {
            applySearchNavigation(.searchPresentationChanged(current.isSearchPresented))
        }
        if previous.coverage != current.coverage {
            applySearchNavigation(.coverageChanged(isCovered: isSearchListCoveredByDestination))
        }
        if previous.activeServerId != current.activeServerId {
            resetLocalHostState()
            startServerTask(for: current.activeServerId)
        }
        if current.stackCount < previous.stackCount {
            Task { await loadProviderSetupState() }
        }
        if current.splitPathCount < previous.splitPathCount {
            Task { await loadProviderSetupState() }
        }
    }

    private func startServerTask(for serverId: String?) {
        if serverTask != nil, serverTaskServerId == .some(serverId) { return }
        serverTask?.cancel()
        serverTaskServerId = .some(serverId)
        serverTask = Task { [weak self] in
            guard let self else { return }
            if SessionListSearchPresentation.hasQuery(navigation.inboxSessionSearch.searchText) {
                refreshSearch()
            }
            providerSetupState = .unknown
            async let refresh: () = refreshVisibleServer()
            async let providers: () = loadProviderSetupState()
            _ = await (refresh, providers)
            applyE2ELaunchHintsIfNeeded()
        }
    }

    private var currentCoverageKey: String {
        "\(navigation.workspaceStackRouteElements.count):\(navigation.workspaceNavigationPresentation):\(navigation.splitDetailTarget != nil)"
    }

    /// A covered screen stops reacting, and no update pass is guaranteed
    /// between the push and here (a non-animated push, a route restore). Take
    /// the covered state now so Back always sees covered then uncovered and
    /// presents the search again.
    private func recordCoverageBeforeGoingQuiet() {
        guard isSearchListCoveredByDestination else { return }
        applySearchNavigation(.coverageChanged(isCovered: true))
        observed?.coverage = currentCoverageKey
        observed?.stackCount = navigation.workspaceStackRouteElements.count
        observed?.splitPathCount = navigation.splitDetailPathElements.count
    }

    private var isSearchListCoveredByDestination: Bool {
        SessionListSearchNavigationPersistence.isInboxCovered(
            isSplitPresentation: navigation.workspaceNavigationPresentation == .split,
            stackDepth: navigation.workspaceStackRouteElements.count,
            splitDetailReplacesList: navigation.splitDetailTarget != nil
        )
    }

    private func applySearchNavigation(_ event: SessionListSearchNavigationPersistence.Event) {
        let next = SessionListSearchNavigationPersistence.reduce(
            navigation.inboxSessionSearch,
            event: event,
            isCoveredByDestination: isSearchListCoveredByDestination
        )
        if next != navigation.inboxSessionSearch {
            navigation.inboxSessionSearch = next
        }
    }

    private func refreshSearch() {
        let serverId = coordinator.activeServerId
        searchStore.search(
            query: navigation.inboxSessionSearch.searchText,
            workspaceId: nil,
            apiClient: serverId.flatMap { coordinator.connection(for: $0) }?.apiClient
        )
    }

    private func resetLocalHostState() {
        applySearchNavigation(.reset)
        navigation.workspaceSessionSearchByID = [:]
        let reset = SessionInboxHostChange.reset(
            searchText: navigation.inboxSessionSearch.searchText,
            expandedStoppedGroupIDs: expandedStoppedGroupIDs,
            collapsedStoppedGroupIDs: collapsedStoppedGroupIDs,
            searchStore: searchStore
        )
        expandedStoppedGroupIDs = reset.expandedStoppedGroupIDs
        collapsedStoppedGroupIDs = reset.collapsedStoppedGroupIDs
    }

    private func pullToRefresh() {
        Task { [weak self] in
            guard let self else { return }
            async let refresh: () = refreshVisibleServer()
            async let providers: () = loadProviderSetupState()
            _ = await (refresh, providers)
            list.refreshControl.endRefreshing()
        }
    }

    private func refreshVisibleServer() async {
        guard let serverId = coordinator.activeServerId else { return }
        await coordinator.refreshServer(serverId, force: true)
    }

    private func retryVisibleServer() async {
        guard let serverId = coordinator.activeServerId else { return }
        failedRetryServerId = nil
        if coordinator.connection(for: serverId)?.apiClient == nil {
            await coordinator.retryServerConnection(serverId)
        } else {
            await refreshVisibleServer()
        }
        guard coordinator.activeServerId == serverId else { return }
        let state = readState()
        failedRetryServerId = state.refreshFailed || state.transportUnavailable ? serverId : nil
    }

    private func loadProviderSetupState() async {
        guard let requestedServerId = coordinator.activeServerId else {
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

    // MARK: Snapshot

    private func applySnapshot(_ state: InboxState) {
        let data = viewData(state)
        itemsById = data.itemsById
        var next = List.Snapshot()
        func appendSessions(_ entries: [SessionListEntry], to section: Section, item: (String) -> Item) {
            next.append(sessions: entries, to: section, item: item) { rowContent(for: $0, data: data) }
        }

        if state.showsVersionNotice, let server = state.selectedServer {
            next.appendSection(.prompt, item: .prompt, row: .serverVersion(serverId: server.id))
        } else if state.showsProviderPrompt, let server = state.selectedServer {
            next.appendSection(.prompt, item: .prompt, row: .providerSetup(serverId: server.id, serverName: server.name))
        }

        if state.showsPushDiscovery, let serverId = state.activeServerId {
            next.appendSection(
                .pushDiscovery,
                item: .pushDiscovery,
                row: .pushDiscovery(serverId: serverId, status: PushDiscoveryProgress.status(of: pushDiscoveryProgress, for: serverId))
            )
        }

        if state.refreshFailed, !data.isEmpty, let server = state.selectedServer {
            next.appendSection(.cachedWarning, item: .cachedWarning, row: .cachedWarning(serverName: server.name))
        }

        if state.hasSearchQuery {
            if data.isSearching && data.searchMatches.isEmpty {
                next.appendSection(.status, item: .searching, row: .searching)
            } else if data.searchMatches.isEmpty {
                let query = state.search.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                next.appendSection(.status, item: .noMatches, row: .noMatches(query: query))
            } else {
                next.appendSection(.results, header: .title(String(localized: "Results")))
                appendSessions(data.searchMatches, to: .results, item: Item.session)
            }
        } else {
            if !data.yourTurn.isEmpty {
                next.appendSection(.yourTurn, header: .title(SessionInboxSectionTitle.yourTurn))
                appendSessions(data.yourTurn, to: .yourTurn, item: Item.session)
            }
            if !data.working.isEmpty {
                next.appendSection(.working, header: .title(SessionInboxSectionTitle.working))
                appendSessions(data.working, to: .working, item: Item.session)
            }
            let now = Date()
            for group in data.stoppedGroups {
                let section = Section.stopped(group.id)
                let isExpanded = isStoppedDayExpanded(group.id, day: group.day)
                next.appendSection(section, header: .group(
                    title: SessionInboxSectionTitle.stopped(day: group.day, now: now, calendar: Calendar.current),
                    isExpanded: isExpanded,
                    accessibilityIdentifier: "workspace.sessionList.\(group.id)",
                    toggle: StoppedDay(groupID: group.id, day: group.day)
                ))
                if isExpanded {
                    appendSessions(group.items, to: section, item: Item.stoppedSession)
                }
            }
            if ProviderSetupPromptPolicy.shouldShowInboxEmptyState(
                isEmpty: data.isEmpty,
                showsProviderSetup: state.showsProviderPrompt || state.showsVersionNotice
            ) {
                next.appendSection(.empty, item: .empty, row: .empty(emptyState(state)))
            }
        }
        list.apply(next)
    }

    private func emptyState(_ state: InboxState) -> EmptyState {
        guard state.activeServerId != nil else { return .noServers }
        if state.isSyncing, let server = state.selectedServer {
            return .loading(serverName: server.name)
        }
        if state.refreshFailed || state.transportUnavailable, let server = state.selectedServer {
            return .unavailable(serverName: server.name, afterRetry: failedRetryServerId == state.activeServerId)
        }
        return .noActiveSessions(serverName: state.selectedServer?.name ?? String(localized: "this server"))
    }

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        let palette = root.themeStore.activeThemeID.palette
        switch row {
        case .serverVersion(let serverId):
            cell.backgroundConfiguration = .clear()
            cell.contentConfiguration = ServerVersionPromptConfiguration(themeID: root.themeStore.activeThemeID) { [weak self] in
                self?.navigation.openHostSwitcherDestination(.serverSettings, serverId: serverId)
            }
        case .providerSetup(let serverId, let serverName):
            cell.backgroundConfiguration = .clear()
            cell.contentConfiguration = ProviderSetupPromptListRow.providerSetup(
                root: root,
                message: String(localized: "Connect a model provider before starting a session on \(serverName)."),
                openAccessibilityIdentifier: "workspace.providerSetup.open"
            ) { [weak self] in
                self?.navigation.openModelProviders(ModelProvidersNavTarget(serverId: serverId))
            }
        case .pushDiscovery(let serverId, let status):
            cell.backgroundConfiguration = .clear()
            cell.contentConfiguration = PushDiscoveryCardConfiguration(
                themeID: root.themeStore.activeThemeID,
                status: status,
                onTurnOn: { [weak self] in self?.turnOnPush(serverId: serverId) },
                onDismiss: { [weak self] in self?.dismissPushDiscovery(serverId: serverId) }
            )
        case .cachedWarning(let serverName):
            var content = UIListContentConfiguration.cell()
            content.image = UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            content.imageProperties.tintColor = UIColor(palette.orange)
            content.text = String(localized: "Showing cached server data for \(serverName). Pull to retry.")
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.textProperties.color = UIColor(palette.orange)
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "workspace.sessionList.cachedWarning"
        case .searching:
            cell.contentConfiguration = UIContentUnavailableConfiguration.sessionListSearching()
        case .noMatches(let query):
            cell.contentConfiguration = UIContentUnavailableConfiguration.sessionListNoMatches(query: query)
        case .empty(let empty):
            cell.contentConfiguration = emptyConfiguration(empty)
        }
    }

    private func emptyConfiguration(_ empty: EmptyState) -> UIContentUnavailableConfiguration {
        var content = UIContentUnavailableConfiguration.empty()
        switch empty {
        case .noServers:
            content.image = UIImage(systemName: "server.rack")
            content.text = String(localized: "No Servers")
            content.secondaryText = String(localized: "Pair with a server to get started.")
        case .loading(let serverName):
            content.image = UIImage(systemName: "arrow.triangle.2.circlepath")
            content.text = String(localized: "Loading Sessions")
            content.secondaryText = String(localized: "Refreshing \(serverName)…")
        case .unavailable(let serverName, let afterRetry):
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.text = String(localized: "Server Data Unavailable")
            content.secondaryText = afterRetry
                ? String(localized: "\(serverName) is still unavailable after retry.")
                : String(localized: "\(serverName)'s workspace and session data are unavailable.")
            var button = UIButton.Configuration.borderedProminent()
            button.title = String(localized: "Retry")
            content.button = button
            content.buttonProperties.primaryAction = UIAction { [weak self] _ in
                Task { await self?.retryVisibleServer() }
            }
        case .noActiveSessions(let serverName):
            content.image = UIImage(systemName: "text.bubble")
            content.text = String(localized: "No Active Sessions")
            content.secondaryText = String(
                localized: "No active sessions on \(serverName). Start a quick session or choose a workspace from the sidebar."
            )
        }
        return content
    }

    // MARK: Actions

    /// Server Settings' turn-on path: the relay disclosure, then registration, which asks
    /// iOS for notification permission. The card leaves when push is on (`PushDiscovery`
    /// closes as the opt-in is saved) and says why when it could not turn on.
    private func turnOnPush(serverId: String) {
        guard let connection = coordinator.connection(for: serverId) else { return }
        PushEnableFlow.start(
            connection: connection,
            presenter: self,
            openPrivacyPolicy: { [weak self] in
                self?.root.opener.open(.webLink(AppSupportLinks.privacyPolicyURL))
            },
            progress: { [weak self] outcome in
                switch outcome {
                case .cancelled, .enabled: self?.pushDiscoveryProgress = nil
                case .working: self?.pushDiscoveryProgress = PushDiscoveryProgress(serverId: serverId, status: .working)
                case .failed(let message):
                    self?.pushDiscoveryProgress = PushDiscoveryProgress(serverId: serverId, status: .failed(message))
                }
            }
        )
    }

    private func dismissPushDiscovery(serverId: String) {
        pushDiscoveryProgress = nil
        PushDiscovery.close(serverId: serverId)
    }

    private func open(_ item: InboxItem) {
        var normalized = item.session
        if normalized.control == nil,
           !normalized.isControlConversation,
           normalized.workspaceId == nil || normalized.workspaceId?.isEmpty == true {
            normalized.workspaceId = item.workspace?.id
        }
        if normalized.workspaceName == nil || normalized.workspaceName?.isEmpty == true {
            normalized.workspaceName = item.workspace?.name
        }
        guard let routeScope = SessionInboxSessionRouting.routeScope(for: normalized) else {
            showError(String(localized: "Session route is unavailable"))
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

    private func openThread(_ rootSession: Session) {
        guard let serverId = coordinator.activeServerId else { return }
        applySearchNavigation(.willOpenDestination)
        navigation.openSessionThread(SessionThreadNavTarget(serverId: serverId, rootSessionId: rootSession.id))
    }

    /// Stops or resumes on the session's own route.
    private func setRunning(_ running: Bool, _ item: InboxItem) async {
        guard let routeScope = SessionInboxSessionRouting.routeScope(for: item.session) else { return }
        await SessionListLifecycle.setRunning(
            running, item.session, scope: routeScope, connection: item.connection
        ) { showError($0) }
    }

    private func confirmDelete(_ pending: PendingDelete) {
        let id = pending.session.id
        let sourceView = list.cell(forFirstOf: [.session(id), .stoppedSession(id)])
        SessionListAlerts.confirmDelete(pending.session, from: self, sourceView: sourceView) { [weak self] in
            Task { await self?.delete(pending) }
        }
    }

    private func delete(_ pending: PendingDelete) async {
        guard let connection = coordinator.connection(for: pending.serverId) else { return }
        await SessionListLifecycle.delete(
            pending.session,
            scope: pending.routeScope,
            serverId: pending.serverId,
            connection: connection,
            drafts: root.composerDraftStore
        ) { showError($0) }
    }

    private func showError(_ message: String) {
        pendingError = message
        presentPendingError()
    }

    private func presentPendingError() {
        guard isOnScreen else { return }
        SessionListAlerts.presentPendingError(&pendingError, from: self)
    }

    private func switchVisibleServer() {
        pendingError = nil
        if let alert = presentedViewController as? SessionListErrorAlert {
            alert.dismiss(animated: true)
        }
        navigation.showAllWorkspaceSessions()
    }

    private func startQuickSession(dictate: Bool) {
        navigation.presentQuickSession(
            QuickSessionStart(mode: dictate ? .dictation : .message),
            from: .sessionListBar
        )
    }

    private func openNowPlaying() {
        guard let player = coordinator.activeServerId.flatMap({ coordinator.connection(for: $0) })?.audioPlayer else {
            return
        }
        SessionListHostedChrome.presentNowPlayingPlayer(player, from: self)
    }

    private func openFiles() {
        guard let serverId = coordinator.activeServerId else { return }
        navigation.openWorkspaceFileBrowser(FileBrowserNavTarget.hostHome(serverId: serverId))
    }

    // MARK: E2E launch hints

    private func applyE2ELaunchHintsIfNeeded() {
        autoOpenE2EWorkspaceIfRequested()
        autoOpenE2ESessionIfRequested()
    }

    private func autoOpenE2EWorkspaceIfRequested() {
        guard !hasAutoOpenedE2EWorkspace,
              navigation.workspaceStackRouteElements.isEmpty,
              let workspaceName = ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"],
              !workspaceName.isEmpty,
              let serverId = coordinator.activeServerId,
              let connection = coordinator.connection(for: serverId),
              let workspace = connection.workspaceStore.workspaces.first(where: { $0.name == workspaceName })
        else { return }

        hasAutoOpenedE2EWorkspace = true
        navigation.openWorkspace(WorkspaceNavTarget(serverId: serverId, workspace: workspace))
    }

    private func autoOpenE2ESessionIfRequested() {
        let serverId = coordinator.activeServerId
        guard !hasAutoOpenedE2ESession,
              let sessionId = ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"],
              !sessionId.isEmpty,
              // A requested workspace opens the session from its own list instead.
              ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"] == nil,
              let item = sessionItems(serverId: serverId, connection: serverId.flatMap { coordinator.connection(for: $0) })
                .first(where: { $0.session.id == sessionId })
        else { return }

        hasAutoOpenedE2ESession = true
        open(item)
    }

    // MARK: Bars

    /// Rail and compact bars. Items rebuild when their set changes; the
    /// SwiftUI controls inside them update in place.
    ///
    /// Message stays installed while a chat is pushed over this list. Bar
    /// items belong to this controller, and the chat shows its own (none,
    /// with the toolbar hidden), so the capsule never sits on the chat's
    /// composer. Kept installed, it slides in with the pop instead of
    /// appearing after it, when the shell's routes catch up.
    private func syncBars(_ state: InboxState) {
        let joinsRail = SessionListBarItems.joinsRail(traitCollection)
        let palette = root.themeStore.activeThemeID.palette
        // No Message mic while a Live Voice call holds the microphone; read here, in the
        // observed pass, so the mic goes and comes back with the call.
        let showsDictation = SessionInboxComposeChrome.showsDictationShortcut(hasActivePlayback: state.hasActivePlayback)
            && !root.liveVoiceCalls.ownsMicrophone
        let player = state.connection?.audioPlayer

        if !joinsRail {
            bottomBar.update(
                showsDictation: showsDictation,
                hasActivePlayback: state.hasActivePlayback,
                toolbar: state.toolbar,
                player: player,
                columnWidth: columnWidth
            )
        }
        if let server = state.selectedServer {
            let model = HostSwitcherModel(
                coordinator: coordinator,
                serverStore: coordinator.serverStore,
                navigation: navigation,
                current: server,
                destination: .inbox
            ) { [weak self] _ in self?.switchVisibleServer() }
            if let switcher, switcher.joinsRail == joinsRail {
                switcher.update(model)
            } else {
                switcher = SessionListServerSwitcher(model: model, joinsRail: joinsRail)
            }
            if switcherServerId != server.id {
                switcherServerId = server.id
                // Once per connection: a known value is never refetched.
                Task { await model.loadServerMetricsEnabled() }
            }
        }

        let bars = BarState(
            joinsRail: joinsRail,
            showsSidebarOpen: onOpenSidebar != nil,
            showsSidebarToggle: showsSidebarToggle,
            hasServer: state.selectedServer != nil,
            showsNowPlaying: state.toolbar.showsNowPlayingPill && player != nil,
            parksNowPlayingNextToCompose: state.toolbar.parksNowPlayingNextToCompose,
            canOpenFiles: SessionInboxComposeChrome.canOpenFiles(hasServer: state.activeServerId != nil),
            showsDictation: showsDictation,
            themeID: root.themeStore.activeThemeID
        )
        if bars != barState {
            barState = bars
            installBarItems(bars, palette: palette, showsDictation: showsDictation)
        }
        if let sidebarToggle {
            WorkspaceSplitSidebarToggle.sync(sidebarToggle, root: root)
        }
    }

    private func installBarItems(_ bars: BarState, palette: ThemePalette, showsDictation: Bool) {
        let tint = UIColor(palette.fg)
        let railTint = SessionListBarItems.railTint(palette)
        sidebarToggle = bars.showsSidebarToggle ? WorkspaceSplitSidebarToggle.makeItem(root: root) : nil
        var leading: [UIBarButtonItem] = sidebarToggle.map { [$0] } ?? []
        var trailing: [UIBarButtonItem] = []
        var pinned: [UIBarButtonItem] = []
        var bottom: [UIBarButtonItem] = []
        let openSidebar: () -> Void = { [weak self] in self?.onOpenSidebar?() }

        if bars.joinsRail {
            // Navigation, then Message, then the pinned server switcher. A
            // text principal would keep a horizontal bar, so the system title stays.
            navigationItem.titleView = nil
            if bars.showsSidebarOpen {
                trailing.append(SessionListBarItems.sidebarOpen(joinsRail: true, tint: railTint, action: openSidebar))
            }
            trailing.append(bottomBar.railCompose(showsDictation: showsDictation, tint: railTint))
            if bars.hasServer, let switcher {
                pinned.append(SessionListBarItems.railItem(switcher.item, priority: .keep))
            }
            if bars.showsNowPlaying {
                trailing.append(bottomBar.railNowPlaying(tint: railTint))
            }
            // Bottom-anchored: spacers cannot push a rail item down.
            bottom.append(SessionListBarItems.files(
                isEnabled: bars.canOpenFiles,
                accessibilityLabel: String(localized: "Open server files"),
                railTitle: String(localized: "Files"),
                palette: palette
            ) { [weak self] in self?.openFiles() })
        } else {
            // The title leads, after the sidebar control. An empty title view
            // hides the centered system title but keeps `title` for Back.
            navigationItem.titleView = hiddenSystemTitle
            if bars.showsSidebarOpen {
                leading.append(SessionListBarItems.sidebarOpen(joinsRail: false, tint: tint, action: openSidebar))
            }
            if bars.hasServer, let switcher {
                trailing.append(switcher.item)
            }
            bottom = bottomBar.items(
                showsNowPlaying: bars.showsNowPlaying,
                parksNowPlayingNextToCompose: bars.parksNowPlayingNextToCompose,
                files: SessionListBarItems.files(
                    isEnabled: bars.canOpenFiles,
                    accessibilityLabel: String(localized: "Open server files"),
                    railTitle: nil,
                    palette: palette
                ) { [weak self] in self?.openFiles() }
            )
        }

        var leadingGroups = leading.isEmpty
            ? [] : [UIBarButtonItemGroup(barButtonItems: leading, representativeItem: nil)]
        if !bars.joinsRail {
            let titleItem = SessionListBarItems.horizontalOnly(UIBarButtonItem(customView: titleLabel))
            titleItem.hidesSharedBackground = true
            leadingGroups.append(UIBarButtonItemGroup(barButtonItems: [titleItem], representativeItem: nil))
        }
        navigationItem.leadingItemGroups = leadingGroups
        navigationItem.trailingItemGroups = trailing.isEmpty
            ? [] : [UIBarButtonItemGroup(barButtonItems: trailing, representativeItem: nil)]
        navigationItem.pinnedTrailingGroup = pinned.isEmpty
            ? nil : UIBarButtonItemGroup(barButtonItems: pinned, representativeItem: nil)
        setToolbarItems(bottom, animated: false)
        if navigationController?.topViewController === self {
            navigationController?.setToolbarHidden(bottom.isEmpty, animated: false)
        }
    }
}

// MARK: - Model

private extension SessionInboxViewController {
    struct InboxItem {
        let serverId: String
        let connection: ServerConnection
        let session: Session
        let workspace: Workspace?
    }

    struct PendingDelete {
        let serverId: String
        let routeScope: SessionRouteScope
        let session: Session
    }

    struct ViewData {
        let yourTurn: [SessionListEntry]
        let working: [SessionListEntry]
        let stoppedGroups: [SessionInboxStoppedDayGroup<SessionListEntry>]
        let searchMatches: [SessionListEntry]
        /// Inbox items by session id, for row context and routing.
        let itemsById: [String: InboxItem]
        let isSearching: Bool
        let isEmpty: Bool
    }

    struct InboxState {
        let activeServerId: String?
        let connection: ServerConnection?
        let selectedServer: PairedServer?
        let search: SessionListSearchNavigationPersistence.State
        let hasSearchQuery: Bool
        let hasActivePlayback: Bool
        let toolbar: InAppNowPlayingChrome.SessionListToolbar
        let showsVersionNotice: Bool
        let showsProviderPrompt: Bool
        let showsPushDiscovery: Bool
        let refreshFailed: Bool
        let transportUnavailable: Bool
        let isSyncing: Bool
    }

    struct Observed: Equatable {
        var searchText: String
        var isSearchPresented: Bool
        var coverage: String
        var activeServerId: String?
        var stackCount: Int
        var splitPathCount: Int
    }

    enum Section: Hashable {
        case prompt
        case pushDiscovery
        case cachedWarning
        case status
        case results
        case yourTurn
        case working
        case stopped(String)
        case empty
    }

    /// Session rows by session id; one fixed id per state row. A stopped row
    /// has its own id, so a session that stops leaves Working and arrives in
    /// its day group instead of moving between them.
    enum Item: Hashable {
        case prompt
        case pushDiscovery
        case cachedWarning
        case searching
        case noMatches
        case empty
        case session(String)
        case stoppedSession(String)
    }

    /// A row that is not a session.
    enum Row: Equatable {
        case serverVersion(serverId: String)
        case providerSetup(serverId: String, serverName: String)
        case pushDiscovery(serverId: String, status: PushDiscoveryCardConfiguration.Status)
        case cachedWarning(serverName: String)
        case searching
        case noMatches(query: String)
        case empty(EmptyState)
    }

    enum EmptyState: Equatable {
        case noServers
        case loading(serverName: String)
        case unavailable(serverName: String, afterRetry: Bool)
        case noActiveSessions(serverName: String)
    }

    /// An expandable stopped-day group's toggle.
    struct StoppedDay: Equatable {
        let groupID: String
        let day: Date
    }

    struct BarState: Equatable {
        let joinsRail: Bool
        let showsSidebarOpen: Bool
        let showsSidebarToggle: Bool
        let hasServer: Bool
        let showsNowPlaying: Bool
        let parksNowPlayingNextToCompose: Bool
        let canOpenFiles: Bool
        /// The rail's Message item offers Dictate only with the mic.
        let showsDictation: Bool
        let themeID: ThemeID
    }
}

enum SessionInboxTransportAvailability {
    static func isUnavailable(hasAPIClient: Bool, isPreparing: Bool) -> Bool {
        !hasAPIClient && !isPreparing
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
        session.routeScope
    }

    static func allSessionsContext(for session: Session, workspaceName: String?) -> String? {
        if session.isControlConversation { return "Oppi Control" }
        return SessionRowPresentationBuilder.allSessionsWorkspaceContext(
            for: session,
            workspaceName: workspaceName
        )
    }
}
