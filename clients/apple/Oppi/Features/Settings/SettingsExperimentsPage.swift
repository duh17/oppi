import UIKit

/// Settings > Experiments: opt-in features, each off by default and saved on
/// this device. Rex, Herdr, and Calendar Events are declared in `SettingsCatalog`
/// (`experimentRex`, `experimentHerdr`, `experimentCalendarEvents`) and read and
/// written through the app's device `SettingsStore`, so a switch saves as it flips
/// and the feature follows without a relaunch. Live Voice still writes its own
/// default key here, as it did before the settings kit; it is the one row this page
/// writes itself.
///
/// Calendar Events asks for calendar access once it is on and nobody has answered
/// yet, while this page is on screen: the switch is the only place that asks. With
/// access, its section offers Calendars (which ones Schedules shows); refused, it
/// offers the system Settings page where access is given back.
final class SettingsExperimentsViewController: ListScreenController<SettingsExperimentsViewController.Section, SettingsExperimentsViewController.Item> {
    enum Section: Hashable, Sendable { case liveVoice, rex, herdr, calendarEvents }
    enum Item: Hashable, Sendable {
        case liveVoice, rex, herdr, calendarEvents
        /// Which calendars Schedules shows; with access only.
        case calendars
        /// Access was refused: opens Oppi's page in the system Settings.
        case calendarAccess
        /// The failure line under the declared setting with this id.
        case failure(String)
    }

    /// Live Voice's own key, for the switch this page still writes directly.
    private let defaults: UserDefaults
    private let deviceCalendar: DeviceCalendar
    /// Set when this page asked for calendar access, so it asks once.
    private var askedCalendarAccess = false

    init(root: AppRootEnvironment) {
        self.defaults = .standard
        deviceCalendar = root.deviceCalendar
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
    convenience init(defaults: UserDefaults, deviceCalendar: DeviceCalendar = DeviceCalendar()) {
        self.init(
            settings: SettingsStore(serverId: nil, device: DeviceAdapter(defaults: defaults), server: ServerAdapter { _ in nil }),
            defaults: defaults,
            deviceCalendar: deviceCalendar
        )
    }

    private init(settings: SettingsStore, defaults: UserDefaults, deviceCalendar: DeviceCalendar) {
        self.defaults = defaults
        self.deviceCalendar = deviceCalendar
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
            AppPreferenceStore.Experiments.calendarEventsEnabled,
        ].count { $0 }
    }

    override func updateProperties() {
        super.updateProperties()
        // The switch just turned on, with no answer yet: the system asks now.
        guard let settings, DeviceCalendar.isEnabled(settings), deviceCalendar.access == .notDetermined,
              !askedCalendarAccess else { return }
        askedCalendarAccess = true
        Task { [deviceCalendar] in await deviceCalendar.requestAccess() }
    }

