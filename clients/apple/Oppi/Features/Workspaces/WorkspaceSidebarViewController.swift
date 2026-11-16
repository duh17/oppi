import UIKit

/// The workspace list: the split shell's primary column and the compact
/// shell's drawer.
///
/// A scrolling `UICollectionView` list holds the destinations, the Pinned
/// section (the server's pins, `PinsSection`), the Workspaces disclosure, and
/// the workspace rows. New Workspace and App Settings sit in a
/// second, non-scrolling list pinned below it. Everything reads
/// `SceneNavigation` and the stores in `updateProperties()`: the selection a row
/// paints is `SceneNavigation`'s, never the collection view's own. A store tick
/// reconfigures only the rows whose content changed.
///
/// Destinations, the disclosure, state rows, and the footer are native list
/// cells. The workspace row (`WorkspaceSidebarRowConfiguration`) draws the
/// runtime icon, lock badge, status counts, and git line.
final class WorkspaceSidebarViewController: UIViewController {
    private let root: AppRootEnvironment
    private let onSelect: (() -> Void)?

    private var navigation: SceneNavigation { root.navigation }
    private var coordinator: ConnectionCoordinator { root.coordinator }

    private let headerLabel = UILabel()
    private let list: UICollectionView
    private let footerList: FooterListView
    private let footerDivider = UIView()
    private let footerHeight: NSLayoutConstraint
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var footerDataSource: UICollectionViewDiffableDataSource<Section, Item>?

    private var model = Model()
    private var appliedThemeID: ThemeID?
    private var lastDefaults: Defaults?
    private var isPresentingCreate = false
    /// The next snapshot animates: the user toggled the disclosure.
    private var animatesNextSnapshot = false
    /// The Pinned section of the window's server; a new one when the server changes.
    private var pinsSection: PinsSection?

    private enum Section: Hashable { case main }

    /// Fixed ids for everything but workspaces, which use the workspace id.
    private enum Item: Hashable {
        case utility(WorkspaceUtilityNavTarget)
        case pinsHeader
        case pin(String)
        case disclosure
        case workspace(String)
        case loading
        case unavailable
        case empty
        case stale
        case noServer
        case newWorkspace

        var pinId: String? {
            if case .pin(let id) = self { return id }
            return nil
        }
    }

    /// What `AppStorage` read before: the same defaults keys.
    private struct Defaults: Equatable {
        var workspacesExpanded: Bool
        var pluginSidebar: Bool

        static func read() -> Self {
            let defaults = UserDefaults.standard
            return Self(
                workspacesExpanded: defaults.object(forKey: AppIdentifiers.workspaceSidebarExpandedKey) as? Bool
                    ?? WorkspaceSidebarDisclosurePolicy.defaultExpanded,
                pluginSidebar: AppPreferenceStore.Experiments.pluginSidebarEnabled
            )
        }
    }

    private struct UtilityRow: Equatable {
        let item: WorkspaceSidebarPrimaryUtilityItem
        let isSelected: Bool
    }

    private struct WorkspaceRow: Equatable {
        let target: WorkspaceNavTarget
        let status: WorkspaceSidebarSessionStatus
        let gitSummary: WorkspaceSidebarGitSummary?
        let isSelected: Bool
        let lockBadge: ScopedLockState
    }

    /// Everything the cells draw, built in `updateProperties()`.
    private struct Model {
        var mainItems: [Item] = []
        var footerItems: [Item] = []
        var utilities: [WorkspaceUtilityNavTarget: UtilityRow] = [:]
        var workspaces: [String: WorkspaceRow] = [:]
        var pinsHeader: PinsSection.Header?
        var pins: [String: PinsSection.Row] = [:]
        var workspacesExpanded = WorkspaceSidebarDisclosurePolicy.defaultExpanded
        var server: PairedServer?

        func contentDiffers(_ item: Item, from previous: Self) -> Bool {
            switch item {
            case .utility(let target): utilities[target] != previous.utilities[target]
            case .pinsHeader: pinsHeader != previous.pinsHeader
            case .pin(let id): pins[id] != previous.pins[id]
            case .workspace(let id): workspaces[id] != previous.workspaces[id]
            case .disclosure: workspacesExpanded != previous.workspacesExpanded
            default: false
            }
        }
    }

