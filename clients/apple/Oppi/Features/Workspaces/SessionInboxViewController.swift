import UIKit

/// All Sessions: the active server's sessions, the compact stack's root and
/// the split detail root when nothing is selected.
///
/// The workspace sidebar owns project selection. This screen keeps the main
/// content focused on session rows and uses small row context instead of a
/// workspace header card. It reads the app's stores in `updateProperties()`,
/// builds a value per row, and applies a diffable snapshot keyed by session
/// id; only rows whose values changed reconfigure. Rows are SwiftUI
/// (`SessionListEntryRow`) hosted per cell; taps, swipes, and the long-press
/// menu belong to the collection view.
final class SessionInboxViewController: UIViewController, UICollectionViewDelegate {
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

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private let search = ScreenSearchController(prompt: String(localized: "Search sessions"))
    private let searchStore = SessionSearchStore()
    private let refreshControl = UIRefreshControl()
    private let leadingDragGuard = SessionListLeadingDragGuard()
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
    private var hasAutoOpenedE2EWorkspace = false
    private var hasAutoOpenedE2ESession = false
    private var hasAutoOpenedRemoteScreen = false
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

    // Snapshot values by item and section.
    private var rows: [Item: SessionListRowContent] = [:]
    private var stateRows: [Item: StateRow] = [:]
    private var headers: [Section: Header] = [:]
    private var itemsById: [String: InboxItem] = [:]
    private var lastThemeID: ThemeID?
    private var hasAppliedSnapshot = false

