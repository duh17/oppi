import UIKit

/// Settings > Storage & About: the app version, the Support & Contact link, the
/// size of what Oppi caches from servers on this device, and Clear Local Cache
/// behind a confirmation. The cache itself is `LocalCache`.
final class SettingsStorageViewController: SettingsListViewController<SettingsStorageViewController.Section, SettingsStorageViewController.Item> {
    enum Section: Hashable, Sendable { case about, support, cache }
    enum Item: Hashable, Sendable { case version, support, cacheSize, clearCache }

    private let root: AppRootEnvironment

    /// Nil until the first measurement finishes.
    private var cacheSizeText: String?
    private var isClearing = false

    init(root: AppRootEnvironment) {
        self.root = root
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
                .support,
                footer: String(localized: "Where to report a problem or ask for help. Opens using your Open Links setting."),
                items: [.support]
            ),
            SettingsSectionModel(
                .cache,
                footer: String(localized: "Session history, server details, and file lists Oppi keeps on this device so screens open quickly."),
                items: [.cacheSize, .clearCache]
            ),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .version, .support: AnyHashable(0)
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

    private lazy var supportRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(
            title: String(localized: "Support & Contact"),
            systemImage: "questionmark.circle",
            identifier: "settings.supportContact",
            hint: String(localized: "Opens Oppi's public support and contact page")
        ) { [weak self] in
            self?.root.opener.open(.webLink(AppSupportLinks.supportURL))
        }
    }

    override func prepareRegistrations() {
        _ = (actionRow, supportRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .clearCache: collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .support: collectionView.dequeueConfiguredReusableCell(using: supportRow, for: indexPath, item: item)
        case .version, .cacheSize: super.dequeue(item, at: indexPath)
        }
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
        case .support, .clearCache:
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
