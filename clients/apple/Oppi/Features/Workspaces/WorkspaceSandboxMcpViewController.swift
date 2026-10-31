import UIKit

/// MCP servers of a sandbox workspace: the server's own MCP servers, with a
/// switch for each one this sandbox may load. A switch saves at once. The
/// server reports which servers cannot run in the sandbox and why.
///
/// Pushed from Workspace Settings, which already made the workspace's server
/// the active one and bound `model` to it; this page only reads the model. The
/// list is the model's own load, so the base runs it and draws its state row.
@MainActor
final class WorkspaceSandboxMcpViewController: ListScreenController<
    WorkspaceSandboxMcpViewController.Section,
    WorkspaceSandboxMcpViewController.Item
> {
    enum Section: Hashable, Sendable { case servers }

    enum Item: Hashable, Sendable {
        /// With a way to add one: the row opens the MCP Servers list.
        case openServers
        case server(String)
        /// A picked name the server no longer lists, so it can still be switched off.
        case missing(String)
    }

    private let model: WorkspaceSettingsModel
    private let root: AppRootEnvironment
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

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    /// The server's MCP servers, each time the page shows: another device can
    /// add one to the global list.
    override var loadPolicy: LoadPolicy { .eachAppearance }

    override func load() async throws {
        await model.loadSandboxMcpServers()
    }

    // MARK: - Rows

    /// Picked names no longer in the server's list.
    private func missingNames(from servers: [McpServerSummary]) -> [String] {
        model.sandboxMcpSelection.subtracting(servers.map(\.name)).sorted()
    }

    override func sections() -> [ListSection<Section, Item>] {
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        let servers = model.sandboxMcpServers ?? []
        let missing = missingNames(from: servers)
        var items: [Item] = servers.map { .server($0.name) }
        items += missing.map { .missing($0) }
        // Nothing to pick from once the read settled: the way to add one sits under
        // the empty row. While it loads, the row beside it is the base's.
        if servers.isEmpty, missing.isEmpty, !isLoading, model.sandboxMcpLoadError == nil, model.sandboxMcpError == nil {
            items.append(.openServers)
        }
        let serverName = model.serverName(in: root.coordinator.serverStore) ?? String(localized: "your server")
        let footer = String(localized: "Only servers you turn on load in this workspace. Web servers are called from \(serverName), and only to Allowed Hosts; their sign-in stays there. Command servers run inside the sandbox, where the agent can read their settings; servers that use \(serverName)\u{2019}s secrets are blocked.")
        return [ListSection(
            .servers,
            footer: footer,
            items: items,
            state: stateRow(
                hasContent: !(servers.isEmpty && missing.isEmpty),
                isLoading: isLoading,
                failure: failure
            )
        )]
    }

    override func loadingCaption() -> String? { String(localized: "Loading MCP servers…") }

    override func failureTitle() -> String? { String(localized: "Couldn't Load MCP Servers") }

    override func emptyState() -> LoadState? {
        .empty(title: String(localized: "No MCP servers to pick from yet."), systemImage: "network")
    }

    /// The save's failure, over the servers the page already had, through the kit's
    /// one row: a save that failed is Retried by reading the list again.
    private var failure: LoadFailureReport? {
        if let reason = model.sandboxMcpError {
            return LoadFailureReport(title: String(localized: "Couldn't Save the MCP Server"), reason: reason)
        }
        return failureReport(reason: model.sandboxMcpLoadError)
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .openServers:
            return AnyHashable(0)
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

    private lazy var linkRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(
            title: String(localized: "Open MCP Servers"),
            image: .symbol("network"),
            value: nil,
            identifier: "workspace.edit.sandboxMcp.openServers"
        ) { [weak self] in self?.openServers() }
    }

    override func prepareRegistrations() {
        _ = (serverRow, linkRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .server, .missing:
            collectionView.dequeueConfiguredReusableCell(using: serverRow, for: indexPath, item: item)
        case .openServers:
            collectionView.dequeueConfiguredReusableCell(using: linkRow, for: indexPath, item: item)
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
