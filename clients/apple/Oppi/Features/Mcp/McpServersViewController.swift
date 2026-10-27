import UIKit

/// One MCP scope on the active host: the shell's MCP Servers route (the global
/// scope, `~/.pi/agent/mcp.json`, where the host row switches servers) and a
/// host workspace's own `.pi/mcp.json`, pushed from Workspace Settings like Pi
/// extensions.
///
/// The list probes the host on every appearance, on pull to refresh, when the
/// active server changes, and when a sign-in ends. A sign-in the host still
/// has open is adopted here (Continue / Cancel), and the sheet it opens is
/// presented from whichever MCP screen is on top (`McpSignInPresenter`).
@MainActor
final class McpServersViewController: UIViewController, UICollectionViewDelegate {
    let scopeId: String

    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    private enum Section: Hashable {
        case host, signIn, error, loading, servers, inherited, unavailable, note
    }

    private enum Item: Hashable {
        case host
        case signInProvider, signInContinue, signInCancel, signInError
        case error, retry
        case loading
        case scopeError(Int)
        case noServers
        case server(String)
        case inherited(String)
        case unavailable
        case note
    }

    /// Everything the rows read, taken in `updateProperties()` so observation
    /// tracks it and a reconfigured row sees one consistent copy.
    private struct ViewState {
        var server: PairedServer?
        var hasClient: Bool
        var hostState: ServerBadgeConnectionState?
        var serverCount: Int
        var snapshot: McpServersResponse?
        var error: String?
        var loading: Bool
        /// The sign-in the Continue and Cancel rows act on, while it is live.
        var liveAttempt: ProviderAuthFlowAttempt?
    }

    private let root: AppRootEnvironment
    private let model = McpServersModel()
    private let collectionView = ControlScreenList.makeCollectionView()
    private let refreshControl = UIRefreshControl()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var changedRows = ChangedRows<Item>()
    private var state = ViewState(
        server: nil, hasClient: false, hostState: nil, serverCount: 0,
        snapshot: nil, error: nil, loading: false, liveAttempt: nil
    )
    private let addItem = UIBarButtonItem()
    private var sidebarToggle: UIBarButtonItem?
    private let signInPresenter = McpSignInPresenter()
    private var observedServerId: String?
    private var observedFlowStatus: ProviderAuthFlowSnapshot.Status?
    /// Probes waiting for their host's client.
    private var preparingCount = 0 {
        didSet { setNeedsUpdateProperties() }
    }
    private var activityObservers = NotificationObservers()

    init(scopeId: String, root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.scopeId = scopeId
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = "MCP Servers"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var isGlobal: Bool { scopeId == McpScopeSnapshot.globalId }
    private var signIn: McpSignInOwner { model.signIn }

    /// The active server and its client. Only the global list can switch
    /// servers; a workspace belongs to one host, which Workspace Settings made
    /// the active one.
    private var server: PairedServer? {
        coordinator.serverStore.servers.first { $0.id == coordinator.activeServerId }
    }

    private var client: APIClient? {
        coordinator.activeServerId.flatMap { coordinator.connection(for: $0)?.apiClient }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true, footers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "mcp.list"
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in
            Task { [weak self] in
                await self?.refresh()
                self?.refreshControl.endRefreshing()
            }
        }, for: .valueChanged)
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()

        addItem.title = "Add MCP Server"
        addItem.image = UIImage(systemName: "plus")
        addItem.primaryAction = UIAction(title: "Add MCP Server", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.presentAdd()
        }
        addItem.accessibilityIdentifier = "mcp.add"

