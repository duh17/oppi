import UIKit

/// Pinned (route `.utility(.pinned)`): the window server's pins in two
/// sections, each in its saved order. Sessions come first as wide cards;
/// every other pin (games, web pages, folders, files, panels) is a tile in a
/// grid, as many across as fit. Where two tiles don't fit at their 160 pt
/// minimum (a Slide Over or other narrow window), those pins draw as the
/// File Browser's pin rows instead, and the tiles come back as the screen
/// widens.
///
/// A session card is the session lists' own row (`SessionListEntryConfiguration`),
/// so it shows the session's live status; a tap opens its chat as a session
/// link does. A session this device has not loaded, or one the server says
/// was deleted, draws as a plain pin row. A tile shows what its pin opens
/// (`PinPreviewStore`): a PDF's first page or a picture, a folder's size
/// and first items, a game's last frame and build, a web page's title and
/// image; until a preview arrives, and for a pin that is gone or can't open
/// here, its kind's glyph. Every pin opens as its link does (a folder or
/// file beside the focused pane on a wide window); a gone one offers Remove
/// Pin, and a game while Godot Pane is off here is dimmed and says so.
///
/// `PinsSection` owns every pin's tap, menu, swipe, drag, and Edit mode.
/// Edit shows a session card's delete and reorder controls and a tile's
/// remove button; a tile moves by dragging it. A pin moves only within its
/// section, and Done saves the order and removals once.
@MainActor
final class PinnedViewController: UIViewController {
    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    /// The screen's sections: session cards, then the tile grid.
    enum Section: Int, Hashable, CaseIterable {
        case sessions, places

        init(_ kind: PinKind) {
            self = kind == .sessions ? .sessions : .places
        }
    }

    /// What one item draws; an item reconfigures only when this changes.
    private enum ItemContent: Equatable {
        /// A session this device has, drawn as the session lists draw it.
        case session(SessionListRowContent, pin: PinsSection.Row)
        /// A pin as the File Browser's pin row (`PinsSection.configureRow`):
        /// a session pin that is gone or not loaded here, a thread or a
        /// session list, and every other pin while tiles don't fit.
        case row(PinsSection.Row)
        /// Any other pin: a tile.
        case tile(PinTileView.Content, pin: PinsSection.Row)

        var isTile: Bool {
            if case .tile = self { true } else { false }
        }
    }

