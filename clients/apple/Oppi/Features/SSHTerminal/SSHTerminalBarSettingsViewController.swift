import UIKit

/// Settings > Terminal > Bottom Bar: the buttons of the terminal's bottom
/// bar as one ordered list. The bar draws the ones that are on, in this order,
/// in one pill centred between Back and the trailing corner; a row's switch
/// shows or hides its button, and its handle drags it into place. A hidden
/// button moves into the … menu, except keys and Paste, which the keyboard bars
/// and the grid's hold menu already offer, and Program Shortcuts, which the
/// chat bar's key strip has.
///
/// The list holds three kinds of row: the built-in buttons, Program Shortcuts
/// (the detected program's keys, as the key strips show them), and the custom
/// keys the person made. A custom key opens its editor from its row or a swipe,
/// and a swipe deletes it. Add Custom Key… sits under the list.
///
/// A Rex pane draws one Rex control, the pane switcher's pill, and its panel
/// replaces the program-status symbol and Rex Sessions. A **Rex Panel** section
/// says which of the panel's sections show (This pane, Panes, Other sessions)
/// and whether the pill's icon carries the program's status; it is left out of a
/// terminal that Run on Connect started in Herdr, which has no Rex.
///
/// The terminal can push this page from its … menu (Customize Bar…), so the
/// bar being changed is one Back away. Opened from a terminal, the page leaves
/// out the rows that terminal's multiplexer rules out (`SSHTerminalBarContext`:
/// a Rex pane has no Herdr row), for presentation only: the saved layout keeps
/// those actions' places and switches, and reordering moves only the rows shown.
/// Opened from Settings it has every row.
final class SSHTerminalBarSettingsViewController: ListScreenController<
    SSHTerminalBarSettingsViewController.Section, SSHTerminalBarSettingsViewController.Item
