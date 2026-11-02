import UIKit

/// Add or edit a saved SSH host. Opening never dials. Connect is an explicit tap.
///
/// Opened from a workspace's or chat's Terminal, the form starts with the
/// workspace's server host and `folderTerminal` set: saving it then continues
/// into that folder's terminal, and Connect opens it instead of the host's own.
///
/// A `ListScreenController`: the base owns the list, its sections and headings,
/// and the redraw that leaves a row alone until what it draws changes. The form
/// has no load of its own: every row is the draft in `profile`, `portText`, and
/// `sudoPasswordText`, and the session's state says what the actions do.
final class SSHTerminalSetupViewController: ListScreenController<
    SSHTerminalSetupViewController.Section, SSHTerminalSetupViewController.Item
> {
    enum Section: Hashable, Sendable {
        case host, multiplexer, startup, colors, identity, actions, delete
    }

    enum Item: Hashable, Sendable {
        case host, port, username, authentication, savePassword, sudoPassword, removeSudoPassword
        case multiplexer, startup, colors
        case publicKey, copyKey, backing, identityStatus, replaceKey
        case connecting, connect, saveHost, failure, trustUnknown, trustMismatch
        case deleteHost
    }

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
    /// How often the form refilled its fields from a saved host. The field rows
    /// are keyed by it, never by their text, so typing never reconfigures the
    /// field it is typed in and a pass that changes nothing else leaves the
    /// caret, the selection, and the keyboard where the person left them.
    private var formRevision = 0
    /// The Save Password row's one switch, kept across redraws so a pass never
    /// replaces it.
    private let saveSwitch = UISwitch()

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
        super.init(
            title: "Terminal",
            listIdentifier: "sshTerminal.setup.list",
            headers: true,
            footers: true,
            dismissesKeyboardOnDrag: true
        )
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var target: String { profile.host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var port: UInt16? { UInt16(portText) }
    private var canConnect: Bool {
        !target.isEmpty && !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port != nil && port != 0
    }

    private var style: SettingsStyle { .current }
    private var isConnecting: Bool { session.connecting }

    override func viewDidLoad() {
        super.viewDidLoad()
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
        saveSwitch.accessibilityLabel = "Save Password"
        saveSwitch.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            profile.savesPassword = toggle.isOn
        }, for: .valueChanged)
        loadIdentityIfSelected()
        updateConnectBarItem()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        chrome?.hostDidDisappear()
    }

    override func updateProperties() {
        // Read, and record what the session says, before the pass draws: the
        // session's own changes (a connect, a prompt, the terminal it pushed)
        // and the device key's are what the form shows.
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
        super.updateProperties()
        updateConnectBarItem()
        chrome?.sync()
    }

    @objc private func barConnect() { connect() }

    /// Always in the navigation bar so Connect is tappable while the keyboard is up.
    private func updateConnectBarItem() {
        let item = UIBarButtonItem(title: "Connect", style: .prominent, target: self, action: #selector(barConnect))
        item.accessibilityIdentifier = "sshTerminal.connect"
        item.isEnabled = canConnect && !isConnecting
        navigationItem.rightBarButtonItem = item
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(
                .host,
                header: String(localized: "Host"),
                footer: hostFooter,
                items: hostItems
            ),
            ListSection(
                .multiplexer,
                header: String(localized: "Multiplexer"),
                footer: multiplexerFooter,
                items: [.multiplexer]
            ),
            ListSection(
                .startup,
                header: String(localized: "Run on Connect"),
                footer: startupFooter,
                items: profile.opensRexSessions ? [] : [.startup]
            ),
            ListSection(.colors, header: String(localized: "Colors"), items: [.colors]),
            ListSection(
                .identity,
                header: String(localized: "This Device’s SSH Identity"),
                footer: identityFooter,
                items: identityItems
            ),
            ListSection(.actions, footer: actionsFooter, items: actionItems),
            ListSection(.delete, items: SSHTerminalProfileStore().contains(profile.id) ? [.deleteHost] : []),
        ]
    }

    /// A page whose headings sit on every section but the actions and the delete.
    override func showsHeader(for section: Section) -> Bool {
        switch section {
        case .actions, .delete: false
        default: true
        }
    }

    private var hostItems: [Item] {
        var items: [Item] = [.host, .port, .username, .authentication]
        if profile.authentication == .password { items.append(.savePassword) }
        if profile.authentication == .deviceKey {
            items.append(.sudoPassword)
            if hasSavedSudoPassword { items.append(.removeSudoPassword) }
        }
        return items
    }

    private var identityItems: [Item] {
        guard profile.authentication == .deviceKey else { return [] }
        if deviceKey.identity != nil { return [.publicKey, .copyKey, .backing] }
        return deviceKey.identityNeedsReplacement ? [.identityStatus, .replaceKey] : [.identityStatus]
    }

    private var actionItems: [Item] {
        var items: [Item] = isConnecting ? [.connecting] : [.connect, .saveHost]
        if session.failure != nil { items.append(.failure) }
        switch session.hostFailure {
        case .unknownHostKey: items.append(.trustUnknown)
        case .hostKeyMismatch: items.append(.trustMismatch)
        default: break
        }
        return items
    }

    private var hostFooter: String {
        var text = String(localized: "Remote Login (sshd) must be enabled. When Oppi’s Tailscale node is running, *.ts.net hosts use it; other hosts use your current network.")
        if profile.authentication == .deviceKey {
            text += "\n\nA sudo password is optional. It stays in this device’s private Keychain, and at a terminal password prompt Fill Password types it after Face ID, Touch ID, or your passcode, without pressing Return. It goes to whatever program on that terminal shows the prompt. Changing the host, port, or user removes it."
        }
        return text
    }

    private var multiplexerFooter: String {
        let access = SSHTerminalExperimentAccess.current
        var parts = [access.herdr
            ? String(localized: "Herdr and tmux run in this host’s terminal: choosing one sets Run on Connect.")
            : String(localized: "tmux runs in this host’s terminal: choosing it sets Run on Connect.")]
        if access.rex {
            parts.append(String(localized: "With Rex, Connect opens the host’s Rex sessions instead of a terminal; tap a pane to open it here, or Shell for the login shell."))
        }
        return parts.joined(separator: " ")
    }

    private var startupFooter: String {
        // The Herdr note only while the form offers Herdr.
        let exits = SSHTerminalExperimentAccess.current.herdr
            ? String(localized: "The connection ends when the command exits (for Herdr, detach with Ctrl-B Q).")
            : String(localized: "The connection ends when the command exits.")
        var text = String(localized: "Runs this command in the terminal instead of a login shell, like `ssh -t host 'command'` or OpenSSH RemoteCommand. \(exits) The command must be on the PATH that SSH commands see.")
        if folderTerminal != nil {
            text += "\n\nTerminal from a workspace or chat starts its own login shell in that folder and ignores this command."
        }
        return text
    }

    private var identityFooter: String {
        var text = String(localized: "Append this public key to ~/.ssh/authorized_keys. Signing requires Face ID or your device passcode. The simulator uses a software key. Oppi never installs the key for you.")
        if deviceKey.identityNeedsReplacement {
            text += "\nReplace the old entry in ~/.ssh/authorized_keys with the new public key before connecting."
        }
        return text
    }

    private var actionsFooter: String {
        String(localized: "Saved passwords stay only in this device’s private Keychain and require Face ID or passcode at connect. Unsaved passwords are used for one attempt only. Keyboard-interactive and private-key import are not supported. Reconnect opens a fresh shell; use tmux to preserve work. Input is never replayed.")
    }

    /// What each row is drawn from. A field is keyed by everything a pass may
    /// change about it and never by its text, so typing redraws the rows that
    /// follow it and leaves the field itself untouched.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .host, .port, .username, .startup:
            AnyHashable([AnyHashable(isConnecting), AnyHashable(formRevision)])
        case .sudoPassword:
            AnyHashable([AnyHashable(isConnecting), AnyHashable(formRevision), AnyHashable(hasSavedSudoPassword)])
        case .authentication:
            AnyHashable([AnyHashable(profile.authentication), AnyHashable(isConnecting)])
        case .multiplexer:
            AnyHashable([AnyHashable(profile.multiplexerChoice), AnyHashable(isConnecting), experimentKey])
        case .savePassword:
            AnyHashable([AnyHashable(profile.savesPassword), AnyHashable(isConnecting)])
        case .colors:
            AnyHashable(colorSummary)
        case .publicKey:
            AnyHashable(deviceKey.identity?.publicKeyOpenSSH ?? "")
        case .backing:
            AnyHashable(deviceKey.identity?.backingDescription ?? "")
        case .identityStatus:
            AnyHashable(deviceKey.identityFailure ?? String(localized: "Loading identity…"))
        case .copyKey:
            AnyHashable(copied)
        case .replaceKey, .removeSudoPassword:
            AnyHashable(isConnecting)
        case .connecting:
            AnyHashable(session.savingHostOnly)
        case .connect, .saveHost:
            AnyHashable([AnyHashable(canConnect), AnyHashable(isConnecting)])
        case .failure:
            AnyHashable(session.failure)
        case .trustUnknown, .trustMismatch, .deleteHost:
            AnyHashable(0)
        }
    }

    /// The experiments decide which choices the Multiplexer row offers.
    private var experimentKey: AnyHashable {
        let access = SSHTerminalExperimentAccess.current
        return AnyHashable([AnyHashable(access.herdr), AnyHashable(access.rex)])
    }

    // MARK: - Cells

    private lazy var fieldRow = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, item in
        self?.configureField(cell, item: item)
    }

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
        if item == .multiplexer { self?.configureMultiplexer(cell) } else { self?.configureAuthentication(cell) }
    }

    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            title: "Terminal Colors",
            image: nil,
            value: colorSummary,
            identifier: "sshTerminal.colors"
        ) { [weak self] in self?.presentColorPicker() }
    }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, item in
        self?.configureAction(cell, item: item)
    }

    override func prepareRegistrations() {
        _ = (fieldRow, menuRow, indexRow, actionRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .host, .port, .username, .startup, .sudoPassword:
            collectionView.dequeueConfiguredReusableCell(using: fieldRow, for: indexPath, item: item)
        case .authentication, .multiplexer:
            collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .colors:
            collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        case .copyKey, .replaceKey, .connect, .saveHost, .deleteHost, .removeSudoPassword:
            collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        default:
            super.dequeue(item, at: indexPath)
        }
    }

    private func configureField(_ cell: SSHTerminalTextFieldCell, item: Item) {
        let fg = style.title
        let enabled = !isConnecting
        switch item {
        case .host:
            cell.configure(
                text: profile.host, placeholder: "Hostname or IP", identifier: "sshTerminal.host",
                keyboard: .URL, textColor: fg, enabled: enabled
            ) { [weak self] in
                self?.profile.host = $0
                self?.session.hostFailure = nil
                self?.session.failure = nil
                self?.setNeedsUpdateProperties()
            }
        case .port:
            cell.configure(
                text: portText, placeholder: "Port", identifier: "sshTerminal.port",
                keyboard: .numberPad, textColor: fg, enabled: enabled
            ) { [weak self] in
                self?.portText = $0
                self?.session.hostFailure = nil
                self?.session.failure = nil
                self?.setNeedsUpdateProperties()
            }
        case .username:
            cell.configure(
                text: profile.username, placeholder: "Username", identifier: "sshTerminal.username",
                keyboard: .default, textColor: fg, enabled: enabled
            ) { [weak self] in
                self?.profile.username = $0
                self?.setNeedsUpdateProperties()
            }
        case .sudoPassword:
            cell.configure(
                text: sudoPasswordText,
                placeholder: hasSavedSudoPassword ? "Sudo Password: saved, type to replace" : "Sudo Password (optional)",
                identifier: "sshTerminal.sudoPassword",
                isSecure: true, textColor: fg, enabled: enabled
            ) { [weak self] in
                self?.sudoPasswordText = $0
            }
        case .startup:
            cell.configure(
                text: profile.startupCommand ?? "", placeholder: "Login shell", identifier: "sshTerminal.startupCommand",
                monospaced: true, textColor: fg, enabled: enabled
            ) { [weak self] in
                guard let self else { return }
                profile.startupCommand = $0
                // The Multiplexer row shows what Run on Connect starts.
                setNeedsUpdateProperties()
            }
        default:
            break
        }
    }

    /// Herdr and tmux write the Run on Connect command below; Rex hides it.
    ///
    /// The menu offers the choices whose experiment is on (`SSHTerminalExperimentAccess`):
    /// Rex and Herdr are experiments (Settings → Experiments), and a host saved
    /// with one reads as None while its experiment is off, without rewriting what
    /// the host saved. Choosing what the row already shows writes nothing, so a
    /// saved Rex or Herdr choice survives the switch being off.
    private func configureMultiplexer(_ cell: SettingsMenuRowCell) {
        let access = SSHTerminalExperimentAccess.current
        let current = profile.multiplexerChoice.available(in: access)
        cell.configure(
            title: "Multiplexer",
            identifier: "sshTerminal.multiplexer",
            isEnabled: !isConnecting,
            value: current.label,
            menu: {
                SSHTerminalMultiplexerChoice.offered(in: access).map { choice in
                    SettingsMenuOption(title: choice.label, selected: choice == current) { [weak self] in
                        guard choice != current else { return }
                        self?.profile.choose(choice)
                        self?.setNeedsUpdateProperties()
                    }
                }
            }
        )
    }

    private func configureAuthentication(_ cell: SettingsMenuRowCell) {
        let authentication = profile.authentication
        cell.configure(
            title: "Sign In",
            identifier: "sshTerminal.authentication",
            isEnabled: !isConnecting,
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
                isEnabled: !isConnecting
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
                isEnabled: !isConnecting
            ) { [weak self] in self?.loadIdentityIfSelected(createReplacement: true) }
        case .connect:
            cell.configure(
                title: "Connect",
                identifier: "sshTerminal.connect.list",
                isEnabled: canConnect && !isConnecting
            ) { [weak self] in self?.connect() }
        case .saveHost:
            cell.configure(
                title: "Save Host",
                identifier: "sshTerminal.saveHost",
                isEnabled: canConnect && !isConnecting
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

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        let style = self.style
        var content = content(.subtitle)
        switch item {
        case .savePassword:
            content = self.content(.info)
            content.text = "Save Password"
            saveSwitch.isOn = profile.savesPassword
            saveSwitch.isEnabled = !isConnecting
            saveSwitch.accessibilityIdentifier = "sshTerminal.savePassword"
            cell.accessories = [.customView(configuration: .init(customView: saveSwitch, placement: .trailing()))]
            cell.accessibilityIdentifier = "sshTerminal.savePassword"
        case .publicKey:
            content.text = deviceKey.identity?.publicKeyOpenSSH ?? ""
            content.textProperties.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            content.textProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "sshTerminal.publicKey"
        case .backing:
            content.text = deviceKey.identity?.backingDescription ?? ""
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = style.value
        case .identityStatus:
            content.text = deviceKey.identityFailure ?? String(localized: "Loading identity…")
            content.textProperties.color = style.value
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
        case .failure:
            content.text = "Disconnected — \(session.failure ?? "")"
            content.textProperties.color = style.destructive
            content.textProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "sshTerminal.failure"
        case .trustUnknown:
            content.text = "New host — trust decision"
            content.secondaryText = "Verify the fingerprint, then Trust & Connect."
            cell.accessibilityIdentifier = "sshTerminal.trustPrompt"
        case .trustMismatch:
            content.text = "Host key changed — connection blocked."
            content.textProperties.color = style.destructive
            content.secondaryText = "Forget the trusted key only after you verify why it changed."
        default:
            break
        }
        cell.contentConfiguration = content
    }

    // MARK: - Actions

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
        // A live terminal of this host reads its theme folders; without one the
        // picker offers the two built-in choices and the one already chosen.
        let readThemes: (@MainActor () async -> [String]?)?
        if let live {
            readThemes = { await SSHTerminalColorLoader.listThemes { try await live.run($0) } }
        } else {
            readThemes = nil
        }
        let picker = SSHTerminalColorPickerViewController(
            selected: colorChoice,
            hostSummary: summary,
            readThemes: readThemes
        ) { [weak self] choice in
            guard let self else { return }
            self.colorChoice = choice
            // A saved host's terminal follows at once; a new host's choice is kept with the host.
            if SSHTerminalProfileStore().contains(self.profile.id) {
                SSHTerminalColorStore().setChoice(choice, for: self.profile.id)
            }
            self.setNeedsUpdateProperties()
        }
        Router.push(picker, from: self)
    }

    private func copyPublicKey() {
        guard let identity = deviceKey.identity else { return }
        UIPasteboard.general.string = identity.publicKeyOpenSSH
        copied = true
        setNeedsUpdateProperties()
    }

    private func loadIdentityIfSelected(createReplacement: Bool = false) {
        guard profile.authentication == .deviceKey else {
            deviceKey.applyLoadResult(identity: nil, needsReplacement: false, failure: nil)
            setNeedsUpdateProperties()
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
        setNeedsUpdateProperties()
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

    /// The form now shows what a connect or a save wrote, so its fields are
    /// refilled: the revision is what the field rows are keyed by.
    private func applySaved(_ saved: SSHTerminalProfile) {
        profile = saved
        portText = String(saved.port)
        if !sudoPasswordText.isEmpty {
            sudoPasswordText = ""
            view.endEditing(true)
        }
        formRevision &+= 1
        SSHTerminalColorStore().setChoice(colorChoice, for: saved.id)
        setNeedsUpdateProperties()
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
            formRevision &+= 1
            setNeedsUpdateProperties()
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
        // A Rex host opens its sessions screen, which signs in on its own, while the
        // Rex experiment is on: off, the host is a plain shell.
        if profile.listsRexSessions(), folderTerminal == nil {
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
