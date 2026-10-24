import UIKit

/// One Pi extension on one server (route `.serverResourceDetail`, kind
/// `.extension`): its server default switch, where it comes from, its status
/// with Retry, and the tools and commands it contributes. An extension with a
/// user-editable host file also offers Edit with Oppi, which opens the shared
/// guided composer on this screen's server and then the session it starts.
///
/// The route makes the extension's server the active one on every appearance
/// ("Loading extension…" until it is ready). The catalog row shows at once; the
/// detail request adds the contributions, and a newer detail summary wins over a
/// stale catalog row until a mutation settles (`resolvedServerExtensionDetailSummary`).
@MainActor
final class ServerExtensionDetailViewController: UIViewController, UICollectionViewDelegate {
    let target: ServerResourceDetailNavTarget

    private enum Section: Hashable {
        case summary, serverDefault, actions, source, status, loading, tools, commands
    }

    private enum Item: Hashable {
        case title
        case enabled
        case mutationError
        case editWithOppi
        case detail(String)
        case status
        case loadError
        case warning(String)
        case retry
        case loadingContributions
        case tool(String)
        case command(String)
    }

    private enum Shown: Equatable {
        case loading
        case unavailable(String)
        case list
    }

    /// Everything the rows read, taken in `updateProperties()` so observation
    /// tracks it and a reconfigured row sees one consistent copy.
    private struct ViewState {
        var summary: ServerExtensionSummary
        var detail: ServerExtensionDetail?
        var loadError: String?
        var isLoading: Bool
        var isPending: Bool
        var mutationError: String?
        var mutationsAllowed: Bool
        var serverName: String
        var editPath: String?
    }

    private let root: AppRootEnvironment
    /// The route makes the extension's server the active one on every appearance.
    private let switchesServer: Bool
    private let loader: ServerResourceDetailLoader<ServerExtensionDetail>
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private let guidedSheet = RouterModalPresenter()

    /// The extension's server once it is ready.
    private var connection: ServerConnection? {
        didSet { setNeedsUpdateProperties() }
    }
    private var mutationVerb: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var showsEditSheet = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var state: ViewState?
    private var changedRows = ChangedRows<Item>()
    private var shown: Shown?
    private var connectTask: Task<Void, Never>?

    /// `connection`: the extension's server when the caller already has it
    /// ready; nil makes it the active server first.
    init(target: ServerResourceDetailNavTarget, root: AppRootEnvironment, connection: ServerConnection? = nil) {
        self.target = target
        self.root = root
        self.connection = connection
        switchesServer = connection == nil
        loader = ServerResourceDetailLoader(target: target)
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        connectTask?.cancel()
    }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    private var serverName: String {
        root.coordinator.serverStore.server(for: target.serverId)?.name ?? "this server"
    }

