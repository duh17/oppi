import UIKit

/// Settings > General: haptics, how long the screen stays on after activity,
/// and where web links open. Values are `AppPreferences`, which are not
/// observable, so each change writes the preference and asks for a re-read.
///
/// A choice row is a title with a trailing pop-up menu. At accessibility text
/// sizes the pop-up would take the row's width and leave the title no room, so
/// the row stacks instead (the title over the current choice, like a system
/// value cell) and tapping it opens the same choices in an action sheet.
final class SettingsGeneralViewController: SettingsListViewController<SettingsGeneralViewController.Section, SettingsGeneralViewController.Item> {
    enum Section: Hashable, Sendable { case haptics, screenAwake, links }
    enum Item: Hashable, Sendable { case haptics, keepAwake, openLinks }

    private typealias Choice = (title: String, selected: Bool, action: () -> Void)

    init() {
        super.init(title: String(localized: "General"), listIdentifier: "settings.general.list", footers: true)
    }

    private var stacksChoiceRows: Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        [
            SettingsSectionModel(
                .haptics,
                footer: String(localized: "Adds short taps as you use Oppi. Also follows your iOS System Haptics setting."),
                items: [.haptics]
            ),
            // Matches `ScreenAwakeController`: voice capture and running agents
            // hold the screen on; the preset only adds time after they stop.
            SettingsSectionModel(
                .screenAwake,
                footer: String(localized: "Oppi always keeps the screen on while you dictate or an agent is working, and this sets how long it stays on afterward."),
                items: [.keepAwake]
            ),
            SettingsSectionModel(
                .links,
                footer: AppPreferences.Browser.linkOpeningMode.detail,
                items: [.openLinks]
            ),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .haptics: AnyHashable(AppPreferences.Interaction.isHapticFeedbackEnabled)
        case .keepAwake: AnyHashable([AnyHashable(AppPreferences.ScreenAwake.timeoutPreset), AnyHashable(stacksChoiceRows)])
        case .openLinks: AnyHashable([AnyHashable(AppPreferences.Browser.linkOpeningMode), AnyHashable(stacksChoiceRows)])
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        var content = UIListContentConfiguration.valueCell()
        if item == .haptics {
            let title = String(localized: "Haptic Feedback")
            content.text = title
            cell.accessories = [.settingsToggle(
                AppPreferences.Interaction.isHapticFeedbackEnabled,
                identifier: "settings.general.haptics",
                label: title
            ) { [weak self] enabled in
                AppPreferences.Interaction.setHapticFeedbackEnabled(enabled)
                self?.setNeedsUpdateProperties()
            }]
        } else if let row = choiceRow(item) {
            content.text = row.title
            if stacksChoiceRows {
                content.secondaryText = row.options.first(where: \.selected)?.title
                cell.accessibilityIdentifier = row.identifier
            } else {
                cell.accessories = [.settingsPopUpMenu(identifier: row.identifier, label: row.title, options: row.options)]
            }
        }
        cell.contentConfiguration = content
    }

    private func choiceRow(_ item: Item) -> (title: String, identifier: String, options: [Choice])? {
        switch item {
        case .haptics:
            return nil
        case .keepAwake:
            let current = AppPreferences.ScreenAwake.timeoutPreset
            return (String(localized: "Keep Awake After Activity"), "settings.general.keepAwake",
                AppPreferences.ScreenAwake.TimeoutPreset.allCases.map { preset in
                    (preset.label, preset == current, { [weak self] in
                        AppPreferences.ScreenAwake.setTimeoutPreset(preset)
                        ScreenAwakeController.shared.refreshFromPreferences()
                        self?.setNeedsUpdateProperties()
                    })
                })
        case .openLinks:
            let current = AppPreferences.Browser.linkOpeningMode
            return (String(localized: "Open Links"), "settings.general.openLinks",
                AppPreferences.Browser.LinkOpeningMode.allCases.map { mode in
                    (mode.label, mode == current, { [weak self] in
                        AppPreferences.Browser.setLinkOpeningMode(mode)
                        self?.setNeedsUpdateProperties()
                    })
                })
        }
    }

    // MARK: - Stacked rows

    override func isSelectable(_ item: Item) -> Bool { stacksChoiceRows && item != .haptics }

    override func select(_ item: Item) {
        guard let row = choiceRow(item), presentedViewController == nil else { return }
        let sheet = UIAlertController(title: row.title, message: nil, preferredStyle: .actionSheet)
        for option in row.options {
            sheet.addAction(UIAlertAction(title: option.title, style: .default) { _ in option.action() })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        // On iPad the sheet is a popover from the row that opened it.
        if let popover = sheet.popoverPresentationController,
           let cell = dataSource?.indexPath(for: item).flatMap(collectionView.cellForItem(at:)) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }
}
