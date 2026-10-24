import UIKit

/// What the browser lists and searches with, and what a reader it opens
/// reads: the server's connection, the API client it lists with, the file
/// index it searches, the app navigation, and the review-comment scope of
/// the screen that shows it.
@MainActor
struct FileBrowserServices {
    let connection: ServerConnection
    let apiClient: APIClient?
    let fileIndexStore: FileIndexStore
    let navigation: AppNavigation
    let reviewCommentSelectionScope: ReviewCommentSelectionScope?

    func isSame(as other: Self) -> Bool {
        connection === other.connection
            && apiClient === other.apiClient
            && fileIndexStore === other.fileIndexStore
            && navigation === other.navigation
    }
}

/// The bar of the chat Files panel's All tab. The embedded browser cannot
/// reach that screen's bar, so the panel applies it.
struct FileBrowserEmbeddedChrome: Equatable {
    var title: String
    /// Back opens the parent folder.
    var canGoBack: Bool
    /// Forward opens the next folder down the trail Back left.
    var canGoForward: Bool
}

/// The keyed markdown viewport store the tree pane and pushed readers share,
/// so a file opened again comes back where it was read.
@MainActor
final class FileBrowserViewportRestore {
    var state = FullScreenMarkdownViewportRestoreState()
}

/// A workspace's files or the server's home folder (route `.fileBrowser`),
/// and the chat Files panel's All tab.
///
/// As a shell route the screen is gated: while its workspace (for the home
/// folder, its server) is locked it shows the lock cover and keeps none of
/// its content; unlocked, it switches to its server and shows "Connecting…"
/// until that server is ready. Compact width lists one folder, and each
/// folder deeper is its own route, so Back and the swipe pop folders.
/// Regular width shows the folder tree beside the open file, and folders
/// open in place. In the chat panel (`compactOnly`) folders open in place and
/// files push the reader onto the panel's stack.
///
/// The screen reads the lock service, the server's `FileIndexStore`, and
/// `AppNavigation` in `updateProperties()` and applies a diffable snapshot
/// keyed by entry path; state rows have fixed ids. The open file is a
/// `FileViewerViewController` from `FileBrowserViewerFactory`, a child whose
/// bar items show in this screen's bar.
@MainActor
final class FileBrowserViewController: UIViewController, UICollectionViewDelegate, UITextFieldDelegate {
    /// The split detail root carries the sidebar toggle.
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    /// The chat panel applies this to its bar.
    var onEmbeddedChromeChange: ((FileBrowserEmbeddedChrome) -> Void)?

    private let root: AppRootEnvironment
    private let serverId: String?
    private let scope: FileBrowserScope
    private let initialPath: String
    private let layoutMode: FileBrowserLayoutMode
    private let isShellRoute: Bool
    /// The column folder and file the content mounts with: the route's, kept
    /// current with what this screen records on it, so unlocking comes back
    /// to them.
    private var restoredDirectory: String?
    private var restoredSelection: FileBrowserSelection?
    private var navigation: AppNavigation { services?.navigation ?? root.navigation }

    /// The shell route's server stores once its server is ready; the panel's
    /// from the start.
    private var services: FileBrowserServices? {
        didSet { setNeedsUpdateProperties() }
    }
    private let embeddedNavigator: ScreenNavigator?
    private lazy var navigator: ScreenNavigator = embeddedNavigator ?? .forUIKitScreen(self, root: root)

    // Gate (shell route).
    private var phase: Phase?
    private var lockCover: ScopedLockCoverViewController?
    private var connectTask: Task<Void, Never>?

    // Content state, fresh each time the content mounts (after an unlock).
    private var state: ContentState {
        didSet { setNeedsUpdateProperties() }
    }
    private var loadTask: Task<Void, Never>?
    /// The content's appearance work ran (SwiftUI `.task`s); ends when the
    /// screen leaves or locks.
    private var contentIsLive = false
    /// Between `viewIsAppearing` and `viewDidDisappear`. A covered screen
    /// neither renders nor reacts, the way a hosted SwiftUI screen stops.
    private var isOnScreen = false
    private var hasAppeared = false
    private var searchedIndex: [String]?
    private let viewportRestore = FileBrowserViewportRestore()

    // Views.
    private let treeColumn = UIView()
    private let columnSearch = FileBrowserColumnSearchField()
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private let stateView = UIContentUnavailableView(configuration: .empty())
    private let refreshControl = UIRefreshControl()
    private let divider = UIView()
    private let dividerTint = UIView()
    private let paneContainer = UIView()
    private let paneEmpty = UIContentUnavailableView(configuration: .empty())
    private let search = ScreenSearchController(prompt: String(localized: "Search files"))
    private var searchInstalled = false
    private var listConstraints: [NSLayoutConstraint] = []
    private var columnConstraints: [NSLayoutConstraint] = []
    private var paneOnlyConstraints: [NSLayoutConstraint] = []
    private var collectionTopInList: NSLayoutConstraint?
    private var collectionTopInColumn: NSLayoutConstraint?
    private var appliedLayout: Layout?

    // The open file.
    private var paneViewer: FileViewerViewController?
    private var paneKey: PaneKey?

    // Snapshot and bar values.
    private var rows: [Item: Row] = [:]
    private var taps: [Item: Tap] = [:]
    private var overlay: Overlay?
    private var compactSearchHeader: String?
    private var snapshotScope: String?
    private var lastThemeID: ThemeID?
    private var appliedBars: BarState?
    private var sidebarToggle: UIBarButtonItem?
    private var lastChrome: FileBrowserEmbeddedChrome?

    /// The `.fileBrowser` shell route.
    init(root: AppRootEnvironment, target: FileBrowserNavTarget, showsSidebarToggle: Bool) {
        self.root = root
        serverId = target.serverId
        scope = target.scope
        initialPath = target.path
        layoutMode = .adaptive
        isShellRoute = true
        restoredDirectory = target.columnDirectoryPath
        restoredSelection = target.columnSelectedFile
        embeddedNavigator = nil
        self.showsSidebarToggle = showsSidebarToggle
        state = ContentState(treeDirectoryPath: target.columnDirectoryPath, selectedFile: target.columnSelectedFile)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
        // The search stays in the bar under the title, as the hosted screen's
        // did, not in a bottom toolbar over the list's last rows.
        navigationItem.searchBarPlacementAllowsToolbarIntegration = false
    }

    /// The chat Files panel's All tab: one compact list on the panel's server
    /// stores; files push onto the panel's stack through `navigator`.
    init(
        root: AppRootEnvironment,
        services: FileBrowserServices,
        navigator: ScreenNavigator,
        serverId: String?,
        scope: FileBrowserScope
    ) {
        self.root = root
        self.serverId = serverId
        self.scope = scope
        initialPath = ""
        layoutMode = .compactOnly
        isShellRoute = false
        restoredDirectory = nil
        restoredSelection = nil
        embeddedNavigator = navigator
        showsSidebarToggle = false
        state = ContentState()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        super.init(nibName: nil, bundle: nil)
        self.services = services
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        connectTask?.cancel()
        loadTask?.cancel()
    }

    // MARK: Embedding (chat panel)

    /// The panel re-rendered: its stores and its bar's search text.
    func updateEmbedding(services: FileBrowserServices, searchText: String) {
        self.services = services
        setSearchText(searchText)
    }

    /// The panel's Back: the parent folder.
    func showParentDirectory() {
        guard canGoBack else { return }
        popToBreadcrumbDepth(max(0, currentDepth - 1))
    }

