import UIKit

/// Session Outline: a scannable, searchable timeline of the session and, when
/// the server has one, its tree for `/tree`-style branch switching.
///
/// Sits at the root of a router navigation controller, as a chat sheet or in
/// the chat's trailing column. It owns its bar (title, Close) and its
/// `UISearchController`, so search, selection, and close have one owner.
/// Closing goes through the presenter (`onClose`), whose router dismissal or
/// column removal ends an active search first.
///
/// Entries are built once when the outline opens, then replaced by the
/// server's full-session outline when it loads. Search uses the shared
/// `FuzzyMatch` matcher, debounced at 200ms; clearing the field applies at
/// once. Both lists are diffable lists keyed by entry or node id.
final class SessionOutlineViewController: UIViewController, UICollectionViewDelegate {
    enum Layout: Int {
        case timeline
        case tree
    }

    // MARK: Inputs

    private let items: [ChatItem]
    private let toolArgsStore: ToolArgsStore
    private let toolDetails: (String) -> JSONValue?
    let onSelect: (String) -> Void
    private let onFork: ((String) -> Void)?
    private let onNavigateTreeNode: ((SessionTreeNavigationRequest) async throws -> Void)?
    private let initialTreeSnapshot: SessionTreeSnapshot?
    private let loadTree: ((SessionTreeFilterMode) async throws -> SessionTreeSnapshot)?
    private let initialOutlineSnapshot: SessionOutlineSnapshot?
    private let loadOutline: (() async throws -> SessionOutlineSnapshot)?
    /// Closes the outline through its presenter's state: at the root of a
    /// router navigation controller (a modal or the trailing column) the
    /// presenter owns the dismissal.
    private let onClose: () -> Void

    // MARK: State

    private(set) var layout: Layout = .timeline
    private var searchText = ""
    /// The query the lists show: `searchText` after the debounce.
    private(set) var query = ""
    private var filter: OutlineFilter = .all

    private var allEntries: [OutlineEntry] = []
    private(set) var displayedEntries: [OutlineEntry] = []
    private var entriesByID: [String: OutlineEntry] = [:]
    private var outlineSnapshot: SessionOutlineSnapshot?
    private var isLoadingOutline = false
    private var outlineLoadErrorMessage: String?

    private var treeFilter: SessionTreeFilterMode = .standard
    private var treeSnapshot: SessionTreeSnapshot?
    private var treeSnapshotFilter: SessionTreeFilterMode?
    private var treeFilteredNodes: [SessionTreeNodeSnapshot] = []
    private var collapsibleTreeNodeIds: Set<String> = []
    private var collapsedTreeNodeIds: Set<String> = []
    private var treeDisplayNodesByID: [String: SessionTreeDisplayNode] = [:]
    private var isLoadingTree = false
    private var treeLoadErrorMessage: String?
    private var treeNavigateErrorMessage: String?
    private var navigatingTreeNodeId: String?
    private var pendingTreeNavigationTargetId: String?
    private weak var summarySheet: TreeSummaryInstructionsViewController?

    private var searchDebounceTask: Task<Void, Never>?
    private var themeID: ThemeID?

    // MARK: Views