    private let root: AppRootEnvironment
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>?
    private var items: [String: ItemContent] = [:]
    private var sections: [Section: [String]] = [:]
    private var themeID: ThemeID?
    private var display = SessionRowDisplay.standard
    /// The places draw as rows: the screen is too narrow for two tiles.
    private var placesAsRows = false
    private let previews = PinPreviewStore()
    /// The window server's pins; a new section when the window's server changes.
    private var pinsSection: PinsSection?
    private var sidebarToggle: UIBarButtonItem?
    /// Edit's tile move: a press on a tile drags it to a new place.
    private lazy var moveGesture: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(moveTile(_:)))
        gesture.minimumPressDuration = 0.15
        gesture.delegate = self
        gesture.isEnabled = false
        return gesture
    }()
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
        // Session cards change height with their session's state, as in the session lists.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.addGestureRecognizer(moveGesture)
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
        // pin event: the statuses and previews are read again each time the
        // screen shows.
        section()?.refresh()
        previews.refresh()
        setNeedsUpdateProperties()
    }

    /// The places switch between tiles and rows as the width crosses two
    /// tiles' minimum: a Slide Over resize, a pane or column resize, a rotation.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let width = view.bounds.inset(by: view.safeAreaInsets).width
        let asRows = Self.tileColumns(width: width) < 2
        guard asRows != placesAsRows else { return }
        placesAsRows = asRows
        collectionView.collectionViewLayout.invalidateLayout()
        applySnapshot(section()?.content()?.rows ?? [], restyle: false)
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
        applySnapshot(content?.rows ?? [], restyle: restyle)
        updateEmptyState(available: section != nil, isEmpty: content == nil)

        let isEditing = section?.isEditing == true
        moveGesture.isEnabled = isEditing
        editItem.title = isEditing ? String(localized: "Done") : String(localized: "Edit")
        editItem.style = isEditing ? .prominent : .plain
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
            // The screen has no collapsed state: its sections always show.
            isCollapsed: { false },
            setCollapsed: { _ in },
            setEditing: { [weak self] editing in self?.collectionView.isEditing = editing },
            changed: { [weak self] in self?.setNeedsUpdateProperties() }
        ))
        pinsSection = section
        return section
    }

    private func applySnapshot(_ pinRows: [PinsSection.Row], restyle: Bool) {
        guard let dataSource else { return }
        let connection = root.windowConnection
        let serverId = root.windowServerId
        let pins = Dictionary(
            (connection?.pins.pins ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var nextItems: [String: ItemContent] = [:]
        var nextSections: [Section: [String]] = [:]
        for row in pinRows {
            guard let pin = pins[row.id], let kind = pin.kind else { continue }
            nextSections[Section(kind), default: []].append(row.id)
            nextItems[row.id] = content(for: pin, kind: kind, row: row, connection: connection, serverId: serverId)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        for section in Section.allCases {
            guard let ids = nextSections[section], !ids.isEmpty else { continue }
            snapshot.appendSections([section])
            snapshot.appendItems(ids, toSection: section)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let kept = snapshot.itemIdentifiers.filter(existing.contains)
        // A pin that turns from a tile into a row (or back) needs the other cell.
        let reformed = kept.filter { items[$0]?.isTile != nextItems[$0]?.isTile }
        let changed = kept.filter { id in
            !reformed.contains(id) && (restyle || items[id] != nextItems[id])
        }
        snapshot.reloadItems(reformed)
        snapshot.reconfigureItems(changed)
        items = nextItems
        sections = nextSections
        dataSource.apply(snapshot, animatingDifferences: collectionView.window != nil && reformed.isEmpty)
    }

    /// A session this device has (and the server still has) draws as its
    /// session row; another session pin as a pin row; anything else as a
    /// tile, or a pin row while tiles don't fit.
    private func content(
        for pin: Pin, kind: PinKind, row: PinsSection.Row, connection: ServerConnection?, serverId: String?
    ) -> ItemContent {
        guard kind == .sessions else {
            if placesAsRows { return .row(row) }
            // The list read already says whether the target is there; a gone pin reads nothing.
            let preview = pin.isGone ? nil : connection.flatMap { connection in
                serverId.flatMap { previews.preview(for: pin.target, serverId: $0, connection: connection, checksPresence: false) }
            }
            return .tile(PinTileView.Content.make(place: Self.place(pin, row: row), kind: kind, preview: preview, palette: palette), pin: row)
        }
        guard let connection, case .session(let sessionId) = pin.target, !row.isGone,
              let session = Self.session(sessionId, in: connection) else { return .row(row) }
        let workspaceName = session.workspaceId.flatMap { id in
            connection.workspaceStore.workspaces.first { $0.id == id }?.name
        }
        return .session(SessionListRowContent.make(
            entry: SessionListEntry(session: session, thread: nil, outsideRoot: nil),
            connection: connection,
            workspaceContext: SessionInboxSessionRouting.allSessionsContext(for: session, workspaceName: workspaceName),
            searchSnippet: nil,
            lockTarget: { session in serverId.map { ScopedLockTarget.session(session, serverId: $0) } },
            callBadge: serverId.flatMap { root.liveVoiceCalls.rowBadge(serverId: $0, sessionId: session.id) }
        ), pin: row)
    }

    /// A pin as a tile shows it: its row's words and state, and its label
    /// as a name of its own.
    static func place(_ pin: Pin, row: PinsSection.Row) -> PinTilePlace {
        PinTilePlace(
            route: pin.target,
            title: row.title,
            detail: row.detail,
            keepsTitle: pin.label != nil,
            isGone: row.isGone,
            isOff: row.isOff,
            isUnreadable: pin.status == .unreadable,
            isLocked: row.isLocked
        )
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
                message: String(localized: "Update Oppi on this server to pin sessions, files, folders, and games.")
            )
        } else if available, isEmpty {
            .empty(
                title: String(localized: "Nothing Pinned Yet"),
                systemImage: "pin",
                message: String(localized: "Keep the sessions, files, folders, and games you return to here. Touch and hold one and choose Pin, or use Pin in a pane\u{2019}s menu.")
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
            section.beginEditing(groups: Section.allCases.map { sections[$0] ?? [] })
        }
    }

    /// Edit's drag of a tile: the collection view's interactive move, which
    /// the data source's reordering handlers report to the section.
    @objc private func moveTile(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
            collectionView.beginInteractiveMovementForItem(at: indexPath)
        case .changed:
            collectionView.updateInteractiveMovementTargetPosition(point)
        case .ended:
            collectionView.endInteractiveMovement()
        default:
            collectionView.cancelInteractiveMovement()
        }
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self else { return nil }
            if dataSource?.sectionIdentifier(for: index) == .places, !placesAsRows {
                return tileSection(environment)
            }
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.backgroundColor = .clear
            configuration.headerMode = .none
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self, let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
                return pinsSection?.trailingSwipe(pinId: id)
            }
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            section.contentInsets.bottom = 4
            return section
        }
    }

    private static let tileSpacing = 14.0

    /// The inset grouped list's side margin at `width`.
    private static func tileMargin(width: Double) -> Double {
        width >= 600 ? 20 : 16
    }

    /// How many tiles at least 160 points wide fit across `width`: two on
    /// an iPhone, four on an iPad mini; fewer than two draws rows instead.
    static func tileColumns(width: Double) -> Int {
        let usable = width - tileMargin(width: width) * 2
        return Int((usable + tileSpacing) / (160 + tileSpacing))
    }

    /// Tiles as many across as fit, on the inset grouped list's margins.
    private func tileSection(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width
        let margin = Self.tileMargin(width: width)
        let spacing = Self.tileSpacing
        let usable = width - margin * 2
        // The width the screen measured can differ from the layout's by a safe area; one tile is the least.
        let columns = max(1, Self.tileColumns(width: width))
        let tileWidth = ((usable - spacing * Double(columns - 1)) / Double(columns)).rounded(.down)
        let height = PinTileView.height(forWidth: tileWidth, traits: environment.traitCollection)
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(tileWidth), heightDimension: .absolute(height)))
        let row = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
            repeatingSubitem: item, count: columns
        )
        row.interItemSpacing = .fixed(spacing)
        let section = NSCollectionLayoutSection(group: row)
        section.interGroupSpacing = 16
        section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: margin, bottom: 24, trailing: margin)
        return section
    }

    // MARK: Cells

    private func installDataSource() {
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        let tile = UICollectionView.CellRegistration<PinTileCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, String>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            if case .tile = self?.items[id] {
                return collectionView.dequeueConfiguredReusableCell(using: tile, for: indexPath, item: id)
            }
            return collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: id)
        }
        // Edit moves a pin within its section (`targetIndexPathForMove`).
        dataSource.reorderingHandlers.canReorderItem = { [weak self] _ in self?.pinsSection?.isEditing == true }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            let snapshot = transaction.finalSnapshot
            let groups = Section.allCases.map { section in
                snapshot.sectionIdentifiers.contains(section) ? snapshot.itemIdentifiers(inSection: section) : []
            }
            self?.sections = Dictionary(uniqueKeysWithValues: zip(Section.allCases, groups))
            self?.pinsSection?.didReorder(groups)
        }
        self.dataSource = dataSource
    }

    private func configure(_ cell: UICollectionViewListCell, id: String) {
        guard let content = items[id], let section = pinsSection else { return }
        let palette = palette
        // Reuse: each kind of row sets what the other kind sets.
        cell.accessibilityIdentifier = nil
        cell.accessibilityLabel = nil
        cell.accessibilityCustomActions = nil
        cell.isAccessibilityElement = false
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = palette.ui.bgHighlight
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
        case .row(let row):
            PinsSection.configureRow(cell, row: row, palette: palette)
            section.decorate(cell, row: row, palette: palette)
        case .tile:
            break
        }
    }

    private func configure(_ cell: PinTileCell, id: String) {
        guard case .tile(let content, let row) = items[id], let section = pinsSection else { return }
        cell.show(
            content, isEditing: row.isEditing, palette: palette,
            identifier: section.rowIdentifier(row), removeIdentifier: section.removeIdentifier(row)
        )
        cell.remove = { [weak section] in section?.removeWhileEditing(row.id) }
        cell.accessibilityLabel = content.accessibilityLabel
        cell.accessibilityCustomActions = section.accessibilityActions(row)
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

extension PinnedViewController: UICollectionViewDelegate, UICollectionViewDragDelegate, UIGestureRecognizerDelegate {
    /// A tap opens the pin (or offers to remove one that is gone); the item
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

    /// A pin moves only within its section.
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

    /// Edit's tile move starts only on a tile: a session card moves by its
    /// reorder control.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === moveGesture,
              let indexPath = collectionView.indexPathForItem(at: gesture.location(in: collectionView)),
              let id = dataSource?.itemIdentifier(for: indexPath) else { return false }
        if case .tile = items[id] { return true }
        return false
    }
}
