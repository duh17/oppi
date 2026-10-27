import UIKit

/// Settings > General: haptics, how long the screen stays on after activity,
/// and where web links open. Values are `AppPreferences`, which are not
/// observable, so each change writes the preference and asks for a re-read.
/// A choice is a `SettingsMenuRowCell`: its menu is the one way to change it,
/// at every text size.
final class SettingsGeneralViewController: SettingsListViewController<SettingsGeneralViewController.Section, SettingsGeneralViewController.Item> {
    enum Section: Hashable, Sendable { case haptics, screenAwake, links }
    enum Item: Hashable, Sendable { case haptics, keepAwake, openLinks }

    private typealias Choice = (title: String, selected: Bool, action: () -> Void)

    init() {
        super.init(title: String(localized: "General"), listIdentifier: "settings.general.list", scope: .device, footers: true)
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
                footer: String(localized: "Oppi keeps the screen on while you dictate or an agent is working. This sets how long it stays on afterward."),
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
        case .keepAwake: AnyHashable(AppPreferences.ScreenAwake.timeoutPreset)
        case .openLinks: AnyHashable(AppPreferences.Browser.linkOpeningMode)
        }
    }

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
        guard let self, let row = choiceRow(item) else { return }
        cell.configure(title: row.title, identifier: row.identifier, options: row.options)
    }

    override func prepareRegistrations() {
        _ = menuRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        item == .haptics
            ? super.dequeue(item, at: indexPath)
            : collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        guard item == .haptics else { return }
        toggleRow(
            cell,
            title: String(localized: "Haptic Feedback"),
            isOn: AppPreferences.Interaction.isHapticFeedbackEnabled,
            identifier: "settings.general.haptics"
        ) { [weak self] enabled in
            AppPreferences.Interaction.setHapticFeedbackEnabled(enabled)
            self?.setNeedsUpdateProperties()
        }
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
}
