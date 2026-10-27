import UIKit

/// Extensions for the active server (route `.utility(.extensions)`): the
/// selected-server row, then the catalog in sections (Built-in, Needs
/// Attention, Enabled and Disabled Pi Extensions), with search, pull to
/// refresh, and its loading, offline, empty, and failed states in the list. A
/// row opens the extension's detail through `AppNavigation`, so the route
/// survives a stack/split change. The screen follows the active server and
/// reloads the catalog when it changes and each time it appears.
///
/// What the list shows is `ServerExtensionListPresentation` and
/// `ServerExtensionCatalogPresentationState`.
@MainActor
final class ServerExtensionsViewController: UIViewController, UICollectionViewDelegate {
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    private enum Section: Hashable {
        case server, notice, state, noPi
        case kind(ServerExtensionSectionKind)
    }

    private enum Item: Hashable {
        case server
        case cachedWarning
        case firstLoad
        case unavailable
        case noResults
        case noPi
        case row(String)
    }

    /// Everything the rows read, taken in `updateProperties()` so observation
    /// tracks it and a reconfigured row sees one consistent copy.
    private struct ViewState {
        var activeServerId: String?
        var server: PairedServer?
        var serverState: ServerBadgeConnectionState?
        var hasSeveralServers: Bool
        var presentation: ServerExtensionListPresentation
        var catalog: ServerExtensionCatalogPresentationState
        /// The rows' extensions by id, built once per pass.
        var resources: [String: ServerExtensionSummary]
        var themeID: ThemeID
        /// A size change re-measures every row (line limits, wrapped labels).
        var contentSize: UIContentSizeCategory
    }

    private let root: AppRootEnvironment
    private let collectionView = ControlScreenList.makeCollectionView()
    private let refreshControl = UIRefreshControl()
    private let search = ScreenSearchController(prompt: "Search extensions")
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var changedRows = ChangedRows<Item>()
    private var sidebarToggle: UIBarButtonItem?
    private var state: ViewState?

    private var searchText = "" {
        didSet { setNeedsUpdateProperties() }
    }
    private var refreshTask: Task<Void, Never>?
    /// The server the catalog was last requested for, so a switch reloads once.
    private var refreshedServerId: String?
    private var isOnScreen = false

