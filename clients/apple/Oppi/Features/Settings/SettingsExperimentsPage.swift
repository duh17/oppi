import UIKit

/// Settings > Experiments: opt-in features, each off by default and saved on
/// this device. Session Threads lives on `AppNavigation` so every mounted
/// session list sees a change; the rest are `AppPreferences.Experiments`
/// defaults the features read when they start.
final class SettingsExperimentsViewController: UIViewController {
    private let navigation: AppNavigation
    private let defaults: UserDefaults
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var appliedThemeID: ThemeID?

    private enum Section: Hashable { case sessionThreads, sshTerminal, liveVoice, durableSessions }
    private enum Item: Hashable {
        case sessionThreads, sshTerminal, liveVoice, durableSessions, durableSessionsDefault
    }

    init(navigation: AppNavigation, defaults: UserDefaults = .standard) {
        self.navigation = navigation
        self.defaults = defaults
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Experiments")
        navigationItem.largeTitleDisplayMode = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// How many experiments are currently on, for the root row summary.
    @MainActor
    static func enabledCount(sessionThreadsEnabled: Bool) -> Int {
        [
            sessionThreadsEnabled,
            AppPreferences.Experiments.sshTerminalEnabled,
            AppPreferences.Experiments.liveVoiceEnabled,
            AppPreferences.Experiments.durableSessionsEnabled,
        ].filter { $0 }.count
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.allowsSelection = false
        collectionView.accessibilityIdentifier = "settings.experiments.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil)
        setNeedsUpdateProperties()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        applySnapshot(sessionThreads: navigation.sessionThreadsEnabled)
    }

    private func applySnapshot(sessionThreads: Bool) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.sessionThreads, .sshTerminal, .liveVoice, .durableSessions])
        snapshot.appendItems([.sessionThreads], toSection: .sessionThreads)
        snapshot.appendItems([.sshTerminal], toSection: .sshTerminal)
        snapshot.appendItems([.liveVoice], toSection: .liveVoice)
        snapshot.appendItems(
            [.durableSessions] + (isOn(AppPreferences.Experiments.durableSessionsKey) ? [.durableSessionsDefault] : []),
            toSection: .durableSessions
        )
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = self?.dataSource?.sectionIdentifier(for: indexPath.section).map(Self.footer)
            content.textProperties.numberOfLines = 0
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private static func footer(_ section: Section) -> String {
        switch section {
        case .sessionThreads:
            String(localized: "Groups sessions under the session that launched them, with Thread strips and a Thread view.")
        case .sshTerminal:
            String(localized: "Adds SSH Hosts to Settings.")
        case .liveVoice:
            String(localized: "Adds Live Voice to the composer's mic menu and Quick Session, to talk to a session hands-free. Needs a server with a voice backend.")
        case .durableSessions:
            String(localized: "On servers that offer durable sessions, the new-session composer shows a Classic / Durable switch. New sessions start Classic unless Start Sessions as Durable is on. Durable sessions are a development playground: they don't run your Pi extensions yet and don't match terminal coding agents feature for feature.")
        }
    }

    // MARK: - Cells

    private func isOn(_ key: String) -> Bool { defaults.bool(forKey: key) }

    /// Saves the experiment and re-reads the page, so the Durable Sessions
    /// default row follows its parent toggle.
    private func set(_ key: String, _ enabled: Bool) {
        defaults.set(enabled, forKey: key)
        setNeedsUpdateProperties()
    }

    private func configure(_ cell: UICollectionViewListCell, item: Item) {
        var content = UIListContentConfiguration.valueCell()
        switch item {
        case .sessionThreads:
            content.text = String(localized: "Session Threads")
            cell.accessories = [.settingsToggle(navigation.sessionThreadsEnabled, identifier: "settings.sessionThreads") { [weak self] in
                self?.navigation.sessionThreadsEnabled = $0
            }]
        case .sshTerminal:
            content.text = String(localized: "SSH Terminal")
            cell.accessories = [.settingsToggle(isOn(AppPreferences.Experiments.sshTerminalKey), identifier: "settings.experiments.sshTerminal") { [weak self] in
                self?.set(AppPreferences.Experiments.sshTerminalKey, $0)
            }]
        case .liveVoice:
            content.text = String(localized: "Live Voice")
            cell.accessories = [.settingsToggle(isOn(AppPreferences.Experiments.liveVoiceKey), identifier: "settings.experiments.liveVoice") { [weak self] in
                self?.set(AppPreferences.Experiments.liveVoiceKey, $0)
            }]
        case .durableSessions:
            content.text = String(localized: "Durable Sessions")
            cell.accessories = [.settingsToggle(isOn(AppPreferences.Experiments.durableSessionsKey), identifier: "settings.experiments.durableSessions") { [weak self] in
                self?.set(AppPreferences.Experiments.durableSessionsKey, $0)
            }]
        case .durableSessionsDefault:
            content.text = String(localized: "Start Sessions as Durable")
            cell.accessories = [.settingsToggle(isOn(AppPreferences.Experiments.durableSessionsDefaultKey), identifier: "settings.experiments.durableSessionsDefault") { [weak self] in
                self?.set(AppPreferences.Experiments.durableSessionsDefaultKey, $0)
            }]
        }
        cell.contentConfiguration = content
    }
}
