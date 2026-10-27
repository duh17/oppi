import UIKit

/// Skills for the active server (route `.utility(.skills)`): the selected
/// server's row (a switcher menu with several paired servers), the Skills the
/// server resolved grouped by what needs attention, and search in the bar. A
/// row opens the Skill's page through `AppNavigation`, so the route stays
/// tracked. `ServerSkillListPresentation` decides the search, the groups, and
/// which state shows (`ServerSkillCatalogPresentationState`).
///
/// The catalog reloads on every appearance, on pull to refresh, and when the
/// active server changes; choosing another server in the row clears the search.
@MainActor
final class ServerSkillsViewController: UIViewController, UICollectionViewDelegate {
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    private enum Section: Hashable {
        case server, warning, status
        case kind(ServerSkillSectionKind)
    }

    private enum Item: Hashable {
        case server
        case cachedWarning
        case loading
        case unavailable
        case empty
        case noResults
        case skill(String)
    }

    /// Everything the rows read, taken in `updateProperties()` so observation
    /// tracks it and a reconfigured row sees one consistent copy.
    private struct ViewState {
        var server: PairedServer?
        var catalog: ServerSkillCatalogPresentationState
        var presentation: ServerSkillListPresentation
        var skills: [String: ServerSkillSummary]
        var serverStates: [String: ServerBadgeConnectionState]
        /// The symbol in a row's state line is sized when the row is made.
        var contentSize: UIContentSizeCategory
        var themeID: ThemeID
    }

    private let root: AppRootEnvironment
    private let collectionView = ControlScreenList.makeCollectionView()
    private let refreshControl = UIRefreshControl()
    private let search = ScreenSearchController(prompt: String(localized: "Search skills"))
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var changedRows = ChangedRows<Item>()
    private var sidebarToggle: UIBarButtonItem?
    private var state: ViewState?
    private var query = "" {
        didSet { setNeedsUpdateProperties() }
    }
    private var loadTask: Task<Void, Never>?
    /// The server the running or last load asked for, so a change of the
    /// active server loads once.
    private var requestedServerId: String?
    private var isOnScreen = false