    /// The panel's Forward: one folder deeper along the trail Back (or a
    /// breadcrumb) left.
    func showForwardDirectory() {
        guard let path = forwardDirectoryPath else { return }
        openDirectory(path: path)
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        // Pull-to-refresh needs the bounce even when the rows fit on screen.
        collectionView.alwaysBounceVertical = true
        collectionView.showsHorizontalScrollIndicator = false
        refreshControl.addAction(UIAction { [weak self] _ in self?.pullToRefresh() }, for: .valueChanged)
        stateView.isHidden = true

        columnSearch.textField.delegate = self
        columnSearch.textField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setSearchText(columnSearch.textField.text ?? "")
        }, for: .editingChanged)
        columnSearch.onClear = { [weak self] in self?.setSearchText("") }

        for subview in [treeColumn, divider, paneContainer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        dividerTint.translatesAutoresizingMaskIntoConstraints = false
        divider.addSubview(dividerTint)
        for subview in [columnSearch, collectionView, stateView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            treeColumn.addSubview(subview)
        }
        paneEmpty.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(paneEmpty)
        installConstraints()

        search.onTextChange = { [weak self] text in self?.setSearchText(text) }
        installDataSource()
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        // The server switch runs again each time the unlocked screen shows,
        // as the hosted gate's `.task(id:)` did.
        if let lockTarget, !ScopedLockService.shared.isLocked(lockTarget) {
            startConnectTask()
        }
        setNeedsUpdateProperties()
        updatePropertiesIfNeeded()
        if isShellRoute {
            navigationController?.setToolbarHidden(true, animated: animated)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if searchInstalled {
            search.hostDidAppear(self)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        hasAppeared = false
        connectTask?.cancel()
        connectTask = nil
        endContent()
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

        let isLocked = lockTarget.map { ScopedLockService.shared.isLocked($0) } ?? false
        // The sidebar toggle stays on the lock cover and "Connecting":
        // only the column Back belongs to the content.
        if isShellRoute {
            syncLeadingItems(showsColumnBack: !isLocked && services != nil && replacesStackBackButton)
        }
        if isLocked {
            show(.locked)
            return
        }
        guard let services else {
            show(.connecting)
            startConnectTask()
            return
        }
        show(.content)
        if !contentIsLive {
            beginContent(services)
        }

        // A query stays current with the file index under it.
        let index = services.fileIndexStore.paths
        if index != searchedIndex {
            searchedIndex = index
            if !trimmedQuery.isEmpty {
                performLocalSearch(query: trimmedQuery)
            }
        }
        let indexIsLoading = services.fileIndexStore.isLoading && index == nil

        let layout = currentLayout
        applyLayout(layout)
        applySnapshot(layout: layout, indexIsLoading: indexIsLoading, reconfigureAll: themeChanged)
        syncPane(layout: layout, services: services)
        syncBars(layout: layout)
    }

    private func applyTheme(_ palette: ThemePalette) {
        let background = UIColor(palette.bg)
        view.backgroundColor = background
        collectionView.backgroundColor = .clear
        divider.backgroundColor = .separator
        dividerTint.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.18)
        columnSearch.apply(palette)
        var empty = paneEmptyConfiguration()
        empty.background.backgroundColor = background
        paneEmpty.configuration = empty
        paneViewer?.view.backgroundColor = background
        overlay = nil
    }

    // MARK: Gate

    private var lockTarget: ScopedLockTarget? {
        guard isShellRoute, let serverId else { return nil }
        // Workspace files follow the workspace lock; the home folder the server's.
        switch scope {
        case .workspace(let workspaceId, _):
            return .workspace(serverId: serverId, workspaceId: workspaceId)
        case .hostHome:
            return .server(serverId)
        }
    }

    /// Locked: the cover alone. Connecting: "Connecting…". Content: the
    /// browser, its bars, and its search.
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
        if next == .locked, let lockTarget {
            // The content goes with the lock; unlocking connects again.
            connectTask?.cancel()
            connectTask = nil
            services = nil
            let cover = ScopedLockCoverViewController(target: lockTarget, title: String(localized: "Files"))
            embed(cover, in: view)
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
        let showsContent = next == .content
        treeColumn.isHidden = !showsContent
        divider.isHidden = !showsContent
        paneContainer.isHidden = !showsContent
        appliedLayout = nil
    }

    private func startConnectTask() {
        guard isShellRoute, connectTask == nil, isOnScreen, let serverId else { return }
        let coordinator = root.coordinator
        connectTask = Task { [weak self] in
            let ready = await coordinator.switchToServerReady(serverId)
            guard let self else { return }
            connectTask = nil
            guard ready, !Task.isCancelled else { return }
            if let lockTarget, ScopedLockService.shared.isLocked(lockTarget) { return }
            guard let connection = coordinator.connection(for: serverId) else { return }
            let next = FileBrowserServices(
                connection: connection,
                apiClient: connection.apiClient,
                fileIndexStore: connection.fileIndexStore,
                navigation: root.navigation,
                reviewCommentSelectionScope: nil
            )
            if let services, services.isSame(as: next) { return }
            services = next
            // Mount the content now rather than on the next update pass.
            updatePropertiesIfNeeded()
        }
    }

    /// SwiftUI `.task(id:)` and `.task`: list the folder, warm the index.
    private func beginContent(_ services: FileBrowserServices) {
        contentIsLive = true
        startDirectoryLoad()
        ensureFileIndex(services)
    }

    /// SwiftUI `onDisappear`: the tasks stop.
    private func endContent() {
        guard contentIsLive else { return }
        contentIsLive = false
        loadTask?.cancel()
        loadTask = nil
    }

    /// Everything the content mounted, and its state, like a torn-down
    /// SwiftUI view.
    private func tearDownContent() {
        endContent()
        uninstallSearch()
        state = ContentState(treeDirectoryPath: restoredDirectory, selectedFile: restoredSelection)
        searchedIndex = nil
        removePane()
        rows = [:]
        taps = [:]
        overlay = nil
        compactSearchHeader = nil
        snapshotScope = nil
        stateView.isHidden = true
        var empty = NSDiffableDataSourceSnapshot<Section, Item>()
        empty.deleteAllItems()
        dataSource?.apply(empty, animatingDifferences: false)
        navigationItem.title = nil
        navigationItem.hidesBackButton = false
    }

    private func embed(_ child: UIViewController, in container: UIView) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: container.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        child.didMove(toParent: self)
    }

    // MARK: Derived state

    private var isHostHome: Bool {
        if case .hostHome = scope { return true }
        return false
    }

    private var workspaceId: String {
        if case .workspace(let workspaceId, _) = scope { return workspaceId }
        return ""
    }

    private var worktreeId: String? {
        if case .workspace(_, let worktreeId) = scope { return worktreeId }
        return nil
    }

    private var currentDirectoryPath: String {
        state.treeDirectoryPath ?? initialPath
    }

    private var isRoot: Bool {
        currentDirectoryPath.isEmpty || currentDirectoryPath == "/"
    }

    private var usesInlineCompactNavigation: Bool {
        layoutMode == .compactOnly
    }

    /// A workspace shell route: folders and workspace files open as routes
    /// through `AppNavigation`. In the chat panel folders open in place and
    /// files push through the screen navigator.
    private var routesThroughShell: Bool {
        FileBrowserTreeNavigationReducer.shouldUseWorkspaceLinkedFileDestination(
            usesInlineCompactNavigation: usesInlineCompactNavigation,
            serverId: serverId
        )
    }

    private var showsColumn: Bool {
        FileBrowserColumnPolicy.showsColumn(
            layoutMode: layoutMode,
            horizontalSizeClass: traitCollection.horizontalSizeClass
        )
    }

    private var currentLayout: Layout {
        if showsColumn { return .column }
        return state.selectedFile == nil ? .list : .selectedFile
    }

    private var canGoBack: Bool {
        usesInlineCompactNavigation && !isRoot && state.selectedFile == nil
    }

    /// The trail's next folder below this one, while the trail runs deeper.
    private var forwardDirectoryPath: String? {
        guard usesInlineCompactNavigation, state.selectedFile == nil,
              let trail = state.forwardTrailPath,
              trail != currentDirectoryPath, trail.hasPrefix(currentDirectoryPath) else { return nil }
        return Self.directoryPrefix(of: trail, depth: currentDepth + 1)
    }

    private var trimmedQuery: String {
        state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !state.searchText.isEmpty
    }

    private func navTarget(path: String) -> FileBrowserNavTarget {
        FileBrowserNavTarget(serverId: serverId ?? "", scope: scope, path: path)
    }

    private var currentDepth: Int {
        navTarget(path: currentDirectoryPath).depth
    }

    private var columnBackAction: FileBrowserColumnBackAction {
        FileBrowserTreeNavigationReducer.columnBackAction(
            selectedFile: state.selectedFile,
            treeDirectoryPath: state.treeDirectoryPath,
            initialPath: initialPath,
            currentDirectoryPath: currentDirectoryPath
        )
    }

    private var replacesStackBackButton: Bool {
        guard !usesInlineCompactNavigation else { return false }
        if case .useStackBack = columnBackAction { return false }
        return true
    }

    private var usesInPlaceDirectoryNavigation: Bool {
        FileBrowserTreeNavigationReducer.usesInPlaceDirectoryNavigation(
            showsColumn: showsColumn,
            treeDirectoryPathIsSet: state.treeDirectoryPath != nil,
            usesInlineCompactNavigation: usesInlineCompactNavigation
        )
    }

    /// One bar for this screen: the open file, otherwise the folder.
    private var barTitle: String {
        if let selectedFile = state.selectedFile { return selectedFile.name }
        if isRoot { return scope.breadcrumbRootLabel }
        let trimmed = currentDirectoryPath.hasSuffix("/") ? String(currentDirectoryPath.dropLast()) : currentDirectoryPath
        return trimmed.split(separator: "/").last.map(String.init) ?? scope.breadcrumbRootLabel
    }

    private var contentSource: FileBrowserContentSource {
        isHostHome ? .hostFile : .workspaceFile
    }

    private func contentFilePath(_ relativePath: String) -> String {
        isHostHome ? FileBrowserHostHomePath.rawPath(relativePath: relativePath) : relativePath
    }

    private func directoryPath(for entry: FileEntry, relativeTo parentPath: String) -> String {
        if let path = entry.path {
            return path.hasSuffix("/") ? path : "\(path)/"
        }
        return parentPath.isEmpty ? "\(entry.name)/" : "\(parentPath)\(entry.name)/"
    }

    private func filePath(for entry: FileEntry, relativeTo parentPath: String) -> String {
        let relative = entry.path ?? (parentPath.isEmpty ? entry.name : "\(parentPath)\(entry.name)")
        return contentFilePath(relative)
    }

    private func listingNavigationContext(_ listing: DirectoryListingResponse) -> FileBrowserNavigationContext {
        FileBrowserNavigationContext(files: listing.entries.compactMap { entry in
            guard !entry.isDirectory else { return nil }
            return FileBrowserSelection(
                path: filePath(for: entry, relativeTo: currentDirectoryPath),
                name: entry.name,
                size: entry.size
            )
        })
    }

    private var searchNavigationContext: FileBrowserNavigationContext {
        FileBrowserNavigationContext(files: state.fuzzyResults.map { result in
            FileBrowserSelection(path: result.path, name: (result.path as NSString).lastPathComponent, size: nil)
        })
    }

    /// Previous/next for an opened file: the search results while searching,
    /// otherwise this folder's files.
    private var currentNavigationContext: FileBrowserNavigationContext? {
        if isSearching { return searchNavigationContext }
        return state.listing.map(listingNavigationContext)
    }

    // MARK: Loading

    private func startDirectoryLoad() {
        loadTask?.cancel()
        let path = currentDirectoryPath
        loadTask = Task { [weak self] in
            await self?.loadDirectory(path: path)
        }
    }

    private func loadDirectory(path: String) async {
        guard let api = services?.apiClient else {
            state.error = "Not connected"
            ClientLog.error("FileBrowser", "Directory load failed", metadata: [
                "workspaceId": workspaceId,
                "path": Self.safeDebugPath(path),
                "reason": "missing_api_client",
                "layoutMode": String(describing: layoutMode),
            ])
            return
        }
        do {
            let response: DirectoryListingResponse
            switch FileBrowserDirectoryRequest.make(scope: scope, path: path) {
            case .workspace(let workspaceId, let listingPath, let worktreeId):
                response = try await api.listWorkspaceDirectory(
                    workspaceId: workspaceId,
                    path: listingPath,
                    worktreeId: worktreeId
                )
            case .hostHome(let listingPath):
                response = try await api.listHostDirectory(path: listingPath)
            }
            guard !Task.isCancelled, path == currentDirectoryPath else { return }
            var next = state
            next.listing = response
            next.error = nil
            state = next
        } catch {
            guard !Task.isCancelled, path == currentDirectoryPath else { return }
            state.error = error.localizedDescription
            var metadata = ClientLog.networkErrorMetadata(error)
            metadata.merge([
                "workspaceId": workspaceId,
                "path": Self.safeDebugPath(path),
                "layoutMode": String(describing: layoutMode),
            ]) { current, _ in current }
            ClientLog.error("FileBrowser", "Directory load failed", metadata: metadata)
        }
    }

    private static func safeDebugPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<root>" }
        if trimmed.count <= 96 { return trimmed }
        return String(trimmed.prefix(93)) + "..."
    }

    private func ensureFileIndex(_ services: FileBrowserServices) {
        guard !isHostHome, let api = services.apiClient else { return }
        services.fileIndexStore.ensureLoaded(workspaceId: workspaceId, worktreeId: worktreeId, apiClient: api)
    }

    /// Lists the folder again; a workspace's file index reloads too.
    private func pullToRefresh() {
        Task { [weak self] in
            guard let self else { return }
            await loadDirectory(path: currentDirectoryPath)
            if !isHostHome, let services, let api = services.apiClient {
                services.fileIndexStore.invalidate()
                services.fileIndexStore.ensureLoaded(workspaceId: workspaceId, worktreeId: worktreeId, apiClient: api)
            }
            refreshControl.endRefreshing()
        }
    }

    // MARK: Search

    private func setSearchText(_ text: String) {
        guard state.searchText != text else { return }
        var next = state
        next.searchText = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            next.fuzzyResults = []
        }
        state = next
        if !trimmed.isEmpty {
            performLocalSearch(query: trimmed)
        }
    }

    /// Fuzzy match over the file index off the main thread; a result lands
    /// only while its query is still the current one.
    private func performLocalSearch(query: String) {
        guard let candidates = services?.fileIndexStore.paths else { return }
        Task { [weak self] in
            let results = await Task.detached {
                FuzzyMatch.search(query: query, candidates: candidates, limit: 100)
            }.value
            guard let self, trimmedQuery == query else { return }
            state.fuzzyResults = results
        }
    }

    private var searchResultCountText: String {
        let count = state.fuzzyResults.count
        if count >= 100 { return "100+ files" }
        return "\(count) file\(count == 1 ? "" : "s")"
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: Navigation

    private func openDirectory(path: String) {
        guard !usesInPlaceDirectoryNavigation else {
            showDirectoryInPlace(FileBrowserTreeNavigationReducer.openDirectory(path: path, selectedFile: state.selectedFile))
            return
        }
        state.selectedFile = nil
        guard let serverId, !serverId.isEmpty else {
            showDirectoryInPlace(FileBrowserTreeNavigationReducer.openDirectory(path: path, selectedFile: nil))
            return
        }
        pushDirectory(path: path)
    }

    /// The folder as its own file-browser route above this one.
    private func pushDirectory(path: String) {
        let target = navTarget(path: path)
        switch navigation.workspaceNavigationPresentation {
        case .stack:
            navigation.pushWorkspaceFileBrowser(target)
        case .split:
            navigation.pushSplitDetailFileBrowser(target)
        }
    }

    private func showDirectoryInPlace(_ mutation: FileBrowserTreeNavigationMutation) {
        var next = state
        if usesInlineCompactNavigation {
            // Moving up keeps the deepest folder for Forward; opening a folder
            // off that trail starts a new one.
            let path = mutation.treeDirectoryPath
            let trail = state.forwardTrailPath ?? currentDirectoryPath
            next.forwardTrailPath = trail.hasPrefix(path) ? trail : path
        }
        next.treeDirectoryPath = mutation.treeDirectoryPath
        next.selectedFile = mutation.selectedFile
        next.error = nil
        next.listing = nil
        state = next
        recordColumnRoute()
        if contentIsLive {
            startDirectoryLoad()
        }
    }

    private func popToBreadcrumbDepth(_ targetDepth: Int) {
        let popCount = currentDepth - targetDepth
        guard popCount > 0 else { return }
        guard !usesInPlaceDirectoryNavigation else {
            showDirectoryInPlace(FileBrowserTreeNavigationReducer.popToBreadcrumb(
                path: breadcrumbPath(for: targetDepth),
                selectedFile: state.selectedFile
            ))
            return
        }
        switch navigation.workspaceNavigationPresentation {
        case .stack:
            let depth = navigation.workspaceStackRouteElements.count
            guard depth >= popCount else { return }
            navigation.popWorkspaceStack(toDepth: depth - popCount)
        case .split:
            let depth = navigation.splitDetailPathElements.count
            guard depth >= popCount else { return }
            navigation.popSplitDetail(toDepth: depth - popCount)
        }
    }

    private func breadcrumbPath(for depth: Int) -> String {
        Self.directoryPrefix(of: currentDirectoryPath, depth: depth)
    }

    /// The folder `depth` segments into `path`: "" for the root, else "a/b/".
    private static func directoryPrefix(of path: String, depth: Int) -> String {
        guard depth > 0 else { return "" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/").prefix(depth).map(String.init)
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "/") + "/"
    }

    private func performColumnBack() {
        switch columnBackAction {
        case .clearSelectedFile:
            selectFile(nil)
        case .popToDirectory(let path):
            showDirectoryInPlace(FileBrowserTreeNavigationReducer.popToBreadcrumb(
                path: path,
                selectedFile: state.selectedFile
            ))
        case .useStackBack:
            break
        }
    }

    private func selectFile(_ selection: FileBrowserSelection?) {
        guard state.selectedFile != selection else { return }
        state.selectedFile = selection
        recordColumnRoute()
    }

    /// Keeps the column's folder and file on this route, so a stack/split
    /// swap rebuilds them.
    private func recordColumnRoute() {
        guard layoutMode == .adaptive, let serverId else { return }
        guard state.didRecordColumnRoute || state.treeDirectoryPath != nil || state.selectedFile != nil else { return }
        state.didRecordColumnRoute = true
        // What the route now holds is where an unlock comes back to.
        restoredDirectory = currentDirectoryPath
        restoredSelection = state.selectedFile
        navigation.recordFileBrowserColumn(
            serverId: serverId,
            scope: scope,
            routePath: initialPath,
            directoryPath: currentDirectoryPath,
            selectedFile: state.selectedFile
        )
    }

    /// A compact file row: a workspace file on the shell opens its linked
    /// file route; host files and the chat panel's files push the reader.
    private func openCompactFile(_ selection: FileBrowserSelection, context: FileBrowserNavigationContext?) {
        if routesThroughShell, let serverId, case .workspace(let workspaceId, let worktreeId) = scope {
            navigation.openWorkspaceLinkedFile(.workspaceFile(
                serverId: serverId,
                workspaceId: workspaceId,
                worktreeId: worktreeId,
                path: selection.path,
                fileName: selection.name,
                navigationContext: context
            ))
            return
        }
        guard let services else { return }
        FileBrowserViewerFactory.pushReader(readerRequest(selection, context: context, services: services), navigator: navigator)
    }

    private func readerRequest(
        _ selection: FileBrowserSelection,
        context: FileBrowserNavigationContext?,
        services: FileBrowserServices
    ) -> FileBrowserViewerFactory.Request {
        FileBrowserViewerFactory.Request(
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            serverId: serverId,
            source: contentSource,
            selection: selection,
            navigationContext: context,
            services: services,
            viewportRestore: viewportRestore
        )
    }

    // MARK: Layout

    private func installConstraints() {
        let safe = view.safeAreaLayoutGuide
        let treeWidth = treeColumn.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5, constant: -0.5)
        treeWidth.priority = .defaultHigh
        let hairline = 1 / max(1, traitCollection.displayScale)
        NSLayoutConstraint.activate([
            treeColumn.topAnchor.constraint(equalTo: view.topAnchor),
            treeColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            treeColumn.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            columnSearch.topAnchor.constraint(equalTo: treeColumn.safeAreaLayoutGuide.topAnchor),
            columnSearch.leadingAnchor.constraint(equalTo: treeColumn.leadingAnchor),
            columnSearch.trailingAnchor.constraint(equalTo: treeColumn.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: treeColumn.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: treeColumn.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: treeColumn.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: collectionView.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            dividerTint.topAnchor.constraint(equalTo: divider.topAnchor),
            dividerTint.bottomAnchor.constraint(equalTo: divider.bottomAnchor),
            dividerTint.leadingAnchor.constraint(equalTo: divider.leadingAnchor),
            dividerTint.trailingAnchor.constraint(equalTo: divider.trailingAnchor),
            paneEmpty.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            paneEmpty.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
            paneEmpty.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            paneEmpty.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
        ])
        collectionTopInList = collectionView.topAnchor.constraint(equalTo: treeColumn.topAnchor)
        collectionTopInColumn = collectionView.topAnchor.constraint(equalTo: columnSearch.bottomAnchor)
        listConstraints = [
            treeColumn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]
        columnConstraints = [
            treeWidth,
            treeColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            treeColumn.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            divider.leadingAnchor.constraint(equalTo: treeColumn.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: hairline),
            divider.topAnchor.constraint(equalTo: safe.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneContainer.topAnchor.constraint(equalTo: view.topAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        paneOnlyConstraints = [
            treeColumn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneContainer.topAnchor.constraint(equalTo: view.topAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        // Until the content shows, the list's layout keeps the views defined.
        NSLayoutConstraint.activate(listConstraints + paneOnlyConstraints.dropFirst())
        collectionTopInList?.isActive = true
    }

    private func applyLayout(_ layout: Layout) {
        guard appliedLayout != layout else { return }
        let previous = appliedLayout
        appliedLayout = layout
        NSLayoutConstraint.deactivate(listConstraints + columnConstraints + paneOnlyConstraints)
        let column = layout == .column
        switch layout {
        case .list: NSLayoutConstraint.activate(listConstraints)
        case .column: NSLayoutConstraint.activate(columnConstraints)
        case .selectedFile: NSLayoutConstraint.activate(paneOnlyConstraints)
        }
        treeColumn.accessibilityIdentifier = column ? "fileBrowser.tree" : nil
        // The tree searches in its own field (workspace files only).
        let showsSearchField = column && !isHostHome
        columnSearch.isHidden = !showsSearchField
        collectionTopInList?.isActive = false
        collectionTopInColumn?.isActive = showsSearchField
        collectionTopInList?.isActive = !showsSearchField
        treeColumn.isHidden = layout == .selectedFile
        divider.isHidden = !column
        paneContainer.isHidden = layout == .list
        paneEmpty.isHidden = true
        if !column, columnSearch.textField.isFirstResponder {
            columnSearch.textField.resignFirstResponder()
        }
        // Rows and spacing differ between the list and the tree.
        if previous == nil || (previous == .column) != column {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    // MARK: Snapshot

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self else { return nil }
            let section = dataSource?.sectionIdentifier(for: index) ?? .body
            let column = appliedLayout == .column
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.backgroundColor = .clear
            configuration.showsSeparators = !column && section == .body
            if !column, section == .body, compactSearchHeader != nil {
                configuration.headerMode = .supplementary
            }
            let layoutSection = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            if column {
                layoutSection.interGroupSpacing = 4
                layoutSection.contentInsets = switch section {
                case .header: NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
                case .body: NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0)
                case .footer: NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
                }
            }
            return layoutSection
        }
    }

    private func installDataSource() {
        // Each row kind reuses its own cells: a list content view whose
        // secondary text goes away keeps the old label for XCUITest, so a
        // folder row must never reuse a file row's cell.
        let registration = { [weak self] (cell: UICollectionViewListCell, _: IndexPath, item: Item) in
            guard let self, let row = rows[item] else { return }
            configure(cell, row: row)
        }
        let folderCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item>(handler: registration)
        let fileCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item>(handler: registration)
        let resultCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item>(handler: registration)
        let noteCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item>(handler: registration)
        let breadcrumbCell = UICollectionView.CellRegistration<FileBrowserBreadcrumbCell, Item> { [weak self] cell, _, item in
            guard let self, case .breadcrumb(let segments, let depth, let column)? = rows[item] else { return }
            cell.configure(
                segments: segments,
                currentDepth: depth,
                insets: column
                    ? NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 6, trailing: 6)
                    : NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16),
                palette: palette
            ) { [weak self] depth in
                self?.popToBreadcrumbDepth(depth)
            }
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .breadcrumb:
                return collectionView.dequeueConfiguredReusableCell(using: breadcrumbCell, for: indexPath, item: item)
            case .directory:
                return collectionView.dequeueConfiguredReusableCell(using: folderCell, for: indexPath, item: item)
            case .file:
                return collectionView.dequeueConfiguredReusableCell(using: fileCell, for: indexPath, item: item)
            case .result:
                return collectionView.dequeueConfiguredReusableCell(using: resultCell, for: indexPath, item: item)
            case .searchCount, .emptyDirectory, .truncated:
                return collectionView.dequeueConfiguredReusableCell(using: noteCell, for: indexPath, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, _ in
            self?.configureSearchHeader(view)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        self.dataSource = dataSource
    }

    private var palette: ThemePalette {
        (lastThemeID ?? root.themeStore.activeThemeID).palette
    }

    /// The result count over the list's search results.
    private func configureSearchHeader(_ view: UICollectionViewListCell) {
        var content = UIListContentConfiguration.header()
        content.text = compactSearchHeader
        content.textProperties.font = UIFont.scaled(.caption2, monospacedDigits: true)
        content.textProperties.color = UIColor(palette.comment)
        content.textProperties.transform = .none
        view.contentConfiguration = content
        var background = UIBackgroundConfiguration.listHeader()
        background.backgroundColor = UIColor(palette.bg)
        view.backgroundConfiguration = background
    }

    private func refreshSearchHeader() {
        let kind = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                as? UICollectionViewListCell else { continue }
            configureSearchHeader(view)
        }
    }

    private func applySnapshot(layout: Layout, indexIsLoading: Bool, reconfigureAll: Bool) {
        guard let dataSource, layout != .selectedFile else { return }
        let column = layout == .column
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        var nextRows: [Item: Row] = [:]
        var nextTaps: [Item: Tap] = [:]
        var nextOverlay: Overlay?
        var nextHeader: String?
        let selectedPath = column ? state.selectedFile?.path : nil

        func append(_ items: [Item], to section: Section) {
            guard !items.isEmpty else { return }
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }

        if isSearching {
            if indexIsLoading {
                nextOverlay = .indexLoading
            } else if state.fuzzyResults.isEmpty {
                nextOverlay = .noResults(state.searchText)
            } else {
                let context = searchNavigationContext
                if column {
                    nextRows[.searchCount] = .searchCount(searchResultCountText)
                    append([.searchCount], to: .header)
                } else {
                    nextHeader = searchResultCountText
                }
                var items: [Item] = []
                for result in state.fuzzyResults {
                    let item = Item.result(result.path)
                    guard nextRows[item] == nil else { continue }
                    let name = (result.path as NSString).lastPathComponent
                    let directory = (result.path as NSString).deletingLastPathComponent
                    nextRows[item] = .result(ResultRow(
                        name: name,
                        directory: directory.isEmpty ? nil : directory + "/",
                        highlights: Self.fileNameHighlights(fileName: name, fullPath: result.path, positions: result.positions),
                        column: column,
                        isSelected: selectedPath == result.path
                    ))
                    nextTaps[item] = .file(FileBrowserSelection(path: result.path, name: name, size: nil), context)
                    items.append(item)
                }
                append(items, to: .body)
            }
        } else if let listing = state.listing {
            if listing.entries.isEmpty, !column {
                nextOverlay = .empty
            } else {
                if !isRoot {
                    let segments = navTarget(path: currentDirectoryPath).breadcrumbSegments.map {
                        FileBrowserBreadcrumbCell.Segment(label: $0.label, depth: $0.depth)
                    }
                    nextRows[.breadcrumb] = .breadcrumb(segments: segments, depth: currentDepth, column: column)
                    append([.breadcrumb], to: .header)
                }
                if listing.entries.isEmpty {
                    nextRows[.emptyDirectory] = .emptyDirectory
                    append([.emptyDirectory], to: .body)
                } else {
                    let context = listingNavigationContext(listing)
                    var items: [Item] = []
                    for entry in listing.entries {
                        if entry.isDirectory {
                            let path = directoryPath(for: entry, relativeTo: currentDirectoryPath)
                            let item = Item.directory(path)
                            guard nextRows[item] == nil else { continue }
                            nextRows[item] = .directory(name: entry.name, showsChevron: column || routesThroughShell, column: column)
                            nextTaps[item] = .directory(path)
                            items.append(item)
                        } else {
                            let path = filePath(for: entry, relativeTo: currentDirectoryPath)
                            let item = Item.file(path)
                            guard nextRows[item] == nil else { continue }
                            nextRows[item] = .file(FileRow(
                                name: entry.name,
                                size: entry.formattedSize,
                                modified: entry.relativeModifiedTime,
                                isRecent: entry.isRecentlyModified,
                                column: column,
                                isSelected: selectedPath == path
                            ))
                            nextTaps[item] = .file(FileBrowserSelection(path: path, name: entry.name, size: entry.size), context)
                            items.append(item)
                        }
                    }
                    append(items, to: .body)
                }
                if listing.truncated {
                    nextRows[.truncated] = .truncated(listing.entries.count)
                    append([.truncated], to: .footer)
                }
            }
        } else if let error = state.error {
            nextOverlay = .error(error)
        } else {
            nextOverlay = .loading
        }

        let headerChanged = nextHeader != compactSearchHeader
        if (nextHeader == nil) != (compactSearchHeader == nil) {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        compactSearchHeader = nextHeader
        syncOverlay(nextOverlay)

        let current = Set(dataSource.snapshot().itemIdentifiers)
        let changed = snapshot.itemIdentifiers.filter { item in
            current.contains(item) && (reconfigureAll || rows[item] != nextRows[item])
        }
        rows = nextRows
        taps = nextTaps
        snapshot.reconfigureItems(changed)

        // Rows animate only within one folder or one search; a new folder or
        // a new search replaces them.
        let scopeKey = "\(column):\(isSearching):\(currentDirectoryPath)"
        let animated = snapshotScope == scopeKey && view.window != nil
        snapshotScope = scopeKey
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            if headerChanged || reconfigureAll { self?.refreshSearchHeader() }
        }
        let showsRows = nextOverlay == nil
        if showsRows, collectionView.refreshControl == nil {
            collectionView.refreshControl = refreshControl
        } else if !showsRows, collectionView.refreshControl != nil, !refreshControl.isRefreshing {
            collectionView.refreshControl = nil
        }
    }

    /// Loading, failed, empty, and search states fill the list, as the
    /// SwiftUI screen's did outside its list.
    private func syncOverlay(_ next: Overlay?) {
        guard next != overlay else { return }
        overlay = next
        guard let next else {
            stateView.isHidden = true
            return
        }
        var configuration: UIContentUnavailableConfiguration
        switch next {
        case .loading:
            configuration = .loading()
            configuration.text = nil
        case .indexLoading:
            configuration = .loading()
            configuration.text = String(localized: "Loading file index...")
        case .noResults(let query):
            configuration = .search()
            configuration.text = String(localized: "No Results for “\(query)”")
        case .error(let message):
            configuration = .empty()
            configuration.image = UIImage(systemName: "exclamationmark.triangle")
            configuration.text = String(localized: "Unable to Load")
            configuration.secondaryText = message
        case .empty:
            configuration = emptyDirectoryConfiguration()
        }
        configuration.background.backgroundColor = UIColor(palette.bg)
        stateView.configuration = configuration
        stateView.isHidden = false
    }

    private func emptyDirectoryConfiguration() -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "folder")
        configuration.text = String(localized: "Empty Directory")
        configuration.secondaryText = String(localized: "No files in this directory.")
        return configuration
    }

    private func paneEmptyConfiguration() -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "doc.text.magnifyingglass")
        configuration.text = String(localized: "Select a File")
        configuration.secondaryText = String(localized: "Choose a file from the tree.")
        return configuration
    }

    // MARK: Cells

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        let palette = palette
        let comment = UIColor(palette.comment)
        let fg = UIColor(palette.fg)
        cell.accessories = []
        // The tappable rows set this; state rows read as their text.
        var element: (label: String, isSelected: Bool)?
        defer { exposeRow(cell, as: element) }
        switch row {
        case .breadcrumb:
            return
        case .searchCount(let text):
            var content = UIListContentConfiguration.cell()
            content.text = text
            content.textProperties.font = UIFont.scaled(.caption2, monospacedDigits: true)
            content.textProperties.color = comment
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8)
            cell.contentConfiguration = content
            applyPlainBackground(to: cell)
        case .emptyDirectory:
            // At least the SwiftUI view's 220 pt under the breadcrumb.
            var content = emptyDirectoryConfiguration()
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 50, leading: 16, bottom: 50, trailing: 16)
            cell.contentConfiguration = content
            applyPlainBackground(to: cell)
        case .truncated(let count):
            var content = UIListContentConfiguration.cell()
            content.text = "Showing first \(count) entries"
            content.textProperties.font = UIFont.preferredFont(forTextStyle: .caption1)
            content.textProperties.color = comment
            if appliedLayout == .column {
                content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 0, trailing: 8)
            }
            cell.contentConfiguration = content
            applyPlainBackground(to: cell)
        case .directory(let name, let showsChevron, let column):
            if column {
                configureTreeRow(
                    cell,
                    image: Self.treeSymbol("folder.fill"),
                    tint: UIColor(palette.blue),
                    title: NSAttributedString(string: name, attributes: [.font: Self.font(.callout, .regular), .foregroundColor: fg]),
                    subtitle: nil,
                    trailingText: nil,
                    trailingColor: comment,
                    showsChevron: true,
                    isSelected: false
                )
            } else {
                var content = UIListContentConfiguration.cell()
                content.image = UIImage(systemName: "folder.fill")
                content.imageProperties.tintColor = UIColor(palette.blue)
                content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
                content.text = name
                content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
                content.textProperties.color = fg
                content.textProperties.numberOfLines = 1
                cell.contentConfiguration = content
                if showsChevron {
                    cell.accessories = [.disclosureIndicator()]
                }
                applyListBackground(to: cell)
            }
            element = (name, false)
        case .file(let file):
            let icon = FileIcon.forPath(file.name)
            let trailingColor = file.isRecent ? UIColor(palette.green) : comment
            if file.column {
                configureTreeRow(
                    cell,
                    image: Self.treeSymbol(icon.symbolName),
                    tint: comment,
                    title: NSAttributedString(
                        string: file.name,
                        attributes: [.font: Self.font(.callout, file.isSelected ? .semibold : .regular), .foregroundColor: fg]
                    ),
                    subtitle: file.size.isEmpty ? nil : file.size,
                    trailingText: file.modified,
                    trailingColor: trailingColor,
                    showsChevron: false,
                    isSelected: file.isSelected
                )
            } else {
                var content = UIListContentConfiguration.subtitleCell()
                setListIcon(icon, on: &content)
                content.text = file.name
                content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
                content.textProperties.color = fg
                content.textProperties.numberOfLines = 1
                content.secondaryText = file.size
                content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .caption2)
                content.secondaryTextProperties.color = comment
                content.textToSecondaryTextVerticalPadding = 2
                cell.contentConfiguration = content
                cell.accessories = [
                    .label(text: file.modified, options: .init(tintColor: trailingColor, font: UIFont.preferredFont(forTextStyle: .caption2))),
                    .disclosureIndicator(),
                ]
                applyListBackground(to: cell)
            }
            element = ([file.name, file.size, file.modified].filter { !$0.isEmpty }.joined(separator: ", "), file.isSelected)
        case .result(let result):
            let icon = FileIcon.forPath(result.name)
            let title = Self.highlightedName(result, palette: palette)
            if result.column {
                configureTreeRow(
                    cell,
                    image: Self.treeSymbol(icon.symbolName),
                    tint: comment,
                    title: title,
                    subtitle: result.directory,
                    trailingText: nil,
                    trailingColor: comment,
                    showsChevron: false,
                    isSelected: result.isSelected
                )
            } else {
                var content = UIListContentConfiguration.subtitleCell()
                setListIcon(icon, on: &content)
                content.attributedText = title
                content.textProperties.numberOfLines = 1
                content.secondaryText = result.directory
                content.secondaryTextProperties.font = UIFont.scaledMonospaced(.caption2)
                content.secondaryTextProperties.color = comment
                content.secondaryTextProperties.numberOfLines = 1
                content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
                content.textToSecondaryTextVerticalPadding = 2
                cell.contentConfiguration = content
                cell.accessories = [.disclosureIndicator()]
                applyListBackground(to: cell)
            }
            element = ([result.name, result.directory].compactMap { $0 }.joined(separator: ", "), result.isSelected)
        }
    }

    /// A tappable row's one accessibility element is its content, typed a
    /// button with the row's texts as its label, as the SwiftUI rows were.
    /// Runs after the content configuration: a list cell makes itself the
    /// element once it has content. Every field is set on reuse.
    private func exposeRow(_ cell: UICollectionViewListCell, as element: (label: String, isSelected: Bool)?) {
        let content = cell.contentView
        cell.isAccessibilityElement = false
        guard let element else {
            content.isAccessibilityElement = false
            content.accessibilityTraits = .none
            content.accessibilityLabel = nil
            cell.accessibilityElements = nil
            return
        }
        content.isAccessibilityElement = true
        content.accessibilityTraits = element.isSelected ? [.button, .selected] : .button
        content.accessibilityLabel = element.label
        cell.accessibilityElements = [content]
    }

    private func setListIcon(_ icon: FileIcon, on content: inout UIListContentConfiguration) {
        content.image = icon.uiImage(pointSize: 12)
        content.imageProperties.tintColor = UIColor(icon.color)
        content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
        content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
    }

    /// A row of the tree column: icon, name over its detail, trailing time,
    /// and the selected file's rounded wash.
    private func configureTreeRow(
        _ cell: UICollectionViewListCell,
        image: UIImage?,
        tint: UIColor,
        title: NSAttributedString,
        subtitle: String?,
        trailingText: String?,
        trailingColor: UIColor,
        showsChevron: Bool,
        isSelected: Bool
    ) {
        let palette = palette
        let blue = UIColor(palette.blue)
        let comment = UIColor(palette.comment)
        var content = UIListContentConfiguration.subtitleCell()
        content.image = image
        content.imageProperties.tintColor = isSelected ? blue : tint
        content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
        content.imageToTextPadding = 10
        content.attributedText = title
        content.textProperties.numberOfLines = 1
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.secondaryText = subtitle
        content.secondaryTextProperties.font = UIFont.scaledMonospaced(.caption2)
        content.secondaryTextProperties.color = comment
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        content.textToSecondaryTextVerticalPadding = 2
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        cell.contentConfiguration = content
        var accessories: [UICellAccessory] = []
        if let trailingText {
            accessories.append(.label(
                text: trailingText,
                options: .init(tintColor: trailingColor, font: UIFont.preferredFont(forTextStyle: .caption2))
            ))
        }
        if showsChevron {
            let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
            chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Self.font(.caption2, .bold))
            chevron.tintColor = comment.withAlphaComponent(0.7)
            accessories.append(.customView(configuration: .init(customView: chevron, placement: .trailing())))
        }
        cell.accessories = accessories
        let fill = blue.withAlphaComponent(0.16)
        let stroke = blue.withAlphaComponent(0.36)
        let pressed = UIColor(palette.fg).withAlphaComponent(0.06)
        cell.configurationUpdateHandler = { cell, cellState in
            var background = UIBackgroundConfiguration.clear()
            background.cornerRadius = 14
            if isSelected {
                background.backgroundColor = fill
                background.strokeColor = stroke
                background.strokeWidth = 1
            } else if cellState.isHighlighted {
                background.backgroundColor = pressed
            }
            cell.backgroundConfiguration = background
        }
    }

    /// The list's theme page; a touched row shows the system highlight.
    private func applyListBackground(to cell: UICollectionViewListCell) {
        let page = UIColor(palette.bg)
        cell.configurationUpdateHandler = { cell, cellState in
            var background = UIBackgroundConfiguration.listCell().updated(for: cellState)
            if !cellState.isHighlighted, !cellState.isSelected {
                background.backgroundColor = page
            }
            cell.backgroundConfiguration = background
        }
    }

    private func applyPlainBackground(to cell: UICollectionViewListCell) {
        cell.configurationUpdateHandler = { cell, _ in
            cell.backgroundConfiguration = .clear()
        }
    }

    private static func highlightedName(_ result: ResultRow, palette: ThemePalette) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor(palette.fg),
        ]
        let matched: [NSAttributedString.Key: Any] = [
            .font: font(.body, .bold),
            .foregroundColor: UIColor(palette.yellow),
        ]
        for run in result.highlights {
            text.append(NSAttributedString(string: run.text, attributes: run.isMatch ? matched : plain))
        }
        return text
    }

    /// The file name split into matched and unmatched runs. Match positions
    /// index the full path's unicode scalars; only the name's are shown.
    private static func fileNameHighlights(fileName: String, fullPath: String, positions: [Int]) -> [HighlightRun] {
        let nameScalars = Array(fileName.unicodeScalars)
        let nameStart = fullPath.unicodeScalars.count - nameScalars.count
        let matches = Set(positions.filter { $0 >= nameStart }.map { $0 - nameStart })
        var runs: [HighlightRun] = []
        var index = 0
        while index < nameScalars.count {
            let isMatch = matches.contains(index)
            var end = index
            while end + 1 < nameScalars.count, matches.contains(end + 1) == isMatch {
                end += 1
            }
            runs.append(HighlightRun(
                text: String(String.UnicodeScalarView(nameScalars[index...end])),
                isMatch: isMatch
            ))
            index = end + 1
        }
        return runs
    }

    private static func treeSymbol(_ name: String) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(font: font(.body, .semibold))
        )
    }

    private static func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
        FileBrowserBreadcrumbCell.font(style, weight)
    }

    // MARK: Selection

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return false }
        return taps[item] != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath), let tap = taps[item] else { return }
        switch tap {
        case .directory(let path):
            // A shell route's list row always pushes the folder as a route;
            // the tree and the chat panel open it in place.
            if currentLayout == .list, routesThroughShell {
                pushDirectory(path: path)
            } else {
                openDirectory(path: path)
            }
        case .file(let selection, let context):
            if showsColumn {
                selectFile(selection)
            } else {
                openCompactFile(selection, context: context)
            }
        }
    }

    // MARK: The open file

    /// The tree-pane viewer beside the tree, or alone for a selection kept
    /// in compact width. "Select a File" fills an empty column pane. Another
    /// selection on the same server shows in the same viewer, so its
    /// previous/next slide and editing state carry over.
    private func syncPane(layout: Layout, services: FileBrowserServices) {
        guard layout != .list, let selection = state.selectedFile else {
            removePane()
            paneEmpty.isHidden = layout != .column
            return
        }
        paneEmpty.isHidden = true
        let context = currentNavigationContext
        let key = PaneKey(
            selection: selection,
            context: context,
            connection: ObjectIdentifier(services.connection),
            apiClient: services.apiClient.map(ObjectIdentifier.init)
        )
        guard key != paneKey else { return }
        if let paneViewer, let paneKey,
           paneKey.connection == key.connection, paneKey.apiClient == key.apiClient {
            self.paneKey = key
            paneViewer.show(selection, navigationContext: context)
            return
        }
        removePane()
        paneKey = key
        let viewer = FileBrowserViewerFactory.make(
            readerRequest(selection, context: context, services: services),
            onSelectionChange: { [weak self] selection in self?.selectFile(selection) },
            onBack: { [weak self] in self?.selectFile(nil) }
        )
        viewer.view.backgroundColor = UIColor(palette.bg)
        embed(viewer, in: paneContainer)
        paneViewer = viewer
    }

    private func removePane() {
        paneKey = nil
        guard let paneViewer else { return }
        paneViewer.willMove(toParent: nil)
        paneViewer.view.removeFromSuperview()
        paneViewer.removeFromParent()
        self.paneViewer = nil
        // The file's Edit, status, Preview, and Done go with it. Locking and
        // "Connecting" tear the content down without the bar sync that
        // otherwise follows.
        navigationItem.rightBarButtonItems = nil
    }

    // MARK: Bars

    private func syncBars(layout: Layout) {
        let title = barTitle
        guard isShellRoute else {
            let chrome = FileBrowserEmbeddedChrome(
                title: title,
                canGoBack: canGoBack,
                canGoForward: forwardDirectoryPath != nil
            )
            if chrome != lastChrome {
                lastChrome = chrome
                onEmbeddedChromeChange?(chrome)
            }
            return
        }
        navigationItem.title = title
        navigationItem.hidesBackButton = replacesStackBackButton

        // The open file's own items (Edit, the editor's status, Preview, and
        // Done) join this screen's bar.
        let fileItems = paneViewer?.bar.trailingItems ?? []
        if !(navigationItem.rightBarButtonItems ?? []).elementsEqual(fileItems, by: ===) {
            navigationItem.rightBarButtonItems = fileItems
        }

        // The bar's search lists files in place of the folder; the column
        // searches in its own field.
        if layout == .list, !isHostHome {
            installSearch()
            search.searchController.hidesNavigationBarDuringPresentation = UIDevice.current.userInterfaceIdiom != .pad
            search.setText(state.searchText)
        } else {
            uninstallSearch()
        }
        columnSearch.setText(state.searchText)
    }

    /// The split detail root's sidebar toggle in every phase, then the
    /// column Back while the content shows.
    private func syncLeadingItems(showsColumnBack: Bool) {
        let bars = BarState(
            showsSidebarToggle: showsSidebarToggle,
            showsColumnBack: showsColumnBack,
            themeID: root.themeStore.activeThemeID
        )
        if bars != appliedBars {
            appliedBars = bars
            installBarItems(bars)
        }
        if let sidebarToggle {
            WorkspaceSplitSidebarToggle.sync(sidebarToggle, root: root)
        }
    }

    private func installBarItems(_ bars: BarState) {
        sidebarToggle = bars.showsSidebarToggle ? WorkspaceSplitSidebarToggle.makeItem(root: root) : nil
        var leading: [UIBarButtonItem] = sidebarToggle.map { [$0] } ?? []
        if bars.showsColumnBack {
            let back = UIBarButtonItem(
                title: String(localized: "Back"),
                image: UIImage(systemName: "chevron.left"),
                primaryAction: UIAction { [weak self] _ in self?.performColumnBack() }
            )
            back.accessibilityIdentifier = "fileBrowser.columnBack"
            leading.append(SessionListBarItems.horizontalOnly(back))
        }
        navigationItem.leadingItemGroups = leading.isEmpty
            ? [] : [UIBarButtonItemGroup(barButtonItems: leading, representativeItem: nil)]
    }

    private func installSearch() {
        guard !searchInstalled else { return }
        searchInstalled = true
        search.install(on: self, alwaysVisible: true)
        if hasAppeared {
            search.hostDidAppear(self)
        }
    }

    private func uninstallSearch() {
        guard searchInstalled else { return }
        searchInstalled = false
        search.uninstall(from: self)
    }
}