        // A sign-in polls only while the app is active, wherever it is shown.
        let center = NotificationCenter.default
        activityObservers.tokens = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.signIn.attempt?.startPolling() }
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.signIn.attempt?.stopPolling() }
            },
        ]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Like the SwiftUI `.task` it replaces: a probe each time the list
        // shows, so a server removed from its detail is gone on return.
        Task { [weak self] in await self?.refresh() }
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)

        let server = server
        // Rows and errors show only for the host that produced them: the active
        // server can change (the host menu, the iPad sidebar) before its client
        // is ready and before this screen has probed it.
        let snapshot = model.snapshot(forHost: server?.id)
        let shownHost = model.snapshotHostId == server?.id
        let attempt = signIn.attempt
        state = ViewState(
            server: server,
            hasClient: client != nil,
            hostState: server.map { HostSwitcherBadgeState.make(for: $0, coordinator: coordinator) },
            serverCount: coordinator.serverStore.servers.count,
            snapshot: snapshot,
            error: shownHost ? model.error : nil,
            loading: model.loading || preparingCount > 0,
            liveAttempt: signIn.hasActive ? attempt : nil
        )
        addItem.isEnabled = !(snapshot == nil || state.loading || signIn.hasActive)
        ControlScreenList.setBarItems(trailing: [addItem], leading: sidebarItems(), on: navigationItem)

        // `.task(id: activeServerId)`: a switched server is probed again.
        let activeId = coordinator.activeServerId
        if activeId != observedServerId {
            let first = observedServerId == nil
            observedServerId = activeId
            // The first probe is `viewIsAppearing`'s.
            if !first { Task { [weak self] in await self?.refresh() } }
        }
        // A sign-in that ends changes what the host has: probe again.
        let status = attempt?.flow.status
        if status != observedFlowStatus {
            observedFlowStatus = status
            if status?.isTerminal == true { Task { [weak self] in await self?.refresh() } }
        }
        signInPresenter.sync(owner: signIn, root: root, from: self)
        applySnapshot()
    }

    /// The sidebar toggle at the split detail root.
    private func sidebarItems() -> [UIBarButtonItem] {
        guard showsSidebarToggle else { return [] }
        let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
        sidebarToggle = toggle
        WorkspaceSplitSidebarToggle.sync(toggle, root: root)
        return [toggle]
    }

    // MARK: - Data

    /// Probes the active server. The old host's rows go first, then it waits
    /// for the new host's client; a host that stopped being active meanwhile
    /// is not probed.
    private func refresh() async {
        guard let server else { return }
        model.switchHost(to: server.id)
        preparingCount += 1
        let client = await coordinator.apiClientReady(for: server.id)
        preparingCount -= 1
        guard let client, coordinator.activeServerId == server.id else { return }
        let scopeId = scopeId
        await model.refresh(
            hostId: server.id, hostName: server.name,
            flowClient: McpFlowClient(client: client)
        ) { try await client.listMcpServers(scopeId: scopeId) }
    }

    private func presentAdd() {
        guard let server, let snapshot = model.snapshot(forHost: server.id), let client else { return }
        let add = McpAddServerViewController(
            client: client, scope: snapshot.scope, serverName: server.name, root: root
        ) { [weak self] in
            Task { [weak self] in await self?.refresh() }
        }
        Router.present(add, presentation: .sheet.inNavigation(), from: self)
    }

    private func openDetail(_ name: String) {
        guard let server, let scope = model.snapshot(forHost: server.id)?.scope,
              let entry = scope.servers.first(where: { $0.name == name }),
              let client else { return }
        let detail = McpServerDetailViewController(
            scope: scope, entry: entry, client: client,
            serverId: server.id, serverName: server.name,
            signIn: signIn, root: root
        )
        Router.push(detail, from: self)
    }

    // MARK: - List

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        // A workspace belongs to one host; only the global list can switch hosts.
        if isGlobal, state.server != nil {
            snapshot.appendSections([.host])
            snapshot.appendItems([.host], toSection: .host)
        }
        if state.liveAttempt != nil {
            snapshot.appendSections([.signIn])
            var items: [Item] = [.signInProvider, .signInContinue, .signInCancel]
            if state.liveAttempt?.actionError != nil { items.append(.signInError) }
            snapshot.appendItems(items, toSection: .signIn)
        }
        if state.error != nil {
            snapshot.appendSections([.error])
            snapshot.appendItems([.error, .retry], toSection: .error)
        }
        if state.loading {
            snapshot.appendSections([.loading])
            snapshot.appendItems([.loading], toSection: .loading)
        }
        if let scope = state.snapshot?.scope, state.hasClient, state.server != nil {
            snapshot.appendSections([.servers])
            var items: [Item] = scope.errors.indices.map(Item.scopeError)
            if scope.servers.isEmpty { items.append(.noServers) }
            items += scope.servers.map { Item.server($0.name) }
            snapshot.appendItems(items, toSection: .servers)
            if let inherited = scope.inherited, !inherited.isEmpty {
                snapshot.appendSections([.inherited])
                snapshot.appendItems(inherited.map { Item.inherited($0.name) }, toSection: .inherited)
            }
        } else if !state.loading, state.error == nil {
            snapshot.appendSections([.unavailable])
            snapshot.appendItems([.unavailable], toSection: .unavailable)
        }
        snapshot.appendSections([.note])
        snapshot.appendItems([.note], toSection: .note)

        // Only the rows whose inputs changed: a reconfigured host row would
        // close the server menu it has open.
        let current = dataSource.snapshot()
        let themeID = root.themeStore.activeThemeID
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) {
            AnyHashable([AnyHashable(themeID)] + rowInputs($0))
        }
        snapshot.reconfigureItems(changed.filter { current.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshSignInHeader()
    }

    private func scopeError(at index: Int) -> String? {
        guard let errors = state.snapshot?.scope.errors, errors.indices.contains(index) else { return nil }
        return errors[index]
    }

    private func rowInputs(_ item: Item) -> [AnyHashable] {
        switch item {
        case .host:
            return [state.server?.id, state.server?.name, state.server?.resolvedBadgeIcon.symbolName,
                    state.hostState?.title, state.serverCount]
        case .signInProvider, .signInContinue, .signInCancel, .signInError:
            guard let attempt = state.liveAttempt else { return [] }
            return [ObjectIdentifier(attempt), attempt.providerName, attempt.isCancelling, attempt.actionError]
        case .error, .retry:
            return [state.error]
        case .scopeError(let index):
            return [scopeError(at: index)]
        case .server(let name):
            guard let entry = state.snapshot?.scope.servers.first(where: { $0.name == name }) else { return [] }
            return [entry.transport, entry.tools.count, entry.exposure.rawValue, entry.state, state.snapshot?.scope.id]
        case .inherited(let name):
            guard let entry = state.snapshot?.scope.inherited?.first(where: { $0.name == name }) else { return [] }
            return [entry.transport, entry.tools.count, entry.exposure.rawValue, entry.state, state.snapshot?.scope.id]
        case .loading, .noServers, .unavailable, .note:
            return []
        }
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            if let self, let section = dataSource?.sectionIdentifier(for: indexPath.section) {
                content.text = headerText(section)
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            if let self, let section = dataSource?.sectionIdentifier(for: indexPath.section) {
                content.text = footerText(section)
            }
            view.contentConfiguration = content
        }
        let host = UICollectionView.CellRegistration<ServerCatalogServerRowCell, Item> { [weak self] cell, _, _ in
            guard let self, let server = state.server, let hostState = state.hostState else { return }
            cell.configure(
                server: server,
                state: hostState,
                palette: palette,
                menu: state.serverCount > 1 ? hostMenu(current: server) : nil
            )
        }
        let message = UICollectionView.CellRegistration<ServerCatalogStateCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            if item == .loading {
                cell.configureLoading("Probing MCP servers…", palette: palette)
            } else {
                cell.configureMessage(
                    systemImage: "server.rack",
                    title: "MCP Servers Unavailable",
                    detail: "Connect to a paired server to manage MCP.",
                    palette: palette
                )
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .host:
                collectionView.dequeueConfiguredReusableCell(using: host, for: indexPath, item: item)
            case .loading, .unavailable:
                collectionView.dequeueConfiguredReusableCell(using: message, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func headerText(_ section: Section) -> String? {
        switch section {
        case .signIn: state.liveAttempt.map { "Sign-In on \($0.serverName)" }
        case .servers: isGlobal ? nil : "This Workspace"
        case .inherited: "From Global"
        case .host, .error, .loading, .unavailable, .note: nil
        }
    }

    private func footerText(_ section: Section) -> String? {
        switch section {
        case .servers:
            isGlobal
                ? "Global servers from ~/.pi/agent/mcp.json load in every host workspace. Each workspace\u{2019}s own servers are in its Workspace Settings."
                : "Servers from this workspace\u{2019}s .pi/mcp.json. A server here replaces a global server with the same name."
        case .inherited:
            "Global servers that also load in this workspace. Change them from MCP Servers in the sidebar."
        case .host, .signIn, .error, .loading, .unavailable, .note:
            nil
        }
    }

    /// The sign-in header names the attempt's server; supplementary views do
    /// not reconfigure, so a new attempt rewrites the visible one.
    private func refreshSignInHeader() {
        guard let section = dataSource?.snapshot().indexOfSection(.signIn),
              let header = collectionView.supplementaryView(
                  forElementKind: UICollectionView.elementKindSectionHeader,
                  at: IndexPath(item: 0, section: section)
              ) as? UICollectionViewListCell else { return }
        var content = UIListContentConfiguration.header()
        content.text = headerText(.signIn)
        header.contentConfiguration = content
    }

    // MARK: - Rows

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        switch item {
        case .host, .loading, .unavailable:
            break
        case .signInProvider:
            ControlScreenList.staticRow(cell)
            var content = UIListContentConfiguration.cell()
            content.text = state.liveAttempt?.providerName
            content.textProperties.color = UIColor(palette.fg)
            cell.contentConfiguration = content
        case .signInContinue:
            ControlScreenList.buttonRow(cell, identifier: "mcp.auth.continue", label: "Continue Sign-In") { [weak self] in
                self?.signIn.resume()
            }
            cell.contentConfiguration = Self.actionContent("Continue Sign-In", color: UIColor(palette.blue))
        case .signInCancel:
            let cancelling = state.liveAttempt?.isCancelling == true
            ControlScreenList.buttonRow(
                cell, identifier: "mcp.auth.cancel", label: "Cancel Sign-In", enabled: !cancelling
            ) { [weak self] in
                guard let owner = self?.signIn else { return }
                Task { await owner.cancel() }
            }
            cell.contentConfiguration = Self.actionContent(
                "Cancel Sign-In", color: UIColor(cancelling ? palette.comment : palette.red)
            )
        case .signInError:
            ControlScreenList.staticRow(cell)
            let message = state.liveAttempt?.actionError
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(message, style: .body, color: UIColor(palette.red))
            }
        case .error:
            ControlScreenList.staticRow(cell, identifier: "mcp.error")
            let message = state.error
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(message, style: .body, color: UIColor(palette.red))
            }
        case .retry:
            ControlScreenList.buttonRow(cell, identifier: "mcp.retry", label: "Retry") { [weak self] in
                Task { [weak self] in await self?.refresh() }
            }
            cell.contentConfiguration = Self.actionContent("Retry", color: UIColor(palette.blue))
        case .scopeError(let index):
            ControlScreenList.staticRow(cell)
            let message = scopeError(at: index)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(message, style: .body, color: UIColor(palette.red))
            }
        case .noServers:
            ControlScreenList.staticRow(cell)
            var content = UIListContentConfiguration.cell()
            content.text = "No MCP servers configured"
            content.textProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
        case .server(let name):
            guard let scope = state.snapshot?.scope,
                  let entry = scope.servers.first(where: { $0.name == name }) else { return }
            ControlScreenList.buttonRow(
                cell,
                identifier: "mcp.server.\(scope.id).\(entry.name)",
                label: entry.name,
                value: Self.summary(entry)
            ) { [weak self] in
                self?.openDetail(name)
            }
            cell.contentConfiguration = Self.serverContent(entry, palette: palette)
            cell.accessories = [.disclosureIndicator()]
        case .inherited(let name):
            guard let scope = state.snapshot?.scope,
                  let entry = scope.inherited?.first(where: { $0.name == name }) else { return }
            ControlScreenList.staticRow(cell, identifier: "mcp.inherited.\(scope.id).\(entry.name)")
            cell.contentConfiguration = Self.serverContent(entry, palette: palette)
        case .note:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(
                    "Refresh probes Pi's configured servers, not running sessions. Configuration changes apply to new sessions or /reload.",
                    style: .footnote,
                    color: UIColor(palette.comment)
                )
            }
            ControlScreenList.background(cell, grouped: false, palette: palette)
        }
    }

    private static func actionContent(_ title: String, color: UIColor) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.color = color
        return content
    }

    /// The status word's color on a server row.
    private static func statusColor(_ state: String, palette: ThemePalette) -> UIColor {
        switch state {
        case "connected": UIColor(palette.green)
        case "disabled", "replaced": .secondaryLabel
        case "failed", "disconnected": UIColor(palette.red)
        case "needs-auth", "untrusted": UIColor(palette.orange)
        default: UIColor(palette.comment)
        }
    }

    private static func summary(_ entry: McpServerSummary) -> String {
        "\(entry.transportLabel) · \(entry.tools.count) tools · \(entry.exposure.title), \(entry.stateLabel)"
    }

    private static func serverContent(_ entry: McpServerSummary, palette: ThemePalette) -> ControlViewContent {
        ControlViewContent(insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0)) {
            let title = ControlRowViews.label(entry.name, style: .headline, color: UIColor(palette.fg))
            let detail = ControlRowViews.label(
                "\(entry.transportLabel) · \(entry.tools.count) tools · \(entry.exposure.title)",
                style: .subheadline,
                color: UIColor(palette.comment)
            )
            let status = ControlRowViews.symbolLabel(
                entry.stateLabel,
                systemImage: entry.state == "connected" ? "checkmark.circle" : "circle",
                style: .caption1,
                color: statusColor(entry.state, palette: palette)
            )
            return ControlRowViews.stack([title, detail, status], spacing: 4)
        }
    }

    // MARK: - Host row

    /// Built each time it opens, so the connection words are current. A
    /// choice asks for the server's lock, then makes it the active one once its
    /// connection is ready (what the SwiftUI `ServerCatalogServerRow` did).
    private func hostMenu(current: PairedServer) -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let coordinator = coordinator
            let servers = coordinator.serverStore.servers.map { server in
                let state = HostSwitcherBadgeState.make(for: server, coordinator: coordinator)
                let action = UIAction(
                    title: state == .connected ? server.name : "\(server.name) — \(state.title)",
                    image: UIImage(systemName: server.id == current.id
                        ? "checkmark.circle.fill"
                        : server.resolvedBadgeIcon.symbolName)
                ) { _ in
                    Task { @MainActor in
                        guard await ScopedLockService.shared.authorize(.server(server.id)) else { return }
                        await coordinator.switchToServerReady(server)
                    }
                }
                action.accessibilityValue = state.title
                return action
            }
            let usage = UIAction(
                title: HostSwitcherDestination.usage.menuTitle,
                image: UIImage(systemName: HostSwitcherDestination.usage.systemImage)
            ) { [weak self] _ in
                self?.root.navigation.openHostSwitcherDestination(.usage, serverId: current.id)
            }
            usage.accessibilityIdentifier = HostSwitcherDestination.usage.accessibilityIdentifier
            completion([
                UIMenu(options: .displayInline, children: servers),
                UIMenu(options: .displayInline, children: [usage]),
            ])
        }])
    }
}

/// Notification tokens that unregister when their owner goes, which a
/// main-actor screen's nonisolated `deinit` cannot do itself.
private final class NotificationObservers: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
