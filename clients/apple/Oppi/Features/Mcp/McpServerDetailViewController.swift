import UIKit

/// One MCP server in one scope: where it connects, its Enabled switch and
/// Exposure, OAuth sign-in and sign-out, the references it passes, its
/// connection error, its tools, and Remove. Every change is saved to the
/// scope's `mcp.json` and re-read from the host.
///
/// The list owns the host's sign-in (`McpSignInOwner`), so popping this page
/// cannot lose its Continue / Cancel handle. A sign-in started here presents
/// its sheet from this page, which covers the list.
@MainActor
final class McpServerDetailViewController: ListScreenController<McpServerDetailViewController.Section, McpServerDetailViewController.Item> {
    enum Section: Hashable, Sendable {
        case info, config, oauth, headers, environment, connectionError, scopeErrors, tools, busy, error, remove
    }

    enum Item: Hashable, Sendable {
        case status, transport, url, command, cwd, trustNote
        case enabled, exposure
        case continueSignIn, signIn, signOut
        case header(String), env(String)
        case connectionError
        case scopeError(Int)
        case noTools, tool(String)
        case busy, error
        case remove
    }

    private var scope: McpScopeSnapshot {
        didSet { setNeedsUpdateProperties() }
    }
    private var entry: McpServerSummary {
        didSet { setNeedsUpdateProperties() }
    }
    private var busy = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private let client: APIClient
    private let serverId: String
    private let serverName: String
    private let signIn: McpSignInOwner
    private let root: AppRootEnvironment
    private let refreshControl = UIRefreshControl()
    private let signInPresenter = McpSignInPresenter()
    private var observedFlowStatus: ProviderAuthFlowSnapshot.Status?

