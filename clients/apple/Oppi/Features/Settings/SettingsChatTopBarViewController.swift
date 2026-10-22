import UIKit

/// Settings > Chat > Top Bar: which of Files, Git, Outline, Context, and Terminal a
/// chat's top bar shows, and in what order. A row's switch shows or hides it; a
/// hidden button moves into the … menu, which always stays last. Rows reorder
/// with their handles, so editing stays on and there is no Edit button.
///
/// The order holds every action, hidden ones included, so a hidden button
/// returns to the place it left. Terminal keeps its row in every chat: a chat
/// without a workspace folder only leaves it out of that chat's bar.
final class SettingsChatTopBarViewController: UIViewController, UICollectionViewDelegate {
    private let defaults: UserDefaults
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, ChatTopBarAction>?
    private var appliedThemeID: ThemeID?
    private var changedRows = ChangedRows<ChatTopBarAction>()

    private enum Section: Hashable { case buttons }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Top Bar")
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The chat's "Chat tools are in the menu" hint points here; reaching
        // the page is done.
        FeatureEducationTips.markTopBarMoreToolsFound()
        collectionView.delegate = self
        collectionView.isEditing = true
        collectionView.accessibilityIdentifier = "settings.chat.topBar.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil)
        setNeedsUpdateProperties()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        applySnapshot()
    }

    private var layout: ChatTopBarLayout { AppPreferences.ChatTopBar.layout(in: defaults) }

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, ChatTopBarAction>()
        snapshot.appendSections([.buttons])
        snapshot.appendItems(layout.order, toSection: .buttons)
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { AnyHashable(layout.isShown($0)) }
        snapshot.reconfigureItems(changed.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, ChatTopBarAction> { [weak self] cell, _, action in
            self?.configure(cell, action: action)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = self?.footer
            content.textProperties.numberOfLines = 0
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, action in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: action)
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        dataSource?.reorderingHandlers.canReorderItem = { _ in true }
        dataSource?.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            // Every action has a row here, so the dragged order is the order.
            let order = transaction.finalSnapshot.itemIdentifiers(inSection: .buttons)
            AppPreferences.ChatTopBar.setLayout(ChatTopBarLayout(order: order, shown: layout.shown), in: defaults)
            // The bar's order now matches; redraw so the snapshot and the
            // preference cannot drift after a drag.
            setNeedsUpdateProperties()
        }
    }

    private func configure(_ cell: UICollectionViewListCell, action: ChatTopBarAction) {
        var content = cell.defaultContentConfiguration()
        content.text = action.label
        content.image = action.image(textStyle: .body)
        // The symbol column's width for every row, so a label beside the Git
        // logo (an image, not a symbol) lines up with the others.
        content.imageProperties.reservedLayoutSize.width = UIListContentConfiguration.ImageProperties.standardDimension
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "settings.chat.topBar.row.\(action.rawValue)"
        cell.accessories = [
            .settingsToggle(
                layout.isShown(action),
                identifier: "settings.chat.topBar.\(action.rawValue)"
            ) { [weak self] isOn in
                guard let self else { return }
                AppPreferences.ChatTopBar.setLayout(layout.setting(action, shown: isOn), in: defaults)
            },
            // Always editing, so the handle is part of the row, not a mode.
            .reorder(displayed: .always),
        ]
    }

    private var footer: String {
        String(localized: "A button turned off moves into the … menu, which always stays last. Terminal also needs a workspace folder on the server.")
    }

    /// Rows are switched and dragged, never selected: editing mode stays on for
    /// the reorder handles, and a selected row would read as a choice.
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }
}
