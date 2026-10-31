import UIKit

/// Add or edit a saved SSH host. Opening never dials. Connect is an explicit tap.
///
/// Opened from a workspace's or chat's Terminal, the form starts with the
/// workspace's server host and `folderTerminal` set: saving it then continues
/// into that folder's terminal, and Connect opens it instead of the host's own.
final class SSHTerminalSetupViewController: UIViewController, UICollectionViewDelegate {
    private let profileID: UUID?
    private var profile: SSHTerminalProfile
    private var portText: String
    /// Set when the form was opened for "Open Terminal here".
    private let folderTerminal: SSHTerminalFolderTarget?
    /// A sudo password typed in this form and not saved yet. The field never
    /// shows a saved one: reading it takes Face ID.
    private var sudoPasswordText = ""
    private var deviceKey = SSHTerminalDeviceKeyState()
    private var copied = false
    private let session = SSHTerminalConnectSession()
    /// Where the terminal's colors come from; saved with the host.
    private var colorChoice: SSHTerminalColorChoice
    private var chrome: SSHTerminalConnectChrome?
    /// Edit Host from a terminal the switcher changed: that host's form opens
    /// once the terminal has closed over this one.
    private var editAfterTerminal: UUID?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var lastThemeID: ThemeID?

    private enum Section: Hashable { case host, multiplexer, startup, colors, identity, actions, delete }
    private enum Item: Hashable {
        case host, port, username, authentication, savePassword, sudoPassword, removeSudoPassword
        case multiplexer, startup, colors
        case publicKey, copyKey, backing, identityStatus, replaceKey
        case connecting, connect, saveHost, failure, trustUnknown, trustMismatch
        case deleteHost
    }

