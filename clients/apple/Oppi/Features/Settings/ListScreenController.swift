import UIKit

/// One section of a list screen: its rows, and the header and footer text the
/// section shows. A page returns these from `sections()` and the base list owns
/// the snapshot, the headings, and the redraw.
///
/// `scope` is where the section's settings are kept, when that differs from the
/// page's own scope. The base puts one sentence about it in front of the
/// footer, so a page that mixes scopes says which rows are which.
struct ListSection<Section: Hashable & Sendable, Item: Hashable & Sendable> {
    var id: Section
    var header: String?
    var footer: String?
    var scope: SettingsScope?
    var items: [Item]
    /// The list's own state where the section's rows would be: loading, empty,
    /// nothing matched, or failed with one Retry. The base draws it as the
    /// section's first row, from `LoadState` (`SettingsStateRowCell`'s shape),
    /// so a section whose only row is the state shows what the whole screen
    /// used to: the same words, and `identifier` on its text or its Retry.
    var state: ListStateRow?

    init(
        _ id: Section,
        header: String? = nil,
        footer: String? = nil,
        scope: SettingsScope? = nil,
        items: [Item],
        state: ListStateRow? = nil
    ) {
        self.id = id
        self.header = header
        self.footer = footer
        self.scope = scope
        self.items = items
        self.state = state
    }
}

/// A section's state row: the list's own state (`LoadState`, the type every
/// screen's whole-screen state is) and the identifier that finds it.
struct ListStateRow {
    var state: LoadState
    /// `app.staticTexts[identifier]`, or `app.buttons[identifier]` when the
    /// state has a Retry. One per page: two sections cannot share a row.
    var identifier: String
}

/// The cell a page draws its rows in. `.card` is the kit's theme-card row
/// (`SidebarListCell`, filled by `configureCard(_:item:)`); `.plain` is a plain
/// list cell, filled by `configure(_:item:)`.
enum ListRowStyle {
    case plain
    case card
}

/// What a page loads, and what starts its load. The kit runs one load at a
/// time (`load()`), cancels it when the page leaves and when its subject
/// changes, and keeps the outcome (`isLoading`, `loadFailure`); a page says
/// which of these it is and what its load asks for.
enum LoadPolicy {
    /// The page loads nothing: no task, and no pull to refresh control.
    case none
    /// A load when the page appears, when its subject changes, on pull to
    /// refresh, and when `setNeedsLoad()` asks (a Retry, a foreground return,
    /// a finished sign-in).
    case eachAppearance
    /// A load when the page first appears, and again only when its subject
    /// changes or `setNeedsLoad()` asks: a page back from a pushed editor keeps
    /// what that editor saved.
    case onceUntilSubjectChanges
}

/// Why a page's load could not run, in the words its failure row shows ("Server
/// offline"). A page throws one from `load()` when its server is not there yet;
/// anything else it throws is the request's own error.
struct LoadFailure: LocalizedError, Equatable {
    var message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

/// A row of the list: one of the page's items, or the base's own state row for
/// a section that declared one. The state is not an `Item` because a page has
/// no case for it and no cell to fill: the base draws it from `LoadState`.
/// A page that reorders or finds a row (`dataSource`) reads its own out with
/// `pageItem`.
enum ListSlot<Section: Hashable & Sendable, Item: Hashable & Sendable>: Hashable {
    case item(Item)
    case state(Section)

