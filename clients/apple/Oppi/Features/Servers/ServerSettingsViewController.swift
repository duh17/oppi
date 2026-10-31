import ActivityKit
import UIKit

/// Server Settings for one server: a summary of it, one index row per focused
/// page, its badge, the Mobile Output Guide, Server Metrics, and Durable Sessions
/// switches, this device's Notifications for it, its lock, and Remove Server.
///
/// The page is pinned to the server it was made for: its `SettingsStore`, its
/// `ServerSettingsModel`, its Notifications controller, the switcher's current
/// server, and every action closure use that server, never the visible one.
/// `ServerSettingsRouteViewController` shows the visible server's page and
/// replaces it when the visible server changes; a page never follows a switch.
///
/// The page scope is the server (every device on it). Five sections are not:
/// Notifications (this device's, kept for this server), Badge Icon, Start Sessions
/// as Durable, Lock, and Remove Server (this device only). Each says so in its footer.
@MainActor
final class ServerSettingsViewController: ListScreenController<ServerSettingsViewController.Section, ServerSettingsViewController.Item> {
    enum Section: Hashable, Sendable {
        case summary, pages, badge, mobileOutputGuide, serverMetrics, durableSessions, startDurable
        case notifications, lock, remove
    }

    enum Item: Hashable, Sendable {
        case summary, summaryError
        case modelProviders, workspaces, dictionary, pairedDevices, about
        case mobileOutputGuide, serverMetrics, durableSessions, startDurable, settingFailure(String)
        case pushSwitch, pushWorking, pushError
        case liveActivitySwitch, liveActivityWorking, liveActivityError, liveActivitySystemOff
        case badge, lock, remove
    }

    /// The server this page is pinned to, as it was when the page was made.
    let server: PairedServer
    let model: ServerSettingsModel
    let notifications: ServerNotificationsController
    private let root: AppRootEnvironment
    private let locks = ScopedLockService.shared
    private let switcher = PinnedServerSwitcher()
    private var pushed: [WeakScreen] = []
    private struct WeakScreen {
        weak var screen: UIViewController?
    }
    private var loadTask: Task<Void, Never>?
    private var hasAppeared = false
    /// Counts the redraws a switch needs when its state did not change (a cancelled
    /// save, a refused unlock), so the switch returns to what the state says.
    private var toggleRevision = 0

