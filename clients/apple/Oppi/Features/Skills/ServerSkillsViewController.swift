import UIKit

/// Skills for the active server (route `.utility(.skills)`): the selected
/// server's row (a switcher menu with several paired servers), the Skills the
/// server resolved grouped by what needs attention, and search in the bar. A
/// row opens the Skill's page through `AppNavigation`, so the route stays
/// tracked. `ServerSkillListPresentation` decides the search, the groups, and
/// which state shows (`ServerSkillCatalogPresentationState`).
///
/// A `ListScreenController`: the base owns the list, the state row, and the
/// load. The catalog reloads on every appearance, on pull to refresh, and when
/// the active server changes; choosing another server in the row clears the
/// search.
@MainActor
final class ServerSkillsViewController: ListScreenController<ServerSkillsViewController.Section, ServerSkillsViewController.Item> {
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    enum Section: Hashable, Sendable {
        case server, warning, status
        case kind(ServerSkillSectionKind)
    }

    enum Item: Hashable, Sendable {
        case server
        case cachedWarning
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
    }

    private let root: AppRootEnvironment
    private let search = ScreenSearchController(prompt: String(localized: "Search skills"))
    private var sidebarToggle: UIBarButtonItem?
    private var state: ViewState?
    private var query = "" {
        didSet { setNeedsUpdateProperties() }
    }

    init(root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        super.init(title: String(localized: "Skills"), listIdentifier: "skills.list", headers: true)
        traitOverrides.appRootEnvironment = root
    }

    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.hostDidAppear(self)
    }

    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The active server's catalog: another server is another catalog.
    override func loadSubject() -> AnyHashable? { AnyHashable(coordinator.activeServerId) }

    /// A switched server starts its own search: the old one's query would
    /// filter the new server's catalog for a Skill it never had.
    override func subjectDidChange() {
        query = ""
        search.setText("")
    }

    override func updateProperties() {
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
            contentSize: traitCollection.preferredContentSizeCategory
        )
        super.updateProperties()
        ListScreen.setBarItems(trailing: [], leading: sidebarItems(), on: navigationItem)
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

    /// The active server's Skills catalog: the base runs it on every appearance,
    /// on pull to refresh, and when the active server changes. The catalog's own
    /// state (loading, syncing, failed) is the store's, so the state row stays
    /// the store's too.
    override func load() async throws {
        guard let serverId = coordinator.activeServerId else { return }
        guard let connection = coordinator.connection(for: serverId),
              let api = connection.apiClient else { return }
        connection.serverResourceStore.switchServer(to: serverId)
        await connection.serverResourceStore.load(serverId: serverId, api: api)
    }

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        guard let state else { return [] }
        var sections: [ListSection<Section, Item>] = []
        if state.server != nil {
            sections.append(ListSection(.server, items: [.server]))
        }
        if state.catalog == .cachedOffline, state.server != nil {
            sections.append(ListSection(.warning, items: [.cachedWarning]))
        }
        if let row = stateRow(hasContent: !state.presentation.visibleSkills.isEmpty, isLoading: state.catalog == .firstLoad, failure: failureReport(
            reason: state.catalog == .unavailable
                ? String(localized: "The selected server has no cached Skills catalog.")
                : nil
        )) {
            sections.append(ListSection(.status, items: [], state: row))
        }
        switch state.catalog {
        case .cachedOffline, .content:
            for section in state.presentation.sections {
                // A diffable list traps on a repeated item; a repeated id shows once.
                var shown = Set<String>()
                sections.append(ListSection(
                    .kind(section.kind),
                    header: section.kind.rawValue,
                    items: section.skills.filter { shown.insert($0.id).inserted }.map { Item.skill($0.id) }
                ))
            }
        case .firstLoad, .unavailable, .empty, .filteredNoResults:
            break
        }
        return sections
    }

    /// A reload swaps the catalog's sections; the rows should not slide.
    override var animatesUpdates: Bool { false }

    /// The catalog's groups carry a heading; the server, warning, and state
    /// rows do not.
    override func showsHeader(for section: Section) -> Bool {
        if case .kind = section { return true }
        return false
    }

    /// The caption the catalog's compact loading row shows.
    override func loadingCaption() -> String? { String(localized: "Loading skills…") }

    override func failureTitle() -> String? { String(localized: "Couldn't Load Skills") }

    /// Nothing resolved, or a search that matched nothing: the two empty states
    /// this page has.
    override func emptyState() -> LoadState? {
        guard let state else { return nil }
        switch state.catalog {
        case .filteredNoResults:
            return .empty(
                title: String(localized: "No skills match “\(state.presentation.query)”."),
                systemImage: "sparkles.rectangle.stack"
            )
        case .empty:
            return .empty(
                title: String(
                    localized: "No skills found. Pi did not resolve any skills on \(state.server?.name ?? String(localized: "this server"))."
                ),
                systemImage: "sparkles.rectangle.stack"
            )
        default:
            return nil
        }
    }

    override func inputs(of item: Item) -> AnyHashable {
        guard let state else { return AnyHashable(0) }
        switch item {
        case .server:
            return AnyHashable([
                AnyHashable(state.server), AnyHashable(state.serverStates),
                AnyHashable(coordinator.serverStore.servers.map(\.id)),
            ])
        case .cachedWarning:
            return AnyHashable([AnyHashable(state.server?.name), AnyHashable(state.contentSize)])
        case .skill(let id):
            guard let skill = state.skills[id] else { return AnyHashable(0) }
            return AnyHashable([
                AnyHashable(skill.name), AnyHashable(skill.description), AnyHashable(skill.provenance.label),
                AnyHashable(skill.packageName), AnyHashable(skill.state), AnyHashable(state.contentSize),
            ])
        }
    }

    // MARK: - Rows

    private lazy var serverRow = UICollectionView.CellRegistration<ServerCatalogServerRowCell, Item> { [weak self] cell, _, _ in
        guard let self, let state, let server = state.server,
              let serverState = state.serverStates[server.id] else { return }
        cell.configure(
            server: server,
            state: serverState,
            palette: palette,
            menu: state.serverStates.count > 1 ? serverMenu() : nil
        )
    }

    private lazy var cachedWarningRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        var content = UIListContentConfiguration.cell()
        content.text = "Showing cached settings for \(state?.server?.name ?? "this server"). Pull to retry."
        content.image = UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath")
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = palette.ui.orange
        content.imageProperties.tintColor = palette.ui.orange
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "skills.cachedWarning"
    }

    // A registration must exist before the first row is dequeued.
    override func prepareRegistrations() {
        _ = (serverRow, cachedWarningRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .server:
            collectionView.dequeueConfiguredReusableCell(using: serverRow, for: indexPath, item: item)
        case .cachedWarning:
            collectionView.dequeueConfiguredReusableCell(using: cachedWarningRow, for: indexPath, item: item)
        case .skill:
            cardCell(for: item, at: indexPath)
        }
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
                query = ""
                search.setText("")
            }
        )
    }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        guard let state, case .skill(let id) = item, let skill = state.skills[id] else { return }
        ListScreen.buttonRow(
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
        content.textProperties.color = palette.ui.fg
        content.image = UIImage(systemName: "sparkles.rectangle.stack")
        content.imageProperties.tintColor = palette.ui.blue

        let comment = palette.ui.comment
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
