import UIKit

/// One Skill on one server (route `.serverResourceDetail`, kind `.skill`): its
/// server default switch, where it comes from, its validation with Retry, and
/// the file list the browser opens.
///
/// The route makes the Skill's server the active one on every appearance
/// ("Connecting…" until it is ready). The catalog row shows at once; the
/// detail request adds the file list, and a newer detail summary wins over a
/// stale catalog row until a mutation settles (`resolvedServerSkillDetailSummary`).
@MainActor
final class ServerSkillDetailViewController: UIViewController, UICollectionViewDelegate {
    let target: ServerResourceDetailNavTarget

    private enum Section: Hashable {
        case summary, serverDefault, source, validation, loading, contents
    }

    private enum Item: Hashable {
        case title
        case enabled
        case mutationError
        case detail(String)
        case status
        case loadError
        case warning(String)
        case retry
        case loadingContents
        case browse
    }

    private enum Shown: Equatable {
        case connecting
        case loading
        case unavailable(String)
        case list
    }

    /// Everything the rows read, taken in `updateProperties()` so observation
    /// tracks it and a reconfigured row sees one consistent copy.
    private struct ViewState {
        var summary: ServerSkillSummary
        var detail: ServerSkillDetail?
        var loadError: String?
        var isLoading: Bool
        var isPending: Bool
        var mutationError: String?
        var mutationsAllowed: Bool
        var serverName: String
    }

    private let root: AppRootEnvironment
    /// The route makes the Skill's server the active one on every appearance.
    private let switchesServer: Bool
    private let loader: ServerResourceDetailLoader<ServerSkillDetail>
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?

    /// The Skill's server once it is ready.
    private var connection: ServerConnection? {
        didSet { setNeedsUpdateProperties() }
    }
    private var mutationVerb: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var state: ViewState?
    private var changedRows = ChangedRows<Item>()
    private var connectTask: Task<Void, Never>?

    /// `connection`: the Skill's server when the caller already has it ready;
    /// nil makes it the active server first.
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
        .skill(target.resourceId)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true, footers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "skills.detail.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
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
        let summary = resolvedServerSkillDetailSummary(
            catalogSummary: store?.skills(forServer: target.serverId).first { $0.id == target.resourceId },
            freshDetail: loader.usesDetailSummary ? loader.detail : nil
        )
        let loadError = loader.error
        let isLoading = loader.isLoading
        title = summary?.name ?? String(localized: "Skill")

