import UIKit

/// The Rex screen (the sidebar's Rex, and a pane's Rex): every Rex this device
/// reaches, each as a section of its sessions with their panes inline. First the
/// Rexes reached straight over Tailscale (found on the tailnet, or added by name
/// in Rex on Your Tailnet), with no SSH and no sign-in; then the saved SSH hosts,
/// whose Rex is read over that host. A saved host whose Rex is one of the direct
/// ones is left out (`RexListDedupe`). A tap opens that session or pane in a
/// terminal; a session's swipe renames or closes it, its ⊕ adds a pane, and ＋
/// or a heading's ⋯ makes a session.
///
/// A `ListScreenController`: the base owns the list, the theme, the snapshot,
/// the swipe actions, and the rows' redraw keys. This page owns the followers
/// behind the sections, which read Rex only while it shows with nothing over it,
/// and its own pull to refresh (it loads nothing itself).
final class RexListViewController: ListScreenController<RexListViewController.Section, RexListViewController.Item> {
    var showsSidebarToggle = false {
        didSet { if isViewLoaded { installBarItems() } }
    }

    /// One run of a Rex's rows (`SSHTerminalRexListGroup`): its heading, its status
    /// card, a session's heading, or a session's panes.
    enum Section: Hashable, Sendable { case group(host: UUID, id: String) }
    enum Item: Hashable, Sendable {
        /// A row of a Rex's section, by the Rex (a saved host's id, or a tailnet
        /// node's stand-in id) and the row's id there.
        case rexRow(host: UUID, id: String)
    }

    /// How a saved host's follower is made. The screen never prompts on its own;
    /// the debug harness and tests pass one over a stand-in Rex.
    private let makeFollower: @MainActor (SSHTerminalProfile) -> SSHTerminalRexFollower
    /// Where the saved hosts live. Tests pass a store over their own defaults.
    private let profileStore: @Sendable () -> SSHTerminalProfileStore
    /// A saved host's section: its follower, and the chrome that signs it in.
    private struct RexHost {
        let follower: SSHTerminalRexFollower
        let chrome: SSHTerminalConnectChrome
    }

    private var rexHosts: [UUID: RexHost] = [:]
    /// The Rexes reached over Tailscale alone, each a section of its own.
    private let tailnetRex: RexTailnetSection
    /// The connect chrome of each tailnet Rex's follower, by its id: it pushes
    /// the terminal a tapped session opens.
    private var tailnetChromes: [UUID: SSHTerminalConnectChrome] = [:]
    /// Starts Oppi's own Tailscale node when the person connected it in
    /// Settings, for its machine list. Tests pass one that does nothing.
    private let startsTailnet: @MainActor () -> Void
    /// What the Rex rows drew last, by item: `inputs(of:)` keys a row on its own
    /// value, so only a row that changed is configured again and a working
    /// pane's mark keeps animating.
    private var rexRows: [Item: SSHTerminalRexListRow] = [:]
    /// How each section draws: on the page's background, or as a card.
    private var groupStyles: [Section: SSHTerminalRexListGroup.Style] = [:]
    /// The route each Rex heading names, by Rex: a saved host's can change as
    /// its follower reads Rex over Tailscale or SSH.
    private var routeLabels: [UUID: String] = [:]
    private var profiles: [SSHTerminalProfile] = []
    /// The saved hosts this screen lists: every saved host but the ones whose Rex
    /// is a listed direct Rex.
    private var listedProfiles: [SSHTerminalProfile] = []
    /// Each saved host's Rex id as its own stream said it, kept while the screen
    /// lives: a host left out for being a direct Rex has no follower to say it
    /// again, and must stay left out.
    private var savedHostIDs: [UUID: String] = [:]
    private var isOnScreen = false
    /// False while the pane this page sits in is covered or parked
    /// (`PaneVisibility`): its view stays in the window, but nobody sees it.
    private var paneShown = true
    private var editAfterTerminal: UUID?
    /// The Rex experiment's switch changing while this screen is up.
    private var experimentObserver: NSObjectProtocol?

