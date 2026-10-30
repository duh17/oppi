import UIKit

/// Settings > SSH Terminal > Bottom Bar: which buttons the terminal's bottom
/// bar shows, and in what order. Middle holds the customizable middle pill
/// (Type in Terminal, Chat Bar, keys, Paste, Browse Files Here); Right holds
/// Herdr, Rex, and the switcher, which sit beside … at the trailing end. A row's
/// switch shows or hides its button; a hidden one moves into the … menu,
/// except keys and Paste, which the keyboard bars and the grid's hold menu
/// already offer. Rows reorder with their handles inside their section, so
/// editing stays on and there is no Edit button.
///
/// The terminal can push this page from its … menu (Customize Bar…), so the
/// bar being changed is one Back away.
final class SSHTerminalBarSettingsViewController: SettingsListViewController<
    SSHTerminalBarSettingsViewController.Section, SSHTerminalBarSettingsViewController.Item
> {
    enum Section: Hashable, Sendable { case middle, trailing, reset }

    enum Item: Hashable, Sendable {
        case action(SSHTerminalBarAction)
        case reset
    }

    private var layout: SSHTerminalBarLayout { AppPreferences.SSHTerminalBar.layout }

    init() {
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
        dataSource?.reorderingHandlers.canReorderItem = { item in
            if case .action = item { return true }
            return false
        }
        dataSource?.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            // The base keeps a drag inside its section, so the sections in
            // order are the order.
            let snapshot = transaction.finalSnapshot
            let order = [Section.middle, .trailing].flatMap { section in
                snapshot.itemIdentifiers(inSection: section).compactMap { item -> SSHTerminalBarAction? in
                    if case .action(let action) = item { return action }
                    return nil
                }
            }
            save(SSHTerminalBarLayout(order: order, shown: layout.shown))
        }
    }

    /// The page's one write. The preference posts its change, which the open
    /// terminal redraws its bar from; this page redraws itself.
    private func save(_ next: SSHTerminalBarLayout) {
        AppPreferences.SSHTerminalBar.setLayout(next)
        setNeedsUpdateProperties()
    }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        let layout = layout
        func items(_ group: SSHTerminalBarAction.Group) -> [Item] {
            layout.order.filter { $0.group == group }.map(Item.action)
        }
        var sections: [SettingsSectionModel<Section, Item>] = [
            SettingsSectionModel(
                .middle,
                header: String(localized: "Middle"),
                footer: String(localized: "A button turned off moves into the \u{2026} menu, except keys and Paste, which the keyboard bars have. A button that doesn't fit the screen moves into the menu too, except Paste, which is left out."),
                items: items(.middle)
            ),
            SettingsSectionModel(
                .trailing,
                header: String(localized: "Right"),
                footer: String(localized: "Herdr and Rex show when the host runs them, and Switch Terminal when more than one terminal is open."),
                items: items(.trailing)
            ),
        ]
        if !layout.isDefault {
            sections.append(SettingsSectionModel(.reset, items: [.reset]))
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
