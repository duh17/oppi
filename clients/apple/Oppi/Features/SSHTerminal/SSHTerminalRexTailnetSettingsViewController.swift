import UIKit

/// Settings › Terminal › Rex on Your Tailnet: the Rex nodes this device reaches
/// by their Tailscale name alone, with no SSH host and no sign-in, and what limits
/// that list.
///
/// A node saved here shows on the Terminal page as a Rex section of its own, over
/// its own Tailscale link; discovery finds the rest while that page shows. This page never connects and never probes: it lists what was saved and
/// takes a name typed by hand (Add Rex by Tailscale Name), which is the only way
/// in when Oppi has no Tailscale machine list of its own.
final class SSHTerminalRexTailnetSettingsViewController: ListScreenController<
    SSHTerminalRexTailnetSettingsViewController.Section, SSHTerminalRexTailnetSettingsViewController.Item
> {
    enum Section: Hashable, Sendable { case names, add }

    enum Item: Hashable, Sendable {
        /// A saved node, by its MagicDNS name (the store's key).
        case rex(String)
        case add
    }

    /// Where the nodes added by name live.
    private let store: RexDirectStore
    /// How this device reaches a tailnet now; previews pin it.
    private let reach: @MainActor () -> RexTailnetReach

    init(
        store: RexDirectStore = RexDirectStore(),
        reach: @escaping @MainActor () -> RexTailnetReach = { .current }
    ) {
        self.store = store
        self.reach = reach
        super.init(
            title: String(localized: "Rex on Your Tailnet"),
            listIdentifier: "settings.sshTerminal.rexTailnet.list",
            scope: .device,
            headers: true,
            footers: true
        )
    }

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(
                .names,
                footer: footer,
                items: store.tailnetHosts().map { Item.rex($0.dnsName) }
            ),
            ListSection(.add, items: [.add]),
        ]
    }

    override func showsHeader(for section: Section) -> Bool { false }

    private var footer: String {
        let base = String(localized: "A Rex shows on the Terminal page once its Tailscale serving is on (rex server tailscale on), and Rex admits this device by its Tailscale identity: the account that signed the Rex node in.")
        switch reach() {
        case .peers: return base
        case .systemOnly: return base + " " + Self.listsNoMachines
        case .none: return base + " " + Self.onNoTailnet
        }
    }

    /// What limits the list, for the footer here: Oppi has no machine list of its
    /// own, or the device is on no tailnet at all.
    private static let listsNoMachines = String(localized: "Oppi's own Tailscale is off, so it cannot list your tailnet's machines. Add a Rex by its Tailscale name, or connect Tailscale in Settings to find Rex here.")
    private static let onNoTailnet = String(localized: "This device is not on a tailnet. Connect Tailscale in Settings, or the Tailscale app, to reach Rex without SSH.")

    // MARK: - Rows

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .rex: AnyHashable(store.tailnetHosts().map(\.dnsName))
        case .add: AnyHashable(0)
        }
    }

    private lazy var plainRow = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
        guard let self, case .rex(let dnsName) = item else { return }
        let host = store.tailnetHosts().first { $0.dnsName == dnsName }
        var content = content(.subtitle)
        content.text = host?.name ?? dnsName
        content.secondaryText = dnsName
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "settings.sshTerminal.rexTailnet.\(dnsName)"
    }

    private lazy var addRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(
            title: String(localized: "Add Rex by Tailscale Name\u{2026}"),
            systemImage: "plus",
            identifier: "settings.sshTerminal.rexTailnet.add"
        ) { [weak self] in self?.promptForName() }
    }

    override func prepareRegistrations() {
        _ = (plainRow, addRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .rex:
            collectionView.dequeueConfiguredReusableCell(using: plainRow, for: indexPath, item: item)
        case .add:
            collectionView.dequeueConfiguredReusableCell(using: addRow, for: indexPath, item: item)
        }
    }

    override func trailingSwipeActions(for item: Item) -> UISwipeActionsConfiguration? {
        guard case .rex(let dnsName) = item else { return nil }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { [weak self] _, _, done in
            self?.remove(dnsName: dnsName)
            done(true)
        }
        remove.accessibilityLabel = String(localized: "Remove Rex")
        let config = UISwipeActionsConfiguration(actions: [remove])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    /// Removes one saved name: what its row's swipe runs.
    private func remove(dnsName: String) {
        store.forgetTailnetHost(dnsName: dnsName)
        setNeedsUpdateProperties()
    }

    // MARK: - Add

    private func promptForName(message: String? = nil, text: String = "") {
        TextPrompt(
            title: String(localized: "Add Rex by Tailscale Name"),
            message: message ?? String(localized: "The Rex's Tailscale name, as rex server tailscale pair shows it. Rex lets in the Tailscale account that signed it in."),
            placeholder: "rex.tailnet-name.ts.net",
            text: text,
            actionTitle: String(localized: "Add"),
            fieldIdentifier: "sshTerminal.rexTailnet.addName",
            actionIdentifier: "sshTerminal.rexTailnet.addConfirm",
            keyboardType: .URL
        ).present(from: self) { [weak self] typed in
            guard let self, !addTailnetRex(named: typed) else { return }
            promptForName(
                message: String(localized: "That is not a Tailscale name. Enter the full name, such as rex.tail1234.ts.net."),
                text: typed
            )
        }
    }

    /// Saves the Rex named by what was typed and lists it on the next pass. False
    /// for a name that is not a Rex's Tailscale name.
    @discardableResult
    func addTailnetRex(named typed: String) -> Bool {
        guard let host = RexTailnetHost.parse(typed) else { return false }
        store.saveTailnetHost(host)
        setNeedsUpdateProperties()
        return true
    }
}