    init(
        showsSidebarToggle: Bool = false,
        profileStore: @escaping @Sendable () -> SSHTerminalProfileStore = { SSHTerminalProfileStore() },
        makeFollower: @escaping @MainActor (SSHTerminalProfile) -> SSHTerminalRexFollower = {
            SSHTerminalRexFollower(profile: $0, promptsAutomatically: false)
        },
        tailnetRex: RexTailnetSection = RexTailnetSection(),
        startsTailnet: @escaping @MainActor () -> Void = { TailnetNodeController.shared.startIfEnabled() }
    ) {
        self.showsSidebarToggle = showsSidebarToggle
        self.profileStore = profileStore
        self.makeFollower = makeFollower
        self.tailnetRex = tailnetRex
        self.startsTailnet = startsTailnet
        super.init(title: String(localized: "Rex"), listIdentifier: "rex.list", headers: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// This device's experiments, narrowed to what the window's server offers.
    private var access: SSHTerminalExperimentAccess {
        SSHTerminalExperimentAccess.current.narrowed(
            to: .offered(by: AppRootEnvironment.near(self)?.windowConnection)
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installBarItems()
        reload()
        // Rex is an experiment: its switch turned while this screen is up takes
        // effect here without a relaunch.
        experimentObserver = NotificationCenter.default.addObserver(
            forName: AppPreferences.Experiments.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followersAppeared() }
        }
        updatePropertiesIfNeeded()
    }

    isolated deinit {
        if let experimentObserver { NotificationCenter.default.removeObserver(experimentObserver) }
    }

    private func followersAppeared() {
        reload()
        for host in rexHosts.values { host.follower.appeared() }
        for follower in tailnetRex.listedFollowers { follower.appeared() }
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        // The saved hosts first: a host edited or deleted while this screen was
        // covered must not be signed in from the old copy.
        followersAppeared()
        // Oppi's own node lists the tailnet's machines; it starts only if the
        // person connected Tailscale in Settings.
        startsTailnet()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        // A screen pushed over this one (a terminal, a form) leaves the saved
        // hosts' connections up, read again on return; leaving closes them.
        let covered = navigationController?.viewControllers.contains(self) == true && !isBeingDismissed
        stopFollowing(closing: !covered)
    }

    /// The sections stop reading while nobody sees them; `closing` also ends the
    /// saved hosts' connections, which sign in again when the screen returns.
    private func stopFollowing(closing: Bool) {
        for host in rexHosts.values {
            host.follower.stopReading()
            host.chrome.hostDidDisappear()
            if closing { host.follower.close() }
        }
        for follower in tailnetRex.listedFollowers {
            follower.stopReading()
            tailnetChromes[follower.host.id]?.hostDidDisappear()
        }
        tailnetRex.stop()
    }

    override func updateProperties() {
        _ = AppScenePhase.shared.isBackground
        for host in rexHosts.values { _ = host.follower.session.showsTerminal }
        for follower in tailnetRex.listedFollowers { _ = follower.session.showsTerminal }
        _ = sshTerminalThemeID
        if !terminalShown, let id = editAfterTerminal {
            editAfterTerminal = nil
            openEditor(profileID: id)
        }
        let active = isActive
        // The direct Rexes first: which saved hosts are listed depends on them.
        syncTailnetRex(active: active)
        syncListedHosts()
        // ＋ names the Rexes it can start a session on, which this pass may have
        // just found.
        syncPlusItem()
        super.updateProperties()
        syncRefreshControl()
        // Signing in to every saved host is bounded: the followers already
        // connecting count, the rest are granted in saved order so the first
        // screenful fills first, and only a follower that will really dial is
        // charged.
        var budget = SSHTerminalConnectBudget(
            max(0, SSHTerminalConnectBudget.inFlight - rexHosts.values.filter { $0.follower.session.connecting }.count)
        )
        for profile in listedProfiles {
            guard let host = rexHosts[profile.id] else { continue }
            host.chrome.sync()
            guard active else {
                host.follower.sync(active: false)
                continue
            }
            let follower = host.follower
            follower.sync(active: !follower.wouldStartSignIn || budget.take())
            if let sessions = follower.monitor.snapshot?.sessions {
                profileStore().rexCollapsed.prune(to: Set(sessions.map(\.sessionID)), for: profile.id)
                follower.collapsedSessions.formIntersection(sessions.map(\.sessionID))
            }
        }
    }

    // MARK: - The list

    /// The direct Rexes, then the saved hosts'. Each Rex is its heading (its name
    /// and the way it is reached), a card of anything about its connection, and
    /// each session's small heading over a card of its panes.
    override func sections() -> [ListSection<Section, Item>] {
        var sections: [ListSection<Section, Item>] = []
        var rows: [Item: SSHTerminalRexListRow] = [:]
        var styles: [Section: SSHTerminalRexListGroup.Style] = [:]
        var routes: [UUID: String] = [:]
        func add(_ id: UUID, _ groups: [SSHTerminalRexListGroup], route: String) {
            routes[id] = route
            for group in groups {
                let section = Section.group(host: id, id: group.id)
                let items = group.rows.map { Item.rexRow(host: id, id: $0.id) }
                for (item, row) in zip(items, group.rows) { rows[item] = row }
                styles[section] = group.style
                sections.append(ListSection(section, items: items))
            }
        }
        let tailscale = String(localized: "Tailscale")
        for follower in tailnetRex.listedFollowers {
            add(follower.host.id, SSHTerminalRexListRow.groups(hostName: follower.host.name, state: follower.listState), route: tailscale)
        }
        for profile in listedProfiles {
            let overTailscale = if case .tailscale? = rexHosts[profile.id]?.follower.monitor.route { true } else { false }
            add(profile.id, rexSectionGroups(for: profile), route: overTailscale ? tailscale : String(localized: "SSH"))
        }
        rexRows = rows
        groupStyles = styles
        routeLabels = routes
        return sections
    }

    /// Headings sit on the page's background, close over the card they head;
    /// cards follow their heading with no gap.
    override func layoutSection(for section: Section, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        guard let style = groupStyles[section] else { return nil }
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.backgroundColor = .clear
        config.headerMode = .none
        config.showsSeparators = style == .card
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let item = dataSource?.itemIdentifier(for: indexPath)?.pageItem else { return nil }
            return trailingSwipeActions(for: item)
        }
        let layout = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        var insets = layout.contentInsets
        switch (style, section) {
        case (.heading, .group(_, "heading")):
            insets.top = 22
            insets.bottom = 4
        case (.heading, _):
            insets.top = 10
            insets.bottom = 2
        case (.card, _):
            insets.top = 2
            insets.bottom = 4
        }
        layout.contentInsets = insets
        return layout
    }

    override func emptyState() -> LoadState? {
        .empty(
            title: String(localized: "No Rex Yet"),
            systemImage: "rectangle.split.3x1",
            message: String(localized: "Turn on Find Rex on Your Tailnet, or add a Rex by its Tailscale name, in Rex settings (⚙︎). A saved SSH host's Rex shows here too.")
        )
    }

    /// A Rex row is keyed on the row itself, so a pass that changes another row
    /// (or none) leaves a working pane's mark animating.
    override func inputs(of item: Item) -> AnyHashable {
        guard case .rexRow(let host, "header") = item else { return AnyHashable(rexRows[item]) }
        return AnyHashable([AnyHashable(rexRows[item]), AnyHashable(routeLabels[host])])
    }

    /// A follower's answer replaces its rows at once.
    override var animatesUpdates: Bool { false }

    // MARK: - Rows

    override func prepareRegistrations() {
        _ = (rexCell, rexActionCell, rexSessionCell)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        // A session is a row with a disclosure; a pane and the rows that ask
        // something are buttons; the rest read.
        switch rexRows[item]?.kind {
        case .session:
            return collectionView.dequeueConfiguredReusableCell(using: rexSessionCell, for: indexPath, item: item)
        case .pane, .tapToConnect, .newSession, .retry, .startRex:
            return collectionView.dequeueConfiguredReusableCell(using: rexActionCell, for: indexPath, item: item)
        default:
            return collectionView.dequeueConfiguredReusableCell(using: rexCell, for: indexPath, item: item)
        }
    }

    private lazy var rexCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
        self?.configureRexRow(cell, item: item)
    }

