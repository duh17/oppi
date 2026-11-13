import EventKit
import UIKit

/// Whether Oppi may read this device's events. Write-only access reads nothing, so it is
/// `denied` here, as are a restricted device and a refusal.
enum DeviceCalendarAccess: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

/// One of this device's event calendars, for the picker of which ones Schedules shows.
struct DeviceCalendarInfo: Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    /// The account it belongs to: "iCloud", an Exchange address, "On My iPhone".
    let account: String
}

/// Where the device's events come from. `EventKitCalendarStore` is the device's own; a
/// screenshot preview supplies a fixed week of events through the same protocol.
@MainActor
protocol DeviceCalendarStore: AnyObject {
    var access: DeviceCalendarAccess { get }
    /// Asks the person for full access to events; true when it was given.
    func requestAccess() async -> Bool
    func calendars() -> [DeviceCalendarInfo]
    /// Events overlapping `interval` in every calendar but the hidden ones, without
    /// cancelled events and the ones this person declined.
    func events(in interval: DateInterval, hiddenCalendarIds: Set<String>) -> [ScheduleCalendarEvent]
}

/// The Calendar Events experiment's reader: this device's events for the Schedules
/// calendar, and only while the experiment is on (`SettingsCatalog.experimentCalendarEvents`)
/// and the person gave access. Access is asked for only when the person turns the
/// experiment on (Settings → Experiments), never at launch.
///
/// Nothing here is synced or sent: events are read when a calendar view draws.
/// `generation` moves when the calendar changes outside the app (EventKit's change
/// notification), so the views that read events redraw.
@MainActor @Observable
final class DeviceCalendar {
    private(set) var access: DeviceCalendarAccess
    /// Bumped when the device's calendars or events change.
    private(set) var generation = 0

    @ObservationIgnored private let store: any DeviceCalendarStore
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(store: any DeviceCalendarStore = EventKitCalendarStore()) {
        self.store = store
        access = store.access
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        })
        // Access changes in the system Settings app, while Oppi is in the background.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The system's question, once: an answer already given is changed only in Settings.
    func requestAccess() async {
        guard access == .notDetermined else { return }
        _ = await store.requestAccess()
        refreshAccess()
        generation += 1
    }

    private func refreshAccess() {
        let current = store.access
        if current != access { access = current }
    }

    private func storeChanged() {
        refreshAccess()
        generation += 1
    }

    /// Whether the experiment is on: the views read events, and Settings shows its rows.
    static func isEnabled(_ settings: SettingsStore) -> Bool {
        settings.read(SettingsCatalog.experimentCalendarEvents).current == true
    }

    /// The device's event calendars, once access is given.
    func calendars() -> [DeviceCalendarInfo] {
        _ = generation
        guard access == .granted else { return [] }
        return store.calendars()
    }

    /// The events Schedules shows in `interval`: none while the experiment is off or access
    /// is not given, else every calendar's but the ones the person hid.
    func events(in interval: DateInterval, settings: SettingsStore) -> [ScheduleCalendarEvent] {
        // Every observed value is read before any return.
        _ = generation
        let enabled = Self.isEnabled(settings)
        let hidden = Set(settings.read(SettingsCatalog.calendarEventsHiddenCalendars).current ?? [])
        guard enabled, access == .granted else { return [] }
        return store.events(in: interval, hiddenCalendarIds: hidden)
    }

    /// The experiment is on but the calendar cannot be read: the views say so.
    func isDenied(settings: SettingsStore) -> Bool {
        let enabled = Self.isEnabled(settings)
        return enabled && access == .denied
    }

    /// The system Settings page for Oppi, where calendar access is given back.
    static func openSystemSettings(_ opener: AppOpener) {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        opener.open(.system(url))
    }
}

/// This device's calendars through EventKit. The event store is made on first use, so a
/// root that never shows events never opens one.
@MainActor
final class EventKitCalendarStore: DeviceCalendarStore {
    private lazy var store = EKEventStore()

    var access: DeviceCalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func calendars() -> [DeviceCalendarInfo] {
        store.calendars(for: .event).map {
            DeviceCalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "")
        }
    }

    func events(in interval: DateInterval, hiddenCalendarIds: Set<String>) -> [ScheduleCalendarEvent] {
        let calendars = store.calendars(for: .event).filter { !hiddenCalendarIds.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        return store.events(matching: predicate).compactMap { event in
            guard event.status != .canceled,
                  event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined,
                  let start = event.startDate, let end = event.endDate else { return nil }
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ScheduleCalendarEvent(
                id: "\(event.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))",
                title: title.isEmpty ? String(localized: "New Event") : title,
                start: start,
                end: end,
                isAllDay: event.isAllDay,
                location: event.location?.managementNilIfBlank,
                notes: event.notes?.managementNilIfBlank,
                calendarTitle: event.calendar?.title ?? ""
            )
        }
    }
}
