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
///
/// A `ListScreenController`: the base owns the list, the section headings and
/// footer, and the load on appearance and pull to refresh. This page keeps the
/// rows, the bar's host switcher, and the sign-in and API key sheets it opens.
@MainActor
final class ModelProvidersViewController: ListScreenController<ModelProvidersViewController.Section, ModelProvidersViewController.Item> {
    let target: ModelProvidersNavTarget

    enum Section: Hashable, Sendable {
        case signInAttempt, state, connected, available, error
    }

    enum Item: Hashable, Sendable {
        case signInAttempt
        case onboarding
        case provider(String)
        case allConnected
        case error
    }

    private let root: AppRootEnvironment
    private var switcher: SessionListServerSwitcher?
    private var switcherServerId: String?
    private var foregroundObserver: NSObjectProtocol?

    // Host-local state, reset when the visible server changes.
    private var statuses: [ProviderAuthProviderStatus] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var setupState: ProviderSetupState = .unknown {
        didSet { setNeedsUpdateProperties() }
    }
    private var quotas: ProviderQuotasInfo? {
        didSet { setNeedsUpdateProperties() }
    }
    /// A failure of something the page did (a credential change, a sign-in). A
    /// failed load is the base's `loadFailure`.
    private var errorMessage: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var actionInFlightId: String? {
        didSet { setNeedsUpdateProperties() }
    }

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

    init(target: ModelProvidersNavTarget, root: AppRootEnvironment) {
        self.target = target
        self.root = root
        super.init(
            title: HostSwitcherDestination.modelProviders.title,
            listIdentifier: "server.modelProviders.list",
            headers: true, footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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
        // The bar's switcher joins the Duo's rail, so the bar is laid out again
        // when the size classes change.
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Usage drifts while the screen is away; the base loads it on the way back.
        resumeFlowPollingIfLive()
        // A cancelled interactive pop appears again without disappearing.
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.server != nil else { return }
                self.resumeFlowPollingIfLive()
                self.setNeedsLoad()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        flowAttempt?.stopPolling()
        super.viewDidDisappear(animated)
    }

    override func updateProperties() {
        let server = server
        installSwitcher(server)
        // A sign-in that settles changes what the server has; show it.
        let settled = flowAttempt?.isSettled ?? false
        if settled, !attemptWasSettled, let attempt = flowAttempt {
            reloadIfVisible(serverId: attempt.serverId)
        }
        attemptWasSettled = settled
        super.updateProperties()
    }

    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The visible server: it owns the providers and the usage.
    override func loadSubject() -> AnyHashable? { AnyHashable(server?.id) }

    /// Host-local state belongs to one server: a switch starts that server's
    /// rows from nothing and loads them again. A live sign-in stays: it is bound
    /// to its own server's client and keeps polling.
    override func subjectDidChange() {
        statuses = []
        setupState = .unknown
        quotas = nil
        errorMessage = nil
        if let apiKeySheet { Router.finish(apiKeySheet) }
    }

    // MARK: - Bar

    private func installSwitcher(_ server: PairedServer?) {
        guard let server else {
            switcher = nil
            ListScreen.setBarItems(trailing: [], leading: [], on: navigationItem)
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
            ListScreen.setBarItems(trailing: [item], leading: [], on: navigationItem)
        }
        if switcherServerId != server.id {
            switcherServerId = server.id
            // Once per connection: a known value is never refetched.
            Task { await model.loadServerMetricsEnabled() }
        }
    }

    // MARK: - Data

    /// The visible server's providers and usage: the base runs it on every
    /// appearance, on pull to refresh, when the app becomes active, and when the
    /// server changes; a credential change or a settled sign-in asks for it
    /// through `setNeedsLoad()`.
    override func load() async throws {
        guard let serverId = server?.id else { return }
        guard let client = await coordinator.apiClientReady(for: serverId) else {
            setupState = .unavailable
            throw LoadFailure(String(localized: "Unable to prepare the server connection"))
        }
        async let fetchedQuotas = try? await client.fetchProviderQuotas()
        let loaded: [ProviderAuthProviderStatus]
        do {
            loaded = try await client.listProviderAuthStatus()
        } catch {
            // A load this page cancelled (it left, or a newer one replaced it)
            // shows no failure: the providers it had stay.
            guard !Task.isCancelled, !error.isLoadCancellation else { return }
            statuses = []
            setupState = .unavailable
            throw LoadFailure(String(localized: "Failed to load provider status: \(error.localizedDescription)"))
        }
        guard !Task.isCancelled else { return }
        statuses = loaded
        setupState = ProviderSetupState(providerStatuses: loaded)
        errorMessage = nil
        // Statuses show as soon as they arrive; usage (provider round-trips on
        // the server, often seconds) fills in behind them, and a refresh that
        // cannot read it keeps the usage already on screen.
        if let loadedQuotas = await fetchedQuotas, !Task.isCancelled { quotas = loadedQuotas }
    }

    private func reloadIfVisible(serverId: String) {
        guard serverId == server?.id else { return }
        setNeedsLoad()
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

    override func sections() -> [ListSection<Section, Item>] {
        // Without a server there is nothing to list: the page is its state.
        guard server != nil else { return [] }
        var sections: [ListSection<Section, Item>] = []
        if flowAttempt != nil, flowSheet == nil {
            sections.append(ListSection(.signInAttempt, items: [.signInAttempt]))
        }
        // The load's own state, and its Retry: the base draws it in this place.
        sections.append(ListSection(.state, items: []))
        if ProviderConfigurationPresentation(state: setupState).showsProviderSections {
            let connected = connectedProviders.map { Item.provider($0.id) }
            sections.append(ListSection(
                .connected,
                header: "Connected",
                footer: connectedFooterText,
                items: connected.isEmpty ? [.onboarding] : connected
            ))
            let available = availableProviders.map { Item.provider($0.id) }
            sections.append(ListSection(
                .available, header: "Available", items: available.isEmpty ? [.allConnected] : available
            ))
        }
        // A credential change or a sign-in that failed is the page's own error,
        // not the load's: it is a line of its own, with nothing to retry.
        if errorMessage != nil {
            sections.append(ListSection(.error, items: [.error]))
        }
        return sections
    }

    /// "Connected" and "Available" carry a heading; the sign-in attempt, the
    /// state and error rows do not.
    override func showsHeader(for section: Section) -> Bool {
        section == .connected || section == .available
    }

    /// The load's own state, in the list: a compact loading row until the
    /// providers are here, and one failed row with Retry.
    override func stateSection() -> Section? { .state }

    /// Nothing loaded yet: the page does not know what the server has.
    override func hasContent() -> Bool { setupState != .unknown }

    override func loadingCaption() -> String? { String(localized: "Loading providers…") }

    /// A page with no server says so over the whole screen instead of in a row.
    override func wholeScreenState() -> LoadState? {
        server == nil ? .serverUnavailable : nil
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .signInAttempt:
            guard let attempt = flowAttempt else { return AnyHashable(0) }
            return AnyHashable([
                AnyHashable(ObjectIdentifier(attempt)), AnyHashable(attempt.flow.status.rawValue),
                AnyHashable(attempt.isGone), AnyHashable(attempt.isSettled), AnyHashable(server?.id),
            ])
        case .provider(let id):
            guard let provider = statuses.first(where: { $0.id == id }) else { return AnyHashable(0) }
            let quota = quota(for: provider)
            return AnyHashable([
                AnyHashable(provider.name), AnyHashable(provider.authenticated),
                AnyHashable(provider.credentialType?.rawValue), AnyHashable(provider.expiresAt),
                AnyHashable(provider.maskedKey), AnyHashable(provider.supportsApiKey), AnyHashable(provider.oauth != nil),
                AnyHashable(quota?.fetchedAt), AnyHashable(quota?.error),
                AnyHashable(actionInFlightId == id), AnyHashable(hasLiveSignIn), AnyHashable(actionInFlightId != nil),
            ])
        case .error:
            return AnyHashable([AnyHashable(errorMessage)])
        case .onboarding, .allConnected:
            return AnyHashable(0)
        }
    }

    /// When the usage on screen was read, so a stale bar is recognizable. It is
    /// the connected group's footer, rebuilt on every pass.
    private var connectedFooterText: String? {
        let shown = connectedProviders.compactMap { quota(for: $0) }
        guard !shown.isEmpty, let fetchedAt = quotas?.fetchedAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(fetchedAt) / 1000)
        let hasTick = shown.contains { $0.windows.contains { $0.evenPaceRemainingFraction(at: Date()) != nil } }
        return "Usage as of \(date.formatted(date: .omitted, time: .shortened))."
            + (hasTick ? " The tick on each bar marks an even pace." : "")
    }