#if DEBUG
extension FileBrowserViewController {
    /// The viewer a file row pushes (`FileBrowserViewerFactory.pushReader`),
    /// on this browser's server stores.
    func debugPushedReaderForTesting(path: String, name: String, size: Int?) -> FileViewerViewController.Configuration? {
        guard let services else { return nil }
        return FileBrowserViewerFactory.configuration(
            readerRequest(FileBrowserSelection(path: path, name: name, size: size), context: nil, services: services),
            chromeMode: .pushed
        )
    }
}
#endif

// MARK: - Model

private extension FileBrowserViewController {
    enum Phase: Equatable {
        case locked
        case connecting
        case content
    }

    enum Layout: Equatable {
        /// One folder's list (compact width, the chat panel).
        case list
        /// The tree beside the open file (regular width).
        case column
        /// The open file alone: a column selection kept in compact width or
        /// across a stack/split swap.
        case selectedFile
    }

    struct ContentState {
        var listing: DirectoryListingResponse?
        var error: String?
        var searchText = ""
        var fuzzyResults: [FuzzyMatch.ScoredPath] = []
        var treeDirectoryPath: String?
        var selectedFile: FileBrowserSelection?
        var didRecordColumnRoute = false
        /// The chat panel's deepest folder on the current branch, where
        /// Forward leads back to.
        var forwardTrailPath: String?
    }

