import UIKit

/// Model Providers for the visible server (route `.modelProviders`): the
/// connected providers with their usage, the ones still available, sign-in
/// flows, and API keys. The host switcher in the bar changes the server; this
/// screen follows it and reloads. A live sign-in stays with the server that
/// started it.
///
/// Usage reloads on appearance, pull to refresh, a return to the foreground,
/// and after a credential change, so the even-pace tick on each bar reflects
/// the current time.
@MainActor
final class ModelProvidersViewController: UIViewController, UICollectionViewDelegate {
    let target: ModelProvidersNavTarget

    private enum Section: Hashable {
        case signInAttempt, loading, connected, available, error
    }

    private enum Item: Hashable {
        case signInAttempt
        case loading
        case onboarding
        case provider(String)
        case allConnected
        case error
    }

    private let root: AppRootEnvironment
    private let collectionView = ControlScreenList.makeCollectionView()
    private let refreshControl = UIRefreshControl()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var changedRows = ChangedRows<Item>()
    private var switcher: SessionListServerSwitcher?
    private var switcherServerId: String?
    private var foregroundObserver: NSObjectProtocol?
    private var hasAppeared = false

    // Host-local state, reset when the visible server changes.
    private var loadedServerId: String?
    private var statuses: [ProviderAuthProviderStatus] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var setupState: ProviderSetupState = .unknown {
        didSet { setNeedsUpdateProperties() }
    }
    private var quotas: ProviderQuotasInfo? {
        didSet { setNeedsUpdateProperties() }
    }
    private var errorMessage: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var actionInFlightId: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var loadGeneration = 0

    /// Retained after its sheet closes, so a live sign-in stays reachable.
    private var flowAttempt: ProviderAuthFlowAttempt? {
        didSet { setNeedsUpdateProperties() }
    }
    private weak var flowSheet: ProviderSignInViewController? {
        didSet { setNeedsUpdateProperties() }
    }
    private weak var apiKeySheet: ProviderAPIKeyViewController?
    /// The attempt's last settled state, so settling reloads the providers once.
    private var attemptWasSettled = false

    /// Fixture data that replaces the server load (screenshot preview only).
    private let fixture: (statuses: [ProviderAuthProviderStatus], quotas: ProviderQuotasInfo)?

    init(target: ModelProvidersNavTarget, root: AppRootEnvironment) {
        self.target = target
        self.root = root
        fixture = nil
        super.init(nibName: nil, bundle: nil)
        setUp()
    }