    init(
        scope: McpScopeSnapshot,
        entry: McpServerSummary,
        client: APIClient,
        serverId: String,
        serverName: String,
        signIn: McpSignInOwner,
        root: AppRootEnvironment
    ) {
        self.scope = scope
        self.entry = entry
        self.client = client
        self.serverId = serverId
        self.serverName = serverName
        self.signIn = signIn
        self.root = root
        super.init(
            title: entry.name,
            listIdentifier: "mcp.detail.list",
            scope: scope.id == McpScopeSnapshot.globalId ? .server(serverName) : .workspace(scope.title),
            headers: true,
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    private var palette: ThemePalette { ThemeRuntimeState.currentPalette() }

    /// This server's sign-in, if the host's open one belongs to it.
    private var attempt: ProviderAuthFlowAttempt? {
        guard signIn.scopeId == scope.id, signIn.attempt?.serverId == serverId,
              signIn.attempt?.providerName == entry.name else { return nil }
        return signIn.attempt
    }

    private var locked: Bool { busy || signIn.hasActive }

    /// `untrusted`: Pi's host MCP commands (status, sign-in, sign-out) skip this project file
    /// until a trust decision is remembered, even when sessions load it.
    private var needsRememberedTrust: Bool { entry.state == "untrusted" }

    private var trustNote: String? {
        if scope.projectTrust == .distrusted { return scope.projectTrust?.explanation }
        guard needsRememberedTrust else { return nil }
        return "Status and sign-in need a remembered trust for this folder. Choose Trust (remember) when a session here asks, or trust the project in Pi on the host."
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in
            Task { [weak self] in
                await self?.reload()
                self?.refreshControl.endRefreshing()
            }
        }, for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func updateProperties() {
        // The page's rows read the sign-in owner, so this pass tracks it.
        let attempt = attempt
        title = entry.name
        // A sign-in that completes changed the server's state: read it again.
        let status = attempt?.flow.status
        if status != observedFlowStatus {
            observedFlowStatus = status
            if status == .completed { Task { [weak self] in await self?.reload() } }
        }
        signInPresenter.sync(owner: signIn, root: root, from: self)
        super.updateProperties()
    }

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        var result: [ListSection<Section, Item>] = []
        var info: [Item] = [.status, .transport]
        if entry.config.url != nil { info.append(.url) }
        if entry.config.command != nil { info.append(.command) }
        if entry.config.cwd != nil { info.append(.cwd) }
        if trustNote != nil { info.append(.trustNote) }
        result.append(ListSection(.info, header: "\(scope.title) · \(serverName)", items: info))
        result.append(ListSection(
            .config,
            footer: "\(entry.exposure.explanation) Saved in this scope's mcp.json. New sessions or /reload pick up configuration changes.",
            items: [.enabled, .exposure]
        ))
        if entry.supportsOAuth {
            let live = attempt.map { !$0.isSettled } ?? false
            result.append(ListSection(
                .oauth, header: "OAuth", items: live ? [.continueSignIn] : [.signIn, .signOut]
            ))
        }
        if let headers = entry.config.headers, !headers.isEmpty {
            result.append(ListSection(.headers, header: "Headers", items: headers.keys.sorted().map(Item.header)))
        }
        if let env = entry.config.env, !env.isEmpty {
            result.append(ListSection(.environment, header: "Environment", items: env.keys.sorted().map(Item.env)))
        }
        if entry.error != nil {
            result.append(ListSection(.connectionError, header: "Connection Error", items: [.connectionError]))
        }
        if !scope.errors.isEmpty {
            result.append(ListSection(.scopeErrors, items: scope.errors.indices.map(Item.scopeError)))
        }
        // A diffable list traps on a repeated item; a repeated tool shows once.
        var seen = Set<String>()
        let tools: [Item] = entry.tools.isEmpty
            ? [.noTools]
            : entry.tools.filter { seen.insert($0).inserted }.map(Item.tool)
        result.append(ListSection(.tools, header: "Tools (\(entry.tools.count))", items: tools))
        if busy { result.append(ListSection(.busy, items: [.busy])) }
        if error != nil { result.append(ListSection(.error, items: [.error])) }
        result.append(ListSection(.remove, items: [.remove]))
        return result
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .status: AnyHashable(entry.state)
        case .transport: AnyHashable(entry.transport)
        case .url: AnyHashable(entry.config.url)
        case .command: AnyHashable([entry.config.command] + (entry.config.args ?? []).map { Optional($0) })
        case .cwd: AnyHashable(entry.config.cwd)
        case .trustNote: AnyHashable(trustNote)
        case .enabled: AnyHashable([AnyHashable(entry.enabled), AnyHashable(locked)])
        case .exposure: AnyHashable([AnyHashable(entry.exposure.rawValue), AnyHashable(locked)])
        case .continueSignIn: AnyHashable(0)
        case .signIn: AnyHashable([AnyHashable(entry.state), AnyHashable(locked), AnyHashable(needsRememberedTrust)])
        case .signOut: AnyHashable([AnyHashable(locked), AnyHashable(needsRememberedTrust)])
        case .header(let key): AnyHashable(entry.config.headers?[key])
        case .env(let key): AnyHashable(entry.config.env?[key])
        case .connectionError: AnyHashable(entry.error)
        case .scopeError(let index):
            AnyHashable(scope.errors.indices.contains(index) ? scope.errors[index] : nil)
        case .noTools: AnyHashable(0)
        case .tool(let name): AnyHashable(entry.toolExposure?[name]?.rawValue)
        case .busy: AnyHashable(0)
        case .error: AnyHashable(error)
        case .remove: AnyHashable(locked)
        }
    }

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, _ in
        self?.configureExposure(cell)
    }

    private func configureExposure(_ cell: SettingsMenuRowCell) {
        let client = client
        let scopeId = scope.id
        let name = entry.name
        cell.configure(
            title: "Exposure",
            identifier: "mcp.exposure",
            options: McpExposure.allCases.map { option in
                (title: option.title, selected: option == entry.exposure, action: { [weak self] in
                    // The row is a menu button at every text size, so a change
                    // asked for while another is saving or a sign-in is open
                    // stops here.
                    guard let self, !locked else { return }
                    perform {
                        try await client.patchMcpServer(
                            scopeId: scopeId, name: name, patch: McpPatchServerRequest(exposure: option)
                        )
                    }
                })
            }
        )
    }

    override func prepareRegistrations() {
        _ = menuRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .continueSignIn, .signIn, .signOut, .remove:
            cardCell(for: item, at: indexPath)
        case .exposure:
            collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        default:
            super.dequeue(item, at: indexPath)
        }
    }

    // MARK: - Rows

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        let palette = palette
        let entry = entry
        let client = client
        let scopeId = scope.id
        let name = entry.name
        switch item {
        case .status:
            cell.contentConfiguration = McpRowContent.value("Status", entry.stateLabel)
        case .transport:
            cell.contentConfiguration = McpRowContent.value("Transport", entry.transportLabel)
        case .url:
            let url = entry.config.url ?? ""
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.selectableText(url, style: .body, color: UIColor(palette.fg))
            }
        case .command:
            let command = ([entry.config.command ?? ""] + (entry.config.args ?? [])).joined(separator: " ")
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                let text = ControlRowViews.selectableText(command, style: .body, color: UIColor(palette.fg))
                text.font = UIFont.scaledMonospaced(.body)
                return text
            }
        case .cwd:
            cell.contentConfiguration = McpRowContent.value("Working Directory", entry.config.cwd ?? "")
        case .trustNote:
            let note = trustNote
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.label(note, style: .footnote, color: UIColor(palette.orange))
            }
        case .enabled:
            cell.contentConfiguration = Self.rowText("Enabled")
            cell.accessories = [.settingsToggle(
                entry.enabled, identifier: "mcp.enabled", label: "Enabled", isEnabled: !locked, reusing: cell
            ) { [weak self] value in
                self?.perform {
                    try await client.patchMcpServer(
                        scopeId: scopeId, name: name, patch: McpPatchServerRequest(enabled: value)
                    )
                }
            }]
        case .exposure:
            break
        case .header(let key):
            reference(cell, key, entry.config.headers?[key])
        case .env(let key):
            reference(cell, key, entry.config.env?[key])
        case .connectionError:
            let message = entry.error ?? ""
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.selectableText(message, style: .body, color: UIColor(palette.red))
            }
        case .scopeError(let index):
            let message = scope.errors.indices.contains(index) ? scope.errors[index] : nil
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(message, style: .body, color: UIColor(palette.red))
            }
        case .noTools:
            cell.contentConfiguration = Self.rowText("No tools available", color: UIColor(palette.comment))
        case .tool(let name):
            let exposure = entry.toolExposure?[name]
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                let tool = ControlRowViews.selectableText(name, style: .body, color: UIColor(palette.fg))
                tool.font = UIFont.scaledMonospaced(.body)
                var views: [UIView] = [tool]
                if let exposure {
                    views.append(ControlRowViews.label(exposure.title, style: .caption1, color: UIColor(palette.comment)))
                }
                return ControlRowViews.stack(views, spacing: 2)
            }
        case .busy:
            cell.contentConfiguration = UIContentUnavailableConfiguration.loadState(
                .loading(String(localized: "Updating…")),
                palette: palette
            )
        case .error:
            cell.accessibilityIdentifier = "mcp.detail.error"
            let message = error
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(message, style: .body, color: UIColor(palette.red))
            }
        case .continueSignIn, .signIn, .signOut, .remove:
            break
        }
    }

    /// A row that is one button: its element is the row's only accessibility
    /// element, so `app.buttons[id]` finds it. The kit paints the theme card
    /// behind it, as it does for the rows beside these.
    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        let locked = locked
        switch item {
        case .continueSignIn:
            ListScreen.buttonRow(cell, identifier: "mcp.detail.auth.continue", label: "Continue Sign-In") { [weak self] in
                self?.signIn.resume()
            }
            cell.contentConfiguration = Self.rowText("Continue Sign-In", color: UIColor(palette.blue))
        case .signIn:
            let enabled = !(locked || needsRememberedTrust)
            let title = entry.state == "needs-auth" ? "Sign In" : "Sign In Again"
            ListScreen.buttonRow(cell, identifier: "mcp.login", label: title, enabled: enabled) { [weak self] in
                self?.startLogin()
            }
            cell.contentConfiguration = Self.rowText(title, color: UIColor(enabled ? palette.blue : palette.comment))
        case .signOut:
            let enabled = !(locked || needsRememberedTrust)
            ListScreen.buttonRow(cell, identifier: "mcp.logout", label: "Sign Out", enabled: enabled) { [weak self] in
                self?.confirmLogout()
            }
            cell.contentConfiguration = Self.rowText("Sign Out", color: UIColor(enabled ? palette.red : palette.comment))
        case .remove:
            ListScreen.buttonRow(cell, identifier: "mcp.remove", label: "Remove Server", enabled: !locked) { [weak self] in
                self?.confirmRemove()
            }
            cell.contentConfiguration = Self.rowText("Remove Server", color: UIColor(locked ? palette.comment : palette.red))
        default:
            break
        }
    }

    private static func rowText(_ text: String, color: UIColor? = nil) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = text
        if let color { content.textProperties.color = color }
        return content
    }

    /// A header or environment reference: its name, and its value or `[redacted]`.
    private func reference(_ cell: UICollectionViewListCell, _ key: String, _ value: String?) {
        let palette = palette
        let shown = value ?? "[redacted]"
        cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
            let name = ControlRowViews.label(key, style: .subheadline, color: UIColor(palette.comment), lines: 1)
            name.font = UIFont.scaledMonospaced(.subheadline)
            name.setContentCompressionResistancePriority(.required, for: .horizontal)
            name.setContentHuggingPriority(.required, for: .horizontal)
            let content = ControlRowViews.selectableText(shown, style: .subheadline, color: UIColor(palette.fg))
            content.font = UIFont.scaledMonospaced(.subheadline)
            content.textAlignment = .right
            let row = ControlRowViews.stack([name, content], axis: .horizontal, spacing: 12, alignment: .top)
            row.isAccessibilityElement = true
            row.accessibilityLabel = key
            row.accessibilityValue = shown
            return row
        }
    }

    // MARK: - Actions

    private func confirmRemove() {
        guard !locked else { return }
        let name = entry.name
        Confirmation(
            title: "Remove \(name) from \(scope.title)?",
            message: "The configuration entry will be removed. Stored OAuth credentials are not deleted; sign out first if needed.",
            actionTitle: "Remove Server"
        ).present(from: self, anchor: row(for: .remove)) { [weak self] in
            self?.remove()
        }
    }

    private func confirmLogout() {
        let name = entry.name
        let client = client
        let scopeId = scope.id
        Confirmation(
            title: "Sign out of \(name)?",
            message: "This removes stored OAuth credentials on the host. You will need to sign in again to use this server.",
            actionTitle: "Sign Out"
        ).present(from: self, anchor: row(for: .signOut)) { [weak self] in
            self?.perform {
                try await client.logoutMcpServer(scopeId: scopeId, name: name)
            }
        }
    }

    /// The cell of the row that asked, where an action sheet points on iPad.
    private func row(for item: Item) -> UIView? {
        indexPath(for: item).flatMap(collectionView.cellForItem(at:))
    }

    private func remove() {
        guard !busy else { return }
        busy = true
        let client = client
        let scopeId = scope.id
        let name = entry.name
        Task { [weak self] in
            do {
                try await client.removeMcpServer(scopeId: scopeId, name: name)
                if let self { Router.finish(self) }
            } catch {
                self?.error = error.localizedDescription
            }
            self?.busy = false
        }
    }

    /// Reads this server again, on pull to refresh and after a change saves.
    /// The page keeps its own refresh control (a sign-in's state decides what
    /// reloads), so this is its own reload, not the base's `refresh()`.
    private func reload() async {
        guard attempt?.isSettled != false else { return }
        do {
            let currentScope = try await client.listMcpServers(scopeId: scope.id).scope
            scope = currentScope
            if let current = currentScope.servers.first(where: { $0.name == entry.name }) { entry = current }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// One change at a time: save it to the host, then read the scope again.
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { [weak self] in
            do {
                try await action()
                await self?.reload()
            } catch {
                self?.error = error.localizedDescription
            }
            self?.busy = false
        }
    }

    private func startLogin() {
        guard !busy else { return }
        busy = true
        error = nil
        let client = client
        let scopeId = scope.id
        let name = entry.name
        let serverId = serverId
        let serverName = serverName
        // The owner outlives this page: a sign-in that started is adopted even
        // if the page was popped while the host answered.
        let signIn = signIn
        Task { [weak self] in
            do {
                let flow = try await client.startMcpAuthFlow(scopeId: scopeId, name: name)
                let attempt = ProviderAuthFlowAttempt(
                    flow: flow.providerPresentation, client: McpFlowClient(client: client),
                    serverId: serverId, serverName: serverName, providerName: name
                )
                signIn.adopt(attempt, scopeId: scopeId)
            } catch {
                self?.error = error.localizedDescription
            }
            self?.busy = false
        }
    }
}