    enum Section: Hashable {
        /// The breadcrumb, or the tree's search result count.
        case header
        case body
        /// "Showing first N entries".
        case footer
    }

    /// Entries key by path (folders end in "/"); state rows have fixed ids.
    enum Item: Hashable {
        case breadcrumb
        case searchCount
        case directory(String)
        case file(String)
        case result(String)
        case emptyDirectory
        case truncated
    }

    struct FileRow: Equatable {
        let name: String
        let size: String
        let modified: String
        let isRecent: Bool
        let column: Bool
        let isSelected: Bool
    }

    struct HighlightRun: Equatable {
        let text: String
        let isMatch: Bool
    }

    struct ResultRow: Equatable {
        let name: String
        let directory: String?
        let highlights: [HighlightRun]
        let column: Bool
        let isSelected: Bool
    }

    enum Row: Equatable {
        case breadcrumb(segments: [FileBrowserBreadcrumbCell.Segment], depth: Int, column: Bool)
        case searchCount(String)
        case directory(name: String, showsChevron: Bool, column: Bool)
        case file(FileRow)
        case result(ResultRow)
        case emptyDirectory
        case truncated(Int)
    }

    enum Tap {
        case directory(String)
        case file(FileBrowserSelection, FileBrowserNavigationContext)
    }

    enum Overlay: Equatable {
        case loading
        case indexLoading
        case noResults(String)
        case error(String)
        case empty
    }

    struct PaneKey: Equatable {
        let selection: FileBrowserSelection
        let context: FileBrowserNavigationContext?
        let connection: ObjectIdentifier
        let apiClient: ObjectIdentifier?
    }

    struct BarState: Equatable {
        let showsSidebarToggle: Bool
        let showsColumnBack: Bool
        let themeID: ThemeID
    }
}

private extension FileBrowserViewController.ContentState {
    init(treeDirectoryPath: String?, selectedFile: FileBrowserSelection?) {
        self.init()
        self.treeDirectoryPath = treeDirectoryPath
        self.selectedFile = selectedFile
    }
}