    /// The page's row, when this slot is one; nil for a state row.
    var pageItem: Item? {
        if case .item(let item) = self { return item }
        return nil
    }
}

/// The base of a list screen: a themed inset-grouped list with section headers
/// and footers, rows redrawn only when their inputs change, and the page's load
/// — one task, cancelled when the page leaves or its subject changes. The
/// list's own background is clear, so the theme's `bg` shows behind the cards.
///
/// A page subclasses it, names its `Section` and `Item` types, says its scope
/// (where the page's settings are kept, if it has settings), and overrides:
/// - `sections()`: the sections and rows now. It runs inside
///   `updateProperties()`, so every `@Observable` store it reads re-runs the
///   page when it changes. Preferences that are not observable call
///   `setNeedsUpdateProperties()` after writing; `viewWillAppear` does the
///   same when the page comes back from a pushed page.
/// - `showsHeader(for:)`: which sections show a header. A page whose sections
///   carry headings only on some (a catalog's groups) narrows the `headers:`
///   it was built with.
/// - `loadPolicy`, `loadSubject()`, `load()` and `subjectDidChange()`: what the
///   page loads, when, and what its load is for. The base owns the one task:
///   it starts it on appearance (per the policy), on pull to refresh, on a
///   subject change, and on `setNeedsLoad()` (a Retry, a foreground return, a
///   finished sign-in); it cancels it when the page leaves and before another
///   starts, and ignores a cancelled load instead of showing it as a failure.
///   `isLoading` and `loadFailure` are the outcome the page's rows read.
///   `isShowing` says whether the page can be seen.
/// - `animatesUpdates`: whether a snapshot change animates its rows. A catalog
///   list that swaps whole sections answers false.
/// - `ListSection.state`: the list's own loading, empty, or failed state
///   (`LoadState`) where the section's rows would be; the base draws it, with
///   its identifier, so a page owns no state row, cell, or identifier map.
/// - `wholeScreenState()`: the same state for a page with no rows at all
///   (connecting, loading, or failed with one Retry), which the base draws over
///   the whole screen instead of in a row.
/// - `inputs(of:)`: the values a row is drawn from. Only rows whose inputs
///   changed are reconfigured. The default differs on every pass, so a row a
///   page does not key is redrawn every pass and cannot go stale; a page whose
///   row holds an open pop-up menu, a switch in flight, or a text field keys it
///   with what the row draws, so a pass leaves it alone. The theme is added for
///   every row.
/// - `configure(_:item:)`: a plain list cell (`content(_:)` fills its title in
///   the theme's title color, `toggleRow` makes a switch row);
///   `configureCard(_:item:)` with `rowStyle` `.card` for the kit's theme-card
///   rows; or `dequeue(_:at:)` for pages with their own cell classes: the
///   kit's `SettingsIndexRowCell`, `SettingsMenuRowCell`,
///   `SettingsActionRowCell`, and `SettingsStateRowCell`.
/// - `isSelectable(_:)` and `select(_:)`: the rows that act when tapped. A
///   selectable row carries the button trait, and VoiceOver activation selects
///   it, so touch and accessibility run the same `select(_:)`.
/// - `copyText(of:)`: the text a long press on an info row copies.
/// - `trailingSwipeActions(for:)`, `decorate(header:section:)`,
///   `decorate(footer:section:)`: swipe actions, and an icon or tone on a
///   section heading.
///
/// A page keeps its own data, except for the settings it declares in
/// `SettingsCatalog`: those are read and written through its `settings` store
/// by `settingToggleRow` and `settingChoiceRow` (`SettingsDeclaredRows.swift`),
/// which draw their state, scope, and failures from the declaration.
@MainActor
class ListScreenController<Section: Hashable & Sendable, Item: Hashable & Sendable>: UIViewController, UICollectionViewDelegate {
    private(set) lazy var collectionView: UICollectionView = {
        // One section at a time, because the page says which of them show a
        // header (`showsHeader(for:)`) and which of a catalog's groups have a
        // heading. Everything else is the kit's list: a clear background so the
        // theme's `bg` shows behind the cards, and the page's swipe actions.
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            config.backgroundColor = .clear
            let section = self?.dataSource?.sectionIdentifier(for: index)
            let headers = section.map { self?.showsHeader(for: $0) ?? false } ?? self?.showsHeaders ?? false
            config.headerMode = headers ? .supplementary : .none
            config.footerMode = self?.showsFooters == true ? .supplementary : .none
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let item = self?.pageItem(at: indexPath) else { return nil }
                return self?.trailingSwipeActions(for: item)
            }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()
    private(set) var dataSource: UICollectionViewDiffableDataSource<Section, ListSlot<Section, Item>>?
    /// Whether the page is on screen: set when it appears and leaves. A page
    /// asks this before reacting to something that changed while it was covered.
    private(set) var isShowing = false
    /// The page's load: one task, cancelled when the page leaves and before a
    /// load for another subject starts.
    private var loadTask: Task<Void, Never>?
    /// The subject of the page's last load, and whether it was ever taken (a
    /// page's subject can be nil). Compared on every `updateProperties()` pass.
    private var loadedSubject: AnyHashable?
    private var hasLoadedSubject = false
    /// Whether the page ever started a load here, so `onceUntilSubjectChanges`
    /// knows a later appearance keeps what this one loaded.
    private var hasLoadedOnce = false
    /// Whether the page is loading its content now. A page's state row or
    /// spinner reads it.
    private(set) var isLoading = false {
        didSet { if isLoading != oldValue { setNeedsUpdateProperties() } }
    }
    /// Why the page's last load failed, in its own words. A load that succeeds
    /// clears it; a load the page cancelled never sets it.
    private(set) var loadFailure: String? {
        didSet { if loadFailure != oldValue { setNeedsUpdateProperties() } }
    }
    /// The list's pull to refresh, for a page that loads (`loadPolicy` other
    /// than `.none`). Only the base touches it: it starts the page's load and
    /// ends when that load settles.
    private lazy var pullToRefreshControl = UIRefreshControl()
    /// Where the page's settings are kept; `nil` for a page that has none. A
    /// section says its scope only when it differs from this.
    let pageScope: SettingsScope?
    /// The store behind the page's declared settings (`SettingsCatalog`).
    let settings: SettingsStore?
    private let showsHeaders: Bool
    private let showsFooters: Bool
    private let listEndsAtKeyboard: Bool
    private let dismissesKeyboardOnDrag: Bool
    private var appliedThemeID: ThemeID?
    private var changedRows = ChangedRows<ListSlot<Section, Item>>()
    private var models: [Section: ListSection<Section, Item>] = [:]
    /// Counts `updateProperties()` passes: the default `inputs(of:)` key differs
    /// on every one, so a row a page does not key is drawn again each pass.
    private var pass = 0

