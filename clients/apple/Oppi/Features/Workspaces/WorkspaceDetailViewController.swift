import UIKit

/// Whether a failed workspace refresh interrupts with an alert.
enum WorkspaceDetailLoadErrorPolicy {
    static func shouldPresent(
        error: any Error,
        workspaceId: String,
        hadVisibleData: Bool,
        knownWorkspaceIds: Set<String>
    ) -> Bool {
        guard !hadVisibleData else { return false }

        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }

        if let apiError = error as? APIError,
           case .server(let status, let message) = apiError,
           status == 404,
           message.localizedCaseInsensitiveContains("Workspace not found"),
           knownWorkspaceIds.contains(workspaceId) {
            return false
        }

        return true
    }
}

/// One workspace's sessions (route `.workspace`), on the workspace's server.
///
/// The screen is gated: while the workspace is locked it shows the lock cover
/// and keeps nothing of the workspace mounted (bars, search, tasks, state);
/// unlocked, it switches to the workspace's server and shows "Connecting…"
/// until that server is ready, then lists the sessions of the selected
/// worktree through that server's connection. It reads the stores in
/// `updateProperties()`, builds a value per row, and applies a diffable
/// snapshot keyed by session id; only rows whose values changed reconfigure.
/// Session and local-session rows are SwiftUI hosted per cell; taps, swipes,
/// and the long-press menu belong to the collection view.
///
/// The shell keeps one screen per server and workspace id; a refreshed
/// `Workspace` value for it arrives through `update(workspace:)`.
final class WorkspaceDetailViewController: UIViewController, UICollectionViewDelegate {
    /// The split detail root carries the sidebar toggle.
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    private let root: AppRootEnvironment
    private let serverId: String
    private let workspaceId: String
    /// The route's value; the server's store has the latest one.
    private var routeWorkspace: Workspace
    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var navigation: AppNavigation { root.navigation }
    private var lockTarget: ScopedLockTarget { .workspace(serverId: serverId, workspaceId: workspaceId) }

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private let search = ScreenSearchController(prompt: String(localized: "Search sessions"))
    private let refreshControl = UIRefreshControl()
    private let leadingDragGuard = SessionListLeadingDragGuard()
    private let titleButton = WorkspaceTitleButton()
    private let scrim = UIView()
    private let progressPanel = WorkspaceDetailProgressPanel()

    // Gate and server scope.
    private var phase: Phase?
    private var lockCover: ScopedLockCoverViewController?
    /// The workspace server's connection once it is ready. Dropped with the
    /// content when the workspace locks; unlocking connects again.
    private var connection: ServerConnection? {
        didSet { setNeedsUpdateProperties() }
    }
    private var connectTask: Task<Void, Never>?

    // Content state, fresh each time the content mounts (after an unlock).
    private var state = ContentState() {
        didSet {
            if oldValue.isRefreshingWorkspaceData, !state.isRefreshingWorkspaceData {
                scheduleWorkspaceLoadCompletionCheck()
            }
            setNeedsUpdateProperties()
        }
    }
    private var searchStore = SessionSearchStore()
    private var pendingError: String?
    private var columnWidth: CGFloat = 0 {
        didSet { if columnWidth != oldValue { setNeedsUpdateProperties() } }
    }

    /// Between `viewIsAppearing` and `viewDidDisappear`. A covered screen
    /// neither renders nor reacts, the way a hosted SwiftUI screen stops.
    private var isOnScreen = false
    private var hasAppeared = false
    private var isWaitingToAllowSearchHiding = false
    /// The content's appearance work ran and its tasks run (SwiftUI
    /// `onAppear` and `.task`); ends when the screen leaves or locks.
    private var contentIsLive = false
    private var workspaceTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var pollingKey: String?
    /// Values whose changes this screen reacts to; nil until the content shows.
    private var observed: Observed?

    // Snapshot values by item and section.
    private var rows: [Item: SessionListRowContent] = [:]
    private var localRows: [Item: LocalRow] = [:]
    private var stateRows: [Item: StateRow] = [:]
    private var headers: [Section: Header] = [:]
    private var lastThemeID: ThemeID?
    private var hasAppliedSnapshot = false

    // Overlays and bars.
    private var contextBar: WorkspaceContextBarView?
    private var contextBarHeight: CGFloat = 0
    private var barState: BarState?
    private var titleState: TitleState?
    private var composeHost: HostedContentController?
    private var composeParams: ComposeParams?
    private var pillHost: HostedContentController?
    private var pillParams: PillParams?
    private var sidebarToggle: UIBarButtonItem?

    private lazy var rowActions = SessionListRowActions(
        open: { [weak self] session in self?.openSession(session) },
        openThread: { [weak self] rootSession in self?.openThread(rootSession) },
        stop: { [weak self] session in
            Task { await self?.stopSession(session) }
        },
        resume: { [weak self] session in
            Task { await self?.resumeSession(session) }
        },
        delete: { [weak self] session in
            { [weak self] in self?.confirmDelete(session) }
        },
        lockTarget: { [serverId] session in .session(session, serverId: serverId) }
    )

    init(root: AppRootEnvironment, target: WorkspaceNavTarget, showsSidebarToggle: Bool = false) {
        self.root = root
        serverId = target.serverId
        workspaceId = target.workspace.id
        routeWorkspace = target.workspace
        self.showsSidebarToggle = showsSidebarToggle
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
        // Pushed screens show a bare chevron (the shell's `.minimal` Back)
        // that speaks the workspace's name, as the hosted screen's did.
        navigationItem.backBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        connectTask?.cancel()
        workspaceTask?.cancel()
        pollingTask?.cancel()
    }