    // Bars.
    private var barState: BarState?
    private var composeHost: HostedContentController?
    private var composeParams: ComposeParams?
    private var pillHost: HostedContentController?
    private var pillParams: PillParams?
    private var switcherHost: HostedContentController?
    private var switcherParams: SwitcherParams?
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
            Task { await self.stop(item) }
        },
        resume: { [weak self] session in
            guard let self, let item = item(for: session) else { return }
            Task { await self.resume(item) }
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
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
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
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        collectionView.accessibilityIdentifier = "workspace.sessionList"
        collectionView.refreshControl = refreshControl
        // Pull-to-refresh needs the bounce even when the rows fit on screen.
        collectionView.alwaysBounceVertical = true
        leadingDragGuard.install(on: collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        refreshControl.addAction(UIAction { [weak self] _ in self?.pullToRefresh() }, for: .valueChanged)

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
        search.onTextChange = { [weak self] text in
            guard let self else { return }
            var next = navigation.inboxSessionSearch
            guard next.searchText != text else { return }
            next.searchText = text
            navigation.inboxSessionSearch = next
        }
        search.onPresentationChange = { [weak self] presented in
            guard let self else { return }
            var next = navigation.inboxSessionSearch
            guard next.isSearchPresented != presented else { return }
            next.isSearchPresented = presented
            navigation.inboxSessionSearch = next
        }

        installDataSource()
        if #available(iOS 27.1, *) {
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (screen: Self, _) in
                screen.setNeedsUpdateProperties()
            }
        }
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
        columnWidth = view.bounds.width
    }

    override func updateProperties() {
        super.updateProperties()
        let themeStore = root.themeStore
        overrideUserInterfaceStyle = themeStore.userInterfaceStyle
        guard isOnScreen, dataSource != nil else { return }

        reactToChanges()

        let themeID = themeStore.activeThemeID
        let themeChanged = lastThemeID != themeID
        if themeChanged {
            lastThemeID = themeID
            view.backgroundColor = themeStore.backgroundColor
            collectionView.backgroundColor = themeStore.backgroundColor
            titleLabel.textColor = UIColor(themeID.palette.fg)
        }

        let state = readState()
        let searchState = state.search
        search.searchController.hidesNavigationBarDuringPresentation = !state.toolbar.avoidsHidingContentWhileSearching
        search.setText(searchState.searchText)
        search.setPresented(searchState.isSearchPresented)

        applySnapshot(state, reconfigureAll: themeChanged)
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
        if let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: items.map(\.session),
            query: state.search.searchText,
            extraCandidates: { session in
                [itemsById[session.id]?.workspace?.name]
            },
            serverResults: searchStore.results
                // A content match would say what a locked session contains;
                // locked sessions match by name only.
                .filter { result in
                    guard let session = result.session, let serverId = state.activeServerId else { return true }
                    return !ScopedLockService.shared.isLocked(.session(session, serverId: serverId))
                },
            completedServerQuery: searchStore.completedServerQuery,
            activeServerQuery: searchStore.activeServerQuery,
            snippetsBySessionId: searchStore.snippetsBySessionId
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
        let attention = { (session: Session) in Self.attentionCounts(for: session, connection: connection) }
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

    private static func attentionCounts(for session: Session, connection: ServerConnection?) -> SessionListAttentionCounts {
        SessionRowPresentationBuilder.attentionCounts(
            sessionId: session.id,
            pendingAskCountForSession: { pendingAskCount(for: $0, connection: connection) }
        )
    }

    /// All Sessions shows one server, so every row reads the active connection.
    private static func pendingAskCount(for sessionId: String, connection: ServerConnection?) -> Int {
        guard let connection else { return 0 }
        return SessionListAttentionMerger.askCount(
            listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
            hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
            hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
        )
    }

    private func rowContent(for entry: SessionListEntry, data: ViewData, state: InboxState) -> SessionListRowContent {
        var statuses: [String: SessionStatusKind] = [:]
        for session in SessionListRowContent.drawnSessions(of: entry) {
            statuses[session.id] = SessionStatusKind.resolve(
                session: session,
                pendingAskCount: Self.pendingAskCount(for: session.id, connection: state.connection),
                seenAt: state.connection?.sessionStore.seenAt(for: session.id)
            )
        }
        let presentation: SessionRowPresentation
        if let item = data.itemsById[entry.session.id] ?? inboxItem(for: entry.session, state: state) {
            let attention = Self.attentionCounts(for: item.session, connection: state.connection)
            presentation = SessionRowPresentationBuilder.make(
                session: item.session,
                pendingAskCount: attention.askCount,
                pendingAsk: item.connection.askRequestStore.pending(for: item.session.id),
                workspaceContext: SessionInboxSessionRouting.allSessionsContext(
                    for: item.session,
                    workspaceName: item.workspace?.name
                ),
                seenAt: item.connection.sessionStore.seenAt(for: item.session.id),
                searchSnippet: searchStore.snippetsBySessionId[item.session.id],
                catalogModels: item.connection.chatState.cachedModels
            )
        } else {
            presentation = SessionRowPresentationBuilder.make(session: entry.session)
        }
        // Every All Sessions row already names its workspace.
        return SessionListRowContent(entry: entry, presentation: presentation, statuses: statuses)
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
            refreshControl.endRefreshing()
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

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.backgroundColor = .clear
            let section = self?.dataSource?.sectionIdentifier(for: index)
            configuration.headerMode = section?.hasHeader == true ? .supplementary : .none
            configuration.showsSeparators = section?.listsSessions == true
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipe(at: indexPath)
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func installDataSource() {
        let sessionCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, let row = rows[item] else { return }
            cell.contentConfiguration = SessionListEntryRow.cellConfiguration(row, actions: rowActions, root: root)
            cell.backgroundConfiguration = rowBackground()
            // No tap highlight, as the SwiftUI rows had none.
            cell.automaticallyUpdatesBackgroundConfiguration = false
        }
        let stateCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, let row = stateRows[item] else { return }
            configure(cell, row: row)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .session, .stoppedSession:
                collectionView.dequeueConfiguredReusableCell(using: sessionCell, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: stateCell, for: indexPath, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<SessionListSectionHeaderView>(
            elementKind: SessionListSectionHeaderView.elementKind
        ) { [weak self] view, _, indexPath in
            self?.configure(view, at: indexPath)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        self.dataSource = dataSource
    }

    private func applySnapshot(_ state: InboxState, reconfigureAll: Bool) {
        guard let dataSource else { return }
        let data = viewData(state)
        itemsById = data.itemsById

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        var nextRows: [Item: SessionListRowContent] = [:]
        var nextStates: [Item: StateRow] = [:]
        var nextHeaders: [Section: Header] = [:]

        func appendState(_ row: StateRow, item: Item, section: Section) {
            snapshot.appendSections([section])
            snapshot.appendItems([item], toSection: section)
            nextStates[item] = row
        }
        func appendSessions(_ entries: [SessionListEntry], section: Section, item: (String) -> Item) {
            snapshot.appendSections([section])
            var items: [Item] = []
            items.reserveCapacity(entries.count)
            for entry in entries {
                let id = item(entry.id)
                // A diffable snapshot traps on a repeated item.
                guard nextRows[id] == nil else { continue }
                nextRows[id] = rowContent(for: entry, data: data, state: state)
                items.append(id)
            }
            snapshot.appendItems(items, toSection: section)
        }

        if state.showsVersionNotice, let server = state.selectedServer {
            appendState(.serverVersion(serverId: server.id), item: .prompt, section: .prompt)
        } else if state.showsProviderPrompt, let server = state.selectedServer {
            appendState(.providerSetup(serverId: server.id, serverName: server.name), item: .prompt, section: .prompt)
        }

        if state.refreshFailed, !data.isEmpty, let server = state.selectedServer {
            appendState(.cachedWarning(serverName: server.name), item: .cachedWarning, section: .cachedWarning)
        }

        if state.hasSearchQuery {
            if data.isSearching && data.searchMatches.isEmpty {
                appendState(.searching, item: .searching, section: .status)
            } else if data.searchMatches.isEmpty {
                let query = state.search.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                appendState(.noMatches(query: query), item: .noMatches, section: .status)
            } else {
                nextHeaders[.results] = Header(title: String(localized: "Results"), stoppedDay: nil)
                appendSessions(data.searchMatches, section: .results, item: Item.session)
            }
        } else {
            if !data.yourTurn.isEmpty {
                nextHeaders[.yourTurn] = Header(title: SessionInboxSectionTitle.yourTurn, stoppedDay: nil)
                appendSessions(data.yourTurn, section: .yourTurn, item: Item.session)
            }
            if !data.working.isEmpty {
                nextHeaders[.working] = Header(title: SessionInboxSectionTitle.working, stoppedDay: nil)
                appendSessions(data.working, section: .working, item: Item.session)
            }
            let now = Date()
            for group in data.stoppedGroups {
                let section = Section.stopped(group.id)
                let isExpanded = isStoppedDayExpanded(group.id, day: group.day)
                nextHeaders[section] = Header(
                    title: SessionInboxSectionTitle.stopped(day: group.day, now: now, calendar: Calendar.current),
                    stoppedDay: StoppedDay(groupID: group.id, day: group.day, isExpanded: isExpanded)
                )
                appendSessions(isExpanded ? group.items : [], section: section, item: Item.stoppedSession)
            }
            if ProviderSetupPromptPolicy.shouldShowInboxEmptyState(
                isEmpty: data.isEmpty,
                showsProviderSetup: state.showsProviderPrompt || state.showsVersionNotice
            ) {
                appendState(.empty(emptyState(state)), item: .empty, section: .empty)
            }
        }

        let current = Set(dataSource.snapshot().itemIdentifiers)
        let changed = snapshot.itemIdentifiers.filter { item in
            guard current.contains(item) else { return false }
            if reconfigureAll { return true }
            if let row = nextRows[item] { return rows[item] != row }
            return stateRows[item] != nextStates[item]
        }
        let headersChanged = reconfigureAll || headers != nextHeaders
        rows = nextRows
        stateRows = nextStates
        headers = nextHeaders
        snapshot.reconfigureItems(changed)

        let animated = hasAppliedSnapshot && view.window != nil
        hasAppliedSnapshot = true
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            if headersChanged { self?.refreshVisibleHeaders() }
        }
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

    private func rowBackground() -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = root.themeStore.backgroundColor
        return background
    }

    private func configure(_ cell: UICollectionViewListCell, row: StateRow) {
        let palette = root.themeStore.activeThemeID.palette
        cell.accessibilityIdentifier = nil
        cell.backgroundConfiguration = rowBackground()
        cell.automaticallyUpdatesBackgroundConfiguration = false
        switch row {
        case .serverVersion(let serverId):
            cell.backgroundConfiguration = .clear()
            cell.contentConfiguration = ProviderSetupPromptListRow.serverVersion(root: root) { [weak self] in
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
            var content = UIContentUnavailableConfiguration.loading()
            content.text = String(localized: "Searching sessions…")
            cell.contentConfiguration = content
        case .noMatches(let query):
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: "magnifyingglass")
            content.text = String(localized: "No Matching Sessions")
            content.secondaryText = String(localized: "No sessions match “\(query)”.")
            cell.contentConfiguration = content
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

    private func configure(_ view: SessionListSectionHeaderView, at indexPath: IndexPath) {
        guard let section = dataSource?.sectionIdentifier(for: indexPath.section),
              let header = headers[section] else { return }
        let palette = root.themeStore.activeThemeID.palette
        guard let stopped = header.stoppedDay else {
            view.configure(title: header.title, palette: palette)
            return
        }
        view.configure(
            title: header.title,
            isExpanded: stopped.isExpanded,
            accessibilityIdentifier: "workspace.sessionList.\(stopped.groupID)",
            palette: palette
        ) { [weak self] in
            self?.toggleStoppedDayExpansion(stopped.groupID, day: stopped.day)
        }
    }

    private func refreshVisibleHeaders() {
        let kind = SessionListSectionHeaderView.elementKind
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                as? SessionListSectionHeaderView else { continue }
            configure(view, at: indexPath)
        }
    }

    private func session(at indexPath: IndexPath) -> Session? {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        return rows[item]?.entry.session
    }

    private func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let session = session(at: indexPath) else { return nil }
        return SessionListRowMenus.trailingSwipe(
            for: session,
            actions: rowActions,
            palette: root.themeStore.activeThemeID.palette
        )
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        session(at: indexPath) != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let session = session(at: indexPath) else { return }
        rowActions.open(session)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let session = session(at: indexPath) else {
            return nil
        }
        return SessionListRowMenus.contextMenu(for: session, actions: rowActions)
    }

    // MARK: Actions

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

    private func stop(_ item: InboxItem) async {
        guard let api = item.connection.apiClient,
              let routeScope = SessionInboxSessionRouting.routeScope(for: item.session) else { return }
        do {
            let updated = try await api.stopSession(scope: routeScope, sessionId: item.session.id)
            item.connection.sessionStore.upsert(updated)
        } catch {
            showError("Stop failed: \(error.localizedDescription)")
        }
    }

    private func resume(_ item: InboxItem) async {
        guard let api = item.connection.apiClient,
              let routeScope = SessionInboxSessionRouting.routeScope(for: item.session) else { return }
        do {
            let updated = try await api.resumeSession(scope: routeScope, sessionId: item.session.id)
            item.connection.sessionStore.upsert(updated)
        } catch {
            showError("Resume failed: \(error.localizedDescription)")
        }
    }

    private func confirmDelete(_ pending: PendingDelete) {
        let sourceView = cell(for: pending.session.id)
        SessionListAlerts.confirmDelete(pending.session, from: self, sourceView: sourceView) { [weak self] in
            Task { await self?.delete(pending) }
        }
    }

    private func cell(for sessionId: String) -> UIView? {
        for item in [Item.session(sessionId), .stoppedSession(sessionId)] {
            if let indexPath = dataSource?.indexPath(for: item), let cell = collectionView.cellForItem(at: indexPath) {
                return cell
            }
        }
        return nil
    }

    private func delete(_ pending: PendingDelete) async {
        guard let connection = coordinator.connection(for: pending.serverId),
              let api = connection.apiClient else { return }
        connection.sessionStore.remove(id: pending.session.id)
        await TimelineCache.shared.removeTrace(pending.session.id, serverId: pending.serverId)
        do {
            try await api.deleteSession(scope: pending.routeScope, sessionId: pending.session.id)
            forgetDeleted(pending)
        } catch let apiError as APIError {
            if case .server(let status, _) = apiError, status == 404 {
                forgetDeleted(pending)
            } else {
                showError("Delete failed: \(apiError.localizedDescription)")
            }
        } catch {
            showError("Delete failed: \(error.localizedDescription)")
        }
    }

    /// Only after the server no longer has the session; a failed delete
    /// brings it back on the next sync, still locked.
    private func forgetDeleted(_ pending: PendingDelete) {
        ScopedLockService.shared.forgetSession(serverId: pending.serverId, sessionId: pending.session.id)
        root.composerDraftStore.clearDraft(
            serverID: pending.serverId,
            workspaceID: pending.routeScope.composerDraftScopeID,
            sessionID: pending.session.id
        )
    }

    private func showError(_ message: String) {
        pendingError = message
        presentPendingError()
    }

    private func presentPendingError() {
        guard isOnScreen, viewIfLoaded?.window != nil, let message = pendingError else { return }
        guard presentedViewController == nil || presentedViewController is SessionListErrorAlert else { return }
        pendingError = nil
        SessionListAlerts.presentError(message, from: self)
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
        autoOpenRemoteScreenIfRequested()
    }

    private func autoOpenRemoteScreenIfRequested() {
        let connection = coordinator.activeServerId.flatMap { coordinator.connection(for: $0) }
        guard !hasAutoOpenedRemoteScreen,
              ProcessInfo.processInfo.environment["OPPI_E2E_OPEN_REMOTE_SCREEN"] == "1",
              navigation.workspaceStackRouteElements.isEmpty,
              WorkspaceUtilityNavTarget.desktopStill.isReleaseEnabled,
              ReleaseFeatures.desktopStillEnabled || connection?.desktopLiveViewAvailable == true
        else { return }
        hasAutoOpenedRemoteScreen = true
        navigation.openWorkspaceUtility(.desktopStill)
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
        let showsDictation = SessionInboxComposeChrome.showsDictationShortcut(hasActivePlayback: state.hasActivePlayback)
        let player = state.connection?.audioPlayer

        if !joinsRail {
            let params = ComposeParams(
                showsDictation: showsDictation,
                hasActivePlayback: state.hasActivePlayback,
                columnWidth: columnWidth
            )
            if composeParams != params || composeHost == nil {
                composeParams = params
                composeHost = SessionListHostedChrome.composeCapsule(
                    updating: composeHost,
                    root: root,
                    showsDictation: showsDictation,
                    hasActivePlayback: state.hasActivePlayback,
                    columnWidth: columnWidth,
                    onStart: { [weak self] in self?.startQuickSession(dictate: false) },
                    onDictate: { [weak self] in self?.startQuickSession(dictate: true) }
                )
            }
        }
        if !joinsRail, state.toolbar.showsNowPlayingPill, let player {
            let params = PillParams(player: ObjectIdentifier(player), density: state.toolbar.pillDensity)
            if pillParams != params || pillHost == nil {
                pillParams = params
                pillHost = SessionListHostedChrome.nowPlayingPill(
                    updating: pillHost,
                    root: root,
                    audioPlayer: player,
                    density: state.toolbar.pillDensity
                ) { [weak self] in self?.openNowPlaying() }
            }
        }
        if let server = state.selectedServer {
            let params = SwitcherParams(server: server, fitsVerticalRail: joinsRail)
            if switcherParams != params || switcherHost == nil {
                switcherParams = params
                switcherHost = SessionListHostedChrome.serverSwitcher(
                    updating: switcherHost,
                    root: root,
                    current: server,
                    fitsVerticalRail: joinsRail
                ) { [weak self] _ in self?.switchVisibleServer() }
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
            trailing.append(SessionListBarItems.railCompose(
                showsDictation: showsDictation,
                tint: railTint,
                onStart: { [weak self] in self?.startQuickSession(dictate: false) },
                onDictate: { [weak self] in self?.startQuickSession(dictate: true) }
            ))
            if bars.hasServer, let switcherHost {
                pinned.append(SessionListBarItems.railItem(SessionListBarItems.hosted(switcherHost), priority: .keep))
            }
            if bars.showsNowPlaying {
                trailing.append(SessionListBarItems.railNowPlaying(tint: railTint) { [weak self] in self?.openNowPlaying() })
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
            if bars.hasServer, let switcherHost {
                trailing.append(SessionListBarItems.hosted(switcherHost))
            }
            if let composeHost {
                bottom.append(SessionListBarItems.hosted(composeHost))
            }
            if bars.showsNowPlaying, let pillHost {
                bottom.append(bars.parksNowPlayingNextToCompose ? .fixedSpace() : .flexibleSpace())
                bottom.append(SessionListBarItems.hosted(pillHost))
            }
            bottom.append(.flexibleSpace())
            bottom.append(SessionListBarItems.files(
                isEnabled: bars.canOpenFiles,
                accessibilityLabel: String(localized: "Open server files"),
                railTitle: nil,
                palette: palette
            ) { [weak self] in self?.openFiles() })
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
        case cachedWarning
        case status
        case results
        case yourTurn
        case working
        case stopped(String)
        case empty

        var hasHeader: Bool {
            switch self {
            case .results, .yourTurn, .working, .stopped: true
            case .prompt, .cachedWarning, .status, .empty: false
            }
        }

        var listsSessions: Bool { hasHeader }
    }

    /// Session rows by session id; one fixed id per state row. A stopped row
    /// has its own id, so a session that stops leaves Working and arrives in
    /// its day group instead of moving between them.
    enum Item: Hashable {
        case prompt
        case cachedWarning
        case searching
        case noMatches
        case empty
        case session(String)
        case stoppedSession(String)
    }

    enum StateRow: Equatable {
        case serverVersion(serverId: String)
        case providerSetup(serverId: String, serverName: String)
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

    struct StoppedDay: Equatable {
        let groupID: String
        let day: Date
        let isExpanded: Bool
    }

    struct Header: Equatable {
        let title: String
        /// Set for an expandable stopped-day group.
        let stoppedDay: StoppedDay?
    }

    struct BarState: Equatable {
        let joinsRail: Bool
        let showsSidebarOpen: Bool
        let showsSidebarToggle: Bool
        let hasServer: Bool
        let showsNowPlaying: Bool
        let parksNowPlayingNextToCompose: Bool
        let canOpenFiles: Bool
        let themeID: ThemeID
    }

    struct ComposeParams: Equatable {
        let showsDictation: Bool
        let hasActivePlayback: Bool
        let columnWidth: CGFloat
    }

    struct PillParams: Equatable {
        let player: ObjectIdentifier
        let density: InAppNowPlayingChrome.PillDensity
    }

    struct SwitcherParams: Equatable {
        let server: PairedServer
        let fitsVerticalRail: Bool
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
