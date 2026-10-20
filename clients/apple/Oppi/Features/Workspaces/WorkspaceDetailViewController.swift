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
/// snapshot keyed by session id to its `SessionListCollection`, which owns
/// the cells, taps, swipes, and long-press menu. Local-session rows are
/// `LocalSessionRowConfiguration` cells.
///
/// The shell keeps one screen per server and workspace id; a refreshed
/// `Workspace` value for it arrives through `update(workspace:)`.
/// Extensions: +List (rows and snapshot), +Chrome (bars, title, overlays),
/// +Actions (what the controls do), +Refresh (loading and polling).
final class WorkspaceDetailViewController: UIViewController {
    /// The split detail root carries the sidebar toggle.
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    let root: AppRootEnvironment
    let serverId: String
    let workspaceId: String
    /// The route's value; the server's store has the latest one.
    var routeWorkspace: Workspace
    private var coordinator: ConnectionCoordinator { root.coordinator }
    var navigation: AppNavigation { root.navigation }
    private var lockTarget: ScopedLockTarget { .workspace(serverId: serverId, workspaceId: workspaceId) }

    typealias List = SessionListCollection<Section, Item, Row, GroupToggle>
    /// Session rows, and local-session rows that import and resume on a tap.
    lazy var list: List = {
        let list = List(
            root: root,
            appearance: .insetGrouped,
            actions: rowActions,
            iconAssetCache: { [weak self] in self?.connection?.iconAssetCache },
            configureRow: { [weak self] cell, row in self?.configure(cell, row: row) },
            onToggle: { [weak self] toggle in self?.toggle(toggle) }
        )
        list.isRowSelectable = { row in
            if case .local(_, let isEnabled) = row { return isEnabled }
            return false
        }
        list.didSelectRow = { [weak self] row in
            guard case .local(let local, _) = row else { return }
            Task { await self?.importAndResumeLocal(local) }
        }
        return list
    }()
    private let search = ScreenSearchController(prompt: String(localized: "Search sessions"))
    let titleButton = WorkspaceTitleButton()
    let scrim = UIView()
    /// "Creating session..." or "Resuming session..." over the list.
    let progressPanel = FloatingProgressPanel()

    // Gate and server scope.
    private var phase: Phase?
    private var lockCover: ScopedLockCoverViewController?
    /// The workspace server's connection once it is ready. Dropped with the
    /// content when the workspace locks; unlocking connects again.
    var connection: ServerConnection? {
        didSet { setNeedsUpdateProperties() }
    }
    private var connectTask: Task<Void, Never>?

    // Content state, fresh each time the content mounts (after an unlock).
    var state = ContentState() {
        didSet {
            if oldValue.isRefreshingWorkspaceData, !state.isRefreshingWorkspaceData {
                scheduleWorkspaceLoadCompletionCheck()
            }
            setNeedsUpdateProperties()
        }
    }
    var searchStore = SessionSearchStore()
    private var pendingError: String?
    var columnWidth: CGFloat = 0 {
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

    private var lastThemeID: ThemeID?

    // Overlays and bars.
    var contextBar: WorkspaceContextBarView?
    var contextBarHeight: CGFloat = 0
    var barState: BarState?
    var titleState: TitleState?
    lazy var bottomBar = SessionListBottomBar(
        root: root,
        onStart: { [weak self] in self?.startQuickSession(dictate: false) },
        onDictate: { [weak self] in self?.startQuickSession(dictate: true) },
        onNowPlaying: { [weak self] in self?.openNowPlaying() }
    )
    var sidebarToggle: UIBarButtonItem?

    lazy var rowActions = SessionListRowActions(
        open: { [weak self] session in self?.openSession(session) },
        openThread: { [weak self] rootSession in self?.openThread(rootSession) },
        stop: { [weak self] session in
            Task { await self?.setRunning(false, session) }
        },
        resume: { [weak self] session in
            Task { await self?.setRunning(true, session) }
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
        let collectionView = list.collectionView
        list.refreshControl.addAction(UIAction { [weak self] _ in self?.pullToRefresh() }, for: .valueChanged)

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

        search.bind(
            get: { [weak self] in self?.searchNavigation ?? .init() },
            set: { [weak self] in self?.searchNavigation = $0 }
        )
        SessionListBarItems.updatesWithVerticalBarEdge(self)
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
        guard isOnScreen else { return }

        let themeID = themeStore.activeThemeID
        if lastThemeID != themeID {
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
        search.show(detail.search, toolbar: detail.toolbar)
        applySnapshot(detail)
        syncOverlays(detail)
        syncBars(detail)
    }

    private func applyTheme(_ palette: ThemePalette) {
        let background = UIColor(palette.bg)
        view.backgroundColor = background
        list.collectionView.backgroundColor = background
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

        list.collectionView.isHidden = next != .content
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
        bottomBar.reset()
        setToolbarItems([], animated: false)
        if navigationController?.topViewController === self {
            navigationController?.setToolbarHidden(true, animated: false)
        }
        list.removeAll()
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

    func applySearchNavigation(_ event: SessionListSearchNavigationPersistence.Event) {
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
    func currentWorkspace(_ connection: ServerConnection) -> Workspace {
        let store = connection.workspaceStore
        guard let activeServerId = store.activeServerId,
              let latest = store.workspacesByServer[activeServerId]?.first(where: { $0.id == workspaceId }) else {
            return routeWorkspace
        }
        return latest
    }

    /// The selected worktree's sessions, from the cold list projection:
    /// timeline-frequency events do not rebuild the sections.
    func workspaceSessions(_ connection: ServerConnection) -> [Session] {
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

    // MARK: Errors

    func showError(_ message: String) {
        pendingError = message
        presentPendingError()
    }

    /// The hosted screen's `error = nil`: the pending error goes and a shown
    /// alert closes. With a prefix, only an error that starts with it.
    func clearError(onlyWithPrefix prefix: String? = nil) {
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
        guard isOnScreen, phase == .content else { return }
        SessionListAlerts.presentPendingError(&pendingError, from: self)
    }
}

// MARK: - Model

extension WorkspaceDetailViewController {
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

    /// A row that is not a session: a state, or an importable local session
    /// (disabled while one imports).
    enum Row: Equatable {
        case searching
        case noMatches(query: String)
        case empty
        case archiveLoading
        case local(LocalSession, isEnabled: Bool)
    }

    enum GroupToggle: Equatable {
        case stopped(groupID: String, isExpanded: Bool)
        case archive(WorkspaceSessionArchiveBucket)
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
}
