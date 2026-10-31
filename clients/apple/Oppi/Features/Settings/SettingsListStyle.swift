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
        title = palette.ui.fg
        value = palette.ui.comment
        accent = palette.ui.blue
        destructive = palette.ui.red
        warning = palette.ui.orange
        page = palette.ui.bg
        let highlight = palette.ui.bgHighlight
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
        /// copies the value (`ListScreenController.copyText(of:)`).
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

/// The list every settings page draws: pinned at the readable form width and
/// painted in the theme.
@MainActor
enum SettingsListStyle {
    /// Pins `collectionView` to `view`. With `endsAtKeyboard` the list ends at the
    /// top of the keyboard rather than the bottom of the view, so a field or
    /// editor in it can scroll above the keyboard; use it for a list that
    /// edits text in place.
    static func pin(_ collectionView: UICollectionView, in view: UIView, endsAtKeyboard: Bool = false) {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        let bottom: NSLayoutConstraint
        if endsAtKeyboard {
            view.keyboardLayoutGuide.usesBottomSafeArea = false
            bottom = collectionView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        } else {
            bottom = collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        }
        let maxWidth = collectionView.widthAnchor.constraint(lessThanOrEqualToConstant: IPadReadableContentWidth.form)
        let fillWidth = collectionView.widthAnchor.constraint(equalTo: view.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            bottom,
            collectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            maxWidth,
            fillWidth,
        ])
    }

    static func applyTheme(to view: UIView, collectionView: UICollectionView, themeID: ThemeID) {
        view.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        let bg = themeID.palette.ui.bg
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
    ///
    /// `cell`: the row the switch sits in. The cell keeps one switch for its whole
    /// life and every call sets it (value, enabled, identifier, label, action),
    /// so a row redrawn from a changed value (a save that rolled back) or reused
    /// for another row never has a replaced switch lingering beside the new one
    /// at the old position.
    static func settingsToggle(
        _ isOn: Bool,
        identifier: String? = nil,
        label: String? = nil,
        isEnabled: Bool = true,
        reusing cell: UICollectionViewListCell,
        onChange: @escaping (Bool) -> Void
    ) -> UICellAccessory {
        let held = SettingsSwitchHolder.holder(of: cell)
        let toggle = held.toggle
        toggle.isOn = isOn
        toggle.isEnabled = isEnabled
        toggle.accessibilityIdentifier = identifier
        toggle.accessibilityLabel = label
        if let previous = held.action { toggle.removeAction(previous, for: .valueChanged) }
        let action = UIAction { action in
            guard let toggle = action.sender as? UISwitch else { return }
            onChange(toggle.isOn)
        }
        held.action = action
        toggle.addAction(action, for: .valueChanged)
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

/// The one switch a settings row keeps across redraws, with its current action.
@MainActor
private final class SettingsSwitchHolder {
    private static var key: UInt8 = 0
    let toggle = UISwitch()
    var action: UIAction?

    static func holder(of cell: UICollectionViewListCell) -> SettingsSwitchHolder {
        if let held = objc_getAssociatedObject(cell, &key) as? SettingsSwitchHolder { return held }
        let holder = SettingsSwitchHolder()
        objc_setAssociatedObject(cell, &key, holder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return holder
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
