import UIKit

/// Settings > Appearance: where the theme comes from, which theme or themes
/// are chosen, and Custom Themes. Choosing a theme opens the theme gallery.
/// The values are `ThemeStore`, which is observable, so a change from the
/// gallery or from the system's light/dark switch redraws the page.
final class SettingsAppearanceViewController: SettingsListViewController<SettingsAppearanceViewController.Section, SettingsAppearanceViewController.Item> {
    enum Section: Hashable, Sendable { case source, themes, custom }
    enum Item: Hashable, Sendable {
        case source
        case theme(ThemeSlot)
        case customThemes
    }

    private let root: AppRootEnvironment
    private var themeStore: ThemeStore { root.themeStore }

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(title: String(localized: "Appearance"), listIdentifier: "settings.appearance.list", scope: .device, footers: true)
        traitOverrides.appRootEnvironment = root
    }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        let manual = themeStore.mode == .manual
        let themesFooter: String? = if manual {
            themeStore.manualThemeID.detail.isEmpty ? nil : themeStore.manualThemeID.detail
        } else {
            String(localized: "Uses your iOS Display & Brightness setting, including Apple's automatic schedule.")
        }
        return [
            SettingsSectionModel(.source, footer: themeStore.mode.detail, items: [.source]),
            SettingsSectionModel(
                .themes,
                footer: themesFooter,
                items: manual ? [.theme(.manual)] : [.theme(.light), .theme(.dark)]
            ),
            SettingsSectionModel(
                .custom,
                footer: String(localized: "Import themes from your server, or describe a new one and Oppi writes it. Themes are JSON files in the Oppi data directory (usually ~/.config/oppi/themes); Pi TUI themes in ~/.pi/agent/themes are converted automatically."),
                items: [.customThemes]
            ),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .source: AnyHashable(themeStore.mode)
        case .theme(let slot): AnyHashable(slot.themeID(in: themeStore).rawValue)
        case .customThemes: AnyHashable(0)
        }
    }

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            title: String(localized: "Theme Source"),
            identifier: "settings.appearance.themeSource",
            options: ThemeMode.allCases.map { mode in
                (mode.displayName, mode == themeStore.mode, { [weak self] in self?.themeStore.mode = mode })
            }
        )
    }

    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .theme(let slot):
            cell.configure(
                title: slot.title,
                systemImage: nil,
                value: slot.themeID(in: themeStore).displayName,
                identifier: slot.rowIdentifier
            ) { [weak self] in self?.openGallery(slot) }
        case .customThemes:
            cell.configure(
                title: String(localized: "Custom Themes"),
                systemImage: nil,
                value: nil,
                identifier: "settings.appearance.customThemes"
            ) { [weak self] in self?.openCustomThemes() }
        case .source:
            break
        }
    }

    override func prepareRegistrations() {
        _ = (menuRow, indexRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        item == .source
            ? collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
            : collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
    }

    private func navigator() -> ScreenNavigator {
        ScreenNavigator.forUIKitScreen(self, root: root)
    }

    private func openGallery(_ slot: ThemeSlot) {
        navigator().push(ThemeGalleryViewController(themeStore: themeStore, slot: slot))
    }

    private func openCustomThemes() {
        navigator().push(ThemeImportViewController(root: root))
    }
}
