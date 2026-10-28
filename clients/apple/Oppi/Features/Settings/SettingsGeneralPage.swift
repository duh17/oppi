import UIKit

/// Settings > General: haptics, how long the screen stays on after activity,
/// and where web links open. All three are device settings declared in
/// `SettingsCatalog` (on their `AppPreferences` keys) and read and written
/// through the app's `SettingsStore`; the page draws them with the kit's declared
/// rows, so a refused or failed write shows under its row. A choice is a
/// `SettingsMenuRowCell`: its menu is the one way to change it, at every text size.
final class SettingsGeneralViewController: SettingsListViewController<SettingsGeneralViewController.Section, SettingsGeneralViewController.Item> {
    enum Section: Hashable, Sendable { case haptics, screenAwake, links }
    enum Item: Hashable, Sendable {
        case haptics, keepAwake, openLinks
        /// The failure line under the declared setting with this id.
        case failure(String)
    }

    init(root: AppRootEnvironment) {
        super.init(
            title: String(localized: "General"),
            listIdentifier: "settings.general.list",
            scope: .device,
            settings: root.settings,
            footers: true
        )
    }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        let haptics = SettingsCatalog.hapticFeedback
        let keepAwake = SettingsCatalog.keepAwakeAfterActivity
        let openLinks = SettingsCatalog.openLinks
        let mode = settings?.read(openLinks).current ?? openLinks.default
        return [
            SettingsSectionModel(
                .haptics,
                footer: haptics.copy.footer,
                items: settingRows(haptics, .haptics) { .failure($0) }
            ),
            // Matches `ScreenAwakeController`: voice capture and running agents
            // hold the screen on; the preset only adds time after they stop.
            SettingsSectionModel(
                .screenAwake,
                footer: keepAwake.copy.footer,
                items: settingRows(keepAwake, .keepAwake) { .failure($0) }
            ),
            SettingsSectionModel(
                .links,
                footer: mode.detail,
                items: settingRows(openLinks, .openLinks) { .failure($0) }
            ),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .haptics: settingInputs(SettingsCatalog.hapticFeedback)
        case .keepAwake: settingInputs(SettingsCatalog.keepAwakeAfterActivity)
        case .openLinks: settingInputs(SettingsCatalog.openLinks)
        case .failure(let id): settingFailureInputs(id)
        }
    }

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .keepAwake:
            settingChoiceRow(cell, SettingsCatalog.keepAwakeAfterActivity, choices: AppPreferences.ScreenAwake.TimeoutPreset.allCases.map {
                SettingChoice(value: $0, title: $0.label)
            })
        case .openLinks:
            settingChoiceRow(cell, SettingsCatalog.openLinks, choices: AppPreferences.Browser.LinkOpeningMode.allCases.map {
                SettingChoice(value: $0, title: $0.label)
            })
        case .haptics, .failure:
            break
        }
    }

    override func prepareRegistrations() {
        _ = menuRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .haptics: super.dequeue(item, at: indexPath)
        case .keepAwake, .openLinks: collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .failure(let id): dequeueSettingFailure(id, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        if item == .haptics { settingToggleRow(cell, SettingsCatalog.hapticFeedback) }
    }
}