    /// - Parameters:
    ///   - listIdentifier: the list's accessibility identifier,
    ///     `<feature>.<page>.list` (`agents.list`, `mcp.detail.list`); the
    ///     Settings family's own pages say `settings.<page>.list`.
    ///   - scope: where the page's settings are kept. A page of declared
    ///     settings takes it from their `SettingStorage`; a page that has no
    ///     settings leaves it nil.
    ///   - settings: the store a page with declared settings reads and writes.
    ///   - headers: whether sections can show a header.
    ///   - footers: whether sections can show a footer. A page with a section
    ///     scope needs them, since the scope sentence is part of the footer.
    ///   - largeTitle: a page that roots its stack keeps the large title.
    ///   - endsAtKeyboard: a page that edits text in place ends its list at the
    ///     keyboard (`SettingsListStyle.pin`), so the field scrolls above it.
    ///   - dismissesKeyboardOnDrag: whether dragging the list puts the keyboard
    ///     away. The list dismisses it interactively and bounces even when its
    ///     rows do not fill it, which is what a list that built its own
    ///     collection view got; a page that edits text turns it on.
    init(
        title: String,
        listIdentifier: String,
        scope: SettingsScope? = nil,
        settings: SettingsStore? = nil,
        headers: Bool = false,
        footers: Bool = false,
        largeTitle: Bool = false,
        endsAtKeyboard: Bool = false,
        dismissesKeyboardOnDrag: Bool = false
    ) {
        pageScope = scope
        self.settings = settings
        showsHeaders = headers
        showsFooters = footers
        listEndsAtKeyboard = endsAtKeyboard
        self.dismissesKeyboardOnDrag = dismissesKeyboardOnDrag
        super.init(nibName: nil, bundle: nil)
        self.title = title
        navigationItem.largeTitleDisplayMode = largeTitle ? .always : .inline
        collectionView.accessibilityIdentifier = listIdentifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Page hooks

    /// The sections and rows the page shows now.
    func sections() -> [ListSection<Section, Item>] { [] }

    /// Whether `section` shows its header. The default is the `headers:` the
    /// page was built with; a page whose sections carry a heading only on some
    /// (a catalog's groups) answers for each.
    func showsHeader(for section: Section) -> Bool { showsHeaders }

    // MARK: - Load

    /// What the page loads, and when. The default loads nothing: a page with
    /// nothing to load gets no task and no pull to refresh control.
    var loadPolicy: LoadPolicy { .none }

    /// What the page's load is for: the server it follows, the route it serves.
    /// The base compares it on every `updateProperties()` pass; a change
    /// cancels the load that is running, runs `subjectDidChange()`, and starts
    /// one for the new subject.
    func loadSubject() -> AnyHashable? { nil }

    /// The page's subject changed: drop what the old one showed, so nothing of
    /// it stays on screen while the new one loads.
    func subjectDidChange() {}

    /// Loads the page's content. A throw becomes `loadFailure`, which the
    /// page's rows show; a cancelled load (the page left, its subject changed,
    /// another load replaced it) is not a failure and stores nothing.
    func load() async throws {}

    /// Runs the page's `load()` now, cancelling one already running: a Retry, a
    /// foreground return, a settled sign-in.
    func setNeedsLoad() {
        startLoad()
    }

    /// Takes the failure back, for a page that showed it as an alert rather
    /// than a row: a later failure sets it again.
    func clearLoadFailure() { loadFailure = nil }

    /// Runs `load()` for the page's subject now, replacing a load in flight.
    private func startLoad() {
        guard loadPolicy != .none else { return }
        loadTask?.cancel()
        loadedSubject = loadSubject()
        hasLoadedSubject = true
        hasLoadedOnce = true
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await load()
                guard !Task.isCancelled else { return }
                loadFailure = nil
                isLoading = false
            } catch {
                // A load this page cancelled — it left, its subject changed, or
                // another load replaced it — is not a failure, and leaves the
                // flags to the load that replaced it.
                guard !Task.isCancelled else { return }
                // The page is still here and its request ended as a cancel (a
                // superseded request, a URLSession cancel): the load is over and
                // nothing failed.
                isLoading = false
                guard !error.isLoadCancellation else { return }
                loadFailure = error.localizedDescription
            }
            if pullToRefreshControl.isRefreshing { pullToRefreshControl.endRefreshing() }
        }
    }

