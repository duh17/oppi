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
        super.init(title: String(localized: "Storage & About"), listIdentifier: "settings.storage.list", scope: .device, footers: true)
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

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            title: String(localized: "Clear Local Cache"),
            tint: .destructive,
            identifier: "settings.storage.clearCache",
            isBusy: isClearing,
            confirmation: .init(
                title: String(localized: "Clear Local Cache?"),
                message: String(localized: "Oppi downloads it from your servers again when needed."),
                actionTitle: String(localized: "Clear Local Cache")
            )
        ) { [weak self] in self?.clear() }
    }

    override func prepareRegistrations() {
        _ = actionRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        item == .clearCache
            ? collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
            : super.dequeue(item, at: indexPath)
    }

    /// The version and the cache size: read-only facts.
    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        var content = content(.info)
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
            break
        }
        cell.contentConfiguration = content
    }

    override func copyText(of item: Item) -> String? {
        item == .version ? Self.appVersionLabel : nil
    }

    // MARK: - Clear Local Cache

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