    private var mutationKey: ServerResourceMutationKey {
        .normalExtension(target.resourceId)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true, footers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "server.extension.list"
        ControlScreenList.pinFullWidth(collectionView, in: view)
        installDataSource()
        guidedSheet.anchor = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // The server switch and the detail load run on every appearance, as
        // the hosted screen's tasks did.
        if switchesServer {
            connect()
        } else {
            startLoad()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guidedSheet.sync()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        connectTask?.cancel()
        connectTask = nil
        loader.cancel()
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        let store = connection?.serverResourceStore
        let summary = resolvedServerExtensionDetailSummary(
            catalogSummary: store?.extensions(forServer: target.serverId).first { $0.id == target.resourceId },
            freshDetail: loader.usesDetailSummary ? loader.detail : nil
        )
        let loadError = loader.error
        let isLoading = loader.isLoading
        title = summary?.name ?? "Extension"

        guard let summary, let store else {
            state = nil
            // Unavailable only after a load failed: a load that never finished
            // (cancelled as the screen left) is still loading when it returns.
            show(connection == nil || isLoading || loadError == nil
                ? .loading
                : .unavailable(loadError ?? ""))
            updateModals()
            return
        }
        state = ViewState(
            summary: summary,
            detail: loader.detail,
            loadError: loadError,
            isLoading: isLoading,
            isPending: store.isMutationPending(mutationKey, serverId: target.serverId),
            mutationError: store.mutationError(for: mutationKey, serverId: target.serverId),
            mutationsAllowed: store.mutationsAllowed(for: .extensions, serverId: target.serverId),
            serverName: serverName,
            editPath: ServerExtensionListPresentation.editablePath(for: summary)
        )
        show(.list)
        applySnapshot()
        updateModals()
    }

    // MARK: - Content

    private func show(_ next: Shown) {
        shown = next
        collectionView.isHidden = next != .list
        // Rebuilt on every pass, so a theme change recolors these states.
        switch next {
        case .list:
            contentUnavailableConfiguration = nil
        case .loading:
            var loading = ControlScreenList.loading("Loading extension…")
            loading.background.backgroundColor = root.themeStore.backgroundColor
            contentUnavailableConfiguration = loading
        case .unavailable(let reason):
            var unavailable = ControlScreenList.unavailable(
                "Extension Unavailable",
                systemImage: "exclamationmark.triangle.fill",
                description: reason,
                palette: palette
            )
            var retry = UIButton.Configuration.borderedProminent()
            retry.title = "Retry"
            unavailable.button = retry
            unavailable.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.startLoad() }
            unavailable.background.backgroundColor = root.themeStore.backgroundColor
            contentUnavailableConfiguration = unavailable
        }
    }

    // MARK: - List

