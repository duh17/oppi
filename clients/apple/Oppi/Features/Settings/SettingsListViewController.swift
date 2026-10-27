import UIKit

/// One section of a settings page: its rows, and the header and footer text
/// the section shows. A page returns these from `sections()` and the base list
/// owns the snapshot, the headings, and the redraw.
///
/// `scope` is where the section's settings are kept, when that differs from
/// the page's own scope. The base puts one sentence about it in front of the
/// footer, so a page that mixes scopes says which rows are which.
struct SettingsSectionModel<Section: Hashable & Sendable, Item: Hashable & Sendable> {
    var id: Section
    var header: String?
    var footer: String?
    var scope: SettingsScope?
    var items: [Item]

    init(_ id: Section, header: String? = nil, footer: String? = nil, scope: SettingsScope? = nil, items: [Item]) {
        self.id = id
        self.header = header
        self.footer = footer
        self.scope = scope
        self.items = items
    }
}

/// The base of a settings page: a themed inset-grouped list with section
/// headers and footers, rows redrawn only when their inputs change, and a
/// refresh each time the page comes back on screen. The list's own background
/// is clear, so the theme's `bg` shows behind the cards.
///
/// A page subclasses it, names its `Section` and `Item` types, says its
/// scope (where the page's settings are kept), and overrides:
/// - `sections()`: the sections and rows now. It runs inside
///   `updateProperties()`, so every `@Observable` store it reads re-runs the
///   page when it changes. Preferences that are not observable call
///   `setNeedsUpdateProperties()` after writing; `viewWillAppear` does the
///   same when the page comes back from a pushed page.
/// - `inputs(of:)`: the values a row is drawn from. Only rows whose inputs
///   changed are reconfigured, so a pass triggered by an open pop-up menu or by
///   another row leaves that menu alone. The theme is added for every row.
/// - `configure(_:item:)`: a plain list cell (`content(_:)` fills its title in
///   the theme's title color, `toggleRow` makes a switch row), or
///   `dequeue(_:at:)` for pages with their own cell classes: the kit's
///   `SettingsIndexRowCell`, `SettingsMenuRowCell`, `SettingsActionRowCell`,
///   and `SettingsStateRowCell`.
/// - `isSelectable(_:)` and `select(_:)`: the rows that act when tapped. A
///   selectable row carries the button trait, and VoiceOver activation selects
///   it, so touch and accessibility run the same `select(_:)`.
/// - `copyText(of:)`: the text a long press on an info row copies.
/// - `trailingSwipeActions(for:)`, `decorate(header:section:)`,
///   `decorate(footer:section:)`: swipe actions, and an icon or tone on a
///   section heading.
///
/// The kit is presentational: a page keeps its own data and saves it itself.
@MainActor
class SettingsListViewController<Section: Hashable & Sendable, Item: Hashable & Sendable>: UIViewController, UICollectionViewDelegate {
    private(set) lazy var collectionView: UICollectionView = {
        var config = SettingsListStyle.layoutConfiguration(headers: showsHeaders, footers: showsFooters)
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let item = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            return trailingSwipeActions(for: item)
        }
        return UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
    }()
    private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    /// Where the page's settings are kept. A section says its scope only when
    /// it differs from this.
    let pageScope: SettingsScope
    private let showsHeaders: Bool
    private let showsFooters: Bool
    private var appliedThemeID: ThemeID?
    private var changedRows = ChangedRows<Item>()
    private var models: [Section: SettingsSectionModel<Section, Item>] = [:]

    /// - Parameters:
    ///   - listIdentifier: the list's accessibility identifier, `settings.<page>.list`.
    ///   - scope: where the page's settings are kept. Every page says it.
    ///   - headers: whether sections can show a header.
    ///   - footers: whether sections can show a footer. A page with a section
    ///     scope needs them, since the scope sentence is part of the footer.
    ///   - largeTitle: a page that roots its stack keeps the large title.
    init(
        title: String,
        listIdentifier: String,
        scope: SettingsScope,
        headers: Bool = false,
        footers: Bool = false,
        largeTitle: Bool = false
    ) {
        pageScope = scope
        showsHeaders = headers
        showsFooters = footers
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
    /// is the switch's, which is what `app.switches[id]` finds.
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
        cell.accessories = [.settingsToggle(isOn, identifier: identifier, label: title, isEnabled: isEnabled, onChange: onChange)]
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        SettingsListStyle.pin(collectionView, in: view)
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
            SettingsListStyle.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        applySnapshot(sections(), themeID: themeID)
    }

    // MARK: - Snapshot

    private func applySnapshot(_ sections: [SettingsSectionModel<Section, Item>], themeID: ThemeID) {
        guard let dataSource else { return }
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
        snapshot.reconfigureItems(changed.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
        // Headings are not rows, so a reconfigure does not reach them. They are
        // redrawn in place: reloading the section would rebuild its rows and
        // move VoiceOver focus off the one the person is on.
        SetupListSupplementaries.refresh(collectionView) { [weak self] view, kind, indexPath in
            self?.configureSupplementary(view, kind: kind, at: indexPath)
        }
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
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, kind, indexPath in
            self?.configureSupplementary(view, kind: kind, at: indexPath)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, kind, indexPath in
            self?.configureSupplementary(view, kind: kind, at: indexPath)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView, cellProvider: SettingsListStyle.cardProvider { [weak self] _, indexPath, item in
            self?.dequeue(item, at: indexPath)
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
        dataSource?.itemIdentifier(for: indexPath).map(isSelectable) ?? false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        select(item)
    }

    /// Long press on an info row copies its value.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = dataSource?.itemIdentifier(for: indexPath),
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
