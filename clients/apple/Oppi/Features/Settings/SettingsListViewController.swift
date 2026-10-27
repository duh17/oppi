import UIKit

/// One section of a settings page: its rows, and the header and footer text
/// the section shows. A page returns these from `sections()` and the base list
/// owns the snapshot, the headings, and the redraw.
struct SettingsSectionModel<Section: Hashable & Sendable, Item: Hashable & Sendable> {
    var id: Section
    var header: String?
    var footer: String?
    var items: [Item]

    init(_ id: Section, header: String? = nil, footer: String? = nil, items: [Item]) {
        self.id = id
        self.header = header
        self.footer = footer
        self.items = items
    }
}

/// The base of a settings page: a themed inset-grouped list with section
/// headers and footers, rows redrawn only when their inputs change, and a
/// refresh each time the page comes back on screen.
///
/// A page subclasses it, names its `Section` and `Item` types, and overrides:
/// - `sections()`: the sections and rows now. It runs inside
///   `updateProperties()`, so every `@Observable` store it reads re-runs the
///   page when it changes. Preferences that are not observable call
///   `setNeedsUpdateProperties()` after writing; `viewWillAppear` does the
///   same when the page comes back from a pushed page.
/// - `inputs(of:)`: the values a row is drawn from. Only rows whose inputs
///   changed are reconfigured, so a pass triggered by an open pop-up menu or by
///   another row leaves that menu alone. The theme is added for every row.
/// - `configure(_:item:)`: a plain list cell, or `dequeue(_:at:)` for pages
///   with their own cell classes.
/// - `isSelectable(_:)` and `select(_:)`: the rows that act when tapped. A
///   selectable row carries the button trait, and VoiceOver activation selects
///   it, so touch and accessibility run the same `select(_:)`.
@MainActor
class SettingsListViewController<Section: Hashable & Sendable, Item: Hashable & Sendable>: UIViewController, UICollectionViewDelegate {
    let collectionView: UICollectionView
    private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var appliedThemeID: ThemeID?
    private var changedRows = ChangedRows<Item>()
    private var models: [Section: SettingsSectionModel<Section, Item>] = [:]

    /// - Parameters:
    ///   - listIdentifier: the list's accessibility identifier, `settings.<page>.list`.
    ///   - headers: whether sections can show a header.
    ///   - footers: whether sections can show a footer.
    ///   - largeTitle: a page that roots its stack keeps the large title.
    init(
        title: String,
        listIdentifier: String,
        headers: Bool = false,
        footers: Bool = false,
        largeTitle: Bool = false
    ) {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        if headers { config.headerMode = .supplementary }
        if footers { config.footerMode = .supplementary }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
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
    func sections() -> [SettingsSectionModel<Section, Item>] { [] }

    /// The values `item` is drawn from; the row redraws when they change.
    func inputs(of item: Item) -> AnyHashable { AnyHashable(0) }

    /// Fills a plain list cell for `item`. The cell arrives reset.
    func configure(_ cell: UICollectionViewListCell, item: Item) {}

    /// The cell for `item`. Override to dequeue a page's own cell classes;
    /// the default is a plain list cell filled by `configure(_:item:)`.
    func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: plainCell, for: indexPath, item: item)
    }

    /// Called once before the first row is dequeued. A page with its own cell
    /// registrations creates them here (touching its `lazy var`s): UIKit refuses
    /// a registration created while a cell is being dequeued.
    func prepareRegistrations() {}

    /// Whether tapping `item` does something.
    func isSelectable(_ item: Item) -> Bool { false }

    /// Runs when a selectable row is tapped or activated.
    func select(_ item: Item) {}

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        SSHTerminalSettingsList.pin(collectionView, in: view)
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

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        applySnapshot(sections(), themeID: themeID)
    }

    // MARK: - Snapshot

    private func applySnapshot(_ sections: [SettingsSectionModel<Section, Item>], themeID: ThemeID) {
        guard let dataSource else { return }
        let previous = models
        models = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for section in sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.items, toSection: section.id)
        }
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        // The theme is in the key: a light/dark or theme change repaints every
        // row, which otherwise keeps the colors it was configured with.
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { item in
            AnyHashable([AnyHashable(themeID), inputs(of: item)])
        }
        // Headings are not rows: a section whose header or footer text moved is
        // reloaded so its supplementary view is configured again. Its rows are
        // rebuilt by the reload, so they are not also reconfigured.
        let retitled = sections.filter { section in
            guard let old = previous[section.id] else { return false }
            return old.header != section.header || old.footer != section.footer
        }
        let reloaded = Set(retitled.flatMap(\.items))
        snapshot.reconfigureItems(changed.filter { shown.contains($0) && !reloaded.contains($0) })
        snapshot.reloadSections(retitled.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
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

    private func installDataSource() {
        _ = plainCell
        prepareRegistrations()
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.model(at: indexPath)?.header
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.model(at: indexPath)?.footer
            content.textProperties.numberOfLines = 0
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] _, indexPath, item in
            self?.dequeue(item, at: indexPath)
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func model(at indexPath: IndexPath) -> SettingsSectionModel<Section, Item>? {
        dataSource?.sectionIdentifier(for: indexPath.section).flatMap { models[$0] }
    }

    // MARK: - UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource?.itemIdentifier(for: indexPath).map(isSelectable) ?? false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        select(item)
    }
}
