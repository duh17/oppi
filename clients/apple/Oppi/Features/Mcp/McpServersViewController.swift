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
///
/// A `ListScreenController`: the base owns the list, the probe on appearance
/// and pull to refresh, and the text of its one state row — a probe failure or
/// a host that cannot answer it is one failed row with Retry.
@MainActor
final class McpServersViewController: ListScreenController<McpServersViewController.Section, McpServersViewController.Item> {
    let scopeId: String

    var showsSidebarToggle: Bool {
        didSet { setNeedsUpdateProperties() }
    }

    enum Section: Hashable, Sendable {
        case host, signIn, state, servers, inherited, note
    }

    enum Item: Hashable, Sendable {
        case host
        case signInProvider, signInContinue, signInCancel, signInError
        case scopeError(Int)
        case noServers
        case server(String)
        case inherited(String)
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
    private var state = ViewState(
        server: nil, hasClient: false, hostState: nil, serverCount: 0,
        snapshot: nil, error: nil, loading: false, liveAttempt: nil
    )
    private let addItem = UIBarButtonItem()
    private var sidebarToggle: UIBarButtonItem?
    private let signInPresenter = McpSignInPresenter()
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
        super.init(title: "MCP Servers", listIdentifier: "mcp.list", headers: true, footers: true)
        traitOverrides.appRootEnvironment = root
    }

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

    override func updateProperties() {
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
        super.updateProperties()
        addItem.isEnabled = !(snapshot == nil || state.loading || signIn.hasActive)
        ListScreen.setBarItems(trailing: [addItem], leading: sidebarItems(), on: navigationItem)

        // A sign-in that ends changes what the host has: probe again.
        let status = attempt?.flow.status
        if status != observedFlowStatus {
            observedFlowStatus = status
            if status?.isTerminal == true { setNeedsLoad() }
        }
        signInPresenter.sync(owner: signIn, root: root, from: self)
    }

    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The active server's MCP scope: another server is another host's servers.
    override func loadSubject() -> AnyHashable? { AnyHashable(coordinator.activeServerId) }

    /// A probe swaps the host's sections; the rows should not slide.
    override var animatesUpdates: Bool { false }

    /// The sidebar toggle at the split detail root.
    private func sidebarItems() -> [UIBarButtonItem] {
        guard showsSidebarToggle else { return [] }
        let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
        sidebarToggle = toggle
        WorkspaceSplitSidebarToggle.sync(toggle, root: root)
        return [toggle]
    }

    // MARK: - Data

