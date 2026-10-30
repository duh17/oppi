import UIKit

/// Settings > Experiments: opt-in features, each off by default and saved on
/// this device: `AppPreferences.Experiments` defaults the features read when
/// they start.
final class SettingsExperimentsViewController: ListScreenController<SettingsExperimentsViewController.Section, SettingsExperimentsViewController.Item> {
    enum Section: Hashable, Sendable { case liveVoice }
    enum Item: Hashable, Sendable { case liveVoice }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
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
    static func enabledCount() -> Int {
        AppPreferences.Experiments.liveVoiceEnabled ? 1 : 0
    }

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(
                .liveVoice,
                footer: String(localized: "Adds Live Voice to the composer's mic menu and Quick Session, to talk to a session hands-free. Needs a server with a voice backend."),
                items: [.liveVoice]
            ),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .liveVoice: AnyHashable(isOn(AppPreferences.Experiments.liveVoiceKey))
        }
    }

    // MARK: - Cells

    private func isOn(_ key: String) -> Bool { defaults.bool(forKey: key) }

    /// Saves the experiment and re-reads the page.
    private func set(_ key: String, _ enabled: Bool) {
        defaults.set(enabled, forKey: key)
        setNeedsUpdateProperties()
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        switch item {
        case .liveVoice:
            toggleRow(cell, title: String(localized: "Live Voice"), isOn: isOn(AppPreferences.Experiments.liveVoiceKey), identifier: "settings.experiments.liveVoice") { [weak self] in
                self?.set(AppPreferences.Experiments.liveVoiceKey, $0)
            }
        }
    }
}
