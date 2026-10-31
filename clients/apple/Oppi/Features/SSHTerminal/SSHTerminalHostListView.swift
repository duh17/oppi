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
    /// What the Rex rows drew last, by item: only a row whose inputs changed is
    /// reconfigured, so a working pane's mark keeps animating.
    private var rexRows: [Item: SSHTerminalRexListRow] = [:]
    private var rexRowsThemeID: ThemeID?
    private var isOnScreen = false
    private var connectingProfile = SSHTerminalProfile()
    private var metadataIsCorrupt = false
    private var editAfterTerminal: UUID?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var lastThemeID: ThemeID?

    private enum Section: Hashable { case status, rex(UUID), hosts, empty, terminal, reset }
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
        /// Settings > Terminal > Bottom Bar.
        case bottomBar
        case reset
    }

    init(
        showsSidebarToggle: Bool = false,
        profileStore: @escaping @Sendable () -> SSHTerminalProfileStore = { SSHTerminalProfileStore() },
        makeFollower: @escaping @MainActor (SSHTerminalProfile) -> SSHTerminalRexFollower = {
            SSHTerminalRexFollower(profile: $0, promptsAutomatically: false)
        }
    ) {
        self.showsSidebarToggle = showsSidebarToggle
        self.profileStore = profileStore
        self.makeFollower = makeFollower
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
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        // The saved hosts first: a host edited or deleted while this screen was
        // covered must not be signed in, or saved back, from the old copy.
        reload()
        for host in rexHosts.values { host.follower.appeared() }
        setNeedsUpdateProperties()
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
        let themeID = sshTerminalThemeID
        if lastThemeID != themeID {
            lastThemeID = themeID
            SettingsListStyle.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        let terminalShown = session.showsTerminal || rexHosts.values.contains { $0.follower.session.showsTerminal }
        if !terminalShown, let id = editAfterTerminal {
            editAfterTerminal = nil
            openEditor(profileID: id)
        }
        applySnapshot()
        chrome?.sync()
        // The tab follows Rex only while it shows, in the foreground, with
        // nothing over it: a pane's terminal, the form, and a sign-in sheet
        // each cover it.
        let covered = terminalShown || editAfterTerminal != nil || presentedViewController != nil
        let active = isOnScreen && !AppScenePhase.shared.isBackground && !covered
        for host in rexHosts.values {
            host.chrome.sync()
            host.follower.sync(active: active)
        }
    }

    private func installBarItems() {
        let add = UIBarButtonItem(
            title: "Add Host",
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.openEditor(profileID: nil) }
        )
        add.accessibilityIdentifier = "sshTerminal.host.add"
        navigationItem.rightBarButtonItem = add
        if showsSidebarToggle, let root = AppRootEnvironment.near(self) {
            navigationItem.leftBarButtonItem = WorkspaceSplitSidebarToggle.makeItem(root: root)
        }
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
                onEdit: { [weak self] in self?.openEditor(profileID: profile.id) }
            )
        }
        let indexCell = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
            let store = SSHTerminalBarStore()
            let layout = store.layout
            let keys = store.customKeys
            cell.configure(
                title: String(localized: "Bottom Bar"),
                systemImage: nil,
                value: layout.order.filter { layout.isShown($0) }.map { $0.title(customKeys: keys) }.joined(separator: ", "),
                identifier: "settings.sshTerminal.bar"
            ) { [weak self] in
                guard let self else { return }
                Router.push(SSHTerminalBarSettingsViewController(), from: self)
            }
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
                case .pane, .tapToConnect, .newSession:
                    collectionView.dequeueConfiguredReusableCell(using: rexActionCell, for: indexPath, item: item)
                default:
                    collectionView.dequeueConfiguredReusableCell(using: rexCell, for: indexPath, item: item)
                }
            case .host:
                collectionView.dequeueConfiguredReusableCell(using: hostCell, for: indexPath, item: item)
            case .bottomBar:
                collectionView.dequeueConfiguredReusableCell(using: indexCell, for: indexPath, item: item)
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
        content.textProperties.color = UIColor(palette.fg)
        content.secondaryTextProperties.color = UIColor(palette.comment)
        switch item {
        case .corrupt:
            content.text = SSHTerminalProfileStoreError.corruptMetadata.localizedDescription
            content.textProperties.numberOfLines = 0
        case .connecting:
            configureConnecting(cell, palette: palette)
            return
        case .failure(let message):
            content.text = "Disconnected — \(message)"
            content.textProperties.color = UIColor(palette.red)
            content.textProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "sshTerminal.failure"
        case .trustUnknown:
            content.text = "New host — trust decision"
            content.secondaryText = "Verify the fingerprint, then Trust & Connect."
            cell.accessibilityIdentifier = "sshTerminal.trustPrompt"
        case .trustMismatch:
            content.text = "Host key changed — connection blocked."
            content.textProperties.color = UIColor(palette.red)
            content.secondaryText = "Forget the trusted key only after you verify why it changed."
        case .addHost:
            // With no saved host this row is the whole screen: it leads with
            // the action and says what saving one gives you.
            content.text = "Add Host"
            content.textProperties.color = UIColor(palette.blue)
            content.secondaryText = "No saved hosts yet. Enter a host, port, and user, then connect."
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "sshTerminal.host.add"
        case .host, .bottomBar, .rexRow:
            break
        case .reset:
            content.text = "Reset Host List"
            content.textProperties.color = UIColor(palette.red)
            cell.accessibilityIdentifier = "sshTerminal.resetHostList"
        }
        cell.contentConfiguration = content
    }

    private func configureConnecting(_ cell: UICollectionViewListCell, palette: ThemePalette) {
        var content = UIListContentConfiguration.cell()
        content.text = session.savingHostOnly ? "Saving Host…" : "Connecting…"
        content.textProperties.color = UIColor(palette.fg)
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
        for profile in profiles {
            guard let follower = rexHosts[profile.id]?.follower else { continue }
            let section = Section.rex(profile.id)
            let hostRows = SSHTerminalRexListRow.rows(hostName: profile.endpointLabel, state: follower.listState)
            let items = hostRows.map { Item.rexRow(host: profile.id, id: $0.id) }
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
            for (item, row) in zip(items, hostRows) { rows[item] = row }
        }
        if profiles.isEmpty && !metadataIsCorrupt {
            snapshot.appendSections([.empty])
            snapshot.appendItems([.addHost], toSection: .empty)
        } else if !profiles.isEmpty {
            snapshot.appendSections([.hosts])
            snapshot.appendItems(profiles.map { .host($0.id) }, toSection: .hosts)
        }
        if !metadataIsCorrupt {
            snapshot.appendSections([.terminal])
            snapshot.appendItems([.bottomBar], toSection: .terminal)
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
    }

    /// Makes, updates, and drops a follower per Rex host: one saved with
    /// Multiplexer: Rex, or one Oppi has seen Rex on (`SSHTerminalRexHostStore`).
    /// A host in neither group is never dialed from here.
    private func syncRexHosts() {
        let seen = profileStore().rexHosts
        let wanted = profiles.filter { $0.opensRexSessions || seen.hasSeenRex(on: $0) }
        for id in rexHosts.keys where !wanted.contains(where: { $0.id == id }) {
            rexHosts[id]?.follower.close()
            rexHosts[id]?.chrome.hostDidDisappear()
            rexHosts[id] = nil
        }
        for profile in wanted {
            if let existing = rexHosts[profile.id] {
                existing.follower.update(profile: profile)
            } else {
                rexHosts[profile.id] = makeRexHost(profile)
            }
        }
        collectionView.refreshControl = rexHosts.isEmpty ? nil : rexRefreshControl
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
    /// and tries again where it had no `nc` or no Rex.
    private func refreshRexHosts() async {
        let followers = rexHosts.values.map(\.follower).filter { $0.isConnected || $0.profile.connectsWithoutPrompt() }
        let reads = followers.map { follower in Task { @MainActor in await follower.refresh() } }
        for read in reads { await read.value }
    }

    private func makeRexHost(_ profile: SSHTerminalProfile) -> RexHost {
        let follower = makeFollower(profile)
        // What this host's monitor finds keeps the memory of where Rex is: a
        // host with no `rex` leaves the section (when it was in it only because
        // Rex had been seen there).
        follower.monitor.onFinding = { [weak self, weak follower] finding in
            guard let self, let follower else { return }
            self.profileStore().rexHosts.record(finding, on: follower.profile)
            if finding == .absent(.notInstalled) {
                Task { @MainActor [weak self] in self?.reload() }
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

    private func configureRexRow(_ cell: UICollectionViewListCell, item: Item) {
        guard case .rexRow(let hostID, _) = item, let row = rexRows[item] else { return }
        let palette = sshTerminalThemeID.palette
        let prefix = "sshTerminal.rexList.\(hostID.uuidString)"
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.color = UIColor(palette.fg)
        content.secondaryTextProperties.color = UIColor(palette.comment)
        cell.accessories = []
        cell.accessibilityTraits = []
        switch row.kind {
        case .header(let name, let needsYou):
            content.text = name
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.image = SSHTerminalBarAction.rex.image()
            content.imageProperties.tintColor = UIColor(palette.comment)
            content.secondaryText = needsYou > 0 ? "Rex \u{00B7} " + SSHTerminalRexListRow.needsYouText(needsYou) : "Rex"
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.secondaryTextProperties.color = UIColor(needsYou > 0 ? palette.orange : palette.comment)
            cell.accessibilityIdentifier = "\(prefix).header"
            cell.accessibilityTraits = .header
        case .placeholder(let text):
            content.text = text
            content.textProperties.color = UIColor(palette.comment)
            cell.accessibilityIdentifier = "\(prefix).\(row.id)"
        case .failure(let text):
            content.text = text
            content.textProperties.color = UIColor(palette.red)
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "\(prefix).\(row.id)"
        case .window(let windowID, let name):
            content.text = name
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = UIColor(palette.comment)
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
        content.textProperties.color = UIColor(palette.fg)
        content.secondaryTextProperties.color = UIColor(palette.comment)
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
            content.imageProperties.tintColor = UIColor(palette.comment)
            cell.accessories = cell.statusAccessories(for: pane.status, themeID: themeID)
            cell.indentationLevel = pane.windowName == nil ? 1 : 2
            cell.configureAction(
                identifier: "\(prefix).\(pane.blockID)",
                label: pane.accessibilityLabel,
                value: pane.status.label,
                hint: "Open this pane"
            ) { [weak self] in self?.activateRexRow(host: hostID, id: id) }
        case .newSession(let busy):
            content.text = busy ? "Working\u{2026}" : "New Rex Session"
            content.textProperties.color = UIColor(busy ? palette.comment : palette.blue)
            content.image = UIImage(systemName: "plus")
            content.imageProperties.tintColor = UIColor(busy ? palette.comment : palette.blue)
            cell.accessories = []
            cell.indentationLevel = 0
            cell.configureAction(
                identifier: "\(prefix).new",
                label: "New Rex Session",
                value: busy ? "Working" : nil,
                hint: "Makes a session with a shell and opens it"
            ) { [weak self] in self?.activateRexRow(host: hostID, id: id) }
        case .tapToConnect:
            content.text = "Tap to connect"
            content.textProperties.color = UIColor(palette.blue)
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
            toggle: { [weak self] in self?.toggleRexSession(host: hostID, id: id) }
        )
    }

    /// The session a row stands for and the follower that can change it now,
    /// resolved when the action runs from the row's identity.
    private func manageableSession(host hostID: UUID, id: String) -> (follower: SSHTerminalRexFollower, sessionID: String, name: String)? {
        guard let follower = rexHosts[hostID]?.follower, follower.canManage,
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

    /// Shows or hides a session's panes. Resolved from the row's identity when it runs.
    private func toggleRexSession(host hostID: UUID, id: String) {
        guard let follower = rexHosts[hostID]?.follower, case .session(let session)? = rexRows[.rexRow(host: hostID, id: id)]?.kind else { return }
        follower.toggleExpanded(session: session.sessionID)
        setNeedsUpdateProperties()
    }

    /// The one action a Rex row has, for a touch (the row's selection) and for
    /// VoiceOver's activation: resolved from the row's identity when it runs.
    private func activateRexRow(host hostID: UUID, id: String) {
        guard let follower = rexHosts[hostID]?.follower, let row = rexRows[.rexRow(host: hostID, id: id)] else { return }
        switch row.kind {
        case .session(let session):
            guard !follower.session.connecting, !follower.session.passwordPrompt else { return }
            follower.open(session: session.sessionID)
        case .pane(let pane):
            guard !follower.session.connecting, !follower.session.passwordPrompt else { return }
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
        rename.backgroundColor = UIColor(sshTerminalThemeID.palette.blue)
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

    /// A Rex host's heading and its notes do nothing when tapped.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard case .rexRow = dataSource?.itemIdentifier(for: indexPath) else { return true }
        return dataSource?.itemIdentifier(for: indexPath).flatMap { rexRows[$0]?.kind.isAction } ?? false
    }

    private func openEditor(profileID: UUID?) {
        Router.push(SSHTerminalSetupViewController(profileID: profileID), from: self)
    }

    /// A row opens its host: a Rex host's sessions screen, else its own terminal.
    private func open(_ profile: SSHTerminalProfile) {
        guard profile.opensRexSessions else { return connect(profile) }
        Router.push(SSHTerminalRexSessionsViewController(profile: profile), from: self)
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

    private func confirmDelete(_ profile: SSHTerminalProfile) {
        Confirmation(
            title: "Delete this host and its saved passwords?",
            actionTitle: "Delete Host"
        ).present(from: self, anchor: nil) { [weak self] in self?.delete(profile) }
    }

    private func delete(_ profile: SSHTerminalProfile) {
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
        syncRexHosts()
        applySnapshot()
    }
}
