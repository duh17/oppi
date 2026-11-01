import UIKit

/// Device-local host list. Row tap connects. Edit and Add push the setup form.
/// Appearing loads defaults only: it does not dial and does not read the Keychain.
/// Coming back from the form or the terminal reloads the list.
final class SSHTerminalHostListViewController: UIViewController, UICollectionViewDelegate {
    var showsSidebarToggle = false {
        didSet { if isViewLoaded { installBarItems() } }
    }

    /// How a Rex host's follower is made. The tab never prompts on its own;
    /// the debug harness and tests pass one over a stand-in Rex.
    private let makeFollower: @MainActor (SSHTerminalProfile) -> SSHTerminalRexFollower
    /// Where the saved hosts live. Tests pass a store over their own defaults.
    private let profileStore: @Sendable () -> SSHTerminalProfileStore

    private let session = SSHTerminalConnectSession()
    private var chrome: SSHTerminalConnectChrome?
    private var profiles: [SSHTerminalProfile] = []
    /// The Rex section's hosts, by saved host: each follows its own Rex over
    /// its own connection while this screen shows.
    private struct RexHost {
        let follower: SSHTerminalRexFollower
        let chrome: SSHTerminalConnectChrome
    }

    private var rexHosts: [UUID: RexHost] = [:]
    /// Rex on your tailnet: Rex reached over Tailscale alone, each listed as a
    /// Rex section of its own.
    private let tailnetRex: RexTailnetSection
    /// The connect chrome of each tailnet Rex's follower, by its id: it pushes
    /// the terminal a tapped session opens.
    private var tailnetChromes: [UUID: SSHTerminalConnectChrome] = [:]
    /// Starts Oppi's own Tailscale node when the person connected it in
    /// Settings, for its machine list. Tests pass one that does nothing.
    private let startsTailnet: @MainActor () -> Void
    /// What the Rex rows drew last, by item: only a row whose inputs changed is
    /// reconfigured, so a working pane's mark keeps animating.
    private var rexRows: [Item: SSHTerminalRexListRow] = [:]
    private var rexRowsThemeID: ThemeID?
    private var isOnScreen = false
    /// What the page lists now: the mode button's choice, or the first mode its
    /// experiments allow. Read once per pass, before the snapshot.
    private var mode: SSHTerminalPageMode = .shell
    /// Where the mode is kept: read for what the page shows and written by its button,
    /// so one store is both answers. A test or a preview passes its own.
    private let settings: SettingsStore
    private var connectingProfile = SSHTerminalProfile()
    private var metadataIsCorrupt = false
    private var editAfterTerminal: UUID?
    /// The Rex experiment's switch changing while this tab is up.
    private var experimentObserver: NSObjectProtocol?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var lastThemeID: ThemeID?

    private enum Section: Hashable { case status, rex(UUID), hosts, empty, reset }
    private enum Item: Hashable {
        case corrupt
        case connecting
        case failure(String)
        case trustUnknown
        case trustMismatch
        case addHost
        case host(UUID)
        /// A row of a Rex host's section, by the host and the row's id there.
        case rexRow(host: UUID, id: String)
        case reset
    }

    init(
        showsSidebarToggle: Bool = false,
        profileStore: @escaping @Sendable () -> SSHTerminalProfileStore = { SSHTerminalProfileStore() },
        makeFollower: @escaping @MainActor (SSHTerminalProfile) -> SSHTerminalRexFollower = {
            SSHTerminalRexFollower(profile: $0, promptsAutomatically: false)
        },
        tailnetRex: RexTailnetSection = RexTailnetSection(),
        startsTailnet: @escaping @MainActor () -> Void = { TailnetNodeController.shared.startIfEnabled() },
        settings: SettingsStore = .liveDevice()
    ) {
        self.showsSidebarToggle = showsSidebarToggle
        self.profileStore = profileStore
        self.makeFollower = makeFollower
        self.tailnetRex = tailnetRex
        self.startsTailnet = startsTailnet
        self.settings = settings
        var config = SettingsListStyle.layoutConfiguration(headers: false, footers: false)
        config.trailingSwipeActionsConfigurationProvider = { indexPath in
            nil
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = "Terminal"
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        var config = SettingsListStyle.layoutConfiguration(headers: false, footers: false)
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        collectionView.setCollectionViewLayout(UICollectionViewCompositionalLayout.list(using: config), animated: false)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        collectionView.accessibilityIdentifier = "sshTerminal.hostList"
        SettingsListStyle.pin(collectionView, in: view)
        installBarItems()
        installDataSource()
        chrome = SSHTerminalConnectChrome(
            host: self,
            session: session,
            profile: { [weak self] in self?.connectingProfile ?? SSHTerminalProfile() },
            setProfile: { [weak self] in self?.connectingProfile = $0 },
            editHost: { [weak self] in self?.editConnectedHost() },
            submitPassword: { [weak self] in self?.connect(password: $0) },
            onSaved: { [weak self] _ in self?.reload() }
        )
        reload()
        // Rex and Herdr are experiments: a switch turned while this tab is up (in
        // Settings over it) takes effect here without a relaunch.
        experimentObserver = NotificationCenter.default.addObserver(
            forName: AppPreferences.Experiments.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.experimentsChanged() }
        }
        setNeedsUpdateProperties()
    }

    isolated deinit {
        if let experimentObserver { NotificationCenter.default.removeObserver(experimentObserver) }
    }

