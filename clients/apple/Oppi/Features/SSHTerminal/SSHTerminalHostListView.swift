import UIKit

/// Device-local host list. Row tap connects. Edit and Add push the setup form.
/// Appearing loads defaults only: it does not dial and does not read the Keychain.
/// Coming back from the form or the terminal reloads the list.
final class SSHTerminalHostListViewController: UIViewController, UICollectionViewDelegate {
    var showsSidebarToggle = false {
        didSet { if isViewLoaded { installBarItems() } }
    }

    private let session = SSHTerminalConnectSession()
    private var chrome: SSHTerminalConnectChrome?
    private var profiles: [SSHTerminalProfile] = []
    private var connectingProfile = SSHTerminalProfile()
    private var metadataIsCorrupt = false
    private var editAfterTerminal: UUID?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var lastThemeID: ThemeID?

    private enum Section: Hashable { case status, hosts, empty, reset }
    private enum Item: Hashable {
        case corrupt
        case connecting
        case failure(String)
        case trustUnknown
        case trustMismatch
        case empty
        case addHost
        case host(UUID)
        case reset
    }

    init(showsSidebarToggle: Bool = false) {
        self.showsSidebarToggle = showsSidebarToggle
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        config.footerMode = .none
        config.trailingSwipeActionsConfigurationProvider = { indexPath in
            nil
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = "SSH Terminal"
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        config.footerMode = .none
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        collectionView.setCollectionViewLayout(UICollectionViewCompositionalLayout.list(using: config), animated: false)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        collectionView.accessibilityIdentifier = "sshTerminal.hostList"
        SSHTerminalSettingsList.pin(collectionView, in: view)
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
        chrome?.start()
        reload()
        setNeedsUpdateProperties()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        chrome?.hostDidDisappear()
        if isMovingFromParent || isBeingDismissed {
            chrome?.stopObserving()
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
        for profile in profiles { _ = SSHTerminalRegistry.shared.isLive(profile.id) }
        let themeID = sshTerminalThemeID
        if lastThemeID != themeID {
            lastThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        if !session.showsTerminal, let id = editAfterTerminal {
            editAfterTerminal = nil
            openEditor(profileID: id)
        }
        applySnapshot()
        chrome?.sync()
    }

    private func installBarItems() {
        let add = UIBarButtonItem(
            title: "Add Host",
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.openEditor(profileID: nil) }
        )
        add.accessibilityIdentifier = "sshTerminal.host.add"
        navigationItem.rightBarButtonItem = add
        if showsSidebarToggle {
            let visible = HostFactory.root(near: self)?.navigation.splitColumnVisibility != .detailOnly
            let toggle = UIBarButtonItem(
                title: visible ? "Hide Sidebar" : "Show Sidebar",
                image: UIImage(systemName: "sidebar.leading"),
                primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    guard let navigation = HostFactory.root(near: self)?.navigation else { return }
                    navigation.splitColumnVisibility = navigation.splitColumnVisibility == .detailOnly ? .all : .detailOnly
                    self.installBarItems()
                }
            )
            toggle.accessibilityIdentifier = "workspace.split.sidebarToggle"
            navigationItem.leftBarButtonItem = toggle
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
            cell.configure(
                profile: profile,
                live: live,
                palette: self.sshTerminalThemeID.palette,
                enabled: !self.session.connecting && !self.session.passwordPrompt,
                onConnect: { [weak self] in self?.connect(profile) },
                onEdit: { [weak self] in self?.openEditor(profileID: profile.id) }
            )
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .host:
                collectionView.dequeueConfiguredReusableCell(using: hostCell, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
            }
        }
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
        case .empty:
            content.text = "No saved hosts."
            content.textProperties.color = UIColor(palette.comment)
        case .addHost:
            content.text = "Add Host"
            content.textProperties.color = UIColor(palette.blue)
            cell.accessibilityIdentifier = "sshTerminal.host.add"
        case .host:
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
        if profiles.isEmpty && !metadataIsCorrupt {
            snapshot.appendSections([.empty])
            snapshot.appendItems([.empty, .addHost], toSection: .empty)
        } else if !profiles.isEmpty {
            snapshot.appendSections([.hosts])
            snapshot.appendItems(profiles.map { .host($0.id) }, toSection: .hosts)
        }
        if metadataIsCorrupt {
            snapshot.appendSections([.reset])
            snapshot.appendItems([.reset], toSection: .reset)
        }
        if let current = dataSource?.snapshot(), current.itemIdentifiers == snapshot.itemIdentifiers {
            snapshot.reloadItems(snapshot.itemIdentifiers)
        }
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource?.itemIdentifier(for: indexPath), case .host(let id) = item,
              let profile = profiles.first(where: { $0.id == id }) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete Host") { [weak self] _, _, done in
            self?.confirmDelete(profile)
            done(true)
        }
        delete.accessibilityLabel = "Delete Host"
        let config = UISwipeActionsConfiguration(actions: [delete])
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
            connect(profile)
        case .reset:
            confirmReset()
        case .trustUnknown, .trustMismatch:
            chrome?.reopenTrust()
        default:
            break
        }
    }

    private func openEditor(profileID: UUID?) {
        Router.push(SSHTerminalSetupViewController(profileID: profileID), from: self)
    }

    private func connect(_ profile: SSHTerminalProfile, password: String? = nil) {
        connectingProfile = profile.normalized()
        session.connect(
            profile: connectingProfile,
            suppliedPassword: password,
            experimentEnabled: AppPreferences.Experiments.sshTerminalEnabled
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
        let sheet = UIAlertController(
            title: "Delete this host and its saved password?",
            message: nil,
            preferredStyle: .actionSheet
        )
        let action = UIAlertAction(title: "Delete Host", style: .destructive) { [weak self] _ in
            self?.delete(profile)
        }
        sheet.addAction(action)
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    private func delete(_ profile: SSHTerminalProfile) {
        do {
            if session.connectedProfile?.id == profile.id { session.cancel() }
            try SSHTerminalProfileStore().delete(id: profile.id)
            SSHTerminalRegistry.shared.close(profile.id, reason: "The host was deleted.")
            reload()
        } catch {
            session.failure = error.localizedDescription
        }
    }

    /// Corrupt metadata cannot name per-profile password accounts, so this
    /// drops only the unreadable defaults value. It does not scan the Keychain.
    private func confirmReset() {
        let sheet = UIAlertController(
            title: "Reset the host list?",
            message: "The saved host data cannot be read. This removes it so you can add your hosts again.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Reset Host List", style: .destructive) { [weak self] _ in
            SSHTerminalProfileStore().discardCorruptMetadata()
            self?.reload()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    private func reload() {
        let store = SSHTerminalProfileStore()
        metadataIsCorrupt = store.metadataIsCorrupt
        profiles = store.load()
        if metadataIsCorrupt { profiles = [] }
        applySnapshot()
    }
}
