import UIKit

/// Extensions for the active server (route `.utility(.extensions)`): the
/// selected-server row, then Pi extensions and plugins in sections (Built-in,
/// Needs Attention, Enabled, Disabled), with search, pull to refresh, and its
/// loading, offline, empty, and failed states in the list. Reload (a bar
/// button) reloads the server's plugins; its report is the Last Reload
/// section, kept per server by the store, until the next one. A
/// row opens the extension's detail through `AppNavigation`, so the route
/// survives a stack/split change. The screen follows the active server and
/// reloads the catalog when it changes and each time it appears.
///
/// A `ListScreenController`: the base owns the list, the state rows, and the
/// load. What the list shows is `ServerExtensionListPresentation` and
/// `ServerExtensionCatalogPresentationState`.
@MainActor
final class ServerExtensionsViewController: ListScreenController<ServerExtensionsViewController.Section, ServerExtensionsViewController.Item> {
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    enum Section: Hashable, Sendable {
        case server, notice, reload, state, noPi
        case kind(ServerExtensionSectionKind)
    }

    enum Item: Hashable, Sendable {
        case server
        case cachedWarning
        case pluginsUnavailable
        case reloadLine(String)
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
        var pluginsUnavailable: String?
        var reload: ServerPluginReloadState?
        var canReload: Bool
        /// The rows' extensions by id, built once per pass.
        var resources: [String: ServerExtensionSummary]
        /// A size change re-measures every row (line limits, wrapped labels).
        var contentSize: UIContentSizeCategory
    }

