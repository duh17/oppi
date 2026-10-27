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

    /// The card behind a group of rows. The system paints it from the page's
    /// light or dark scheme, which `SettingsListStyle.applyTheme` sets from the
    /// theme, so it follows the theme without a token per theme.
    static let card = UIColor.secondarySystemGroupedBackground

    init(palette: ThemePalette) {
        title = UIColor(palette.fg)
        value = UIColor(palette.comment)
        accent = UIColor(palette.blue)
        destructive = UIColor(palette.red)
        warning = UIColor(palette.orange)
        page = UIColor(palette.bg)
    }

    @MainActor
    static var current: SettingsStyle { SettingsStyle(palette: ThemeRuntimeState.currentPalette()) }

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