    /// Compares the page's subject every pass: a new one belongs to another
    /// server, route, or connection, so the page's rows and the load that is
    /// running are no longer its own.
    private func updateLoadSubject() {
        guard loadPolicy != .none else { return }
        let subject = loadSubject()
        guard hasLoadedSubject else {
            hasLoadedSubject = true
            loadedSubject = subject
            return
        }
        guard subject != loadedSubject else { return }
        loadedSubject = subject
        subjectDidChange()
        // A covered page loads when it appears again.
        if isShowing { startLoad() }
    }

    /// The page's state while it has no rows to show at all: connecting,
    /// loading, or failed. The base draws it with
    /// `UIContentUnavailableConfiguration.loadState` over the empty list, so it
    /// says and looks what every other screen's whole-screen state does. A page
    /// with rows states itself in a section (`ListSection.state`).
    func wholeScreenState() -> LoadState? { nil }

    /// Whether a snapshot change animates its rows. The default animates once
    /// the list has rows, so a page's first rows appear in place; a catalog
    /// list that swaps whole sections answers false, so a reload does not slide
    /// them around.
    var animatesUpdates: Bool {
        (dataSource?.snapshot().numberOfItems ?? 0) > 0
    }

    /// The values `item` is drawn from; the row redraws when they change. The
    /// default differs on every pass, so a page that does not key a row gets it
    /// drawn again; a row that holds an open menu, a switch in flight, or a text
    /// field is keyed with what it draws instead.
    func inputs(of item: Item) -> AnyHashable { AnyHashable(pass) }