    #if DEBUG
    /// Screenshot harness entry: fixture providers and usage, no server load.
    init(
        target: ModelProvidersNavTarget,
        root: AppRootEnvironment,
        statuses: [ProviderAuthProviderStatus],
        quotas: ProviderQuotasInfo
    ) {
        self.target = target
        self.root = root
        fixture = (statuses, quotas)
        super.init(nibName: nil, bundle: nil)
        setUp()
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setUp() {
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
        title = HostSwitcherDestination.modelProviders.title
    }

    private var coordinator: ConnectionCoordinator { root.coordinator }
    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    /// The visible host: the active server, else the one this route opened for.
    private var server: PairedServer? {
        ServerSelection.resolveVisible(
            activeId: coordinator.activeServerId,
            frozenId: target.serverId,
            from: coordinator.serverStore.servers
        )
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true, footers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "server.modelProviders.list"
        collectionView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        ModelProvidersList.pinReadable(collectionView, in: view, maxWidth: IPadReadableContentWidth.detail)
        installDataSource()
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        resumeFlowPollingIfLive()
        // Usage drifts while the screen is away; the first load starts with the
        // host in updateProperties.
        if hasAppeared, loadedServerId != nil { reload() }
        hasAppeared = true
        // A cancelled interactive pop appears again without disappearing.
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loadedServerId != nil else { return }
                self.resumeFlowPollingIfLive()
                self.reload()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        flowAttempt?.stopPolling()
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        guard let server else {
            loadedServerId = nil
            installSwitcher(nil)
            collectionView.isHidden = true
            var unavailable = ControlScreenList.unavailable(
                "Server Unavailable",
                systemImage: "server.rack",
                description: "This paired server is no longer available.",
                palette: palette
            )
            unavailable.background.backgroundColor = root.themeStore.backgroundColor
            contentUnavailableConfiguration = unavailable
            return
        }
        collectionView.isHidden = false
        contentUnavailableConfiguration = nil
        installSwitcher(server)
        if loadedServerId != server.id {
            switchHost(to: server.id)
        }
        // A sign-in that settles changes what the server has; show it.
        let settled = flowAttempt?.isSettled ?? false
        if settled, !attemptWasSettled, let attempt = flowAttempt {
            reloadIfVisible(serverId: attempt.serverId)
        }
        attemptWasSettled = settled
        applySnapshot()
    }

    // MARK: - Bar

    private func installSwitcher(_ server: PairedServer?) {
        guard let server else {
            switcher = nil
            ControlScreenList.setBarItems(trailing: [], leading: [], on: navigationItem)
            return
        }
        let joinsRail = SessionListBarItems.joinsRail(traitCollection)
        let model = HostSwitcherModel(
            coordinator: coordinator,
            serverStore: coordinator.serverStore,
            navigation: root.navigation,
            current: server,
            destination: .modelProviders
        )
        if let switcher, switcher.joinsRail == joinsRail {
            switcher.update(model)
        } else {
            let made = SessionListServerSwitcher(model: model, joinsRail: joinsRail)
            switcher = made
            let item = joinsRail ? SessionListBarItems.railItem(made.item, priority: .keep) : made.item
            ControlScreenList.setBarItems(trailing: [item], leading: [], on: navigationItem)
        }
        if switcherServerId != server.id {
            switcherServerId = server.id
            // Once per connection: a known value is never refetched.
            Task { await model.loadServerMetricsEnabled() }
        }
    }

    // MARK: - Data

    /// Host-local state resets on a host switch. A live sign-in stays: it is
    /// bound to its own server's client and keeps polling.
    private func switchHost(to serverId: String) {
        loadedServerId = serverId
        statuses = []
        setupState = .unknown
        quotas = nil
        errorMessage = nil
        if let apiKeySheet { Router.finish(apiKeySheet) }
        reload()
    }

    private func reload() {
        Task { await load() }
    }

    private func refresh() {
        Task {
            await load()
            refreshControl.endRefreshing()
        }
    }

    private func reloadIfVisible(serverId: String) {
        guard serverId == loadedServerId else { return }
        reload()
    }

    /// Statuses and usage together. A load for a host that is no longer
    /// visible, or that a newer load replaced, is dropped.
    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if let fixture {
            statuses = fixture.statuses
            setupState = ProviderSetupState(providerStatuses: fixture.statuses)
            quotas = fixture.quotas
            return
        }
        guard let serverId = loadedServerId else { return }
        let isCurrent = { [weak self] in self?.loadGeneration == generation && self?.loadedServerId == serverId }
        guard let client = await coordinator.apiClientReady(for: serverId) else {
            guard isCurrent() else { return }
            setupState = .unavailable
            errorMessage = "Unable to prepare server transport"
            return
        }
        async let fetchedQuotas = try? await client.fetchProviderQuotas()
        let result: Result<[ProviderAuthProviderStatus], Error>
        do {
            result = .success(try await client.listProviderAuthStatus())
        } catch {
            result = .failure(error)
        }
        let loadedQuotas = await fetchedQuotas
        guard isCurrent() else { return }
        switch result {
        case .success(let loaded):
            statuses = loaded
            setupState = ProviderSetupState(providerStatuses: loaded)
            errorMessage = nil
        case .failure(let error):
            statuses = []
            setupState = .unavailable
            errorMessage = "Failed to load provider status: \(error.localizedDescription)"
        }
        quotas = loadedQuotas
    }

    // MARK: - List

