import UIKit

/// The colors a settings page draws with, read from the current theme. One
/// title color on every page: the theme's `fg`. A page never picks `.label`
/// or a one-off color for a row title.
struct SettingsStyle {
    /// A row's title.
    let title: UIColor
    /// A row's current value, and the secondary lines under a title.
    let value: UIColor
    /// The tint of choices, links, and actions that do something.
    let accent: UIColor
    /// Actions that delete or disconnect.
    let destructive: UIColor
    /// A problem the person can still act on.
    let warning: UIColor
    /// The page behind the cards.
    let page: UIColor
    /// The card behind a group of rows: the system card or the theme's own
    /// `bgHighlight`, whichever reads better against `bg`. In a dark theme that
    /// is whichever contrasts more (the system card sits at 1.01 on a `bg` near
    /// `#1C1C1E`). A light theme keeps the system card (white) unless it is
    /// under `minimumCardContrast` against `bg`, and then takes `bgHighlight`
    /// if that contrasts more.
    let card: UIColor

    /// The least contrast ratio a themed card needs against the page.
    static let minimumCardContrast: CGFloat = 1.08

    init(palette: ThemePalette, isDark: Bool) {
        title = UIColor(palette.fg)
        value = UIColor(palette.comment)
        accent = UIColor(palette.blue)
        destructive = UIColor(palette.red)
        warning = UIColor(palette.orange)
        page = UIColor(palette.bg)
        let highlight = UIColor(palette.bgHighlight)
        let system = UIColor.secondarySystemGroupedBackground
        let highlightContrast = Self.contrast(highlight, page, isDark: isDark)
        let systemContrast = Self.contrast(system, page, isDark: isDark)
        let prefersHighlight = isDark
            ? highlightContrast > systemContrast
            : systemContrast < Self.minimumCardContrast && highlightContrast > systemContrast
        card = prefersHighlight ? highlight : system
    }

    @MainActor
    static var current: SettingsStyle {
        SettingsStyle(
            palette: ThemeRuntimeState.currentPalette(),
            isDark: ThemeRuntimeState.currentThemeID().preferredColorScheme != .light
        )
    }

    /// WCAG contrast ratio between two colors in a light or dark scheme, 1 to 21.
    static func contrast(_ first: UIColor, _ second: UIColor, isDark: Bool) -> CGFloat {
        let (one, two) = (luminance(first, isDark: isDark), luminance(second, isDark: isDark))
        return (max(one, two) + 0.05) / (min(one, two) + 0.05)
    }

    private static func luminance(_ color: UIColor, isDark: Bool) -> CGFloat {
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The background of a settings row: the system list-cell look (so a press
    /// keeps its pressed fill) with the theme's card color when the row is at
    /// rest.
    @MainActor
    static func cardBackground(for state: UICellConfigurationState) -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listCell().updated(for: state)
        if !state.isHighlighted, !state.isSelected, !state.isFocused {
            background.backgroundColor = current.card
        }
        return background
    }

    /// What a plain list row shows.
    enum Content {
        /// A title, and what a switch or menu in the accessory says.
        case plain
        /// A read-only fact: the title and its value on one line. Long press
        /// copies the value (`SettingsListViewController.copyText(of:)`).
        case info
        /// A title with a second line under it.
        case subtitle
    }

    /// A list content configuration with the title in the theme's title color
    /// and the value in its value color.
    @MainActor
    static func content(_ kind: Content) -> UIListContentConfiguration {
        var content: UIListContentConfiguration = switch kind {
        case .plain: .cell()
        case .info: .valueCell()
        case .subtitle: .subtitleCell()
        }
        let style = current
        content.textProperties.color = style.title
        content.secondaryTextProperties.color = style.value
        return content
    }
}

/// Where a setting is kept, which a page says only when it differs from what
/// the page as a whole says.
enum SettingsScope: Hashable, Sendable {
    /// This device only.
    case device
    /// The server, for every device that uses it. The name is the server's.
    case server(String)
    /// One workspace. The name is the workspace's.
    case workspace(String)
    /// This device's own value, stored on the server. The name is the server's.
    case deviceOnServer(String)

    /// The one sentence a section shows when its scope is not its page's.
    var sentence: String {
        switch self {
        case .device: String(localized: "Saved on this device.")
        case .server(let name): String(localized: "Applies to every device on \(name).")
        case .workspace: String(localized: "Applies to this workspace.")
        case .deviceOnServer(let name): String(localized: "For this device, kept on \(name).")
        }
    }

