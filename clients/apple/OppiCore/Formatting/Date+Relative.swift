import Foundation

extension Date {
    /// Relative time string: "just now", "2m ago", "1h ago", "3d ago".
    func relativeString(relativeTo now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(self))

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }

    /// `relativeString` up to a week, then a short calendar date ("Oct 15",
    /// or "Oct 15, 2025" in another year) instead of a count of days.
    func relativeOrShortDateString(relativeTo now: Date = Date(), calendar: Calendar = .current) -> String {
        guard now.timeIntervalSince(self) >= 7 * 86400 else { return relativeString(relativeTo: now) }
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone
        ).month(.abbreviated).day()
        if calendar.isDate(self, equalTo: now, toGranularity: .year) { return formatted(style) }
        return formatted(style.year())
    }
}