    private var connectedProviders: [ProviderAuthProviderStatus] {
        statuses.filter(\.authenticated).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var availableProviders: [ProviderAuthProviderStatus] {
        statuses.filter { !$0.authenticated }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func quota(for provider: ProviderAuthProviderStatus) -> ProviderQuota? {
        guard provider.authenticated,
              let quota = quotas?.quota(forProviderId: provider.id),
              quota.hasAnyUsageWindow || quota.error != nil || quota.planLabel != nil || !quota.creditLines.isEmpty
        else { return nil }
        return quota
    }

    private var hasLiveSignIn: Bool {
        flowAttempt.map { !$0.isSettled } ?? false
    }

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if flowAttempt != nil, flowSheet == nil {
            snapshot.appendSections([.signInAttempt])
            snapshot.appendItems([.signInAttempt], toSection: .signInAttempt)
        }
        let presentation = ProviderConfigurationPresentation(state: setupState)
        if presentation.showsLoading {
            snapshot.appendSections([.loading])
            snapshot.appendItems([.loading], toSection: .loading)
        } else if presentation.showsProviderSections {
            snapshot.appendSections([.connected, .available])
            let connected = connectedProviders.map { Item.provider($0.id) }
            snapshot.appendItems(connected.isEmpty ? [.onboarding] : connected, toSection: .connected)
            let available = availableProviders.map { Item.provider($0.id) }
            snapshot.appendItems(available.isEmpty ? [.allConnected] : available, toSection: .available)
        }
        if errorMessage != nil {
            snapshot.appendSections([.error])
            snapshot.appendItems([.error], toSection: .error)
        }
        // Only the rows whose inputs changed. A refreshed row keeps its ⋯ menu
        // when the menu's choices are the same (`ProviderRowContentView`).
        let current = dataSource.snapshot()
        let themeID = root.themeStore.activeThemeID
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { AnyHashable([AnyHashable(themeID)] + rowInputs($0)) }
        snapshot.reconfigureItems(changed.filter { current.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
        // The footer carries the usage time; supplementary views do not reconfigure.
        if let section = snapshot.indexOfSection(.connected),
           let footer = collectionView.supplementaryView(
               forElementKind: UICollectionView.elementKindSectionFooter,
               at: IndexPath(item: 0, section: section)
           ) as? UICollectionViewListCell {
            footer.contentConfiguration = connectedFooter()
        }
    }

    private func rowInputs(_ item: Item) -> [AnyHashable] {
        switch item {
        case .signInAttempt:
            guard let attempt = flowAttempt else { return [] }
            return [ObjectIdentifier(attempt), attempt.flow.status.rawValue, attempt.isGone, attempt.isSettled, loadedServerId]
        case .provider(let id):
            guard let provider = statuses.first(where: { $0.id == id }) else { return [] }
            let quota = quota(for: provider)
            return [
                provider.name, provider.authenticated, provider.credentialType?.rawValue, provider.expiresAt,
                provider.maskedKey, provider.supportsApiKey, provider.oauth != nil,
                quota?.fetchedAt, quota?.error, actionInFlightId == id, hasLiveSignIn, actionInFlightId != nil,
            ]
        case .error:
            return [errorMessage]
        case .loading, .onboarding, .allConnected:
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
            content.text = switch self?.dataSource?.sectionIdentifier(for: indexPath.section) {
            case .connected: "Connected"
            case .available: "Available"
            default: nil
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            view.contentConfiguration = dataSource?.sectionIdentifier(for: indexPath.section) == .connected
                ? connectedFooter()
                : UIListContentConfiguration.footer()
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

    /// When the usage on screen was read, so a stale bar is recognizable.
    private func connectedFooter() -> UIListContentConfiguration {
        var content = UIListContentConfiguration.footer()
        let shown = connectedProviders.compactMap { quota(for: $0) }
        if !shown.isEmpty, let fetchedAt = quotas?.fetchedAt {
            let date = Date(timeIntervalSince1970: TimeInterval(fetchedAt) / 1000)
            let now = Date()
            let hasTick = shown.contains { $0.windows.contains { $0.evenPaceRemainingFraction(at: now) != nil } }
            content.text = "Usage as of \(date.formatted(date: .omitted, time: .shortened))."
                + (hasTick ? " The tick on each bar marks an even pace." : "")
        }
        return content
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        switch item {
        case .signInAttempt:
            configureAttemptRow(cell, palette: palette)
        case .loading:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.loading("Loading providers…")
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .onboarding:
            ControlScreenList.staticRow(cell, identifier: "server.modelProviders.onboarding")
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 12, leading: 0, bottom: 12, trailing: 0)) {
                ControlRowViews.stack([
                    ControlRowViews.symbolLabel(
                        "Connect a model provider",
                        systemImage: "key.fill",
                        style: .headline,
                        color: UIColor(palette.fg)
                    ),
                    ControlRowViews.label(
                        "Finish setup by signing in or adding an API key. This unlocks model selection for sessions on this server.",
                        style: .footnote,
                        color: UIColor(palette.comment)
                    ),
                ], spacing: 8)
            }
        case .provider(let id):
            ControlScreenList.staticRow(cell)
            guard let provider = statuses.first(where: { $0.id == id }) else { return }
            cell.contentConfiguration = ProviderRowConfiguration(
                provider: provider,
                quota: quota(for: provider),
                action: rowAction(for: provider),
                themeID: root.themeStore.activeThemeID,
                now: Date()
            )
        case .allConnected:
            ControlScreenList.staticRow(cell)
            var content = UIListContentConfiguration.cell()
            content.text = "All providers are currently connected"
            content.textProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
        case .error:
            ControlScreenList.staticRow(cell, identifier: "server.modelProviders.error")
            let message = errorMessage
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(message, style: .body, color: UIColor(palette.red))
            }
        }
    }

    private func configureAttemptRow(_ cell: SidebarListCell, palette: ThemePalette) {
        guard let attempt = flowAttempt else { return }
        let status = attempt.isGone
            ? "No longer on the server"
            : ProviderAuthFlowPresentation.statusText(attempt.flow.status)
        let summary = attempt.serverId == loadedServerId ? status : "\(status) \u{00B7} \(attempt.serverName)"
        let title = "Sign in to \(attempt.providerName)"
        let trailing = attempt.isSettled ? "View" : "Return"
        ControlScreenList.buttonRow(
            cell,
            identifier: "server.modelProviders.signInAttempt",
            label: title,
            value: summary
        ) { [weak self] in
            self?.presentFlowSheet()
        }
        let providerId = attempt.flow.providerId
        let themeID = root.themeStore.activeThemeID
        cell.contentConfiguration = ControlViewContent {
            let icon = UIImageView(image: ComposerProviderIconRenderer.image(
                provider: providerId,
                size: 18,
                colors: SessionRowStyle.for(themeID).colors
            ))
            icon.contentMode = .scaleAspectFit
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
            ])
            let text = ControlRowViews.stack([
                ControlRowViews.label(title, style: .body, color: UIColor(palette.fg)),
                ControlRowViews.label(summary, style: .caption1, color: UIColor(palette.comment)),
            ], spacing: 2)
            let action = ControlRowViews.label(trailing, style: .subheadline, color: UIColor(palette.blue), lines: 1)
            action.setContentCompressionResistancePriority(.required, for: .horizontal)
            action.setContentHuggingPriority(.required, for: .horizontal)
            return ControlRowViews.stack([icon, text, ControlRowViews.spacer(), action], axis: .horizontal, spacing: 12, alignment: .center)
        }
    }

    // MARK: - Row actions

    private func rowAction(for provider: ProviderAuthProviderStatus) -> ProviderRowAction {
        if actionInFlightId == provider.id { return .busy }
        let signIn = UIAction(
            title: provider.authenticated ? "Sign In Again" : "Sign In",
            attributes: hasLiveSignIn ? .disabled : []
        ) { [weak self] _ in self?.askWhereToSignIn(provider) }
        let apiKey = UIAction(title: provider.credentialType == .apiKey ? "Replace API Key" : "Set API Key") { [weak self] _ in
            self?.presentAPIKeyEditor(for: provider)
        }
        if provider.authenticated {
            var items: [UIMenuElement] = []
            if provider.oauth != nil { items.append(signIn) }
            if provider.supportsApiKey { items.append(apiKey) }
            items.append(UIAction(title: "Sign Out", image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive) { [weak self] _ in
                self?.confirmSignOut(provider)
            })
            return .menu(UIMenu(children: items))
        }
        let idle = actionInFlightId == nil
        if provider.oauth != nil, provider.supportsApiKey {
            return .connect(title: "Connect", enabled: idle, menu: UIMenu(children: [signIn, apiKey]), action: nil)
        }
        if provider.oauth != nil {
            return .connect(title: "Sign In", enabled: idle && !hasLiveSignIn, menu: nil) { [weak self] in
                self?.askWhereToSignIn(provider)
            }
        }
        if provider.supportsApiKey {
            return .connect(title: apiKey.title, enabled: idle, menu: nil) { [weak self] in
                self?.presentAPIKeyEditor(for: provider)
            }
        }
        return .connect(title: "Connect", enabled: false, menu: nil, action: nil)
    }

    /// The row's cell, to anchor a sheet that pops over on iPad.
    private func anchor(for provider: ProviderAuthProviderStatus) -> UIView {
        dataSource?.indexPath(for: .provider(provider.id)).flatMap(collectionView.cellForItem(at:)) ?? view
    }

    private func presentActionSheet(_ sheet: UIAlertController, anchor: UIView) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        Router.topPresenter(from: self).present(sheet, animated: true)
    }