    /// The footer a section shows: the scope sentence when the section's scope
    /// is not the page's, then the section's own footer.
    static func footer(_ footer: String?, scope: SettingsScope?, pageScope: SettingsScope) -> String? {
        guard let scope, scope != pageScope else { return footer }
        guard let footer, !footer.isEmpty else { return scope.sentence }
        return scope.sentence + " " + footer
    }
}

/// The list every settings page draws: pinned at the readable form width and
/// painted in the theme.
@MainActor
enum SettingsListStyle {
    static func pin(_ collectionView: UICollectionView, in view: UIView) {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        let maxWidth = collectionView.widthAnchor.constraint(lessThanOrEqualToConstant: IPadReadableContentWidth.form)
        let fillWidth = collectionView.widthAnchor.constraint(equalTo: view.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            maxWidth,
            fillWidth,
        ])
    }

    static func applyTheme(to view: UIView, collectionView: UICollectionView, themeID: ThemeID) {
        view.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        let bg = UIColor(themeID.palette.bg)
        view.backgroundColor = bg
        collectionView.backgroundColor = bg
    }

    /// Paints a settings row's card in the theme. A cell that already has its
    /// own background handler keeps it.
    @discardableResult
    static func card(_ cell: UICollectionViewCell) -> UICollectionViewCell {
        guard let cell = cell as? UICollectionViewListCell else { return cell }
        if cell.configurationUpdateHandler == nil {
            cell.configurationUpdateHandler = { cell, state in
                cell.backgroundConfiguration = SettingsStyle.cardBackground(for: state)
            }
        }
        // A theme change reconfigures the row through the data source, which
        // comes back here; the handler reads the theme again.
        cell.setNeedsUpdateConfiguration()
        return cell
    }

    /// A data source's cell provider whose cells are painted with the theme's
    /// card. Every settings list builds its data source with this.
    static func cardProvider<Item>(
        _ provider: @escaping (UICollectionView, IndexPath, Item) -> UICollectionViewCell?
    ) -> (UICollectionView, IndexPath, Item) -> UICollectionViewCell? {
        { collectionView, indexPath, item in provider(collectionView, indexPath, item).map(card) }
    }

    /// An inset-grouped list layout whose own background is clear, so the
    /// theme's `bg` shows behind the cards instead of the system's grouped
    /// background.
    static func layoutConfiguration(headers: Bool, footers: Bool) -> UICollectionLayoutListConfiguration {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.backgroundColor = .clear
        if headers { config.headerMode = .supplementary }
        if footers { config.footerMode = .supplementary }
        return config
    }
}

@MainActor
extension UICellAccessory {
    /// A trailing switch. `identifier` makes it `app.switches[id]` in UI tests.
    /// A disabled switch keeps a row's saved value visible while the row cannot
    /// be changed. `label` names the switch for VoiceOver and `app.switches[label]`
    /// where the row's text is not its name.
    static func settingsToggle(
        _ isOn: Bool,
        identifier: String? = nil,
        label: String? = nil,
        isEnabled: Bool = true,
        onChange: @escaping (Bool) -> Void
    ) -> UICellAccessory {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.isEnabled = isEnabled
        toggle.accessibilityIdentifier = identifier
        toggle.accessibilityLabel = label
        toggle.addAction(UIAction { action in
            guard let toggle = action.sender as? UISwitch else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        return .customView(configuration: .init(customView: toggle, placement: .trailing()))
    }

    /// A trailing pop-up button showing the current choice. Pages that are not
    /// on the settings base use it; a page on the base uses `SettingsMenuRowCell`.
    static func settingsPopUpMenu(
        identifier: String,
        isEnabled: Bool = true,
        options: [(title: String, selected: Bool, action: () -> Void)]
    ) -> UICellAccessory {
        let button = UIButton(type: .system)
        button.isEnabled = isEnabled
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.accessibilityIdentifier = identifier
        button.menu = UIMenu(children: options.map { option in
            UIAction(title: option.title, state: option.selected ? .on : .off) { _ in option.action() }
        })
        var config = UIButton.Configuration.plain()
        config.indicator = .popup
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 0)
        button.configuration = config
        return .customView(configuration: .init(customView: button, placement: .trailing()))
    }
}

/// Which rows of a settings list a pass must reconfigure: those whose inputs
/// changed since the last pass. Reconfiguring a row replaces its accessories,
/// and replacing a pop-up button dismisses the menu it has open, so a pass
/// that UIKit runs for the menu itself, or for a change to another row, must
/// leave that row alone.
struct ChangedRows<Item: Hashable> {
    private var last: [Item: AnyHashable] = [:]

    /// The rows in `items` whose `inputs` differ from the previous call.
    mutating func changed(in items: [Item], inputs: (Item) -> AnyHashable) -> [Item] {
        var next: [Item: AnyHashable] = [:]
        var changed: [Item] = []
        for item in items {
            let value = inputs(item)
            next[item] = value
            if last[item] != value { changed.append(item) }
        }
        last = next
        return changed
    }
}
