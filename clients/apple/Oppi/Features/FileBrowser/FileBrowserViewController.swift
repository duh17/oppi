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
    let navigation: SceneNavigation
    let reviewCommentSelectionScope: ReviewCommentSelectionScope?

    func isSame(as other: Self) -> Bool {
        connection === other.connection
            && apiClient === other.apiClient
            && fileIndexStore === other.fileIndexStore
            && navigation === other.navigation
    }
}

/// The bar of the chat Files panel. The embedded browser cannot reach that
/// screen's bar, so the panel applies it.
struct FileBrowserEmbeddedChrome: Equatable {
    var title: String
    /// Back opens the parent folder.
    var canGoBack: Bool
    /// Forward opens the next folder down the trail Back left.
    var canGoForward: Bool
    /// The search's scope bar (`FileBrowserSearchScope.titles`); nil at the
    /// root, where there is only one scope.
    var searchScopeTitles: [String]?
    var searchScope: FileBrowserSearchScope
}

/// The keyed markdown viewport store the open file's reader and pushed readers share,
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
/// Regular width shows the folder tree, folders open in place, and the open
/// file is a pane of its own: the reader opens as this screen's attached leaf
/// (`AttachedLeafController`) beside the list, with the pane divider between
/// them, or full over the list when the two do not fit side by side (the
/// iPad mini in portrait). Each pane has its own bar: the list's carries the
/// folder, its Back (up a folder) and View Options; the reader's the file's
/// title, actions and Close. Where the reader cannot sit beside the list (a
/// pane that is not the window's routed one, or a selection kept into compact
/// width) it is a sheet. In the chat panel (`compactOnly`) folders open in
/// place and files push the reader onto the panel's stack.
///
/// The screen reads the lock service, the server's `FileIndexStore`, and
/// `SceneNavigation` in `updateProperties()` and applies a diffable snapshot
/// keyed by entry path; state rows have fixed ids.
@MainActor
final class FileBrowserViewController: UIViewController, UICollectionViewDelegate, UITextFieldDelegate {
    /// The split detail root carries the sidebar toggle.
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    /// The chat panel applies this to its bar.
    var onEmbeddedChromeChange: ((FileBrowserEmbeddedChrome) -> Void)?

    /// The device's sort and visibility choices, shared by every browser.
    private var viewOptions: FileBrowserViewOptionsStore { .shared }

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
    private var navigation: SceneNavigation { services?.navigation ?? root.navigation }

    /// The shell route's server stores once its server is ready; the panel's
    /// from the start.
    private(set) var services: FileBrowserServices? {
        didSet { setNeedsUpdateProperties() }
    }

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
    private var searchedKey: SearchKey?
    private var cachedChangeMarks: (files: [GitFileStatus], total: Int, marks: FileBrowserChangeMarks)?
    private let viewportRestore = FileBrowserViewportRestore()

    // Views.
    private let treeColumn = UIView()
    private let columnSearch = FileBrowserColumnSearchField()
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private let stateView = UIContentUnavailableView(loadState: .loading(nil))
    private let refreshControl = UIRefreshControl()
    private let search = ScreenSearchController(prompt: String(localized: "Search files"))
    private var searchInstalled = false
    private var collectionTopInList: NSLayoutConstraint?
    private var collectionTopInColumn: NSLayoutConstraint?
    private var appliedLayout: Layout?

    // The open file: a pane beside the list, or a sheet.
    private lazy var readerLeaf = AttachedLeafController(screen: self)
    private let readerSheet = RouterModalPresenter()
    /// The reader built last, and the file it was last told to show: another
    /// file on the same server goes to it, so its previous/next slide and
    /// editing state carry over.
    private weak var reader: FileViewerViewController?
    private var readerShows: ReaderShows?

    // Snapshot and bar values.
    private var rows: [Item: Row] = [:]
    private var taps: [Item: Tap] = [:]
    private var overlay: Overlay?
    private var compactSearchHeader: String?
    private var snapshotScope: String?
    private var lastThemeID: ThemeID?
    private var appliedBars: BarState?
    private var sidebarToggle: UIBarButtonItem?
    private lazy var viewOptionsItem = Self.makeViewOptionsItem { [weak self] in self?.pinsSection?.viewOptionsElements() ?? [] }
    /// The Pinned section of a shell route's root (`FileBrowserPinsSection`).
    private(set) lazy var pinsSection: FileBrowserPinsSection? = isShellRoute ? serverId.map { serverId in
        FileBrowserPinsSection(serverId: serverId, scope: scope, presenter: self, hooks: .init(
            connection: { [weak self] in self?.services?.connection },
            navigation: { [weak self] in self?.navigation },
            currentFolder: { [weak self] in self?.currentDirectoryPath ?? "" },
            openFolderHere: { [weak self] path in self?.activate(.directory(path)) },
            setEditing: { [weak self] editing in self?.collectionView.isEditing = editing },
            changed: { [weak self] in self?.setNeedsUpdateProperties() }
        ))
    } : nil
    private var lastChrome: FileBrowserEmbeddedChrome?
    /// The listing's order and the checkout's Git changes, read each pass.
    private var arrangement = FileBrowserViewOptions()
    private var arrangedMemo: (listingID: UUID, options: FileBrowserViewOptions, entries: [FileEntry])?
    private var changeMarks = FileBrowserChangeMarks.none

