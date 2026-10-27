import UIKit

/// Settings > Experiments: opt-in features, each off by default and saved on
/// this device. Session Threads lives on `AppNavigation` so every mounted
/// session list sees a change; the rest are `AppPreferences.Experiments`
/// defaults the features read when they start.
final class SettingsExperimentsViewController: SettingsListViewController<SettingsExperimentsViewController.Section, SettingsExperimentsViewController.Item> {
    enum Section: Hashable, Sendable { case sessionThreads, liveVoice, durableSessions }
    enum Item: Hashable, Sendable {
        case sessionThreads, liveVoice, durableSessions, durableSessionsDefault
    }

    private let navigation: AppNavigation
    private let defaults: UserDefaults

    init(navigation: AppNavigation, defaults: UserDefaults = .standard) {
        self.navigation = navigation
        self.defaults = defaults
        super.init(
            title: String(localized: "Experiments"),
            listIdentifier: "settings.experiments.list",
            scope: .device,
            footers: true
        )
    }

    /// How many experiments are currently on, for the root row summary.
    @MainActor
    static func enabledCount(sessionThreadsEnabled: Bool) -> Int {
        [
            sessionThreadsEnabled,
            AppPreferences.Experiments.liveVoiceEnabled,
            AppPreferences.Experiments.durableSessionsEnabled,
        ].filter { $0 }.count
    }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        [
            SettingsSectionModel(
                .sessionThreads,
                footer: String(localized: "Groups sessions under the session that launched them, with Thread strips and a Thread view."),
                items: [.sessionThreads]
            ),
            SettingsSectionModel(
                .liveVoice,
                footer: String(localized: "Adds Live Voice to the composer's mic menu and Quick Session, to talk to a session hands-free. Needs a server with a voice backend."),
                items: [.liveVoice]
            ),
            SettingsSectionModel(
                .durableSessions,
                footer: String(localized: "On servers that offer durable sessions, the new-session composer shows a Classic / Durable switch. New sessions start Classic unless Start Sessions as Durable is on. Durable sessions are a development playground: they don't run your Pi extensions yet and don't match terminal coding agents feature for feature."),
                items: [.durableSessions] + (isOn(AppPreferences.Experiments.durableSessionsKey) ? [.durableSessionsDefault] : [])
            ),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .sessionThreads: AnyHashable(navigation.sessionThreadsEnabled)
        case .liveVoice: AnyHashable(isOn(AppPreferences.Experiments.liveVoiceKey))
        case .durableSessions: AnyHashable(isOn(AppPreferences.Experiments.durableSessionsKey))
        case .durableSessionsDefault: AnyHashable(isOn(AppPreferences.Experiments.durableSessionsDefaultKey))
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

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        switch item {
        case .sessionThreads:
            toggleRow(cell, title: String(localized: "Session Threads"), isOn: navigation.sessionThreadsEnabled, identifier: "settings.sessionThreads") { [weak self] in
                self?.navigation.sessionThreadsEnabled = $0
            }
        case .liveVoice:
            toggleRow(cell, title: String(localized: "Live Voice"), isOn: isOn(AppPreferences.Experiments.liveVoiceKey), identifier: "settings.experiments.liveVoice") { [weak self] in
                self?.set(AppPreferences.Experiments.liveVoiceKey, $0)
            }
        case .durableSessions:
            toggleRow(cell, title: String(localized: "Durable Sessions"), isOn: isOn(AppPreferences.Experiments.durableSessionsKey), identifier: "settings.experiments.durableSessions") { [weak self] in
                self?.set(AppPreferences.Experiments.durableSessionsKey, $0)
            }
        case .durableSessionsDefault:
            toggleRow(cell, title: String(localized: "Start Sessions as Durable"), isOn: isOn(AppPreferences.Experiments.durableSessionsDefaultKey), identifier: "settings.experiments.durableSessionsDefault") { [weak self] in
                self?.set(AppPreferences.Experiments.durableSessionsDefaultKey, $0)
            }
        }
    }
}
