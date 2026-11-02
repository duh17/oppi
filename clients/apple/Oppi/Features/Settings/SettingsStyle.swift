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