    /// A refreshed value of the same workspace (the shell keys this screen by
    /// server and workspace id).
    func update(workspace: Workspace) {
        guard workspace.id == workspaceId, workspace != routeWorkspace else { return }
        routeWorkspace = workspace
        setNeedsUpdateProperties()
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
        refreshControl.addAction(UIAction { [weak self] _ in self?.pullToRefresh() }, for: .valueChanged)

        scrim.isHidden = true
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))
        progressPanel.isHidden = true

        for subview in [collectionView, scrim] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        progressPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressPanel)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: safe.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            progressPanel.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            progressPanel.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            progressPanel.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -32),
        ])

        search.onTextChange = { [weak self] text in
            guard let self else { return }
            var next = searchNavigation
            guard next.searchText != text else { return }
            next.searchText = text
            searchNavigation = next
        }
        search.onPresentationChange = { [weak self] presented in
            guard let self else { return }
            var next = searchNavigation
            guard next.isSearchPresented != presented else { return }
            next.isSearchPresented = presented
            searchNavigation = next
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
        // The server switch runs again each time the unlocked screen shows,
        // as the hosted gate's `.task(id:)` did.
        if !ScopedLockService.shared.isLocked(lockTarget) {
            startConnectTask()
        }
        setNeedsUpdateProperties()
        updatePropertiesIfNeeded()
        navigationController?.setToolbarHidden(toolbarItems?.isEmpty ?? true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        allowSearchToHide()
        // A search asked for while covered starts on return.
        if phase == .content {
            search.setPresented(searchNavigation.isSearchPresented)
        }
        presentPendingError()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        recordCoverageBeforeGoingQuiet()
        isOnScreen = false
        hasAppeared = false
        isWaitingToAllowSearchHiding = false
        connectTask?.cancel()
        connectTask = nil
        endContent()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The bottom bar lays out inside the safe area. Landscape insets are
        // wider than the Message capsule's reserve leaves room for, so sizing
        // from the full width pushed the capsule into the bar's overflow menu.
        columnWidth = view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
        if isWaitingToAllowSearchHiding {
            allowSearchToHide()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        let themeStore = root.themeStore
        overrideUserInterfaceStyle = themeStore.userInterfaceStyle
        guard isOnScreen, dataSource != nil else { return }

        let themeID = themeStore.activeThemeID
        let themeChanged = lastThemeID != themeID
        if themeChanged {
            lastThemeID = themeID
            applyTheme(themeID.palette)
        }

        if ScopedLockService.shared.isLocked(lockTarget) {
            show(.locked)
            lockCover?.coverTitle = routeWorkspace.name
            return
        }
        guard let connection else {
            show(.connecting)
            startConnectTask()
            return
        }
        show(.content)
        if !contentIsLive {
            beginContent(connection)
        }

        reactToChanges(connection)
        let detail = readState(connection)
        search.searchController.hidesNavigationBarDuringPresentation = !detail.toolbar.avoidsHidingContentWhileSearching
        search.setText(detail.search.searchText)
        search.setPresented(detail.search.isSearchPresented)

        applySnapshot(detail, reconfigureAll: themeChanged)
        syncOverlays(detail)
        syncBars(detail)
    }

    private func applyTheme(_ palette: ThemePalette) {
        let background = UIColor(palette.bg)
        view.backgroundColor = background
        collectionView.backgroundColor = background
        scrim.backgroundColor = background.withAlphaComponent(0.5)
        progressPanel.apply(palette)
    }

    // MARK: Gate

    /// Locked: the cover alone. Connecting: "Connecting…". Content: the list,
    /// its bars, and its search.
    private func show(_ next: Phase) {
        guard phase != next else { return }
        let previous = phase
        phase = next

        if previous == .content {
            tearDownContent()
        }
        if next != .locked, let lockCover {
            lockCover.willMove(toParent: nil)
            lockCover.view.removeFromSuperview()
            lockCover.removeFromParent()
            self.lockCover = nil
        }
        if next == .locked {
            // The content goes with the lock; unlocking connects again.
            connectTask?.cancel()
            connectTask = nil
            connection = nil
            let cover = ScopedLockCoverViewController(target: lockTarget, title: routeWorkspace.name)
            addChild(cover)
            cover.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cover.view)
            NSLayoutConstraint.activate([
                cover.view.topAnchor.constraint(equalTo: view.topAnchor),
                cover.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                cover.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                cover.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            cover.didMove(toParent: self)
            lockCover = cover
        }

        if next == .connecting {
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = String(localized: "Connecting…")
            loading.background.backgroundColor = root.themeStore.backgroundColor
            contentUnavailableConfiguration = loading
        } else {
            contentUnavailableConfiguration = nil
        }

        collectionView.isHidden = next != .content
        if next == .content {
            search.install(on: self, alwaysVisible: false)
            if hasAppeared {
                allowSearchToHide()
            }
        }
    }

    /// The bar starts shown, then hides as the list scrolls. A bar that is
    /// still joining the navigation bar when it is told to hide comes in
    /// collapsed (the Duo rail attaches it a layout pass after the screen
    /// appears), so the hiding starts once the bar is on screen.
    private func allowSearchToHide() {
        guard navigationItem.searchController === search.searchController else {
            isWaitingToAllowSearchHiding = false
            return
        }
        guard search.searchController.searchBar.window != nil else {
            isWaitingToAllowSearchHiding = true
            return
        }
        isWaitingToAllowSearchHiding = false
        search.hostDidAppear(self)
    }

    /// Everything the content mounted: tasks, search, bars, overlays, and,
    /// like a torn-down SwiftUI view, its state.
    private func tearDownContent() {
        endContent()
        search.uninstall(from: self)
        state = ContentState()
        searchStore = SessionSearchStore()
        observed = nil
        pendingError = nil
        if let alert = presentedViewController as? SessionListErrorAlert {
            alert.dismiss(animated: false)
        }
        removeContextBar()
        scrim.isHidden = true
        progressPanel.isHidden = true
        navigationItem.title = nil
        navigationItem.titleView = nil
        navigationItem.leadingItemGroups = []
        navigationItem.trailingItemGroups = []
        navigationItem.backBarButtonItem?.accessibilityLabel = nil
        sidebarToggle = nil
        barState = nil
        titleState = nil
        composeHost = nil
        composeParams = nil
        pillHost = nil
        pillParams = nil
        setToolbarItems([], animated: false)
        if navigationController?.topViewController === self {
            navigationController?.setToolbarHidden(true, animated: false)
        }
        var empty = NSDiffableDataSourceSnapshot<Section, Item>()
        empty.deleteAllItems()
        dataSource?.apply(empty, animatingDifferences: false)
        rows = [:]
        localRows = [:]
        stateRows = [:]
        headers = [:]
        hasAppliedSnapshot = false
    }

    private func startConnectTask() {
        guard connectTask == nil, isOnScreen else { return }
        connectTask = Task { [weak self, serverId] in
            guard let self else { return }
            let ready = await coordinator.switchToServerReady(serverId)
            connectTask = nil
            guard ready, !Task.isCancelled, !ScopedLockService.shared.isLocked(lockTarget) else { return }
            connection = coordinator.connection(for: serverId)
            // Mount the content now rather than on the next update pass.
            updatePropertiesIfNeeded()
        }
    }

    // MARK: Content lifecycle

    /// SwiftUI `onAppear`, then `.task(id: workspace.id)` and the polling task.
    private func beginContent(_ connection: ServerConnection) {
        contentIsLive = true
        handleViewAppear(connection)
        workspaceTask?.cancel()
        workspaceTask = Task { [weak self] in
            guard let self else { return }
            await loadWorktrees()
            // Start git status immediately so the context bar does not wait for
            // the workspace session-list refresh.
            refreshGitStatusContextBar()
            await refreshWorkspaceData()
            guard !Task.isCancelled else { return }
            autoOpenE2ESessionIfRequested()
            await autoCreateE2ESessionIfRequested()
        }
        restartPolling()
    }

    /// SwiftUI `onDisappear`: the tasks stop and an open load measurement ends.
    private func endContent() {
        guard contentIsLive else { return }
        contentIsLive = false
        workspaceTask?.cancel()
        workspaceTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        pollingKey = nil
        state.workspaceLoad = nil
    }

    private var isNavigatingDeeperInWorkspaceStack: Bool {
        navigation.workspaceStackRouteElements.count > 1
    }

    private var currentPollingKey: String {
        "\(workspaceId):\(state.selectedWorktreeId):\(isNavigatingDeeperInWorkspaceStack ? "covered" : "visible")"
    }

    /// The polling task restarts when its key changes, like `.task(id:)`. A
    /// screen with a destination pushed over it does not poll.
    private func restartPolling() {
        pollingTask?.cancel()
        pollingKey = currentPollingKey
        guard !isNavigatingDeeperInWorkspaceStack else {
            pollingTask = nil
            return
        }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            beginWorkspaceLoadIfNeeded(path: state.hasPresentedWorkspaceOnce ? "return_from_chat" : "open")
            await refreshWorkspaceData()
            await runWorkspaceRefreshPolling()
        }
    }

    private func handleViewAppear(_ connection: ServerConnection) {
        let path = state.hasPresentedWorkspaceOnce ? "return_from_chat" : "open"
        beginWorkspaceLoadIfNeeded(path: path)
        state.hasPresentedWorkspaceOnce = true
        refreshGitStatusContextBar()
        if hasSessionSearchQuery {
            refreshSearch(connection)
        }
        if state.workspaceLoad?.hadImmediateContent == true {
            scheduleWorkspaceLoadCompletionCheck()
        }
    }

    // MARK: Reactions

    /// Side effects of state changes, in the order the SwiftUI screen
    /// declared them. They run before this pass reads state; a change they
    /// make runs another pass.
    private func reactToChanges(_ connection: ServerConnection) {
        let search = searchNavigation
        let current = Observed(
            searchText: search.searchText,
            isSearchPresented: search.isSearchPresented,
            stackCount: navigation.workspaceStackRouteElements.count,
            splitDetailTarget: navigation.splitDetailTarget,
            pollingKey: currentPollingKey
        )
        if contentIsLive, pollingKey != current.pollingKey {
            restartPolling()
        }
        guard let previous = observed else {
            observed = current
            return
        }
        guard previous != current else { return }
        observed = current
        if previous.searchText != current.searchText {
            applySearchNavigation(.searchTextChanged(current.searchText))
            refreshSearch(connection)
        }
        if previous.isSearchPresented != current.isSearchPresented {
            applySearchNavigation(.searchPresentationChanged(current.isSearchPresented))
        }
        if previous.stackCount != current.stackCount || previous.splitDetailTarget != current.splitDetailTarget {
            applySearchNavigation(.coverageChanged(isCovered: isSearchListCoveredByDestination))
        }
    }

    // MARK: Search state

    /// This workspace's search, kept in `AppNavigation` across pushes.
    private var searchNavigation: SessionListSearchNavigationPersistence.State {
        get { navigation.workspaceSessionSearchByID[workspaceId] ?? .init() }
        set {
            if newValue == .init() {
                navigation.workspaceSessionSearchByID.removeValue(forKey: workspaceId)
            } else {
                navigation.workspaceSessionSearchByID[workspaceId] = newValue
            }
        }
    }

    private var hasSessionSearchQuery: Bool {
        SessionListSearchPresentation.hasQuery(searchNavigation.searchText)
    }

    /// A covered screen stops reacting, and no update pass is guaranteed
    /// between the push and here (a non-animated push, a route restore). Take
    /// the covered state now so Back always sees covered then uncovered and
    /// presents the search again.
    private func recordCoverageBeforeGoingQuiet() {
        guard phase == .content, isSearchListCoveredByDestination else { return }
        applySearchNavigation(.coverageChanged(isCovered: true))
        observed?.stackCount = navigation.workspaceStackRouteElements.count
        observed?.splitDetailTarget = navigation.splitDetailTarget
    }

    private var isSearchListCoveredByDestination: Bool {
        SessionListSearchNavigationPersistence.isWorkspaceListCovered(
            stackDepth: navigation.workspaceStackRouteElements.count,
            splitDetailReplacesList: navigation.splitDetailTarget != nil
        )
    }

    private func applySearchNavigation(_ event: SessionListSearchNavigationPersistence.Event) {
        let next = SessionListSearchNavigationPersistence.reduce(
            searchNavigation,
            event: event,
            isCoveredByDestination: isSearchListCoveredByDestination
        )
        if next != searchNavigation {
            searchNavigation = next
        }
    }

    private func refreshSearch(_ connection: ServerConnection) {
        searchStore.search(
            query: searchNavigation.searchText,
            workspaceId: SessionInboxSearchScope.workspaceId(scopedTo: workspaceId),
            apiClient: connection.apiClient
        )
    }

    // MARK: State

    /// The current workspace from the server's store. The route carries a
    /// value copy, which goes stale after an edit (name, icon, host mount).
    private func currentWorkspace(_ connection: ServerConnection) -> Workspace {
        let store = connection.workspaceStore
        guard let activeServerId = store.activeServerId,
              let latest = store.workspacesByServer[activeServerId]?.first(where: { $0.id == workspaceId }) else {
            return routeWorkspace
        }
        return latest
    }

    /// The selected worktree's sessions, from the cold list projection:
    /// timeline-frequency events do not rebuild the sections.
    private func workspaceSessions(_ connection: ServerConnection) -> [Session] {
        connection.sessionStore.listProjectionSessions(workspaceId: workspaceId)
            .filter { ($0.worktreeId ?? WorkspaceWorktree.mainId) == state.selectedWorktreeId }
    }

    /// What the screen shows, read from the stores. Reads here are tracked,
    /// so a store change runs `updateProperties()` again.
    private func readState(_ connection: ServerConnection) -> DetailState {
        let search = searchNavigation
        let hasActivePlayback = connection.audioPlayer.hasActivePlayback
        return DetailState(
            connection: connection,
            workspace: currentWorkspace(connection),
            sessions: workspaceSessions(connection),
            search: search,
            hasSearchQuery: SessionListSearchPresentation.hasQuery(search.searchText),
            hasActivePlayback: hasActivePlayback,
            toolbar: InAppNowPlayingChrome.sessionListToolbar(
                hasActivePlayback: hasActivePlayback,
                isSearchPresented: search.isSearchPresented
            ),
            lockBadge: ScopedLockService.shared.badge(lockTarget),
            isNavigatingDeeper: isNavigatingDeeperInWorkspaceStack,
            isSplit: navigation.workspaceNavigationPresentation == .split,
            gitStatus: connection.gitStatusStore.gitStatus
        )
    }

    private func viewData(_ detail: DetailState) -> ViewData {
        let startNs = SessionListPerf.timestampNs()
        let sessions = detail.sessions
        let localFiltered = filteredLocalSessions(query: detail.search.searchText, hasQuery: detail.hasSearchQuery)

        if let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: sessions,
            query: detail.search.searchText,
            extraCandidates: { _ in [] },
            // A content match would say what a locked session contains;
            // locked sessions match by name only.
            serverResults: searchStore.results.filter { result in
                guard let session = result.session else { return true }
                return !ScopedLockService.shared.isLocked(.session(session, serverId: serverId))
            },
            completedServerQuery: searchStore.completedServerQuery,
            activeServerQuery: searchStore.activeServerQuery,
            snippetsBySessionId: searchStore.snippetsBySessionId
        ) {
            let searchMatches = matches.map(\.session)
            SessionListPerf.recordViewDataCompute(
                startNs: startNs,
                activeCount: searchMatches.count,
                stoppedCount: 0,
                workspaceId: workspaceId
            )
            return ViewData(
                yourTurn: [],
                working: [],
                stopped: [],
                localFiltered: localFiltered,
                searchMatches: SessionListEntries.flat(searchMatches),
                isEmpty: sessions.isEmpty && localFiltered.isEmpty && searchMatches.isEmpty
            )
        }

        // Same sections and order as All Sessions; stopped history keeps this list's day/month grouping.
        let attention = { (session: Session) in self.attentionCounts(for: session, connection: detail.connection) }
        let split = SessionInboxGrouping.split(
            items: entries(for: sessions, connection: detail.connection),
            session: \.representative,
            attention: { attention($0.session) },
            sectionKind: { $0.sectionKind(attention: attention) },
            isBlocked: { $0.isBlocked(attention: attention) }
        )
        SessionListPerf.recordViewDataCompute(
            startNs: startNs,
            activeCount: split.yourTurn.count + split.working.count,
            stoppedCount: split.stopped.count,
            workspaceId: workspaceId
        )
        return ViewData(
            yourTurn: split.yourTurn,
            working: split.working,
            stopped: split.stopped,
            localFiltered: localFiltered,
            searchMatches: [],
            isEmpty: sessions.isEmpty
        )
    }

    /// Importable local Pi sessions. The server owns cwd/host-mount alignment,
    /// so the client applies only the search filter.
    private func filteredLocalSessions(query: String, hasQuery: Bool) -> [LocalSession] {
        guard hasQuery else { return state.localSessions }
        let normalized = SessionListSearchPresentation.normalizedQuery(query)
        return state.localSessions.filter { FuzzyMatch.match(query: normalized, candidate: $0.displayTitle) != nil }
    }

    /// This list's sessions; threads only when the Session Threads experiment is on.
    /// Threads are built over every loaded session so a thread keeps members from
    /// other workspaces and worktrees; a session whose root is elsewhere links to it.
    private func entries(for listed: [Session], connection: ServerConnection) -> [SessionListEntry] {
        SessionListEntries.entries(
            threadsEnabled: navigation.sessionThreadsEnabled,
            listed: listed,
            loaded: connection.sessionStore.listProjectionSessions
        )
    }

    /// An older-history bucket threads (experiment on) only within itself, so a thread never
    /// claims recent sessions that already have their own rows above.
    private func archiveEntries(for bucket: WorkspaceSessionArchiveBucket) -> [SessionListEntry] {
        let sessions = state.archiveStoppedSessionsByBucketID[bucket.id] ?? []
        return SessionListEntries.entries(threadsEnabled: navigation.sessionThreadsEnabled, listed: sessions, loaded: sessions)
    }

    private func attentionCounts(for session: Session, connection: ServerConnection) -> SessionListAttentionCounts {
        SessionRowPresentationBuilder.attentionCounts(
            sessionId: session.id,
            pendingAskCountForSession: { Self.pendingAskCount(for: $0, connection: connection) }
        )
    }

    private static func pendingAskCount(for sessionId: String, connection: ServerConnection) -> Int {
        SessionListAttentionMerger.askCount(
            listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
            hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
            hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
        )
    }

    private func rowContent(for entry: SessionListEntry, connection: ServerConnection) -> SessionListRowContent {
        let rowStartNs = SessionListPerf.timestampNs()
        var statuses: [String: SessionStatusKind] = [:]
        var foreignNames: [String: String] = [:]
        for session in SessionListRowContent.drawnSessions(of: entry) {
            statuses[session.id] = SessionStatusKind.resolve(
                session: session,
                pendingAskCount: Self.pendingAskCount(for: session.id, connection: connection),
                seenAt: connection.sessionStore.seenAt(for: session.id)
            )
            if let name = foreignWorkspaceName(for: session, connection: connection) {
                foreignNames[session.id] = name
            }
        }
        let session = entry.session
        let attention = attentionCounts(for: session, connection: connection)
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            pendingAskCount: attention.askCount,
            pendingAsk: connection.askRequestStore.pending(for: session.id),
            seenAt: connection.sessionStore.seenAt(for: session.id),
            searchSnippet: searchStore.snippetsBySessionId[session.id],
            catalogModels: connection.chatState.cachedModels
        )
        SessionListPerf.recordRowCompute(
            durationMs: Int((SessionListPerf.timestampNs() &- rowStartNs) / 1_000_000),
            rowCount: 1,
            workspaceId: workspaceId
        )
        return SessionListRowContent(
            entry: entry,
            presentation: presentation,
            statuses: statuses,
            foreignWorkspaceNames: foreignNames
        )
    }

    /// Workspace name for a session that runs in another workspace; this list's own workspace is implied.
    private func foreignWorkspaceName(for session: Session, connection: ServerConnection) -> String? {
        guard let id = session.workspaceId, id != workspaceId else { return nil }
        return connection.workspaceStore.workspaces.first { $0.id == id }?.name ?? session.workspaceName
    }

    private func isGroupExpanded(_ group: WorkspaceStoppedSessionGrouping.Group) -> Bool {
        if state.expandedStoppedGroupIDs.contains(group.id) { return true }
        if state.collapsedStoppedGroupIDs.contains(group.id) { return false }
        return group.isExpandedByDefault
    }

    private func isArchiveBucketExpanded(_ bucketId: String) -> Bool {
        state.expandedStoppedGroupIDs.contains(bucketId)
    }

    private func toggle(_ toggle: GroupToggle) {
        switch toggle {
        case .stopped(let groupID, let isExpanded):
            if isExpanded {
                state.expandedStoppedGroupIDs.remove(groupID)
                state.collapsedStoppedGroupIDs.insert(groupID)
            } else {
                state.collapsedStoppedGroupIDs.remove(groupID)
                state.expandedStoppedGroupIDs.insert(groupID)
            }
        case .archive(let bucket):
            if isArchiveBucketExpanded(bucket.id) {
                state.expandedStoppedGroupIDs.remove(bucket.id)
                state.collapsedStoppedGroupIDs.insert(bucket.id)
            } else {
                state.collapsedStoppedGroupIDs.remove(bucket.id)
                state.expandedStoppedGroupIDs.insert(bucket.id)
                Task { await ensureArchiveBucketLoaded(bucket) }
            }
        }
    }

    // MARK: Snapshot

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.backgroundColor = .clear
            let section = self?.dataSource?.sectionIdentifier(for: index)
            configuration.headerMode = section?.hasHeader == true ? .supplementary : .none
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipe(at: indexPath)
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func installDataSource() {
        let sessionCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, let row = rows[item] else { return }
            cell.contentConfiguration = SessionListEntryRow.cellConfiguration(
                row,
                actions: rowActions,
                root: root,
                connection: connection
            )
            cell.backgroundConfiguration = rowBackground()
            // No tap highlight, as the SwiftUI rows had none.
            cell.automaticallyUpdatesBackgroundConfiguration = false
        }
        let localCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, let row = localRows[item] else { return }
            let local = row.session
            cell.contentConfiguration = LocalSessionRow.cellConfiguration(
                local,
                isEnabled: row.isEnabled,
                root: root
            ) { [weak self] in
                Task { await self?.importAndResumeLocal(local) }
            }
            cell.backgroundConfiguration = rowBackground()
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
            case .session, .stoppedSession, .archiveSession:
                collectionView.dequeueConfiguredReusableCell(using: sessionCell, for: indexPath, item: item)
            case .local, .archiveLocal:
                collectionView.dequeueConfiguredReusableCell(using: localCell, for: indexPath, item: item)
            case .searching, .noMatches, .empty, .archiveLoading:
                collectionView.dequeueConfiguredReusableCell(using: stateCell, for: indexPath, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<SessionListSectionHeaderView>(
            elementKind: SessionListSectionHeaderView.elementKind
        ) { [weak self] view, _, indexPath in
            view.horizontalInset = SessionListSectionHeaderView.insetGroupedInset
            self?.configure(view, at: indexPath)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        self.dataSource = dataSource
    }

    private func applySnapshot(_ detail: DetailState, reconfigureAll: Bool) {
        guard let dataSource else { return }
        let data = viewData(detail)
        let connection = detail.connection

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        var nextRows: [Item: SessionListRowContent] = [:]
        var nextLocals: [Item: LocalRow] = [:]
        var nextStates: [Item: StateRow] = [:]
        var nextHeaders: [Section: Header] = [:]
        let localsEnabled = !state.isImportingLocal

        func appendState(_ row: StateRow, item: Item, section: Section) {
            snapshot.appendSections([section])
            snapshot.appendItems([item], toSection: section)
            nextStates[item] = row
        }
        func append(_ items: [WorkspaceStoppedSessionGrouping.Item], to section: Section, archive: Bool) {
            var ids: [Item] = []
            ids.reserveCapacity(items.count)
            for item in items {
                switch item {
                case .entry(let entry):
                    let id = archive ? Item.archiveSession(entry.id) : Item.stoppedSession(entry.id)
                    // A diffable snapshot traps on a repeated item.
                    guard nextRows[id] == nil else { continue }
                    nextRows[id] = rowContent(for: entry, connection: connection)
                    ids.append(id)
                case .local(let local):
                    let id = archive ? Item.archiveLocal(local.path) : Item.local(local.path)
                    guard nextLocals[id] == nil else { continue }
                    nextLocals[id] = LocalRow(session: local, isEnabled: localsEnabled)
                    ids.append(id)
                }
            }
            snapshot.appendItems(ids, toSection: section)
        }
        func appendSessions(_ entries: [SessionListEntry], section: Section) {
            snapshot.appendSections([section])
            var ids: [Item] = []
            ids.reserveCapacity(entries.count)
            for entry in entries {
                let id = Item.session(entry.id)
                guard nextRows[id] == nil else { continue }
                nextRows[id] = rowContent(for: entry, connection: connection)
                ids.append(id)
            }
            snapshot.appendItems(ids, toSection: section)
        }

        if detail.hasSearchQuery {
            if searchStore.isSearching && data.searchMatches.isEmpty && data.localFiltered.isEmpty {
                appendState(.searching, item: .searching, section: .status)
            } else if data.searchMatches.isEmpty && data.localFiltered.isEmpty {
                let query = detail.search.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                appendState(.noMatches(query: query), item: .noMatches, section: .status)
            } else {
                if !data.searchMatches.isEmpty {
                    nextHeaders[.results] = .title(String(localized: "Results"))
                    appendSessions(data.searchMatches, section: .results)
                }
                if !data.localFiltered.isEmpty {
                    nextHeaders[.localResults] = .title(String(localized: "Local Sessions"))
                    snapshot.appendSections([.localResults])
                    append(data.localFiltered.map(WorkspaceStoppedSessionGrouping.Item.local), to: .localResults, archive: false)
                }
            }
        } else {
            if !data.yourTurn.isEmpty {
                nextHeaders[.yourTurn] = .title(SessionInboxSectionTitle.yourTurn)
                appendSessions(data.yourTurn, section: .yourTurn)
            }
            if !data.working.isEmpty {
                nextHeaders[.working] = .title(SessionInboxSectionTitle.working)
                appendSessions(data.working, section: .working)
            }
            let groups = WorkspaceStoppedSessionGrouping.groups(
                stoppedEntries: data.stopped,
                localSessions: data.localFiltered
            )
            for (index, group) in groups.enumerated() {
                let section = Section.stopped(group.id)
                let isExpanded = isGroupExpanded(group)
                let title = WorkspaceStoppedSessionGrouping.title(group.bucket)
                nextHeaders[section] = .group(GroupHeader(
                    title: index == 0 ? "Stopped · \(title)" : title,
                    detail: nil,
                    isExpanded: isExpanded,
                    accessibilityIdentifier: "workspace.stoppedGroup.\(group.id)",
                    toggle: .stopped(groupID: group.id, isExpanded: isExpanded)
                ))
                snapshot.appendSections([section])
                if isExpanded {
                    append(group.items, to: section, archive: false)
                }
            }
            for bucket in state.archiveBuckets {
                let section = Section.archive(bucket.id)
                let isExpanded = isArchiveBucketExpanded(bucket.id)
                nextHeaders[section] = .group(GroupHeader(
                    title: "Stopped · \(WorkspaceStoppedSessionGrouping.title(bucket))",
                    detail: "\(bucket.itemCount)",
                    isExpanded: isExpanded,
                    accessibilityIdentifier: nil,
                    toggle: .archive(bucket)
                ))
                snapshot.appendSections([section])
                guard isExpanded else { continue }
                if state.loadingArchiveBucketIDs.contains(bucket.id) {
                    let item = Item.archiveLoading(bucket.id)
                    snapshot.appendItems([item], toSection: section)
                    nextStates[item] = .archiveLoading
                } else {
                    append(
                        WorkspaceStoppedSessionGrouping.archiveItems(
                            entries: archiveEntries(for: bucket),
                            localSessions: state.archiveLocalSessionsByBucketID[bucket.id] ?? []
                        ),
                        to: section,
                        archive: true
                    )
                }
            }
            if data.isEmpty {
                appendState(.empty, item: .empty, section: .empty)
            }
        }

        let current = Set(dataSource.snapshot().itemIdentifiers)
        let changed = snapshot.itemIdentifiers.filter { item in
            guard current.contains(item) else { return false }
            if reconfigureAll { return true }
            if let row = nextRows[item] { return rows[item] != row }
            if let local = nextLocals[item] { return localRows[item] != local }
            return stateRows[item] != nextStates[item]
        }
        let headersChanged = reconfigureAll || headers != nextHeaders
        rows = nextRows
        localRows = nextLocals
        stateRows = nextStates
        headers = nextHeaders
        snapshot.reconfigureItems(changed)

        let animated = hasAppliedSnapshot && view.window != nil
        hasAppliedSnapshot = true
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            if headersChanged { self?.refreshVisibleHeaders() }
        }
    }

    private func rowBackground() -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = root.themeStore.backgroundColor
        return background
    }

    private func configure(_ cell: UICollectionViewListCell, row: StateRow) {
        let palette = root.themeStore.activeThemeID.palette
        cell.backgroundConfiguration = rowBackground()
        cell.automaticallyUpdatesBackgroundConfiguration = false
        switch row {
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
        case .empty:
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: "terminal")
            content.text = String(localized: "No Sessions")
            content.secondaryText = String(
                localized: "Tap Message to compose a Quick Session in this worktree."
            )
            cell.contentConfiguration = content
        case .archiveLoading:
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Loading older sessions…")
            content.textProperties.color = UIColor(palette.comment)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.contentConfiguration = content
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .leading()))]
            return
        }
        cell.accessories = []
    }

    private func configure(_ view: SessionListSectionHeaderView, at indexPath: IndexPath) {
        guard let section = dataSource?.sectionIdentifier(for: indexPath.section),
              let header = headers[section] else { return }
        let palette = root.themeStore.activeThemeID.palette
        switch header {
        case .title(let title):
            view.configure(title: title, palette: palette)
        case .group(let group):
            view.configure(
                title: group.title,
                detail: group.detail,
                isExpanded: group.isExpanded,
                accessibilityIdentifier: group.accessibilityIdentifier,
                palette: palette
            ) { [weak self] in
                self?.toggle(group.toggle)
            }
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

    // MARK: Overlays

    /// The git context bar over the list (and its scrim while expanded), and
    /// the creating / resuming progress panel.
    private func syncOverlays(_ detail: DetailState) {
        if let gitStatus = detail.gitStatus, gitStatus.isGitRepo {
            let context = WorkspaceContextBarView.Context(
                gitStatus: gitStatus,
                workspaceId: workspaceId,
                worktreeId: state.selectedWorktreeId,
                serverId: serverId,
                collapseToken: state.contextBarCollapseToken
            )
            if let contextBar {
                contextBar.context = context
            } else {
                installContextBar(context, connection: detail.connection)
            }
        } else {
            removeContextBar()
        }
        scrim.isHidden = !(state.contextBarExpanded && contextBar != nil)

        if state.isCreating || state.isImportingLocal {
            progressPanel.text = state.isImportingLocal
                ? String(localized: "Resuming session...")
                : String(localized: "Creating session...")
            progressPanel.isHidden = false
            view.bringSubviewToFront(progressPanel)
        } else {
            progressPanel.isHidden = true
        }
    }

    /// The bar sizes itself (collapsed or expanded) and reports each height.
    private func installContextBar(_ context: WorkspaceContextBarView.Context, connection: ServerConnection) {
        let bar = WorkspaceContextBarView(
            context: context,
            options: .init(showCleanWorkspace: true),
            connection: connection,
            apiClient: connection.apiClient,
            navigation: navigation
        )
        bar.presenter = self
        bar.onExpandedChanged = { [weak self] expanded in
            self?.state.contextBarExpanded = expanded
        }
        bar.onHeightChange = { [weak self] height in
            self?.setContextBarHeight(height)
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(bar, aboveSubview: scrim)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        contextBar = bar
    }

    private func removeContextBar() {
        guard let contextBar else { return }
        contextBar.removeFromSuperview()
        self.contextBar = nil
        setContextBarHeight(0)
        if state.contextBarExpanded {
            state.contextBarExpanded = false
        }
    }

    /// The list's content starts below the bar, as `contentMargins` did.
    private func setContextBarHeight(_ height: CGFloat) {
        let next = max(0, ceil(height))
        guard abs(next - contextBarHeight) > 0.5 else { return }
        contextBarHeight = next
        collectionView.contentInset.top = next
        collectionView.verticalScrollIndicatorInsets.top = next
    }

    @objc private func scrimTapped() {
        state.contextBarCollapseToken &+= 1
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return false }
        if rows[item] != nil { return true }
        return localRows[item]?.isEnabled == true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        if let session = rows[item]?.entry.session {
            rowActions.open(session)
        } else if let local = localRows[item], local.isEnabled {
            Task { await importAndResumeLocal(local.session) }
        }
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

    private func selectWorktree(_ worktree: WorkspaceWorktree) {
        guard state.selectedWorktreeId != worktree.id else { return }
        state.selectedWorktreeId = worktree.id
        resetWorktreeScopedState()
        refreshGitStatusContextBar()
        Task { await refreshWorkspaceData() }
    }

    private func loadWorktrees() async {
        guard let api = connection?.apiClient else { return }
        state.isLoadingWorktrees = state.worktrees.isEmpty
        defer { state.isLoadingWorktrees = false }

        do {
            let fetched = try await api.listWorkspaceWorktrees(workspaceId: workspaceId)
            state.worktrees = fetched
            if !fetched.contains(where: { $0.id == state.selectedWorktreeId }) {
                state.selectedWorktreeId = fetched.first?.id ?? WorkspaceWorktree.mainId
                resetWorktreeScopedState()
            }
        } catch {
            // Worktree discovery is best-effort: older servers lack the route, and sandbox
            // workspaces answer 409. Keep the main checkout visible.
            if state.worktrees.isEmpty, let connection {
                state.worktrees = visibleWorktrees(currentWorkspace(connection))
            }
        }
    }

    private func visibleWorktrees(_ workspace: Workspace) -> [WorkspaceWorktree] {
        guard state.worktrees.isEmpty else { return state.worktrees }
        return [
            WorkspaceWorktree(
                id: WorkspaceWorktree.mainId,
                name: "Main checkout",
                path: workspace.hostMount ?? "",
                branch: nil,
                headSha: nil,
                isMain: true,
                isGitRepo: false,
                sessionCount: nil
            ),
        ]
    }

    private func resetWorktreeScopedState() {
        state.workspaceRefreshGeneration &+= 1
        state.localSessions = []
        state.archiveBuckets = []
        state.archiveStoppedSessionsByBucketID = [:]
        state.archiveLocalSessionsByBucketID = [:]
        state.loadingArchiveBucketIDs = []
        state.expandedStoppedGroupIDs = []
        state.collapsedStoppedGroupIDs = []
        state.isRefreshingWorkspaceData = false
        state.workspaceLoad = nil
    }

    private func autoOpenE2ESessionIfRequested() {
        guard !state.hasAutoOpenedE2ESession,
              let connection,
              let sessionId = ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"],
              !sessionId.isEmpty,
              routeWorkspace.name == ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"]
        else { return }

        state.hasAutoOpenedE2ESession = true
        if let session = workspaceSessions(connection).first(where: { $0.id == sessionId }) {
            openSession(session)
        } else {
            routeToSession(sessionId)
        }
    }

    /// Once per process. Split replaces this screen when a chat replaces the
    /// detail root, so a screen-local flag cannot remember the launch hint.
    @MainActor
    private enum E2EWorkspaceLaunchHintGate {
        static var didCreateSession = false
    }

    private func autoCreateE2ESessionIfRequested() async {
        // Split replaces the detail root with the chat, so this screen is gone
        // when Back returns here. A screen-local flag would create and open
        // another session, and the chat would look like it never left.
        guard !E2EWorkspaceLaunchHintGate.didCreateSession,
              !state.hasAutoCreatedE2ESession,
              (ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"] ?? "").isEmpty,
              ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_CREATE_SESSION"] == "1",
              routeWorkspace.name == ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"]
        else { return }

        E2EWorkspaceLaunchHintGate.didCreateSession = true
        state.hasAutoCreatedE2ESession = true
        await createSession()
    }

    /// Creates a session in this workspace and worktree. Sandbox VM errors
    /// (QEMU unavailable, VM start failure) arrive as standard API errors and
    /// show in the error alert.
    private func createSession() async {
        guard let connection, let api = connection.apiClient else {
            showError("Server is offline — reconnecting in background")
            return
        }
        state.isCreating = true
        clearError()

        do {
            let response = try await api.createWorkspaceSession(
                workspaceId: workspaceId,
                worktreeId: state.selectedWorktreeId
            )
            connection.sessionStore.upsert(response.session)
            state.isCreating = false
            routeToSession(response.session.id)
        } catch {
            showError(error.localizedDescription)
            state.isCreating = false
        }
    }

    private func stopSession(_ session: Session) async {
        guard let connection, let api = connection.apiClient else { return }
        do {
            let updated = try await api.stopWorkspaceSession(workspaceId: workspaceId, sessionId: session.id)
            connection.sessionStore.upsert(updated)
        } catch {
            showError("Stop failed: \(error.localizedDescription)")
        }
    }

    private func resumeSession(_ session: Session) async {
        guard let connection, let api = connection.apiClient else { return }
        do {
            let updated = try await api.resumeWorkspaceSession(workspaceId: workspaceId, sessionId: session.id)
            connection.sessionStore.upsert(updated)
            removeArchiveSession(session.id)
        } catch {
            showError("Resume failed: \(error.localizedDescription)")
        }
    }

    private func confirmDelete(_ session: Session) {
        SessionListAlerts.confirmDelete(session, from: self, sourceView: cell(for: session.id)) { [weak self] in
            Task { await self?.deleteSession(session) }
        }
    }

    private func cell(for sessionId: String) -> UIView? {
        for item in [Item.session(sessionId), .stoppedSession(sessionId), .archiveSession(sessionId)] {
            if let indexPath = dataSource?.indexPath(for: item), let cell = collectionView.cellForItem(at: indexPath) {
                return cell
            }
        }
        return nil
    }

    private func deleteSession(_ session: Session) async {
        guard let connection, let api = connection.apiClient else { return }
        connection.sessionStore.remove(id: session.id)
        removeArchiveSession(session.id)
        await TimelineCache.shared.removeTrace(session.id, serverId: serverId)
        do {
            try await api.deleteWorkspaceSession(workspaceId: workspaceId, sessionId: session.id)
            forgetDeleted(session)
        } catch let apiError as APIError {
            // 404 means already deleted server-side — local removal above is sufficient.
            if case .server(let status, _) = apiError, status == 404 {
                forgetDeleted(session)
            } else {
                showError("Delete failed: \(apiError.localizedDescription)")
            }
        } catch {
            showError("Delete failed: \(error.localizedDescription)")
        }
    }

    /// Only after the server no longer has the session; a failed delete
    /// brings it back on the next sync, still locked.
    private func forgetDeleted(_ session: Session) {
        ScopedLockService.shared.forgetSession(serverId: serverId, sessionId: session.id)
        root.composerDraftStore.clearDraft(serverID: serverId, workspaceID: workspaceId, sessionID: session.id)
    }

    private func openSession(_ session: Session) {
        guard let connection else { return }
        applySearchNavigation(.willOpenDestination)
        let workspace = currentWorkspace(connection)
        var normalized = session
        if normalized.workspaceId == nil || normalized.workspaceId?.isEmpty == true {
            normalized.workspaceId = workspace.id
        }
        if normalized.workspaceName == nil || normalized.workspaceName?.isEmpty == true {
            normalized.workspaceName = workspace.name
        }
        connection.sessionStore.cacheSessionForNavigation(normalized)
        routeToSession(normalized.id)
    }

    private func openThread(_ rootSession: Session) {
        applySearchNavigation(.willOpenDestination)
        navigation.openSessionThread(SessionThreadNavTarget(serverId: serverId, rootSessionId: rootSession.id))
    }

    /// Opens the session's chat through `AppNavigation`. The screen always
    /// has its server, so the hosted screen's server-less push of a chat on
    /// the current connection is gone.
    private func routeToSession(_ sessionId: String) {
        let workspace = connection.map { currentWorkspace($0) } ?? routeWorkspace
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId, workspaceId: workspace.id),
            workspace: WorkspaceNavTarget(serverId: serverId, workspace: workspace)
        )
    }

    private func importAndResumeLocal(_ local: LocalSession) async {
        guard let connection, let api = connection.apiClient, !state.isImportingLocal else { return }
        state.isImportingLocal = true
        clearError()

        do {
            let session = try await api.createWorkspaceSessionFromLocal(
                workspaceId: workspaceId,
                piSessionFile: local.path,
                worktreeId: state.selectedWorktreeId
            )
            connection.sessionStore.upsert(session)

            // Remove from local list immediately (server will also filter it on next fetch)
            state.localSessions.removeAll { $0.path == local.path }
            removeArchiveLocalSession(local.path)

            state.isImportingLocal = false
            applySearchNavigation(.willOpenDestination)
            routeToSession(session.id)
        } catch {
            showError("Resume failed: \(error.localizedDescription)")
            state.isImportingLocal = false
        }
    }

    private func startQuickSession(dictate: Bool) {
        navigation.presentQuickSession(
            QuickSessionStart(
                context: QuickSessionLaunchContext(
                    serverId: serverId,
                    workspaceId: workspaceId,
                    worktreeId: state.selectedWorktreeId
                ),
                mode: dictate ? .dictation : .message
            ),
            from: .workspaceBar
        )
    }

    private func openNowPlaying() {
        guard let player = connection?.audioPlayer else { return }
        SessionListHostedChrome.presentNowPlayingPlayer(player, from: self)
    }

    private func openWorkspaceFiles() {
        let target = FileBrowserNavTarget(
            serverId: serverId,
            workspaceId: workspaceId,
            worktreeId: state.selectedWorktreeId,
            path: ""
        )
        ClientLog.info("FileBrowser", "Workspace files toolbar tapped", metadata: [
            "workspaceId": workspaceId,
            "serverId": serverId,
            "presentation": navigation.workspaceNavigationPresentation == .stack ? "stack" : "split",
            "workspaceStackDepth": String(navigation.workspaceStackRouteElements.count),
        ])
        switch navigation.workspaceNavigationPresentation {
        case .stack:
            navigation.openWorkspaceFileBrowser(target)
        case .split:
            let workspace = connection.map { currentWorkspace($0) } ?? routeWorkspace
            navigation.openWorkspaceFileBrowser(target, workspace: WorkspaceNavTarget(serverId: serverId, workspace: workspace))
        }
    }

    private func openWorkspaceConfiguration() {
        let workspace = connection.map { currentWorkspace($0) } ?? routeWorkspace
        navigation.openWorkspaceConfiguration(WorkspaceNavTarget(serverId: serverId, workspace: workspace))
    }

    private func pullToRefresh() {
        Task { [weak self] in
            guard let self else { return }
            await refreshWorkspaceData()
            refreshControl.endRefreshing()
        }
    }

    // MARK: Archive buckets

    private func isArchiveBucketGroupID(_ id: String) -> Bool {
        id.hasPrefix("day:") || id.hasPrefix("month:")
    }

    private func pruneArchiveState(validBucketIDs: Set<String>) {
        state.archiveStoppedSessionsByBucketID = state.archiveStoppedSessionsByBucketID.filter { validBucketIDs.contains($0.key) }
        state.archiveLocalSessionsByBucketID = state.archiveLocalSessionsByBucketID.filter { validBucketIDs.contains($0.key) }
        state.loadingArchiveBucketIDs = state.loadingArchiveBucketIDs.filter { validBucketIDs.contains($0) }
        state.expandedStoppedGroupIDs = state.expandedStoppedGroupIDs.filter {
            validBucketIDs.contains($0) || !isArchiveBucketGroupID($0)
        }
        state.collapsedStoppedGroupIDs = state.collapsedStoppedGroupIDs.filter {
            validBucketIDs.contains($0) || !isArchiveBucketGroupID($0)
        }
    }

    private func ensureArchiveBucketLoaded(_ bucket: WorkspaceSessionArchiveBucket) async {
        if state.archiveStoppedSessionsByBucketID[bucket.id] != nil || state.archiveLocalSessionsByBucketID[bucket.id] != nil {
            return
        }
        guard !state.loadingArchiveBucketIDs.contains(bucket.id) else { return }
        guard let api = connection?.apiClient else { return }

        state.loadingArchiveBucketIDs.insert(bucket.id)
        defer { state.loadingArchiveBucketIDs.remove(bucket.id) }

        do {
            let response = try await api.getWorkspaceSessionListBucket(
                workspaceId: workspaceId,
                since: bucket.startAt,
                until: bucket.endAt,
                worktreeId: state.selectedWorktreeId
            )
            state.archiveStoppedSessionsByBucketID[bucket.id] = response.sessionSummaries
                .map(\.session)
                .filter { session in
                    session.status == .stopped &&
                        session.lastActivity >= bucket.startAt &&
                        session.lastActivity < bucket.endAt
                }
            state.archiveLocalSessionsByBucketID[bucket.id] = response.importableSessions
        } catch {
            showError("Failed to load older sessions: \(error.localizedDescription)")
        }
    }

    private func updateArchiveBucketCounts(
        bucketId: String,
        removedManagedStoppedCount: Int = 0,
        removedImportableLocalCount: Int = 0
    ) {
        guard let index = state.archiveBuckets.firstIndex(where: { $0.id == bucketId }) else { return }
        var bucket = state.archiveBuckets[index]
        bucket.managedStoppedCount = max(0, bucket.managedStoppedCount - removedManagedStoppedCount)
        bucket.importableLocalCount = max(0, bucket.importableLocalCount - removedImportableLocalCount)
        bucket.itemCount = max(0, bucket.itemCount - removedManagedStoppedCount - removedImportableLocalCount)
        if bucket.itemCount == 0 {
            state.archiveBuckets.remove(at: index)
            state.archiveStoppedSessionsByBucketID.removeValue(forKey: bucketId)
            state.archiveLocalSessionsByBucketID.removeValue(forKey: bucketId)
            state.expandedStoppedGroupIDs.remove(bucketId)
            state.collapsedStoppedGroupIDs.remove(bucketId)
        } else {
            state.archiveBuckets[index] = bucket
        }
    }

    private func removeArchiveSession(_ sessionId: String) {
        for (bucketId, sessions) in state.archiveStoppedSessionsByBucketID where sessions.contains(where: { $0.id == sessionId }) {
            state.archiveStoppedSessionsByBucketID[bucketId] = sessions.filter { $0.id != sessionId }
            updateArchiveBucketCounts(bucketId: bucketId, removedManagedStoppedCount: 1)
            break
        }
    }

    private func removeArchiveLocalSession(_ path: String) {
        for (bucketId, sessions) in state.archiveLocalSessionsByBucketID where sessions.contains(where: { $0.path == path }) {
            state.archiveLocalSessionsByBucketID[bucketId] = sessions.filter { $0.path != path }
            updateArchiveBucketCounts(bucketId: bucketId, removedImportableLocalCount: 1)
            break
        }
    }

    // MARK: Refresh and polling

    private func runWorkspaceRefreshPolling() async {
        var policy = SessionListRefreshPollingPolicy()

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Int.random(in: 10...15)))
            guard !Task.isCancelled else { break }

            let polling = workspacePollingState()
            guard policy.shouldRefresh(hasActiveWork: polling.hasActiveWork, hasAttention: polling.hasAttention) else {
                continue
            }

            await refreshWorkspaceData()
        }
    }

    private func workspacePollingState() -> (hasActiveWork: Bool, hasAttention: Bool) {
        guard let connection else { return (false, false) }
        let sessions = workspaceSessions(connection)
        let sessionIds = Set(sessions.map(\.id))
        let hasActiveWork = sessions.contains { session in
            switch session.status {
            case .starting, .busy, .stopping:
                true
            case .ready, .stopped, .error:
                false
            }
        }
        let hasAskAttention = sessions.contains { Self.pendingAskCount(for: $0.id, connection: connection) > 0 }
            || connection.askRequestStore.pending.values.contains { ask in
                ask.workspaceId == workspaceId ||
                    (ask.workspaceId == nil && sessionIds.contains(ask.sessionId))
            }
        return (hasActiveWork: hasActiveWork, hasAttention: hasAskAttention)
    }

    private func refreshWorkspaceData() async {
        guard !state.isRefreshingWorkspaceData else { return }
        let requestedGeneration = state.workspaceRefreshGeneration
        state.isRefreshingWorkspaceData = true
        defer {
            if requestedGeneration == state.workspaceRefreshGeneration {
                state.isRefreshingWorkspaceData = false
            }
        }

        guard let connection, let api = connection.apiClient else { return }
        let hadVisibleData = !workspaceSessions(connection).isEmpty
            || !state.localSessions.isEmpty
            || !state.archiveBuckets.isEmpty

        do {
            let startedAt = Date()
            let range = (since: startedAt.addingTimeInterval(-Double(Self.hotStoppedRangeDays) * 86_400), until: startedAt)
            let response = try await api.getWorkspaceSessionList(
                workspace: currentWorkspace(connection),
                since: range.since,
                until: range.until,
                worktreeId: state.selectedWorktreeId
            )
            guard !Task.isCancelled, requestedGeneration == state.workspaceRefreshGeneration else { return }

            connection.sessionStore.applyWorkspaceRecentSnapshot(
                workspaceId: workspaceId,
                summaries: response.sessionSummaries,
                requestStartedAt: startedAt
            )
            state.archiveBuckets = response.archiveBuckets
            pruneArchiveState(validBucketIDs: Set(response.archiveBuckets.map(\.id)))
            state.localSessions = response.importableSessions
            connection.applyWorkspaceAttentionSnapshot(
                APIClient.WorkspaceAttentionResponse(
                    workspaceId: workspaceId,
                    serverNow: response.serverNow,
                    attention: response.attention
                )
            )
            clearError(onlyWithPrefix: Self.loadErrorPrefix)
        } catch {
            guard !Task.isCancelled, requestedGeneration == state.workspaceRefreshGeneration else { return }
            if WorkspaceDetailLoadErrorPolicy.shouldPresent(
                error: error,
                workspaceId: workspaceId,
                hadVisibleData: hadVisibleData,
                knownWorkspaceIds: Set(connection.workspaceStore.workspaces.map(\.id))
            ) {
                showError("\(Self.loadErrorPrefix) \(error.localizedDescription)")
            }
        }
    }

    private static let hotStoppedRangeDays = 3
    private static let loadErrorPrefix = "Failed to load workspace:"

    private func refreshGitStatusContextBar() {
        // GitStatusStore is connection-scoped, so returning from a chat can leave
        // the workspace list showing the last pushed status until REST refreshes it.
        guard let connection, let api = connection.apiClient else { return }
        connection.gitStatusStore.loadInitial(
            workspaceId: workspaceId,
            worktreeId: state.selectedWorktreeId,
            apiClient: api,
            gitStatusEnabled: currentWorkspace(connection).gitStatusEnabled ?? true
        )
    }

    // MARK: Load telemetry

    private func beginWorkspaceLoadIfNeeded(path: String) {
        guard state.workspaceLoad == nil, let connection else { return }
        state.workspaceLoad = WorkspaceLoadMeasurement(
            startedAtMs: Date.nowMs(),
            path: path,
            hadImmediateContent: !workspaceSessions(connection).isEmpty || !state.localSessions.isEmpty
        )
    }

    private func scheduleWorkspaceLoadCompletionCheck() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.finishWorkspaceLoadIfReady()
        }
    }

    private func finishWorkspaceLoadIfReady() {
        guard let workspaceLoad = state.workspaceLoad else { return }
        if !workspaceLoad.hadImmediateContent, state.isRefreshingWorkspaceData {
            return
        }
        ChatSessionTelemetry.recordTimingMetric(
            .workspaceLoadMs,
            durationMs: Date.nowMs() - workspaceLoad.startedAtMs,
            workspaceId: workspaceId,
            tags: ["path": workspaceLoad.path]
        )
        state.workspaceLoad = nil
    }

    // MARK: Errors

    private func showError(_ message: String) {
        pendingError = message
        presentPendingError()
    }

    /// The hosted screen's `error = nil`: the pending error goes and a shown
    /// alert closes. With a prefix, only an error that starts with it.
    private func clearError(onlyWithPrefix prefix: String? = nil) {
        func matches(_ message: String?) -> Bool {
            guard let prefix else { return true }
            return message?.hasPrefix(prefix) == true
        }
        if matches(pendingError) {
            pendingError = nil
        }
        if let alert = presentedViewController as? SessionListErrorAlert, matches(alert.message) {
            alert.dismiss(animated: true)
        }
    }

    private func presentPendingError() {
        guard isOnScreen, phase == .content, viewIfLoaded?.window != nil, let message = pendingError else { return }
        guard presentedViewController == nil || presentedViewController is SessionListErrorAlert else { return }
        pendingError = nil
        SessionListAlerts.presentError(message, from: self)
    }

    // MARK: Bars

    /// Rail and compact bars. Items rebuild when their set changes; the
    /// SwiftUI controls inside them update in place.
    private func syncBars(_ detail: DetailState) {
        let joinsRail = SessionListBarItems.joinsRail(traitCollection)
        let palette = root.themeStore.activeThemeID.palette
        let showsDictation = SessionInboxComposeChrome.showsDictationShortcut(hasActivePlayback: detail.hasActivePlayback)
        let player = detail.connection.audioPlayer
        let showsBottomItems = !detail.isNavigatingDeeper

        navigationItem.title = detail.workspace.name
        navigationItem.backBarButtonItem?.accessibilityLabel = detail.workspace.name

        let worktrees = visibleWorktrees(detail.workspace)
        let selectedName = state.worktrees.first { $0.id == state.selectedWorktreeId }?.displayName ?? "Main"
        let title = TitleState(
            name: detail.workspace.name,
            worktreeName: selectedName,
            worktrees: worktrees,
            selectedWorktreeId: state.selectedWorktreeId,
            canSwitch: !state.isLoadingWorktrees && worktrees.count > 1,
            lockBadge: detail.lockBadge,
            themeID: root.themeStore.activeThemeID
        )

        if !joinsRail, showsBottomItems {
            let params = ComposeParams(
                showsDictation: showsDictation,
                hasActivePlayback: detail.hasActivePlayback,
                columnWidth: columnWidth
            )
            if composeParams != params || composeHost == nil {
                composeParams = params
                composeHost = SessionListHostedChrome.composeCapsule(
                    updating: composeHost,
                    root: root,
                    showsDictation: showsDictation,
                    hasActivePlayback: detail.hasActivePlayback,
                    columnWidth: columnWidth,
                    onStart: { [weak self] in self?.startQuickSession(dictate: false) },
                    onDictate: { [weak self] in self?.startQuickSession(dictate: true) }
                )
            }
            // Disabled while a session is being created.
            composeHost?.view.isUserInteractionEnabled = !state.isCreating
            composeHost?.view.alpha = state.isCreating ? 0.55 : 1
        }
        if !joinsRail, showsBottomItems, detail.toolbar.showsNowPlayingPill {
            let params = PillParams(player: ObjectIdentifier(player), density: detail.toolbar.pillDensity)
            if pillParams != params || pillHost == nil {
                pillParams = params
                pillHost = SessionListHostedChrome.nowPlayingPill(
                    updating: pillHost,
                    root: root,
                    audioPlayer: player,
                    density: detail.toolbar.pillDensity
                ) { [weak self] in self?.openNowPlaying() }
            }
        }

        let bars = BarState(
            joinsRail: joinsRail,
            showsSidebarToggle: showsSidebarToggle,
            isSplit: detail.isSplit,
            showsBottomItems: showsBottomItems,
            showsNowPlaying: detail.toolbar.showsNowPlayingPill,
            parksNowPlayingNextToCompose: detail.toolbar.parksNowPlayingNextToCompose,
            isCreating: state.isCreating,
            showsDictation: showsDictation,
            showsUnlockedBadge: detail.lockBadge == .unlocked,
            configurationLabel: Self.configurationAccessibilityLabel(detail.workspace),
            title: title
        )
        if bars != barState {
            barState = bars
            installBarItems(bars, palette: palette)
        }
        if title != titleState {
            titleState = title
            configureTitleButton(title, palette: palette)
        }
        if let sidebarToggle {
            WorkspaceSplitSidebarToggle.sync(sidebarToggle, root: root)
        }
    }

    private static func configurationAccessibilityLabel(_ workspace: Workspace) -> String {
        workspace.runtime == .sandbox
            ? String(localized: "Edit sandbox workspace")
            : String(localized: "Edit workspace")
    }

    private func installBarItems(_ bars: BarState, palette: ThemePalette) {
        let tint = UIColor(palette.fg)
        let railTint = SessionListBarItems.railTint(palette)
        sidebarToggle = bars.showsSidebarToggle ? WorkspaceSplitSidebarToggle.makeItem(root: root) : nil
        var leading: [UIBarButtonItem] = sidebarToggle.map { [$0] } ?? []
        var trailing: [UIBarButtonItem] = []
        var bottom: [UIBarButtonItem] = []
        let showWorkspaces = UIAction { [weak self] _ in self?.navigation.showWorkspaceListInSplitSidebar() }
        let openConfiguration = UIAction { [weak self] _ in self?.openWorkspaceConfiguration() }
        let openFiles: () -> Void = { [weak self] in self?.openWorkspaceFiles() }

        if bars.joinsRail {
            // The principal title is a wide custom view; the rail keeps the
            // system title and a labeled worktree symbol with the same menu.
            navigationItem.titleView = nil
            if bars.isSplit {
                // Split detail has no system Back.
                let item = UIBarButtonItem(
                    title: String(localized: "Workspaces"),
                    image: UIImage(systemName: "sidebar.leading"),
                    primaryAction: showWorkspaces
                )
                item.tintColor = railTint
                item.accessibilityLabel = String(localized: "Show workspaces")
                item.accessibilityIdentifier = "workspace.sidebar.showWorkspaces"
                trailing.append(SessionListBarItems.railItem(item, priority: .navigation))
            }
            if bars.showsBottomItems {
                let compose = SessionListBarItems.railCompose(
                    showsDictation: bars.showsDictation,
                    tint: railTint,
                    onStart: { [weak self] in self?.startQuickSession(dictate: false) },
                    onDictate: { [weak self] in self?.startQuickSession(dictate: true) }
                )
                compose.isEnabled = !bars.isCreating
                trailing.append(compose)
            }
            if bars.showsUnlockedBadge {
                let badge = UIBarButtonItem(
                    title: String(localized: "Unlocked"),
                    image: UIImage(systemName: "lock.open.fill"),
                    primaryAction: nil
                )
                badge.tintColor = tint
                badge.accessibilityLabel = String(localized: "Unlocked")
                badge.accessibilityIdentifier = "lockBadge.unlocked"
                trailing.append(SessionListBarItems.railItem(badge, priority: .keep))
            }
            trailing.append(SessionListBarItems.railItem(worktreeRailItem(bars.title, tint: tint), priority: .keep))
            let configuration = UIBarButtonItem(
                title: String(localized: "Config"),
                image: UIImage(systemName: "slider.horizontal.3"),
                primaryAction: openConfiguration
            )
            configuration.tintColor = railTint
            configuration.accessibilityLabel = bars.configurationLabel
            configuration.accessibilityIdentifier = "workspace.edit.open"
            trailing.append(SessionListBarItems.railItem(configuration, priority: .keep))
            if bars.showsBottomItems {
                if bars.showsNowPlaying {
                    trailing.append(SessionListBarItems.railNowPlaying(tint: railTint) { [weak self] in self?.openNowPlaying() })
                }
                // Bottom-anchored: spacers cannot push a rail item down.
                bottom.append(SessionListBarItems.files(
                    isEnabled: true,
                    accessibilityLabel: String(localized: "Open workspace files"),
                    railTitle: String(localized: "Files"),
                    palette: palette,
                    action: openFiles
                ))
            }
        } else {
            navigationItem.titleView = titleButton
            if bars.isSplit {
                let item = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), primaryAction: showWorkspaces)
                item.tintColor = tint
                item.accessibilityLabel = String(localized: "Show workspaces")
                item.accessibilityIdentifier = "workspace.sidebar.showWorkspaces"
                leading.append(SessionListBarItems.horizontalOnly(item))
            }
            let configuration = UIBarButtonItem(
                image: UIImage(systemName: "slider.horizontal.3"),
                primaryAction: openConfiguration
            )
            configuration.tintColor = tint
            configuration.accessibilityLabel = bars.configurationLabel
            configuration.accessibilityIdentifier = "workspace.edit.open"
            trailing.append(configuration)
            if bars.showsBottomItems {
                if let composeHost {
                    bottom.append(SessionListBarItems.hosted(composeHost))
                }
                if bars.showsNowPlaying, let pillHost {
                    bottom.append(bars.parksNowPlayingNextToCompose ? .fixedSpace() : .flexibleSpace())
                    bottom.append(SessionListBarItems.hosted(pillHost))
                }
                bottom.append(.flexibleSpace())
                bottom.append(SessionListBarItems.files(
                    isEnabled: true,
                    accessibilityLabel: String(localized: "Open workspace files"),
                    railTitle: nil,
                    palette: palette,
                    action: openFiles
                ))
            }
        }

        navigationItem.leadingItemGroups = leading.isEmpty
            ? [] : [UIBarButtonItemGroup(barButtonItems: leading, representativeItem: nil)]
        navigationItem.trailingItemGroups = trailing.isEmpty
            ? [] : [UIBarButtonItemGroup(barButtonItems: trailing, representativeItem: nil)]
        setToolbarItems(bottom, animated: false)
        if navigationController?.topViewController === self {
            navigationController?.setToolbarHidden(bottom.isEmpty, animated: false)
        }
    }

    // MARK: Title and worktree menu

    private func worktreeMenu(_ title: TitleState) -> UIMenu {
        let actions = title.worktrees.map { worktree in
            var label = WorkspaceWorktreeMenuFormatting.title(for: worktree)
            if let count = WorkspaceWorktreeMenuFormatting.sessionCountText(for: worktree) {
                label += " · \(count)"
            }
            let symbol = title.selectedWorktreeId == worktree.id
                ? "checkmark"
                : worktree.isMain ? "house" : "point.3.connected.trianglepath.dotted"
            let action = UIAction(title: label, image: UIImage(systemName: symbol)) { [weak self] _ in
                self?.selectWorktree(worktree)
            }
            action.accessibilityIdentifier = "workspace.worktree.\(worktree.id)"
            return action
        }
        return UIMenu(children: [
            UIMenu(title: String(localized: "Worktree"), options: .displayInline, children: actions),
        ])
    }

    private func worktreeAccessibilityLabel(_ title: TitleState) -> String {
        title.canSwitch
            ? String(localized: "Switch worktree, current worktree \(title.worktreeName)")
            : String(localized: "Current worktree \(title.worktreeName)")
    }

    /// The rail's worktree control: the title's menu on a labeled branch symbol.
    private func worktreeRailItem(_ title: TitleState, tint: UIColor) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: String(localized: "Worktree"),
            image: UIImage(systemName: "arrow.triangle.branch"),
            primaryAction: nil,
            menu: title.canSwitch ? worktreeMenu(title) : nil
        )
        item.tintColor = tint
        item.accessibilityLabel = worktreeAccessibilityLabel(title)
        item.accessibilityIdentifier = title.canSwitch ? "workspace.worktree.menu" : "workspace.worktree.title"
        return item
    }

    /// The principal title: the workspace name with its lock badge over the
    /// worktree name, and the worktree menu when there is more than one.
    private func configureTitleButton(_ title: TitleState, palette: ThemePalette) {
        titleButton.configure(
            name: title.name,
            worktreeName: title.worktreeName,
            lockSymbol: title.lockBadge.symbolName,
            showsChevron: title.canSwitch,
            palette: palette
        )
        titleButton.menu = title.canSwitch ? worktreeMenu(title) : nil
        titleButton.isUserInteractionEnabled = title.canSwitch
        titleButton.accessibilityLabel = worktreeAccessibilityLabel(title)
        titleButton.accessibilityIdentifier = title.canSwitch ? "workspace.worktree.menu" : "workspace.worktree.title"
        titleButton.accessibilityTraits = title.canSwitch ? .button : .staticText
    }
}