    /// The `.fileBrowser` shell route.
    init(
        root: AppRootEnvironment,
        target: FileBrowserNavTarget,
        showsSidebarToggle: Bool
    ) {
        self.root = root
        serverId = target.serverId
        scope = target.scope
        initialPath = target.path
        layoutMode = .adaptive
        isShellRoute = true
        restoredDirectory = target.columnDirectoryPath
        restoredSelection = target.columnSelectedFile
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
    /// stores; files push onto the stack of the controller that embeds it.
    init(
        root: AppRootEnvironment,
        services: FileBrowserServices,
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

    /// The panel re-rendered: its stores and its bar's search text and scope.
    func updateEmbedding(services: FileBrowserServices, searchText: String, searchScope: FileBrowserSearchScope) {
        self.services = services
        setSearchScope(searchScope)
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
        collectionView.dragDelegate = self
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
        columnSearch.onScopeChange = { [weak self] index in
            self?.setSearchScope(FileBrowserSearchScope(rawValue: index) ?? .everywhere)
        }

        treeColumn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(treeColumn)
        for subview in [columnSearch, collectionView, stateView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            treeColumn.addSubview(subview)
        }
        installConstraints()
        addChild(readerLeaf)
        view.addSubview(readerLeaf.view)
        readerLeaf.view.frame = .zero
        readerLeaf.didMove(toParent: self)
        readerLeaf.onDismissRequested = { [weak self] in self?.selectFile(nil) }
        readerSheet.anchor = self

        search.onTextChange = { [weak self] text in self?.setSearchText(text) }
        search.scopeAccessibilityIdentifier = "fileBrowser.searchScope"
        search.onScopeChange = { [weak self] index in
            self?.setSearchScope(FileBrowserSearchScope(rawValue: index) ?? .everywhere)
        }
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
        // Pins show only at a root; a subfolder's appearance reads nothing.
        if isRoot { pinsSection?.refresh() }
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
        readerSheet.sync()
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
        // The sidebar toggle stays on the lock cover and "Connecting"; the
        // column Back belongs to the content.
        if isShellRoute {
            let showsContent = !isLocked && services != nil
            syncLeadingItems(showsColumnBack: showsContent && replacesStackBackButton)
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

        arrangement = viewOptions.options
        changeMarks = currentChangeMarks(services)

        // A query stays current with the file index under it, and with its
        // scope's folder.
        let index = services.fileIndexStore.paths
        let searchKey = SearchKey(
            index: index,
            scope: state.searchScope,
            folder: currentDirectoryPath,
            showsHidden: arrangement.showsHidden
        )
        if searchKey != searchedKey {
            searchedKey = searchKey
            if !trimmedQuery.isEmpty {
                performLocalSearch(query: trimmedQuery)
            }
        }
        let indexIsLoading = services.fileIndexStore.isLoading && index == nil

        let layout = currentLayout
        applyLayout(layout)
        applySnapshot(layout: layout, indexIsLoading: indexIsLoading, reconfigureAll: themeChanged)
        syncReader(services: services)
        syncBars(layout: layout)
    }

    private func applyTheme(_ palette: ThemePalette) {
        let background = palette.ui.bg
        view.backgroundColor = background
        collectionView.backgroundColor = .clear
        columnSearch.apply(palette)
        reader?.view.backgroundColor = background
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
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
                .connecting,
                palette: palette,
                background: root.themeStore.backgroundColor
            )
        } else {
            contentUnavailableConfiguration = nil
        }
        treeColumn.isHidden = next != .content
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
        searchedKey = nil
        closeReader()
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
    /// through `SceneNavigation`. In the chat panel folders open in place and
    /// files push onto the panel's own stack.
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
        showsColumn ? .column : .list
    }

    /// Whether the list can collapse to its strip beside the open file
    /// (⇧⌘L), and whether it is collapsed: the reader filling the window by
    /// the person's choice. Nil while no reader sits beside the list, or
    /// the two do not fit side by side (then the reader is full already).
    var listCollapse: Bool? {
        guard isOnScreen, phase == .content else { return nil }
        return readerLeaf.fillsWindow
    }

    /// Collapses the list beside the open file, or gives it its room back,
    /// as the divider's drag and its strip's tap do.
    func toggleListCollapse() {
        guard let collapsed = listCollapse else { return }
        readerLeaf.setFillsWindow(!collapsed)
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

    /// The list's bar names its folder; the open file names itself in its own pane.
    private var barTitle: String {
        if isRoot { return scope.breadcrumbRootLabel }
        return folderName(currentDirectoryPath)
    }

    private func folderName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? scope.breadcrumbRootLabel
    }

    /// The checkout's Git changes, while the shared status store holds this
    /// browser's checkout (a chat or workspace screen on it loaded it); the
    /// browser never moves the store to another checkout itself.
    private func currentChangeMarks(_ services: FileBrowserServices) -> FileBrowserChangeMarks {
        guard case .workspace(let workspaceId, let worktreeId) = scope,
              let status = services.connection.gitStatusStore.status(workspaceId: workspaceId, worktreeId: worktreeId),
              status.isGitRepo else { return .none }
        if let cached = cachedChangeMarks, cached.files == status.files, cached.total == status.totalFiles {
            return cached.marks
        }
        let marks = FileBrowserChangeMarks(status.files, totalCount: status.totalFiles)
        cachedChangeMarks = (status.files, status.totalFiles, marks)
        return marks
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

    /// The listing's entries in display order, sorted once per listing and
    /// view options; the rows and previous/next both read this.
    private func arrangedEntries(_ listing: DirectoryListingResponse) -> [FileEntry] {
        if let memo = arrangedMemo, memo.listingID == state.listingID, memo.options == arrangement {
            return memo.entries
        }
        let entries = arrangement.arranged(listing.entries)
        arrangedMemo = (state.listingID, arrangement, entries)
        return entries
    }

    /// Previous/next walk the folder's files in the order the list shows them.
    private func listingNavigationContext(_ listing: DirectoryListingResponse) -> FileBrowserNavigationContext {
        FileBrowserNavigationContext(files: arrangedEntries(listing).compactMap { entry in
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

    /// Retry on a failed listing: back to the loading state, then list again.
    private func retryDirectoryLoad() {
        state.error = nil
        startDirectoryLoad()
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

    /// Fuzzy match over the file index (the scope's part of it) off the main
    /// thread; a result lands only while its query and scope are still the
    /// current ones.
    private func performLocalSearch(query: String) {
        guard let paths = services?.fileIndexStore.paths else { return }
        let scope = effectiveSearchScope
        let folder = currentDirectoryPath
        let options = arrangement
        Task { [weak self] in
            let results = await Task.detached {
                let candidates = options.searchable(scope.candidates(paths, folder: folder))
                return FuzzyMatch.search(query: query, candidates: candidates, limit: 100)
            }.value
            guard let self, trimmedQuery == query, effectiveSearchScope == scope, currentDirectoryPath == folder,
                  arrangement.showsHidden == options.showsHidden else { return }
            state.fuzzyResults = results
        }
    }

    /// This Folder only below the root; at the root both scopes are one.
    private var effectiveSearchScope: FileBrowserSearchScope {
        searchScopeTitles == nil ? .everywhere : state.searchScope
    }

    /// The scope bar's titles: Everywhere and the folder on screen, below
    /// the root of a workspace (the home folder has no index to search).
    private var searchScopeTitles: [String]? {
        guard !isHostHome, !isRoot else { return nil }
        return FileBrowserSearchScope.titles(folderName: folderName(currentDirectoryPath))
    }

    private func setSearchScope(_ scope: FileBrowserSearchScope) {
        guard state.searchScope != scope else { return }
        state.searchScope = scope
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
            showDirectoryInPlace(path)
            return
        }
        state.selectedFile = nil
        guard let serverId, !serverId.isEmpty else {
            showDirectoryInPlace(path)
            return
        }
        pushDirectory(path: path)
    }

    /// The folder as its own file-browser route above this one.
    private func pushDirectory(path: String) {
        navigation.pushWorkspaceFileBrowser(navTarget(path: path))
    }

    /// Lists `path` in place. The open file stays open: it is a pane of its own.
    private func showDirectoryInPlace(_ path: String) {
        var next = state
        if usesInlineCompactNavigation {
            // Moving up keeps the deepest folder for Forward; opening a folder
            // off that trail starts a new one.
            let trail = state.forwardTrailPath ?? currentDirectoryPath
            next.forwardTrailPath = trail.hasPrefix(path) ? trail : path
        }
        next.treeDirectoryPath = path
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
            showDirectoryInPlace(breadcrumbPath(for: targetDepth))
            return
        }
        let depth = navigation.shownStackDepth
        guard depth >= popCount else { return }
        navigation.popShownStack(toDepth: depth - popCount)
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
        case .popToDirectory(let path):
            showDirectoryInPlace(path)
        case .useStackBack:
            break
        }
    }

    private func selectFile(_ selection: FileBrowserSelection?) {
        guard state.selectedFile != selection else { return }
        state.selectedFile = selection
        if selection == nil { state.selectedContext = nil }
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
        FileBrowserViewerFactory.pushReader(readerRequest(selection, context: context, services: services), from: self)
    }

    func readerRequest(
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

    /// The list fills the screen; the column searches in its own field above it.
    private func installConstraints() {
        NSLayoutConstraint.activate([
            treeColumn.topAnchor.constraint(equalTo: view.topAnchor),
            treeColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            treeColumn.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            treeColumn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
        ])
        collectionTopInList = collectionView.topAnchor.constraint(equalTo: treeColumn.topAnchor)
        collectionTopInColumn = collectionView.topAnchor.constraint(equalTo: columnSearch.bottomAnchor)
        collectionTopInList?.isActive = true
    }

    private func applyLayout(_ layout: Layout) {
        guard appliedLayout != layout else { return }
        let previous = appliedLayout
        appliedLayout = layout
        let column = layout == .column
        treeColumn.accessibilityIdentifier = column ? "fileBrowser.tree" : nil
        // The tree searches in its own field (workspace files only).
        let showsSearchField = column && !isHostHome
        columnSearch.isHidden = !showsSearchField
        collectionTopInList?.isActive = false
        collectionTopInColumn?.isActive = showsSearchField
        collectionTopInList?.isActive = !showsSearchField
        if !column, columnSearch.textField.isFirstResponder {
            columnSearch.textField.resignFirstResponder()
        }
        // Rows and spacing differ between the list and the tree.
        if previous != nil {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    // MARK: Snapshot

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self else { return nil }
            let section = dataSource?.sectionIdentifier(for: index) ?? .body
            let column = appliedLayout?.isColumn ?? false
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.backgroundColor = .clear
            configuration.showsSeparators = !column && (section == .body || section == .pins)
            if section == .pins {
                configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                    self?.pinId(at: indexPath).flatMap { self?.pinsSection?.trailingSwipe(pinId: $0) }
                }
                // The Pinned heading has no rule under it; the pins do, like the listing's rows.
                configuration.itemSeparatorHandler = { indexPath, separator in
                    var separator = separator
                    if indexPath.item == 0 { separator.bottomSeparatorVisibility = .hidden }
                    return separator
                }
            }
            if !column, section == .body, compactSearchHeader != nil {
                configuration.headerMode = .supplementary
            }
            let layoutSection = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            if column {
                layoutSection.interGroupSpacing = 4
                layoutSection.contentInsets = switch section {
                case .header, .pins: NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
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
            configure(cell, row: row, path: item.path)
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
        let pinCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, case .pin(let row)? = rows[item] else { return }
            configurePin(cell, row: row)
            pinsSection?.decorate(cell, row: row, palette: palette)
        }
        let listingHeaderCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            FileBrowserPinsSection.configureListingHeader(cell, palette: palette)
        }
        let pinsHeaderCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self, case .pinsHeader(let header)? = rows[item] else { return }
            pinsSection?.configureHeader(cell, header: header, palette: palette)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .pin:
                return collectionView.dequeueConfiguredReusableCell(using: pinCell, for: indexPath, item: item)
            case .pinsHeader:
                return collectionView.dequeueConfiguredReusableCell(using: pinsHeaderCell, for: indexPath, item: item)
            case .listingHeader:
                return collectionView.dequeueConfiguredReusableCell(using: listingHeaderCell, for: indexPath, item: item)
            case .breadcrumb:
                return collectionView.dequeueConfiguredReusableCell(using: breadcrumbCell, for: indexPath, item: item)
            case .directory:
                return collectionView.dequeueConfiguredReusableCell(using: folderCell, for: indexPath, item: item)
            case .file:
                return collectionView.dequeueConfiguredReusableCell(using: fileCell, for: indexPath, item: item)
            case .result:
                return collectionView.dequeueConfiguredReusableCell(using: resultCell, for: indexPath, item: item)
            case .searchCount, .emptyDirectory, .truncated, .marksIncomplete:
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
        // Edit mode moves pins only (`FileBrowserPinsSection`).
        dataSource.reorderingHandlers.canReorderItem = { [weak self] item in
            if case .pin = item { self?.pinsSection?.isEditing == true } else { false }
        }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            let ids = transaction.finalSnapshot.itemIdentifiers(inSection: .pins).compactMap(\.pinId)
            self?.pinsSection?.didReorder(ids)
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
        content.textProperties.color = palette.ui.comment
        content.textProperties.transform = .none
        view.contentConfiguration = content
        var background = UIBackgroundConfiguration.listHeader()
        background.backgroundColor = palette.ui.bg
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
        guard let dataSource else { return }
        let column = layout.isColumn
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        var nextRows: [Item: Row] = [:]
        var nextTaps: [Item: Tap] = [:]
        var nextOverlay: Overlay?
        var nextHeader: String?
        let selectedPath = column ? state.selectedFile?.path : nil

        func append(_ items: [Item], to section: Section) {
            guard !items.isEmpty else { return }
            if !snapshot.sectionIdentifiers.contains(section) {
                snapshot.appendSections([section])
            }
            snapshot.appendItems(items, toSection: section)
        }

        let pinned = isSearching ? nil : pinsSection?.content(atRoot: isRoot)
        if let pinned {
            nextRows[.pinsHeader] = .pinsHeader(pinned.header)
            for row in pinned.rows { nextRows[.pin(row.id)] = .pin(row) }
            append([.pinsHeader] + pinned.rows.map { .pin($0.id) }, to: .pins)
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
                        mark: changeMarks.mark(forFile: result.path),
                        column: column,
                        isSelected: selectedPath == result.path
                    ))
                    nextTaps[item] = .file(FileBrowserSelection(path: result.path, name: name, size: nil), context)
                    items.append(item)
                }
                append(items, to: .body)
            }
        } else if let listing = state.listing {
            let entries = arrangedEntries(listing)
            if entries.isEmpty, !column {
                nextOverlay = .empty
            } else {
                if !isRoot {
                    let segments = navTarget(path: currentDirectoryPath).breadcrumbSegments.map {
                        FileBrowserBreadcrumbCell.Segment(label: $0.label, depth: $0.depth)
                    }
                    nextRows[.breadcrumb] = .breadcrumb(segments: segments, depth: currentDepth, column: column)
                    append([.breadcrumb], to: .header)
                }
                if pinned != nil {
                    nextRows[.listingHeader] = .listingHeader
                    append([.listingHeader], to: .header)
                }
                if entries.isEmpty {
                    nextRows[.emptyDirectory] = .emptyDirectory
                    append([.emptyDirectory], to: .body)
                } else {
                    let context = listingNavigationContext(listing)
                    var items: [Item] = []
                    for entry in entries {
                        if entry.isDirectory {
                            let path = directoryPath(for: entry, relativeTo: currentDirectoryPath)
                            let item = Item.directory(path)
                            guard nextRows[item] == nil else { continue }
                            nextRows[item] = .directory(DirectoryRow(
                                name: entry.name,
                                hasChanges: changeMarks.folderHasChanges(path),
                                showsChevron: column || routesThroughShell,
                                column: column
                            ))
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
                                mark: changeMarks.mark(forFile: path),
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
        // Git listed only some of its changes: an unmarked file may be
        // changed too, so the list says so instead of looking clean.
        if nextOverlay == nil, changeMarks.unlistedCount > 0 {
            nextRows[.marksIncomplete] = .marksIncomplete(changeMarks.unlistedCount)
            append([.marksIncomplete], to: .footer)
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

        // Rows animate only within one folder or one search (a re-sort moves
        // them); a new folder or a new search replaces them.
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
        let state: LoadState
        switch next {
        case .loading:
            state = .loading(nil)
        case .indexLoading:
            state = .loading(String(localized: "Loading file index..."))
        case .noResults(let query):
            state = .noResults(query: query)
        case .error(let message):
            state = .failed(
                title: String(localized: "Unable to Load"),
                message: message,
                retry: RetryAction { [weak self] in self?.retryDirectoryLoad() }
            )
        case .empty:
            state = Self.emptyDirectoryState
        }
        stateView.configuration = UIContentUnavailableConfiguration.loadState(state, palette: palette, background: palette.ui.bg)
        stateView.isHidden = false
    }

    private static let emptyDirectoryState = LoadState.empty(
        title: String(localized: "Empty Directory"),
        systemImage: "folder",
        message: String(localized: "No files in this directory.")
    )

    // MARK: Cells

    private func configure(_ cell: UICollectionViewListCell, row: Row, path: String?) {
        let palette = palette
        let comment = palette.ui.comment
        let fg = palette.ui.fg
        cell.accessories = []
        // The tappable rows set this; state rows read as their text.
        var element: (label: String, isSelected: Bool)?
        defer { exposeRow(cell, as: element, path: path) }
        switch row {
        case .breadcrumb, .pinsHeader, .pin, .listingHeader:
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
            var content = UIContentUnavailableConfiguration.loadState(Self.emptyDirectoryState, palette: palette)
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 50, leading: 16, bottom: 50, trailing: 16)
            cell.contentConfiguration = content
            applyPlainBackground(to: cell)
        case .marksIncomplete(let unlisted):
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Git reported \(unlisted) more changes than it listed; those files show no change mark.")
            content.textProperties.font = UIFont.preferredFont(forTextStyle: .caption1)
            content.textProperties.color = comment
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            cell.contentConfiguration = content
            applyPlainBackground(to: cell)
        case .truncated(let count):
            var content = UIListContentConfiguration.cell()
            content.text = "Showing first \(count) entries"
            content.textProperties.font = UIFont.preferredFont(forTextStyle: .caption1)
            content.textProperties.color = comment
            if appliedLayout?.isColumn == true {
                content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 0, trailing: 8)
            }
            cell.contentConfiguration = content
            applyPlainBackground(to: cell)
        case .directory(let directory):
            let name = directory.name
            let folderDot = directory.hasChanges ? Self.changeDot(comment.withAlphaComponent(0.7), diameter: 6) : nil
            if directory.column {
                configureTreeRow(
                    cell,
                    image: Self.treeSymbol("folder.fill"),
                    tint: palette.ui.blue,
                    title: NSAttributedString(string: name, attributes: [.font: Self.font(.callout, .regular), .foregroundColor: fg]),
                    subtitle: nil,
                    trailingText: nil,
                    trailingColor: comment,
                    changeDot: folderDot,
                    showsChevron: true,
                    isSelected: false
                )
            } else {
                var content = UIListContentConfiguration.cell()
                content.image = UIImage(systemName: "folder.fill")
                content.imageProperties.tintColor = palette.ui.blue
                content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
                content.text = name
                content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
                content.textProperties.color = fg
                content.textProperties.numberOfLines = 1
                cell.contentConfiguration = content
                var accessories: [UICellAccessory] = folderDot.map { [$0] } ?? []
                if directory.showsChevron {
                    accessories.append(.disclosureIndicator())
                }
                cell.accessories = accessories
                applyListBackground(to: cell)
            }
            let changes = directory.hasChanges ? String(localized: "Contains changes") : nil
            element = ([name, changes].compactMap { $0 }.joined(separator: ", "), false)
        case .file(let file):
            let icon = FileIcon.forPath(file.name)
            let trailingColor = file.isRecent ? palette.ui.green : comment
            let dot = file.mark.map { Self.changeDot(Self.markColor($0.kind, palette: palette), diameter: 7) }
            let detail = Self.detailLine(size: file.size, mark: file.mark, palette: palette, font: file.column
                ? UIFont.scaledMonospaced(.caption2) : UIFont.preferredFont(forTextStyle: .caption2))
            if file.column {
                configureTreeRow(
                    cell,
                    image: Self.treeSymbol(icon.symbolName),
                    tint: comment,
                    title: NSAttributedString(
                        string: file.name,
                        attributes: [.font: Self.font(.callout, file.isSelected ? .semibold : .regular), .foregroundColor: fg]
                    ),
                    subtitle: detail,
                    trailingText: file.modified,
                    trailingColor: trailingColor,
                    changeDot: dot,
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
                content.secondaryAttributedText = detail
                content.secondaryTextProperties.color = comment
                content.textToSecondaryTextVerticalPadding = 2
                cell.contentConfiguration = content
                cell.accessories = (dot.map { [$0] } ?? []) + [
                    .label(text: file.modified, options: .init(tintColor: trailingColor, font: UIFont.preferredFont(forTextStyle: .caption2))),
                    .disclosureIndicator(),
                ]
                applyListBackground(to: cell)
            }
            element = (
                [file.name, file.mark?.spokenDescription, file.size, file.modified]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
                file.isSelected
            )
        case .result(let result):
            let icon = FileIcon.forPath(result.name)
            let title = Self.highlightedName(result, palette: palette)
            let dot = result.mark.map { Self.changeDot(Self.markColor($0.kind, palette: palette), diameter: 7) }
            if result.column {
                configureTreeRow(
                    cell,
                    image: Self.treeSymbol(icon.symbolName),
                    tint: comment,
                    title: title,
                    subtitle: result.directory.map { NSAttributedString(string: $0) },
                    trailingText: nil,
                    trailingColor: comment,
                    changeDot: dot,
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
                cell.accessories = (dot.map { [$0] } ?? []) + [.disclosureIndicator()]
                applyListBackground(to: cell)
            }
            element = (
                [result.name, result.mark?.spokenDescription, result.directory].compactMap { $0 }.joined(separator: ", "),
                result.isSelected
            )
        }
    }

    /// A tappable row's one accessibility element is its content, typed a
    /// button with the row's texts as its label, as the SwiftUI rows were.
    /// Runs after the content configuration: a list cell makes itself the
    /// element once it has content. Every field is set on reuse. The id ends in the
    /// entry's path (a folder's ends in "/"), so a row is found by its path, not its text.
    private func exposeRow(_ cell: UICollectionViewListCell, as element: (label: String, isSelected: Bool)?, path: String?) {
        let content = cell.contentView
        cell.isAccessibilityElement = false
        guard let element, let path else {
            content.isAccessibilityElement = false
            content.accessibilityTraits = .none
            content.accessibilityLabel = nil
            content.accessibilityIdentifier = nil
            content.accessibilityCustomActionsBlock = nil
            cell.accessibilityElements = nil
            return
        }
        // Read when VoiceOver asks, so Pin and Unpin match the pins then.
        content.accessibilityCustomActionsBlock = { [weak self] in
            MainActor.assumeIsolated { self?.rowAccessibilityActions(path: path) ?? [] }
        }
        content.isAccessibilityElement = true
        content.accessibilityTraits = element.isSelected ? [.button, .selected] : .button
        content.accessibilityLabel = element.label
        content.accessibilityIdentifier = "fileBrowser.row.\(path)"
        cell.accessibilityElements = [content]
    }

    private func setListIcon(_ icon: FileIcon, on content: inout UIListContentConfiguration) {
        content.image = icon.uiImage(pointSize: 12)
        content.imageProperties.tintColor = icon.color
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
        subtitle: NSAttributedString?,
        trailingText: String?,
        trailingColor: UIColor,
        changeDot: UICellAccessory? = nil,
        showsChevron: Bool,
        isSelected: Bool
    ) {
        let palette = palette
        let blue = palette.ui.blue
        let comment = palette.ui.comment
        var content = UIListContentConfiguration.subtitleCell()
        content.image = image
        content.imageProperties.tintColor = isSelected ? blue : tint
        content.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
        content.imageToTextPadding = 10
        content.attributedText = title
        content.textProperties.numberOfLines = 1
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.secondaryAttributedText = subtitle
        content.secondaryTextProperties.font = UIFont.scaledMonospaced(.caption2)
        content.secondaryTextProperties.color = comment
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        content.textToSecondaryTextVerticalPadding = 2
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        cell.contentConfiguration = content
        var accessories: [UICellAccessory] = changeDot.map { [$0] } ?? []
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
        let pressed = palette.ui.fg.withAlphaComponent(0.06)
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

    /// A pin drawn as the listing draws its folders and files: the tree's
    /// row in the column, the list's row with its chevron otherwise.
    private func configurePin(_ cell: UICollectionViewListCell, row: FileBrowserPinsSection.Row) {
        let palette = palette
        let tint = row.isGone || !row.isDirectory ? palette.ui.comment : palette.ui.blue
        let color = row.isGone ? palette.ui.comment : palette.ui.fg
        let opens = !row.isGone && !row.isEditing
        if appliedLayout?.isColumn == true {
            configureTreeRow(
                cell,
                image: Self.treeSymbol(row.icon?.symbolName ?? "folder.fill"),
                tint: tint,
                title: NSAttributedString(string: row.title, attributes: [.font: Self.font(.callout, .regular), .foregroundColor: color]),
                subtitle: row.detail.map { NSAttributedString(string: $0) },
                trailingText: nil,
                trailingColor: palette.ui.comment,
                showsChevron: opens,
                isSelected: false
            )
            return
        }
        var content = UIListContentConfiguration.subtitleCell()
        if let icon = row.icon, !row.isGone {
            setListIcon(icon, on: &content)
        } else {
            content.image = UIImage(systemName: row.icon?.symbolName ?? "folder.fill")
            content.imageProperties.tintColor = tint
            content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
        }
        content.text = row.title
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        content.textProperties.color = color
        content.secondaryText = row.detail
        content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .caption2)
        content.secondaryTextProperties.color = palette.ui.comment
        content.textToSecondaryTextVerticalPadding = 2
        cell.contentConfiguration = content
        cell.accessories = opens ? [.disclosureIndicator()] : []
        applyListBackground(to: cell)
    }

    /// The list's theme page; a touched row shows the system highlight.
    private func applyListBackground(to cell: UICollectionViewListCell) {
        let page = palette.ui.bg
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
            .foregroundColor: palette.ui.fg,
        ]
        let matched: [NSAttributedString.Key: Any] = [
            .font: font(.body, .bold),
            .foregroundColor: palette.ui.yellow,
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

    /// A changed file's dot, by how Git changed it; a folder's dimmer one.
    private static func changeDot(_ color: UIColor, diameter: CGFloat) -> UICellAccessory {
        // A cell accessory's custom view is sized by its frame: UIKit
        // refuses one that sizes itself with constraints.
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        dot.backgroundColor = color
        dot.layer.cornerRadius = diameter / 2
        dot.isAccessibilityElement = false
        return .customView(configuration: .init(
            customView: dot,
            placement: .trailing(),
            reservedLayoutWidth: .custom(diameter),
            maintainsFixedSize: true
        ))
    }

    private static func markColor(_ kind: FileBrowserChangeMark.Kind, palette: ThemePalette) -> UIColor {
        switch kind {
        case .added: palette.ui.diffAdded
        case .modified: palette.ui.orange
        case .deleted, .conflicted: palette.ui.diffRemoved
        case .renamed: palette.ui.purple
        }
    }

    /// The size, then Git's line counts in their diff colors.
    private static func detailLine(
        size: String,
        mark: FileBrowserChangeMark?,
        palette: ThemePalette,
        font: UIFont
    ) -> NSAttributedString? {
        let comment = palette.ui.comment
        let text = NSMutableAttributedString(string: size, attributes: [.font: font, .foregroundColor: comment])
        func append(_ string: String, _ color: UIColor) {
            if text.length > 0 { text.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            text.append(NSAttributedString(string: string, attributes: [
                .font: UIFont.scaled(.caption2, monospacedDigits: true),
                .foregroundColor: color,
            ]))
        }
        if let added = mark?.addedLines, added > 0 { append("+\(added)", palette.ui.diffAdded) }
        if let removed = mark?.removedLines, removed > 0 { append("\u{2212}\(removed)", palette.ui.diffRemoved) }
        return text.length > 0 ? text : nil
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
        if case .pin = item { return true }
        if case .pinsHeader = item { return true }
        return taps[item] != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource?.itemIdentifier(for: indexPath) {
        case .pin(let id)?: pinsSection?.select(id)
        case .pinsHeader?: pinsSection?.toggleCollapsed()
        case let item?: taps[item].map(activate)
        case nil: break
        }
    }

    func rowPath(at indexPath: IndexPath) -> String? { dataSource?.itemIdentifier(for: indexPath)?.path }
    func pinId(at indexPath: IndexPath) -> String? { dataSource?.itemIdentifier(for: indexPath)?.pinId }

    /// A row as a pane entry, for a drag (`+Drag`) and the pane menu items.
    /// Home rows name their folder or file as `~/…`.
    func paneEntry(forRowPath path: String) -> PaneStackEntry? {
        guard let serverId else { return nil }
        let route: PaneRoute
        switch scope {
        case .workspace(let workspaceId, let worktreeId):
            route = path.hasSuffix("/")
                ? .files(workspace: workspaceId, path: String(path.dropLast()))
                : .file(.workspace(id: workspaceId, worktree: worktreeId), path: path, line: nil)
        case .hostHome:
            route = path.hasSuffix("/")
                ? .hostFiles(path: FileBrowserHostHomePath.rawPath(relativePath: path))
                : .file(.host, path: path, line: nil)
        }
        return PaneStackEntry(serverId: serverId, route: route)
    }

    /// The entry at `path` for its row menu (`FileBrowserViewController+RowMenu.swift`):
    /// its file (nil for a folder), its cell, and what a tap on it does.
    func rowMenuEntry(path: String) -> (file: FileBrowserSelection?, cell: UIView?, open: @MainActor () -> Void)? {
        guard let (item, tap) = taps.first(where: { $0.key.path == path }) else { return nil }
        let file: FileBrowserSelection? = if case .file(let selection, _) = tap { selection } else { nil }
        let cell = dataSource?.indexPath(for: item).flatMap { collectionView.cellForItem(at: $0) }
        return (file, cell, { [weak self] in self?.activate(tap) })
    }

    private func activate(_ tap: Tap) {
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
                state.selectedContext = context
                selectFile(selection)
            } else {
                openCompactFile(selection, context: context)
            }
        }
    }

    // MARK: The open file

    /// The open file's reader: this screen's attached leaf beside the list
    /// where the window has room for panes (`readerLeaf.opensBeside`), else a
    /// sheet over it. One reader per server: another file goes to the reader
    /// already open (`show`), so its previous/next slide and editing state
    /// carry over. The reader keeps the folder it was opened from for
    /// previous and next, also after the list moves to another folder.
    private func syncReader(services: FileBrowserServices) {
        guard let selection = state.selectedFile else {
            closeReader()
            return
        }
        let server = ReaderServer(
            connection: ObjectIdentifier(services.connection),
            apiClient: services.apiClient.map(ObjectIdentifier.init)
        )
        let context: FileBrowserNavigationContext? = if let shows = readerShows, shows.selection == selection,
                                                         shows.context != nil {
            shows.context
        } else {
            state.selectedContext ?? currentNavigationContext
        }
        let shows = ReaderShows(server: server, selection: selection, context: context)
        if let reader, let shown = readerShows, shown.server == server, shown != shows {
            readerShows = shows
            reader.show(selection, navigationContext: context)
        }
        let makeReader: () -> UIViewController = { [weak self] in
            guard let self else { preconditionFailure("The reader opens only while its browser is alive") }
            return self.makeReader(shows, services: services)
        }
        let beside = readerLeaf.opensBeside
        readerLeaf.show(
            beside ? AttachedLeafController.Panel(
                id: AnyHashable(server),
                minWidth: PaneMinimumSize.attached.width,
                idealWidth: 520,
                maxWidth: 820,
                route: paneEntry(forRowPath: selection.path),
                makeScreen: makeReader
            ) : nil,
            root: beside ? root : nil
        )
        readerSheet.update(
            id: beside ? nil : AnyHashable(server),
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.selectFile(nil) },
            screen: { .controller(makeReader) }
        )
    }

    /// A reader for what the browser has open now (`shows` when it was
    /// asked for), with a Close that closes the file.
    private func makeReader(_ requested: ReaderShows, services: FileBrowserServices) -> FileViewerViewController {
        let shows = state.selectedFile.map { ReaderShows(server: requested.server, selection: $0, context: requested.context) }
            ?? requested
        let viewer = FileBrowserViewerFactory.make(
            readerRequest(shows.selection, context: shows.context, services: services),
            onSelectionChange: { [weak self] selection in self?.selectFile(selection) },
            onBack: { [weak self] in self?.selectFile(nil) }
        )
        viewer.view.backgroundColor = palette.ui.bg
        let mode = FullScreenViewerNavigationChrome.DismissMode.modal
        let close = UIBarButtonItem(
            title: mode.accessibilityLabel,
            image: UIImage(systemName: mode.systemImageName),
            primaryAction: UIAction { [weak self] _ in self?.selectFile(nil) }
        )
        close.accessibilityLabel = mode.accessibilityLabel
        close.accessibilityIdentifier = "fileBrowser.reader.close"
        viewer.navigationItem.leftBarButtonItem = close
        reader = viewer
        readerShows = shows
        return viewer
    }

    private func closeReader() {
        readerShows = nil
        readerLeaf.show(nil, root: nil)
        readerSheet.update(
            id: nil, presentation: .sheet.inNavigation(), root: root, clear: {},
            screen: { preconditionFailure("No file is open to present") }
        )
    }

    // MARK: Bars

    private func syncBars(layout: Layout) {
        let title = barTitle
        let scopeTitles = searchScopeTitles
        guard isShellRoute else {
            let chrome = FileBrowserEmbeddedChrome(
                title: title,
                canGoBack: canGoBack,
                canGoForward: forwardDirectoryPath != nil,
                searchScopeTitles: scopeTitles,
                searchScope: effectiveSearchScope
            )
            if chrome != lastChrome {
                lastChrome = chrome
                onEmbeddedChromeChange?(chrome)
            }
            return
        }
        navigationItem.title = title
        navigationItem.hidesBackButton = replacesStackBackButton

        // The folder's View Options; the open file's items are in its own pane's bar.
        if navigationItem.rightBarButtonItems?.count != 1 || navigationItem.rightBarButtonItems?.first !== viewOptionsItem {
            navigationItem.rightBarButtonItems = [viewOptionsItem]
        }

        // The bar's search lists files in place of the folder; the column
        // searches in its own field.
        if layout == .list, !isHostHome {
            installSearch()
            search.keepsNavigationBarInWideWindow()
            search.setText(state.searchText)
            search.setScopes(scopeTitles, selected: effectiveSearchScope.rawValue)
        } else {
            uninstallSearch()
        }
        columnSearch.setText(state.searchText)
        columnSearch.setScopes(isSearching ? scopeTitles : nil, selected: effectiveSearchScope.rawValue)
    }

    /// The split detail root's sidebar toggle in every phase, then the
    /// column Back (up a folder) while the content shows.
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
        /// The folder tree, its rows and spacing (regular width); the open
        /// file is a pane beside it.
        case column

        var isColumn: Bool { self == .column }
    }

    struct ContentState {
        var listing: DirectoryListingResponse? {
            didSet { listingID = UUID() }
        }
        /// Changes with every listing, so its sorted entries are kept per listing.
        private(set) var listingID = UUID()
        var error: String?
        var searchText = ""
        var searchScope = FileBrowserSearchScope.everywhere
        var fuzzyResults: [FuzzyMatch.ScoredPath] = []
        var treeDirectoryPath: String?
        var selectedFile: FileBrowserSelection?
        /// The folder the open file was chosen in, for its previous and next;
        /// nil for a restored file until its folder lists.
        var selectedContext: FileBrowserNavigationContext?
        var didRecordColumnRoute = false
        /// The chat panel's deepest folder on the current branch, where
        /// Forward leads back to.
        var forwardTrailPath: String?
    }

    enum Section: Hashable {
        /// The Pinned section at the root (`FileBrowserPinsSection`).
        case pins
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
        /// Git's status lists only some of its changes.
        case marksIncomplete
        case pinsHeader
        /// A pin, by its id.
        case pin(String)
        /// "Files" over the listing, under the Pinned section.
        case listingHeader

        /// The entry's path; nil for a state row or a pin.
        var path: String? {
            switch self {
            case .directory(let path), .file(let path), .result(let path): path
            case .breadcrumb, .searchCount, .emptyDirectory, .truncated, .marksIncomplete, .pinsHeader, .pin, .listingHeader: nil
            }
        }

        var pinId: String? {
            if case .pin(let id) = self { return id }
            return nil
        }
    }

    struct DirectoryRow: Equatable {
        let name: String
        /// Git reports a change somewhere below it.
        let hasChanges: Bool
        let showsChevron: Bool
        let column: Bool
    }

    struct FileRow: Equatable {
        let name: String
        let size: String
        let modified: String
        let isRecent: Bool
        let mark: FileBrowserChangeMark?
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
        let mark: FileBrowserChangeMark?
        let column: Bool
        let isSelected: Bool
    }

    /// What a search ran over: a new index, scope, or scope folder runs it again.
    struct SearchKey: Equatable {
        let index: [String]?
        let scope: FileBrowserSearchScope
        let folder: String
        let showsHidden: Bool
    }

    enum Row: Equatable {
        case breadcrumb(segments: [FileBrowserBreadcrumbCell.Segment], depth: Int, column: Bool)
        case searchCount(String)
        case directory(DirectoryRow)
        case file(FileRow)
        case result(ResultRow)
        case emptyDirectory
        case truncated(Int)
        case marksIncomplete(Int)
        case pinsHeader(FileBrowserPinsSection.Header)
        case pin(FileBrowserPinsSection.Row)
        case listingHeader
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

    /// The server stores a reader reads with: one reader per server.
    struct ReaderServer: Hashable {
        let connection: ObjectIdentifier
        let apiClient: ObjectIdentifier?
    }

    /// What the reader was last told to show.
    struct ReaderShows: Equatable {
        let server: ReaderServer
        let selection: FileBrowserSelection
        let context: FileBrowserNavigationContext?
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