    private let search = ScreenSearchController(prompt: "Search session timeline…")
    private let layoutControl = UISegmentedControl(items: ["Timeline", "Tree"])
    private let layoutHeader = UIView()
    private var dividers: [UIView] = []
    private let timelinePane = UIStackView()
    private let timelineFilterBar = SessionOutlineFilterBar(titles: OutlineFilter.allCases.map(\.rawValue))
    private let outlineBanner = SessionOutlineBannerView()
    private let timelineList: UICollectionView
    private var timelineDataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let treePane = UIStackView()
    private let treeFilterBar = SessionOutlineFilterBar(titles: SessionTreeFilterMode.allCases.map(\.title))
    private let treeBanner = SessionOutlineBannerView()
    private let treeList: UICollectionView
    private let treeUnavailable = UIContentUnavailableView(configuration: .empty())
    private var treeDataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(
        items: [ChatItem],
        toolArgsStore: ToolArgsStore,
        toolDetails: @escaping (String) -> JSONValue? = { _ in nil },
        onSelect: @escaping (String) -> Void,
        onFork: ((String) -> Void)? = nil,
        onNavigateTreeNode: ((SessionTreeNavigationRequest) async throws -> Void)? = nil,
        initialTreeSnapshot: SessionTreeSnapshot? = nil,
        loadTree: ((SessionTreeFilterMode) async throws -> SessionTreeSnapshot)? = nil,
        initialOutlineSnapshot: SessionOutlineSnapshot? = nil,
        loadOutline: (() async throws -> SessionOutlineSnapshot)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.items = items
        self.toolArgsStore = toolArgsStore
        self.toolDetails = toolDetails
        self.onSelect = onSelect
        self.onFork = onFork
        self.onNavigateTreeNode = onNavigateTreeNode
        self.initialTreeSnapshot = initialTreeSnapshot
        self.loadTree = loadTree
        self.initialOutlineSnapshot = initialOutlineSnapshot
        self.loadOutline = loadOutline
        self.onClose = onClose
        timelineList = UICollectionView(frame: .zero, collectionViewLayout: Self.listLayout(separators: true))
        treeList = UICollectionView(frame: .zero, collectionViewLayout: Self.listLayout(separators: false))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        searchDebounceTask?.cancel()
    }

    private var hasTree: Bool {
        initialTreeSnapshot != nil || loadTree != nil || treeSnapshot != nil
    }