/// The principal title: the workspace name and lock badge over the worktree
/// name, with a chevron when it opens the worktree menu. One accessibility
/// element; the screen sets its label.
private final class WorkspaceTitleButton: UIButton {
    private let nameLabel = UILabel()
    private let lockImage = UIImageView()
    private let worktreeLabel = UILabel()
    private let chevron = UIImageView()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsMenuAsPrimaryAction = true
        isAccessibilityElement = true

        nameLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold)
        )
        nameLabel.adjustsFontForContentSizeCategory = true
        worktreeLabel.font = .preferredFont(forTextStyle: .caption2)
        worktreeLabel.adjustsFontForContentSizeCategory = true
        let symbol = UIImage.SymbolConfiguration(textStyle: .caption2)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        lockImage.preferredSymbolConfiguration = symbol
        chevron.preferredSymbolConfiguration = symbol
        chevron.image = UIImage(systemName: "chevron.down")
        for view in [lockImage, chevron] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        worktreeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let nameRow = UIStackView(arrangedSubviews: [nameLabel, lockImage])
        nameRow.spacing = 4
        nameRow.alignment = .center
        let titles = UIStackView(arrangedSubviews: [nameRow, worktreeLabel])
        titles.axis = .vertical
        titles.alignment = .center
        titles.spacing = 1
        row.addArrangedSubview(titles)
        row.addArrangedSubview(chevron)
        row.spacing = 5
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The bar sizes a title view by its intrinsic size; a button's own
    /// would be its (empty) system title's.
    override var intrinsicContentSize: CGSize {
        row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }

    func configure(name: String, worktreeName: String, lockSymbol: String?, showsChevron: Bool, palette: ThemePalette) {
        let comment = UIColor(palette.comment)
        nameLabel.text = name
        nameLabel.textColor = UIColor(palette.fg)
        lockImage.image = lockSymbol.flatMap { UIImage(systemName: $0) }
        lockImage.isHidden = lockSymbol == nil
        lockImage.tintColor = comment
        worktreeLabel.text = worktreeName
        worktreeLabel.textColor = comment
        chevron.isHidden = !showsChevron
        chevron.tintColor = comment
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Model

private extension ScopedLockState {
    var symbolName: String? {
        switch self {
        case .none: nil
        case .locked: "lock.fill"
        case .unlocked: "lock.open.fill"
        }
    }
}

private extension WorkspaceDetailViewController {
    enum Phase: Equatable {
        case locked
        case connecting
        case content
    }

    struct WorkspaceLoadMeasurement {
        let startedAtMs: Int64
        let path: String
        let hadImmediateContent: Bool
    }

    /// What the hosted screen kept in `@State`, fresh for each mount.
    struct ContentState {
        var isCreating = false
        var expandedStoppedGroupIDs: Set<String> = []
        var collapsedStoppedGroupIDs: Set<String> = []
        var localSessions: [LocalSession] = []
        var worktrees: [WorkspaceWorktree] = []
        var selectedWorktreeId = WorkspaceWorktree.mainId
        var isLoadingWorktrees = false
        var isImportingLocal = false
        var contextBarCollapseToken = 0
        var contextBarExpanded = false
        var archiveBuckets: [WorkspaceSessionArchiveBucket] = []
        var archiveStoppedSessionsByBucketID: [String: [Session]] = [:]
        var archiveLocalSessionsByBucketID: [String: [LocalSession]] = [:]
        var loadingArchiveBucketIDs: Set<String> = []
        var isRefreshingWorkspaceData = false
        var workspaceRefreshGeneration = 0
        var hasPresentedWorkspaceOnce = false
        var hasAutoCreatedE2ESession = false
        var hasAutoOpenedE2ESession = false
        var workspaceLoad: WorkspaceLoadMeasurement?
    }

    struct DetailState {
        let connection: ServerConnection
        let workspace: Workspace
        /// The selected worktree's sessions.
        let sessions: [Session]
        let search: SessionListSearchNavigationPersistence.State
        let hasSearchQuery: Bool
        let hasActivePlayback: Bool
        let toolbar: InAppNowPlayingChrome.SessionListToolbar
        let lockBadge: ScopedLockState
        /// A destination is pushed over this list: no compose, now playing, or files.
        let isNavigatingDeeper: Bool
        let isSplit: Bool
        let gitStatus: GitStatus?
    }

    struct ViewData {
        let yourTurn: [SessionListEntry]
        let working: [SessionListEntry]
        let stopped: [SessionListEntry]
        let localFiltered: [LocalSession]
        let searchMatches: [SessionListEntry]
        let isEmpty: Bool
    }

    struct Observed: Equatable {
        var searchText: String
        var isSearchPresented: Bool
        var stackCount: Int
        var splitDetailTarget: WorkspaceSplitDetailTarget?
        var pollingKey: String
    }

    enum Section: Hashable {
        case status
        case results
        case localResults
        case yourTurn
        case working
        case stopped(String)
        case archive(String)
        case empty

        var hasHeader: Bool {
            switch self {
            case .results, .localResults, .yourTurn, .working, .stopped, .archive: true
            case .status, .empty: false
            }
        }
    }

    /// Session rows by session id, local rows by file path, one fixed id per
    /// state row. Stopped and older-history rows have their own ids, so a
    /// session that stops leaves Working and arrives in its group instead of
    /// moving between them.
    enum Item: Hashable {
        case searching
        case noMatches
        case empty
        case session(String)
        case stoppedSession(String)
        case archiveSession(String)
        case local(String)
        case archiveLocal(String)
        case archiveLoading(String)
    }

    struct LocalRow: Equatable {
        let session: LocalSession
        let isEnabled: Bool
    }

    enum StateRow: Equatable {
        case searching
        case noMatches(query: String)
        case empty
        case archiveLoading
    }

    enum GroupToggle: Equatable {
        case stopped(groupID: String, isExpanded: Bool)
        case archive(WorkspaceSessionArchiveBucket)
    }

    struct GroupHeader: Equatable {
        let title: String
        /// The older-history bucket's item count.
        let detail: String?
        let isExpanded: Bool
        let accessibilityIdentifier: String?
        let toggle: GroupToggle
    }

    enum Header: Equatable {
        case title(String)
        case group(GroupHeader)
    }

    struct TitleState: Equatable {
        let name: String
        let worktreeName: String
        let worktrees: [WorkspaceWorktree]
        let selectedWorktreeId: String
        let canSwitch: Bool
        let lockBadge: ScopedLockState
        let themeID: ThemeID
    }

    struct BarState: Equatable {
        let joinsRail: Bool
        let showsSidebarToggle: Bool
        let isSplit: Bool
        let showsBottomItems: Bool
        let showsNowPlaying: Bool
        let parksNowPlayingNextToCompose: Bool
        let isCreating: Bool
        let showsDictation: Bool
        let showsUnlockedBadge: Bool
        let configurationLabel: String
        /// The rail's worktree item carries the title's menu.
        let title: TitleState
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
}

/// The floating "Creating session..." / "Resuming session..." panel.
private final class WorkspaceDetailProgressPanel: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var accessibilityLabel: String? {
        get { label.text }
        set {}
    }

    func apply(_ palette: ThemePalette) {
        let surface = ThemeSurfaceStyle.resolve(.elevatedPanel, palette: palette)
        backgroundColor = UIColor(surface.fill)
        layer.borderColor = surface.stroke.map { UIColor($0).cgColor }
        layer.borderWidth = surface.stroke == nil ? 0 : surface.strokeLineWidth
        spinner.color = UIColor(palette.cyan)
        label.textColor = UIColor(palette.fg)
    }
}
