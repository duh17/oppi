import UIKit

/// Settings > Experiments: opt-in features, each off by default and saved on
/// this device. Rex and Herdr are declared in `SettingsCatalog`
/// (`experimentRex`, `experimentHerdr`) and read and written through the app's
/// device `SettingsStore`, so a switch saves as it flips and the feature follows
/// without a relaunch. Live Voice still writes its own default key here, as it
/// did before the settings kit; it is the one row this page writes itself.
final class SettingsExperimentsViewController: ListScreenController<SettingsExperimentsViewController.Section, SettingsExperimentsViewController.Item> {
    enum Section: Hashable, Sendable { case liveVoice, rex, herdr }
    enum Item: Hashable, Sendable {
        case liveVoice, rex, herdr
        /// The failure line under the declared setting with this id.
        case failure(String)
    }

    /// Live Voice's own key, for the switch this page still writes directly.
    private let defaults: UserDefaults

    init(root: AppRootEnvironment) {
        self.defaults = .standard
        super.init(
            title: String(localized: "Experiments"),
            listIdentifier: "settings.experiments.list",
            scope: .device,
            settings: root.settings,
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    /// The page over its own defaults: a test's store, with no live settings store.
    convenience init(defaults: UserDefaults) {
        self.init(settings: SettingsStore(serverId: nil, device: DeviceAdapter(defaults: defaults), server: ServerAdapter { _ in nil }), defaults: defaults)
    }

    private init(settings: SettingsStore, defaults: UserDefaults) {
        self.defaults = defaults
        super.init(
            title: String(localized: "Experiments"),
            listIdentifier: "settings.experiments.list",
            scope: .device,
            settings: settings,
            footers: true
        )
    }

    /// How many experiments are currently on, for the root row summary.
    @MainActor
    static func enabledCount() -> Int {
        [
            AppPreferences.Experiments.liveVoiceEnabled,
            AppPreferenceStore.Experiments.rexEnabled,
            AppPreferenceStore.Experiments.herdrEnabled,
        ].count { $0 }
    }

    override func sections() -> [ListSection<Section, Item>] {
        let rex = SettingsCatalog.experimentRex
        let herdr = SettingsCatalog.experimentHerdr
        return [
            ListSection(
                .liveVoice,
                footer: String(localized: "Adds Live Voice to the composer's mic menu and Quick Session, to talk to a session hands-free. Needs a server with a voice backend."),
                items: [.liveVoice]
            ),
            ListSection(
                .rex,
                footer: rex.copy.footer,
                items: settingRows(rex, .rex) { .failure($0) }
            ),
            ListSection(
                .herdr,
                footer: herdr.copy.footer,
                items: settingRows(herdr, .herdr) { .failure($0) }
            ),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .liveVoice: AnyHashable(isOn(AppPreferences.Experiments.liveVoiceKey))
        case .rex: settingInputs(SettingsCatalog.experimentRex)
        case .herdr: settingInputs(SettingsCatalog.experimentHerdr)
        case .failure(let id): settingFailureInputs(id)
        }
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .liveVoice, .rex, .herdr: super.dequeue(item, at: indexPath)
        case .failure(let id): dequeueSettingFailure(id, at: indexPath)
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
        case .rex:
            settingToggleRow(cell, SettingsCatalog.experimentRex)
        case .herdr:
            settingToggleRow(cell, SettingsCatalog.experimentHerdr)
        case .liveVoice:
            toggleRow(cell, title: String(localized: "Live Voice"), isOn: isOn(AppPreferences.Experiments.liveVoiceKey), identifier: "settings.experiments.liveVoice") { [weak self] in
                self?.set(AppPreferences.Experiments.liveVoiceKey, $0)
            }
        case .failure:
            break
        }
    }
}
