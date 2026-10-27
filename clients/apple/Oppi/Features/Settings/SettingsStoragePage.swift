import UIKit

/// Settings > Storage & About: the app version, the size of what Oppi caches
/// from servers on this device, and Clear Local Cache behind a confirmation.
/// The cache itself is `LocalCache`.
final class SettingsStorageViewController: SettingsListViewController<SettingsStorageViewController.Section, SettingsStorageViewController.Item> {
    enum Section: Hashable, Sendable { case about, cache }
    enum Item: Hashable, Sendable { case version, cacheSize, clearCache }

    /// Nil until the first measurement finishes.
    private var cacheSizeText: String?
    private var isClearing = false

    init() {
        super.init(title: String(localized: "Storage & About"), listIdentifier: "settings.storage.list", footers: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await refreshCacheSize() }
    }

    private func refreshCacheSize() async {
        let size = await LocalCache.formattedSize()
        guard cacheSizeText != size else { return }
        cacheSizeText = size
        setNeedsUpdateProperties()
    }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        [
            SettingsSectionModel(.about, items: [.version]),
            SettingsSectionModel(
                .cache,
                footer: String(localized: "Session history, server details, and file lists Oppi keeps on this device so screens open quickly."),
                items: [.cacheSize, .clearCache]
            ),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .version: AnyHashable(0)
        case .cacheSize: AnyHashable(cacheSizeText)
        case .clearCache: AnyHashable(isClearing)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        var content = UIListContentConfiguration.valueCell()
        let palette = ThemeRuntimeState.currentPalette()
        switch item {
        case .version:
            content.text = String(localized: "Version")
            content.secondaryText = Self.appVersionLabel
            cell.accessibilityIdentifier = "settings.storage.version"
        case .cacheSize:
            content.text = String(localized: "Local Cache")
            content.secondaryText = cacheSizeText ?? String(localized: "Calculating…")
            cell.accessibilityIdentifier = "settings.storage.cacheSize"
        case .clearCache:
            content.text = String(localized: "Clear Local Cache")
            content.textProperties.color = UIColor(palette.red).withAlphaComponent(isClearing ? 0.5 : 1)
            cell.accessibilityIdentifier = "settings.storage.clearCache"
            if isClearing { cell.accessibilityTraits.insert(.notEnabled) }
        }
        cell.contentConfiguration = content
    }

    override func isSelectable(_ item: Item) -> Bool { item == .clearCache && !isClearing }

    override func select(_ item: Item) {
        if item == .clearCache { confirmClear() }
    }

    // MARK: - Clear Local Cache

    private func confirmClear() {
        guard !isClearing, presentedViewController == nil else { return }
        let sheet = UIAlertController(
            title: String(localized: "Clear Local Cache?"),
            message: String(localized: "Oppi downloads it from your servers again when needed."),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: String(localized: "Clear Local Cache"), style: .destructive) { [weak self] _ in
            self?.clear()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        // On iPad the sheet is a popover from the row that opened it.
        if let popover = sheet.popoverPresentationController {
            let row: UIView = dataSource?.indexPath(for: .clearCache).flatMap(collectionView.cellForItem(at:)) ?? collectionView
            popover.sourceView = row
            popover.sourceRect = row.bounds
        }
        present(sheet, animated: true)
    }

    private func clear() {
        guard !isClearing else { return }
        isClearing = true
        setNeedsUpdateProperties()
        Task {
            await LocalCache.clear()
            isClearing = false
            await refreshCacheSize()
            setNeedsUpdateProperties()
        }
    }

    private static var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }
}