    /// `model` is for the screenshot harness and tests: a model that is already
    /// loaded (or never loads). The app makes the server's own.
    init(server: PairedServer, root: AppRootEnvironment, model: ServerSettingsModel? = nil) {
        self.server = server
        self.root = root
        self.model = model ?? ServerSettingsModel(coordinator: root.coordinator, serverId: server.id)
        notifications = ServerNotificationsController(serverId: server.id)
        super.init(
            title: HostSwitcherDestination.serverSettings.title,
            listIdentifier: "server.details.list",
            scope: .server(server.name),
            settings: root.coordinator.settings(for: server.id),
            headers: true,
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    private var coordinator: ConnectionCoordinator { root.coordinator }

    /// The pinned server as the pairing list has it now (a new badge icon or name).
    private var current: PairedServer { coordinator.serverStore.server(for: server.id) ?? server }

    /// The pages this page pushed and that are still on screen: pinned to this server, so
    /// the route closes them when it replaces this page.
    var pushedScreens: [UIViewController] { pushed.compactMap(\.screen) }

    /// Records a page this one pushed above itself.
    func track(_ screen: UIViewController?) {
        guard let screen else { return }
        pushed.removeAll { $0.screen == nil }
        pushed.append(WeakScreen(screen: screen))
    }

    /// The Server Settings route this page is shown in, which also owns the bar.
    private var route: ServerSettingsRouteViewController? { parent as? ServerSettingsRouteViewController }

    /// The navigation item the bar shows: the route's when this page is embedded in it.
    private var barItem: UINavigationItem { pinnedRouteNavigationItem }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task {
                await self?.model.load()
                // The page's own switch reads the store; a pull reads the document again.
                _ = await self?.settings?.reload(SettingsCatalog.serverMetricsEnabled)
                _ = await self?.settings?.reload(SettingsCatalog.mobileOutputGuideEnabled)
                _ = await self?.settings?.reload(SettingsCatalog.durableSessionsEnabled)
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
        loadTask = Task { [model] in await model.load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        // Another surface (the discovery card) may have turned push on.
        notifications.reload()
        // Another device may have changed a server setting while this page sat under one it
        // pushed. The first appearance already reads them.
        if hasAppeared, let settings {
            Task {
                _ = await settings.reload(SettingsCatalog.mobileOutputGuideEnabled)
                _ = await settings.reload(SettingsCatalog.serverMetricsEnabled)
                _ = await settings.reload(SettingsCatalog.durableSessionsEnabled)
            }
        }
        hasAppeared = true
        super.viewWillAppear(animated)
    }

    override func updateProperties() {
        super.updateProperties()
        updateBar()
    }

    // MARK: - Bar

    /// The switcher for the pinned server. A switch changes the visible server,
    /// and the route then replaces this page.
    private func updateBar() {
        switcher.update(
            server: current,
            destination: .serverSettings,
            root: root,
            traits: traitCollection,
            item: barItem
        )
    }

    // MARK: - Snapshot

    override func sections() -> [ListSection<Section, Item>] {
        let name = current.name
        var summary: [Item] = [.summary]
        if model.error != nil { summary.append(.summaryError) }

        var notificationItems: [Item] = []
        if relayHost != nil {
            notificationItems.append(.pushSwitch)
            if notifications.pushStatus == .working { notificationItems.append(.pushWorking) }
            if notifications.pushFailure != nil { notificationItems.append(.pushError) }
        }
        notificationItems.append(.liveActivitySwitch)
        if notifications.liveActivityStatus == .working { notificationItems.append(.liveActivityWorking) }
        if notifications.liveActivityStatus == .failed, notifications.liveActivityEnabled {
            notificationItems.append(.liveActivityError)
        }
        if notifications.liveActivityEnabled, !ActivityAuthorizationInfo().areActivitiesEnabled {
            notificationItems.append(.liveActivitySystemOff)
        }

        let serverSections: [ListSection<Section, Item>] = [
            ListSection(.summary, items: summary),
            ListSection(.pages, items: [.modelProviders, .workspaces, .dictionary, .pairedDevices, .about]),
            ListSection(
                .badge,
                footer: String(localized: "The badge color shows the connection: green connected, blue connecting, orange recovering, red offline."),
                scope: .device,
                items: [.badge]
            ),
            ListSection(
                .mobileOutputGuide,
                footer: SettingsCatalog.mobileOutputGuideEnabled.copy.footer,
                items: settingRows(SettingsCatalog.mobileOutputGuideEnabled, .mobileOutputGuide) { .settingFailure($0) }
            ),
            ListSection(
                .serverMetrics,
                footer: String(localized: "Off by default. When on, this server samples its CPU, memory, and disk every 30 seconds for the Server Metrics page, and keeps the samples for 30 days."),
                items: settingRows(SettingsCatalog.serverMetricsEnabled, .serverMetrics) { .settingFailure($0) }
            ),
            ListSection(
                .durableSessions,
                footer: SettingsCatalog.durableSessionsEnabled.copy.footer,
                items: settingRows(SettingsCatalog.durableSessionsEnabled, .durableSessions) { .settingFailure($0) }
            ),
        ]
        let deviceSections: [ListSection<Section, Item>] = [
            ListSection(
                .notifications,
                header: String(localized: "Notifications"),
                footer: ServerNotificationsSection.footer(
                    relayHost: relayHost,
                    relayRefusesThisDevice: ServerNotificationsSection.relayRefusesThisDevice,
                    pushEnabled: notifications.pushEnabled
                ),
                scope: .deviceOnServer(name),
                items: notificationItems
            ),
            ListSection(
                .lock,
                footer: ScopedLockToggleRow.footer(for: "this server and its workspaces and sessions"),
                scope: .device,
                items: [.lock]
            ),
            ListSection(
                .remove,
                footer: String(localized: "Removing a server only unpairs this device. It does not delete the server or its data."),
                scope: .device,
                items: [.remove]
            ),
        ]
        return serverSections + startDurableSection + deviceSections
    }

    /// This device's default engine, shown under the server's switch while it is on: it
    /// changes nothing on a server that offers no durable sessions.
    private var startDurableSection: [ListSection<Section, Item>] {
        guard settings?.read(SettingsCatalog.durableSessionsEnabled).current == true else { return [] }
        return [ListSection(
            .startDurable,
            footer: SettingsCatalog.startSessionsAsDurable.copy.footer,
            scope: .device,
            items: [.startDurable]
        )]
    }

    /// The device store, which holds Start Sessions as Durable.
    private var deviceSettings: SettingsStore { coordinator.deviceSettings }

    /// The host the server's push relay is on, known while the server is connected.
    private var relayHost: String? {
        coordinator.connection(for: server.id)?.pushRelay?.host()
    }

    /// The relay this device registered with names it while the server is offline or reconnecting.
    private var relayHostForConsent: String? {
        relayHost ?? PushRegistration.savedRelay(serverId: server.id)?.host()
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .summary:
            let state = HostSwitcherBadgeState.make(for: current, coordinator: coordinator)
            return AnyHashable([
                AnyHashable(current.name),
                AnyHashable(current.resolvedBadgeIcon),
                AnyHashable(String(describing: state)),
                AnyHashable(Self.connectionStatusTitle(for: current, coordinator: coordinator)),
                AnyHashable(String(describing: locks.badge(.server(server.id)))),
                AnyHashable(model.isLoading),
                AnyHashable(ThemeRuntimeState.currentThemeID()),
            ])
        case .summaryError:
            return AnyHashable(model.error ?? "")
        case .modelProviders:
            return AnyHashable([model.providerSummary, String(describing: model.providerSetupState)])
        case .workspaces:
            return AnyHashable(workspaceCount ?? "")
        case .pairedDevices:
            return AnyHashable(pairedDeviceCount ?? "")
        case .about:
            return AnyHashable(model.aboutSummary ?? "")
        case .dictionary, .liveActivityError, .liveActivitySystemOff, .badge:
            return AnyHashable(0)
        case .mobileOutputGuide:
            return settingInputs(SettingsCatalog.mobileOutputGuideEnabled)
        case .serverMetrics:
            return settingInputs(SettingsCatalog.serverMetricsEnabled)
        case .durableSessions:
            return settingInputs(SettingsCatalog.durableSessionsEnabled)
        case .startDurable:
            return settingInputs(SettingsCatalog.startSessionsAsDurable, store: deviceSettings)
        case .settingFailure(let id):
            return settingFailureInputs(id)
        case .pushSwitch:
            return AnyHashable([
                AnyHashable(notifications.pushEnabled),
                AnyHashable(notifications.pushStatus),
                AnyHashable(notifications.redraws),
                AnyHashable(ServerNotificationsSection.relayRefusesThisDevice),
            ])
        case .pushWorking:
            return AnyHashable(0)
        case .pushError:
            return AnyHashable(notifications.pushFailure ?? "")
        case .liveActivitySwitch:
            return AnyHashable([
                AnyHashable(notifications.liveActivityEnabled),
                AnyHashable(notifications.liveActivityStatus),
                AnyHashable(notifications.redraws),
            ])
        case .liveActivityWorking:
            return AnyHashable(0)
        case .lock:
            return AnyHashable([
                AnyHashable(locks.isFlagged(lockScope)),
                AnyHashable(locks.isAuthenticating),
                AnyHashable(toggleRevision),
            ])
        case .remove:
            return AnyHashable([current.name, String(removingLastServer)])
        }
    }

    private var workspaceCount: String? {
        coordinator.connection(for: server.id).map { String($0.workspaceStore.workspaces.count) }
    }

    private var pairedDeviceCount: String? {
        let state = model.pairedDevicesState(currentDeviceId: current.deviceCredential?.deviceId)
        guard case .loaded(let rows, _) = state else { return nil }
        return String(rows.count)
    }

    private var lockScope: ScopedLockScope { .server(serverId: server.id) }

    // MARK: - Cells

    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        configureIndex(cell, item: item)
    }

    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        configureState(cell, item: item)
    }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        configureRemove(cell)
    }

    private lazy var summaryRow = UICollectionView.CellRegistration<ServerSettingsSummaryCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        let state = HostSwitcherBadgeState.make(for: current, coordinator: coordinator)
        cell.configure(
            name: current.name,
            status: Self.connectionStatusTitle(for: current, coordinator: coordinator),
            state: state,
            icon: current.resolvedBadgeIcon,
            lock: locks.badge(.server(server.id)),
            isLoading: model.isLoading,
            identifier: "server.summary"
        )
    }

    override func prepareRegistrations() {
        _ = (indexRow, stateRow, actionRow, summaryRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .summary:
            collectionView.dequeueConfiguredReusableCell(using: summaryRow, for: indexPath, item: item)
        case .modelProviders, .workspaces, .dictionary, .pairedDevices, .about, .badge:
            collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        case .summaryError, .settingFailure, .pushWorking, .pushError,
             .liveActivityWorking, .liveActivityError, .liveActivitySystemOff:
            collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        case .remove:
            collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .mobileOutputGuide, .serverMetrics, .durableSessions, .startDurable, .pushSwitch, .liveActivitySwitch, .lock:
            super.dequeue(item, at: indexPath)
        }
    }

    /// Switch rows and the loading row, which are plain list cells.
    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        switch item {
        case .mobileOutputGuide:
            settingToggleRow(cell, SettingsCatalog.mobileOutputGuideEnabled)
        case .serverMetrics:
            settingToggleRow(cell, SettingsCatalog.serverMetricsEnabled)
        case .durableSessions:
            settingToggleRow(cell, SettingsCatalog.durableSessionsEnabled)
        case .startDurable:
            settingToggleRow(cell, SettingsCatalog.startSessionsAsDurable, store: deviceSettings)
        case .pushSwitch:
            switchRow(
                cell,
                title: String(localized: "Push Notifications"),
                systemImage: "bell.badge",
                isOn: notifications.pushEnabled,
                identifier: "server.push.enabled",
                isEnabled: notifications.pushStatus != .working && !ServerNotificationsSection.relayRefusesThisDevice
            ) { [weak self] isOn in self?.pushSwitchChanged(isOn) }
        case .liveActivitySwitch:
            switchRow(
                cell,
                title: String(localized: "Live Activities"),
                systemImage: "platter.filled.bottom.iphone",
                isOn: notifications.liveActivityEnabled,
                identifier: "server.liveActivity.enabled",
                isEnabled: notifications.liveActivityStatus != .working
            ) { [weak self] isOn in self?.liveActivitySwitchChanged(isOn) }
        case .lock:
            switchRow(
                cell,
                title: String(localized: "Lock Server"),
                isOn: locks.isFlagged(lockScope),
                identifier: "server.lock",
                isEnabled: !locks.isAuthenticating
            ) { [weak self] isOn in self?.lockSwitchChanged(isOn) }
        default:
            break
        }
    }

    /// A switch row. The one place this page builds one, so every switch reads the same.
    private func switchRow(
        _ cell: UICollectionViewListCell,
        title: String,
        systemImage: String? = nil,
        isOn: Bool,
        identifier: String,
        isEnabled: Bool,
        onChange: @escaping (Bool) -> Void
    ) {
        toggleRow(cell, title: title, isOn: isOn, identifier: identifier, isEnabled: isEnabled, onChange: onChange)
        guard let systemImage, var content = cell.contentConfiguration as? UIListContentConfiguration else { return }
        content.image = UIImage(systemName: systemImage)
        content.imageProperties.tintColor = SettingsStyle.current.accent
        cell.contentConfiguration = content
    }

    private func configureIndex(_ cell: SettingsIndexRowCell, item: Item) {
        switch item {
        case .modelProviders:
            cell.configure(
                title: HostSwitcherDestination.modelProviders.menuTitle,
                image: .symbol(HostSwitcherDestination.modelProviders.systemImage),
                value: model.providerSummary,
                valueNeedsAttention: model.providerSetupState == .needsConfiguration,
                identifier: "server.modelProviders.open"
            ) { [weak self] in self?.open(.modelProviders) }
        case .workspaces:
            cell.configure(
                title: String(localized: "Workspaces"),
                image: .symbol("square.grid.2x2"),
                value: workspaceCount,
                identifier: "server.manageWorkspaces"
            ) { [weak self] in self?.open(.workspaces) }
        case .dictionary:
            cell.configure(
                title: String(localized: "Dictation Dictionary"),
                image: .symbol("text.book.closed"),
                value: nil,
                identifier: "server.dictationDictionary"
            ) { [weak self] in self?.open(.dictionary) }
        case .pairedDevices:
            cell.configure(
                title: String(localized: "Paired Devices"),
                image: .symbol("iphone.gen3"),
                value: pairedDeviceCount,
                identifier: "server.row.pairedDevices"
            ) { [weak self] in self?.open(.pairedDevices) }
        case .about:
            cell.configure(
                title: String(localized: "About This Server"),
                image: .symbol("info.circle"),
                value: model.aboutSummary,
                identifier: "server.row.about"
            ) { [weak self] in self?.open(.about) }
        case .badge:
            cell.configure(
                title: String(localized: "Badge Icon"),
                image: .symbol("app.badge"),
                value: nil,
                identifier: "server.row.badge"
            ) { [weak self] in self?.open(.badge) }
        default:
            break
        }
    }

    private func configureState(_ cell: SettingsStateRowCell, item: Item) {
        switch item {
        case .summaryError:
            cell.configure(
                .failure(model.error ?? "", retry: { [weak self] in self?.retryLoad() }),
                identifier: "server.summary.error"
            )
        case .settingFailure(let id):
            guard let settings else { return }
            let retry: (() -> Void)? = settings.canRetry(id: id) ? { settings.retry(id: id) } : nil
            cell.configure(.failure(settings.failureReason(id: id) ?? "", retry: retry), identifier: "\(id).failure")
        case .pushWorking:
            cell.configure(.loading(String(localized: "Updating push notifications…")), identifier: "server.push.working")
        case .pushError:
            cell.configure(.failure(notifications.pushFailure ?? "", retry: nil), identifier: "server.push.error")
        case .liveActivityWorking:
            cell.configure(.loading(String(localized: "Updating Live Activities…")), identifier: "server.liveActivity.working")
        case .liveActivityError:
            cell.configure(
                .failure(String(localized: "Couldn't let this server update the Live Activity while Oppi is closed. Oppi tries again when it reconnects."), retry: nil),
                identifier: "server.liveActivity.error"
            )
        case .liveActivitySystemOff:
            cell.configure(
                .failure(String(localized: "Live Activities are off for Oppi in the Settings app."), retry: nil),
                identifier: "server.liveActivity.systemOff"
            )
        default:
            break
        }
    }

    private func configureRemove(_ cell: SettingsActionRowCell) {
        let name = current.name
        let isLast = removingLastServer
        cell.configure(
            title: String(localized: "Remove Server"),
            systemImage: "trash",
            tint: .destructive,
            identifier: "server.remove",
            confirmation: .init(
                title: isLast ? String(localized: "Remove only paired server?") : String(localized: "Remove \(name)?"),
                message: isLast
                    ? String(localized: "This is the only paired server on this device. Removing it deletes its cached sessions and files from this device and returns you to onboarding. You'll need to pair again before using the app.")
                    : String(localized: "This removes the server and its cached sessions and files from this device. It does not delete anything on the server, and you can pair it again later."),
                actionTitle: isLast ? String(localized: "Remove Last Server") : String(localized: "Remove Server"),
                style: .actionSheet
            )
        ) { [weak self] in self?.removeServer() }
    }

    // MARK: - Selection

    override func isSelectable(_ item: Item) -> Bool {
        switch item {
        case .modelProviders, .workspaces, .dictionary, .pairedDevices, .about, .badge: true
        default: false
        }
    }

    override func select(_ item: Item) {
        open(item)
    }

    // MARK: - Actions

    /// Each page named here belongs to the pinned server: the pages take this page's
    /// model and server, and are tracked so the route can close them with this page.
    /// Model Providers is a routed screen and is not.
    private func open(_ item: Item) {
        let server = current
        switch item {
        case .modelProviders:
            root.navigation.openModelProviders(ModelProvidersNavTarget(serverId: server.id))
        case .workspaces:
            push(WorkspaceListViewController(server: server, root: root))
        case .dictionary:
            push(DictationDictionaryViewController.make(root: root, serverId: server.id))
        case .pairedDevices:
            push(ServerPairedDevicesViewController(model: model, server: server, root: root))
        case .about:
            push(ServerAboutViewController(model: model, server: server, root: root))
        case .badge:
            push(ServerBadgeViewController(server: server, root: root))
        default:
            break
        }
    }

    /// Pushes a page of this server's and tracks it.
    private func push(_ screen: UIViewController) {
        Router.push(screen, from: self)
        track(screen)
    }

    private func retryLoad() {
        let model = model
        Task { await model.load() }
    }

    /// A save that settled without changing what the state says leaves the switch
    /// where the finger put it; drawing the rows again puts it back.
    private func redrawToggles() {
        toggleRevision += 1
        setNeedsUpdateProperties()
    }

    // MARK: - Lock

    /// Turning the lock on never asks and keeps this screen open for now; turning
    /// it off asks for device authentication and stays on after a cancel.
    private func lockSwitchChanged(_ isOn: Bool) {
        let scope = lockScope
        if isOn {
            locks.lock(scope, unlockedForNow: true)
            redrawToggles()
        } else {
            let locks = locks
            Task { [weak self] in
                _ = await locks.removeLock(scope)
                self?.redrawToggles()
            }
        }
    }

    // MARK: - Notifications

    private func pushSwitchChanged(_ isOn: Bool) {
        guard isOn else {
            notifications.turnPushOff(connection: coordinator.connection(for: server.id))
            return
        }
        // The switch shows only while the relay is known.
        guard let connection = coordinator.connection(for: server.id), connection.pushRelay != nil else {
            notifications.redraw()
            return
        }
        let notifications = notifications
        PushEnableFlow.start(
            connection: connection,
            presenter: self,
            openPrivacyPolicy: { [weak self] in
                self?.root.opener.open(.webLink(AppSupportLinks.privacyPolicyURL))
            },
            progress: { notifications.apply($0) }
        )
        // Nothing is on until the person agrees; the switch stays where the state says.
        notifications.redraw()
    }

    private func liveActivitySwitchChanged(_ isOn: Bool) {
        let server = server
        guard isOn,
              let consent = ServerNotificationsSection.consentForLiveActivityOn(
                  pushEnabled: notifications.pushEnabled,
                  relayHost: relayHostForConsent
              ) else {
            notifications.setLiveActivity(isOn, connection: coordinator.connection(for: server.id))
            return
        }
        presentConsent(consent) { [weak self] in
            guard let self else { return }
            notifications.setLiveActivity(true, connection: coordinator.connection(for: server.id))
        }
        notifications.redraw()
    }

    /// The same disclosure `PushEnableFlow` shows for push, for Live Activities.
    private func presentConsent(_ consent: ServerNotificationsSection.Consent, turnOn: @escaping () -> Void) {
        consent.present(
            from: self,
            identifier: "liveActivity.enable.disclosure",
            onTurnOn: turnOn,
            onCancel: { [weak self] in self?.notifications.redraw() },
            onPrivacyPolicy: { [weak self] in self?.root.opener.open(.webLink(AppSupportLinks.privacyPolicyURL)) }
        )
    }

    // MARK: - Remove Server

    private var removingLastServer: Bool {
        let servers = coordinator.serverStore.servers
        return servers.count == 1 && servers.first?.id == server.id
    }

    /// Removes the pinned server, not whichever one is visible when this runs,
    /// then closes the screen; the last server's removal goes to onboarding.
    private func removeServer() {
        let server = current
        let coordinator = coordinator
        let root = root
        // Removing the visible server makes another one visible, which would swap the
        // route's page; the route is captured now, before that, so it can close.
        let route = route
        Task { @MainActor [self] in
            guard await AppLockService.shared.authorizeProtectedAction(
                reason: String(localized: "Remove \(server.name) from this device")
            ) else { return }
            route?.willFinish()
            await coordinator.removeServer(id: server.id)
            if coordinator.serverStore.servers.isEmpty {
                root.navigation.showOnboarding = true
                return
            }
            if let route {
                route.finish()
            } else {
                Router.finish(self)
            }
        }
    }

    // MARK: - Shared with About

    /// The connection line the summary and About This Server both show.
    static func connectionStatusTitle(for server: PairedServer, coordinator: ConnectionCoordinator) -> String {
        let state = HostSwitcherBadgeState.make(for: server, coordinator: coordinator)
        return ServerConnectionLanePresentation.title(
            server: server,
            connection: coordinator.connection(for: server.id),
            state: state,
            isPreparing: coordinator.preparingServerIds.contains(server.id)
        )
    }
}