    /// The Experiments switch changed: the Rex sections, the tailnet nodes, and
    /// the followers follow it now, as they do on the way back to this tab.
    private func experimentsChanged() {
        reload()
        for host in rexHosts.values { host.follower.appeared() }
        for follower in tailnetRex.listedFollowers { follower.appeared() }
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        // The saved hosts first: a host edited or deleted while this screen was
        // covered must not be signed in, or saved back, from the old copy.
        reload()
        for host in rexHosts.values { host.follower.appeared() }
        for follower in tailnetRex.listedFollowers { follower.appeared() }
        // Oppi's own node lists the tailnet's machines; it starts only if
        // the person connected Tailscale in Settings.
        startsTailnet()
        // The toolbar belongs to the navigation controller and is shown per screen:
        // this page shows it when it offers a mode, and anything pushed over it hides
        // it (`viewWillDisappear`).
        installModeButton()
        setNeedsUpdateProperties()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A terminal or a form over this page has no mode button.
        navigationController?.setToolbarHidden(true, animated: true)
    }


    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        chrome?.hostDidDisappear()
        // The monitors stop while the tab is covered. A screen pushed over it (a
        // terminal, a form) leaves its connection up, read again on return;
        // leaving the tab for another closes them, and they sign in again on return.
        let covered = navigationController?.viewControllers.contains(self) == true && !isBeingDismissed
        for host in rexHosts.values {
            host.follower.stopReading()
            host.chrome.hostDidDisappear()
            if !covered { host.follower.close() }
        }
        for follower in tailnetRex.listedFollowers {
            follower.stopReading()
            tailnetChromes[follower.host.id]?.hostDidDisappear()
        }
        tailnetRex.stop()
    }

    override func updateProperties() {
        super.updateProperties()
        _ = session.connecting
        _ = session.failure
        _ = session.hostFailure
        _ = session.passwordPrompt
        _ = session.showsTerminal
        _ = session.forgetConfirmation
        _ = session.savingHostOnly
        _ = session.channel
        _ = AppScenePhase.shared.isBackground
        for profile in profiles { _ = SSHTerminalRegistry.shared.terminals(for: profile.id) }
        for host in rexHosts.values { _ = host.follower.session.showsTerminal }
        for follower in tailnetRex.listedFollowers { _ = follower.session.showsTerminal }
        let themeID = sshTerminalThemeID
        if lastThemeID != themeID {
            lastThemeID = themeID
            SettingsListStyle.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        if !terminalShown, let id = editAfterTerminal {
            editAfterTerminal = nil
            openEditor(profileID: id)
        }
        let active = isActive
        // The mode before the rows it decides, and before any follower dials: a page
        // that just switched to Shell must not open a Rex connection for a section
        // nobody sees.
        let mode = SSHTerminalPageMode.resolved(storedMode, in: SSHTerminalExperimentAccess.current)
        let modeChanged = mode != self.mode
        self.mode = mode
        if modeChanged {
            // Another list, and another set of connections: the button follows the
            // mode, and the followers follow the list.
            installBarItems()
            syncRexHosts()
        }
        // Before the snapshot: a Rex just added (or found) is listed in this
        // pass. A change made after the snapshot read would wait for an
        // unrelated update, since this pass does not run again for it.
        syncTailnetRex(active: active)
        // ＋ names the hosts it can start a session on, and that set changes here: a
        // host saved or deleted, a host renamed, or a tailnet node found after the page
        // appeared. Same pass as the discovery that found it, or the menu stays stale
        // until something else reloads.
        syncPlusItem()
        applySnapshot()
        chrome?.sync()
        // Rex mode signs in to every saved host, so the page bounds what dials: it
        // counts the followers already connecting, grants the rest of `inFlight`, and
        // walks the saved hosts in order so the first screenful fills first. Only a
        // follower that will really dial is charged — one waiting for a tap would
        // otherwise take a grant no connection ever uses.
        var budget = SSHTerminalConnectBudget(
            max(0, SSHTerminalConnectBudget.inFlight - rexHosts.values.filter { $0.follower.session.connecting }.count)
        )
        for profile in profiles {
            guard let host = rexHosts[profile.id] else { continue }
            host.chrome.sync()
            guard active else {
                host.follower.sync(active: false)
                continue
            }
            let follower = host.follower
            follower.sync(active: !follower.wouldStartSignIn || budget.take())
            if let sessions = follower.monitor.snapshot?.sessions {
                let store = profileStore().rexExpanded
                store.prune(to: Set(sessions.map(\.sessionID)), for: profile.id)
                follower.expandedSessions.formIntersection(sessions.map(\.sessionID))
            }
        }
        // A follower that is not a saved host's (a host deleted while its chrome is
        // up) still gets its pass.
        for (id, host) in rexHosts where !profiles.contains(where: { $0.id == id }) {
            host.chrome.sync()
            host.follower.sync(active: active && !host.follower.wouldStartSignIn)
        }
    }

    /// The nav bar's two buttons: ＋ saves a host, ⚙︎ opens Settings › Terminal
    /// (the hosts' forms, Rex on Your Tailnet, and the Bottom Bar), which is where
    /// the occasional setup leaves this page.
    private func installBarItems() {
        let plus = Self.plus(mode: mode, hosts: sessionHosts)
        let hosts = plusMenu()
        // With several hosts to choose from the item has a menu and no action of its
        // own: a tap opens the menu, and choosing an item is what starts the session.
        let add = UIBarButtonItem(
            title: Self.plusTitle(plus),
            image: UIImage(systemName: "plus"),
            primaryAction: hosts == nil ? plusAction() : nil,
            menu: hosts
        )
        add.accessibilityIdentifier = Self.plusIdentifier(plus)
        // What ＋ offers, by identity: a tailnet node is found after the first pass, and a
        // renamed host is another menu.
        hostsShown = sessionHosts.map { "\($0.id.uuidString)|\($0.endpointLabel)" }
        let settings = UIBarButtonItem(
            title: String(localized: "Terminal Settings"),
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                Router.push(SSHTerminalSettingsViewController(), from: self)
            }
        )
        settings.accessibilityIdentifier = "sshTerminal.settings"
        navigationItem.rightBarButtonItems = [add, settings]
        installModeButton()
        if showsSidebarToggle, let root = AppRootEnvironment.near(self) {
            navigationItem.leftBarButtonItem = WorkspaceSplitSidebarToggle.makeItem(root: root)
        }
    }

    /// Rex mode's ＋ is a session, not a host: on the host that is the only saved one,
    /// or the one picked in its menu when there are several. Shell mode's ＋ is a host.
    static func plus(
        mode: SSHTerminalPageMode,
        hosts: [SSHTerminalProfile]
    ) -> SSHTerminalPlusAction {
        guard mode == .rex else { return .newHost }
        return hosts.isEmpty ? .newHost : .newSession(hosts)
    }

    /// What ＋ says and how a test finds it: New Host when it saves one (Shell mode, or
    /// Rex with nothing saved), New Session when Rex's list has a host to use.
    static func plusTitle(_ action: SSHTerminalPlusAction) -> String {
        switch action {
        case .newHost: String(localized: "Add Host")
        case .newSession: String(localized: "New Session")
        }
    }

    static func plusIdentifier(_ action: SSHTerminalPlusAction) -> String {
        switch action {
        case .newHost: "sshTerminal.host.add"
        case .newSession: "sshTerminal.page.newSession"
        }
    }

    private func plusAction() -> UIAction {
        UIAction { [weak self] _ in
            guard let self else { return }
            switch Self.plus(mode: mode, hosts: sessionHosts) {
            case .newHost:
                openEditor(profileID: nil)
            case .newSession(let hosts):
                guard let host = hosts.first else { return }
                startSession(on: host)
            }
        }
    }

    /// Rex mode with several hosts: one item per host, so ＋ asks which one.
    private func plusMenu() -> UIMenu? {
        guard case .newSession(let hosts) = Self.plus(mode: mode, hosts: sessionHosts), hosts.count > 1 else { return nil }
        return UIMenu(children: hosts.map { profile in
            UIAction(title: profile.endpointLabel) { [weak self] _ in self?.startSession(on: profile) }
        })
    }

    /// A session on this host, opened on its new pane.
    private func startSession(on profile: SSHTerminalProfile) {
        // A saved host's follower, or a tailnet node's (its stand-in profile carries the
        // node's id).
        let follower: (any SSHTerminalRexListFollowing)?
        if let saved = rexHosts[profile.id]?.follower {
            follower = saved
        } else {
            follower = tailnetRex.follower(id: profile.id)
        }
        guard let follower else { return }
        Task { await follower.createSession() }
    }

    /// Every host Rex mode can start a session on: the saved hosts in saved order, then
    /// the Rexes reached over Tailscale by name.
    private var sessionHosts: [SSHTerminalProfile] {
        guard mode == .rex else { return profiles }
        return profiles + tailnetRex.listedFollowers.map { $0.profile }
    }

    /// The mode button, at the trailing corner of the bottom toolbar: one menu of the
    /// modes this device offers, and no toolbar at all when there is nothing to choose
    /// (with Rex's experiment off the page is Shell).
    private func installModeButton() {
        guard navigationController?.topViewController === self else { return }
        guard SSHTerminalPageMode.available(in: SSHTerminalExperimentAccess.current).count > 1 else {
            setToolbarItems(nil, animated: false)
            navigationController?.setToolbarHidden(true, animated: true)
            return
        }
        let item = UIBarButtonItem(
            title: String(localized: "Terminal Mode"),
            image: UIImage(systemName: mode == .rex ? "rectangle.split.3x1" : "rectangle.stack"),
            primaryAction: nil,
            menu: modeMenu()
        )
        item.accessibilityIdentifier = "sshTerminal.mode"
        item.accessibilityValue = mode.label
        setToolbarItems([.flexibleSpace(), item], animated: true)
        navigationController?.setToolbarHidden(false, animated: true)
    }

    /// The modes this device can show, with the one on screen checked.
    private func modeMenu() -> UIMenu {
        let current = mode
        return UIMenu(children: SSHTerminalPageMode.available(in: SSHTerminalExperimentAccess.current).map { candidate in
            UIAction(
                title: candidate.label,
                state: candidate == current ? .on : .off
            ) { [weak self] _ in
                self?.choose(candidate)
            }
        })
    }

    /// The person's choice: written through the declaration, so one place owns the key
    /// and its default, and redrawn here. A mode whose experiment turns off later
    /// falls back on its own (`SSHTerminalPageMode.resolved`).
    /// The person's choice, from the mode menu. Not private, so a test reaches the
    /// same owner action a tap does (`UIAction` handlers are not reachable).
    func choose(_ candidate: SSHTerminalPageMode) {
        // The one store the page reads is the one it writes, so the next pass draws
        // what was stored instead of a second copy of the choice.
        settings.set(SettingsCatalog.terminalPageMode, candidate.rawValue)
        setNeedsUpdateProperties()
    }

    /// Rebuilds the bar's buttons when the hosts ＋ offers are not the ones it was built
    /// for. One owner, called from the pass and from a reload.
    private func syncPlusItem() {
        if hostsShown != sessionHosts.map({ "\($0.id.uuidString)|\($0.endpointLabel)" }) { installBarItems() }
    }

    /// The hosts the bar's ＋ was built for, each as its id and the name it showed:
    /// adding, deleting, or renaming one rebuilds it, and so does a tailnet node found
    /// after the first pass, so the menu never offers a host that is gone, misses one
    /// that is there, or names it as it was.
    private var hostsShown: [String] = []

    /// What the device last chose, nil when nothing was chosen yet.
    private var storedMode: SSHTerminalPageMode? {
        guard case .value(let value, _) = settings.read(SettingsCatalog.terminalPageMode) else { return nil }
        return SSHTerminalPageMode(rawValue: value)
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let hostCell = UICollectionView.CellRegistration<SSHTerminalHostRowCell, Item> { [weak self] cell, _, item in
            guard let self, case .host(let id) = item,
                  let profile = self.profiles.first(where: { $0.id == id }) else { return }
            let live = SSHTerminalRegistry.shared.isLive(profile.id)
            let folderTerminals = SSHTerminalRegistry.shared.terminals(for: profile.id).compactMap(\.folder)
            cell.configure(
                profile: profile,
                live: live,
                folderTerminals: folderTerminals,
                palette: self.sshTerminalThemeID.palette,
                enabled: !self.session.connecting && !self.session.passwordPrompt,
                onConnect: { [weak self] in self?.open(profile) },
                onEdit: { [weak self] in self?.openEditor(profileID: profile.id) },
                onDelete: { [weak self] in self?.confirmDelete(profile) }
            )
        }
        let rexCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configureRexRow(cell, item: item)
        }
        let rexActionCell = UICollectionView.CellRegistration<SSHTerminalRexListActionCell, Item> { [weak self] cell, _, item in
            self?.configureRexAction(cell, item: item)
        }
        let rexSessionCell = UICollectionView.CellRegistration<SSHTerminalRexListSessionCell, Item> { [weak self] cell, _, item in
            self?.configureRexSession(cell, item: item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView, cellProvider: SettingsListStyle.cardProvider { [weak self] collectionView, indexPath, item in
            switch item {
            case .rexRow:
                // A session is a row with a disclosure; a pane and the connect
                // row are buttons; the rest read.
                switch self?.rexRows[item]?.kind {
                case .session:
                    collectionView.dequeueConfiguredReusableCell(using: rexSessionCell, for: indexPath, item: item)
                // A retry is a button like a pane: the row that asks again has to be
                // drawn by the cell that carries the action, or it is a dead label.
                case .pane, .tapToConnect, .newSession, .retry:
                    collectionView.dequeueConfiguredReusableCell(using: rexActionCell, for: indexPath, item: item)
                default:
                    collectionView.dequeueConfiguredReusableCell(using: rexCell, for: indexPath, item: item)
                }
            case .host:
                collectionView.dequeueConfiguredReusableCell(using: hostCell, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
            }
        })
    }

    private func configure(_ cell: UICollectionViewListCell, item: Item) {
        let palette = sshTerminalThemeID.palette
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        cell.accessibilityHint = nil
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.color = palette.ui.fg
        content.secondaryTextProperties.color = palette.ui.comment
        switch item {
        case .corrupt:
            content.text = SSHTerminalProfileStoreError.corruptMetadata.localizedDescription
            content.textProperties.numberOfLines = 0
        case .connecting:
            configureConnecting(cell, palette: palette)
            return
        case .failure(let message):
            content.text = "Disconnected — \(message)"
            content.textProperties.color = palette.ui.red
            content.textProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "sshTerminal.failure"
        case .trustUnknown:
            content.text = "New host — trust decision"
            content.secondaryText = "Verify the fingerprint, then Trust & Connect."
            cell.accessibilityIdentifier = "sshTerminal.trustPrompt"
        case .trustMismatch:
            content.text = "Host key changed — connection blocked."
            content.textProperties.color = palette.ui.red
            content.secondaryText = "Forget the trusted key only after you verify why it changed."
        case .addHost:
            // With no saved host this row is the whole screen: it leads with
            // the action and says what saving one gives you.
            content.text = "Add Host"
            content.textProperties.color = palette.ui.blue
            content.secondaryText = "No saved hosts yet. Enter a host, port, and user, then connect."
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "sshTerminal.host.add"
        case .host, .rexRow:
            break
        case .reset:
            content.text = "Reset Host List"
            content.textProperties.color = palette.ui.red
            cell.accessibilityIdentifier = "sshTerminal.resetHostList"
        }
        cell.contentConfiguration = content
    }

    private func configureConnecting(_ cell: UICollectionViewListCell, palette: ThemePalette) {
        var content = UIListContentConfiguration.cell()
        content.text = session.savingHostOnly ? "Saving Host…" : "Connecting…"
        content.textProperties.color = palette.ui.fg
        cell.contentConfiguration = content
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        var conf = UIButton.Configuration.plain()
        conf.title = "Cancel"
        conf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
        let cancel = UIButton(configuration: conf)
        cancel.addAction(UIAction { [weak self] _ in self?.session.cancel() }, for: .touchUpInside)
        cell.accessories = [
            .customView(configuration: .init(customView: spinner, placement: .leading())),
            .customView(configuration: .init(customView: cancel, placement: .trailing())),
        ]
        cell.accessibilityIdentifier = "sshTerminal.connecting"
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        var status: [Item] = []
        if metadataIsCorrupt { status.append(.corrupt) }
        if session.connecting { status.append(.connecting) }
        if let failure = session.failure { status.append(.failure(failure)) }
        switch session.hostFailure {
        case .unknownHostKey: status.append(.trustUnknown)
        case .hostKeyMismatch: status.append(.trustMismatch)
        default: break
        }
        if !status.isEmpty {
            snapshot.appendSections([.status])
            snapshot.appendItems(status, toSection: .status)
        }
        var rows: [Item: SSHTerminalRexListRow] = [:]
        switch mode {
        case .rex:
            // Every saved host, its sessions and panes, with the Rexes reached over
            // Tailscale by name after them. The host rows stay off the page: a tap
            // opens a pane, and the host's own form is its heading's ⋯.
            for profile in profiles {
                let section = Section.rex(profile.id)
                let hostRows = rexSectionRows(for: profile)
                let items = hostRows.map { Item.rexRow(host: profile.id, id: $0.id) }
                snapshot.appendSections([section])
                snapshot.appendItems(items, toSection: section)
                for (item, row) in zip(items, hostRows) { rows[item] = row }
            }
            if tailnetRex.isShown {
                for follower in tailnetRex.listedFollowers {
                    let section = Section.rex(follower.host.id)
                    let hostRows = SSHTerminalRexListRow.rows(hostName: follower.host.dnsName, state: follower.listState)
                    let items = hostRows.map { Item.rexRow(host: follower.host.id, id: $0.id) }
                    snapshot.appendSections([section])
                    snapshot.appendItems(items, toSection: section)
                    for (item, row) in zip(items, hostRows) { rows[item] = row }
                }
            }
        case .shell:
            if !profiles.isEmpty {
                snapshot.appendSections([.hosts])
                snapshot.appendItems(profiles.map { .host($0.id) }, toSection: .hosts)
            }
        }
        if profiles.isEmpty && !metadataIsCorrupt {
            snapshot.appendSections([.empty])
            snapshot.appendItems([.addHost], toSection: .empty)
        }
        if metadataIsCorrupt {
            snapshot.appendSections([.reset])
            snapshot.appendItems([.reset], toSection: .reset)
        }
        // A Rex row is redrawn only when what it draws changed (or the theme
        // did); every other row still redraws with its screen's state.
        let themeID = sshTerminalThemeID
        let themeChanged = rexRowsThemeID != themeID
        let changedRex = rows.filter { rexRows[$0.key] != $0.value || themeChanged }.map(\.key)
        if let current = dataSource?.snapshot(), current.itemIdentifiers == snapshot.itemIdentifiers {
            snapshot.reloadItems(snapshot.itemIdentifiers.filter { rows[$0] == nil })
        }
        snapshot.reconfigureItems(changedRex)
        rexRows = rows
        rexRowsThemeID = themeID
        dataSource?.apply(snapshot, animatingDifferences: false)
        // One pull to refresh for every Rex the tab lists: the hosts' and the tailnet's.
        // A remembered host has no follower at all, and it still needs the pull: the
        // control follows what the page lists, not what it dialled.
        let refreshes = mode == .rex && (!Self.rexFollowedHosts(profiles, mode: mode).isEmpty || tailnetRex.isShown)
        if (collectionView.refreshControl != nil) != refreshes {
            collectionView.refreshControl = refreshes ? rexRefreshControl : nil
        }
    }

    /// One saved host's rows in Rex mode: its heading and what its follower last read.
    /// A host known to have no Rex on it has no follower this visit, and keeps one
    /// muted line instead of a gap.
    private func rexSectionRows(for profile: SSHTerminalProfile) -> [SSHTerminalRexListRow] {
        guard let follower = rexHosts[profile.id]?.follower else {
            return [
                .init(id: "header", kind: .header(name: profile.endpointLabel, needsYou: 0)),
                .init(id: "noRex", kind: .placeholder(String(localized: "No Rex on this host."))),
                // The same owner as a pull to refresh: one row asks this host again.
                .init(id: "retry", kind: .retry(String(localized: "Retry"))),
            ]
        }
        return SSHTerminalRexListRow.rows(hostName: profile.endpointLabel, state: follower.listState)
    }

    /// The hosts this page follows: every saved host in Rex mode, and none in any
    /// other mode (a host is a plain SSH login; the mode decides what is read). With
    /// Rex's experiment off nothing on this page reaches Rex.
    static func rexFollowedHosts(
        _ profiles: [SSHTerminalProfile],
        mode: SSHTerminalPageMode,
        access: SSHTerminalExperimentAccess = .current
    ) -> [SSHTerminalProfile] {
        guard access.rex, mode == .rex else { return [] }
        return profiles
    }

    /// Which of those hosts this visit dials: a host whose last read found no Rex is
    /// not asked again until a pull to refresh, and keeps its muted line meanwhile.
    static func rexDialledHosts(
        _ profiles: [SSHTerminalProfile],
        noRex: SSHTerminalRexHostStore
    ) -> [SSHTerminalProfile] {
        profiles.filter { !noRex.hasNoRex(on: $0) }
    }

    /// Makes, updates, and drops a follower per host the mode lists. Every saved host
    /// gets one in Rex mode; a host with no `rex` on it says so in one muted line and
    /// its monitor gives up until a pull to refresh, as before.
    private func syncRexHosts() {
        let wanted = Self.rexDialledHosts(Self.rexFollowedHosts(profiles, mode: mode), noRex: profileStore().rexHosts)
        for id in rexHosts.keys where !wanted.contains(where: { $0.id == id }) {
            guard let host = rexHosts[id] else { continue }
            // A host whose read found no Rex is not dialled again: drop what is open
            // without marking another sign-in owed, or the next pass would dial it.
            if profileStore().rexHosts.hasNoRex(on: host.follower.profile) {
                host.follower.stopForNoRex()
            } else {
                host.follower.close()
            }
            host.chrome.hostDidDisappear()
            rexHosts[id] = nil
        }
        for profile in wanted {
            if let existing = rexHosts[profile.id] {
                existing.follower.update(profile: profile)
            } else {
                let host = makeRexHost(profile)
                host.follower.expandedSessions = profileStore().rexExpanded.expanded(for: profile.id)
                rexHosts[profile.id] = host
            }
        }
    }

    private lazy var rexRefreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        control.addAction(UIAction { [weak self, weak control] _ in
            Task { @MainActor in
                await self?.refreshRexHosts()
                control?.endRefreshing()
            }
        }, for: .valueChanged)
        return control
    }()

    /// A pull reads Rex again on every host it can without asking for anything,
    /// and tries again where it had no `nc` or no Rex; on the tailnet it asks
    /// every machine whether it is Rex again and reads each node's Rex again.
    private func refreshRexHosts() async {
        // A pull asks again everywhere, including the hosts whose last read found no Rex.
        // Which ones those are has to be read before the memory goes, and they need a
        // follower again, so this pull dials them too (under the same budget, in the
        // pass that follows).
        let store = profileStore()
        let remembered = Self.rexFollowedHosts(profiles, mode: mode).filter { store.rexHosts.hasNoRex(on: $0) }
        store.rexHosts.forgetNoRex()
        if !remembered.isEmpty {
            syncRexHosts()
            setNeedsUpdateProperties()
        }
        // Only a follower that is already connected is asked on the pull itself: its
        // stream is open, so reading again costs no sign-in. One made again by this pull
        // owes a sign-in, and the pass that follows grants it under the budget, so a
        // long list of remembered hosts cannot dial all at once.
        let hosts = rexHosts.values.map(\.follower).filter(\.isConnected)
        var reads = hosts.map { follower in Task { @MainActor in await follower.refresh() } }
        reads += tailnetRex.listedFollowers.map { follower in Task { @MainActor in await follower.refresh() } }
        reads.append(Task { @MainActor [tailnetRex] in await tailnetRex.refresh() })
        for read in reads { await read.value }
    }

    /// The tailnet nodes, from what Oppi's node knows now: makes
    /// and drops a follower (and its connect chrome) per listed node and runs
    /// each only while the tab is `active`. Reads the node's machine list, so a
    /// machine joining or leaving updates it.
    private func syncTailnetRex(active: Bool) {
        // Rex off, or a mode that does not list them: the nodes, their followers, and
        // discovery all go, so nothing here asks the tailnet about Rex.
        guard AppPreferenceStore.Experiments.rexEnabled, mode == .rex else {
            tailnetRex.clear()
            for id in tailnetChromes.keys {
                tailnetChromes[id]?.hostDidDisappear()
                tailnetChromes[id] = nil
            }
            return
        }
        let tailnet = TailnetNodeController.shared
        // Discovery does not outlive the foreground (the followers stop on their own).
        if AppScenePhase.shared.isBackground { tailnetRex.stop() }
        let sshRexHosts = profiles.filter { rexHosts[$0.id] != nil }
        tailnetRex.update(
            peers: tailnet.onlinePeers, selfDNSName: tailnet.snapshot?.selfDNSName, sshRexHosts: sshRexHosts, active: active
        )
        let followers = tailnetRex.listedFollowers
        let listed = Set(followers.map(\.host.id))
        for id in tailnetChromes.keys where !listed.contains(id) {
            tailnetChromes[id]?.hostDidDisappear()
            tailnetChromes[id] = nil
        }
        for follower in followers {
            if tailnetChromes[follower.host.id] == nil {
                // No prompts: Rex admits this device by its Tailscale identity.
                tailnetChromes[follower.host.id] = SSHTerminalConnectChrome(
                    host: self, session: follower.session,
                    profile: { [weak follower] in follower?.profile ?? SSHTerminalProfile() },
                    setProfile: { _ in }, editHost: {}, submitPassword: { _ in }, onSaved: { _ in }
                )
            }
            tailnetChromes[follower.host.id]?.sync()
            follower.sync(active: active)
        }
    }

    /// The follower behind a Rex section: a saved host's, or a tailnet node's.
    private func rexFollower(_ id: UUID) -> (any SSHTerminalRexListFollowing)? {
        rexHosts[id]?.follower ?? tailnetRex.follower(id: id)
    }

    private func makeRexHost(_ profile: SSHTerminalProfile) -> RexHost {
        let follower = makeFollower(profile)
        // What this host's monitor finds keeps the memory of where Rex is, which the
        // Bottom Bar's Rex button and a terminal still read. The page lists every
        // saved host whatever it finds, so a host without Rex keeps its muted line.
        follower.monitor.onFinding = { [weak self, weak follower] finding in
            guard let self, let follower else { return }
            self.profileStore().rexHosts.record(finding, on: follower.profile)
            // No Rex on the host: the idle sign-in has nothing left to read, so it goes
            // without owing another, and the page keeps the heading, one muted line, and
            // the way to ask again. The store now says so, which is what drops the
            // follower: a visit after this one makes none at all.
            if finding == .absent(.notInstalled) {
                // `syncRexHosts` drops it, and dropping a host the store says has no Rex
                // is what stops it without owing a sign-in.
                self.syncRexHosts()
                self.reload()
            }
        }
        let chrome = SSHTerminalConnectChrome(
            host: self,
            session: follower.session,
            profile: { [weak follower] in follower?.profile ?? SSHTerminalProfile() },
            setProfile: { [weak follower] in follower?.profile = $0 },
            editHost: { [weak self, weak follower] in
                guard let follower else { return }
                if let id = follower.session.connectedProfile?.id { self?.editAfterTerminal = id }
                follower.session.showsTerminal = false
            },
            submitPassword: { [weak follower] in follower?.submitPassword($0) },
            onSaved: { [weak follower] in follower?.profile = $0 },
            // A trust decision or password an automatic sign-in hit waits for the tap.
            presentsPrompts: { [weak follower] in follower?.holdsPrompts != true }
        )
        return RexHost(follower: follower, chrome: chrome)
    }

    /// A tailnet node's ⋯: a session on it, which is all a node without a saved form
    /// can be asked to do.
    private func tailnetMenuButton(_ hostID: UUID, palette: ThemePalette) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        config.baseForegroundColor = palette.ui.comment
        button.configuration = config
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "sshTerminal.rexList.\(hostID.uuidString).menu"
        button.menu = UIMenu(children: [
            UIAction(title: String(localized: "New Session")) { [weak self] _ in
                guard let follower = self?.tailnetRex.follower(id: hostID) else { return }
                Task { await follower.createSession() }
            },
        ])
        return button
    }

    /// The ⋯ a Rex section's heading draws: the host's own actions, which Shell mode
    /// puts on the host row instead. A menu button is one tap target, so VoiceOver's
    /// activation opens the same menu a touch does.
    private func hostMenuButton(_ profile: SSHTerminalProfile, palette: ThemePalette) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        config.baseForegroundColor = palette.ui.comment
        button.configuration = config
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "sshTerminal.rexList.\(profile.id.uuidString).menu"
        button.menu = UIMenu(children: [
            // A host with no session has no ⊕ to press: a session starts here.
            UIAction(title: String(localized: "New Session")) { [weak self] _ in
                guard let follower = self?.rexHosts[profile.id]?.follower else { return }
                Task { await follower.createSession() }
            },
            UIAction(title: String(localized: "Edit Host")) { [weak self] _ in
                self?.openEditor(profileID: profile.id)
            },
            UIAction(title: String(localized: "Delete Host"), attributes: .destructive) { [weak self] _ in
                self?.confirmDelete(profile)
            },
        ])
        return button
    }

    private func configureRexRow(_ cell: UICollectionViewListCell, item: Item) {
        guard case .rexRow(let hostID, _) = item, let row = rexRows[item] else { return }
        let palette = sshTerminalThemeID.palette
        let prefix = "sshTerminal.rexList.\(hostID.uuidString)"
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.color = palette.ui.fg
        content.secondaryTextProperties.color = palette.ui.comment
        cell.accessories = []
        cell.accessibilityTraits = []
        switch row.kind {
        case .retry:
            // The action cell draws it.
            break
        case .header(let name, let needsYou):
            content.text = name
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.image = SSHTerminalBarAction.rex.image()
            content.imageProperties.tintColor = palette.ui.comment
            content.secondaryText = needsYou > 0 ? "Rex \u{00B7} " + SSHTerminalRexListRow.needsYouText(needsYou) : "Rex"
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.secondaryTextProperties.color = UIColor(needsYou > 0 ? palette.orange : palette.comment)
            cell.accessibilityIdentifier = "\(prefix).header"
            cell.accessibilityTraits = .header
            // The heading is the host in Rex mode (no host row is listed), so its
            // actions ride here: a saved host's form and delete, and a tailnet node's
            // session (it has no form of its own).
            cell.accessories = []
            if let profile = profiles.first(where: { $0.id == hostID }) {
                cell.accessories = [.customView(configuration: .init(
                    customView: hostMenuButton(profile, palette: palette),
                    placement: .trailing()
                ))]
            } else if tailnetRex.follower(id: hostID) != nil {
                cell.accessories = [.customView(configuration: .init(
                    customView: tailnetMenuButton(hostID, palette: palette),
                    placement: .trailing()
                ))]
            }
        case .placeholder(let text):
            content.text = text
            content.textProperties.color = palette.ui.comment
            cell.accessibilityIdentifier = "\(prefix).\(row.id)"
        case .failure(let text):
            content.text = text
            content.textProperties.color = palette.ui.red
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "\(prefix).\(row.id)"
        case .window(let windowID, let name):
            content.text = name
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = palette.ui.comment
            cell.indentationLevel = 1
            cell.accessibilityIdentifier = "\(prefix).\(windowID)"
            cell.accessibilityTraits = .header
        case .session, .pane, .tapToConnect, .newSession:
            break
        }
        cell.contentConfiguration = content
    }

    private func configureRexAction(_ cell: SSHTerminalRexListActionCell, item: Item) {
        guard case .rexRow(let hostID, let id) = item, let row = rexRows[item] else { return }
        let themeID = sshTerminalThemeID
        let palette = themeID.palette
        let prefix = "sshTerminal.rexList.\(hostID.uuidString)"
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.color = palette.ui.fg
        content.secondaryTextProperties.color = palette.ui.comment
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        switch row.kind {
        case .pane(let pane):
            content.text = pane.name
            content.secondaryText = pane.detail
            // The pane Rex types into is bold, as in the overview.
            let body = UIFont.preferredFont(forTextStyle: .body)
            content.textProperties.font = pane.isFocused
                ? body.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? body : body
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.image = pane.icon.image()
            content.imageProperties.tintColor = palette.ui.comment
            // How long ago the pane's program last moved rides in the status label: a
            // list cell has one trailing label.
            cell.accessories = cell.statusAccessories(for: pane.status, themeID: themeID, suffix: pane.activity)
            cell.indentationLevel = pane.windowName == nil ? 1 : 2
            cell.configureAction(
                identifier: "\(prefix).\(pane.blockID)",
                label: pane.accessibilityLabel,
                value: [pane.status.label, pane.activity].compactMap { $0 }.joined(separator: ", "),
                hint: "Open this pane"
            ) { [weak self] in self?.activateRexRow(host: hostID, id: id) }
        case .newSession(let busy):
            content.text = busy ? "Working\u{2026}" : "New Session"
            content.textProperties.color = UIColor(busy ? palette.comment : palette.blue)
            content.image = UIImage(systemName: "plus")
            content.imageProperties.tintColor = UIColor(busy ? palette.comment : palette.blue)
            cell.accessories = []
            cell.indentationLevel = 0
            cell.configureAction(
                identifier: "\(prefix).new",
                label: "New Session",
                value: busy ? "Working" : nil,
                hint: "Makes a session with a shell and opens it"
            ) { [weak self] in self?.activateRexRow(host: hostID, id: id) }
        case .retry(let title):
            content.text = title
            content.textProperties.color = palette.ui.blue
            cell.accessories = []
            cell.indentationLevel = 0
            cell.configureAction(
                identifier: "\(prefix).retry",
                label: title,
                value: nil,
                hint: "Reads this host's Rex again"
            ) { [weak self] in self?.activateRexRow(host: hostID, id: id) }
        case .tapToConnect:
            content.text = "Tap to connect"
            content.textProperties.color = palette.ui.blue
            cell.accessories = []
            cell.indentationLevel = 0
            cell.configureAction(
                identifier: "\(prefix).connect",
                label: "Tap to connect",
                value: nil,
                hint: "Signs in to read this host's Rex sessions"
            ) { [weak self] in self?.activateRexRow(host: hostID, id: id) }
        default:
            break
        }
        cell.contentConfiguration = content
    }

    private func configureRexSession(_ cell: SSHTerminalRexListSessionCell, item: Item) {
        guard case .rexRow(let hostID, let id) = item, case .session(let session)? = rexRows[item]?.kind else { return }
        let themeID = sshTerminalThemeID
        cell.contentConfiguration = nil
        cell.indentationLevel = 0
        cell.configureSession(
            session, identifier: "sshTerminal.rexList.\(hostID.uuidString).\(session.sessionID)", themeID: themeID,
            actions: session.manages ? [
                UIAccessibilityCustomAction(name: "Rename") { [weak self] _ in
                    self?.renameRexSession(host: hostID, id: id)
                    return true
                },
                UIAccessibilityCustomAction(name: "Close Session") { [weak self] _ in
                    self?.closeRexSession(host: hostID, id: id)
                    return true
                },
            ] : [],
            perform: { [weak self] in self?.activateRexRow(host: hostID, id: id) },
            toggle: { [weak self] in self?.toggleRexSession(host: hostID, id: id) },
            newPane: session.manages ? { [weak self] in self?.newRexPane(host: hostID, session: session.sessionID) } : nil
        )
    }

    /// The session a row stands for and the follower that can change it now,
    /// resolved when the action runs from the row's identity.
    private func manageableSession(host hostID: UUID, id: String) -> (follower: any SSHTerminalRexListFollowing, sessionID: String, name: String)? {
        guard let follower = rexFollower(hostID), follower.canManage,
              case .session(let session)? = rexRows[.rexRow(host: hostID, id: id)]?.kind else { return nil }
        let label = follower.monitor.snapshot?.sessions.first { $0.sessionID == session.sessionID }?.label
        return (follower, session.sessionID, label ?? "")
    }

    /// Rename: a text field with the session's name. An empty name gives the
    /// session back the name Rex chose for it.
    private func renameRexSession(host hostID: UUID, id: String) {
        guard let target = manageableSession(host: hostID, id: id) else { return }
        TextPrompt(
            title: "Rename Session", message: "Leave it empty to use the name Rex chose.",
            placeholder: "Session name", text: target.name, actionTitle: "Rename",
            fieldIdentifier: "sshTerminal.rexList.rename.field", actionIdentifier: "sshTerminal.rexList.rename.confirm"
        ).present(from: self) { name in
            Task { await target.follower.rename(session: target.sessionID, to: name) }
        }
    }

    /// Close asks first: every pane's program ends.
    private func closeRexSession(host hostID: UUID, id: String) {
        guard let target = manageableSession(host: hostID, id: id) else { return }
        let name = target.name.isEmpty ? "Session" : target.name
        Confirmation(
            title: "Close session \u{201C}\(name)\u{201D}?",
            message: "Every pane's program ends.",
            actionTitle: "Close Session",
            style: .alert,
            actionIdentifier: "sshTerminal.rexList.close.confirm"
        ).present(from: self, anchor: nil) {
            Task { await target.follower.close(session: target.sessionID) }
        }
    }

    /// A session's ⊕: a new pane in it, opened in a terminal of its own.
    private func newRexPane(host hostID: UUID, session sessionID: String) {
        guard let follower = rexFollower(hostID) else { return }
        Task { await follower.createPane(session: sessionID) }
    }

    /// Shows or hides a session's panes. Resolved from the row's identity when it runs.
    private func toggleRexSession(host hostID: UUID, id: String) {
        guard let follower = rexFollower(hostID), case .session(let session)? = rexRows[.rexRow(host: hostID, id: id)]?.kind else { return }
        follower.toggleExpanded(session: session.sessionID)
        // Kept on this device, so coming back to the tab does not fold a session
        // someone was reading. The tailnet nodes' ids are stand-ins and are not kept.
        if rexHosts[hostID] != nil {
            profileStore().rexExpanded.setExpanded(follower.expandedSessions, for: hostID)
        }
        setNeedsUpdateProperties()
    }

    /// The one action a Rex row has, for a touch (the row's selection) and for
    /// VoiceOver's activation: resolved from the row's identity when it runs.
    private func activateRexRow(host hostID: UUID, id: String) {
        guard let row = rexRows[.rexRow(host: hostID, id: id)] else { return }
        // A retry asks about the host that has no follower, so it needs none: the one
        // row a host without Rex draws has to be reachable.
        if case .retry = row.kind {
            Task { await refreshRexHosts() }
            return
        }
        guard let follower = rexFollower(hostID) else { return }
        switch row.kind {
        case .session(let session):
            guard !follower.isOpening else { return }
            follower.open(session: session.sessionID)
        case .pane(let pane):
            guard !follower.isOpening else { return }
            follower.open(session: pane.sessionID, pane: pane.blockID)
        case .newSession:
            guard follower.canManage else { return }
            Task { await follower.createSession() }
        case .tapToConnect:
            follower.connect()
        default:
            break
        }
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        if case .rexRow(let hostID, let id) = item { return rexSwipeActions(host: hostID, id: id) }
        guard case .host(let id) = item, let profile = profiles.first(where: { $0.id == id }) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete Host") { [weak self] _, _, done in
            self?.confirmDelete(profile)
            done(true)
        }
        delete.accessibilityLabel = "Delete Host"
        // UIContextualAction is not UIAccessibilityIdentification: there is no
        // public accessibilityIdentifier (SwiftUI swipe had sshTerminal.host.delete).
        let config = UISwipeActionsConfiguration(actions: [delete])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    /// A session's swipe: Rename, and Close, which asks first (so a full swipe
    /// must not run it, and the row stays until the person confirms). Only
    /// while Rex can be changed.
    private func rexSwipeActions(host hostID: UUID, id: String) -> UISwipeActionsConfiguration? {
        guard manageableSession(host: hostID, id: id) != nil else { return nil }
        let rename = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, done in
            self?.renameRexSession(host: hostID, id: id)
            done(false)
        }
        rename.backgroundColor = sshTerminalThemeID.palette.ui.blue
        let close = UIContextualAction(style: .destructive, title: "Close") { [weak self] _, _, done in
            self?.closeRexSession(host: hostID, id: id)
            done(false)
        }
        let config = UISwipeActionsConfiguration(actions: [close, rename])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .addHost:
            openEditor(profileID: nil)
        case .host(let id):
            guard !session.connecting, !session.passwordPrompt,
                  let profile = profiles.first(where: { $0.id == id }) else { return }
            open(profile)
        case .reset:
            confirmReset()
        case .rexRow(let hostID, let id):
            activateRexRow(host: hostID, id: id)
        case .trustUnknown, .trustMismatch:
            chrome?.reopenTrust()
        default:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard case .rexRow = dataSource?.itemIdentifier(for: indexPath) else { return true }
        return dataSource?.itemIdentifier(for: indexPath).flatMap { rexRows[$0]?.kind.isAction } ?? false
    }

    private func openEditor(profileID: UUID?) {
        Router.push(SSHTerminalSetupViewController(profileID: profileID), from: self)
    }

    /// A host row opens its own login shell, with its Run on Connect command. What the
    /// page lists is the mode's (`SSHTerminalPageMode`); a host is a plain SSH login,
    /// so its row is never a Rex screen.
    private func open(_ profile: SSHTerminalProfile) {
        connect(profile)
    }

    private func connect(_ profile: SSHTerminalProfile, password: String? = nil) {
        connectingProfile = profile.normalized()
        // A row is the host's own terminal, whatever this session last showed.
        SSHTerminalFolderEntry.prepare(session: session, profile: connectingProfile, target: nil)
        session.connect(
            profile: connectingProfile,
            suppliedPassword: password
        ) { [weak self] _ in
            self?.reload()
        }
    }

    private func connect(password: String) {
        connect(connectingProfile, password: password)
    }

    private func editConnectedHost() {
        if let id = session.connectedProfile?.id { editAfterTerminal = id }
        session.showsTerminal = false
    }

    /// Asks to delete a host. The row's ⋯ **Delete Host** and its swipe both end
    /// here, and the sheet's confirming button runs `deleteHost(_:)`. Not private,
    /// so a test reaches the same owner action a touch does.
    func confirmDelete(_ profile: SSHTerminalProfile) {
        Confirmation(
            title: "Delete this host and its saved passwords?",
            actionTitle: "Delete Host",
            actionIdentifier: "sshTerminal.host.delete.confirm"
        ).present(from: self, anchor: nil) { [weak self] in self?.deleteHost(profile) }
    }

    /// Removes a host, its saved passwords, and its terminals: what the
    /// confirmation's button runs. Not private, so a test reaches the same owner
    /// action the sheet does rather than re-implementing a delete.
    func deleteHost(_ profile: SSHTerminalProfile) {
        do {
            if session.connectedProfile?.id == profile.id { session.cancel() }
            try profileStore().delete(id: profile.id)
            SSHTerminalRegistry.shared.closeAllTerminals(of: profile.id, reason: "The host was deleted.")
            reload()
        } catch {
            session.failure = error.localizedDescription
        }
    }

    /// Corrupt metadata cannot name per-profile password accounts, so this
    /// drops only the unreadable defaults value. It does not scan the Keychain.
    private func confirmReset() {
        Confirmation(
            title: "Reset the host list?",
            message: "The saved host data cannot be read. This removes it so you can add your hosts again.",
            actionTitle: "Reset Host List"
        ).present(from: self, anchor: nil) { [weak self] in
            self?.profileStore().discardCorruptMetadata()
            self?.reload()
        }
    }

    private func reload() {
        let store = profileStore()
        metadataIsCorrupt = store.metadataIsCorrupt
        profiles = store.load()
        if metadataIsCorrupt { profiles = [] }
        syncPlusItem()
        syncRexHosts()
        // The SSH hosts' Rex just changed: the tailnet list leaves out what they list.
        syncTailnetRex(active: isActive)
        applySnapshot()
    }

    /// A terminal of this tab's own or of one of its Rex sections is showing.
    private var terminalShown: Bool {
        session.showsTerminal || rexHosts.values.contains { $0.follower.session.showsTerminal }
            || tailnetRex.listedFollowers.contains { $0.session.showsTerminal }
    }

    /// The tab follows Rex only while it shows, in the foreground, with
    /// nothing over it: a pane's terminal, the form, and a sign-in sheet each
    /// cover it.
    private var isActive: Bool {
        let covered = terminalShown || editAfterTerminal != nil || presentedViewController != nil
        return isOnScreen && !AppScenePhase.shared.isBackground && !covered
    }
}
