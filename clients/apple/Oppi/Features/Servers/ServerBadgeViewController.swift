import UIKit

/// Badge Icon: a preview of this server's badge and the grid of icons to pick it
/// from. The preview's tint is the live connection state, as in the server
/// switcher; the choice is kept on this device, per server.
///
/// The page is pinned to the server it was made for (Server Settings pushes it and
/// tracks it, so a server switch closes it). A tap asks the server store to save
/// the icon (Keychain first), and the grid's mark and the preview read the store's own
/// answer, so a save that fails (the Keychain write throws, or the store has not loaded the
/// pairing list) leaves the old icon marked and says why in an alert.
@MainActor
final class ServerBadgeViewController: SettingsListViewController<ServerBadgeViewController.Section, ServerBadgeViewController.Item> {
    enum Section: Hashable, Sendable { case preview, icons }
    enum Item: Hashable, Sendable { case preview, icons }

    let server: PairedServer
    private let root: AppRootEnvironment
    private let errorAlert = ControlErrorAlert()

    init(server: PairedServer, root: AppRootEnvironment) {
        self.server = server
        self.root = root
        super.init(
            title: String(localized: "Badge Icon"),
            listIdentifier: "server.badge.list",
            scope: .device,
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    private var coordinator: ConnectionCoordinator { root.coordinator }

    /// The pinned server as the pairing list has it now.
    private var current: PairedServer { coordinator.serverStore.server(for: server.id) ?? server }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        [
            SettingsSectionModel(.preview, items: [.preview]),
            SettingsSectionModel(
                .icons,
                footer: Self.footer,
                items: [.icons]
            ),
        ]
    }

    /// What the badge's color says. The same four states the Server Settings summary shows.
    static let footer = String(localized: "The badge color shows the connection: green connected, blue connecting, orange recovering, red offline.")

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .preview:
            let state = HostSwitcherBadgeState.make(for: current, coordinator: coordinator)
            return AnyHashable([current.resolvedBadgeIcon.rawValue, String(describing: state)])
        case .icons:
            return AnyHashable(current.resolvedBadgeIcon.rawValue)
        }
    }

    private lazy var gridRow = UICollectionView.CellRegistration<ServerBadgeGridCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(selected: current.resolvedBadgeIcon) { [weak self] icon in self?.choose(icon) }
    }

    override func prepareRegistrations() {
        _ = gridRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .icons: collectionView.dequeueConfiguredReusableCell(using: gridRow, for: indexPath, item: item)
        case .preview: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        guard item == .preview else { return }
        var content = content(.plain)
        content.text = String(localized: "Preview")
        cell.contentConfiguration = content
        let badge = SettingsServerBadgeView()
        let state = HostSwitcherBadgeState.make(for: current, coordinator: coordinator)
        badge.apply(icon: current.resolvedBadgeIcon, tint: state.uiColor(ComposerThemeColors(palette: ThemeRuntimeState.currentPalette())))
        badge.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        badge.isAccessibilityElement = true
        badge.accessibilityLabel = String(localized: "Server badge")
        cell.accessories = [.customView(configuration: .init(customView: badge, placement: .trailing()))]
        cell.accessibilityIdentifier = "server.badge.preview"
    }

    /// Saves `icon` as this server's badge. The grid redraws from the store,
    /// so a save that fails leaves the old icon marked and says why.
    func choose(_ icon: ServerBadgeIcon) {
        do {
            try coordinator.serverStore.setBadgeIcon(id: server.id, to: icon)
        } catch {
            errorAlert.show(
                title: String(localized: "Couldn't Save Badge Icon"),
                message: String(localized: "The previous icon stays. \(error.localizedDescription)"),
                from: self
            ) {}
        }
        setNeedsUpdateProperties()
    }
}

extension ServerBadgeIcon {
    /// What VoiceOver says for the icon: the thing it draws.
    var title: String {
        switch self {
        case .macStudio: String(localized: "Mac Studio")
        case .desktop: String(localized: "Desktop")
        case .laptop: String(localized: "Laptop")
        case .macMini: String(localized: "Mac mini")
        case .macPro: String(localized: "Mac Pro")
        case .display: String(localized: "Display")
        case .serverRack: String(localized: "Server rack")
        case .cpu: String(localized: "Processor")
        case .memorychip: String(localized: "Memory chip")
        case .externaldrive: String(localized: "External drive")
        case .cloud: String(localized: "Cloud")
        case .network: String(localized: "Network")
        case .antenna: String(localized: "Antenna")
        case .wifi: String(localized: "Wi-Fi")
        case .terminal: String(localized: "Terminal")
        case .hammer: String(localized: "Hammer")
        case .wrench: String(localized: "Wrench and screwdriver")
        case .gearshape: String(localized: "Gears")
        case .bolt: String(localized: "Bolt")
        case .cube: String(localized: "Cube")
        case .hexagon: String(localized: "Hexagon")
        case .atom: String(localized: "Atom")
        case .sparkles: String(localized: "Sparkles")
        case .shield: String(localized: "Shield")
        }
    }
}

// MARK: - Grid cell

/// The icon grid: every `ServerBadgeIcon` as a button, six to a row, the chosen one
/// marked. Each button is its own accessibility element (`server.badge.<symbol>`)
/// that speaks what it draws and carries the selected trait when chosen.
final class ServerBadgeGridCell: UICollectionViewListCell {
    static let columns = 6

    private let rows = UIStackView()
    private var buttons: [ServerBadgeIcon: UIButton] = [:]
    private var onChoose: ((ServerBadgeIcon) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        rows.axis = .vertical
        rows.spacing = 4
        rows.distribution = .fill
        rows.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            rows.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            rows.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        let icons = ServerBadgeIcon.allCases
        for start in stride(from: 0, to: icons.count, by: Self.columns) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 4
            row.distribution = .fillEqually
            for icon in icons[start ..< min(start + Self.columns, icons.count)] {
                let button = UIButton(type: .custom)
                button.addAction(UIAction { [weak self] _ in self?.onChoose?(icon) }, for: .touchUpInside)
                button.heightAnchor.constraint(equalToConstant: 44).isActive = true
                button.accessibilityIdentifier = "server.badge.\(icon.rawValue)"
                button.accessibilityLabel = icon.title
                buttons[icon] = button
                row.addArrangedSubview(button)
            }
            // A short last row keeps its columns the width of the others.
            for _ in row.arrangedSubviews.count ..< Self.columns {
                row.addArrangedSubview(UIView())
            }
            rows.addArrangedSubview(row)
        }
        accessibilityElements = ServerBadgeIcon.allCases.compactMap { buttons[$0] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(selected: ServerBadgeIcon, onChoose: @escaping (ServerBadgeIcon) -> Void) {
        self.onChoose = onChoose
        let style = SettingsStyle.current
        for (icon, button) in buttons {
            let isSelected = icon == selected
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: UIImage(systemName: icon.symbolName) != nil ? icon.symbolName : "desktopcomputer")
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            configuration.baseForegroundColor = isSelected ? style.accent : style.value
            var background = UIBackgroundConfiguration.clear()
            background.cornerRadius = 8
            if isSelected {
                background.backgroundColor = style.accent.withAlphaComponent(0.18)
                background.strokeColor = style.accent.withAlphaComponent(0.6)
                background.strokeWidth = 1.5
            }
            configuration.background = background
            button.configuration = configuration
            button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChoose = nil
    }
}