    override func sections() -> [ListSection<Section, Item>] {
        let rex = SettingsCatalog.experimentRex
        let herdr = SettingsCatalog.experimentHerdr
        let calendarEvents = SettingsCatalog.experimentCalendarEvents
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
            ListSection(
                .calendarEvents,
                footer: calendarFooter,
                items: settingRows(calendarEvents, .calendarEvents) { .failure($0) } + calendarRows
            ),
        ]
    }

    /// Calendars with access; the way back to access when it was refused.
    private var calendarRows: [Item] {
        guard let settings, DeviceCalendar.isEnabled(settings) else { return [] }
        switch deviceCalendar.access {
        case .granted: return [.calendars]
        case .denied: return [.calendarAccess]
        case .notDetermined: return []
        }
    }

    private var calendarFooter: String? {
        let footer = SettingsCatalog.experimentCalendarEvents.copy.footer
        guard calendarRows == [.calendarAccess] else { return footer }
        return String(localized: "Oppi can't read your calendar. Allow Full Access to calendars for Oppi in Settings to show its events in Schedules.")
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .liveVoice: AnyHashable(isOn(AppPreferences.Experiments.liveVoiceKey))
        case .rex: settingInputs(SettingsCatalog.experimentRex)
        case .herdr: settingInputs(SettingsCatalog.experimentHerdr)
        case .calendarEvents: settingInputs(SettingsCatalog.experimentCalendarEvents)
        case .calendars: AnyHashable([
            settingInputs(SettingsCatalog.calendarEventsHiddenCalendars), AnyHashable(deviceCalendar.calendars().map(\.id)),
        ])
        case .calendarAccess: AnyHashable(0)
        case .failure(let id): settingFailureInputs(id)
        }
    }

    private lazy var calendarsRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            title: SettingsCatalog.calendarEventsHiddenCalendars.copy.title,
            image: .symbol("calendar"),
            value: calendarsSummary,
            identifier: SettingsCatalog.calendarEventsHiddenCalendars.id
        ) { [weak self] in
            guard let self, let settings else { return }
            Router.push(SettingsCalendarsViewController(settings: settings, deviceCalendar: deviceCalendar), from: self)
        }
    }

    private lazy var calendarAccessRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, _ in
        cell.configure(
            title: String(localized: "Allow Calendar Access"),
            systemImage: "gear",
            identifier: "settings.experiments.calendarEvents.access",
            hint: String(localized: "Opens Oppi in Settings")
        ) { [weak self] in
            guard let self, let opener = AppRootEnvironment.near(self)?.opener else { return }
            DeviceCalendar.openSystemSettings(opener)
        }
    }

    /// "All", or "3 of 5".
    private var calendarsSummary: String {
        let all = deviceCalendar.calendars()
        let hidden = Set(settings?.read(SettingsCatalog.calendarEventsHiddenCalendars).current ?? [])
        let shown = all.count { !hidden.contains($0.id) }
        return shown == all.count ? String(localized: "All") : String(localized: "\(shown) of \(all.count)")
    }

    override func prepareRegistrations() {
        _ = (calendarsRow, calendarAccessRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .liveVoice, .rex, .herdr, .calendarEvents: super.dequeue(item, at: indexPath)
        case .calendars: collectionView.dequeueConfiguredReusableCell(using: calendarsRow, for: indexPath, item: item)
        case .calendarAccess: collectionView.dequeueConfiguredReusableCell(using: calendarAccessRow, for: indexPath, item: item)
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
        case .calendarEvents:
            settingToggleRow(cell, SettingsCatalog.experimentCalendarEvents)
        case .liveVoice:
            toggleRow(cell, title: String(localized: "Live Voice"), isOn: isOn(AppPreferences.Experiments.liveVoiceKey), identifier: "settings.experiments.liveVoice") { [weak self] in
                self?.set(AppPreferences.Experiments.liveVoiceKey, $0)
            }
        case .calendars, .calendarAccess, .failure:
            break
        }
    }
}

/// Settings > Experiments > Calendars: this device's event calendars by account, each
/// checked while Schedules shows its events. Saved on this device as the hidden ones
/// (`SettingsCatalog.calendarEventsHiddenCalendars`), so a calendar added later shows.
final class SettingsCalendarsViewController: ListScreenController<String, String> {
    private let deviceCalendar: DeviceCalendar

    private lazy var calendarRow = UICollectionView.CellRegistration<SettingsSelectionRowCell, String> { [weak self] cell, _, id in
        guard let self, let calendar = deviceCalendar.calendars().first(where: { $0.id == id }) else { return }
        let shown = !hidden.contains(id)
        cell.configure(
            title: calendar.title,
            mark: .trailingCheck,
            isChosen: shown,
            identifier: "settings.experiments.calendarEvents.calendar.\(id)"
        ) { [weak self] in self?.toggle(id) }
    }

    init(settings: SettingsStore, deviceCalendar: DeviceCalendar) {
        self.deviceCalendar = deviceCalendar
        super.init(
            title: String(localized: "Calendars"),
            listIdentifier: "settings.experiments.calendars.list",
            scope: .device,
            settings: settings,
            headers: true
        )
    }

    private var hidden: Set<String> {
        Set(settings?.read(SettingsCatalog.calendarEventsHiddenCalendars).current ?? [])
    }

    /// One section per account, in the order EventKit lists them, calendars by title.
    override func sections() -> [ListSection<String, String>] {
        var accounts: [String] = []
        var calendars: [String: [DeviceCalendarInfo]] = [:]
        for calendar in deviceCalendar.calendars() {
            if calendars[calendar.account] == nil { accounts.append(calendar.account) }
            calendars[calendar.account, default: []].append(calendar)
        }
        return accounts.map { account in
            ListSection(
                account,
                header: account,
                items: (calendars[account] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(\.id)
            )
        }
    }

    override func inputs(of item: String) -> AnyHashable {
        AnyHashable([AnyHashable(hidden.contains(item)), AnyHashable(deviceCalendar.calendars().first { $0.id == item }?.title)])
    }

    override func prepareRegistrations() {
        _ = calendarRow
    }

    override func dequeue(_ item: String, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: calendarRow, for: indexPath, item: item)
    }

    private func toggle(_ id: String) {
        var hidden = hidden
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
        settings?.set(SettingsCatalog.calendarEventsHiddenCalendars, hidden.sorted())
    }
}
