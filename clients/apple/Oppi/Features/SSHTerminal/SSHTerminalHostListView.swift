import UIKit

/// The Terminal page: the hosts saved on this device, each opening its own login
/// shell. Row tap connects. Edit and Add push the setup form. Appearing loads
/// defaults only: it does not dial and does not read the Keychain. Coming back
/// from the form or the terminal reloads the list. Rex has a screen of its own
/// (`RexListViewController`).
///
/// A `ListScreenController`: the base owns the list, the theme, the heading and
/// footer chrome, the snapshot, the swipe actions, and the rows' redraw keys. This
/// page keeps what only it has: the status rows, the saved hosts, the empty state
/// and Reset, and its bar.
final class SSHTerminalHostListViewController:
    ListScreenController<SSHTerminalHostListViewController.Section, SSHTerminalHostListViewController.Item> {
    var showsSidebarToggle = false {
        didSet { if isViewLoaded { installBarItems() } }
    }

    /// Where the saved hosts live. Tests pass a store over their own defaults.
    private let profileStore: @Sendable () -> SSHTerminalProfileStore

    /// A host row's terminal follows the window's server switches, as the page does.
    private lazy var session = SSHTerminalConnectSession(access: { [weak self] in self?.access ?? .current })
    private var chrome: SSHTerminalConnectChrome?
    private var profiles: [SSHTerminalProfile] = []
    private var connectingProfile = SSHTerminalProfile()
    private var metadataIsCorrupt = false
    private var editAfterTerminal: UUID?

    enum Section: Hashable, Sendable { case status, hosts, empty, reset }
    enum Item: Hashable, Sendable {
        case corrupt
        case connecting
        case failure(String)
        case trustUnknown
        case trustMismatch
        case addHost
        case host(UUID)
        case reset
    }

    init(
        showsSidebarToggle: Bool = false,
        profileStore: @escaping @Sendable () -> SSHTerminalProfileStore = { SSHTerminalProfileStore() }
    ) {
        self.showsSidebarToggle = showsSidebarToggle
        self.profileStore = profileStore
        super.init(title: "Terminal", listIdentifier: "sshTerminal.hostList")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// This device's experiments, narrowed to what the window's server offers (its Rex and
    /// Herdr switches): what a host's terminal may run.
    private var access: SSHTerminalExperimentAccess {
        SSHTerminalExperimentAccess.current.narrowed(
            to: .offered(by: AppRootEnvironment.near(self)?.windowConnection)
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installBarItems()
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
        updatePropertiesIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A host edited or deleted while this screen was covered is drawn as it is now.
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        chrome?.hostDidDisappear()
    }

    override func updateProperties() {
        // What this pass draws, read first so the page follows its stores.
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
        _ = sshTerminalThemeID
        if !session.showsTerminal, let id = editAfterTerminal {
            editAfterTerminal = nil
            openEditor(profileID: id)
        }
        super.updateProperties()
        chrome?.sync()
    }

    // MARK: - The list

    /// The status rows first, then the saved hosts. A page with no saved host says
    /// how to add one, and unreadable metadata offers Reset instead.
    override func sections() -> [ListSection<Section, Item>] {
        var sections: [ListSection<Section, Item>] = []
        var status: [Item] = []
        if metadataIsCorrupt { status.append(.corrupt) }
        if session.connecting { status.append(.connecting) }
        if let failure = session.failure { status.append(.failure(failure)) }
        switch session.hostFailure {
        case .unknownHostKey: status.append(.trustUnknown)
        case .hostKeyMismatch: status.append(.trustMismatch)
        default: break
        }
        if !status.isEmpty { sections.append(ListSection(.status, items: status)) }
        if !profiles.isEmpty {
            sections.append(ListSection(.hosts, items: profiles.map { .host($0.id) }))
        }
        if profiles.isEmpty && !metadataIsCorrupt {
            sections.append(ListSection(.empty, items: [.addHost]))
        }
        if metadataIsCorrupt {
            sections.append(ListSection(.reset, items: [.reset]))
        }
        return sections
    }

    /// The snapshot is applied without animating, as this list always did.
    override var animatesUpdates: Bool { false }

    // MARK: - Rows

    override func prepareRegistrations() {
        _ = hostCell
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        if case .host = item {
            return collectionView.dequeueConfiguredReusableCell(using: hostCell, for: indexPath, item: item)
        }
        return super.dequeue(item, at: indexPath)
    }

    private lazy var hostCell = UICollectionView.CellRegistration<SSHTerminalHostRowCell, Item> { [weak self] cell, _, item in
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
            onConnect: { [weak self] in self?.connect(profile) },
            onEdit: { [weak self] in self?.openEditor(profileID: profile.id) },
            onDelete: { [weak self] in self?.confirmDelete(profile) },
            contextMenu: self.rowMenu(for: item)
        )
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
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
        case .host:
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

    /// The rows that act on a tap: a host, the Add Host row, Reset, and the two
    /// trust prompts.
    override func isSelectable(_ item: Item) -> Bool {
        switch item {
        case .addHost, .reset, .trustUnknown, .trustMismatch, .host: true
        case .corrupt, .connecting, .failure: false
        }
    }

    override func select(_ item: Item) {
        switch item {
        case .addHost:
            openEditor(profileID: nil)
        case .host(let id):
            guard !session.connecting, !session.passwordPrompt,
                  let profile = profiles.first(where: { $0.id == id }) else { return }
            connect(profile)
        case .reset:
            confirmReset()
        case .trustUnknown, .trustMismatch:
            chrome?.reopenTrust()
        case .corrupt, .connecting, .failure:
            break
        }
    }

    override func rowActions(for item: Item) -> [ListRowAction] {
        guard case .host(let id) = item, let profile = profiles.first(where: { $0.id == id }) else { return [] }
        // UIContextualAction is not UIAccessibilityIdentification: there is no
        // public accessibilityIdentifier (SwiftUI swipe had sshTerminal.host.delete).
        return [ListRowAction(
            title: "Delete Host",
            systemImage: "trash",
            style: .destructive,
            accessibilityLabel: "Delete Host",
            performsWithFullSwipe: false
        ) { [weak self] done in
            self?.confirmDelete(profile)
            done(true)
        }]
    }

    // MARK: - Bar items

    /// The nav bar's two buttons: ＋ saves a host, ⚙︎ opens Settings › Terminal
    /// (the hosts' forms, Rex on Your Tailnet, and the Bottom Bar), which is where
    /// the occasional setup leaves this page.
    private func installBarItems() {
        let add = UIBarButtonItem(
            title: String(localized: "Add Host"),
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.openEditor(profileID: nil) }
        )
        add.accessibilityIdentifier = "sshTerminal.host.add"
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
        if showsSidebarToggle, let root = AppRootEnvironment.near(self) {
            navigationItem.leftBarButtonItem = WorkspaceSplitSidebarToggle.makeItem(root: root)
        }
    }

    // MARK: - Hosts

    private func openEditor(profileID: UUID?) {
        Router.push(SSHTerminalSetupViewController(profileID: profileID), from: self)
    }

    /// A host row opens its own login shell, with its Run on Connect command.
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

    /// Reads the saved hosts, then asks for the pass that draws them: the base
    /// owns the snapshot.
    private func reload() {
        let store = profileStore()
        metadataIsCorrupt = store.metadataIsCorrupt
        profiles = store.load()
        if metadataIsCorrupt { profiles = [] }
        setNeedsUpdateProperties()
    }
}
