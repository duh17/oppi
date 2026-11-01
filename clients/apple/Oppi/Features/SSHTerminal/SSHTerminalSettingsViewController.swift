import UIKit

/// Settings › Terminal: the occasional setup of the terminal, kept off the page
/// that is for getting into something already running.
///
/// Three things, none of which connects: **Hosts** (a saved host's form: its
/// address, sign-in, Run on Connect command, and colors), **Rex on Your Tailnet**
/// (a Rex reached by its Tailscale name, with no SSH, and what limits that list),
/// and **Bottom Bar** (the buttons the terminal's bar draws, in order).
///
/// The Terminal page keeps the hosts' own rows for connecting, its ＋ for a new
/// host, and a saved host's ⋯ for this same form; what it no longer carries is
/// the Bottom Bar row and the tailnet card, which are settings and live here.
/// Opened from Settings (Terminal) and from the Terminal page's ⚙︎.
final class SSHTerminalSettingsViewController: ListScreenController<
    SSHTerminalSettingsViewController.Section, SSHTerminalSettingsViewController.Item
> {
    enum Section: Hashable, Sendable { case hosts, rexTailnet, bar }

    enum Item: Hashable, Sendable {
        case host(UUID)
        /// The saved metadata cannot be read, so no host can be listed.
        case unreadableHosts
        case rexTailnet
        case bottomBar
    }

    /// Where the saved hosts live. Tests pass a store over their own defaults.
    private let profileStore: @Sendable () -> SSHTerminalProfileStore
    /// The Rex nodes added by Tailscale name, and the store the tailnet page writes.
    private let rexStore: RexDirectStore
    /// How this device reaches a tailnet now; previews pin it.
    private let reach: @MainActor () -> RexTailnetReach
    /// The Bottom Bar's layout and the custom keys it draws.
    private let barStore: SSHTerminalBarStore

    /// The experiments: Rex on Your Tailnet exists, and the Bottom Bar summary names
    /// Rex and Herdr, only while each switch is on (Settings → Experiments).
    private let experiments: @MainActor () -> SSHTerminalExperimentAccess
    /// The experiments' switch changing while this page is up.
    private var experimentObserver: NSObjectProtocol?

    init(
        profileStore: @escaping @Sendable () -> SSHTerminalProfileStore = { SSHTerminalProfileStore() },
        rexStore: RexDirectStore = RexDirectStore(),
        reach: @escaping @MainActor () -> RexTailnetReach = { .current },
        barStore: SSHTerminalBarStore = SSHTerminalBarStore(),
        experiments: @escaping @MainActor () -> SSHTerminalExperimentAccess = { .current }
    ) {
        self.profileStore = profileStore
        self.rexStore = rexStore
        self.reach = reach
        self.barStore = barStore
        self.experiments = experiments
        super.init(
            title: String(localized: "Terminal"),
            listIdentifier: "settings.sshTerminal.list",
            scope: .device,
            headers: true,
            footers: true
        )
        // A switch turned over this page (in Settings → Experiments) takes effect
        // here without a relaunch.
        experimentObserver = NotificationCenter.default.addObserver(
            forName: AppPreferences.Experiments.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsUpdateProperties() }
        }
    }

    isolated deinit {
        if let experimentObserver { NotificationCenter.default.removeObserver(experimentObserver) }
    }

    override func sections() -> [ListSection<Section, Item>] {
        // The Rex row is left out of the page while its experiment is off, rather
        // than listed and disabled: there is nothing to open.
        [hostsSection()] + (experiments().rex ? [rexTailnetSection()] : []) + [barSection()]
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

    /// The buttons the bar draws now: the layout's shown items, named as the bar
    /// names them, without a button whose experiment is off.
    private var barSummary: String {
        let layout = barStore.layout
        let keys = barStore.customKeys
        let access = experiments()
        let shown = layout.order.filter { item in
            guard layout.isShown(item) else { return false }
            guard case .action(let action) = item else { return true }
            return access.allows(action)
        }
        return shown.map { $0.title(customKeys: keys) }.joined(separator: ", ")
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
        case .unreadableHosts:
            break
        }
    }

    private lazy var plainRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
        self?.configurePlain(cell, item: item)
    }

    override func prepareRegistrations() {
        _ = (indexRow, plainRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .host, .rexTailnet, .bottomBar:
            collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        case .unreadableHosts:
            collectionView.dequeueConfiguredReusableCell(using: plainRow, for: indexPath, item: item)
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
        case .unreadableHosts: false
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
        case .unreadableHosts: break
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