    init(root: AppRootEnvironment, onSelect: (() -> Void)? = nil) {
        self.root = root
        self.onSelect = onSelect
        list = UICollectionView(frame: .zero, collectionViewLayout: Self.listLayout(bottomInset: 12))
        footerList = FooterListView(frame: .zero, collectionViewLayout: Self.listLayout(topInset: 2, bottomInset: 8))
        footerHeight = footerList.heightAnchor.constraint(equalToConstant: 112)
        super.init(nibName: nil, bundle: nil)
        // Controllers presented from here find the root.
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        headerLabel.text = "Oppi"
        headerLabel.font = Self.font(.title2, .bold)
        headerLabel.adjustsFontForContentSizeCategory = true
        headerLabel.numberOfLines = 1
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        list.backgroundColor = .clear
        // Only pin rows select (`shouldSelectItemAt`); every other row takes
        // its taps on its clear button.
        list.accessibilityIdentifier = "workspace.sidebar.scroll"
        list.translatesAutoresizingMaskIntoConstraints = false
        footerList.backgroundColor = .clear
        footerList.allowsSelection = false
        footerList.isScrollEnabled = false
        footerList.translatesAutoresizingMaskIntoConstraints = false
        footerDivider.backgroundColor = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerLabel)
        view.addSubview(list)
        view.addSubview(footerDivider)
        view.addSubview(footerList)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 20),
            headerLabel.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 20),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -20),
            list.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
            footerDivider.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -16),
            footerDivider.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            footerDivider.bottomAnchor.constraint(equalTo: footerList.topAnchor),
            footerList.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            footerList.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            footerList.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            footerHeight,
        ])
        footerList.onContentHeightChange = { [weak self] height in
            guard height > 0, self?.footerHeight.constant != height else { return }
            self?.footerHeight.constant = height
        }

        dataSource = makeDataSource(for: list)
        footerDataSource = makeDataSource(for: footerList)
        list.delegate = self
        list.dragDelegate = self
        // Edit mode moves pins only (`PinsSection`).
        dataSource?.reorderingHandlers.canReorderItem = { [weak self] item in
            if case .pin = item { self?.pinsSection?.isEditing == true } else { false }
        }
        dataSource?.reorderingHandlers.didReorder = { [weak self] transaction in
            self?.pinsSection?.didReorder(transaction.finalSnapshot.itemIdentifiers.compactMap(\.pinId))
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A pinned folder deleted on disk sends no event; its status is read again.
        pinsSection?.refresh()
    }

    override func updateProperties() {
        super.updateProperties()
        guard isViewLoaded else { return }
        let themeStore = root.themeStore
        overrideUserInterfaceStyle = themeStore.userInterfaceStyle
        let themeID = themeStore.activeThemeID
        let themeChanged = themeID != appliedThemeID
        if themeChanged {
            appliedThemeID = themeID
            view.backgroundColor = themeID.palette.ui.bg
            headerLabel.textColor = themeID.palette.ui.fg
        }
        let previous = model
        model = makeModel()
        apply(previous: previous, themeChanged: themeChanged)
    }

    /// The disclosure and SSH flags changed in Settings or
    /// elsewhere in the app, as `AppStorage` reacted before.
    /// Posted on whichever thread wrote the default.
    @objc nonisolated private func defaultsDidChange() {
        Task { @MainActor [weak self] in
            guard let self, Defaults.read() != lastDefaults else { return }
            setNeedsUpdateProperties()
        }
    }

    // MARK: Model

    private var selectedServer: PairedServer? {
        ServerSelection.resolve(
            selectedId: root.windowServerId,
            from: coordinator.serverStore.servers
        )
    }

    private func makeModel() -> Model {
        let defaults = Defaults.read()
        lastDefaults = defaults
        let server = selectedServer
        var model = Model()
        model.server = server
        model.workspacesExpanded = defaults.workspacesExpanded

        let selectionTarget = navigation.selectedWorkspaceFilter
        func isUtilitySelected(_ target: WorkspaceUtilityNavTarget) -> Bool {
            navigation.workspaceNavigationPresentation == .split
                && navigation.splitDetailColumn.root == .utility(target)
        }

        // The pages the window's server offers, and its plugin entries while their experiment is on.
        let connection = root.windowConnection
        let plugins = defaults.pluginSidebar ? connection?.serverCapabilities?.pluginSidebar ?? [] : []
        let items = WorkspaceSidebarPrimaryUtilities.items(plugins: plugins) { connection?.offers($0) ?? true }
        for item in items {
            model.utilities[item.target] = UtilityRow(item: item, isSelected: isUtilitySelected(item.target))
            model.mainItems.append(.utility(item.target))
        }
        if let pinned = pinsSection(serverId: server?.id)?.content() {
            model.pinsHeader = pinned.header
            model.mainItems.append(.pinsHeader)
            for row in pinned.rows {
                model.pins[row.id] = row
                model.mainItems.append(.pin(row.id))
            }
        }
        model.mainItems.append(.disclosure)

        if model.workspacesExpanded, let server {
            let serverId = server.id
            let connection = coordinator.connection(for: serverId)
            let workspaceStore = connection?.workspaceStore
            let summaries = workspaceStore?.workspaceSummaries(forServer: serverId) ?? [:]
            let workspaces = sortedWorkspacesForList(workspaceStore?.workspaces ?? [], summaries: summaries)
            let availability = WorkspaceCatalogAvailability(
                hasWorkspaces: !workspaces.isEmpty,
                isLoaded: workspaceStore?.isLoaded ?? false,
                isSyncing: workspaceStore?.isSyncing ?? false,
                lastSyncFailed: workspaceStore?.lastSyncFailed ?? false,
                hasAPIClient: connection?.apiClient != nil,
                isPreparing: coordinator.preparingServerIds.contains(serverId)
            )
            switch availability {
            case .loading:
                model.mainItems.append(.loading)
            case .unavailable:
                model.mainItems.append(.unavailable)
            case .empty:
                model.mainItems.append(.empty)
            case .available:
                if connection == nil
                    || connection?.serverHealth(forServer: serverId).transportState == .disconnected
                    || workspaceStore?.lastSyncFailed == true {
                    model.mainItems.append(.stale)
                }
                // A diffable list traps on a repeated item; a repeated workspace id shows once.
                var seenWorkspaceIds = Set<String>()
                for workspace in workspaces where seenWorkspaceIds.insert(workspace.id).inserted {
                    let target = WorkspaceNavTarget(serverId: serverId, workspace: workspace)
                    model.workspaces[workspace.id] = WorkspaceRow(
                        target: target,
                        status: workspaceSessionStatus(workspaceId: workspace.id, connection: connection),
                        gitSummary: workspaceGitSummary(summaries[workspace.id]?.gitSummary),
                        isSelected: selectionTarget == target,
                        lockBadge: ScopedLockService.shared.badge(
                            .workspace(serverId: serverId, workspaceId: workspace.id)
                        )
                    )
                    model.mainItems.append(.workspace(workspace.id))
                }
            }
        } else if model.workspacesExpanded {
            model.mainItems.append(.noServer)
        }

        if server != nil { model.footerItems.append(.newWorkspace) }
        let appSettings = WorkspaceSidebarPrimaryUtilities.appSettings
        model.utilities[appSettings.target] = UtilityRow(
            item: appSettings,
            isSelected: isUtilitySelected(appSettings.target)
        )
        model.footerItems.append(.utility(appSettings.target))
        return model
    }

    /// The Pinned section of `serverId`, the window's server: every pin of
    /// that server. A tap opens it as a pane link does (beside the focused
    /// pane on a wide window, else in the main pane); the menu's pane items
    /// open from the focused pane, since the sidebar sits outside the panes.
    private func pinsSection(serverId: String?) -> PinsSection? {
        guard let serverId else {
            pinsSection = nil
            return nil
        }
        if let pinsSection, pinsSection.serverId == serverId { return pinsSection }
        list.isEditing = false
        let root = root
        let section = PinsSection(serverId: serverId, identifierPrefix: "workspace.sidebar", presenter: self, hooks: .init(
            // The section is the window server's; a new server makes a new section.
            connection: { root.windowConnection },
            shows: { _ in true },
            open: { [weak self] pin, inMainPane in
                let entry = pin.paneEntry(serverId: serverId)
                root.opener.open(
                    .pane(PaneLink(server: serverId, route: entry.route), sourceServerID: serverId),
                    inMainPane: inMainPane
                )
                self?.onSelect?()
            },
            paneSource: { [weak self] in
                self?.view.window.flatMap { Router.focusedScreen(in: $0) }?.viewIfLoaded
            },
            isCollapsed: { FileBrowserViewOptionsStore.shared.sidebarPinsCollapsed },
            setCollapsed: { FileBrowserViewOptionsStore.shared.setSidebarPinsCollapsed($0) },
            setEditing: { [weak self] editing in self?.list.isEditing = editing },
            changed: { [weak self] in
                self?.animatesNextSnapshot = true
                self?.setNeedsUpdateProperties()
            }
        ))
        pinsSection = section
        return section
    }

    private func workspaceSessionStatus(
        workspaceId: String,
        connection: ServerConnection?
    ) -> WorkspaceSidebarSessionStatus {
        guard let connection else {
            return WorkspaceSidebarSessionStatus(sessions: [])
        }

        return WorkspaceSidebarSessionStatus(
            sessions: connection.sessionStore.listProjectionSessions(workspaceId: workspaceId),
            pendingAskCountForSession: { sessionId in
                SessionListAttentionMerger.askCount(
                    listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
                    hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
                    hasPendingExtensionDialog: connection.extensionDialogs.hasPending(for: sessionId)
                )
            }
        )
    }

    private func workspaceGitSummary(_ summary: WorkspaceGitSummary?) -> WorkspaceSidebarGitSummary? {
        guard let summary, summary.isGitRepo else { return nil }
        let sidebarSummary = WorkspaceSidebarGitSummary(
            changedCount: summary.changedCount,
            aheadCount: summary.ahead ?? 0,
            behindCount: summary.behind ?? 0
        )
        return sidebarSummary.isVisible ? sidebarSummary : nil
    }

    private func workspaceAccessibilityValue(
        status: WorkspaceSidebarSessionStatus,
        gitSummary: WorkspaceSidebarGitSummary?
    ) -> String {
        [status.accessibilityValue, gitSummary?.accessibilityValue]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
    }

    // MARK: Snapshots

    private func apply(previous: Model, themeChanged: Bool) {
        let animates = animatesNextSnapshot && view.window != nil
        animatesNextSnapshot = false
        for (source, items) in [(dataSource, model.mainItems), (footerDataSource, model.footerItems)] {
            guard let source else { continue }
            var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
            snapshot.appendSections([.main])
            snapshot.appendItems(items, toSection: .main)
            let existing = Set(source.snapshot().itemIdentifiers)
            let changed = items.filter {
                existing.contains($0) && (themeChanged || model.contentDiffers($0, from: previous))
            }
            snapshot.reconfigureItems(changed)
            source.apply(snapshot, animatingDifferences: animates)
        }
        footerDivider.isHidden = model.server == nil
    }

    // MARK: Cells

    private func makeDataSource(for collectionView: UICollectionView) -> UICollectionViewDiffableDataSource<Section, Item> {
        let registration = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            cell.element.onActivate = { [weak self] in self?.activate(item) }
            cell.element.onHighlightChange = { [weak cell] in cell?.setNeedsUpdateConfiguration() }
            cell.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 12))
            self?.configure(cell, item: item)
        }
        return UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
    }

    private var palette: ThemePalette {
        (appliedThemeID ?? root.themeStore.activeThemeID).palette
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        // Reuse: every cell sets all of these. The cell's one accessibility
        // element is a button, as the SwiftUI rows were.
        cell.accessories = []
        cell.accessibilityElements = [cell.element]
        cell.accessibilityIdentifier = nil
        cell.accessibilityLabel = nil
        cell.accessibilityCustomActions = nil
        cell.passthrough = nil
        cell.element.isHidden = false
        cell.element.accessibilityIdentifier = nil
        cell.element.accessibilityLabel = nil
        cell.element.accessibilityValue = nil
        cell.element.accessibilityHint = nil
        cell.element.accessibilityCustomActions = nil
        cell.element.isAccessibilityElement = true
        cell.element.accessibilityTraits = .button
        cell.automaticallyUpdatesContentConfiguration = false
        let palette = palette
        var paintsSelection = false
        var isSelected = false

        switch item {
        case .utility(let target):
            guard let row = model.utilities[target] else { return }
            paintsSelection = true
            isSelected = row.isSelected
            configureUtility(cell, row: row, palette: palette)
        case .pinsHeader:
            guard let header = model.pinsHeader, let section = pinsSection else { return }
            configurePinsHeader(cell, header: header, section: section, palette: palette)
        case .pin(let id):
            guard let row = model.pins[id], let section = pinsSection else { return }
            configurePin(cell, row: row, section: section, palette: palette)
        case .disclosure:
            configureDisclosure(cell, palette: palette)
        case .workspace(let id):
            guard let row = model.workspaces[id] else { return }
            let workspace = row.target.workspace
            cell.contentConfiguration = WorkspaceSidebarRowConfiguration(
                workspace: workspace,
                status: row.status,
                gitSummary: row.gitSummary,
                isSelected: row.isSelected,
                lockBadge: row.lockBadge,
                themeID: appliedThemeID ?? root.themeStore.activeThemeID,
                iconAssetCache: root.windowConnectionOrStandIn.iconAssetCache
            )
            cell.element.accessibilityIdentifier = WorkspaceHomeView.workspaceOpenAccessibilityIdentifier(
                workspaceName: workspace.name
            )
            cell.element.accessibilityLabel = "Open \(workspace.name)"
            cell.element.accessibilityValue = workspaceAccessibilityValue(status: row.status, gitSummary: row.gitSummary)
            if row.isSelected { cell.element.accessibilityTraits.insert(.selected) }
        case .loading:
            configureNotice(
                cell, text: "Loading workspaces…", symbol: "arrow.triangle.2.circlepath",
                color: palette.ui.comment, margins: 12
            )
        case .unavailable:
            configureUnavailable(cell, palette: palette)
        case .empty:
            configureNotice(cell, text: "No workspaces", symbol: nil, color: palette.ui.comment, margins: 12)
        case .stale:
            configureNotice(
                cell, text: "Saved workspaces may be out of date",
                symbol: "exclamationmark.arrow.triangle.2.circlepath",
                color: palette.ui.orange, margins: 8
            )
        case .noServer:
            configureNotice(cell, text: "No server selected", symbol: nil, color: palette.ui.comment, margins: 12)
        case .newWorkspace:
            configureNewWorkspace(cell, palette: palette)
        }
        applyBackground(to: cell, paintsSelection: paintsSelection, isSelected: isSelected, palette: palette)
        // After the content configuration: a list cell makes itself the
        // element once it has content. The unavailable notice stays a
        // container so its label and Retry button are separate elements.
        cell.isAccessibilityElement = cell.element.isHidden && item != .unavailable
    }

    private func configureUtility(_ cell: SidebarListCell, row: UtilityRow, palette: ThemePalette) {
        let item = row.item
        let tint = row.isSelected ? palette.blue : palette.fg
        var content = UIListContentConfiguration.cell()
        content.image = UIImage(systemName: item.systemImage)
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        content.imageProperties.tintColor = tint
        content.imageProperties.reservedLayoutSize = CGSize(width: 32, height: 32)
        content.imageToTextPadding = 10
        content.text = item.title
        content.textProperties.font = Self.font(.body, .semibold)
        content.textProperties.color = tint
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        cell.contentConfiguration = content
        cell.element.accessibilityIdentifier = item.accessibilityIdentifier
        cell.element.accessibilityLabel = item.accessibilityLabel
        cell.element.accessibilityHint = item.accessibilityHint ?? "Opens \(item.title.lowercased()) management"
        if row.isSelected { cell.element.accessibilityTraits.insert(.selected) }
    }

    private func configureDisclosure(_ cell: SidebarListCell, palette: ThemePalette) {
        let expanded = model.workspacesExpanded
        let comment = palette.ui.comment
        var content = UIListContentConfiguration.cell()
        content.text = "Workspaces"
        content.textProperties.font = Self.font(.caption1, .semibold)
        content.textProperties.color = comment
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 6, trailing: 8)
        cell.contentConfiguration = content
        let chevron = UIImageView(image: UIImage(systemName: expanded ? "chevron.down" : "chevron.right"))
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Self.font(.caption1, .semibold))
        chevron.tintColor = comment
        cell.accessories = [.customView(configuration: .init(customView: chevron, placement: .trailing()))]
        cell.element.accessibilityIdentifier = "workspace.sidebar.disclosure"
        cell.element.accessibilityLabel = "Workspaces"
        cell.element.accessibilityValue = expanded ? "Expanded" : "Collapsed"
        cell.element.accessibilityHint = expanded ? "Hides workspace rows" : "Shows workspace rows"
    }

    /// "Pinned" as the Workspaces disclosure draws its title, with Edit
    /// (Done while editing) before the chevron. The Edit button takes its own
    /// taps over the row's toggle.
    private func configurePinsHeader(
        _ cell: SidebarListCell,
        header: PinsSection.Header,
        section: PinsSection,
        palette: ThemePalette
    ) {
        let comment = palette.ui.comment
        var content = UIListContentConfiguration.cell()
        content.text = String(localized: "Pinned")
        content.textProperties.font = Self.font(.caption1, .semibold)
        content.textProperties.color = comment
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 6, trailing: 8)
        cell.contentConfiguration = content
        let chevron = UIImageView(image: UIImage(systemName: header.isCollapsed ? "chevron.right" : "chevron.down"))
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Self.font(.caption1, .semibold))
        chevron.tintColor = comment
        var accessories: [UICellAccessory] = [
            .customView(configuration: .init(customView: chevron, placement: .trailing(), isHidden: header.isEditing)),
        ]
        if let edit = section.editAccessory(header, palette: palette) {
            accessories.insert(edit, at: 0)
            cell.passthrough = section.editElement
        }
        cell.accessories = accessories
        cell.element.accessibilityIdentifier = "workspace.sidebar.pinned.header"
        cell.element.accessibilityLabel = String(localized: "Pinned")
        cell.element.accessibilityValue = header.isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded")
        cell.element.accessibilityHint = header.isCollapsed
            ? String(localized: "Shows pinned folders and files")
            : String(localized: "Hides pinned folders and files")
        if !header.isCollapsed { cell.accessibilityElements = [cell.element, section.editElement] }
    }

    /// A pin: its folder or file icon, its name, and where it lives (or why
    /// it can't open), dimmed when it is gone. Unlike the other rows it has no
    /// clear button over it: it is the list's own cell, as the File Browser's
    /// pin rows are, so the list selects, highlights, opens its menu, drags
    /// it, and moves it in Edit mode. The cell is its accessibility element
    /// (`PinsSection.decorate`).
    private func configurePin(_ cell: SidebarListCell, row: PinsSection.Row, section: PinsSection, palette: ThemePalette) {
        let tint = row.isGone || !row.isDirectory ? palette.ui.comment : palette.ui.blue
        var content = UIListContentConfiguration.subtitleCell()
        content.image = UIImage(systemName: row.icon?.symbolName ?? "folder.fill")
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        content.imageProperties.tintColor = tint
        content.imageProperties.reservedLayoutSize = CGSize(width: 32, height: 32)
        content.imageToTextPadding = 10
        content.text = row.title
        content.textProperties.font = Self.font(.body, .regular)
        content.textProperties.color = row.isGone ? palette.ui.comment : palette.ui.fg
        content.textProperties.numberOfLines = 1
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.secondaryText = row.detail
        content.secondaryTextProperties.font = Self.font(.caption1, .regular)
        content.secondaryTextProperties.color = palette.ui.comment
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingHead
        content.textToSecondaryTextVerticalPadding = 2
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        cell.contentConfiguration = content
        cell.element.isHidden = true
        cell.accessibilityElements = nil
        section.decorate(cell, row: row, palette: palette)
    }

    private func configureNotice(
        _ cell: SidebarListCell,
        text: String,
        symbol: String?,
        color: UIColor,
        margins: CGFloat
    ) {
        var content = UIListContentConfiguration.cell()
        content.text = text
        content.textProperties.font = Self.font(.subheadline, .regular)
        content.textProperties.color = color
        content.textProperties.numberOfLines = 0
        if let symbol {
            content.image = UIImage(systemName: symbol)
            content.imageProperties.tintColor = color
            content.imageToTextPadding = 8
        }
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: margins, leading: 8, bottom: margins, trailing: 8)
        cell.contentConfiguration = content
        // Not actionable: the cell speaks for itself.
        cell.element.isHidden = true
        cell.accessibilityElements = nil
    }

    /// The warning with a Retry button. The cell is not an accessibility
    /// element itself, so its label and the button stay separate.
    private func configureUnavailable(_ cell: SidebarListCell, palette: ThemePalette) {
        configureNotice(
            cell, text: "Workspaces unavailable", symbol: "exclamationmark.triangle.fill",
            color: palette.ui.orange, margins: 12
        )
        var configuration = UIButton.Configuration.tinted()
        configuration.title = "Retry"
        configuration.baseForegroundColor = palette.ui.blue
        configuration.baseBackgroundColor = palette.ui.blue
        let retry = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.retryServer()
        })
        cell.accessories = [.customView(configuration: .init(customView: retry, placement: .trailing()))]
    }

    private func configureNewWorkspace(_ cell: SidebarListCell, palette: ThemePalette) {
        let tint = palette.ui.fg
        var content = UIListContentConfiguration.cell()
        content.image = UIImage(systemName: "folder.badge.plus")
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Self.font(.body, .semibold))
        content.imageProperties.tintColor = tint
        content.imageProperties.reservedLayoutSize = CGSize(width: 32, height: 32)
        content.imageToTextPadding = 10
        content.text = "New Workspace"
        content.textProperties.font = Self.font(.body, .semibold)
        content.textProperties.color = tint
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        cell.contentConfiguration = content
        cell.element.accessibilityIdentifier = "workspace.create.sidebar.open"
        cell.element.accessibilityLabel = "Create New Workspace"
    }

    /// Selected destinations paint the theme's wash; every row dims while
    /// touched. The workspace row paints its own selection.
    private func applyBackground(
        to cell: SidebarListCell,
        paintsSelection: Bool,
        isSelected: Bool,
        palette: ThemePalette
    ) {
        let wash = palette.ui.fg
        cell.configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.clear()
            if paintsSelection && isSelected {
                background.backgroundColor = wash.withAlphaComponent(0.08)
            } else if (cell as? SidebarListCell)?.element.isHighlighted == true || state.isHighlighted {
                background.backgroundColor = wash.withAlphaComponent(0.05)
            }
            background.cornerRadius = 12
            // Rows sit 2pt apart.
            background.backgroundInsets = NSDirectionalEdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0)
            cell.backgroundConfiguration = background
        }
    }

    // MARK: Actions

    /// A tap and accessibility activation run the same action.
    private func activate(_ item: Item) {
        switch item {
        case .utility(let target):
            navigation.openWorkspaceUtility(target)
            onSelect?()
        case .workspace(let id):
            guard let row = model.workspaces[id] else { return }
            navigation.openWorkspace(row.target)
            onSelect?()
        case .pinsHeader:
            pinsSection?.toggleCollapsed()
        case .pin(let id):
            // The section's open closes the drawer; a missing pin's alert keeps it.
            pinsSection?.select(id)
        case .disclosure:
            animatesNextSnapshot = true
            UserDefaults.standard.set(!model.workspacesExpanded, forKey: AppIdentifiers.workspaceSidebarExpandedKey)
            setNeedsUpdateProperties()
        case .newWorkspace:
            presentCreateWorkspace()
        case .loading, .unavailable, .empty, .stale, .noServer:
            break
        }
    }

    private func retryServer() {
        guard let serverId = model.server?.id else { return }
        let coordinator = coordinator
        Task {
            if coordinator.connection(for: serverId)?.apiClient == nil {
                await coordinator.retryServerConnection(serverId)
            } else {
                await coordinator.refreshServer(serverId, force: true)
            }
        }
    }

    private func presentCreateWorkspace() {
        guard !isPresentingCreate, let server = model.server else { return }
        isPresentingCreate = true
        WorkspaceCreateSheetContext(
            server: server,
            presentation: .standard,
            openWorkspaceAfterCreate: false,
            prefillName: nil,
            prefillPath: nil
        )
        .present(root: root, from: self) { [weak self] in
            self?.isPresentingCreate = false
        }
    }

    // MARK: Layout

    private static func listLayout(topInset: CGFloat = 0, bottomInset: CGFloat) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.backgroundColor = .clear
            configuration.showsSeparators = false
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            section.contentInsets = NSDirectionalEdgeInsets(top: topInset, leading: 16, bottom: bottomInset, trailing: 16)
            return section
        }
    }

    private static func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style)
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