// MARK: - Summary cell

/// The server's badge in its connection state's tint, its name with a lock badge, the
/// connection line under it, and a spinner while the page loads. Read-only: one
/// accessibility element that reads the name, the state, and the lock.
final class ServerSettingsSummaryCell: UICollectionViewListCell {
    private let badge = SettingsServerBadgeView()
    private let nameLabel = UILabel()
    private let lockView = UIImageView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [badge, nameLabel, lockView, statusLabel, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lockView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small)
        lockView.contentMode = .scaleAspectFit
        lockView.setContentHuggingPriority(.required, for: .horizontal)
        lockView.isAccessibilityElement = false
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        spinner.hidesWhenStopped = true
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            badge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            nameLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            lockView.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 5),
            lockView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            spinner.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            lockView.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        name: String,
        status: String,
        state: ServerBadgeConnectionState,
        icon: ServerBadgeIcon,
        lock: ScopedLockState,
        isLoading: Bool,
        identifier: String
    ) {
        let palette = ThemeRuntimeState.currentPalette()
        badge.apply(icon: icon, tint: state.uiColor(ComposerThemeColors(palette: palette)))
        nameLabel.text = name
        nameLabel.textColor = palette.ui.fg
        statusLabel.text = status
        statusLabel.textColor = palette.ui.comment
        var value = status
        switch lock {
        case .none:
            lockView.image = nil
        case .locked:
            lockView.image = UIImage(systemName: "lock.fill")
            value += ", " + String(localized: "Locked")
        case .unlocked:
            lockView.image = UIImage(systemName: "lock.open.fill")
            value += ", " + String(localized: "Unlocked")
        }
        lockView.tintColor = palette.ui.comment
        if isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
        accessibilityIdentifier = identifier
        accessibilityLabel = name
        accessibilityValue = value
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        statusLabel.text = nil
        lockView.image = nil
        spinner.stopAnimating()
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }
}