    /// `host` prefills a new host (the server's address); a saved host always
    /// shows its own. `folderTerminal` makes this form the first step of
    /// "Open Terminal here".
    init(profileID: UUID? = nil, host: String? = nil, folderTerminal: SSHTerminalFolderTarget? = nil) {
        self.profileID = profileID
        self.folderTerminal = folderTerminal
        var stored = profileID.flatMap { SSHTerminalProfileStore().profile(id: $0) }
            ?? SSHTerminalProfile(id: profileID ?? UUID())
        if profileID == nil, let host, !host.isEmpty { stored.host = host }
        profile = stored
        portText = String(stored.port)
        colorChoice = SSHTerminalColorStore().choice(for: stored.id)
        var config = SettingsListStyle.layoutConfiguration(headers: true, footers: true)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = "Terminal"
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var target: String { profile.host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var port: UInt16? { UInt16(portText) }
    private var canConnect: Bool {
        !target.isEmpty && !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port != nil && port != 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        SettingsListStyle.pin(collectionView, in: view)
        installDataSource()
        chrome = SSHTerminalConnectChrome(
            host: self,
            session: session,
            profile: { [weak self] in self?.normalizedProfile() ?? SSHTerminalProfile() },
            setProfile: { [weak self] in self?.applySaved($0) },
            editHost: { [weak self] in self?.editConnectedHost() },
            submitPassword: { [weak self] password in
                guard let self else { return }
                if self.session.savingHostOnly { self.saveHost(password: password) } else { self.connect(password: password) }
            },
            onSaved: { [weak self] in self?.applySaved($0) }
        )
        loadIdentityIfSelected()
        updateConnectBarItem()
        setNeedsUpdateProperties()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        chrome?.hostDidDisappear()
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
        _ = session.devicePasscodeChanged
        if !session.showsTerminal, let id = editAfterTerminal {
            editAfterTerminal = nil
            Router.push(SSHTerminalSetupViewController(profileID: id), from: self)
        }
        _ = AppScenePhase.shared.isBackground
        deviceKey.observePasscodeChanged(session.devicePasscodeChanged, failure: session.failure)
        let themeID = sshTerminalThemeID
        if lastThemeID != themeID {
            lastThemeID = themeID
            SettingsListStyle.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        applySnapshot()
        updateConnectBarItem()
        chrome?.sync()
    }

    @objc private func barConnect() { connect() }

    /// Always in the navigation bar so Connect is tappable while the keyboard is up.
    private func updateConnectBarItem() {
        let item = UIBarButtonItem(title: "Connect", style: .prominent, target: self, action: #selector(barConnect))
        item.accessibilityIdentifier = "sshTerminal.connect"
        item.isEnabled = canConnect && !session.connecting
        navigationItem.rightBarButtonItem = item
    }

    private func installDataSource() {
        let field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, item in
            self?.configureField(cell, item: item)
        }
        let action = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, item in
            self?.configureAction(cell, item: item)
        }
        let menu = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
            if item == .multiplexer { self?.configureMultiplexer(cell) } else { self?.configureAuthentication(cell) }
        }
        let index = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(
                title: "Terminal Colors",
                image: nil,
                value: colorSummary,
                identifier: "sshTerminal.colors"
            ) { [weak self] in self?.presentColorPicker() }
        }
        let list = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configureList(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.headerTitle(at: indexPath)
            cell.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.footerTitle(at: indexPath)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView, cellProvider: SettingsListStyle.cardProvider { collectionView, indexPath, item in
            switch item {
            case .host, .port, .username, .startup, .sudoPassword:
                collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            case .authentication, .multiplexer:
                collectionView.dequeueConfiguredReusableCell(using: menu, for: indexPath, item: item)
            case .colors:
                collectionView.dequeueConfiguredReusableCell(using: index, for: indexPath, item: item)
            case .copyKey, .replaceKey, .connect, .saveHost, .deleteHost, .removeSudoPassword:
                collectionView.dequeueConfiguredReusableCell(using: action, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: list, for: indexPath, item: item)
            }
        })
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configureField(_ cell: SSHTerminalTextFieldCell, item: Item) {
        let palette = sshTerminalThemeID.palette
        let enabled = !session.connecting
        switch item {
        case .host:
            cell.configure(
                text: profile.host, placeholder: "Hostname or IP", identifier: "sshTerminal.host",
                keyboard: .URL, textColor: palette.ui.fg, enabled: enabled
            ) { [weak self] in
                self?.profile.host = $0
                self?.session.hostFailure = nil
                self?.session.failure = nil
                self?.reloadActionItems()
            }
        case .port:
            cell.configure(
                text: portText, placeholder: "Port", identifier: "sshTerminal.port",
                keyboard: .numberPad, textColor: palette.ui.fg, enabled: enabled
            ) { [weak self] in
                self?.portText = $0
                self?.session.hostFailure = nil
                self?.session.failure = nil
                self?.reloadActionItems()
            }
        case .username:
            cell.configure(
                text: profile.username, placeholder: "Username", identifier: "sshTerminal.username",
                keyboard: .default, textColor: palette.ui.fg, enabled: enabled
            ) { [weak self] in
                self?.profile.username = $0
                self?.reloadActionItems()
            }
        case .sudoPassword:
            cell.configure(
                text: sudoPasswordText,
                placeholder: hasSavedSudoPassword ? "Sudo Password: saved, type to replace" : "Sudo Password (optional)",
                identifier: "sshTerminal.sudoPassword",
                isSecure: true, textColor: palette.ui.fg, enabled: enabled
            ) { [weak self] in
                self?.sudoPasswordText = $0
            }
        case .startup:
            cell.configure(
                text: profile.startupCommand ?? "", placeholder: "Login shell", identifier: "sshTerminal.startupCommand",
                monospaced: true, textColor: palette.ui.fg, enabled: enabled
            ) { [weak self] in
                self?.profile.startupCommand = $0
                self?.reconfigure(.multiplexer)
            }
        default:
            break
        }
    }

    /// Herdr and tmux write the Run on Connect command below; Rex hides it.
    private func configureMultiplexer(_ cell: SettingsMenuRowCell) {
        let current = profile.multiplexerChoice
        cell.configure(
            title: "Multiplexer",
            identifier: "sshTerminal.multiplexer",
            isEnabled: !session.connecting,
            value: current.label,
            menu: {
                SSHTerminalMultiplexerChoice.allCases.map { choice in
                    SettingsMenuOption(title: choice.label, selected: choice == current) { [weak self] in
                        self?.profile.choose(choice)
                        self?.applySnapshot()
                    }
                }
            }
        )
    }

    /// Redraws one row in place, leaving the field being typed in alone.
    private func reconfigure(_ item: Item) {
        guard var snapshot = dataSource?.snapshot(), snapshot.itemIdentifiers.contains(item) else { return }
        snapshot.reconfigureItems([item])
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    private func configureAuthentication(_ cell: SettingsMenuRowCell) {
        let authentication = profile.authentication
        cell.configure(
            title: "Sign In",
            identifier: "sshTerminal.authentication",
            isEnabled: !session.connecting,
            value: authentication == .deviceKey ? "This Device’s Key" : "Password",
            menu: {
                [
                    SettingsMenuOption(
                        title: "Password",
                        selected: authentication == .password
                    ) { [weak self] in
                        self?.profile.authentication = .password
                        self?.loadIdentityIfSelected()
                    },
                    SettingsMenuOption(
                        title: "This Device’s Key",
                        selected: authentication == .deviceKey
                    ) { [weak self] in
                        self?.profile.authentication = .deviceKey
                        self?.loadIdentityIfSelected()
                    },
                ]
            }
        )
    }

    private func configureAction(_ cell: SettingsActionRowCell, item: Item) {
        switch item {
        case .removeSudoPassword:
            cell.configure(
                title: "Remove Saved Sudo Password",
                tint: .destructive,
                identifier: "sshTerminal.removeSudoPassword",
                isEnabled: !session.connecting
            ) { [weak self] in self?.removeSavedSudoPassword() }
        case .copyKey:
            cell.configure(
                title: copied ? "Copied Public Key" : "Copy Public Key",
                systemImage: copied ? "checkmark" : "doc.on.doc",
                identifier: "sshTerminal.copyKey"
            ) { [weak self] in self?.copyPublicKey() }
        case .replaceKey:
            cell.configure(
                title: "Device passcode changed — create a new key",
                identifier: "sshTerminal.replaceKey",
                isEnabled: !session.connecting
            ) { [weak self] in self?.loadIdentityIfSelected(createReplacement: true) }
        case .connect:
            cell.configure(
                title: "Connect",
                identifier: "sshTerminal.connect.list",
                isEnabled: canConnect && !session.connecting
            ) { [weak self] in self?.connect() }
        case .saveHost:
            cell.configure(
                title: "Save Host",
                identifier: "sshTerminal.saveHost",
                isEnabled: canConnect && !session.connecting
            ) { [weak self] in self?.saveHost() }
        case .deleteHost:
            cell.configure(
                title: "Delete Host",
                tint: .destructive,
                identifier: "sshTerminal.deleteHost",
                confirmation: .init(title: "Delete this host and its saved passwords?", actionTitle: "Delete Host")
            ) { [weak self] in self?.deleteHost() }
        default:
            break
        }
    }

    private func configureList(_ cell: UICollectionViewListCell, item: Item) {
        let palette = sshTerminalThemeID.palette
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.color = palette.ui.fg
        content.secondaryTextProperties.color = palette.ui.comment
        switch item {
        case .savePassword:
            content = UIListContentConfiguration.valueCell()
            content.text = "Save Password"
            content.textProperties.color = palette.ui.fg
            let toggle = UISwitch()
            toggle.isOn = profile.savesPassword
            toggle.isEnabled = !session.connecting
            toggle.accessibilityIdentifier = "sshTerminal.savePassword"
            toggle.addAction(UIAction { [weak self] action in
                guard let toggle = action.sender as? UISwitch else { return }
                self?.profile.savesPassword = toggle.isOn
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
            cell.accessibilityIdentifier = "sshTerminal.savePassword"
        case .publicKey:
            content.text = deviceKey.identity?.publicKeyOpenSSH ?? ""
            content.textProperties.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            content.textProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "sshTerminal.publicKey"
        case .copyKey:
            content.text = copied ? "Copied Public Key" : "Copy Public Key"
            content.image = UIImage(systemName: copied ? "checkmark" : "doc.on.doc")
            cell.accessibilityIdentifier = "sshTerminal.copyKey"
        case .backing:
            content.text = deviceKey.identity?.backingDescription ?? ""
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = palette.ui.comment
        case .identityStatus:
            content.text = deviceKey.identityFailure ?? "Loading identity…"
            content.textProperties.color = palette.ui.comment
        case .replaceKey:
            content.text = "Device passcode changed — create a new key"
            content.textProperties.color = palette.ui.blue
        case .connecting:
            content.text = session.savingHostOnly ? "Saving Host…" : "Connecting…"
            let cancel = UIButton(type: .system)
            var conf = UIButton.Configuration.plain()
            conf.title = "Cancel"
            conf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
            cancel.configuration = conf
            cancel.addAction(UIAction { [weak self] _ in self?.session.cancel() }, for: .touchUpInside)
            cell.accessories = [.customView(configuration: .init(customView: cancel, placement: .trailing()))]
            cell.accessibilityIdentifier = "sshTerminal.connecting"
        case .connect:
            content.text = "Connect"
            content.textProperties.color = canConnect ? palette.ui.blue : palette.ui.comment
            cell.accessibilityIdentifier = "sshTerminal.connect"
            cell.accessibilityTraits.insert(.button)
            if !canConnect { cell.accessibilityTraits.insert(.notEnabled) }
        case .saveHost:
            content.text = "Save Host"
            content.textProperties.color = canConnect ? palette.ui.blue : palette.ui.comment
            cell.accessibilityIdentifier = "sshTerminal.saveHost"
            cell.accessibilityTraits.insert(.button)
            if !canConnect { cell.accessibilityTraits.insert(.notEnabled) }
        case .failure:
            content.text = "Disconnected — \(session.failure ?? "")"
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
        case .deleteHost:
            content.text = "Delete Host"
            content.textProperties.color = palette.ui.red
            cell.accessibilityIdentifier = "sshTerminal.deleteHost"
        default:
            break
        }
        cell.contentConfiguration = content
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.host])
        var hostItems: [Item] = [.host, .port, .username, .authentication]
        if profile.authentication == .password { hostItems.append(.savePassword) }
        if profile.authentication == .deviceKey {
            hostItems.append(.sudoPassword)
            if hasSavedSudoPassword { hostItems.append(.removeSudoPassword) }
        }
        snapshot.appendItems(hostItems, toSection: .host)

        snapshot.appendSections([.multiplexer])
        snapshot.appendItems([.multiplexer], toSection: .multiplexer)
        if !profile.opensRexSessions {
            snapshot.appendSections([.startup])
            snapshot.appendItems([.startup], toSection: .startup)
        }

        snapshot.appendSections([.colors])
        snapshot.appendItems([.colors], toSection: .colors)

        if profile.authentication == .deviceKey {
            snapshot.appendSections([.identity])
            if deviceKey.identity != nil {
                snapshot.appendItems([.publicKey, .copyKey, .backing], toSection: .identity)
            } else {
                var items: [Item] = [.identityStatus]
                if deviceKey.identityNeedsReplacement { items.append(.replaceKey) }
                snapshot.appendItems(items, toSection: .identity)
            }
        }

        snapshot.appendSections([.actions])
        var actions: [Item] = []
        if session.connecting {
            actions.append(.connecting)
        } else {
            actions.append(contentsOf: [.connect, .saveHost])
        }
        if session.failure != nil { actions.append(.failure) }
        switch session.hostFailure {
        case .unknownHostKey: actions.append(.trustUnknown)
        case .hostKeyMismatch: actions.append(.trustMismatch)
        default: break
        }
        snapshot.appendItems(actions, toSection: .actions)

        if SSHTerminalProfileStore().contains(profile.id) {
            snapshot.appendSections([.delete])
            snapshot.appendItems([.deleteHost], toSection: .delete)
        }
        // Rows that stay are redrawn in place, whether or not the list around
        // them changed: Sign In shows the choice just made even when it adds or
        // removes the rows below it.
        let shown = Set(dataSource?.snapshot().itemIdentifiers ?? [])
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(shown.contains))
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    private func reloadActionItems() {
        guard var snapshot = dataSource?.snapshot() else { return }
        let items = snapshot.itemIdentifiers.filter {
            switch $0 {
            case .connect, .saveHost, .authentication, .sudoPassword: return true
            default: return false
            }
        }
        guard !items.isEmpty else { return }
        snapshot.reloadItems(items)
        dataSource?.apply(snapshot, animatingDifferences: false)
        updateConnectBarItem()
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return false }
        switch item {
        case .trustUnknown, .trustMismatch:
            return true
        default:
            return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .trustUnknown, .trustMismatch:
            chrome?.reopenTrust()
        default:
            break
        }
    }

    /// What the host's last read found, or what was chosen.
    private var colorSummary: String {
        switch colorChoice {
        case .host:
            SSHTerminalColorStore().cached(for: profile.id, choice: .host).map { "Host’s Ghostty theme: \($0.summary)" }
                ?? "Host’s Ghostty theme"
        case .oppi, .named: colorChoice.title
        }
    }

    private func presentColorPicker() {
        let live = SSHTerminalRegistry.shared.terminals(for: profile.id).first { $0.channel.connected }?.channel
        let summary = SSHTerminalColorStore().cached(for: profile.id, choice: .host)?.summary ?? "Read when you connect"
        let picker = SSHTerminalColorPickerViewController(selected: colorChoice, hostSummary: summary, channel: live) { [weak self] choice in
            guard let self else { return }
            self.colorChoice = choice
            // A saved host's terminal follows at once; a new host's choice is kept with the host.
            if SSHTerminalProfileStore().contains(self.profile.id) {
                SSHTerminalColorStore().setChoice(choice, for: self.profile.id)
            }
            self.applySnapshot()
        }
        Router.push(picker, from: self)
    }

    private func copyPublicKey() {
        guard let identity = deviceKey.identity else { return }
        UIPasteboard.general.string = identity.publicKeyOpenSSH
        copied = true
        applySnapshot()
    }

    private func headerTitle(at indexPath: IndexPath) -> String? {
        guard let section = dataSource?.snapshot().sectionIdentifiers[safe: indexPath.section] else { return nil }
        switch section {
        case .host: return "Host"
        case .multiplexer: return "Multiplexer"
        case .startup: return "Run on Connect"
        case .colors: return "Colors"
        case .identity: return "This Device’s SSH Identity"
        default: return nil
        }
    }

    private func footerTitle(at indexPath: IndexPath) -> String? {
        guard let section = dataSource?.snapshot().sectionIdentifiers[safe: indexPath.section] else { return nil }
        switch section {
        case .host:
            var text = "Remote Login (sshd) must be enabled. When Oppi’s Tailscale node is running, *.ts.net hosts use it; other hosts use your current network."
            if profile.authentication == .deviceKey {
                text += "\n\nA sudo password is optional. It stays in this device’s private Keychain, and at a terminal password prompt Fill Password types it after Face ID, Touch ID, or your passcode, without pressing Return. It goes to whatever program on that terminal shows the prompt. Changing the host, port, or user removes it."
            }
            return text
        case .multiplexer:
            return "Herdr and tmux run in this host’s terminal: choosing one sets Run on Connect. With Rex, Connect opens the host’s Rex sessions instead of a terminal; tap a pane to open it here, or Shell for the login shell."
        case .startup:
            if folderTerminal != nil {
                return "Runs this command in the terminal instead of a login shell, like `ssh -t host 'command'` or OpenSSH RemoteCommand. The connection ends when the command exits (for Herdr, detach with Ctrl-B Q). The command must be on the PATH that SSH commands see.\n\nTerminal from a workspace or chat starts its own login shell in that folder and ignores this command."
            }
            return "Runs this command in the terminal instead of a login shell, like `ssh -t host 'command'` or OpenSSH RemoteCommand. The connection ends when the command exits (for Herdr, detach with Ctrl-B Q). The command must be on the PATH that SSH commands see."
        case .identity:
            var text = "Append this public key to ~/.ssh/authorized_keys. Signing requires Face ID or your device passcode. The simulator uses a software key. Oppi never installs the key for you."
            if deviceKey.identityNeedsReplacement {
                text += "\nReplace the old entry in ~/.ssh/authorized_keys with the new public key before connecting."
            }
            return text
        case .actions:
            return "Saved passwords stay only in this device’s private Keychain and require Face ID or passcode at connect. Unsaved passwords are used for one attempt only. Keyboard-interactive and private-key import are not supported. Reconnect opens a fresh shell; use tmux to preserve work. Input is never replayed."
        default:
            return nil
        }
    }

    private func loadIdentityIfSelected(createReplacement: Bool = false) {
        guard profile.authentication == .deviceKey else {
            deviceKey.applyLoadResult(identity: nil, needsReplacement: false, failure: nil)
            applySnapshot()
            return
        }
        do {
            let identity = try SSHIdentityKeyStore.loadOrCreate(createReplacement: createReplacement)
            deviceKey.applyLoadResult(identity: identity, needsReplacement: false, failure: nil)
            if createReplacement {
                session.failure = "New SSH key created. Replace the old entry in ~/.ssh/authorized_keys before connecting."
            }
        } catch {
            deviceKey.applyLoadResult(
                identity: nil,
                needsReplacement: (error as? SSHIdentityKeyStoreError) == .devicePasscodeChanged,
                failure: error.localizedDescription
            )
        }
        applySnapshot()
    }

    private func normalizedProfile() -> SSHTerminalProfile {
        var result = profile
        result.port = port ?? 22
        return result.normalized().settingSudoPassword(
            supplied: suppliedSudoPassword != nil,
            saved: SSHTerminalProfileStore().profile(id: profile.id)
        )
    }

    /// What the person typed for the sudo password, on a host that can keep one.
    private var suppliedSudoPassword: String? {
        profile.authentication == .deviceKey && !sudoPasswordText.isEmpty ? sudoPasswordText : nil
    }

    /// A sudo password in the Keychain that still belongs to the host as the
    /// form now describes it.
    private var hasSavedSudoPassword: Bool {
        var current = profile
        current.port = port ?? 22
        return current.normalized().reusesSudoPassword(of: SSHTerminalProfileStore().profile(id: profile.id))
    }

    /// Edit Host in the terminal's menu acts on the terminal shown. When the
    /// switcher moved it to another host, that host's form follows.
    private func editConnectedHost() {
        if let shown = session.connectedProfile?.id, shown != profileID { editAfterTerminal = shown }
        session.showsTerminal = false
    }

    private func applySaved(_ saved: SSHTerminalProfile) {
        profile = saved
        portText = String(saved.port)
        if !sudoPasswordText.isEmpty {
            sudoPasswordText = ""
            view.endEditing(true)
        }
        SSHTerminalColorStore().setChoice(colorChoice, for: saved.id)
        applySnapshot()
    }

    private func removeSavedSudoPassword() {
        let store = SSHTerminalProfileStore()
        guard var committed = store.profile(id: profile.id), committed.savesSudoPassword else { return }
        committed.savesSudoPassword = false
        do {
            try store.save(committed)
            SSHTerminalRegistry.shared.reconcile(saved: committed)
            profile.savesSudoPassword = false
            sudoPasswordText = ""
            view.endEditing(true)
            applySnapshot()
        } catch {
            session.failure = error.localizedDescription
        }
    }

    private func saveHost(password: String? = nil) {
        guard canConnect else { return }
        session.saveHost(
            profile: normalizedProfile(),
            suppliedPassword: password,
            sudoPassword: suppliedSudoPassword
        ) { [weak self] saved in
            self?.applySaved(saved)
            // Opened for a workspace folder: the host is usable now, so carry on
            // into that folder's terminal.
            if self?.folderTerminal != nil { self?.connect() }
        }
    }

    private func connect(password: String? = nil) {
        guard canConnect else { return }
        // The same decision a saved host's folder screen makes: the host's own
        // multiplexer terminal, a folder terminal running its attach command, or
        // the plain login shell in the folder.
        let profile = normalizedProfile()
        // A Rex host opens its sessions screen, which signs in on its own.
        if profile.opensRexSessions, folderTerminal == nil {
            session.saveHost(profile: profile, suppliedPassword: password, sudoPassword: suppliedSudoPassword) { [weak self] saved in
                guard let self else { return }
                self.applySaved(saved)
                // Edit Host from that host's sessions screen goes back to it.
                if let below = self.navigationController?.viewControllers.dropLast().last as? SSHTerminalRexSessionsViewController,
                   below.profileID == saved.id {
                    Router.finish(self)
                } else {
                    Router.push(SSHTerminalRexSessionsViewController(profile: saved, suppliedPassword: password), from: self)
                }
            }
            return
        }
        SSHTerminalFolderEntry.prepare(session: session, profile: profile, target: folderTerminal)
        session.connect(
            profile: profile,
            suppliedPassword: password,
            sudoPassword: suppliedSudoPassword,
            onSaved: applySaved
        )
    }

    private func deleteHost() {
        do {
            session.cancel()
            try SSHTerminalProfileStore().delete(id: profile.id)
            SSHTerminalRegistry.shared.closeAllTerminals(of: profile.id, reason: "The host was deleted.")
            Router.finish(self)
        } catch {
            session.failure = error.localizedDescription
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
