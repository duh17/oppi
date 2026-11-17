import UIKit

/// Pinned (route `.utility(.pinned)`): the window server's pins grouped by
/// what they open (`PinKind`: Sessions, Games, Git, Web Pages, Panels,
/// Folders, Files), each group in its saved order.
///
/// A session row is the session lists' own row (`SessionListEntryConfiguration`),
/// so it shows the session's live status; a tap opens its chat as a session
/// link does. A session this device has not loaded, or one the server says
/// was deleted, draws as a plain pin row. Folder and file rows are the File
/// Browser's pins: breadcrumbs, Not found, locks, and a tap that opens them
/// as a pane link does (beside the focused pane on a wide window). Every
/// other pin opens as its link does, with the title and icon of its kind; a
/// game while Godot Pane is off here is dimmed and says so.
///
/// `PinsSection` owns every pin's tap, menu, swipe, drag, and Edit mode; the
/// bar's Edit enters it with the groups, so a pin moves only within its
/// group, and Done saves the order and removals once.
@MainActor
final class PinnedViewController: UIViewController {
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    typealias Group = PinKind

    /// What one row draws; a row reconfigures only when this changes.
    private enum RowContent: Equatable {
        /// A session this device has, drawn as the session lists draw it.
        case session(SessionListRowContent, pin: PinsSection.Row)
        /// Any other pin, or a session that is gone or not loaded here.
        case place(PinsSection.Row, kind: PinKind)
    }