        guard let summary, let store else {
            state = nil
            if connection == nil {
                show(.connecting)
            } else if !isLoading, let loadError {
                show(.unavailable(loadError))
            } else {
                // A load that never finished (cancelled as the screen left) is
                // still loading when it returns.
                show(.loading)
            }
            return
        }
        state = ViewState(
            summary: summary,
            detail: loader.detail,
            loadError: loadError,
            isLoading: isLoading,
            isPending: store.isMutationPending(mutationKey, serverId: target.serverId),
            mutationError: store.mutationError(for: mutationKey, serverId: target.serverId),
            mutationsAllowed: store.mutationsAllowed(for: .skills, serverId: target.serverId),
            serverName: serverName
        )
        show(.list)
        applySnapshot()
    }

    // MARK: - Content

    private func show(_ next: Shown) {
        collectionView.isHidden = next != .list
        // Rebuilt on every pass, so a theme change recolors these states.
        switch next {
        case .list:
            contentUnavailableConfiguration = nil
        case .connecting:
            contentUnavailableConfiguration = backed(ControlScreenList.loading(String(localized: "Connecting…")))
        case .loading:
            contentUnavailableConfiguration = backed(ControlScreenList.loading(String(localized: "Loading skill…")))
        case .unavailable(let reason):
            var unavailable = ControlScreenList.unavailable(
                "Skill Unavailable",
                systemImage: "exclamationmark.triangle.fill",
                description: reason,
                palette: palette
            )
            var retry = UIButton.Configuration.borderedProminent()
            retry.title = String(localized: "Retry")
            unavailable.button = retry
            unavailable.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.startLoad() }
            contentUnavailableConfiguration = backed(unavailable)
        }
    }

    private func backed(_ configuration: UIContentUnavailableConfiguration) -> UIContentUnavailableConfiguration {
        var configuration = configuration
        configuration.background.backgroundColor = root.themeStore.backgroundColor
        return configuration
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

        snapshot.appendSections([.source])
        var details = [Item]()
        if summary.packageName != nil { details.append(.detail("Package")) }
        details += [.detail("Provenance"), .detail("Scope"), .detail("Files")]
        snapshot.appendItems(details, toSection: .source)

        snapshot.appendSections([.validation])
        let hasError = summary.state == .error || summary.state == .unknown
        var validation: [Item] = [.status]
        if summary.loadError ?? state.loadError != nil { validation.append(.loadError) }
        // A diffable list traps on a repeated item; a repeated warning shows once.
        validation += Self.unique(summary.warnings).map(Item.warning)
        if hasError || state.loadError != nil { validation.append(.retry) }
        snapshot.appendItems(validation, toSection: .validation)

        if state.isLoading && state.detail == nil {
            snapshot.appendSections([.loading])
            snapshot.appendItems([.loadingContents], toSection: .loading)
        }
        if state.detail != nil {
            snapshot.appendSections([.contents])
            snapshot.appendItems([.browse], toSection: .contents)
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
            // A refused change sets only the mutation error; redraw so the switch snaps back.
            inputs = [summary.name, summary.state, state.isPending, state.mutationsAllowed, state.serverName, state.mutationError]
        case .mutationError:
            inputs = [summary.name, state.serverName, state.mutationError, mutationVerb]
        case .detail:
            inputs = [summary.packageName, summary.provenance.label, summary.editable]
        case .status:
            inputs = [summary.state]
        case .loadError:
            inputs = [summary.loadError ?? state.loadError]
        case .browse:
            inputs = [summary.name, state.detail?.files.count]
        case .warning, .retry, .loadingContents:
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
            case .validation: "Validation"
            case .contents: "Contents"
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

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        guard let state else { return }
        let summary = state.summary
        switch item {
        case .title:
            ControlScreenList.staticRow(cell, identifier: "skills.detail.title")
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 12, leading: 0, bottom: 12, trailing: 0)) {
                var views = [ControlRowViews.label(
                    summary.name, style: .title2, weight: .bold, color: UIColor(palette.fg)
                )]
                if !summary.description.isEmpty {
                    views.append(ControlRowViews.label(summary.description, style: .body, color: UIColor(palette.comment)))
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
            toggle.isOn = summary.state == .enabled
            toggle.isEnabled = !state.isPending
                && state.mutationsAllowed
                && summary.state != .error
                && summary.state != .unknown
            toggle.accessibilityIdentifier = "skills.detail.enabled"
            toggle.accessibilityLabel = "Enable \(summary.name) on \(state.serverName)"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                // Offline: nothing will redraw the row, so put the switch back now.
                guard self.connection?.apiClient != nil else {
                    toggle.setOn(!toggle.isOn, animated: true)
                    return
                }
                self.setEnabled(toggle.isOn)
            }, for: .valueChanged)
            var accessories: [UICellAccessory] = []
            if state.isPending {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                spinner.accessibilityLabel = "Saving"
                spinner.accessibilityIdentifier = "skills.detail.saving"
                accessories.append(.customView(configuration: .init(customView: spinner, placement: .trailing())))
            }
            accessories.append(.customView(configuration: .init(customView: toggle, placement: .trailing())))
            cell.accessories = accessories
        case .mutationError:
            ControlScreenList.staticRow(cell, identifier: "skills.detail.mutationError")
            let message = "Couldn’t \(mutationVerb ?? "update") \(summary.name) on \(state.serverName). \(state.mutationError ?? "")"
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.symbolLabel(
                    message,
                    systemImage: "exclamationmark.triangle.fill",
                    style: .footnote,
                    color: UIColor(palette.orange)
                )
            }
        case .detail(let title):
            ControlScreenList.staticRow(cell, identifier: "skills.detail.source.\(title.lowercased())")
            let value = switch title {
            case "Package": summary.packageName ?? ""
            case "Provenance": summary.provenance.label
            case "Scope": "Server default"
            default: summary.editable ? "Editable" : "Read-only"
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.valueRow(title, value, palette: palette, style: .body)
            }
        case .status:
            ControlScreenList.staticRow(cell, identifier: "skills.detail.status")
            let hasError = summary.state == .error || summary.state == .unknown
            let label = hasError ? "Error" : "Loaded"
            cell.contentConfiguration = ControlViewContent {
                let row = ControlRowViews.symbolLabel(
                    label,
                    systemImage: hasError ? "exclamationmark.triangle.fill" : "checkmark.circle",
                    style: .body,
                    color: UIColor(palette.fg)
                )
                row.accessibilityLabel = label
                return row
            }
        case .loadError:
            ControlScreenList.staticRow(cell, identifier: "skills.detail.loadError")
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
            ControlScreenList.buttonRow(cell, identifier: "skills.detail.retry", label: "Retry") { [weak self] in
                self?.startLoad()
            }
            var content = UIListContentConfiguration.cell()
            content.text = "Retry"
            content.textProperties.color = UIColor(palette.blue)
            cell.contentConfiguration = content
        case .loadingContents:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.loading("Loading skill contents…")
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .browse:
            let count = state.detail?.files.count ?? 0
            let countLabel = count == 1 ? "1 file" : "\(count) files"
            ControlScreenList.buttonRow(
                cell,
                identifier: "skills.files.open",
                label: "Browse \(summary.name) files",
                value: countLabel
            ) { [weak self] in
                self?.openBrowser()
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                let icon = UIImageView(image: .scaledSymbol("folder", style: .body))
                icon.tintColor = UIColor(palette.blue)
                icon.setContentHuggingPriority(.required, for: .horizontal)
                let title = ControlRowViews.label("Browse Files", style: .body, color: UIColor(palette.fg))
                let value = ControlRowViews.label("\(count)", style: .body, color: UIColor(palette.comment), lines: 1)
                value.setContentHuggingPriority(.required, for: .horizontal)
                return ControlRowViews.stack(
                    [icon, title, ControlRowViews.spacer(), value],
                    axis: .horizontal,
                    spacing: 8,
                    alignment: .center
                )
            }
            cell.accessories = [.disclosureIndicator()]
        }
    }

    // MARK: - Data

    private func connect() {
        connectTask?.cancel()
        let coordinator = root.coordinator
        let serverId = target.serverId
        let isSkill = target.kind == .skill
        connectTask = Task { [weak self] in
            guard isSkill,
                  await coordinator.switchToServerReady(serverId), !Task.isCancelled, let self else { return }
            connection = coordinator.connection(for: serverId)
            startLoad()
        }
    }

    private func startLoad() {
        guard let connection else { return }
        let apiClient = connection.apiClient
        let serverName = serverName
        let store = connection.serverResourceStore
        let target = target
        loader.load(target: target) {
            guard let apiClient else {
                throw ServerResourceDetailLoadError.notConnected(serverName)
            }
            let detail = try await apiClient.getServerSkill(id: target.resourceId)
            store.rememberSkillDetail(detail, serverId: target.serverId)
            return detail
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard let connection, let api = connection.apiClient else { return }
        mutationVerb = enabled ? "enable" : "disable"
        let store = connection.serverResourceStore
        let target = target
        Task { [weak self] in
            await store.setSkillEnabled(
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

    private func openBrowser() {
        root.navigation.openServerSkillBrowser(ServerSkillBrowserNavTarget(
            serverId: target.serverId,
            resourceId: target.resourceId
        ))
    }
}

/// A successful detail response is newer than the catalog row that opened it.
/// This lets Retry clear stale row errors without changing catalog ownership.
func resolvedServerSkillDetailSummary(
    catalogSummary: ServerSkillSummary?,
    freshDetail: ServerSkillDetail?
) -> ServerSkillSummary? {
    freshDetail?.summary ?? catalogSummary
}
