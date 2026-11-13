import Foundation
import Testing
import UIKit
@testable import Oppi

/// The Calendar Events experiment's reader and its switch: nothing is read while it is off,
/// access is asked for once, and only from the switch, refused access reads nothing and
/// says so, and hidden calendars stay out.
@MainActor
@Suite("Device calendar")
struct DeviceCalendarTests {
    /// The device's calendar as `DeviceCalendarStore` sees it, with an access answer to give.
    private final class Store: DeviceCalendarStore {
        var access: DeviceCalendarAccess
        let answer: DeviceCalendarAccess
        private(set) var requests = 0
        let events: [ScheduleCalendarEvent]

        init(access: DeviceCalendarAccess, answer: DeviceCalendarAccess = .granted) {
            self.access = access
            self.answer = answer
            let start = Date(timeIntervalSince1970: 1_794_592_800)
            events = [
                ScheduleCalendarEvent(id: "review", title: "Design review", start: start, end: start.addingTimeInterval(2_700), isAllDay: false, location: nil, notes: nil, calendarTitle: "Work"),
                ScheduleCalendarEvent(id: "lunch", title: "Lunch", start: start.addingTimeInterval(7_200), end: start.addingTimeInterval(10_800), isAllDay: false, location: nil, notes: nil, calendarTitle: "Home"),
            ]
        }

        func requestAccess() async -> Bool {
            requests += 1
            access = answer
            return answer == .granted
        }

        func calendars() -> [DeviceCalendarInfo] {
            [DeviceCalendarInfo(id: "work", title: "Work", account: "Exchange"), DeviceCalendarInfo(id: "home", title: "Home", account: "iCloud")]
        }

        func events(in interval: DateInterval, hiddenCalendarIds: Set<String>) -> [ScheduleCalendarEvent] {
            events.filter { !hiddenCalendarIds.contains($0.calendarTitle.lowercased()) }
        }
    }

    private static let week = DateInterval(start: Date(timeIntervalSince1970: 1_794_500_000), duration: 7 * 86_400)

    private static func settings() throws -> (SettingsStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "DeviceCalendarTests-\(UUID().uuidString)"))
        return (SettingsStore(serverId: nil, device: DeviceAdapter(defaults: defaults), server: ServerAdapter { _ in nil }), defaults)
    }

    @Test("nothing is read while the experiment is off; on, every calendar but the hidden ones")
    func readsOnlyWhileOn() async throws {
        let (settings, _) = try Self.settings()
        let calendar = DeviceCalendar(store: Store(access: .granted))
        #expect(calendar.events(in: Self.week, settings: settings).isEmpty)
        #expect(!calendar.isDenied(settings: settings))

        _ = await settings.set(SettingsCatalog.experimentCalendarEvents, true).value
        #expect(calendar.events(in: Self.week, settings: settings).map(\.id) == ["review", "lunch"])

        _ = await settings.set(SettingsCatalog.calendarEventsHiddenCalendars, ["home"]).value
        #expect(calendar.events(in: Self.week, settings: settings).map(\.id) == ["review"])
    }

    @Test("refused access reads nothing, says so, and is never asked again from the app")
    func deniedAccess() async throws {
        let (settings, _) = try Self.settings()
        _ = await settings.set(SettingsCatalog.experimentCalendarEvents, true).value
        let store = Store(access: .denied)
        let calendar = DeviceCalendar(store: store)
        #expect(calendar.isDenied(settings: settings))
        #expect(calendar.events(in: Self.week, settings: settings).isEmpty)
        #expect(calendar.calendars().isEmpty)
        await calendar.requestAccess()
        #expect(store.requests == 0, "Only Settings can give access back")
    }

    @Test("turning the switch on asks once; a refusal shows the way to Settings, a grant the calendar picker")
    func switchAsksForAccess() async throws {
        for (answer, row) in [(DeviceCalendarAccess.denied, SettingsExperimentsViewController.Item.calendarAccess), (.granted, .calendars)] {
            let defaults = try #require(UserDefaults(suiteName: "DeviceCalendarTests-page-\(UUID().uuidString)"))
            let store = Store(access: .notDetermined, answer: answer)
            let page = SettingsExperimentsViewController(defaults: defaults, deviceCalendar: DeviceCalendar(store: store))
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 1400)
            window.rootViewController = page
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            page.updatePropertiesIfNeeded()
            #expect(store.requests == 0, "Nothing asks while the experiment is off")
            #expect(!page.sections().flatMap(\.items).contains(row))

            let settings = try #require(page.settings)
            _ = await settings.set(SettingsCatalog.experimentCalendarEvents, true).value
            for _ in 0..<50 where store.requests == 0 || !page.sections().flatMap(\.items).contains(row) {
                page.updatePropertiesIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(store.requests == 1, "The switch asked once")
            #expect(page.sections().flatMap(\.items).contains(row), "\(answer) shows \(row)")
            page.updatePropertiesIfNeeded()
            #expect(store.requests == 1, "A later pass does not ask again")
        }
    }
}
