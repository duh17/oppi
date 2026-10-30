import UIKit

/// Settings > Chat > Top Bar: which of Files, Git, Outline, Context, and Terminal a
/// chat's top bar shows, and in what order. A row's switch shows or hides it; a
/// hidden button moves into the … menu, which always stays last. Rows reorder
/// with their handles, so editing stays on and there is no Edit button.
///
/// The order holds every action, hidden ones included, so a hidden button
/// returns to the place it left. Terminal keeps its row in every chat: a chat
/// without a workspace folder only leaves it out of that chat's bar.
final class SettingsChatTopBarViewController: ListScreenController<SettingsChatTopBarViewController.Section, ChatTopBarAction> {
    enum Section: Hashable, Sendable { case buttons }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(
            title: String(localized: "Top Bar"),
            listIdentifier: "settings.chat.topBar.list",
            scope: .device,
            footers: true
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The chat's "Chat tools are in the menu" hint points here; reaching
        // the page is done.
        FeatureEducationTips.markTopBarMoreToolsFound()
        collectionView.isEditing = true
        dataSource?.reorderingHandlers.canReorderItem = { _ in true }
        dataSource?.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            // Every action has a row here, so the dragged order is the order.
            let order = transaction.finalSnapshot.itemIdentifiers(inSection: .buttons).compactMap(\.pageItem)
            AppPreferences.ChatTopBar.setLayout(ChatTopBarLayout(order: order, shown: layout.shown), in: defaults)
            // The bar's order now matches; redraw so the snapshot and the
            // preference cannot drift after a drag.
            setNeedsUpdateProperties()
        }
    }

    private var layout: ChatTopBarLayout { AppPreferences.ChatTopBar.layout(in: defaults) }

    override func sections() -> [ListSection<Section, ChatTopBarAction>] {
        [ListSection(
            .buttons,
            footer: String(localized: "A button turned off moves into the … menu, which always stays last. Terminal also needs a workspace folder on the server."),
            items: layout.order
        )]
    }

    override func inputs(of action: ChatTopBarAction) -> AnyHashable {
        AnyHashable(layout.isShown(action))
    }

    override func configure(_ cell: UICollectionViewListCell, item action: ChatTopBarAction) {
        var content = content(.plain)
        content.text = action.label
        content.image = action.image(textStyle: .body)
        // The symbol column's width for every row, so a label beside the Git
        // logo (an image, not a symbol) lines up with the others.
        content.imageProperties.reservedLayoutSize.width = UIListContentConfiguration.ImageProperties.standardDimension
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "settings.chat.topBar.row.\(action.rawValue)"
        cell.accessories = [
            .settingsToggle(
                layout.isShown(action),
                identifier: "settings.chat.topBar.\(action.rawValue)",
                reusing: cell
            ) { [weak self] isOn in
                guard let self else { return }
                AppPreferences.ChatTopBar.setLayout(layout.setting(action, shown: isOn), in: defaults)
            },
            // Always editing, so the handle is part of the row, not a mode.
            .reorder(displayed: .always),
        ]
    }
}
