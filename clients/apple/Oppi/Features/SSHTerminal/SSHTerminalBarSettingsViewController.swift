import UIKit

/// Settings > Terminal > Bottom Bar: which buttons the terminal's bottom
/// bar shows, and in what order. Middle holds the customizable middle pill
/// (Type in Terminal, Chat Bar, keys, Paste, Browse Files Here); Right holds
/// Herdr, Rex, and the switcher, which sit beside … at the trailing end. A row's
/// switch shows or hides its button; a hidden one moves into the … menu,
/// except keys and Paste, which the keyboard bars and the grid's hold menu
/// already offer. Rows reorder with their handles inside their section, so
/// editing stays on and there is no Edit button.
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
    enum Section: Hashable, Sendable { case middle, trailing, reset }

    enum Item: Hashable, Sendable {
        case action(SSHTerminalBarAction)
        case reset
    }

    private var layout: SSHTerminalBarLayout { AppPreferences.SSHTerminalBar.layout }

    private let context: SSHTerminalBarContext

    init(context: SSHTerminalBarContext = .plain) {
        self.context = context
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
        collectionView.isEditing = true
        dataSource?.reorderingHandlers.canReorderItem = { slot in
            guard let item = slot.pageItem else { return false }
            if case .action = item { return true }
            return false
        }
        dataSource?.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            // The base keeps a drag inside its section, so the sections in
            // order are the order.
            let snapshot = transaction.finalSnapshot
            let next = [Section.middle, .trailing].reduce(layout) { layout, section in
                layout.reordering(snapshot.itemIdentifiers(inSection: section).compactMap(\.pageItem).compactMap { item -> SSHTerminalBarAction? in
                    if case .action(let action) = item { return action }
                    return nil
                })
            }
            save(next)
        }
    }

    /// The page's one write. The preference posts its change, which the open
    /// terminal redraws its bar from; this page redraws itself.
    private func save(_ next: SSHTerminalBarLayout) {
        AppPreferences.SSHTerminalBar.setLayout(next)
        setNeedsUpdateProperties()
    }

    override func sections() -> [ListSection<Section, Item>] {
        let layout = layout
        func items(_ group: SSHTerminalBarAction.Group) -> [Item] {
            layout.order.filter { $0.group == group && !context.hidden.contains($0) }.map(Item.action)
        }
        var sections: [ListSection<Section, Item>] = [
            ListSection(
                .middle,
                header: String(localized: "Middle"),
                footer: String(localized: "A button turned off moves into the \u{2026} menu, except keys and Paste, which the keyboard bars have. A button that doesn't fit the screen moves into the menu too, except Paste, which is left out."),
                items: items(.middle)
            ),
            ListSection(
                .trailing,
                header: String(localized: "Right"),
                footer: String(localized: "Herdr and Rex show when the host runs them, but not in a terminal that is already inside the other, and Switch Terminal when more than one terminal is open."),
                items: items(.trailing)
            ),
        ]
        if !layout.isDefault {
            sections.append(ListSection(.reset, items: [.reset]))
        }
        return sections
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .action(let action): AnyHashable(layout.isShown(action))
        case .reset: AnyHashable(0)
        }
    }

    private lazy var resetRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(
            title: String(localized: "Reset to Default"),
            identifier: "settings.sshTerminal.bar.reset"
        ) { [weak self] in
            AppPreferences.SSHTerminalBar.reset()
            self?.setNeedsUpdateProperties()
        }
    }

    override func prepareRegistrations() {
        _ = resetRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .reset: collectionView.dequeueConfiguredReusableCell(using: resetRow, for: indexPath, item: item)
        case .action: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        guard case .action(let action) = item else { return }
        var content = content(.plain)
        content.text = action.label
        content.image = action.image(configuration: UIImage.SymbolConfiguration(textStyle: .body))
        content.imageProperties.reservedLayoutSize.width = UIListContentConfiguration.ImageProperties.standardDimension
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "settings.sshTerminal.bar.row.\(action.rawValue)"
        cell.accessories = [
            .settingsToggle(
                layout.isShown(action),
                identifier: "settings.sshTerminal.bar.\(action.rawValue)",
                reusing: cell
            ) { [weak self] isOn in
                guard let self else { return }
                save(layout.setting(action, shown: isOn))
            },
            // Always editing, so the handle is part of the row, not a mode.
            .reorder(displayed: .always),
        ]
    }
}
