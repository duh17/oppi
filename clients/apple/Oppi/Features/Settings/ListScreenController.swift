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

/// A page's failed load: the words that title its failure (“Couldn't Load Agent”,
/// or its own sentence when only it can say why), and the request's reason under
/// them, which a load that could not run does not have.
struct LoadFailureReport: Equatable {
    var title: String
    var reason: String?
}

/// The cell a page draws its rows in. `.card` is the kit's theme-card row
/// (`SidebarListCell`, filled by `configureCard(_:item:)`); `.plain` is a plain
/// list cell, filled by `configure(_:item:)`.
enum ListRowStyle {
    case plain
    case card
}

/// Why the base is running the page's load now. A page whose store caches its own
/// read (Skills and Extensions, the workspace list, a Tailnet probe) reads it again
/// only for an ask: appearing again is the same page showing again.
enum LoadTrigger {
    /// The page appeared, or its subject changed.
    case appearance
    /// Something asked for a load: a pull to refresh, a Retry, `setNeedsLoad()`.
    case ask
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
    /// A load when the page first appears, and again only after a load that
    /// succeeded, when its subject changes, or when `setNeedsLoad()` asks: a
    /// page back from a pushed editor keeps what that editor saved, and a page
    /// whose first load failed (or was cancelled) tries again when it appears.
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
///   page loads, when, and what it is for. One task: started on appearance (per
///   the policy), on pull to refresh, on a subject change, and on
///   `setNeedsLoad()`; cancelled when the page leaves; a cancelled load is never
///   a failure. `loadTrigger` says which of those started it, so a page re-reads
///   a store it shares only when somebody asked — capture it (`let force =
///   loadTrigger == .ask`) before the first `await`: a pull that arrives while
///   the load runs replaces the task, and reads the trigger for itself. `loadTrigger` says whether the load running now was the page
///   appearing or an ask for it (a pull, a Retry), for a page whose store caches
///   its own read. `isLoading` and `loadFailure` are what the rows read.
/// - `animatesUpdates`: whether a snapshot change animates its rows.
/// - `stateSection()` with `emptyState()`, `hasContent()`, `loadingCaption()`
///   and `failureTitle()`: the list's one state row (the compact loading row, a
///   failure titled by the page with the request's reason under it and one Retry,
///   the page's empty state), which the base writes and draws. A store-backed
///   page builds the row with `stateRow(hasContent:isLoading:failure:)`;
///   `ListSection.state` remains for a section that states itself on its own.
/// - `wholeScreenState()`: the same state for a page with no rows at all, drawn
///   over the whole screen.
/// - `inputs(of:)`: the values a row is drawn from. Only rows whose inputs
///   changed are reconfigured; the default differs every pass, so a row a page
///   does not key cannot go stale. A row that holds an open menu, a switch in
///   flight, or text is keyed by what it draws. The theme is added for every row.
/// - `configure(_:item:)`: a plain list cell (`content(_:)` fills its title in
///   the theme's title color, `toggleRow` makes a switch row);
///   `configureCard(_:item:)` with `rowStyle` `.card` for the kit's theme-card
///   rows; or `dequeue(_:at:)` for pages with their own cell classes: the
///   kit's `SettingsIndexRowCell`, `SettingsMenuRowCell`,
///   `SettingsActionRowCell`, and `SettingsStateRowCell`.
/// - `isSelectable(_:)` and `select(_:)`: the rows that act when tapped. A
///   selectable row carries the button trait, and VoiceOver activation runs the
///   same `select(_:)`.
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
        // One section at a time: the page says which show a header. Everything
        // else is the kit's list, so the theme's `bg` shows behind the cards.
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
    /// The page's load: one task, cancelled on leave and before another starts.
    private var loadTask: Task<Void, Never>?
    /// The subject of the last load (a page's subject can be nil) and whether it
    /// was ever taken; compared on every pass.
    private var loadedSubject: AnyHashable?
    private var hasLoadedSubject = false
    /// Whether a load succeeded here: a page that loads once keeps it.
    private var hasLoadedOnce = false
    /// Why the load running now was started: the page appearing, or something
    /// asking for it (a pull to refresh, a Retry, `setNeedsLoad()`). Set before
    /// `load()` runs, so a page whose store caches its own read forces it only
    /// for an ask.
    private(set) var loadTrigger: LoadTrigger = .appearance
    /// Whether the page is loading its content now.
    private(set) var isLoading = false {
        didSet { if isLoading != oldValue { setNeedsUpdateProperties() } }
    }
    /// Why the page's last load failed. A load that succeeds clears it; a load
    /// the page cancelled never sets it.
    private(set) var loadFailure: LoadFailureReport? {
        didSet { if loadFailure != oldValue { setNeedsUpdateProperties() } }
    }
    /// The list's pull to refresh, for a page that loads. Only the base touches
    /// it: it starts the page's load and ends when that load settles.
    private lazy var pullToRefreshControl = UIRefreshControl()
    /// Where the page's settings are kept; `nil` for a page that has none.
    let pageScope: SettingsScope?
    /// The store behind the page's declared settings (`SettingsCatalog`).
    let settings: SettingsStore?
    /// The list's accessibility identifier, `<feature>.<page>.list`: the base
    /// derives the state row's identifier from it.
    let listIdentifier: String
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
        self.listIdentifier = listIdentifier
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

