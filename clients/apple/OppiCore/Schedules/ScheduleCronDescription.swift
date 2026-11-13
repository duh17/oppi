import Foundation

/// A cron trigger in words: which days ("Weekdays", "Mondays", "Monthly on the 1st") and
/// which times ("9:00 AM & 5:00 PM", "every 15 minutes").
///
/// It reads the expression the way the server's parser does (`server/src/agent-schedule-cron.ts`:
/// five numeric fields, or six with seconds first; `*`, `n`, `a-b`, `/step`, comma lists; 7 is
/// Sunday; both day fields restricted means either matches) only to describe it. When the next
/// run is due stays the server's answer (`GET /schedules/calendar`), so DST and edge syntax never
/// fork between the app and the runner.
struct ScheduleCronDescription: Equatable, Sendable {
    /// "Every day", "Weekdays", "Mon, Wed, Fri", "Monthly on the 1st", "Yearly on Jan 1".
    let days: String
    /// "9:00 AM & 5:00 PM", "every hour at :15", "every 15 minutes".
    let times: String
    /// It runs on at least five days of every week: a routine, not an occasion.
    let runsMostDays: Bool

    /// "Weekdays · 8:30 AM".
    var text: String { "\(days) · \(times)" }

    /// Nil for an expression the server would refuse.
    init?(expression: String, timeZone: TimeZone, locale: Locale = .current) {
        let raw = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        let fields = raw.count == 6 ? Array(raw.dropFirst()) : raw
        guard fields.count == 5,
              let minute = Field(fields[0], 0...59),
              let hour = Field(fields[1], 0...23),
              let dayOfMonth = Field(fields[2], 1...31),
              let month = Field(fields[3], 1...12),
              let dayOfWeek = Field(fields[4], 0...7, sevenIsZero: true) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        days = Self.days(dayOfMonth: dayOfMonth, month: month, dayOfWeek: dayOfWeek, calendar: calendar)
        times = Self.times(minute: minute, hour: hour, calendar: calendar)
        runsMostDays = dayOfMonth.values.count == 31 && month.values.count == 12 && dayOfWeek.values.count >= 5
    }

    /// One field's values, as the server's `parseCronField` reads them.
    private struct Field {
        let values: [Int]
        /// `*` or `*/n`: the server's wildcard, which decides how the two day fields combine.
        let isWildcard: Bool
        /// The `n` of a lone `*/n`.
        let step: Int?

        init?(_ text: String, _ bounds: ClosedRange<Int>, sevenIsZero: Bool = false) {
            var values = Set<Int>()
            var step: Int?
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            for part in parts {
                let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
                guard (1...2).contains(pieces.count) else { return nil }
                let every = pieces.count == 2 ? Int(pieces[1]) : 1
                guard let every, every > 0 else { return nil }
                let range: ClosedRange<Int>
                if pieces[0] == "*" {
                    range = bounds
                    if pieces.count == 2, parts.count == 1 { step = every }
                } else if pieces[0].contains("-") {
                    let ends = pieces[0].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
                    guard ends.count == 2, let low = ends[0], let high = ends[1],
                          bounds.contains(low), bounds.contains(high), low <= high else { return nil }
                    range = low...high
                } else {
                    guard let value = Int(pieces[0]), bounds.contains(value) else { return nil }
                    range = value...value
                }
                for value in stride(from: range.lowerBound, through: range.upperBound, by: every) {
                    values.insert(sevenIsZero && value == 7 ? 0 : value)
                }
            }
            guard !values.isEmpty else { return nil }
            self.values = values.sorted()
            isWildcard = text == "*" || text.hasPrefix("*/")
            self.step = step
        }
    }

    // MARK: - Days

    private static func days(dayOfMonth: Field, month: Field, dayOfWeek: Field, calendar: Calendar) -> String {
        let weekdays = weekdays(dayOfWeek, calendar: calendar)
        let allWeek = dayOfWeek.values.count == 7
        // Nil when the field allows every day of the month.
        let monthly = monthDays(dayOfMonth, calendar: calendar)
        let everyMonth = month.values.count == 12
        var text: String
        if !dayOfMonth.isWildcard, !dayOfWeek.isWildcard {
            // Both restricted: either day field may match.
            text = String(localized: "\(monthly ?? String(localized: "Every day")) or \(weekdays)")
        } else if let monthly, !allWeek {
            // Both must match: a stepped wildcard (`*/2`) still restricts its field.
            text = "\(monthly) · \(weekdays)"
        } else if let monthly {
            if month.values.count == 1, dayOfMonth.values.count == 1,
               let date = calendar.date(from: DateComponents(year: 2001, month: month.values[0], day: dayOfMonth.values[0])) {
                let formatter = DateFormatter()
                formatter.locale = calendar.locale
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.setLocalizedDateFormatFromTemplate("MMMd")
                return String(localized: "Yearly on \(formatter.string(from: date))")
            }
            text = monthly
        } else {
            text = weekdays
        }
        guard !everyMonth else { return text }
        let names = month.values.map { calendar.shortMonthSymbols[$0 - 1] }.formatted(.list(type: .and, width: .narrow))
        return String(localized: "\(text) in \(names)")
    }

