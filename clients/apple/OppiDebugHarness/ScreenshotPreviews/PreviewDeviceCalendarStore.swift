#if DEBUG
import Foundation

/// A week of this device's calendar for the Schedules screenshots, around the posed
/// morning: today's design review just before the 9:00 run, lunch, a 1:1 that overlaps a
/// planning block, a holiday tomorrow, and meetings across the rest of the week.
@MainActor
final class PreviewDeviceCalendarStore: DeviceCalendarStore {
    private(set) var access: DeviceCalendarAccess
    private let all: [ScheduleCalendarEvent]
    private static let calendars = [
        DeviceCalendarInfo(id: "work", title: "Work", account: "Exchange"),
        DeviceCalendarInfo(id: "home", title: "Home", account: "iCloud"),
        DeviceCalendarInfo(id: "family", title: "Family", account: "iCloud"),
    ]

    init(now: Date, access: DeviceCalendarAccess) {
        self.access = access
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        func at(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func event(
            _ id: String, _ title: String, _ start: Date, minutes: Int, location: String? = nil,
            notes: String? = nil, calendar: String = "Work"
        ) -> ScheduleCalendarEvent {
            ScheduleCalendarEvent(
                id: id, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                isAllDay: false, location: location, notes: notes, calendarTitle: calendar
            )
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        all = [
            event("standup-0", "Team standup", at(0, 8, 45), minutes: 15, location: "Zoom"),
            event(
                "design-review", "Design review: Schedules calendar", at(0, 10, 0), minutes: 45, location: "Zoom",
                notes: "Walk through Day, Week and Month with events. Bring the iPad mini captures."
            ),
            event("lunch", "Lunch with Sam", at(0, 12, 0), minutes: 60, location: "Cafe Ladro", calendar: "Home"),
            event("one-on-one", "1:1 with Alex", at(0, 14, 0), minutes: 30, location: "Room 4B"),
            event("planning", "Sprint planning", at(0, 14, 0), minutes: 90, location: "Zoom"),
            event("pickup", "School pickup", at(0, 16, 30), minutes: 30, calendar: "Family"),
            ScheduleCalendarEvent(
                id: "holiday", title: "Thanksgiving", start: tomorrow,
                end: calendar.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow,
                isAllDay: true, location: nil, notes: nil, calendarTitle: "Family"
            ),
            event("dentist", "Dentist", at(1, 9, 30), minutes: 60, location: "Downtown Dental", calendar: "Home"),
            event("standup-m1", "Team standup", at(-1, 8, 45), minutes: 15, location: "Zoom"),
            event("arch", "Architecture sync", at(-1, 11, 0), minutes: 60, location: "Zoom"),
            event("standup-m2", "Team standup", at(-2, 8, 45), minutes: 15, location: "Zoom"),
            event("demo", "Customer demo", at(-2, 15, 0), minutes: 60, location: "Zoom"),
            event("run", "Long run", at(2, 7, 0), minutes: 90, location: "Green Lake", calendar: "Home"),
            event("review-2", "Release review", at(2, 13, 0), minutes: 60, location: "Zoom"),
            event("standup-3", "Team standup", at(3, 8, 45), minutes: 15, location: "Zoom"),
            event("offsite", "Team offsite", at(3, 10, 0), minutes: 240, location: "Fremont Studio"),
        ]
    }

    func requestAccess() async -> Bool { access == .granted }

    func calendars() -> [DeviceCalendarInfo] { Self.calendars }

    func events(in interval: DateInterval, hiddenCalendarIds: Set<String>) -> [ScheduleCalendarEvent] {
        let hidden = Set(Self.calendars.filter { hiddenCalendarIds.contains($0.id) }.map(\.title))
        return all.filter { $0.start < interval.end && $0.end > interval.start && !hidden.contains($0.calendarTitle) }
    }
}
#endif