    private lazy var rexActionCell = UICollectionView.CellRegistration<SSHTerminalRexListActionCell, Item> { [weak self] cell, _, item in
        self?.configureRexAction(cell, item: item)
    }

    private lazy var rexSessionCell = UICollectionView.CellRegistration<SSHTerminalRexListSessionCell, Item> { [weak self] cell, _, item in
        self?.configureRexSession(cell, item: item)
    }

    override func isSelectable(_ item: Item) -> Bool { rexRows[item]?.kind.isAction ?? false }

    override func select(_ item: Item) {
        guard case .rexRow(let hostID, let id) = item else { return }
        activateRexRow(host: hostID, id: id)
    }

    /// A heading or a muted line does not flash under the finger. `@objc`
    /// because the base, not this class, conforms to the delegate.
    @objc func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource?.itemIdentifier(for: indexPath)?.pageItem else { return true }
        return rexRows[item]?.kind.isAction ?? false
    }

    override func rowActions(for item: Item) -> [ListRowAction] {
        guard case .rexRow(let hostID, let id) = item else { return [] }
        return rexRowActions(host: hostID, id: id)
    }

    // MARK: - Bar items

    /// ＋ starts a session (on the one Rex listed, or the one picked from its
    /// menu), and ⚙︎ opens Rex on Your Tailnet, where Rexes are found and added.
    private func installBarItems() {
        let hosts = sessionHosts
        hostsShown = hosts.map { "\($0.id.uuidString)|\($0.endpointLabel)" }
        var items: [UIBarButtonItem] = []
        if !hosts.isEmpty {
            // With several Rexes the item is a menu with no action of its own.
            let add = UIBarButtonItem(
                title: String(localized: "New Session"),
                image: UIImage(systemName: "plus"),
                primaryAction: hosts.count == 1 ? UIAction { [weak self] _ in self?.startSession(on: hosts[0]) } : nil,
                menu: hosts.count > 1 ? UIMenu(children: hosts.map { profile in
                    UIAction(title: profile.endpointLabel) { [weak self] _ in self?.startSession(on: profile) }
                }) : nil
            )
            add.accessibilityIdentifier = "rex.newSession"
            items.append(add)
        }
        let settings = UIBarButtonItem(
            title: String(localized: "Rex on Your Tailnet"),
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                Router.push(SSHTerminalRexTailnetSettingsViewController(), from: self)
            }
        )
        settings.accessibilityIdentifier = "rex.settings"
        items.append(settings)
        navigationItem.rightBarButtonItems = items
        if showsSidebarToggle, let root = AppRootEnvironment.near(self) {
            navigationItem.leftBarButtonItem = WorkspaceSplitSidebarToggle.makeItem(root: root)
        }
    }

    /// The Rexes ＋ was built for, by id and name: one found, gone, or renamed
    /// rebuilds it.
    private var hostsShown: [String] = []

    private func syncPlusItem() {
        if hostsShown != sessionHosts.map({ "\($0.id.uuidString)|\($0.endpointLabel)" }) { installBarItems() }
    }

    /// Every Rex ＋ can start a session on, in the screen's order.
    private var sessionHosts: [SSHTerminalProfile] {
        tailnetRex.listedFollowers.map(\.profile) + listedProfiles
    }

    /// A session on this Rex, opened on its new pane.
    private func startSession(on profile: SSHTerminalProfile) {
        guard let follower = rexFollower(profile.id) else { return }
        Task { await follower.createSession() }
    }

    // MARK: - Pull to refresh

    /// The pull is the page's own, and only while there is a Rex to ask again.
    private func syncRefreshControl() {
        let refreshes = !listedProfiles.isEmpty || tailnetRex.isShown
        if (collectionView.refreshControl != nil) != refreshes {
            collectionView.refreshControl = refreshes ? rexRefreshControl : nil
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

    /// A pull reads every Rex again without asking for anything, tries again
    /// where a host had no Rex or no `nc`, and asks the tailnet's machines again.
    private func refreshRexHosts() async {
        // The hosts whose last read found no Rex need a follower again; the pass
        // that follows grants their sign-ins under the budget.
        let store = profileStore()
        let remembered = listedProfiles.filter { store.rexHosts.hasNoRex(on: $0) }
        store.rexHosts.forgetNoRex()
        if !remembered.isEmpty {
            syncRexHosts()
            setNeedsUpdateProperties()
        }
        // Only a follower already connected is asked on the pull itself: reading
        // again costs it no sign-in.
        var reads = rexHosts.values.map(\.follower).filter(\.isConnected).map { follower in
            Task { @MainActor in await follower.refresh() }
        }
        reads += tailnetRex.listedFollowers.map { follower in Task { @MainActor in await follower.refresh() } }
        reads.append(Task { @MainActor [tailnetRex] in await tailnetRex.refresh() })
        for read in reads { await read.value }
    }

    // MARK: - Which Rexes

    /// A saved host's rows: its heading and what its follower last read. A host
    /// known to have no Rex has no follower this visit, and keeps one muted line
    /// and the way to ask again.
    private func rexSectionGroups(for profile: SSHTerminalProfile) -> [SSHTerminalRexListGroup] {
        guard let follower = rexHosts[profile.id]?.follower else {
            return [
                .init(id: "heading", style: .heading, rows: [.init(id: "header", kind: .header(name: profile.endpointLabel, needsYou: 0))]),
                .init(id: "status", style: .card, rows: [
                    .init(id: "noRex", kind: .placeholder(String(localized: "No Rex on this host."))),
                    .init(id: "retry", kind: .retry(String(localized: "Retry"))),
                ]),
            ]
        }
        return SSHTerminalRexListRow.groups(hostName: profile.endpointLabel, state: follower.listState)
    }

    /// Which saved hosts are listed now (`RexListDedupe`), and their followers.
    /// With Rex's experiment off nothing on this screen reaches Rex.
    private func syncListedHosts() {
        for (id, host) in rexHosts {
            if let hostID = host.follower.monitor.hostID { savedHostIDs[id] = hostID }
        }
        let learned = tailnetRex.store
        let saved = profiles.map { profile in
            let learnedRex = learned.learned(for: RexDirectHost(profile: profile))
            return RexListDedupe.Saved(
                id: profile.id, hostID: savedHostIDs[profile.id],
                learnedAddress: learnedRex?.address, learnedHostID: learnedRex?.hostID
            )
        }
        let direct = tailnetRex.listedFollowers.map { RexListDedupe.Direct(address: $0.host.address, hostID: $0.monitor.hostID) }
        let shown = Set(RexListDedupe.savedShown(saved, direct: direct))
        let listed = access.rex ? profiles.filter { shown.contains($0.id) } : []
        guard listed != listedProfiles else { return }
        listedProfiles = listed
        syncRexHosts()
    }

    /// Makes, updates, and drops a follower per listed saved host. A host whose
    /// last read found no Rex is not dialled again until a pull or its Retry.
    private func syncRexHosts() {
        let noRex = profileStore().rexHosts
        let wanted = listedProfiles.filter { !noRex.hasNoRex(on: $0) }
        for id in rexHosts.keys where !wanted.contains(where: { $0.id == id }) {
            guard let host = rexHosts[id] else { continue }
            // A host with no Rex is dropped without owing another sign-in.
            if noRex.hasNoRex(on: host.follower.profile) {
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
                host.follower.collapsedSessions = profileStore().rexCollapsed.collapsed(for: profile.id)
                rexHosts[profile.id] = host
            }
        }
    }

    /// The tailnet nodes from what Oppi's node knows now: a follower (and its
    /// connect chrome) per listed node, each run only while the screen is
    /// `active`.
    private func syncTailnetRex(active: Bool) {
        guard access.rex else {
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
        tailnetRex.update(peers: tailnet.onlinePeers, selfDNSName: tailnet.snapshot?.selfDNSName, active: active)
        let followers = tailnetRex.listedFollowers
        let listed = Set(followers.map(\.host.id))
        for id in tailnetChromes.keys where !listed.contains(id) {
            tailnetChromes[id]?.hostDidDisappear()
            tailnetChromes[id] = nil
        }
        for follower in followers {
            follower.monitor.readsHostID = true
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

    /// The follower behind a section: a saved host's, or a tailnet node's.
    private func rexFollower(_ id: UUID) -> (any SSHTerminalRexListFollowing)? {
        rexHosts[id]?.follower ?? tailnetRex.follower(id: id)
    }

    private func makeRexHost(_ profile: SSHTerminalProfile) -> RexHost {
        let follower = makeFollower(profile)
        follower.monitor.readsHostID = true
        // What the host's monitor finds keeps the memory of where Rex is, which a
        // terminal's Rex button still reads.
        follower.monitor.onFinding = { [weak self, weak follower] finding in
            guard let self, let follower else { return }
            self.profileStore().rexHosts.record(finding, on: follower.profile)
            // No Rex on the host: the store says so now, which drops the follower
            // without owing a sign-in, and the section keeps its muted line.
            if finding == .absent(.notInstalled) {
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

    // MARK: - Drawing the rows

    /// A heading's ⋯: New Session on every Rex, and Edit Host on a saved host.
    /// A menu button is one tap target, so VoiceOver's activation opens the same
    /// menu a touch does.
    private func headingMenuButton(_ hostID: UUID, palette: ThemePalette) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        config.baseForegroundColor = palette.ui.comment
        button.configuration = config
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "sshTerminal.rexList.\(hostID.uuidString).menu"
        var actions = [
            UIAction(title: String(localized: "New Session")) { [weak self] _ in
                guard let follower = self?.rexFollower(hostID) else { return }
                Task { await follower.createSession() }
            },
        ]
        if profiles.contains(where: { $0.id == hostID }) {
            actions.append(UIAction(title: String(localized: "Edit Host")) { [weak self] _ in
                self?.openEditor(profileID: hostID)
            })
        }
        button.menu = UIMenu(children: actions)
        return button
    }

    /// A heading sits on the page's background; every other row is a card's.
    private func paintBackground(_ cell: UICollectionViewListCell, heading: Bool) {
        cell.configurationUpdateHandler = { cell, state in
            cell.backgroundConfiguration = heading ? .clear() : SettingsStyle.cardBackground(for: state)
        }
        cell.setNeedsUpdateConfiguration()
    }

    private func configureRexRow(_ cell: UICollectionViewListCell, item: Item) {
        guard case .rexRow(let hostID, _) = item, let row = rexRows[item] else { return }
        let palette = sshTerminalThemeID.palette
        if case .header = row.kind { paintBackground(cell, heading: true) } else { paintBackground(cell, heading: false) }
        let prefix = "sshTerminal.rexList.\(hostID.uuidString)"
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.color = palette.ui.fg
        content.secondaryTextProperties.color = palette.ui.comment
        cell.accessories = []
        cell.accessibilityTraits = []
        cell.indentationLevel = 0
        switch row.kind {
        case .header(let name, let needsYou):
            // The Rex as a title over its sessions, with Rex's mark at a title's
            // symbol size, and how it is reached and who waits under its name.
            content.text = name
            content.textProperties.font = UIFont.scaled(.title3, .semibold)
            content.textProperties.numberOfLines = 1
            content.image = SymbolSizedLogo.image(
                named: "rex-logo",
                reference: "desktopcomputer",
                configuration: UIImage.SymbolConfiguration(textStyle: .title2),
                fallbackSide: 28
            )
            content.imageProperties.tintColor = palette.ui.fg
            content.imageToTextPadding = 12
            let route = routeLabels[hostID].map { "Rex via \($0)" } ?? "Rex"
            content.secondaryText = needsYou > 0 ? route + " \u{00B7} " + RexSnapshot.needsYouText(needsYou) : route
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.secondaryTextProperties.color = needsYou > 0 ? palette.orange : palette.comment
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
            cell.accessibilityIdentifier = "\(prefix).header"
            cell.accessibilityTraits = .header
            // The heading is the Rex: its actions ride here.
            if rexFollower(hostID) != nil || profiles.contains(where: { $0.id == hostID }) {
                cell.accessories = [.customView(configuration: .init(
                    customView: headingMenuButton(hostID, palette: palette),
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
            cell.indentationLevel = 0
            cell.accessibilityIdentifier = "\(prefix).\(windowID)"
            cell.accessibilityTraits = .header
        case .session, .pane, .tapToConnect, .newSession, .retry, .startRex:
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
        cell.accessories = []
        cell.indentationLevel = 0
        paintBackground(cell, heading: false)
        let perform: () -> Void = { [weak self] in self?.activateRexRow(host: hostID, id: id) }
        switch row.kind {
        case .pane(let pane):
            // The program, then its folder in the quiet colour on the same line, as
            // a prompt reads; the pane Rex types into is bold, as in the overview.
            let body = UIFont.preferredFont(forTextStyle: .body)
            let name = NSMutableAttributedString(string: pane.name, attributes: [
                .font: pane.isFocused
                    ? body.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? body : body,
                .foregroundColor: palette.ui.fg,
            ])
            // A shell that titles itself with its folder already says where it is.
            if let folder = pane.folder, !pane.name.hasPrefix("~"), !pane.name.hasPrefix("/") {
                name.append(NSAttributedString(string: "  " + folder, attributes: [.font: body, .foregroundColor: palette.ui.comment]))
            }
            content.attributedText = name
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingMiddle
            content.secondaryText = pane.detail
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.secondaryTextProperties.numberOfLines = 1
            content.image = pane.icon.image()
            content.imageProperties.tintColor = palette.ui.comment
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
            // How long ago the pane's program last moved rides in the status label;
            // the chevron says a tap opens it.
            cell.accessories = cell.statusAccessories(for: pane.status, themeID: themeID, suffix: pane.activity)
                + [.disclosureIndicator(options: .init(tintColor: palette.ui.comment))]
            cell.configureAction(
                identifier: "\(prefix).\(pane.blockID)",
                label: pane.accessibilityLabel,
                value: [pane.status.label, pane.activity].compactMap { $0 }.joined(separator: ", "),
                hint: "Open this pane",
                perform: perform
            )
        case .newSession(let busy):
            content.text = busy ? "Working\u{2026}" : "New Session"
            content.textProperties.color = busy ? palette.comment : palette.blue
            content.image = UIImage(systemName: "plus")
            content.imageProperties.tintColor = busy ? palette.comment : palette.blue
            cell.configureAction(
                identifier: "\(prefix).new", label: "New Session", value: busy ? "Working" : nil,
                hint: "Makes a session with a shell and opens it", perform: perform
            )
        case .retry(let title):
            content.text = title
            content.textProperties.color = palette.ui.blue
            cell.configureAction(identifier: "\(prefix).retry", label: title, value: nil, hint: "Reads this Rex again", perform: perform)
        case .startRex:
            content.text = String(localized: "Start Rex")
            content.textProperties.color = palette.ui.blue
            content.image = UIImage(systemName: "play.fill")
            content.imageProperties.tintColor = palette.ui.blue
            cell.configureAction(
                identifier: "\(prefix).startRex", label: String(localized: "Start Rex"), value: nil,
                hint: "Starts Rex on this host", perform: perform
            )
        case .tapToConnect:
            content.text = "Tap to connect"
            content.textProperties.color = palette.ui.blue
            cell.configureAction(
                identifier: "\(prefix).connect", label: "Tap to connect", value: nil,
                hint: "Signs in to read this host's Rex sessions", perform: perform
            )
        case .header, .placeholder, .failure, .window, .session:
            break
        }
        cell.contentConfiguration = content
    }

    private func configureRexSession(_ cell: SSHTerminalRexListSessionCell, item: Item) {
        guard case .rexRow(let hostID, let id) = item, case .session(let session)? = rexRows[item]?.kind else { return }
        cell.contentConfiguration = nil
        cell.indentationLevel = 0
        paintBackground(cell, heading: true)
        cell.configureSession(
            session, identifier: "sshTerminal.rexList.\(hostID.uuidString).\(session.sessionID)", themeID: sshTerminalThemeID,
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

    // MARK: - Changing Rex

    /// The session a row stands for and the follower that can change it now,
    /// resolved when the action runs from the row's identity.
    private func manageableSession(host hostID: UUID, id: String) -> (follower: any SSHTerminalRexListFollowing, sessionID: String, name: String)? {
        guard let follower = rexFollower(hostID), follower.canManage,
              case .session(let session)? = rexRows[.rexRow(host: hostID, id: id)]?.kind else { return nil }
        let label = follower.monitor.snapshot?.sessions.first { $0.sessionID == session.sessionID }?.label
        return (follower, session.sessionID, label ?? "")
    }

    /// Rename: an empty name gives the session back the name Rex chose for it.
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

    /// Folds or unfolds a session's panes, kept on this device per saved host (a
    /// tailnet node's id is a stand-in and is not kept).
    private func toggleRexSession(host hostID: UUID, id: String) {
        guard let follower = rexFollower(hostID), case .session(let session)? = rexRows[.rexRow(host: hostID, id: id)]?.kind else { return }
        follower.toggleExpanded(session: session.sessionID)
        if rexHosts[hostID] != nil {
            profileStore().rexCollapsed.setCollapsed(follower.collapsedSessions, for: hostID)
        }
        setNeedsUpdateProperties()
    }

    /// The one action a Rex row has, for a touch and for VoiceOver's
    /// activation: resolved from the row's identity when it runs.
    private func activateRexRow(host hostID: UUID, id: String) {
        guard let row = rexRows[.rexRow(host: hostID, id: id)] else { return }
        // A retry asks about a host that has no follower, so it needs none.
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
        case .startRex:
            follower.monitor.startRex()
        default:
            break
        }
    }

    /// A session's swipe: Rename, and Close, which asks first (so a full swipe
    /// must not run it). Only while Rex can be changed.
    private func rexRowActions(host hostID: UUID, id: String) -> [ListRowAction] {
        guard manageableSession(host: hostID, id: id) != nil else { return [] }
        return [
            ListRowAction(title: "Close", systemImage: "xmark.circle", style: .destructive, performsWithFullSwipe: false) { [weak self] done in
                self?.closeRexSession(host: hostID, id: id)
                done(false)
            },
            ListRowAction(title: "Rename", systemImage: "textformat", tint: sshTerminalThemeID.palette.ui.blue) { [weak self] done in
                self?.renameRexSession(host: hostID, id: id)
                done(false)
            },
        ]
    }

    // MARK: - Hosts

    private func openEditor(profileID: UUID?) {
        Router.push(SSHTerminalSetupViewController(profileID: profileID), from: self)
    }

    /// Reads the saved hosts, then asks for the pass that lists them.
    private func reload() {
        let store = profileStore()
        profiles = store.metadataIsCorrupt ? [] : store.load()
        listedProfiles = listedProfiles.compactMap { listed in profiles.first { $0.id == listed.id } }
        syncRexHosts()
        setNeedsUpdateProperties()
    }

    /// A terminal one of the sections opened is showing.
    private var terminalShown: Bool {
        rexHosts.values.contains { $0.follower.session.showsTerminal }
            || tailnetRex.listedFollowers.contains { $0.session.showsTerminal }
    }

    /// The screen follows Rex only while it shows, in the foreground, with
    /// nothing over it: a terminal, the form, and a sign-in sheet each cover it.
    private var isActive: Bool {
        let covered = terminalShown || editAfterTerminal != nil || presentedViewController != nil
        return isOnScreen && paneShown && !AppScenePhase.shared.isBackground && !covered
    }
}

/// A screen in a pane stops following Rex while its pane is covered or parked,
/// as it does when a screen covers it, and follows again once the pane shows.
extension RexListViewController: PaneVisibilityObserving {
    func paneVisibilityDidChange(_ visibility: PaneVisibility) {
        let shown = if case .visible = visibility { true } else { false }
        guard shown != paneShown else { return }
        paneShown = shown
        if shown {
            for host in rexHosts.values { host.follower.appeared() }
            for follower in tailnetRex.listedFollowers { follower.appeared() }
        } else {
            stopFollowing(closing: false)
        }
        setNeedsUpdateProperties()
    }
}