    /// "Weekdays", "Weekends", "Mondays", "Mon, Wed, Fri"; "Every day" for all seven.
    private static func weekdays(_ field: Field, calendar: Calendar) -> String {
        let set = Set(field.values)
        switch set {
        case Set(0...6): return String(localized: "Every day")
        case Set(1...5): return String(localized: "Weekdays")
        case [0, 6]: return String(localized: "Weekends")
        default: break
        }
        if set.count == 1, let day = set.first {
            return String(localized: "\(calendar.standaloneWeekdaySymbols[day])s")
        }
        // In the locale's week order: Monday first where the week starts on Monday.
        let first = calendar.firstWeekday - 1
        let ordered = set.sorted { ($0 - first + 7) % 7 < ($1 - first + 7) % 7 }
        return ordered.map { calendar.shortWeekdaySymbols[$0] }.formatted(.list(type: .and, width: .narrow))
    }

    /// "Monthly on the 1st", "Monthly on the 1st & 15th", "Every other day"; nil for every day.
    private static func monthDays(_ field: Field, calendar: Calendar) -> String? {
        guard field.values.count < 31 else { return nil }
        if let step = field.step, step > 1, field.values.count > 4 {
            return step == 2 ? String(localized: "Every other day") : String(localized: "Every \(step) days")
        }
        let ordinal = NumberFormatter()
        ordinal.locale = calendar.locale
        ordinal.numberStyle = .ordinal
        let days = field.values.map { ordinal.string(from: NSNumber(value: $0)) ?? "\($0)" }
        return String(localized: "Monthly on the \(joined(days))")
    }

    // MARK: - Times

    private static func times(minute: Field, hour: Field, calendar: Calendar) -> String {
        let minutes = minute.values
        let hours = hour.values
        if minutes.count == 60 {
            return hours.count == 24
                ? String(localized: "every minute")
                : String(localized: "every minute, \(hourSpan(hours, calendar: calendar))")
        }
        if minutes.count * hours.count <= 4 {
            let instants = hours.flatMap { hour in minutes.map { (hour, $0) } }
            return joined(instants.map { time(hour: $0.0, minute: $0.1, calendar: calendar) })
        }
        if minutes.count > 1 {
            let every = minute.step.map { String(localized: "every \($0) minutes") }
                ?? String(localized: "\(minutes.count) times an hour")
            return hours.count == 24 ? every : "\(every), \(hourSpan(hours, calendar: calendar))"
        }
        let at = String(format: ":%02d", minutes[0])
        if hours.count == 24 { return String(localized: "every hour at \(at)") }
        if let step = arithmeticStep(hours), step > 1 {
            return String(localized: "every \(step) hours, \(hourSpan(hours, minute: minutes[0], calendar: calendar))")
        }
        if arithmeticStep(hours) == 1 {
            return String(localized: "every hour, \(hourSpan(hours, minute: minutes[0], calendar: calendar))")
        }
        return String(localized: "\(hours.count) times a day")
    }

    /// The common difference of `values`, when they step evenly.
    private static func arithmeticStep(_ values: [Int]) -> Int? {
        guard values.count > 1 else { return nil }
        let step = values[1] - values[0]
        return zip(values, values.dropFirst()).allSatisfy { $1 - $0 == step } ? step : nil
    }

    /// "9:00 AM – 5:00 PM", from the first hour to the last.
    private static func hourSpan(_ hours: [Int], minute: Int = 0, calendar: Calendar) -> String {
        guard let first = hours.first, let last = hours.last else { return "" }
        return "\(time(hour: first, minute: minute, calendar: calendar)) – \(time(hour: last, minute: minute, calendar: calendar))"
    }

    /// "9:00 AM" in the locale's clock.
    private static func time(hour: Int, minute: Int, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        guard let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)) else {
            return String(format: "%d:%02d", hour, minute)
        }
        return formatter.string(from: date)
    }

    /// "a", "a & b", "a, b & c".
    private static func joined(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return "\(items.dropLast().joined(separator: ", ")) & \(last)"
    }
}