    /// Fills a plain list cell for `item`. The cell arrives reset.
    func configure(_ cell: UICollectionViewListCell, item: Item) {}

    /// Fills a card row for `item`. The cell arrives as the theme card, so only
    /// the content is left (`ListScreen.buttonRow`, `ListScreen.staticRow`, the
    /// cell's own configuration). A page whose rows are all cards answers
    /// `rowStyle` with `.card`; a page that mixes them in dequeue
    /// `cardCell(for:at:)`.
    func configureCard(_ cell: SidebarListCell, item: Item) {}

    /// Which cell the page's rows are. A page with only its own cell classes
    /// keeps `.plain` and overrides `dequeue(_:at:)`.
    var rowStyle: ListRowStyle { .plain }

    /// The cell for `item`. Override to dequeue a page's own cell classes;
    /// the default is the cell `rowStyle` names.
    func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch rowStyle {
        case .plain:
            return collectionView.dequeueConfiguredReusableCell(using: plainCell, for: indexPath, item: item)
        case .card:
            return cardCell(for: item, at: indexPath)
        }
    }

    /// The cell for one of a mixed page's rows: the kit's theme card, filled by
    /// `configureCard(_:item:)`.
    func cardCell(for item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: cardCell, for: indexPath, item: item)
    }

    /// Called once before the first row is dequeued. A page with its own cell
    /// registrations creates them here (touching its `lazy var`s): UIKit refuses
    /// a registration created while a cell is being dequeued.
    func prepareRegistrations() {}

    /// Whether tapping `item` does something.
    func isSelectable(_ item: Item) -> Bool { false }

    /// The row of the page's `item`, when the list shows it: for a page that
    /// anchors something to a row (a confirmation) or focuses it.
    func indexPath(for item: Item) -> IndexPath? {
        dataSource?.indexPath(for: .item(item))
    }

    /// The page's items the list shows now, in order. A section's state row is
    /// the base's, not one of them.
    var shownItems: [Item] {
        dataSource?.snapshot().itemIdentifiers.compactMap(\.pageItem) ?? []
    }

    /// The page's items in `section`, in the order the list shows them.
    func items(in section: Section) -> [Item] {
        dataSource?.snapshot().itemIdentifiers(inSection: section).compactMap(\.pageItem) ?? []
    }

    /// Runs when a selectable row is tapped or activated.
    func select(_ item: Item) {}

    /// The text a long press on `item` copies: an info row's value. `nil`
    /// leaves the row without a menu.
    func copyText(of item: Item) -> String? { nil }

    /// The swipe actions at a row's trailing edge.
    func trailingSwipeActions(for item: Item) -> UISwipeActionsConfiguration? { nil }

    /// Adjusts a section's header after the base filled its text: an icon.
    func decorate(header content: inout UIListContentConfiguration, section: Section) {}

    /// Adjusts a section's footer after the base filled its text: a tone.
    func decorate(footer content: inout UIListContentConfiguration, section: Section) {}

    // MARK: - Row helpers

    /// A plain list row's content: the title in the theme's title color, and
    /// the value in its value color. `.info` is a read-only fact.
    func content(_ kind: SettingsStyle.Content) -> UIListContentConfiguration {
        SettingsStyle.content(kind)
    }

    /// Makes `cell` a switch row: the title, and a trailing switch. `identifier`
    /// is the switch's, which is what `app.switches[id]` finds. For a switch
    /// that is not a setting's value (a draft's field, a reorder list's
    /// visibility); a setting declared in `SettingsCatalog` uses
    /// `settingToggleRow`, and the settings-write guard counts the rest.
    func toggleRow(
        _ cell: UICollectionViewListCell,
        title: String,
        isOn: Bool,
        identifier: String? = nil,
        isEnabled: Bool = true,
        onChange: @escaping (Bool) -> Void
    ) {
        var content = content(.plain)
        content.text = title
        cell.contentConfiguration = content
        cell.accessories = [.settingsToggle(isOn, identifier: identifier, label: title, isEnabled: isEnabled, reusing: cell, onChange: onChange)]
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        SettingsListStyle.pin(collectionView, in: view, endsAtKeyboard: listEndsAtKeyboard)
        if dismissesKeyboardOnDrag {
            collectionView.keyboardDismissMode = .interactive
            collectionView.alwaysBounceVertical = true
        }
        collectionView.refreshControl = loadPolicy == .none ? nil : pullToRefreshControl
        if loadPolicy != .none {
            pullToRefreshControl.addAction(UIAction { [weak self] _ in
                self?.setNeedsLoad()
            }, for: .valueChanged)
        }
        installDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil)
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A pushed page writes straight to preferences, so what this page
        // shows is read again on the way back.
        setNeedsUpdateProperties()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isShowing = true
        // The page's own policy says whether appearing loads: every appearance,
        // or once — a page back from a pushed editor keeps what that editor
        // saved until its subject changes or something asks again.
        switch loadPolicy {
        case .none:
            break
        case .eachAppearance:
            startLoad()
        case .onceUntilSubjectChanges:
            if !hasLoadedOnce || loadSubject() != loadedSubject { startLoad() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isShowing = false
        // Leaving cancels the page's load: what it finds after the page is gone
        // is nobody's answer, and a cancelled load is not a failure.
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        if loadPolicy != .none { pullToRefreshControl.endRefreshing() }
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        updateLoadSubject()
        pass &+= 1
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SettingsListStyle.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        let sections = sections()
        applySnapshot(sections, themeID: themeID)
        // A page with nothing to list is its state: no rows, one screen.
        showWholeScreenState(hasRows(sections) ? nil : wholeScreenState(), themeID: themeID)
    }

    /// Whether `sections` show anything: a row, or a section's state row.
    private func hasRows(_ sections: [ListSection<Section, Item>]) -> Bool {
        sections.contains { !$0.items.isEmpty || $0.state != nil }
    }

    /// Rebuilt on every pass, so a theme change recolors it.
    private func showWholeScreenState(_ state: LoadState?, themeID: ThemeID) {
        guard let state else {
            contentUnavailableConfiguration = nil
            return
        }
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
            state, palette: themeID.palette, background: UIColor(themeID.palette.bg)
        )
    }

    // MARK: - Snapshot

    private func applySnapshot(_ sections: [ListSection<Section, Item>], themeID: ThemeID) {
        guard let dataSource else { return }
        models = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, ListSlot<Section, Item>>()
        for section in sections {
            snapshot.appendSections([section.id])
            var slots: [ListSlot<Section, Item>] = section.state.map { _ in [.state(section.id)] } ?? []
            slots += section.items.map { .item($0) }
            snapshot.appendItems(slots, toSection: section.id)
        }
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        // The theme is in the key: a light/dark or theme change repaints every
        // row, which otherwise keeps the colors it was configured with.
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { slot in
            AnyHashable([AnyHashable(themeID), inputs(of: slot)])
        }
        snapshot.reconfigureItems(changed.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: animatesUpdates)
        // Headings are not rows, so a reconfigure does not reach them. They are
        // redrawn in place: reloading the section would rebuild its rows and
        // move VoiceOver focus off the one the person is on.
        SetupListSupplementaries.refresh(collectionView) { [weak self] view, kind, indexPath in
            self?.configureSupplementary(view, kind: kind, at: indexPath)
        }
    }

    /// The values a row is drawn from. A state row's are its own words: the
    /// base draws it, so the page's `inputs(of:)` never sees it.
    private func inputs(of slot: ListSlot<Section, Item>) -> AnyHashable {
        switch slot {
        case .item(let item):
            return inputs(of: item)
        case .state(let section):
            guard let row = models[section]?.state else { return AnyHashable(0) }
            return AnyHashable([
                AnyHashable(row.identifier), AnyHashable(row.state.rowText), AnyHashable(row.state.rowRetry != nil),
            ])
        }
    }

    /// The page's item at `indexPath`, for the swipe actions and the rows that
    /// act.
    private func pageItem(at indexPath: IndexPath) -> Item? {
        dataSource?.itemIdentifier(for: indexPath)?.pageItem
    }

    /// The failure line under a declared setting that failed: the reason and
    /// Retry, from the store, keyed by the setting's id.
    private(set) lazy var settingFailureCell = UICollectionView.CellRegistration<SettingsStateRowCell, String> { [weak self] cell, _, id in
        guard let settings = self?.settings else { return }
        let retry: (() -> Void)? = settings.canRetry(id: id) ? { settings.retry(id: id) } : nil
        cell.configure(.failure(settings.failureReason(id: id) ?? "", retry: retry), identifier: "\(id).failure")
    }

    private lazy var plainCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        // Reuse clears everything a previous row set.
        cell.contentConfiguration = nil
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        cell.accessibilityTraits.remove([.button, .notEnabled])
        configure(cell, item: item)
        if isSelectable(item) { cell.accessibilityTraits.insert(.button) }
    }

    /// The page's rows as the theme's cards: the card's background, then the
    /// page's content. The row builders (`ListScreen.buttonRow`,
    /// `ListScreen.staticRow`) reset the rest, so a reused row keeps nothing.
    private lazy var cardCell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        ListScreen.background(cell, grouped: true, palette: ThemeRuntimeState.currentPalette(), settingsCard: true)
        configureCard(cell, item: item)
    }

    /// The section's state row: `LoadState`'s words, and its Retry when it has
    /// one, under the identifier the page gave it.
    private lazy var stateCell = UICollectionView.CellRegistration<SettingsStateRowCell, ListSlot<Section, Item>> { [weak self] cell, _, slot in
        guard let self, case .state(let section) = slot, let row = models[section]?.state else { return }
        cell.configure(SettingsStateRowCell.State(row.state), identifier: row.identifier)
    }

    private func installDataSource() {
        _ = (plainCell, cardCell, settingFailureCell, stateCell)
        prepareRegistrations()
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, kind, indexPath in
            self?.configureSupplementary(view, kind: kind, at: indexPath)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, kind, indexPath in
            self?.configureSupplementary(view, kind: kind, at: indexPath)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView, cellProvider: SettingsListStyle.cardProvider { [weak self] collectionView, indexPath, slot in
            guard let self else { return nil }
            switch slot {
            case .item(let item):
                return dequeue(item, at: indexPath)
            case .state:
                return collectionView.dequeueConfiguredReusableCell(using: stateCell, for: indexPath, item: slot)
            }
        })
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configureSupplementary(_ view: UICollectionViewListCell, kind: String, at indexPath: IndexPath) {
        guard let section = dataSource?.sectionIdentifier(for: indexPath.section), let model = models[section] else {
            view.contentConfiguration = nil
            return
        }
        if kind == UICollectionView.elementKindSectionHeader {
            var content = UIListContentConfiguration.header()
            content.text = model.header
            decorate(header: &content, section: section)
            view.contentConfiguration = content
        } else {
            var content = UIListContentConfiguration.footer()
            content.text = SettingsScope.footer(model.footer, scope: model.scope, pageScope: pageScope)
            content.textProperties.numberOfLines = 0
            decorate(footer: &content, section: section)
            view.contentConfiguration = content
        }
    }

    // MARK: - UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        pageItem(at: indexPath).map(isSelectable) ?? false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = pageItem(at: indexPath) else { return }
        select(item)
    }

    /// Long press on an info row copies its value.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = pageItem(at: indexPath),
              let text = copyText(of: item), !text.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }])
        })
    }

    /// A row dragged by its handle stays in its own section.
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
        atCurrentIndexPath currentIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard proposedIndexPath.section != originalIndexPath.section else { return proposedIndexPath }
        // Dragged past its section: the nearest end of the section it came from.
        let count = collectionView.numberOfItems(inSection: originalIndexPath.section)
        let item = proposedIndexPath.section < originalIndexPath.section ? 0 : max(0, count - 1)
        return IndexPath(item: item, section: originalIndexPath.section)
    }
}