    init(root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = "Extensions"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.delegate = self
        // A row that rearranges with the text size re-measures.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.accessibilityIdentifier = "extensions.list"
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in self?.pullToRefresh() }, for: .valueChanged)
        ModelProvidersList.pinReadable(collectionView, in: view, maxWidth: IPadReadableContentWidth.form)
        installDataSource()

        search.install(on: self, alwaysVisible: false)
        search.onTextChange = { [weak self] text in
            guard let self, text != searchText else { return }
            searchText = text
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        // A load each time the screen shows, as the hosted screen's task did.
        if let serverId = coordinator.activeServerId {
            refreshedServerId = serverId
            startRefresh(serverId: serverId)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.hostDidAppear(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        refreshTask?.cancel()
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        ControlScreenList.setBarItems(trailing: [], leading: sidebarItems(), on: navigationItem)

        let activeServerId = coordinator.activeServerId
        let servers = coordinator.serverStore.servers
        let server = ServerSelection.resolve(selectedId: activeServerId, from: servers)
        let store = activeServerId.flatMap { coordinator.connection(for: $0) }?.serverResourceStore
        let presentation = ServerExtensionListPresentation(
            extensions: activeServerId.flatMap { store?.extensions(forServer: $0) } ?? [],
            query: searchText
        )
        let catalog: ServerExtensionCatalogPresentationState
        if let activeServerId, let store {
            catalog = .resolve(
                hasLoaded: store.hasLoadedExtensions(forServer: activeServerId),
                lastSyncFailed: store.syncState(for: .extensions, serverId: activeServerId).lastSyncFailed,
                hasVisibleRows: !presentation.visibleExtensions.isEmpty,
                isFilteredNoResults: presentation.isFilteredNoResults
            )
        } else {
            catalog = .unavailable
        }
        state = ViewState(
            activeServerId: activeServerId,
            server: server,
            serverState: server.map { HostSwitcherBadgeState.make(for: $0, coordinator: coordinator) },
            hasSeveralServers: servers.count > 1,
            presentation: presentation,
            catalog: catalog,
            resources: Dictionary(
                presentation.visibleExtensions.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            themeID: root.themeStore.activeThemeID,
            contentSize: traitCollection.preferredContentSizeCategory
        )
        search.setText(searchText)

        // The visible server changed (the pill, a link, a pairing): load its catalog.
        if isOnScreen, let activeServerId, activeServerId != refreshedServerId {
            refreshedServerId = activeServerId
            startRefresh(serverId: activeServerId)
        }
        applySnapshot()
    }

    /// The sidebar toggle at the split detail root.
    private func sidebarItems() -> [UIBarButtonItem] {
        guard showsSidebarToggle else { return [] }
        let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
        sidebarToggle = toggle
        WorkspaceSplitSidebarToggle.sync(toggle, root: root)
        return [toggle]
    }

    // MARK: - List

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.backgroundColor = .clear
            let section = self?.dataSource?.sectionIdentifier(for: sectionIndex)
            if case .kind = section {
                configuration.headerMode = .supplementary
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func applySnapshot() {
        guard let dataSource, let state else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if state.server != nil {
            snapshot.appendSections([.server])
            snapshot.appendItems([.server], toSection: .server)
            if state.catalog == .cachedOffline {
                snapshot.appendSections([.notice])
                snapshot.appendItems([.cachedWarning], toSection: .notice)
            }
        }
        switch state.catalog {
        case .firstLoad:
            snapshot.appendSections([.state])
            snapshot.appendItems([.firstLoad], toSection: .state)
        case .unavailable:
            snapshot.appendSections([.state])
            snapshot.appendItems([.unavailable], toSection: .state)
        case .filteredNoResults:
            snapshot.appendSections([.state])
            snapshot.appendItems([.noResults], toSection: .state)
        case .cachedOffline, .content:
            // A diffable list traps on a repeated item; a repeated id shows once.
            var shown = Set<String>()
            for section in state.presentation.sections {
                snapshot.appendSections([.kind(section.kind)])
                snapshot.appendItems(
                    section.extensions.filter { shown.insert($0.id).inserted }.map { Item.row($0.id) },
                    toSection: .kind(section.kind)
                )
            }
            if state.presentation.hasNoPiExtensions {
                snapshot.appendSections([.noPi])
                snapshot.appendItems([.noPi], toSection: .noPi)
            }
        }
        // Only the rows whose inputs changed, so an open server menu survives a redraw.
        let current = dataSource.snapshot()
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { rowInputs($0, state: state) }
        snapshot.reconfigureItems(changed.filter { current.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// What a row draws from, besides its own identity.
    private func rowInputs(_ item: Item, state: ViewState) -> AnyHashable {
        let inputs: [AnyHashable]
        switch item {
        case .server:
            inputs = [
                state.server?.id, state.server?.name, state.server?.resolvedBadgeIcon.symbolName,
                state.serverState, state.hasSeveralServers,
            ]
        case .cachedWarning:
            inputs = [state.server?.name]
        case .noResults:
            inputs = [state.presentation.query]
        case .firstLoad, .unavailable, .noPi:
            inputs = []
        case .row(let id):
            guard let resource = state.resources[id] else { return AnyHashable(state.themeID) }
            inputs = [
                resource.name, resource.description, resource.packageName, resource.provenance.label,
                resource.state, resource.kind,
            ]
        }
        return [AnyHashable(state.themeID), AnyHashable(state.contentSize), AnyHashable(inputs)]
    }

    private func installDataSource() {
        let server = UICollectionView.CellRegistration<ServerCatalogServerRowCell, Item> { [weak self] cell, _, _ in
            guard let self, let state, let server = state.server, let serverState = state.serverState else { return }
            cell.configure(
                server: server,
                state: serverState,
                palette: palette,
                menu: state.hasSeveralServers ? serverMenu() : nil
            )
        }
        let notice = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self, let server = state?.server else { return }
            var content = UIListContentConfiguration.cell()
            content.text = "Showing cached settings for \(server.name). Pull to retry."
            content.image = UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            content.textProperties.font = .scaled(.subheadline)
            content.textProperties.adjustsFontForContentSizeCategory = true
            content.textProperties.color = UIColor(palette.orange)
            content.imageProperties.tintColor = UIColor(palette.orange)
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "extensions.cachedWarning"
        }
        let message = UICollectionView.CellRegistration<ServerCatalogStateCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            let palette = palette
            switch item {
            case .firstLoad:
                cell.configureLoading("Loading extensions…", palette: palette)
            case .unavailable:
                cell.configureMessage(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Extensions Unavailable",
                    detail: "The selected server has no cached Extensions catalog.",
                    palette: palette,
                    retry: (identifier: "extensions.retry", action: { [weak self] in self?.retry() })
                )
            case .noResults:
                cell.configureMessage(
                    systemImage: "magnifyingglass",
                    title: "No Results",
                    detail: "No extensions match “\(state?.presentation.query ?? "")”.",
                    palette: palette
                )
            default:
                cell.configureMessage(
                    systemImage: "puzzlepiece.extension",
                    title: "No Pi Extensions Found",
                    detail: "Configure Pi extensions in ~/.pi/agent/extensions or Pi user settings.",
                    palette: palette
                )
            }
        }
        let row = UICollectionView.CellRegistration<ServerExtensionRowCell, Item> { [weak self] cell, _, item in
            guard let self, case .row(let id) = item, let resource = state?.resources[id] else { return }
            cell.configure(resource: resource, palette: palette) { [weak self] in self?.open(id) }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            if case .kind(let kind) = self?.dataSource?.sectionIdentifier(for: indexPath.section) {
                content.text = kind.rawValue
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .server:
                collectionView.dequeueConfiguredReusableCell(using: server, for: indexPath, item: item)
            case .cachedWarning:
                collectionView.dequeueConfiguredReusableCell(using: notice, for: indexPath, item: item)
            case .firstLoad, .unavailable, .noResults, .noPi:
                collectionView.dequeueConfiguredReusableCell(using: message, for: indexPath, item: item)
            case .row:
                collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    // MARK: - Selection

    /// Rows open themselves through their button; selecting one runs the same
    /// owner action, so the two can never diverge.
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .row = dataSource?.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if case .row(let id) = dataSource?.itemIdentifier(for: indexPath) { open(id) }
    }

    // MARK: - Actions

    private func open(_ resourceId: String) {
        guard let serverId = coordinator.activeServerId else { return }
        // Opens through `AppNavigation` so the route stays tracked.
        root.navigation.openServerResourceDetail(ServerResourceDetailNavTarget(
            serverId: serverId,
            kind: .extension,
            resourceId: resourceId
        ))
    }

    private func retry() {
        guard let serverId = coordinator.activeServerId else { return }
        startRefresh(serverId: serverId)
    }

    /// The server row's menu (`ServerCatalogServerMenu`); after a switch the
    /// list clears its search and loads the new server's catalog.
    private func serverMenu() -> UIMenu {
        ServerCatalogServerMenu.make(
            coordinator: coordinator,
            navigation: root.navigation,
            shownServerId: { [weak self] in self?.state?.server?.id },
            onSwitched: { [weak self] server in
                guard let self else { return }
                searchText = ""
                search.setText("")
                refreshedServerId = server.id
                startRefresh(serverId: server.id)
            }
        )
    }

    // MARK: - Data

    private func pullToRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            defer { self?.refreshControl.endRefreshing() }
            if let serverId = self?.coordinator.activeServerId {
                await self?.refresh(serverId: serverId)
            }
        }
    }

    private func startRefresh(serverId: String) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh(serverId: serverId) }
    }

    private func refresh(serverId: String) async {
        guard let connection = coordinator.connection(for: serverId),
              let api = connection.apiClient else { return }
        connection.serverResourceStore.switchServer(to: serverId)
        await connection.serverResourceStore.load(serverId: serverId, api: api)
    }
}