    /// Where the sign-in page opens, asked before any flow starts.
    private func askWhereToSignIn(_ provider: ProviderAuthProviderStatus) {
        guard !hasLiveSignIn else { return }
        let sheet = UIAlertController(
            title: "Sign in to \(provider.name)",
            message: "Choose where the sign-in page opens. On server opens a browser on the server's own desktop.",
            preferredStyle: .actionSheet
        )
        let phone = UIAlertAction(title: "On this iPhone", style: .default) { [weak self] _ in
            self?.startFlow(provider, launchMode: .phoneBrowser)
        }
        sheet.addAction(phone)
        sheet.addAction(UIAlertAction(title: "On server", style: .default) { [weak self] _ in
            self?.startFlow(provider, launchMode: .serverBrowser)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.preferredAction = phone
        presentActionSheet(sheet, anchor: anchor(for: provider))
    }

    private func confirmSignOut(_ provider: ProviderAuthProviderStatus) {
        let sheet = UIAlertController(
            title: "Sign out of \(provider.name)?",
            message: "This removes the server's saved key or sign-in for \(provider.name). You will need to sign in again to use it.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
            self?.signOut(provider)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentActionSheet(sheet, anchor: anchor(for: provider))
    }

    private func presentAPIKeyEditor(for provider: ProviderAuthProviderStatus) {
        let editor = ProviderAPIKeyViewController(provider: provider, root: root) { [weak self] key in
            self?.saveAPIKey(key, for: provider)
        }
        apiKeySheet = editor
        Router.present(editor, presentation: .sheet.inNavigation(), from: self)
    }

    // MARK: - Credential changes

    private func apiClient() -> APIClient? {
        guard let serverId = loadedServerId else { return nil }
        return coordinator.apiClient(for: serverId)
    }

    private func saveAPIKey(_ key: String, for provider: ProviderAuthProviderStatus) {
        guard let api = apiClient(), let editor = apiKeySheet else {
            apiKeySheet?.errorMessage = "Invalid server address"
            return
        }
        actionInFlightId = provider.id
        editor.isSaving = true
        editor.errorMessage = nil
        Task { [weak self, weak editor] in
            defer {
                self?.actionInFlightId = nil
                editor?.isSaving = false
            }
            guard await AppLockService.shared.authorizeProtectedAction(
                reason: String(localized: "Save the \(provider.name) API key")
            ) else { return }
            do {
                try await api.setProviderAPIKey(providerId: provider.id, key: key)
                if let editor { Router.finish(editor) }
                await self?.load()
            } catch {
                editor?.errorMessage = "Failed to save API key: \(error.localizedDescription)"
            }
        }
    }

    private func signOut(_ provider: ProviderAuthProviderStatus) {
        guard let api = apiClient() else {
            errorMessage = "Invalid server address"
            return
        }
        actionInFlightId = provider.id
        Task { [weak self] in
            defer { self?.actionInFlightId = nil }
            guard await AppLockService.shared.authorizeProtectedAction(
                reason: String(localized: "Remove the \(provider.name) credential")
            ) else { return }
            do {
                try await api.removeProviderCredential(providerId: provider.id)
                self?.errorMessage = nil
                await self?.load()
            } catch {
                self?.errorMessage = "Failed to remove credential: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Sign-in flow

    private func startFlow(_ provider: ProviderAuthProviderStatus, launchMode: ProviderAuthFlowSnapshot.LaunchMode) {
        guard !hasLiveSignIn, let server, let api = apiClient() else {
            if !hasLiveSignIn { errorMessage = "Invalid server address" }
            return
        }
        actionInFlightId = provider.id
        Task { [weak self] in
            defer { self?.actionInFlightId = nil }
            guard await AppLockService.shared.authorizeProtectedAction(
                reason: String(localized: "Sign in to \(provider.name)")
            ) else { return }
            do {
                let flow = try await api.startProviderAuthFlow(providerId: provider.id, launchMode: launchMode)
                guard let self else { return }
                flowAttempt?.stopPolling()
                let attempt = ProviderAuthFlowAttempt(
                    flow: flow,
                    client: api,
                    serverId: server.id,
                    serverName: server.name,
                    providerName: provider.name
                )
                attemptWasSettled = false
                flowAttempt = attempt
                errorMessage = nil
                attempt.startPolling()
                presentFlowSheet()
            } catch {
                self?.errorMessage = "Failed to start login: \(error.localizedDescription)"
            }
        }
    }

    private func presentFlowSheet() {
        guard let attempt = flowAttempt, flowSheet == nil else { return }
        let sheet = ProviderSignInViewController(
            attempt: attempt,
            root: root,
            visibleServerId: { [weak self] in self?.loadedServerId },
            onDone: { [weak self] in self?.closeFlowSheet() },
            onCancel: { [weak self] in self?.cancelFlow(attempt) }
        )
        flowSheet = sheet
        Router.present(sheet, presentation: .sheet.inNavigation(), from: self) { [weak self] in
            self?.flowSheetDismissed(attempt)
        }
    }

    private func resumeFlowPollingIfLive() {
        guard let attempt = flowAttempt, !attempt.isSettled else { return }
        attempt.startPolling()
    }

    /// Cancel Sign-In is the only way to end a live attempt. The sheet closes
    /// only after the server acknowledges; on failure it stays open with the error.
    private func cancelFlow(_ attempt: ProviderAuthFlowAttempt) {
        Task { [weak self] in
            guard await attempt.cancel(reason: "Cancelled by user"), let self else { return }
            // A login can commit just before the cancel lands; show the real state.
            reloadIfVisible(serverId: attempt.serverId)
            if flowAttempt === attempt { closeFlowSheet() }
        }
    }

    private func closeFlowSheet() {
        flowAttempt?.stopPolling()
        flowAttempt = nil
        if let flowSheet { Router.finish(flowSheet) }
    }

    /// Dismissing never cancels. A live attempt keeps polling and stays
    /// reachable from the list; a settled one is cleared.
    private func flowSheetDismissed(_ attempt: ProviderAuthFlowAttempt) {
        flowSheet = nil
        guard flowAttempt === attempt, !attempt.sheetDismissed() else { return }
        flowAttempt = nil
    }
}

/// Layout shared by Model Providers and its sheets.
@MainActor
enum ModelProvidersList {
    /// The list at a readable width, centered, on iPad; full width on iPhone.
    static func pinReadable(_ collectionView: UICollectionView, in view: UIView, maxWidth: CGFloat) {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        let fillWidth = collectionView.widthAnchor.constraint(equalTo: view.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            collectionView.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            fillWidth,
        ])
    }
}