    /// Probes the active server: the base runs it on every appearance, on pull to
    /// refresh, and when another server becomes active; a finished sign-in asks
    /// for it through `setNeedsLoad()`. The old host's rows go first, then it waits
    /// for the new host's client; a host that stopped being active meanwhile is
    /// not probed.
    override func load() async throws {
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
            self?.setNeedsLoad()
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

    override func sections() -> [ListSection<Section, Item>] {
        var sections: [ListSection<Section, Item>] = []
        // A workspace belongs to one host; only the global list can switch hosts.
        if isGlobal, state.server != nil {
            sections.append(ListSection(.host, items: [.host]))
        }
        if let attempt = state.liveAttempt {
            var items: [Item] = [.signInProvider, .signInContinue, .signInCancel]
            if attempt.actionError != nil { items.append(.signInError) }
            sections.append(ListSection(.signIn, header: "Sign-In on \(attempt.serverName)", items: items))
        }
        if let row = stateRow(hasContent: hasContent, isLoading: state.loading, failure: stateFailure) {
            sections.append(ListSection(.state, items: [], state: row))
        }
        if let scope = state.snapshot?.scope, state.hasClient, state.server != nil {
            var items: [Item] = scope.errors.indices.map(Item.scopeError)
            if scope.servers.isEmpty { items.append(.noServers) }
            items += scope.servers.map { Item.server($0.name) }
            sections.append(ListSection(.servers, header: serverSectionHeader, footer: serversFooter, items: items))
            if let inherited = scope.inherited, !inherited.isEmpty {
                sections.append(ListSection(
                    .inherited,
                    header: "From Global",
                    footer: "Global servers that also load in this workspace. Change them from MCP Servers in the sidebar.",
                    items: inherited.map { Item.inherited($0.name) }
                ))
            }
        }
        sections.append(ListSection(.note, items: [.note]))
        return sections
    }

    /// Whether the host's scope is here: the probe answers with the servers and
    /// the errors they had, so without it there is nothing to list.
    private var hasContent: Bool {
        state.snapshot != nil && state.hasClient && state.server != nil
    }

    /// A host that cannot provide the list (no client, no scope) is a failure
    /// with Retry, like a catalog's; a scope that answered with no servers is
    /// not.
    private var stateFailure: String? {
        if let error = state.error { return error }
        guard !hasContent, !state.loading else { return nil }
        return String(localized: "MCP servers are unavailable. Connect to a paired server to manage MCP.")
    }

    override func loadingCaption() -> String? { String(localized: "Probing MCP servers…") }

    override var stateRowIdentifiers: StateRowIdentifiers {
        StateRowIdentifiers(loading: "mcp.loading", failed: "mcp.retry")
    }

    private var serverSectionHeader: String? {
        isGlobal ? nil : "This Workspace"
    }

    private var serversFooter: String {
        isGlobal
            ? "Global servers from ~/.pi/agent/mcp.json load in every host workspace. Each workspace\u{2019}s own servers are in its Workspace Settings."
            : "Servers from this workspace\u{2019}s .pi/mcp.json. A server here replaces a global server with the same name."
    }

    private func scopeError(at index: Int) -> String? {
        guard let errors = state.snapshot?.scope.errors, errors.indices.contains(index) else { return nil }
        return errors[index]
    }

    /// What a row draws from, besides its own identity: a reconfigured host row
    /// would close the server menu it has open.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .host:
            return AnyHashable([AnyHashable(state.server?.id), AnyHashable(state.server?.name),
                                AnyHashable(state.server?.resolvedBadgeIcon.symbolName),
                                AnyHashable(state.hostState?.title), AnyHashable(state.serverCount)])
        case .signInProvider, .signInContinue, .signInCancel, .signInError:
            guard let attempt = state.liveAttempt else { return AnyHashable(0) }
            return AnyHashable([
                AnyHashable(ObjectIdentifier(attempt)), AnyHashable(attempt.providerName),
                AnyHashable(attempt.isCancelling), AnyHashable(attempt.actionError),
            ])
        case .scopeError(let index):
            return AnyHashable(scopeError(at: index))
        case .server(let name):
            guard let entry = state.snapshot?.scope.servers.first(where: { $0.name == name }) else { return AnyHashable(0) }
            return AnyHashable([AnyHashable(entry.transport), AnyHashable(entry.tools.count),
                                AnyHashable(entry.exposure.rawValue), AnyHashable(entry.state),
                                AnyHashable(state.snapshot?.scope.id)])
        case .inherited(let name):
            guard let entry = state.snapshot?.scope.inherited?.first(where: { $0.name == name }) else { return AnyHashable(0) }
            return AnyHashable([AnyHashable(entry.transport), AnyHashable(entry.tools.count),
                                AnyHashable(entry.exposure.rawValue), AnyHashable(entry.state),
                                AnyHashable(state.snapshot?.scope.id)])
        // The empty-list row and the note hold nothing a reconfigure would
        // disturb, so the kit's default draws them again.
        default:
            return super.inputs(of: item)
        }
    }

    // MARK: - Rows

    private lazy var hostRow = UICollectionView.CellRegistration<ServerCatalogServerRowCell, Item> { [weak self] cell, _, _ in
        guard let self, let server = state.server, let hostState = state.hostState else { return }
        cell.configure(
            server: server,
            state: hostState,
            palette: palette,
            menu: state.serverCount > 1
                ? ServerCatalogServerMenu.make(
                    coordinator: coordinator, navigation: root.navigation,
                    shownServerId: { [weak self] in self?.state.server?.id }
                )
                : nil
        )
    }

    // A registration must exist before the first row is dequeued.
    override func prepareRegistrations() {
        _ = hostRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .host:
            collectionView.dequeueConfiguredReusableCell(using: hostRow, for: indexPath, item: item)
        case .signInProvider, .signInContinue, .signInCancel, .signInError,
             .scopeError, .noServers, .server, .inherited, .note:
            cardCell(for: item, at: indexPath)
        }
    }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        switch item {
        case .host:
            break
        case .signInProvider:
            ListScreen.staticRow(cell)
            var content = UIListContentConfiguration.cell()
            content.text = state.liveAttempt?.providerName
            content.textProperties.color = UIColor(palette.fg)
            cell.contentConfiguration = content
        case .signInContinue:
            ListScreen.buttonRow(cell, identifier: "mcp.auth.continue", label: "Continue Sign-In") { [weak self] in
                self?.signIn.resume()
            }
            cell.contentConfiguration = Self.actionContent("Continue Sign-In", color: UIColor(palette.blue))
        case .signInCancel:
            let cancelling = state.liveAttempt?.isCancelling == true
            ListScreen.buttonRow(
                cell, identifier: "mcp.auth.cancel", label: "Cancel Sign-In", enabled: !cancelling
            ) { [weak self] in
                guard let owner = self?.signIn else { return }
                Task { await owner.cancel() }
            }
            cell.contentConfiguration = Self.actionContent(
                "Cancel Sign-In", color: UIColor(cancelling ? palette.comment : palette.red)
            )
        case .signInError:
            ListScreen.staticRow(cell)
            let message = state.liveAttempt?.actionError
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(message, style: .body, color: UIColor(palette.red))
            }
        case .scopeError(let index):
            ListScreen.staticRow(cell)
            let message = scopeError(at: index)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(message, style: .body, color: UIColor(palette.red))
            }
        case .noServers:
            ListScreen.staticRow(cell)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "No MCP servers configured")
            content.textProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
        case .server(let name):
            guard let scope = state.snapshot?.scope,
                  let entry = scope.servers.first(where: { $0.name == name }) else { return }
            ListScreen.buttonRow(
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
            ListScreen.staticRow(cell, identifier: "mcp.inherited.\(scope.id).\(entry.name)")
            cell.contentConfiguration = Self.serverContent(entry, palette: palette)
        case .note:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(
                    "Refresh probes Pi's configured servers, not running sessions. Configuration changes apply to new sessions or /reload.",
                    style: .footnote,
                    color: UIColor(palette.comment)
                )
            }
            ListScreen.background(cell, grouped: false, palette: palette)
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
}

/// Notification tokens that unregister when their owner goes, which a
/// main-actor screen's nonisolated `deinit` cannot do itself.
private final class NotificationObservers: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