// MARK: - Pins: menus, drags, and Edit-mode moves

extension WorkspaceSidebarViewController: UICollectionViewDelegate, UICollectionViewDragDelegate {
    /// Pin rows are the only rows the list selects; the others have their own button.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        pinId(at: indexPath, in: collectionView) != nil
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        pinId(at: indexPath, in: collectionView) != nil
    }

    /// A tap opens the pin; the row never stays selected, since what the
    /// window shows is `SceneNavigation`'s to paint.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = pinId(at: indexPath, in: collectionView) else { return }
        activate(.pin(id))
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let id = pinId(at: indexPaths[0], in: collectionView) else { return nil }
        return pinsSection?.contextMenu(pinId: id)
    }

    /// A pin drags out as the pane entry it opens as; a pane takes the drop.
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let id = pinId(at: indexPath, in: collectionView) else { return [] }
        return pinsSection?.dragItems(pinId: id) ?? []
    }

    /// A pin moves only among the pins.
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
        atCurrentIndexPath currentIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        let items = (collectionView.dataSource as? UICollectionViewDiffableDataSource<Section, Item>)?
            .snapshot().itemIdentifiers ?? []
        guard let first = items.firstIndex(where: { $0.pinId != nil }),
              let last = items.lastIndex(where: { $0.pinId != nil }) else { return originalIndexPath }
        return IndexPath(item: min(max(proposedIndexPath.item, first), last), section: proposedIndexPath.section)
    }

    private func pinId(at indexPath: IndexPath, in collectionView: UICollectionView) -> String? {
        guard collectionView === list else { return nil }
        return dataSource?.itemIdentifier(for: indexPath)?.pinId
    }
}

