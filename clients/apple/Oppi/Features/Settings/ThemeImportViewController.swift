import UIKit

/// Custom Themes: the server's themes. Tap one to import and apply it, edit
/// one with an Oppi control session (swipe or touch and hold), or describe a
/// new one in the guided composer, as Agents and Schedules do.
@MainActor
final class ThemeImportViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable { case state, themes }
    private enum Item: Hashable {
        case loading
        case failed
        case empty
        case theme(String)
    }

    private let root: AppRootEnvironment
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private let refreshControl = UIRefreshControl()
    private let composer: GuidedControlComposerController
    private let revisionSheet = RouterModalPresenter()

    private var remoteThemes: [RemoteThemeSummary] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var isLoading = true {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var importingName: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var revisingTheme: RemoteThemeSummary? {
        didSet { setNeedsUpdateProperties() }
    }
    private var loadTask: Task<Void, Never>?

    init(root: AppRootEnvironment) {
        self.root = root
        composer = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .themes,
                intent: .create,
                placeholder: "Describe a new theme…"
            ),
            root: root
        )
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = "Custom Themes"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(ControlScreenList.layout(
            appearance: .insetGrouped,
            footers: true,
            trailingSwipe: { [weak self] in self?.swipeActions(at: $0) }
        ), animated: false)
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "themes.list"
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        composer.install(in: self)
        revisionSheet.anchor = self
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Like the SwiftUI `.task` it replaces, a load each time it shows.
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadThemes() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        revisionSheet.sync()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        composer.setScreenError(remoteThemes.isEmpty ? nil : error, identifier: "themes.error")
        applySnapshot()
        let revising = revisingTheme
        revisionSheet.update(
            id: revising.map { AnyHashable($0.id) },
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.revisingTheme = nil },
            screen: { [root] in
                .controller {
                    GuidedControlSessionViewController(
                        configuration: GuidedControlComposerConfiguration(
                            domain: .themes,
                            intent: .revise,
                            targetId: revising?.filename,
                            targetName: revising?.name,
                            targetPath: revising?.path,
                            allowsEmptyRequest: true,
                            placeholder: "Describe how this theme should change…"
                        ),
                        root: root
                    )
                }
            }
        )
    }

    // MARK: - List

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if remoteThemes.isEmpty {
            snapshot.appendSections([.state])
            let state: Item = isLoading ? .loading : (error != nil ? .failed : .empty)
            snapshot.appendItems([state], toSection: .state)
        } else {
            snapshot.appendSections([.themes])
            snapshot.appendItems(remoteThemes.map { .theme($0.filename) }, toSection: .themes)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            if self?.dataSource?.sectionIdentifier(for: indexPath.section) == .themes {
                content.text = "Tap a theme to import and apply it. Swipe or touch and hold to edit it with Oppi."
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        switch item {
        case .loading:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.loading("Fetching themes…")
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .failed:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.unavailable(
                "Unable to Load Themes",
                systemImage: "exclamationmark.triangle",
                description: error,
                palette: palette
            )
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .empty:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.unavailable(
                "No Custom Themes",
                systemImage: "paintpalette",
                description: "Describe a theme below and Oppi writes it to your server.",
                palette: palette
            )
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .theme(let filename):
            guard let summary = remoteThemes.first(where: { $0.filename == filename }) else { return }
            let isImported = CustomThemeStore.load(name: summary.name) != nil
            ControlScreenList.buttonRow(
                cell,
                identifier: "themes.row.\(summary.filename)",
                label: summary.name,
                value: importingName == filename ? "Importing" : (isImported ? "Imported" : summary.colorScheme),
                contextMenu: contextMenu(summary, isImported: isImported)
            ) { [weak self] in
                self?.startImport(summary)
            }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = summary.name
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryText = summary.colorScheme
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            content.textToSecondaryTextVerticalPadding = 2
            cell.contentConfiguration = content
            if importingName == filename {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
            } else if isImported {
                let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
                check.tintColor = UIColor(palette.green)
                cell.accessories = [.customView(configuration: .init(customView: check, placement: .trailing()))]
            }
            ControlScreenList.background(cell, grouped: true, palette: palette)
        }
    }

    private func summary(at indexPath: IndexPath) -> RemoteThemeSummary? {
        guard case .theme(let filename) = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        return remoteThemes.first { $0.filename == filename }
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let summary = summary(at: indexPath) else { return nil }
        var actions: [UIContextualAction] = []
        if CustomThemeStore.load(name: summary.name) != nil {
            let delete = UIContextualAction(style: .destructive, title: "Delete from Device") { [weak self] _, _, done in
                self?.confirmRemoval(summary)
                done(true)
            }
            delete.image = UIImage(systemName: "trash")
            actions.append(delete)
        }
        let edit = UIContextualAction(style: .normal, title: "Edit with Oppi") { [weak self] _, _, done in
            self?.revisingTheme = summary
            done(true)
        }
        edit.image = UIImage(systemName: "text.bubble")
        edit.backgroundColor = UIColor(palette.blue)
        actions.append(edit)
        let config = UISwipeActionsConfiguration(actions: actions)
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    /// Touch and hold: Edit with Oppi, and Delete from Device once imported.
    private func contextMenu(_ summary: RemoteThemeSummary, isImported: Bool) -> UIMenu {
        let edit = UIAction(title: "Edit with Oppi", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
            self?.revisingTheme = summary
        }
        edit.accessibilityIdentifier = "themes.row.\(summary.filename).edit"
        var children: [UIMenuElement] = [edit]
        if isImported {
            children.append(UIAction(
                title: "Delete from Device",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in self?.confirmRemoval(summary) })
        }
        return UIMenu(children: children)
    }

    // MARK: - Actions

    private func confirmRemoval(_ summary: RemoteThemeSummary) {
        let sheet = UIAlertController(
            title: "Delete \(summary.name) from this device?",
            message: "The imported copy is removed. You can import it again from the server.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Delete Theme", style: .destructive) { [weak self] _ in
            self?.root.themeStore.removeImportedTheme(named: summary.name)
            self?.setNeedsUpdateProperties()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        ControlScreenList.presentActionSheet(sheet, from: self)
    }

    private func refresh() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadThemes()
            self?.refreshControl.endRefreshing()
        }
    }

    private func loadThemes() async {
        guard let api = root.coordinator.activeConnection.apiClient else {
            error = "Not connected"
            isLoading = false
            return
        }
        isLoading = true
        // A replaced load leaves the flag to the load that replaced it.
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let themes = try await api.listThemes()
            guard !Task.isCancelled else { return }
            remoteThemes = themes
            error = nil
        } catch {
            // A load this screen cancelled (it left, or a refresh replaced it) is no error.
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func startImport(_ summary: RemoteThemeSummary) {
        Task { await importTheme(summary) }
    }

    private func importTheme(_ summary: RemoteThemeSummary) async {
        guard let api = root.coordinator.activeConnection.apiClient else { return }
        importingName = summary.filename
        defer { importingName = nil }
        do {
            let theme = try await api.getTheme(name: summary.filename)
            guard theme.toPalette() != nil else { return }
            CustomThemeStore.save(theme)
            root.themeStore.selectedThemeID = .custom(theme.name)
            AppHaptics.success()
        } catch {}
    }
}
