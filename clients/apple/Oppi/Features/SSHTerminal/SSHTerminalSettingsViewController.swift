import UIKit

/// Settings › Terminal: the occasional setup of the terminal, kept off the page
/// that is for getting into something already running.
///
/// Four things, none of which connects: **Hosts** (a saved host's form: its
/// address, sign-in, Run on Connect command, and colors), **Rex on Your Tailnet**
/// (a Rex reached by its Tailscale name, with no SSH, and what limits that list),
/// **Bottom Bar** (the buttons the terminal's bar draws, in order), and **Tap in
/// Terminal** (whether a tap raises the keyboard, `SettingsCatalog.terminalTapMode`).
///
/// The Terminal page keeps the hosts' own rows for connecting, its ＋ for a new
/// host, and a saved host's ⋯ for this same form; what it no longer carries is
/// the Bottom Bar row and the tailnet card, which are settings and live here.
/// Opened from Settings (Terminal) and from the Terminal page's ⚙︎.
final class SSHTerminalSettingsViewController: ListScreenController<
    SSHTerminalSettingsViewController.Section, SSHTerminalSettingsViewController.Item
> {
    enum Section: Hashable, Sendable { case hosts, rexTailnet, bar, typing }

    enum Item: Hashable, Sendable {
        case host(UUID)
        /// The saved metadata cannot be read, so no host can be listed.
        case unreadableHosts
        case rexTailnet
        case bottomBar
        case tapMode
        /// The failure line under the declared setting with this id.
        case failure(String)
    }

    /// Where the saved hosts live. Tests pass a store over their own defaults.
    private let profileStore: @Sendable () -> SSHTerminalProfileStore
    /// The Rex nodes added by Tailscale name, and the store the tailnet page writes.
    private let rexStore: RexDirectStore
    /// How this device reaches a tailnet now; previews pin it.
    private let reach: @MainActor () -> RexTailnetReach
    /// The Bottom Bar's layout and the custom keys it draws.
    private let barStore: SSHTerminalBarStore

    init(
        profileStore: @escaping @Sendable () -> SSHTerminalProfileStore = { SSHTerminalProfileStore() },
        rexStore: RexDirectStore = RexDirectStore(),
        reach: @escaping @MainActor () -> RexTailnetReach = { .current },
        barStore: SSHTerminalBarStore = SSHTerminalBarStore(),
        settings: SettingsStore = .liveDevice()
    ) {
        self.profileStore = profileStore
        self.rexStore = rexStore
        self.reach = reach
        self.barStore = barStore
        super.init(
            title: String(localized: "Terminal"),
            listIdentifier: "settings.sshTerminal.list",
            scope: .device,
            settings: settings,
            headers: true,
            footers: true
        )
    }

    override func sections() -> [ListSection<Section, Item>] {
        [hostsSection(), rexTailnetSection(), barSection(), typingSection()]
    }

    override func showsHeader(for section: Section) -> Bool { true }

    // MARK: - Sections

    /// The saved hosts, each row opening its form. A host is saved or deleted on
    /// the Terminal page (＋ there, and a swipe on its row), so this page has no
    /// Add row of its own.
    private func hostsSection() -> ListSection<Section, Item> {
        let store = profileStore()
        let unreadable = store.metadataIsCorrupt
        let profiles = unreadable ? [] : store.load()
        var items = profiles.map { Item.host($0.id) }
        if unreadable { items.append(.unreadableHosts) }
        return ListSection(
            .hosts,
            header: String(localized: "Hosts"),
            footer: String(localized: "Tap a host to edit it."),
            items: items
        )
    }

    /// No footer, and no heading: the row names the page it opens, and the page
    /// itself says what limits the list.
    private func rexTailnetSection() -> ListSection<Section, Item> {
        ListSection(.rexTailnet, items: [.rexTailnet])
    }

    private func barSection() -> ListSection<Section, Item> {
        ListSection(
            .bar,
            footer: String(localized: "Buttons on the terminal's bottom bar, in order. Turned-off buttons move to the \u{2026} menu."),
            items: [.bottomBar]
        )
    }

    /// Whether a tap raises the keyboard: a declared device setting, drawn and
    /// saved by the kit's rows.
    private func typingSection() -> ListSection<Section, Item> {
        let tapMode = SettingsCatalog.terminalTapMode
        return ListSection(.typing, footer: tapMode.copy.footer, items: settingRows(tapMode, .tapMode) { .failure($0) })
    }

    /// The buttons the bar draws now: the layout's shown items, named as the bar
    /// names them.
    private var barSummary: String {
        let layout = barStore.layout
        let keys = barStore.customKeys
        return layout.order.filter(layout.isShown).map { $0.title(customKeys: keys) }.joined(separator: ", ")
    }

    private var tailnetSummary: String {
        let count = rexStore.tailnetHosts().count
        return count == 0 ? String(localized: "None added") : String(localized: "\(count) Rex")
    }

    // MARK: - Rows

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .host(let id):
            // What the row draws, not just which rows exist: a host renamed in its
            // form must not keep the old label on the way back.
            let profile = profileStore().profile(id: id)
            return AnyHashable([profile?.endpointLabel ?? "", profile?.portLabel ?? ""])
        case .unreadableHosts:
            // The row is one fixed sentence: nothing about it changes.
            return AnyHashable(0)
        case .rexTailnet:
            return AnyHashable(tailnetSummary)
        case .bottomBar:
            return AnyHashable(barSummary)
        case .tapMode:
            return settingInputs(SettingsCatalog.terminalTapMode)
        case .failure(let id):
            return settingFailureInputs(id)
        }
    }

    /// Every row that opens something runs `select(_:)`, the same owner action a tap
    /// and VoiceOver's activation take, so the row's closure and `select` cannot
    /// drift apart.
    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .host(let id):
            let profile = profileStore().profile(id: id)
            cell.configure(
                title: profile?.endpointLabel ?? "",
                image: nil,
                value: profile?.portLabel,
                identifier: "settings.sshTerminal.host.\(id.uuidString)"
            ) { [weak self] in self?.select(item) }
        case .rexTailnet:
            cell.configure(
                title: String(localized: "Rex on Your Tailnet"),
                image: nil,
                value: tailnetSummary,
                identifier: "settings.sshTerminal.rexTailnet"
            ) { [weak self] in self?.select(item) }
        case .bottomBar:
            cell.configure(
                title: String(localized: "Bottom Bar"),
                image: nil,
                value: barSummary,
                identifier: "settings.sshTerminal.bar"
            ) { [weak self] in self?.select(item) }
        case .unreadableHosts, .tapMode, .failure:
            break
        }
    }

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, _ in
        self?.settingChoiceRow(cell, SettingsCatalog.terminalTapMode, choices: AppPreferenceStore.Terminal.TapMode.allCases.map {
            SettingChoice(value: $0, title: $0.label)
        })
    }

    private lazy var plainRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
        self?.configurePlain(cell, item: item)
    }

    override func prepareRegistrations() {
        _ = (indexRow, plainRow, menuRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .host, .rexTailnet, .bottomBar:
            collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        case .unreadableHosts:
            collectionView.dequeueConfiguredReusableCell(using: plainRow, for: indexPath, item: item)
        case .tapMode:
            collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .failure(let id):
            dequeueSettingFailure(id, at: indexPath)
        }
    }

    /// The hosts' metadata cannot be read: the same words the Terminal page uses,
    /// and the way out is there (Reset Host List).
    private func configurePlain(_ cell: UICollectionViewListCell, item: Item) {
        guard case .unreadableHosts = item else { return }
        var content = self.content(.subtitle)
        content.text = SSHTerminalProfileStoreError.corruptMetadata.localizedDescription
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "settings.sshTerminal.hosts.unreadable"
    }

    override func isSelectable(_ item: Item) -> Bool {
        switch item {
        case .host, .rexTailnet, .bottomBar: true
        case .unreadableHosts, .tapMode, .failure: false
        }
    }

    override func select(_ item: Item) {
        switch item {
        case .host(let id): openHost(id)
        case .rexTailnet: openTailnet()
        case .bottomBar:
            // The bar's own page, over this page's store, so a change here and there
            // is one layout.
            Router.push(SSHTerminalBarSettingsViewController(store: barStore), from: self)
        case .unreadableHosts, .tapMode, .failure: break
        }
    }

    // MARK: - Pages

    private func openHost(_ id: UUID) {
        Router.push(SSHTerminalSetupViewController(profileID: id), from: self)
    }

    private func openTailnet() {
        Router.push(
            SSHTerminalRexTailnetSettingsViewController(store: rexStore, reach: reach),
            from: self
        )
    }
}