/// A list that reports when its rows change height, for the pinned footer.
/// A list with no height lays out no rows, so the footer starts with an
/// estimate and follows the content from there.
private final class FooterListView: UICollectionView {
    var onContentHeightChange: ((CGFloat) -> Void)?

    override var contentSize: CGSize {
        didSet {
            if oldValue.height != contentSize.height { onContentHeightChange?(contentSize.height) }
        }
    }
}

/// A sidebar row's tap target and its one accessibility element: a button,
/// since XCUITest types a collection view cell as a Cell whatever its traits.
/// A tap and accessibility activation both run `onActivate`.
final class SidebarRowElement: UIButton {
    var onActivate: (() -> Void)?
    var onHighlightChange: (() -> Void)?

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { onHighlightChange?() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addAction(UIAction { [weak self] _ in self?.onActivate?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

final class SidebarListCell: UICollectionViewListCell {
    let element = SidebarRowElement()
    /// A control in the row that takes its own taps over `element` (the
    /// Pinned header's Edit).
    weak var passthrough: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        element.translatesAutoresizingMaskIntoConstraints = false
        // Above the content view, so it takes the taps.
        addSubview(element)
        NSLayoutConstraint.activate([
            element.topAnchor.constraint(equalTo: topAnchor),
            element.bottomAnchor.constraint(equalTo: bottomAnchor),
            element.leadingAnchor.constraint(equalTo: leadingAnchor),
            element.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The list configures its own subviews on top of earlier ones.
        bringSubviewToFront(element)
    }

    /// The content never takes the tap.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let passthrough, passthrough.window != nil, passthrough.isDescendant(of: self),
           let hit = passthrough.hitTest(convert(point, to: passthrough), with: event) {
            return hit
        }
        let hit = super.hitTest(point, with: event)
        return hit != nil && !element.isHidden ? element : hit
    }
}
