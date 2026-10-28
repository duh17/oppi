import Foundation

/// What a schedule's Cadence, Run At, Repeat, Day, Time, Time Zone, and cron
/// controls edit, and the trigger Save sends. Cron validation matches the server's.
struct ScheduleTriggerDraft: Equatable {
    enum Cadence: String, CaseIterable, Equatable {
        case oneTime
        case interval
        case daily
        case weekly
        case custom

        var title: String {
            switch self {
            case .oneTime: "One Time"
            case .interval: "Interval"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .custom: "Custom"
            }
        }
    }

    var cadence: Cadence
    var oneTimeDate: Date
    var intervalMs: Int64
    var timeOfDay: Date
    var weekday: Int
    var timeZone: String
    var customExpression: String

    init(trigger: AgentScheduleTrigger, now: Date = Date()) {
        oneTimeDate = now
        intervalMs = 60 * 60_000
        timeOfDay = now
        weekday = 1
        timeZone = trigger.timeZone
        customExpression = ""

        switch trigger {
        case .at(let date, _):
            cadence = .oneTime
            oneTimeDate = date
        case .every(let intervalMs, _):
            cadence = .interval
            self.intervalMs = intervalMs
        case .cron(let expression, let timeZone):
            customExpression = expression
            if let parsed = Self.parseSimpleCron(expression) {
                cadence = parsed.weekday == nil ? .daily : .weekly
                weekday = parsed.weekday ?? 1
                timeOfDay = Self.dateForTime(
                    hour: parsed.hour,
                    minute: parsed.minute,
                    timeZone: timeZone,
                    fallback: now
                )
            } else {
                cadence = .custom
            }
        }
    }

    var customFieldLabels: String {
        hasSecondsField
            ? "second  minute  hour  day  month  weekday"
            : "minute  hour  day  month  weekday"
    }

    var customAccessibilityHint: String {
        hasSecondsField
            ? "Second, minute, hour, day, month, and weekday. Seconds must be zero."
            : "Minute, hour, day, month, and weekday"
    }

    var customGuidanceText: String {
        if hasSecondsField {
            return "Seconds must be 0. Example: 0 0 9 * * 1-5 runs weekdays at 9:00."
        }
        return "Example: 0 9 * * 1-5 runs weekdays at 9:00. */15 * * * * runs every 15 minutes."
    }

    private var hasSecondsField: Bool {
        customExpression.split(whereSeparator: { $0.isWhitespace }).count == 6
    }

    var customExpressionError: String? {
        guard cadence == .custom else { return nil }
        let fields = customExpression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 || fields.count == 6 else {
            return "Enter 5 fields, or 6 with seconds first."
        }
        // The server accepts six fields for parser compatibility but schedules at minute resolution.
        if fields.count == 6, fields[0] != "0" {
            return "Seconds must be 0 because schedules run at minute resolution."
        }
        let ranges = fields.count == 6
            ? [(0, 0), (0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]
            : [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]
        guard zip(fields, ranges).allSatisfy({
            Self.isValidCronField($0.0, range: $0.1)
        }) else {
            return "Use valid numbers, *, lists, ranges, or / steps for each field."
        }
        return nil
    }

    var canSave: Bool {
        cadence != .custom || customExpressionError == nil
    }

    func makeTrigger() -> AgentScheduleTrigger? {
        switch cadence {
        case .oneTime:
            return .at(oneTimeDate, timeZone: timeZone)
        case .interval:
            return .every(intervalMs: intervalMs, timeZone: timeZone)
        case .daily:
            let time = hourAndMinute()
            return .cron(expression: "\(time.minute) \(time.hour) * * *", timeZone: timeZone)
        case .weekly:
            let time = hourAndMinute()
            return .cron(
                expression: "\(time.minute) \(time.hour) * * \(weekday)",
                timeZone: timeZone
            )
        case .custom:
            guard customExpressionError == nil else { return nil }
            return .cron(
                expression: customExpression.trimmingCharacters(in: .whitespacesAndNewlines),
                timeZone: timeZone
            )
        }
    }

    static func weekdayTitle(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        let normalized = min(max(weekday, 0), 6)
        return symbols[normalized]
    }

    private func hourAndMinute() -> (hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let components = calendar.dateComponents([.hour, .minute], from: timeOfDay)
        return (components.hour ?? 0, components.minute ?? 0)
    }

    private static func parseSimpleCron(_ expression: String) -> (hour: Int, minute: Int, weekday: Int?)? {
        let fields = expression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5,
              let minute = Int(fields[0]), (0...59).contains(minute),
              let hour = Int(fields[1]), (0...23).contains(hour),
              fields[2] == "*", fields[3] == "*" else { return nil }
        if fields[4] == "*" {
            return (hour, minute, nil)
        }
        guard let weekday = Int(fields[4]), (0...7).contains(weekday) else { return nil }
        return (hour, minute, weekday == 7 ? 0 : weekday)
    }

    private static func isValidCronField(_ field: String, range: (Int, Int)) -> Bool {
        let segments = field.split(separator: ",", omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy { segment in
            let stepParts = segment.split(separator: "/", omittingEmptySubsequences: false)
            guard stepParts.count <= 2, let base = stepParts.first, !base.isEmpty else { return false }
            if stepParts.count == 2 {
                guard let step = parseUnsignedCronNumber(stepParts[1]), step > 0 else { return false }
            }
            if base == "*" { return true }

            let rangeParts = base.split(separator: "-", omittingEmptySubsequences: false)
            if rangeParts.count == 2,
               let lower = parseUnsignedCronNumber(rangeParts[0]),
               let upper = parseUnsignedCronNumber(rangeParts[1]) {
                return range.0 <= lower && lower <= upper && upper <= range.1
            }
            guard rangeParts.count == 1,
                  let value = parseUnsignedCronNumber(base) else { return false }
            return (range.0...range.1).contains(value)
        }
    }

    private static func parseUnsignedCronNumber(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(text)
    }

    private static func dateForTime(
        hour: Int,
        minute: Int,
        timeZone: String,
        fallback: Date
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        var components = calendar.dateComponents([.year, .month, .day], from: fallback)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? fallback
    }
}