    private var palette: ThemePalette {
        (themeID ?? ThemeRuntimeState.currentThemeID()).palette
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Session Outline"
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.close()
        })
        close.accessibilityIdentifier = "chat.outline.close"
        navigationItem.leftBarButtonItem = close

        search.install(on: self, alwaysVisible: false)
        // iPad keeps the title and Close while searching: its search bar has
        // no Cancel to end the search.
        search.searchController.hidesNavigationBarDuringPresentation = UIDevice.current.userInterfaceIdiom != .pad
        search.onTextChange = { [weak self] text in
            self?.searchTextChanged(text)
        }

        buildViews()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.reconfigureAllRows()
        }

        outlineSnapshot = initialOutlineSnapshot
        allEntries = outlineSnapshot.map { $0.entries.map(SessionOutlineIndex.entry(from:)) }
            ?? SessionOutlineIndex.entries(items: items, toolArgsStore: toolArgsStore, toolDetails: toolDetails)
        applyFilter()
        if let initialTreeSnapshot {
            treeSnapshot = initialTreeSnapshot
            treeSnapshotFilter = .standard
            applyTreeFilter()
        }
        Task { [weak self] in
            await self?.loadOutlineIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.hostDidAppear(self)
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        let current = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        guard current != themeID else { return }
        themeID = current
        applyTheme()
    }

    // MARK: - Views

    private static func listLayout(separators: Bool) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear
            config.showsSeparators = separators
            if separators {
                config.itemSeparatorHandler = { indexPath, separator in
                    var separator = separator
                    separator.topSeparatorVisibility = .hidden
                    separator.bottomSeparatorInsets.leading = 42
                    return separator
                }
            }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }

    private func makeDivider() -> UIView {
        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: SessionOutlineStyle.hairline(view)).isActive = true
        dividers.append(divider)
        return divider
    }

    private func buildViews() {
        layoutControl.selectedSegmentIndex = Layout.timeline.rawValue
        layoutControl.addAction(UIAction { [weak self] _ in
            guard let self, let layout = Layout(rawValue: layoutControl.selectedSegmentIndex) else { return }
            setLayout(layout)
        }, for: .valueChanged)
        layoutControl.translatesAutoresizingMaskIntoConstraints = false
        layoutHeader.addSubview(layoutControl)
        NSLayoutConstraint.activate([
            layoutControl.topAnchor.constraint(equalTo: layoutHeader.topAnchor, constant: 8),
            layoutControl.bottomAnchor.constraint(equalTo: layoutHeader.bottomAnchor, constant: -8),
            layoutControl.leadingAnchor.constraint(equalTo: layoutHeader.leadingAnchor, constant: 16),
            layoutControl.trailingAnchor.constraint(equalTo: layoutHeader.trailingAnchor, constant: -16),
        ])

        timelineFilterBar.onSelect = { [weak self] index in
            self?.selectFilter(OutlineFilter.allCases[index])
        }
        timelineList.delegate = self
        timelineList.backgroundColor = .clear
        let entryCell = UICollectionView.CellRegistration<SessionOutlineEntryCell, String> { [weak self] cell, _, id in
            guard let self, let entry = entriesByID[id] else { return }
            cell.configure(entry, palette: palette) { [weak self] in
                self?.selectTimelineEntry(id)
            }
        }
        timelineDataSource = UICollectionViewDiffableDataSource(collectionView: timelineList) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: entryCell, for: indexPath, item: id)
        }
        timelinePane.axis = .vertical
        for view in [timelineFilterBar, makeDivider(), outlineBanner, timelineList] {
            timelinePane.addArrangedSubview(view)
        }

        treeFilterBar.onSelect = { [weak self] index in
            self?.selectTreeFilter(SessionTreeFilterMode.allCases[index])
        }
        treeList.delegate = self
        treeList.backgroundColor = .clear
        let treeCell = UICollectionView.CellRegistration<SessionOutlineTreeCell, String> { [weak self] cell, _, id in
            guard let self, let displayNode = treeDisplayNodesByID[id] else { return }
            let isCollapsible = collapsibleTreeNodeIds.contains(id)
            cell.configure(
                .init(
                    displayNode: displayNode,
                    isCollapsible: isCollapsible,
                    isCollapsed: collapsedTreeNodeIds.contains(id),
                    isDisabled: navigatingTreeNodeId != nil,
                    isLoading: navigatingTreeNodeId == id
                ),
                palette: palette,
                onActivate: { [weak self, weak cell] in
                    self?.handleTreeNodeSelection(id, sourceView: cell)
                },
                onToggle: { [weak self] in
                    self?.toggleTreeNodeCollapsed(id)
                }
            )
        }
        treeDataSource = UICollectionViewDiffableDataSource(collectionView: treeList) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: treeCell, for: indexPath, item: id)
        }
        let treeContent = UIView()
        for view in [treeList, treeUnavailable] {
            view.translatesAutoresizingMaskIntoConstraints = false
            treeContent.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: treeContent.topAnchor),
                view.bottomAnchor.constraint(equalTo: treeContent.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: treeContent.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: treeContent.trailingAnchor),
            ])
        }
        treePane.axis = .vertical
        for view in [treeFilterBar, makeDivider(), treeBanner, treeContent] {
            treePane.addArrangedSubview(view)
        }

        let layoutDivider = makeDivider()
        layoutHeader.isHidden = !hasTree
        layoutDivider.isHidden = !hasTree
        // Chrome shrinks to fit its content and the lists take the rest:
        // these containers have no intrinsic height, so hugging priorities
        // would not decide it, and the tree's filter bar took the pane.
        for chrome in [layoutHeader, timelineFilterBar, outlineBanner, treeFilterBar, treeBanner] {
            let fit = chrome.heightAnchor.constraint(equalToConstant: 0)
            fit.priority = .defaultLow + 1
            fit.isActive = true
        }
        let root = UIStackView(arrangedSubviews: [layoutHeader, layoutDivider, timelinePane, treePane])
        root.axis = .vertical
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        showLayout()
    }

    private func applyTheme() {
        let palette = palette
        view.backgroundColor = UIColor(palette.bg)
        for divider in dividers {
            divider.backgroundColor = UIColor(palette.comment.opacity(0.3))
        }
        updateTimelineChrome()
        updateTreeChrome()
        reconfigureAllRows()
    }

    private func reconfigureAllRows() {
        for dataSource in [timelineDataSource, treeDataSource] {
            guard let dataSource else { continue }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    // MARK: - Layout

    private func setLayout(_ newLayout: Layout) {
        guard newLayout != layout else { return }
        layout = newLayout
        showLayout()
        guard newLayout == .tree else {
            treeNavigateErrorMessage = nil
            updateTreeChrome()
            return
        }
        Task { [weak self] in
            await self?.loadTreeIfNeeded()
            self?.applyTreeFilter()
        }
    }

    private func showLayout() {
        timelinePane.isHidden = layout != .timeline
        treePane.isHidden = layout != .tree
        search.searchController.searchBar.placeholder = layout == .timeline
            ? "Search session timeline…"
            : "Search session tree…"
        setContentScrollView(layout == .timeline ? timelineList : treeList, for: .top)
    }

    // MARK: - Search

    private func searchTextChanged(_ text: String) {
        // The bar also reports on activation, with unchanged text.
        guard text != searchText else { return }
        searchText = text
        searchDebounceTask?.cancel()
        guard !text.isEmpty else {
            // Clear search immediately for responsiveness.
            setQuery("")
            return
        }
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.setQuery(text)
        }
    }

    private func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        collapsedTreeNodeIds.removeAll()
        applyFilter()
        applyTreeFilter()
    }

    // MARK: - Timeline

    private func selectFilter(_ newFilter: OutlineFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        applyFilter()
    }

    private func applyFilter() {
        displayedEntries = SessionOutlineIndex.filtered(allEntries, filter: filter, query: query)
        var ids: [String] = []
        var byID: [String: OutlineEntry] = [:]
        ids.reserveCapacity(displayedEntries.count)
        for entry in displayedEntries where byID[entry.id] == nil {
            // A diffable list needs unique ids; a repeated id shows once.
            byID[entry.id] = entry
            ids.append(entry.id)
        }
        entriesByID = byID
        apply(ids, to: timelineDataSource)
        updateTimelineChrome()
    }

    /// Shows `ids` and reconfigures every row that stays: rows are keyed by
    /// id, so without it a row kept the highlights, collapse state, or theme
    /// it was first configured with.
    private func apply(_ ids: [String], to dataSource: UICollectionViewDiffableDataSource<Int, String>) {
        let current = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        snapshot.reconfigureItems(ids.filter(current.contains))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func updateTimelineChrome() {
        guard isViewLoaded else { return }
        let palette = palette
        timelineFilterBar.update(
            selected: OutlineFilter.allCases.firstIndex(of: filter) ?? 0,
            isLoading: isLoadingOutline,
            count: displayedEntries.count,
            palette: palette
        )
        outlineBanner.show(
            outlineSnapshot == nil ? outlineLoadErrorMessage.map { "Full outline unavailable: \($0)" } : nil,
            palette: palette
        )
    }

    private func loadOutlineIfNeeded() async {
        guard let loadOutline, !isLoadingOutline, outlineSnapshot == nil else { return }
        isLoadingOutline = true
        updateTimelineChrome()
        defer {
            isLoadingOutline = false
            updateTimelineChrome()
        }

        do {
            let snapshot = try await loadOutline()
            let projectedEntries = snapshot.entries.map(SessionOutlineIndex.entry(from:))
            if projectedEntries.isEmpty, !items.isEmpty {
                outlineLoadErrorMessage = nil
                return
            }
            outlineSnapshot = snapshot
            allEntries = projectedEntries
            outlineLoadErrorMessage = nil
            applyFilter()
        } catch {
            outlineLoadErrorMessage = error.localizedDescription
        }
    }

    /// Jumps the chat to the row, then closes. The timeline applies the jump
    /// on the main-queue turn `onSelect` queues (its observation hop), so the
    /// close waits one turn more: the outline slides away from the landed row
    /// instead of revealing the old spot and then jumping.
    private func selectTimelineEntry(_ id: String) {
        onSelect(id)
        DispatchQueue.main.async { [weak self] in
            self?.close()
        }
    }

    private func close() {
        searchDebounceTask?.cancel()
        onClose()
    }

    // MARK: - Tree

    private func selectTreeFilter(_ mode: SessionTreeFilterMode) {
        guard treeFilter != mode else { return }
        treeFilter = mode
        collapsedTreeNodeIds.removeAll()
        updateTreeChrome()
        Task { [weak self] in
            await self?.loadTreeIfNeeded()
            self?.applyTreeFilter()
        }
    }

    private func loadTreeIfNeeded() async {
        guard let loadTree, !isLoadingTree else { return }
        guard treeSnapshot == nil || treeSnapshotFilter != treeFilter else { return }

        isLoadingTree = true
        updateTreeChrome()
        defer {
            isLoadingTree = false
            updateTreeChrome()
        }

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                let snapshot = try await loadTree(treeFilter)
                treeSnapshot = snapshot
                treeSnapshotFilter = treeFilter
                treeLoadErrorMessage = nil
                collapsedTreeNodeIds.removeAll()
                return
            } catch {
                if attempt < maxAttempts, SessionOutlineTree.shouldRetryLoad(error) {
                    try? await Task.sleep(for: .milliseconds(250 * attempt))
                    if Task.isCancelled { return }
                    continue
                }
                if treeSnapshotFilter != treeFilter {
                    treeSnapshot = nil
                    treeSnapshotFilter = nil
                }
                treeLoadErrorMessage = error.localizedDescription
                return
            }
        }
    }

    private func applyTreeFilter() {
        treeFilteredNodes = SessionOutlineTree.filteredNodes(treeSnapshot, query: query)
        collapsibleTreeNodeIds = SessionOutlineTree.collapsibleNodeIds(in: treeFilteredNodes)
        refreshTreeRows()
    }

    private func refreshTreeRows() {
        let visible = SessionOutlineTree.visibleNodes(treeFilteredNodes, collapsed: collapsedTreeNodeIds)
        let displayNodes = SessionTreeDisplayLayout.displayNodes(
            visibleNodes: visible,
            allNodes: treeSnapshot?.nodes ?? visible
        )
        var ids: [String] = []
        var byID: [String: SessionTreeDisplayNode] = [:]
        for displayNode in displayNodes where byID[displayNode.id] == nil {
            byID[displayNode.id] = displayNode
            ids.append(displayNode.id)
        }
        treeDisplayNodesByID = byID
        apply(ids, to: treeDataSource)
        updateTreeChrome()
    }

    private func updateTreeChrome() {
        guard isViewLoaded else { return }
        let palette = palette
        treeFilterBar.update(
            selected: SessionTreeFilterMode.allCases.firstIndex(of: treeFilter) ?? 0,
            isLoading: isLoadingTree && treeSnapshot != nil,
            count: treeFilteredNodes.count,
            palette: palette
        )

        let unavailable = treeUnavailableConfiguration()
        treeUnavailable.isHidden = unavailable == nil
        treeList.isHidden = unavailable != nil
        if var unavailable {
            unavailable.textProperties.color = UIColor(palette.fg)
            unavailable.secondaryTextProperties.color = UIColor(palette.comment)
            unavailable.imageProperties.tintColor = UIColor(palette.comment)
            unavailable.background.backgroundColor = UIColor(palette.bgDark)
            treeUnavailable.configuration = unavailable
        }
        treeBanner.show(unavailable == nil ? treeNavigateErrorMessage : nil, palette: palette)
    }

    private func treeUnavailableConfiguration() -> UIContentUnavailableConfiguration? {
        if isLoadingTree, treeSnapshot == nil {
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = "Loading session tree…"
            return loading
        }
        guard treeDisplayNodesByID.isEmpty else { return nil }
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: "arrow.triangle.branch")
        if let treeLoadErrorMessage, treeSnapshot == nil {
            empty.text = "Tree unavailable"
            empty.secondaryText = treeLoadErrorMessage
            return empty
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            var noResults = UIContentUnavailableConfiguration.search()
            noResults.text = "No Results for “\(query)”"
            return noResults
        }
        empty.text = "No tree data"
        empty.secondaryText = "This session has no tree entries yet."
        return empty
    }

    private func toggleTreeNodeCollapsed(_ nodeId: String) {
        guard navigatingTreeNodeId == nil else { return }
        if collapsedTreeNodeIds.contains(nodeId) {
            collapsedTreeNodeIds.remove(nodeId)
        } else {
            collapsedTreeNodeIds.insert(nodeId)
        }
        refreshTreeRows()
    }

    private func handleTreeNodeSelection(_ nodeId: String, sourceView: UIView?) {
        treeNavigateErrorMessage = nil
        updateTreeChrome()

        guard onNavigateTreeNode != nil else {
            onSelect(nodeId)
            close()
            return
        }

        guard navigatingTreeNodeId == nil else { return }
        pendingTreeNavigationTargetId = nodeId
        presentTreeNavigationOptions(from: sourceView)
    }

    private func presentTreeNavigationOptions(from sourceView: UIView?) {
        let options = UIAlertController(
            title: "Navigate Session Tree",
            message: "Choose how to handle the branch you leave behind.",
            preferredStyle: .actionSheet
        )
        options.addAction(UIAlertAction(title: "Switch without summary", style: .default) { [weak self] _ in
            self?.beginPendingTreeNavigation(summarize: false, customInstructions: nil)
        })
        options.addAction(UIAlertAction(title: "Summarize abandoned branch", style: .default) { [weak self] _ in
            self?.beginPendingTreeNavigation(summarize: true, customInstructions: nil)
        })
        options.addAction(UIAlertAction(title: "Summarize with custom instructions", style: .default) { [weak self] _ in
            self?.presentSummaryInstructions()
        })
        // Also runs when a popover (iPad) is dismissed by a tap outside it.
        options.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.pendingTreeNavigationTargetId = nil
        })
        if let popover = options.popoverPresentationController {
            let anchor = sourceView ?? view
            popover.sourceView = anchor
            popover.sourceRect = anchor?.bounds ?? .zero
        }
        present(options, animated: true)
    }

    private func presentSummaryInstructions() {
        guard pendingTreeNavigationTargetId != nil else { return }
        let sheet = TreeSummaryInstructionsViewController(
            isNavigating: navigatingTreeNodeId != nil,
            onCancel: { [weak self] in
                guard let sheet = self?.summarySheet else { return }
                Router.finish(sheet)
            },
            onNavigate: { [weak self] text in
                let instructions = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instructions.isEmpty else { return }
                self?.beginPendingTreeNavigation(summarize: true, customInstructions: instructions)
            }
        )
        summarySheet = sheet
        Router.present(
            sheet,
            presentation: .sheet.inNavigation(),
            from: self,
            theme: HostFactory.root(near: self)?.themeStore,
            onDismiss: { [weak self] in
                // Cancel and swipe-down drop the pending switch; Navigate
                // has already taken it.
                guard let self, navigatingTreeNodeId == nil else { return }
                pendingTreeNavigationTargetId = nil
            }
        )
    }

    private func beginPendingTreeNavigation(summarize: Bool, customInstructions: String?) {
        guard let targetId = pendingTreeNavigationTargetId else { return }
        startTreeNavigation(.init(
            targetId: targetId,
            summarize: summarize,
            customInstructions: customInstructions,
            replaceInstructions: customInstructions == nil ? nil : false,
            label: nil
        ))
    }

    private func startTreeNavigation(_ request: SessionTreeNavigationRequest) {
        treeNavigateErrorMessage = nil
        pendingTreeNavigationTargetId = nil
        if let summarySheet {
            Router.finish(summarySheet)
        }

        guard let onNavigateTreeNode else {
            onSelect(request.targetId)
            close()
            return
        }

        guard navigatingTreeNodeId == nil else { return }
        navigatingTreeNodeId = request.targetId
        refreshTreeRows()

        Task { [weak self] in
            let failure: Error?
            do {
                try await onNavigateTreeNode(request)
                failure = nil
            } catch {
                failure = error
            }
            guard let self else { return }
            navigatingTreeNodeId = nil
            treeNavigateErrorMessage = failure?.localizedDescription
            refreshTreeRows()
            if failure == nil {
                close()
            }
        }
    }

    // MARK: - UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        collectionView !== treeList || navigatingTreeNodeId == nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if collectionView === timelineList {
            guard let id = timelineDataSource.itemIdentifier(for: indexPath) else { return }
            selectTimelineEntry(id)
        } else {
            guard let id = treeDataSource.itemIdentifier(for: indexPath) else { return }
            handleTreeNodeSelection(id, sourceView: collectionView.cellForItem(at: indexPath))
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let onFork, indexPaths.count == 1, let indexPath = indexPaths.first else { return nil }
        let forkable: String?
        if collectionView === timelineList {
            forkable = timelineDataSource.itemIdentifier(for: indexPath)
                .flatMap { entriesByID[$0] }
                .flatMap { $0.isForkable ? $0.id : nil }
        } else {
            forkable = treeDataSource.itemIdentifier(for: indexPath)
                .flatMap { treeDisplayNodesByID[$0]?.node }
                .flatMap { SessionOutlineTree.isForkable($0) ? $0.id : nil }
        }
        guard let id = forkable else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Fork from here", image: UIImage(systemName: "arrow.triangle.branch")) { _ in
                    onFork(id)
                    self?.close()
                },
            ])
        }
    }
}

