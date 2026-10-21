import UIKit

/// Chooses where a host's terminal takes its colors from: the host's own Ghostty
/// theme, the app's theme, or one theme by name. The names come from the host
/// over a live terminal's side channel when the screen opens, so a host with no
/// open terminal offers the first two and the one already chosen.
final class SSHTerminalColorPickerViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    private enum Section: Hashable { case choices, themes }
    private enum Item: Hashable {
        case host, oppi
        case theme(String)
        case loading, unavailable
    }

    private enum ThemeList {
        case offline
        case loading
        case failed
        case loaded([String])
    }

    private let selected: SSHTerminalColorChoice
    private let hostSummary: String
    private let channel: SSHTerminalChannel?
    private let onSelect: (SSHTerminalColorChoice) -> Void
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var themes: ThemeList
    private var query = ""
    private var loadTask: Task<Void, Never>?
    private var lastThemeID: ThemeID?

    /// `channel` is a connected terminal of this host, or nil when there is none.
    init(selected: SSHTerminalColorChoice, hostSummary: String, channel: SSHTerminalChannel?,
         onSelect: @escaping (SSHTerminalColorChoice) -> Void) {
        self.selected = selected
        self.hostSummary = hostSummary
        self.channel = channel
        self.onSelect = onSelect
        themes = channel == nil ? .offline : .loading
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = "Terminal Colors"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.autocapitalizationType = .none
        search.searchBar.accessibilityIdentifier = "sshTerminal.colors.search"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        applySnapshot()
        setNeedsUpdateProperties()
        loadThemes()
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = sshTerminalThemeID
        if lastThemeID != themeID {
            lastThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
            applySnapshot(reconfigure: true)
        }
    }

    private func loadThemes() {
        guard let channel else { return }
        loadTask = Task { [weak self] in
            let names = await SSHTerminalColorLoader.listThemes { try await channel.run($0) }
            guard !Task.isCancelled, let self else { return }
            themes = names.map { .loaded($0) } ?? .failed
            applySnapshot()
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        applySnapshot()
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = self?.footerText(at: indexPath)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func choice(for item: Item) -> SSHTerminalColorChoice? {
        switch item {
        case .host: .host
        case .oppi: .oppi
        case let .theme(name): .named(name)
        case .loading, .unavailable: nil
        }
    }

    private func configure(_ cell: UICollectionViewListCell, item: Item) {
        let palette = sshTerminalThemeID.palette
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.color = UIColor(palette.fg)
        content.secondaryTextProperties.color = UIColor(palette.comment)
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        switch item {
        case .host:
            content.text = SSHTerminalColorChoice.host.title
            content.secondaryText = hostSummary
            cell.accessibilityIdentifier = "sshTerminal.colors.option.host"
        case .oppi:
            content.text = SSHTerminalColorChoice.oppi.title
            cell.accessibilityIdentifier = "sshTerminal.colors.option.oppi"
        case let .theme(name):
            content.text = name
            cell.accessibilityIdentifier = "sshTerminal.colors.theme.\(name)"
        case .loading:
            content.text = "Loading themes…"
            content.textProperties.color = UIColor(palette.comment)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
        case .unavailable:
            content.text = "Couldn’t read the host’s themes"
            content.textProperties.color = UIColor(palette.comment)
        }
        if let value = choice(for: item) {
            let isSelected = value == selected
            cell.accessories = isSelected
                ? [.checkmark(options: .init(tintColor: UIColor(palette.blue)))] : []
            cell.accessibilityTraits.insert(.button)
            if isSelected { cell.accessibilityTraits.insert(.selected) } else { cell.accessibilityTraits.remove(.selected) }
        }
        cell.contentConfiguration = content
    }

    private func footerText(at indexPath: IndexPath) -> String? {
        switch dataSource?.snapshot().sectionIdentifiers[safe: indexPath.section] {
        case .choices:
            return "The host’s theme is read from its Ghostty config each time you connect. Oppi uses its own theme where the host has none."
        case .themes:
            if case .offline = themes {
                return "Connect to this host to choose from the themes it has."
            }
            return nil
        case nil: return nil
        }
    }

    private func applySnapshot(reconfigure: Bool = false) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.choices])
        snapshot.appendItems([.host, .oppi], toSection: .choices)
        snapshot.appendSections([.themes])
        switch themes {
        case .offline:
            if case let .named(name) = selected { snapshot.appendItems([.theme(name)], toSection: .themes) }
        case .loading:
            snapshot.appendItems([.loading], toSection: .themes)
        case .failed:
            snapshot.appendItems([.unavailable], toSection: .themes)
        case let .loaded(names):
            let shown = query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
            snapshot.appendItems(shown.map(Item.theme), toSection: .themes)
        }
        if reconfigure { snapshot.reconfigureItems(snapshot.itemIdentifiers) }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource?.itemIdentifier(for: indexPath).flatMap(choice(for:)) != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let value = dataSource?.itemIdentifier(for: indexPath).flatMap(choice(for:)) else { return }
        onSelect(value)
        Router.finish(self)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