    // MARK: - Rows

    /// The page's rows are the kit's theme cards, filled by
    /// `configureCard(_:item:)`.
    override var rowStyle: ListRowStyle { .card }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        switch item {
        case .signInAttempt:
            configureAttemptRow(cell, palette: palette)
        case .onboarding:
            ListScreen.staticRow(cell, identifier: "server.modelProviders.onboarding")
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
            ListScreen.staticRow(cell)
            guard let provider = statuses.first(where: { $0.id == id }) else { return }
            cell.contentConfiguration = ProviderRowConfiguration(
                provider: provider,
                quota: quota(for: provider),
                action: rowAction(for: provider),
                themeID: root.themeStore.activeThemeID,
                now: Date()
            )
        case .allConnected:
            ListScreen.staticRow(cell)
            var content = UIListContentConfiguration.cell()
            content.text = "All providers are currently connected"
            content.textProperties.color = UIColor(palette.comment)
            cell.contentConfiguration = content
        case .error:
            ListScreen.staticRow(cell, identifier: "server.modelProviders.error")
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
        let summary = attempt.serverId == server?.id ? status : "\(status) \u{00B7} \(attempt.serverName)"
        let title = "Sign in to \(attempt.providerName)"
        let trailing = attempt.isSettled ? "View" : "Return"
        ListScreen.buttonRow(
            cell,
            identifier: "server.modelProviders.signInAttempt",
            label: title,
            value: summary
        ) { [weak self] in
            self?.presentFlowSheet()
        }
        let providerId = attempt.flow.providerId
        cell.contentConfiguration = ControlViewContent {
            let icon = UIImageView(image: EntityIcon.image(.provider(providerId), size: 18))
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
    private func anchor(for provider: ProviderAuthProviderStatus) -> UIView? {
        indexPath(for: .provider(provider.id)).flatMap(collectionView.cellForItem(at:))
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
        AlertAnchor.present(sheet, from: self, anchor: anchor(for: provider))
    }

    private func confirmSignOut(_ provider: ProviderAuthProviderStatus) {
        Confirmation(
            title: "Sign out of \(provider.name)?",
            message: "This removes the server's saved key or sign-in for \(provider.name). You will need to sign in again to use it.",
            actionTitle: "Sign Out"
        ).present(from: self, anchor: anchor(for: provider)) { [weak self] in
            self?.signOut(provider)
        }
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
        guard let serverId = server?.id else { return nil }
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
                self?.setNeedsLoad()
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
                self?.setNeedsLoad()
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
            visibleServerId: { [weak self] in self?.server?.id },
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