// MARK: - Summary instructions

/// Custom summary guidance before a tree switch. A router sheet above the
/// outline; the text is this sheet's own and goes out with Navigate.
final class TreeSummaryInstructionsViewController: UIViewController, UITextViewDelegate {
    private let isNavigating: Bool
    private let onCancel: () -> Void
    private let onNavigate: (String) -> Void
    private let textView = UITextView()
    private let captionLabel = UILabel()
    private lazy var navigateItem = UIBarButtonItem(
        title: "Navigate",
        image: UIImage(systemName: "arrow.turn.down.right"),
        primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            onNavigate(textView.text)
        }
    )

    init(isNavigating: Bool, onCancel: @escaping () -> Void, onNavigate: @escaping (String) -> Void) {
        self.isNavigating = isNavigating
        self.onCancel = onCancel
        self.onNavigate = onNavigate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Summary Instructions"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.onCancel()
        })
        navigateItem.accessibilityIdentifier = "tree-summary-navigate"
        navigationItem.rightBarButtonItem = navigateItem

        captionLabel.text = "Add extra guidance for what to preserve in the branch summary."
        captionLabel.font = SessionOutlineStyle.font(.caption1)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.numberOfLines = 0
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = self
        textView.accessibilityIdentifier = "tree-summary-instructions"
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.layer.cornerRadius = 12
        textView.layer.cornerCurve = .continuous
        textView.layer.borderWidth = 1

        let stack = UIStackView(arrangedSubviews: [captionLabel, textView])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        updateNavigateEnabled()
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        let palette = (HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()).palette
        view.backgroundColor = UIColor(palette.bg)
        captionLabel.textColor = UIColor(palette.comment)
        textView.textColor = UIColor(palette.fg)
        textView.backgroundColor = UIColor(palette.bgDark)
        textView.layer.borderColor = UIColor(palette.comment.opacity(0.18)).cgColor
    }

    func textViewDidChange(_ textView: UITextView) {
        updateNavigateEnabled()
    }

    private func updateNavigateEnabled() {
        let hasInstructions = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        navigateItem.isEnabled = hasInstructions && !isNavigating
    }
}
