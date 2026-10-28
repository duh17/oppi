import UIKit

/// MCP servers of a sandbox workspace: the server's own MCP servers, with a
/// switch for each one this sandbox may load. A switch saves at once. The
/// server reports which servers cannot run in the sandbox and why.
///
/// Pushed from Workspace Settings, which already made the workspace's server
/// the active one and bound `model` to it; this page only reads the model.
@MainActor
final class WorkspaceSandboxMcpViewController: SettingsListViewController<
    WorkspaceSandboxMcpViewController.Section,
    WorkspaceSandboxMcpViewController.Item
> {
    enum Section: Hashable, Sendable { case servers }

    enum Item: Hashable, Sendable {
        case loading
        case loadFailed
        case empty
        /// With a way to add one: the row opens the MCP Servers list.
        case openServers
        case server(String)
        /// A picked name the server no longer lists, so it can still be switched off.
        case missing(String)
        case error
    }

    private let model: WorkspaceSettingsModel
    private let root: AppRootEnvironment
    private var loadTask: Task<Void, Never>?
    /// Bumped when a switch's write ends, so it is redrawn from the stored
    /// value even where that value did not change (a failed write).
    private var toggleRevision = 0

    init(model: WorkspaceSettingsModel, root: AppRootEnvironment) {
        self.model = model
        self.root = root
        super.init(
            title: String(localized: "MCP Servers"),
            listIdentifier: "workspace.edit.sandboxMcp.list",
            scope: .workspace(model.workspace.name),
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    deinit {
        loadTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        let model = model
        loadTask?.cancel()
        loadTask = Task { await model.loadSandboxMcpServers() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Rows

    /// Picked names no longer in the server's list.
    private func missingNames(from servers: [McpServerSummary]) -> [String] {
        model.sandboxMcpSelection.subtracting(servers.map(\.name)).sorted()
    }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        var items: [Item] = []
        if let servers = model.sandboxMcpServers {
            let missing = missingNames(from: servers)
            if servers.isEmpty && missing.isEmpty { items += [.empty, .openServers] }
            items += servers.map { .server($0.name) }
            items += missing.map { .missing($0) }
        } else if model.sandboxMcpLoadError != nil {
            items.append(.loadFailed)
        } else {
            items.append(.loading)
        }
        if model.sandboxMcpError != nil { items.append(.error) }
        let serverName = model.serverName(in: root.coordinator.serverStore) ?? String(localized: "your server")
        let footer = String(localized: "Only servers you turn on load in this workspace. Web servers are called from \(serverName), and only to Allowed Hosts; their sign-in stays there. Command servers run inside the sandbox, where the agent can read their settings; servers that use \(serverName)\u{2019}s secrets are blocked.")
        return [SettingsSectionModel(.servers, footer: footer, items: items)]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .loading, .empty, .openServers:
            return AnyHashable(0)
        case .loadFailed:
            return AnyHashable(model.sandboxMcpLoadError)
        case .error:
            return AnyHashable(model.sandboxMcpError)
        case .server(let name):
            guard let entry = entry(named: name) else { return AnyHashable(0) }
            return AnyHashable([
                AnyHashable(detail(for: entry)),
                AnyHashable(entry.state),
                AnyHashable(model.sandboxMcpSelection.contains(name)),
                AnyHashable(toggleRevision),
            ])
        case .missing(let name):
            return AnyHashable([AnyHashable(model.sandboxMcpSelection.contains(name)), AnyHashable(toggleRevision)])
        }
    }

    private func entry(named name: String) -> McpServerSummary? {
        model.sandboxMcpServers?.first { $0.name == name }
    }

    private lazy var serverRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .server(let name):
            guard let entry = entry(named: name) else { return }
            configureRow(
                cell,
                name: name,
                detail: detail(for: entry),
                blocked: entry.state == "blocked" || entry.state == "disabled",
                warning: entry.state == "blocked"
            )
        case .missing(let name):
            configureRow(cell, name: name, detail: String(localized: "Not in the global mcp.json."), blocked: true, warning: true)
        default:
            break
        }
    }

    /// Loading, empty, and the failures: state rows. A failed load can be retried.
    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .loading:
            cell.configure(.loading(String(localized: "Loading MCP servers\u{2026}")))
        case .loadFailed:
            let model = model
            cell.configure(
                .failure(model.sandboxMcpLoadError ?? "", retry: { Task { await model.loadSandboxMcpServers() } }),
                identifier: "workspace.edit.sandboxMcp.loadError"
            )
        case .error:
            cell.configure(.failure(model.sandboxMcpError ?? "", retry: nil), identifier: "workspace.edit.sandboxMcp.error")
        default:
            cell.configure(.message(String(localized: "No MCP servers to pick from yet.")))
        }
    }

    private lazy var linkRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(
            title: String(localized: "Open MCP Servers"),
            systemImage: "network",
            value: nil,
            identifier: "workspace.edit.sandboxMcp.openServers"
        ) { [weak self] in self?.openServers() }
    }

    override func prepareRegistrations() {
        _ = (serverRow, stateRow, linkRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .server, .missing:
            collectionView.dequeueConfiguredReusableCell(using: serverRow, for: indexPath, item: item)
        case .openServers:
            collectionView.dequeueConfiguredReusableCell(using: linkRow, for: indexPath, item: item)
        default:
            collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        }
    }

    private func detail(for entry: McpServerSummary) -> String {
        if let reason = entry.error { return reason }
        if entry.state == "disabled" { return String(localized: "Disabled in the global mcp.json.") }
        if let url = entry.config.url { return url }
        let command = ([entry.config.command ?? ""] + (entry.config.args ?? [])).joined(separator: " ")
        return String(localized: "Runs in the sandbox: \(command). The agent can read its settings.")
    }

    /// A blocked or disabled server cannot be newly enabled, but a stale pick can be cleared.
    private func configureRow(_ cell: UICollectionViewListCell, name: String, detail: String, blocked: Bool, warning: Bool) {
        let isSelected = model.sandboxMcpSelection.contains(name)
        detailToggleRow(
            cell,
            row: WorkspaceToggleRow(
                title: name,
                detail: detail,
                dimsTitle: blocked,
                warnsDetail: warning,
                isOn: isSelected,
                isEnabled: !(blocked && !isSelected),
                identifier: "workspace.edit.sandboxMcp.\(name)"
            )
        ) { [weak self] on in
            guard let self else { return }
            let model = model
            Task { [weak self] in
                await model.setSandboxMcpServer(name, enabled: on)
                // A failed write reverts the pick, so redraw the switch from it.
                self?.toggleRevision += 1
                self?.setNeedsUpdateProperties()
            }
        }
    }

    // MARK: - Actions

    /// The server's own MCP Servers list, where servers are added.
    private func openServers() {
        Router.push(McpServersViewController(scopeId: McpScopeSnapshot.globalId, root: root), from: self)
    }
}