    init(root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = String(localized: "Skills")
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
    }

    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "skills.list"
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        search.install(on: self, alwaysVisible: false)
        search.onTextChange = { [weak self] text in
            guard let self, text != query else { return }
            query = text
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        // Like the SwiftUI `.task` it replaces, a load each time it shows.
        if let activeServerId = coordinator.activeServerId {
            load(serverId: activeServerId)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.hostDidAppear(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        loadTask?.cancel()
        loadTask = nil
        requestedServerId = nil
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        ControlScreenList.setBarItems(trailing: [], leading: sidebarItems(), on: navigationItem)

        let servers = coordinator.serverStore.servers
        let activeServerId = coordinator.activeServerId
        let server = ServerSelection.resolve(selectedId: activeServerId, from: servers)
        let store = activeServerId.flatMap { coordinator.connection(for: $0) }?.serverResourceStore
        let presentation = ServerSkillListPresentation(
            skills: activeServerId.flatMap { store?.skills(forServer: $0) } ?? [],
            query: query
        )
        let catalog: ServerSkillCatalogPresentationState
        if let activeServerId, let store {
            let sync = store.syncState(for: .skills, serverId: activeServerId)
            catalog = .resolve(
                hasLoaded: store.hasLoadedSkills(forServer: activeServerId),
                isSyncing: sync.isSyncing,
                lastSyncFailed: sync.lastSyncFailed,
                hasVisibleRows: !presentation.visibleSkills.isEmpty,
                isFilteredNoResults: presentation.isFilteredNoResults
            )
        } else {
            catalog = .unavailable
        }
        state = ViewState(
            server: server,
            catalog: catalog,
            presentation: presentation,
            skills: Dictionary(presentation.allSkills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            serverStates: Dictionary(
                servers.map { ($0.id, HostSwitcherBadgeState.make(for: $0, coordinator: coordinator)) },
                uniquingKeysWith: { first, _ in first }
            ),
            contentSize: traitCollection.preferredContentSizeCategory,
            themeID: root.themeStore.activeThemeID
        )
        applySnapshot()

        // The active server changed under the screen: load its catalog.
        if isOnScreen, let activeServerId, activeServerId != requestedServerId {
            load(serverId: activeServerId)
        }
    }

    /// The sidebar toggle at the split detail root.
    private func sidebarItems() -> [UIBarButtonItem] {
        guard showsSidebarToggle else { return [] }
        let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
        sidebarToggle = toggle
        WorkspaceSplitSidebarToggle.sync(toggle, root: root)
        return [toggle]
    }

    // MARK: - Data

    private func load(serverId: String) {
        loadTask?.cancel()
        requestedServerId = serverId
        loadTask = Task { [weak self] in await self?.reload(serverId: serverId) }
    }

    private func reload(serverId: String) async {
        guard let connection = coordinator.connection(for: serverId),
              let api = connection.apiClient else { return }
        connection.serverResourceStore.switchServer(to: serverId)
        await connection.serverResourceStore.load(serverId: serverId, api: api)
    }

    private func refresh() {
        Task { [weak self] in
            if let self, let activeServerId = coordinator.activeServerId {
                await reload(serverId: activeServerId)
            }
            self?.refreshControl.endRefreshing()
        }
    }

    // MARK: - List

    private func applySnapshot() {
        guard let dataSource, let state else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if state.server != nil {
            snapshot.appendSections([.server])
            snapshot.appendItems([.server], toSection: .server)
        }
        if state.catalog == .cachedOffline, state.server != nil {
            snapshot.appendSections([.warning])
            snapshot.appendItems([.cachedWarning], toSection: .warning)
        }
        switch state.catalog {
        case .firstLoad:
            snapshot.appendSections([.status])
            snapshot.appendItems([.loading], toSection: .status)
        case .unavailable:
            snapshot.appendSections([.status])
            snapshot.appendItems([.unavailable], toSection: .status)
        case .empty:
            snapshot.appendSections([.status])
            snapshot.appendItems([.empty], toSection: .status)
        case .filteredNoResults:
            snapshot.appendSections([.status])
            snapshot.appendItems([.noResults], toSection: .status)
        case .cachedOffline, .content:
            for section in state.presentation.sections {
                snapshot.appendSections([.kind(section.kind)])
                // A diffable list traps on a repeated item; a repeated id shows once.
                var shown = Set<String>()
                snapshot.appendItems(
                    section.skills.filter { shown.insert($0.id).inserted }.map { Item.skill($0.id) },
                    toSection: .kind(section.kind)
                )
            }
        }
        // Only the rows whose inputs changed: reconfiguring the server row
        // closes its open menu.
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
            inputs = [state.server, state.serverStates, coordinator.serverStore.servers.map(\.id)]
        case .cachedWarning, .empty:
            inputs = [state.server?.name]
        case .noResults:
            inputs = [state.presentation.query]
        case .loading, .unavailable:
            inputs = []
        case .skill(let id):
            let skill = state.skills[id]
            inputs = [
                skill?.name, skill?.description, skill?.provenance.label, skill?.packageName,
                skill?.state, state.contentSize,
            ]
        }
        return [AnyHashable(state.themeID), AnyHashable(inputs)]
    }

    private func installDataSource() {
        let server = UICollectionView.CellRegistration<ServerCatalogServerRowCell, Item> { [weak self] cell, _, _ in
            guard let self, let state, let server = state.server,
                  let serverState = state.serverStates[server.id] else { return }
            cell.configure(
                server: server,
                state: serverState,
                palette: palette,
                menu: state.serverStates.count > 1 ? serverMenu() : nil
            )
        }
        let notice = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.cell()
            content.text = "Showing cached settings for \(state?.server?.name ?? "this server"). Pull to retry."
            content.image = UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.textProperties.adjustsFontForContentSizeCategory = true
            content.textProperties.color = UIColor(palette.orange)
            content.imageProperties.tintColor = UIColor(palette.orange)
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "skills.cachedWarning"
        }
        let message = UICollectionView.CellRegistration<ServerCatalogStateCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            let palette = palette
            switch item {
            case .loading:
                cell.configureLoading("Loading skills…", palette: palette)
            case .unavailable:
                cell.configureMessage(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Skills Unavailable",
                    detail: "The selected server has no cached Skills catalog.",
                    palette: palette,
                    retry: (identifier: "skills.retry", action: { [weak self] in self?.retry() })
                )
            case .noResults:
                cell.configureMessage(
                    systemImage: "magnifyingglass",
                    title: "No Results",
                    detail: "No skills match “\(state?.presentation.query ?? "")”.",
                    palette: palette
                )
            default:
                cell.configureMessage(
                    systemImage: "sparkles.rectangle.stack",
                    title: "No Skills Found",
                    detail: "Pi did not resolve any skills on \(state?.server?.name ?? "this server").",
                    palette: palette
                )
            }
        }
        let skill = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
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
            case .loading, .unavailable, .empty, .noResults:
                collectionView.dequeueConfiguredReusableCell(using: message, for: indexPath, item: item)
            case .skill:
                collectionView.dequeueConfiguredReusableCell(using: skill, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
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
                query = ""
                search.setText("")
                load(serverId: server.id)
            }
        )
    }

    private func retry() {
        guard let activeServerId = coordinator.activeServerId else { return }
        load(serverId: activeServerId)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        guard let state, case .skill(let id) = item, let skill = state.skills[id] else { return }
        ControlScreenList.background(cell, grouped: true, palette: palette)
        ControlScreenList.buttonRow(
            cell,
            identifier: "skills.row.\(skill.id)",
            label: ServerSkillListPresentation.accessibilityLabel(for: skill)
        ) { [weak self] in
            self?.open(skill)
        }
        cell.contentConfiguration = Self.rowContent(skill, palette: palette)
        cell.accessories = [.disclosureIndicator()]
    }

    // MARK: - Rows

    /// The Skill's icon beside its name, with its description, package,
    /// source, and state as the secondary text. The text styles and sizes are
    /// the list kit's.
    private static func rowContent(_ skill: ServerSkillSummary, palette: ThemePalette) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = skill.name
        content.textProperties.color = UIColor(palette.fg)
        content.image = UIImage(systemName: "sparkles.rectangle.stack")
        content.imageProperties.tintColor = UIColor(palette.blue)

        let comment = UIColor(palette.comment)
        let secondary = NSMutableAttributedString()
        func addLine(_ text: String, color: UIColor) {
            if secondary.length > 0 { secondary.append(NSAttributedString(string: "\n")) }
            secondary.append(NSAttributedString(string: text, attributes: [.foregroundColor: color]))
        }
        if !skill.description.isEmpty { addLine(skill.description, color: comment) }
        if let packageName = skill.packageName { addLine(packageName, color: comment) }
        addLine(skill.provenance.label, color: comment)

        // The state, led by its symbol (orange when the Skill needs attention).
        let isIssue = skill.state == .error || skill.state == .unknown
        // The symbol takes the size of the secondary text it leads.
        let secondaryFont = UIListContentConfiguration.subtitleCell().secondaryTextProperties.font
        let stateColor = UIColor(isIssue ? palette.orange : palette.comment)
        let symbol = isIssue ? "exclamationmark.triangle.fill" : (skill.state == .enabled ? "checkmark.circle" : "minus.circle")
        if let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: secondaryFont))?
            .withTintColor(stateColor, renderingMode: .alwaysOriginal) {
            secondary.append(NSAttributedString(string: "\n"))
            secondary.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            secondary.append(NSAttributedString(
                string: " " + ServerSkillListPresentation.stateLabel(for: skill.state),
                attributes: [.foregroundColor: stateColor]
            ))
        }
        content.secondaryAttributedText = secondary
        content.secondaryTextProperties.numberOfLines = 0
        return content
    }

    // MARK: - Actions

    private func open(_ skill: ServerSkillSummary) {
        guard let activeServerId = coordinator.activeServerId else { return }
        root.navigation.openServerResourceDetail(ServerResourceDetailNavTarget(
            serverId: activeServerId,
            kind: .skill,
            resourceId: skill.id
        ))
    }
}