    private let root: AppRootEnvironment
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Group, String>?
    private var rows: [String: RowContent] = [:]
    private var groups: [Group: [String]] = [:]
    private var themeID: ThemeID?
    private var display = SessionRowDisplay.standard
    /// The window server's pins; a new section when the window's server changes.
    private var pinsSection: PinsSection?
    private var sidebarToggle: UIBarButtonItem?
    /// One Edit button for the screen's life, retitled Done while editing.
    private lazy var editItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: String(localized: "Edit"), primaryAction: UIAction { [weak self] _ in
            self?.toggleEditing()
        })
        item.accessibilityIdentifier = "pinned.edit"
        return item
    }()

    init(root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = String(localized: "Pinned")
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.accessibilityIdentifier = "pinned.list"
        // Rows change height with their session's state, as in the session lists.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.dragDelegate = self
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        installDataSource()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        // A folder deleted on disk or a session deleted elsewhere sends no
        // pin event: the statuses are read again each time the screen shows.
        section()?.refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving keeps what Edit changed, as Done would.
        pinsSection?.finishEditing()
    }

    override func updateProperties() {
        super.updateProperties()
        guard isViewLoaded else { return }
        let themeStore = root.themeStore
        overrideUserInterfaceStyle = themeStore.userInterfaceStyle
        let themeID = themeStore.activeThemeID
        let display = root.sessionRows.display
        let restyle = themeID != self.themeID || display != self.display
        if themeID != self.themeID {
            view.backgroundColor = themeID.palette.ui.bg
            collectionView.backgroundColor = themeID.palette.ui.bg
        }
        self.themeID = themeID
        self.display = display

        let section = section()
        let content = section?.content()
        applySnapshot(content?.rows ?? [], section: section, restyle: restyle)
        updateEmptyState(available: section != nil, isEmpty: content == nil)

        editItem.title = section?.isEditing == true ? String(localized: "Done") : String(localized: "Edit")
        editItem.style = section?.isEditing == true ? .prominent : .plain
        editItem.isEnabled = content != nil
        ListScreen.setBarItems(trailing: section == nil ? [] : [editItem], leading: sidebarItems(), on: navigationItem)
    }

    // MARK: Model

    /// The pins of the window's server; nil on a server without pins.
    private func section() -> PinsSection? {
        guard let serverId = root.windowServerId, root.windowConnection?.pinsAvailable == true else {
            pinsSection = nil
            return nil
        }
        if let pinsSection, pinsSection.serverId == serverId { return pinsSection }
        collectionView.isEditing = false
        let root = root
        let section = PinsSection(serverId: serverId, identifierPrefix: "pinned", presenter: self, hooks: .init(
            // The section is the window server's; a new server makes a new section.
            connection: { root.windowConnection },
            shows: { _ in true },
            open: { [weak self] pin, inMainPane in self?.open(pin, serverId: serverId, inMainPane: inMainPane) },
            paneSource: { [weak self] in self?.viewIfLoaded },
            // The screen has no collapsed state: its groups always show.
            isCollapsed: { false },
            setCollapsed: { _ in },
            setEditing: { [weak self] editing in self?.collectionView.isEditing = editing },
            changed: { [weak self] in self?.setNeedsUpdateProperties() }
        ))
        pinsSection = section
        return section
    }

    private func applySnapshot(_ pinRows: [PinsSection.Row], section: PinsSection?, restyle: Bool) {
        guard let dataSource else { return }
        let connection = root.windowConnection
        let pins = Dictionary(
            (connection?.pins.pins ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var nextRows: [String: RowContent] = [:]
        var nextGroups: [Group: [String]] = [:]
        for row in pinRows {
            guard let pin = pins[row.id], let group = pin.kind else { continue }
            nextGroups[group, default: []].append(row.id)
            nextRows[row.id] = content(for: pin, row: row, connection: connection)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Group, String>()
        for group in Group.allCases {
            guard let ids = nextGroups[group], !ids.isEmpty else { continue }
            snapshot.appendSections([group])
            snapshot.appendItems(ids, toSection: group)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let changed = snapshot.itemIdentifiers.filter { id in
            existing.contains(id) && (restyle || rows[id] != nextRows[id])
        }
        snapshot.reconfigureItems(changed)
        rows = nextRows
        groups = nextGroups
        dataSource.apply(snapshot, animatingDifferences: collectionView.window != nil)
    }

    /// A session this device has (and the server still has) draws as its
    /// session row; anything else as a pin row.
    private func content(for pin: Pin, row: PinsSection.Row, connection: ServerConnection?) -> RowContent {
        guard let connection, case .session(let sessionId) = pin.target, !row.isGone,
              let session = Self.session(sessionId, in: connection) else { return .place(row, kind: pin.kind ?? .files) }
        let workspaceName = session.workspaceId.flatMap { id in
            connection.workspaceStore.workspaces.first { $0.id == id }?.name
        }
        let serverId = root.windowServerId
        return .session(SessionListRowContent.make(
            entry: SessionListEntry(session: session, thread: nil, outsideRoot: nil),
            connection: connection,
            workspaceContext: SessionInboxSessionRouting.allSessionsContext(for: session, workspaceName: workspaceName),
            searchSnippet: nil,
            lockTarget: { session in serverId.map { ScopedLockTarget.session(session, serverId: $0) } },
            callBadge: serverId.flatMap { root.liveVoiceCalls.rowBadge(serverId: $0, sessionId: session.id) }
        ), pin: row)
    }

    /// The session as the lists show it, else its full record.
    private static func session(_ id: String, in connection: ServerConnection) -> Session? {
        connection.sessionStore.listProjectionSessions.first { $0.id == id } ?? connection.sessionStore.session(id: id)
    }

    /// No pins yet, or a server that keeps none (the quick action and
    /// `oppi://pins` reach this screen on any server). Nothing while the
    /// server's capabilities load.
    private func updateEmptyState(available: Bool, isEmpty: Bool) {
        let state: LoadState? = if !available, root.windowConnection?.serverCapabilities != nil {
            .empty(
                title: String(localized: "Pins Unavailable"),
                systemImage: "pin.slash",
                message: String(localized: "Update Oppi on this server to pin sessions, games, web pages, and anything else a pane shows.")
            )
        } else if available, isEmpty {
            .empty(
                title: String(localized: "No Pins"),
                systemImage: "pin",
                message: String(localized: "Pin a session from its row or its chat\u{2019}s \u{2026} menu, a folder or file from Files, or anything a pane shows from its pane menu.")
            )
        } else {
            nil
        }
        contentUnavailableConfiguration = state.map {
            UIContentUnavailableConfiguration.loadState($0, palette: palette, background: palette.ui.bg)
        }
    }

    // MARK: Opening

    /// A pin opens as its link does (`AppOpenRequest(link:)`): a session or
    /// thread over this screen; anything else as a pane link, beside the
    /// focused pane on a wide window (`inMainPane` false), else in the main
    /// stack. A game the opener can't play (Godot Pane off) gets its toast.
    private func open(_ pin: Pin, serverId: String, inMainPane: Bool) {
        let link = PaneLink(server: serverId, route: pin.target)
        root.opener.open(AppOpenRequest(link: link, origin: .inAppHyperlink, sourceServerID: serverId), inMainPane: inMainPane)
    }

    // MARK: Editing

    private func toggleEditing() {
        guard let section = pinsSection else { return }
        if section.isEditing {
            section.finishEditing()
        } else {
            section.beginEditing(groups: Group.allCases.map { groups[$0] ?? [] })
        }
    }

    // MARK: Cells

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.backgroundColor = .clear
            configuration.headerMode = .supplementary
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self, let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
                return pinsSection?.trailingSwipe(pinId: id)
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        let dataSource = UICollectionViewDiffableDataSource<Group, String>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let self, let group = self.dataSource?.sectionIdentifier(for: indexPath.section) else { return }
            var content = UIListContentConfiguration.header()
            content.text = group.title
            content.textProperties.color = palette.ui.comment
            header.contentConfiguration = content
            header.accessibilityTraits = .header
            header.accessibilityIdentifier = "pinned.header.\(group)"
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        // Edit mode moves a pin within its group (`targetIndexPathForMove`).
        dataSource.reorderingHandlers.canReorderItem = { [weak self] _ in self?.pinsSection?.isEditing == true }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            let snapshot = transaction.finalSnapshot
            let groups = Group.allCases.map { group in
                snapshot.sectionIdentifiers.contains(group) ? snapshot.itemIdentifiers(inSection: group) : []
            }
            self?.pinsSection?.didReorder(groups)
        }
        self.dataSource = dataSource
    }

    private func configure(_ cell: UICollectionViewListCell, id: String) {
        guard let content = rows[id], let section = pinsSection else { return }
        let palette = palette
        // Reuse: each kind of row sets what the other kind sets.
        cell.accessibilityIdentifier = nil
        cell.accessibilityLabel = nil
        cell.accessibilityCustomActions = nil
        cell.isAccessibilityElement = false
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = palette.ui.bg
        cell.backgroundConfiguration = background
        cell.hoverStyle = UIHoverStyle(effect: .highlight)

        switch content {
        case .session(let session, let row):
            cell.contentConfiguration = SessionListEntryConfiguration(
                row: session,
                display: display,
                themeID: themeID ?? root.themeStore.activeThemeID,
                iconAssetCache: root.windowConnection?.iconAssetCache,
                actions: sessionActions
            )
            // The session row speaks for itself (its status included); the
            // cell adds the pin's own accessories and actions.
            cell.accessories = section.accessories(for: row, palette: palette)
            cell.accessibilityCustomActions = section.accessibilityActions(row)
        case .place(let row, let kind):
            configurePlace(cell, row: row, kind: kind, palette: palette)
            section.decorate(cell, row: row, palette: palette)
        }
    }

    /// A pin not shown as its session row: its kind's icon (a file's own),
    /// name, and where it lives (or why it can't open), dimmed when it is
    /// gone or Godot Pane is off.
    private func configurePlace(_ cell: UICollectionViewListCell, row: PinsSection.Row, kind: PinKind, palette: ThemePalette) {
        let symbol = row.icon?.symbolName ?? kind.symbol
        let dimmed = row.isGone || row.isOff
        let tint = dimmed || kind == .files ? palette.ui.comment : palette.ui.blue
        var content = UIListContentConfiguration.subtitleCell()
        content.image = UIImage(systemName: symbol)
        content.imageProperties.tintColor = tint
        content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
        content.text = row.title
        content.textProperties.color = dimmed ? palette.ui.comment : palette.ui.fg
        content.textProperties.numberOfLines = 1
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.secondaryText = row.detail
        content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .caption1)
        content.secondaryTextProperties.color = palette.ui.comment
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingHead
        content.textToSecondaryTextVerticalPadding = 2
        cell.contentConfiguration = content
        cell.accessories = []
    }

    /// A session row's own controls: the row opens its chat. It draws no
    /// thread strip here, and Stop, Resume, and Delete stay in the session
    /// lists.
    private lazy var sessionActions = SessionListRowActions(
        open: { [weak self] session in
            guard let self, let id = pinId(forSession: session.id) else { return }
            pinsSection?.select(id)
        },
        toggleThread: { _ in },
        toggleStoppedMembers: { _ in },
        stop: { _ in },
        resume: { _ in },
        delete: { _ in nil },
        lockTarget: { [weak self] session in self?.root.windowServerId.map { ScopedLockTarget.session(session, serverId: $0) } }
    )

    private func pinId(forSession sessionId: String) -> String? {
        root.windowConnection?.pins.pin(for: .session(sessionId))?.id
    }

    private func sidebarItems() -> [UIBarButtonItem] {
        guard showsSidebarToggle else { return [] }
        let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
        sidebarToggle = toggle
        WorkspaceSplitSidebarToggle.sync(toggle, root: root)
        return [toggle]
    }
}

// MARK: - Taps, menus, drags, and Edit-mode moves

extension PinnedViewController: UICollectionViewDelegate, UICollectionViewDragDelegate {
    /// A tap opens the pin (or offers to remove one that is gone); the row
    /// never stays selected.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
        pinsSection?.select(id)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let id = dataSource?.itemIdentifier(for: indexPaths[0]) else { return nil }
        return pinsSection?.contextMenu(pinId: id)
    }

    /// A pin drags out as the pane entry it opens as; a pane takes the drop.
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return [] }
        return pinsSection?.dragItems(pinId: id) ?? []
    }

    /// A pin moves only within its group.
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
        atCurrentIndexPath currentIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard proposedIndexPath.section != originalIndexPath.section else { return proposedIndexPath }
        let last = collectionView.numberOfItems(inSection: originalIndexPath.section) - 1
        return IndexPath(item: proposedIndexPath.section < originalIndexPath.section ? 0 : last, section: originalIndexPath.section)
    }
}