    private let root: AppRootEnvironment
    private let search = ScreenSearchController(prompt: "Search extensions")
    private var sidebarToggle: UIBarButtonItem?
    private lazy var reloadItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: String(localized: "Reload"),
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.reloadPlugins() }
        )
        item.accessibilityIdentifier = "extensions.reload"
        item.accessibilityLabel = String(localized: "Reload Plugins")
        return item
    }()
    private var state: ViewState?

    private var searchText = "" {
        didSet { setNeedsUpdateProperties() }
    }

    init(root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        super.init(title: "Extensions", listIdentifier: "extensions.list", headers: true)
        traitOverrides.appRootEnvironment = root
    }

    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // A row that rearranges with the text size re-measures.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.hostDidAppear(self)
    }

    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The active server's catalog: another server is another catalog.
    override func loadSubject() -> AnyHashable? { AnyHashable(coordinator.activeServerId) }

    /// A switched server starts its own search: the old one's query would filter
    /// the new server's catalog for an extension it never had.
    override func subjectDidChange() {
        searchText = ""
        search.setText("")
    }

    override func updateProperties() {
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
        let reload = activeServerId.flatMap { store?.pluginReload(forServer: $0) }
        let isConnected = activeServerId.flatMap { coordinator.connection(for: $0) }?.apiClient != nil
        state = ViewState(
            activeServerId: activeServerId,
            server: server,
            serverState: server.map { HostSwitcherBadgeState.make(for: $0, coordinator: coordinator) },
            hasSeveralServers: servers.count > 1,
            presentation: presentation,
            catalog: catalog,
            pluginsUnavailable: activeServerId.flatMap { store?.pluginsUnavailable(forServer: $0) },
            reload: reload,
            canReload: isConnected && reload != .reloading,
            resources: Dictionary(
                presentation.visibleExtensions.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            contentSize: traitCollection.preferredContentSizeCategory
        )
        super.updateProperties()
        reloadItem.isEnabled = state?.canReload == true
        ListScreen.setBarItems(trailing: [reloadItem], leading: sidebarItems(), on: navigationItem)
        search.setText(searchText)
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

    override func sections() -> [ListSection<Section, Item>] {
        guard let state else { return [] }
        var sections: [ListSection<Section, Item>] = []
        if state.server != nil {
            sections.append(ListSection(.server, items: [.server]))
            let notices: [Item] = [
                state.catalog == .cachedOffline ? .cachedWarning : nil,
                state.pluginsUnavailable == nil ? nil : .pluginsUnavailable,
            ].compactMap { $0 }
            if !notices.isEmpty {
                sections.append(ListSection(.notice, items: notices))
            }
        }
        if let reload = state.reload {
            sections.append(ListSection(
                .reload,
                header: String(localized: "Last Reload"),
                items: ServerPluginReloadPresentation.lines(for: reload).map { .reloadLine($0.id) }
            ))
        }
        if let row = stateRow(hasContent: !state.presentation.visibleExtensions.isEmpty, isLoading: state.catalog == .firstLoad, failure: failureReport(
            reason: state.catalog == .unavailable
                ? String(localized: "The selected server has no cached Extensions catalog.")
                : nil
        )) {
            sections.append(ListSection(.state, items: [], state: row))
        }
        switch state.catalog {
        case .cachedOffline, .content:
            // A diffable list traps on a repeated item; a repeated id shows once.
            var shown = Set<String>()
            for section in state.presentation.sections {
                sections.append(ListSection(
                    .kind(section.kind),
                    header: section.kind.rawValue,
                    items: section.extensions.filter { shown.insert($0.id).inserted }.map { Item.row($0.id) }
                ))
            }
            if state.presentation.hasNoPiExtensions {
                sections.append(ListSection(.noPi, items: [], state: ListStateRow(
                    state: .empty(
                        title: String(
                            localized: "No Pi extensions found. Configure Pi extensions in ~/.pi/agent/extensions or Pi user settings."
                        ),
                        systemImage: "puzzlepiece.extension"
                    ),
                    identifier: "extensions.noPi"
                )))
            }
        case .firstLoad, .unavailable, .filteredNoResults:
            break
        }
        return sections
    }

    /// A reload swaps the catalog's sections; the rows should not slide.
    override var animatesUpdates: Bool { false }

    /// The catalog's groups carry a heading; the server, notice, and state rows
    /// do not.
    override func showsHeader(for section: Section) -> Bool {
        switch section {
        case .kind, .reload: true
        default: false
        }
    }

    /// The caption the catalog's compact loading row shows.
    override func loadingCaption() -> String? { String(localized: "Loading extensions…") }

    override func failureTitle() -> String? { String(localized: "Couldn't Load Extensions") }

    /// A search that matched nothing: the one empty state this page has.
    override func emptyState() -> LoadState? {
        guard let state, state.catalog == .filteredNoResults else { return nil }
        return .empty(
            title: String(localized: "No extensions match “\(state.presentation.query)”."),
            systemImage: "puzzlepiece.extension"
        )
    }

    override func inputs(of item: Item) -> AnyHashable {
        guard let state else { return AnyHashable(0) }
        let inputs: [AnyHashable]
        switch item {
        case .server:
            inputs = [
                state.server?.id, state.server?.name, state.server?.resolvedBadgeIcon,
                state.serverState, state.hasSeveralServers,
            ]
        case .cachedWarning:
            inputs = [state.server?.name]
        case .pluginsUnavailable:
            inputs = [state.pluginsUnavailable]
        case .reloadLine(let id):
            inputs = [state.reload.flatMap { reload in
                ServerPluginReloadPresentation.lines(for: reload).first { $0.id == id }
            }]
        case .row(let id):
            guard let resource = state.resources[id] else { return AnyHashable(0) }
            inputs = [
                resource.name, resource.description, resource.packageName, resource.provenance.label,
                resource.state, resource.kind, resource.kinds, resource.source, resource.plugin?.required,
                resource.plugin?.kept, resource.warnings.first,
            ]
        }
        return [AnyHashable(state.contentSize), AnyHashable(inputs)]
    }

    // MARK: - Selection

    override func isSelectable(_ item: Item) -> Bool {
        if case .row = item { return true }
        return false
    }

    /// Rows open themselves through their button; selecting one runs the same
    /// owner action, so the two can never diverge.
    override func select(_ item: Item) {
        if case .row(let id) = item { open(id) }
    }

    // MARK: - Actions

    /// Reloads the active server's plugins. The store keeps the report on the server that was
    /// asked, so a switch meanwhile cannot show it under another server.
    func reloadPlugins() {
        guard let serverId = coordinator.activeServerId,
              let connection = coordinator.connection(for: serverId),
              let api = connection.apiClient else { return }
        let store = connection.serverResourceStore
        Task { await store.reloadPlugins(serverId: serverId, api: api) }
    }

    private func open(_ resourceId: String) {
        guard let serverId = coordinator.activeServerId else { return }
        // Opens through `AppNavigation` so the route stays tracked.
        root.navigation.openServerResourceDetail(ServerResourceDetailNavTarget(
            serverId: serverId,
            kind: .extension,
            resourceId: resourceId
        ))
    }

    /// The server row's menu (`ServerCatalogServerMenu`); after a switch the
    /// list clears its search and loads the new server's catalog.
    private func serverMenu() -> UIMenu {
        ServerCatalogServerMenu.make(
            coordinator: coordinator,
            navigation: root.navigation,
            shownServerId: { [weak self] in self?.state?.server?.id },
            onSwitched: { [weak self] _ in
                guard let self else { return }
                searchText = ""
                search.setText("")
            }
        )
    }

    // MARK: - Rows

    private lazy var serverRow = UICollectionView.CellRegistration<ServerCatalogServerRowCell, Item> { [weak self] cell, _, _ in
        guard let self, let state, let server = state.server, let serverState = state.serverState else { return }
        cell.configure(
            server: server,
            state: serverState,
            palette: palette,
            menu: state.hasSeveralServers ? serverMenu() : nil
        )
    }

    private lazy var cachedWarningRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
        guard let self, let server = state?.server else { return }
        var content = UIListContentConfiguration.cell()
        content.text = String(localized: "Showing cached settings for \(server.name). Pull to retry.")
        content.image = UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath")
        content.textProperties.font = .scaled(.subheadline)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = palette.ui.orange
        content.imageProperties.tintColor = palette.ui.orange
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "extensions.cachedWarning"
    }

    private lazy var pluginsUnavailableRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
        guard let self, let reason = state?.pluginsUnavailable else { return }
        var content = UIListContentConfiguration.subtitleCell()
        content.text = String(localized: "Plugins could not be loaded")
        content.secondaryText = reason
        content.image = UIImage(systemName: "exclamationmark.triangle.fill")
        content.textProperties.font = .scaled(.subheadline, .semibold)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = palette.ui.orange
        content.secondaryTextProperties.font = .scaled(.footnote)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = palette.ui.comment
        content.imageProperties.tintColor = palette.ui.orange
        cell.contentConfiguration = content
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "\(content.text ?? ""), \(reason)"
        cell.accessibilityIdentifier = "extensions.pluginsUnavailable"
    }

    private lazy var reloadLineRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
        guard let self, case .reloadLine(let id) = item, let reload = state?.reload,
              let line = ServerPluginReloadPresentation.lines(for: reload).first(where: { $0.id == id }) else { return }
        var content = line.detail == nil ? UIListContentConfiguration.cell() : UIListContentConfiguration.subtitleCell()
        content.text = line.text
        content.secondaryText = line.detail
        content.image = UIImage(systemName: line.symbol)
        let color = line.isIssue ? palette.ui.orange : palette.ui.fg
        content.textProperties.font = .scaled(.subheadline)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = color
        content.secondaryTextProperties.font = .scaled(.caption1)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = palette.ui.comment
        content.imageProperties.tintColor = line.isIssue ? palette.ui.orange : palette.ui.comment
        cell.contentConfiguration = content
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = [line.text, line.detail].compactMap { $0 }.joined(separator: ", ")
        cell.accessibilityIdentifier = "extensions.reload.\(id)"
    }

    private lazy var extensionRow = UICollectionView.CellRegistration<ServerExtensionRowCell, Item> { [weak self] cell, _, item in
        guard let self, case .row(let id) = item, let resource = state?.resources[id] else { return }
        cell.configure(resource: resource, palette: palette) { [weak self] in self?.open(id) }
    }

    // A registration must exist before the first row is dequeued.
    override func prepareRegistrations() {
        _ = (serverRow, cachedWarningRow, pluginsUnavailableRow, reloadLineRow, extensionRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .server:
            collectionView.dequeueConfiguredReusableCell(using: serverRow, for: indexPath, item: item)
        case .cachedWarning:
            collectionView.dequeueConfiguredReusableCell(using: cachedWarningRow, for: indexPath, item: item)
        case .pluginsUnavailable:
            collectionView.dequeueConfiguredReusableCell(using: pluginsUnavailableRow, for: indexPath, item: item)
        case .reloadLine:
            collectionView.dequeueConfiguredReusableCell(using: reloadLineRow, for: indexPath, item: item)
        case .row:
            collectionView.dequeueConfiguredReusableCell(using: extensionRow, for: indexPath, item: item)
        }
    }

    // MARK: - Data

    /// The active server's Extensions catalog: the base runs it on every
    /// appearance, on pull to refresh, and when the active server changes. The
    /// catalog's own state (loading, syncing, failed) is the store's, so the
    /// state row stays the store's too.
    override func load() async throws {
        guard let serverId = coordinator.activeServerId else { return }
        guard let connection = coordinator.connection(for: serverId),
              let api = connection.apiClient else { return }
        connection.serverResourceStore.switchServer(to: serverId)
        await connection.serverResourceStore.load(serverId: serverId, api: api)
    }
}