> {
    enum Section: Hashable, Sendable { case items, add, rexPanel, reset }

    /// A choice of the Rex panel.
    enum RexPanelOption: CaseIterable, Hashable, Sendable {
        case thisPane, panes, otherSessions, statusOnIcon

        var title: String {
            switch self {
            case .thisPane: String(localized: "This Pane")
            case .panes: String(localized: "Panes in This Session")
            case .otherSessions: String(localized: "Other Sessions")
            case .statusOnIcon: String(localized: "Status on the Icon")
            }
        }

        var identifier: String {
            switch self {
            case .thisPane: "settings.sshTerminal.bar.rexPanel.thisPane"
            case .panes: "settings.sshTerminal.bar.rexPanel.panes"
            case .otherSessions: "settings.sshTerminal.bar.rexPanel.otherSessions"
            case .statusOnIcon: "settings.sshTerminal.bar.rexPanel.statusOnIcon"
            }
        }

        func isOn(_ settings: SSHTerminalRexPanelSettings) -> Bool {
            switch self {
            case .thisPane: settings.showsThisPane
            case .panes: settings.showsPanes
            case .otherSessions: settings.showsOtherSessions
            case .statusOnIcon: settings.showsStatusOnIcon
            }
        }

        func setting(_ isOn: Bool, in settings: SSHTerminalRexPanelSettings) -> SSHTerminalRexPanelSettings {
            var next = settings
            switch self {
            case .thisPane: next.showsThisPane = isOn
            case .panes: next.showsPanes = isOn
            case .otherSessions: next.showsOtherSessions = isOn
            case .statusOnIcon: next.showsStatusOnIcon = isOn
            }
            return next
        }
    }

    enum Item: Hashable, Sendable {
        case bar(SSHTerminalBarItem)
        case addKey
        case rexPanel(RexPanelOption)
        case reset
    }

    private let store: SSHTerminalBarStore
    private let context: SSHTerminalBarContext

    init(context: SSHTerminalBarContext = .plain, store: SSHTerminalBarStore = SSHTerminalBarStore()) {
        self.context = context
        self.store = store
        super.init(
            title: String(localized: "Bottom Bar"),
            listIdentifier: "settings.sshTerminal.bar.list",
            scope: .device,
            headers: true,
            footers: true
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dataSource?.reorderingHandlers.canReorderItem = { slot in
            if case .bar = slot.pageItem { return true }
            return false
        }
        dataSource?.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            // The base keeps a drag inside its section, so the items section's
            // order is the new order of the rows shown.
            let shown = transaction.finalSnapshot.itemIdentifiers(inSection: .items).compactMap(\.pageItem).compactMap {
                item -> SSHTerminalBarItem? in
                if case .bar(let bar) = item { return bar }
                return nil
            }
            save(store.layout.reordering(shown))
        }
    }

    /// The page's one write of the layout. The store posts its change, which
    /// the open terminal redraws its bar from; this page redraws itself.
    private func save(_ next: SSHTerminalBarLayout) {
        store.setLayout(next)
        setNeedsUpdateProperties()
    }

    override func sections() -> [ListSection<Section, Item>] {
        let layout = store.layout
        let offers = offeredMultiplexers
        var sections: [ListSection<Section, Item>] = [
            ListSection(
                .items,
                footer: Self.barFooter(offers: offers),
                items: layout.order.filter(isListed).map(Item.bar)
            ),
            ListSection(.add, items: [.addKey]),
        ]
        if offers.rex {
            sections.append(ListSection(
                .rexPanel,
                header: String(localized: "Rex Panel"),
                footer: String(localized: "In a Rex pane the pane switcher at the bottom right is the one Rex control. Tap it for the panel; touch and hold for the quick pane menu. The panel's sections and the status on the icon are chosen here."),
                items: RexPanelOption.allCases.map(Item.rexPanel)
            ))
        }
        if layout != store.defaultLayout {
            sections.append(ListSection(.reset, items: [.reset]))
        }
        return sections
    }

    override func showsHeader(for section: Section) -> Bool { section == .rexPanel }

    /// The multiplexers this page can offer: the terminal has not ruled one out,
    /// and its experiment is on.
    private var offeredMultiplexers: (herdr: Bool, rex: Bool) {
        let access = SSHTerminalExperimentAccess.current
        return (access.herdr && context != .rex, access.rex && context != .herdr)
    }

    /// The list's footer, naming only the multiplexers the bar can draw.
    private static func barFooter(offers: (herdr: Bool, rex: Bool)) -> String {
        let base = String(localized: "The bar draws the buttons that are on, in this order, centred between Back and the corner. A button turned off moves into the \u{2026} menu, except the built-in keys, Program Shortcuts, and Paste, which the keyboard bars have. A button that doesn't fit the screen moves there too, except Paste, which is left out.")
        let multiplexers: String? = switch offers {
        case (true, true): String(localized: "Herdr and Rex show when the host runs them, but not in a terminal that is already inside the other, and Switch Terminal when more than one terminal is open.")
        case (true, false): String(localized: "Herdr shows when the host runs it, and Switch Terminal when more than one terminal is open.")
        case (false, true): String(localized: "Rex shows when the host runs it, and Switch Terminal when more than one terminal is open.")
        case (false, false): String(localized: "Switch Terminal shows when more than one terminal is open.")
        }
        let program = String(localized: "Program Shortcuts shows the keys of the program in front, and a custom key shows only for the program you pick.")
        return [base, multiplexers, program].compactMap { $0 }.joined(separator: " ")
    }

    /// Whether the page lists `item`: every row, except one this terminal's
    /// multiplexer rules out, and a custom key the store no longer has.
    private func isListed(_ item: SSHTerminalBarItem) -> Bool {
        switch item {
        case .action(let action): !context.hidden.contains(action)
        case .programShortcuts: true
        case .customKey(let id): store.customKeys.contains { $0.id == id }
        }
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .bar(let bar):
            AnyHashable([AnyHashable(store.layout.isShown(bar)), AnyHashable(key(bar))])
        case .rexPanel(let option):
            AnyHashable(option.isOn(store.rexPanel))
        case .addKey, .reset:
            AnyHashable(0)
        }
    }

    private func key(_ item: SSHTerminalBarItem) -> SSHTerminalCustomKey? {
        guard case .customKey(let id) = item else { return nil }
        return store.customKeys.first { $0.id == id }
    }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        if item == .addKey {
            cell.configure(
                title: String(localized: "Add Custom Key\u{2026}"),
                systemImage: "plus",
                identifier: "settings.sshTerminal.bar.addKey"
            ) { [weak self] in self?.present(SSHTerminalCustomKey(), isNew: true) }
        } else {
            cell.configure(
                title: String(localized: "Reset to Default"),
                identifier: "settings.sshTerminal.bar.reset"
            ) { [weak self] in
                self?.store.reset()
                self?.setNeedsUpdateProperties()
            }
        }
    }

    override func prepareRegistrations() {
        _ = actionRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .addKey, .reset: collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .bar, .rexPanel: super.dequeue(item, at: indexPath)
        }
    }

    /// The one switch both kinds of row draw.
    private func switchAccessory(
        _ isOn: Bool, identifier: String, cell: UICollectionViewListCell, onChange: @escaping (Bool) -> Void
    ) -> UICellAccessory {
        .settingsToggle(isOn, identifier: identifier, reusing: cell, onChange: onChange)
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        if case .rexPanel(let option) = item {
            var content = content(.plain)
            content.text = option.title
            cell.contentConfiguration = content
            cell.accessories = [
                switchAccessory(option.isOn(store.rexPanel), identifier: option.identifier, cell: cell) { [weak self] isOn in
                    guard let self else { return }
                    store.setRexPanel(option.setting(isOn, in: store.rexPanel))
                    setNeedsUpdateProperties()
                },
            ]
            return
        }
        guard case .bar(let bar) = item else { return }
        let keys = store.customKeys
        let custom = key(bar)
        var content = content(custom == nil ? .plain : .subtitle)
        content.text = bar.title(customKeys: keys)
        let symbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        switch bar {
        case .action(let action):
            content.image = action.image(configuration: symbolConfiguration)
        case .programShortcuts:
            content.image = UIImage(systemName: "command", withConfiguration: symbolConfiguration)
        case .customKey:
            content.image = UIImage(systemName: "keyboard", withConfiguration: symbolConfiguration)
        }
        if let custom {
            content.secondaryText = "\(custom.chord) \u{00B7} \(custom.showFor.title)"
        }
        content.imageProperties.reservedLayoutSize.width = UIListContentConfiguration.ImageProperties.standardDimension
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "settings.sshTerminal.bar.row.\(bar.rawValue)"
        cell.accessories = [
            switchAccessory(
                store.layout.isShown(bar),
                identifier: "settings.sshTerminal.bar.\(bar.rawValue)",
                cell: cell
            ) { [weak self] isOn in
                guard let self else { return }
                save(store.layout.setting(bar, shown: isOn))
            },
            .reorder(displayed: .always),
        ]
    }

    override func isSelectable(_ item: Item) -> Bool {
        if case .bar(let bar) = item { return key(bar) != nil }
        return false
    }

    override func select(_ item: Item) {
        guard case .bar(let bar) = item, let key = key(bar) else { return }
        present(key, isNew: false)
    }

    override func trailingSwipeActions(for item: Item) -> UISwipeActionsConfiguration? {
        guard case .bar(let bar) = item, case .customKey(let id) = bar, let key = key(bar) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, done in
            self?.store.delete(id)
            self?.setNeedsUpdateProperties()
            done(true)
        }
        delete.accessibilityLabel = String(localized: "Delete \(key.displayName)")
        let edit = UIContextualAction(style: .normal, title: String(localized: "Edit")) { [weak self] _, _, done in
            self?.present(key, isNew: false)
            done(true)
        }
        edit.backgroundColor = SettingsStyle.current.accent
        // A full swipe deletes, as in any list; the key is cheap to make again.
        return UISwipeActionsConfiguration(actions: [delete, edit])
    }

    private func present(_ key: SSHTerminalCustomKey, isNew: Bool) {
        let editor = SSHTerminalCustomKeyViewController(key: key, isNew: isNew) { [weak self] saved in
            self?.store.save(saved)
            self?.setNeedsUpdateProperties()
        }
        Router.present(
            editor,
            presentation: .sheet.detents([.large()]).inNavigation(),
            from: self
        )
    }
}