    private func applySnapshot() {
        guard let dataSource, let state else { return }
        let summary = state.summary
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.summary, .serverDefault])
        snapshot.appendItems([.title], toSection: .summary)
        snapshot.appendItems(
            state.mutationError == nil ? [.enabled] : [.enabled, .mutationError],
            toSection: .serverDefault
        )
        if state.editPath != nil {
            snapshot.appendSections([.actions])
            snapshot.appendItems([.editWithOppi], toSection: .actions)
        }

        snapshot.appendSections([.source])
        var details = [Item]()
        if summary.packageName != nil { details.append(.detail("Package")) }
        details += [.detail("Provenance"), .detail("Kind"), .detail("Scope")]
        snapshot.appendItems(details, toSection: .source)

        snapshot.appendSections([.status])
        var statusItems: [Item] = [.status]
        if summary.loadError ?? state.loadError != nil { statusItems.append(.loadError) }
        // A diffable list traps on a repeated item; a repeated warning shows once.
        statusItems += Self.unique(summary.warnings).map(Item.warning)
        if summary.state == .error || state.loadError != nil { statusItems.append(.retry) }
        snapshot.appendItems(statusItems, toSection: .status)

        if state.isLoading && state.detail == nil {
            snapshot.appendSections([.loading])
            snapshot.appendItems([.loadingContributions], toSection: .loading)
        }
        if let tools = state.detail?.contributedTools, !tools.isEmpty {
            snapshot.appendSections([.tools])
            snapshot.appendItems(Self.unique(tools).map(Item.tool), toSection: .tools)
        }
        if let commands = state.detail?.contributedCommands, !commands.isEmpty {
            snapshot.appendSections([.commands])
            snapshot.appendItems(Self.unique(commands).map(Item.command), toSection: .commands)
        }
        // Only the rows whose inputs changed: a replaced Enabled switch would
        // drop a drag in progress, and a replaced text view its selection.
        let current = dataSource.snapshot()
        let themeID = root.themeStore.activeThemeID
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { rowInputs($0, state: state, themeID: themeID) }
        snapshot.reconfigureItems(changed.filter { current.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// What a row draws from, besides its own identity.
    private func rowInputs(_ item: Item, state: ViewState, themeID: ThemeID) -> AnyHashable {
        let summary = state.summary
        let inputs: [AnyHashable]
        switch item {
        case .title:
            inputs = [summary.name, summary.description]
        case .enabled:
            inputs = [summary.name, summary.state, state.isPending, state.mutationsAllowed, state.serverName]
        case .mutationError:
            inputs = [summary.name, state.serverName, state.mutationError, mutationVerb]
        case .detail:
            inputs = [summary.packageName, summary.provenance.label, summary.kind]
        case .status:
            inputs = [summary.state]
        case .loadError:
            inputs = [summary.loadError ?? state.loadError]
        case .editWithOppi, .warning, .retry, .loadingContributions, .tool, .command:
            inputs = []
        }
        return [AnyHashable(themeID), AnyHashable(inputs)]
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = switch self?.dataSource?.sectionIdentifier(for: indexPath.section) {
            case .serverDefault: "Server Default"
            case .source: "Source"
            case .status: "Status"
            case .tools: "Contributed Tools"
            case .commands: "Contributed Commands"
            default: nil
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource?.sectionIdentifier(for: indexPath.section) == .serverDefault
                ? "New sessions use this setting. Reload an active session to apply it now."
                : nil
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        guard let state else { return }
        let summary = state.summary
        switch item {
        case .title:
            ControlScreenList.staticRow(cell, identifier: "server.extension.title")
            let description = summary.description.flatMap { $0.isEmpty ? nil : $0 }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 12, leading: 0, bottom: 12, trailing: 0)) {
                var views = [ControlRowViews.label(
                    summary.name, style: .title2, weight: .bold, color: UIColor(palette.fg)
                )]
                if let description {
                    views.append(ControlRowViews.label(description, style: .body, color: UIColor(palette.comment)))
                }
                return ControlRowViews.stack(views, spacing: 6)
            }
        case .enabled:
            ControlScreenList.staticRow(cell)
            var content = UIListContentConfiguration.cell()
            content.text = "Enabled"
            content.textProperties.color = UIColor(palette.fg)
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = summary.state == .on
            toggle.isEnabled = !state.isPending
                && state.mutationsAllowed
                && summary.state != .error
                && summary.state != .unknown
            toggle.accessibilityIdentifier = "server.extension.enabled"
            toggle.accessibilityLabel = "Enable \(summary.name) on \(state.serverName)"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                self?.setEnabled(toggle?.isOn ?? false)
            }, for: .valueChanged)
            var accessories: [UICellAccessory] = []
            if state.isPending {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                spinner.accessibilityLabel = "Saving"
                spinner.accessibilityIdentifier = "server.extension.saving"
                accessories.append(.customView(configuration: .init(customView: spinner, placement: .trailing())))
            }
            accessories.append(.customView(configuration: .init(customView: toggle, placement: .trailing())))
            cell.accessories = accessories
        case .mutationError:
            ControlScreenList.staticRow(cell, identifier: "server.extension.mutationError")
            let message = "Couldn’t \(mutationVerb ?? "update") \(summary.name) on \(state.serverName). \(state.mutationError ?? "")"
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.symbolLabel(
                    message,
                    systemImage: "exclamationmark.triangle.fill",
                    style: .footnote,
                    color: UIColor(palette.orange)
                )
            }
        case .editWithOppi:
            let hint = "Starts a new session that changes this extension."
            ControlScreenList.buttonRow(
                cell,
                identifier: "server.extension.editWithOppi",
                label: "Edit with Oppi",
                hint: hint
            ) { [weak self] in
                self?.showsEditSheet = true
            }
            var content = UIListContentConfiguration.cell()
            content.image = UIImage(systemName: "text.bubble")
            content.text = "Edit with Oppi"
            content.secondaryText = hint
            content.textProperties.color = UIColor(palette.blue)
            content.imageProperties.tintColor = UIColor(palette.blue)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
        case .detail(let title):
            ControlScreenList.staticRow(cell, identifier: "server.extension.source.\(title.lowercased())")
            let value = switch title {
            case "Package": summary.packageName ?? ""
            case "Provenance": summary.provenance.label
            case "Kind": ServerExtensionListPresentation.kindLabel(for: summary.kind)
            default: "Server default"
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.valueRow(title, value, palette: palette, style: .body)
            }
        case .status:
            ControlScreenList.staticRow(cell, identifier: "server.extension.status")
            let isIssue = summary.state == .error || summary.state == .unknown
            let icon = isIssue ? "exclamationmark.triangle.fill" : (summary.state == .on ? "checkmark.circle" : "minus.circle")
            let label = ServerExtensionListPresentation.stateLabel(for: summary.state)
            cell.contentConfiguration = ControlViewContent {
                let row = ControlRowViews.symbolLabel(label, systemImage: icon, style: .body, color: UIColor(palette.fg))
                row.accessibilityLabel = label
                return row
            }
        case .loadError:
            ControlScreenList.staticRow(cell, identifier: "server.extension.loadError")
            let error = summary.loadError ?? state.loadError ?? ""
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(error, style: .footnote, color: UIColor(palette.orange))
            }
        case .warning(let warning):
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.symbolLabel(
                    warning,
                    systemImage: "exclamationmark.circle",
                    style: .footnote,
                    color: UIColor(palette.fg)
                )
            }
        case .retry:
            ControlScreenList.buttonRow(cell, identifier: "server.extension.retry", label: "Retry") { [weak self] in
                self?.startLoad()
            }
            var content = UIListContentConfiguration.cell()
            content.text = "Retry"
            content.textProperties.color = UIColor(palette.blue)
            cell.contentConfiguration = content
        case .loadingContributions:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.loading("Loading contributions…")
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .tool(let name), .command(let name):
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.selectableText(name, style: .body, color: UIColor(palette.fg))
            }
        }
    }

    // MARK: - Modals

    private func updateModals() {
        let editPath = state?.editPath
        let name = state?.summary.name
        var scoped: (@MainActor () -> ServerConnection)?
        if let connection { scoped = { connection } }
        guidedSheet.update(
            id: showsEditSheet && editPath != nil && connection != nil ? "edit" : nil,
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.showsEditSheet = false },
            screen: { [root] in
                .controller {
                    // The same composer the chat's Context panel opens, on this server.
                    GuidedControlSessionViewController(
                        configuration: GuidedControlComposerConfiguration(
                            domain: .extensions,
                            intent: .revise,
                            targetId: editPath,
                            targetName: name,
                            targetPath: editPath,
                            allowsEmptyRequest: true,
                            placeholder: "Describe how this extension should change…"
                        ),
                        root: root,
                        connection: scoped
                    )
                }
            }
        )
    }

    // MARK: - Data

    private func connect() {
        connectTask?.cancel()
        let coordinator = root.coordinator
        let serverId = target.serverId
        connectTask = Task { [weak self] in
            guard await coordinator.switchToServerReady(serverId), !Task.isCancelled, let self else { return }
            connection = coordinator.connection(for: serverId)
            startLoad()
        }
    }

    private func startLoad() {
        guard let connection else { return }
        let apiClient = connection.apiClient
        let serverName = serverName
        let resourceId = target.resourceId
        loader.load(target: target) {
            guard let apiClient else {
                throw ServerResourceDetailLoadError.notConnected(serverName)
            }
            return try await apiClient.getServerExtension(id: resourceId)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard let connection, let api = connection.apiClient else { return }
        mutationVerb = enabled ? "enable" : "disable"
        let store = connection.serverResourceStore
        let target = target
        Task { [weak self] in
            await store.setExtensionEnabled(
                id: target.resourceId,
                enabled: enabled,
                serverId: target.serverId,
                api: api
            )
            guard let self, store.mutationError(for: mutationKey, serverId: target.serverId) == nil else { return }
            loader.invalidateSummaryAfterAuthoritativeMutation()
            startLoad()
        }
    }
}

/// A successful detail response is newer than the catalog row that opened it.
/// This lets Retry clear stale row errors without changing catalog ownership.
func resolvedServerExtensionDetailSummary(
    catalogSummary: ServerExtensionSummary?,
    freshDetail: ServerExtensionDetail?
) -> ServerExtensionSummary? {
    freshDetail?.summary ?? catalogSummary
}
