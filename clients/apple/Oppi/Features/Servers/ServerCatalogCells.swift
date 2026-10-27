import UIKit

/// The selected-server row of a server-global catalog list (Extensions): the
/// server's badge in its connection state's tint, its name, and the state word
/// under it. One paired server is passive; with several, the whole row is one
/// button that opens the switcher menu (`menu`), which the owner builds each
/// time it opens so it lists current states. The button is the row's only
/// accessibility element.
final class ServerCatalogServerRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let badge = SettingsServerBadgeView()
    private let nameLabel = UILabel()
    private let stateLabel = UILabel()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [badge, nameLabel, stateLabel, chevron, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        // The system highlight is the cell's own: it fills the whole row and
        // keeps the card's corners, which a content-view fill cannot.
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        nameLabel.font = .scaled(.body, .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.font = .scaled(.caption1)
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.numberOfLines = 0
        chevron.image = .scaledSymbol("chevron.up.chevron.down", style: .caption1, weight: .semibold)
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        // The labels paint the row; the button above them is its one accessible element.
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            badge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            nameLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            stateLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            stateLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            stateLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            chevron.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `menu` is nil for a single paired server: the row only reports it.
    func configure(
        server: PairedServer,
        state: ServerBadgeConnectionState,
        palette: ThemePalette,
        menu: UIMenu?
    ) {
        badge.apply(icon: server.resolvedBadgeIcon, tint: state.uiColor(ComposerThemeColors(palette: palette)))
        nameLabel.text = server.name
        nameLabel.textColor = UIColor(palette.fg)
        stateLabel.text = state.title
        stateLabel.textColor = UIColor(palette.comment)
        chevron.tintColor = UIColor(palette.comment)
        chevron.isHidden = menu == nil
        button.accessibilityLabel = "Current server: \(server.name)"
        button.accessibilityValue = state.title
        if let menu {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
            button.isUserInteractionEnabled = true
            button.accessibilityTraits = .button
            button.accessibilityIdentifier = "serverCatalog.server.menu"
        } else {
            button.menu = nil
            button.showsMenuAsPrimaryAction = false
            button.isUserInteractionEnabled = false
            button.accessibilityTraits = .staticText
            button.accessibilityIdentifier = "serverCatalog.server.passive"
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.menu = nil
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        nameLabel.text = nil
        stateLabel.text = nil
        isHighlighted = false
    }
}

/// The menu a catalog list's server row opens (`ServerCatalogServerRowCell`):
/// every paired server, the shown one checked, each titled with its name and,
/// unless connected, its connection state ("Name — state", the state also the
/// action's accessibility value); then Usage for the shown server. Choosing a
/// server asks for its lock, then makes it the active one once its connection
/// is ready. The menu is rebuilt each time it opens, so it lists current states.
@MainActor
enum ServerCatalogServerMenu {
    /// - Parameters:
    ///   - shownServerId: the server the list shows, read each time the menu opens.
    ///   - onSwitched: runs after the chosen server is active. A screen's own
    ///     follow-up (clearing its search, loading its catalog) goes here.
    static func make(
        coordinator: ConnectionCoordinator,
        navigation: AppNavigation,
        shownServerId: @escaping @MainActor () -> String?,
        onSwitched: @escaping @MainActor (PairedServer) -> Void = { _ in }
    ) -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { completion in
            completion(elements(
                coordinator: coordinator, navigation: navigation,
                shownServerId: shownServerId(), onSwitched: onSwitched
            ))
        }])
    }

    private static func elements(
        coordinator: ConnectionCoordinator,
        navigation: AppNavigation,
        shownServerId: String?,
        onSwitched: @escaping @MainActor (PairedServer) -> Void
    ) -> [UIMenuElement] {
        let servers: [UIMenuElement] = coordinator.serverStore.servers.map { server in
            let state = HostSwitcherBadgeState.make(for: server, coordinator: coordinator)
            let title = state == .connected ? server.name : "\(server.name) — \(state.title)"
            let symbol = server.id == shownServerId ? "checkmark.circle.fill" : server.resolvedBadgeIcon.symbolName
            let action = UIAction(title: title, image: UIImage(systemName: symbol)) { _ in
                Task { @MainActor in
                    guard await ScopedLockService.shared.authorize(.server(server.id)),
                          await coordinator.switchToServerReady(server) else { return }
                    onSwitched(server)
                }
            }
            action.accessibilityValue = state.title
            return action
        }
        var elements: [UIMenuElement] = [UIMenu(options: .displayInline, children: servers)]
        if let shownServerId {
            let usage = HostSwitcherDestination.usage
            let action = UIAction(title: usage.menuTitle, image: UIImage(systemName: usage.systemImage)) { _ in
                navigation.openHostSwitcherDestination(usage, serverId: shownServerId)
            }
            action.accessibilityIdentifier = usage.accessibilityIdentifier
            elements.append(UIMenu(options: .displayInline, children: [action]))
        }
        return elements
    }
}