    /// Whether `section` shows its header: the `headers:` the page was built
    /// with, unless the page answers for each.
    func showsHeader(for section: Section) -> Bool { showsHeaders }

    // MARK: - Load

    /// What the page loads, and when. The default loads nothing.
    var loadPolicy: LoadPolicy { .none }

    /// What the page's load is for: the server it follows, the route it serves.
    /// Compared on every pass; a change cancels the running load, runs
    /// `subjectDidChange()`, and starts one for the new subject.
    func loadSubject() -> AnyHashable? { nil }

    /// The page's subject changed: drop what the old one showed.
    func subjectDidChange() {}

    /// Loads the page's content. A throw becomes `loadFailure`; a cancelled load
    /// (the page left, its subject changed, another load replaced it) is not a
    /// failure and stores nothing.
    func load() async throws {}

    /// Runs the page's `load()` now, cancelling one already running: a Retry, a
    /// foreground return, a settled sign-in.
    func setNeedsLoad() {
        startLoad(.ask)
    }

    /// Takes the failure back, for a page that says a load failed another way:
    /// a later failure sets it again.
    func clearLoadFailure() { loadFailure = nil }

    /// Runs `load()` for the page's subject now, replacing a load in flight.
    private func startLoad(_ trigger: LoadTrigger = .appearance) {
        guard loadPolicy != .none else { return }
        // A subject that changed while the page was covered ran no pass to drop
        // its rows, so the load that starts here does it.
        let subject = loadSubject()
        if hasLoadedSubject, subject != loadedSubject {
            hasLoadedOnce = false
            subjectDidChange()
        }
        loadTask?.cancel()
        loadedSubject = subject
        hasLoadedSubject = true
        loadTrigger = trigger
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await load()
                guard !Task.isCancelled else { return }
                loadFailure = nil
                isLoading = false
                // Only a load that succeeded is what a page keeps.
                hasLoadedOnce = true
            } catch {
                // A load this page cancelled leaves the flags to the load that
                // replaced it; the page is still here otherwise.
                guard !Task.isCancelled else { return }
                isLoading = false
                if !error.isLoadCancellation { loadFailure = failureReport(for: error) }
            }
            if pullToRefreshControl.isRefreshing { pullToRefreshControl.endRefreshing() }
        }
    }

    /// Compares the page's subject every pass: a new one belongs to another
    /// server, route, or connection.
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
        // The new subject has loaded nothing yet, so a page that loads once
        // loads it (and tries again if that fails).
        hasLoadedOnce = false
        subjectDidChange()
        // A covered page loads when it appears again.
        if isShowing { startLoad() }
    }

    /// The page's state while it has no rows to show at all: the same failure
    /// with Retry and the same loading as the row, then the page's empty state.
    /// A page whose whole-screen states differ (connecting to its server, a
    /// server that is gone) overrides this.
    func wholeScreenState() -> LoadState? {
        if isLoading { return .loading(loadingCaption()) }
        if let loadFailure {
            return .failed(
                title: loadFailure.title,
                message: loadFailure.reason,
                retry: RetryAction { [weak self] in self?.setNeedsLoad() }
            )
        }
        return emptyState()
    }

    // MARK: - State row

    /// The title of the page's failed row: “Couldn't Load Agent”, under which the
    /// request's own reason shows. nil says the failure is its own title, which a
    /// page uses for the words it throws from `load()` (`LoadFailure`).
    func failureTitle() -> String? { nil }

    /// The section the base puts the list's own state row in, as its first row:
    /// the page lists the section even when it holds nothing else. nil leaves the
    /// row to the page: a store-backed page builds the same row with
    /// `stateRow(hasContent:isLoading:failure:)`, and a page with nothing to list
    /// at all states itself over the whole screen.
    func stateSection() -> Section? { nil }

    /// Whether the load's content is on screen yet: false while the first load is
    /// on its way, so the base shows its loading row where the rows will be.
    func hasContent() -> Bool { true }

    /// The words under the compact loading row's spinner: “Loading skills…”. The
    /// whole-screen loading state draws the same.
    func loadingCaption() -> String? { nil }

    /// What the list says when it has nothing to show and nothing failed.
    func emptyState() -> LoadState? { nil }

    /// The one identifier the base's state row carries, whatever it shows: the
    /// list's own name (`skills.list` → `skills.state`).
    var stateRowIdentifier: String {
        let name = listIdentifier.hasSuffix(".list")
            ? String(listIdentifier.dropLast(".list".count))
            : listIdentifier
        return "\(name).state"
    }

    /// The list's one state row: a load in flight where the rows will be (a Retry
    /// keeps its row and turns it into this one), the failure with one Retry, and
    /// the page's empty state while it has nothing to show. The base fills its
    /// `stateSection()` with it; a page whose store owns the load passes the
    /// store's facts instead of the base's `isLoading` and `loadFailure`.
    func stateRow(hasContent: Bool, isLoading: Bool, failure: LoadFailureReport?) -> ListStateRow? {
        if isLoading, !hasContent || failure != nil {
            return ListStateRow(state: .loading(loadingCaption()), identifier: stateRowIdentifier)
        }
        if let failure {
            return ListStateRow(
                state: .failed(
                    title: failure.title,
                    message: failure.reason,
                    retry: RetryAction { [weak self] in self?.setNeedsLoad() }
                ),
                identifier: stateRowIdentifier
            )
        }
        guard !hasContent, let settled = emptyState() else { return nil }
        return ListStateRow(state: settled, identifier: stateRowIdentifier)
    }

    /// A store-backed page's failure: its reason under the page's `failureTitle()`.
    /// nil stays nil, so a page with nothing to say passes it straight through.
    func failureReport(reason: String?) -> LoadFailureReport? {
        guard let reason else { return nil }
        let title = failureTitle()
        return LoadFailureReport(title: title ?? reason, reason: title == nil ? nil : reason)
    }

    /// Why `error` failed the page's load: the page's own words when it threw a
    /// `LoadFailure`, else the request's reason under the page's `failureTitle()`.
    private func failureReport(for error: any Error) -> LoadFailureReport {
        if let words = error as? LoadFailure { return LoadFailureReport(title: words.message, reason: nil) }
        return LoadFailureReport(
            title: failureTitle() ?? String(localized: "Couldn't Load"),
            reason: error.localizedDescription
        )
    }

    /// Whether a snapshot change animates its rows (the default: once the list
    /// has rows).
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

    /// The page's items the list shows now, in order (a state row is not one).
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
                self?.startLoad(.ask)
            }, for: .valueChanged)
        }
        installDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(redrawRows), name: .oppiThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(redrawRows), name: .oppiEntityIconDidLoad, object: nil)
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

    /// A theme change repaints the rows, and so does artwork arriving: a row that
    /// drew an Agent's fallback symbol redraws once its Genmoji is decoded.
    @objc private func redrawRows() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        updateLoadSubject()
        pass &+= 1
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SettingsListStyle.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        let sections = stateSections()
        applySnapshot(sections, themeID: themeID)
        // A page with nothing to list is its state: no rows, one screen.
        showWholeScreenState(hasRows(sections) ? nil : wholeScreenState(), themeID: themeID)
    }

    /// The page's sections with the base's own state row in the section that
    /// carries it (`stateSection()`). A section that comes out with nothing in it
    /// — no rows, no state, no heading, no footer — is dropped: an empty card is a
    /// gap between the rows, not information.
    private func stateSections() -> [ListSection<Section, Item>] {
        var sections = sections()
        if let stateSection = stateSection(),
           let index = sections.firstIndex(where: { $0.id == stateSection }) {
            sections[index].state = stateRow(hasContent: hasContent(), isLoading: isLoading, failure: loadFailure)
        }
        sections.removeAll { $0.items.isEmpty && $0.state == nil && $0.header == nil && $0.footer == nil }
        return sections
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
            state, palette: themeID.palette, background: themeID.palette.ui.bg
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
