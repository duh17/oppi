import Foundation

/// Org metadata as reader badges: a heading's TODO state, priority and
/// progress cookie form one bar of connected segments, tags trail the title
/// as quiet capsules, and a planning line becomes a bar of dated segments.
///
/// Every badge carries a spoken label ("Next", "priority A", "1 of 3 done"),
/// so VoiceOver reads words rather than the symbols the badge shows.
enum OrgBadges {
    /// The moment and calendar dates are read against: overdue deadlines,
    /// whether a date needs its year, the locale dates are written in.
    struct Clock: Sendable {
        let now: Date
        let calendar: Calendar

        static var current: Self { Self(now: Date(), calendar: .autoupdatingCurrent) }
    }

    // MARK: - Heading

    /// Org has no "waiting" class, so states read as waiting by name.
    private static let waitingPrefixes = ["WAIT", "HOLD", "BLOCK", "DEFER", "PAUSE", "SOMEDAY", "DELEGATE"]
    /// Done states that mean dropped rather than finished, by name.
    private static let droppedPrefixes = ["CANCEL", "KILL", "ABANDON", "DROP", "WONTFIX"]

    /// The state segment of the heading on `line`; tapping it changes the state.
    static func state(_ keyword: String, isDone: Bool, line: Int? = nil) -> MarkdownBadge {
        let tone: MarkdownBadge.Tone
        if isDone {
            tone = droppedPrefixes.contains(where: keyword.hasPrefix) ? .muted : .success
        } else {
            tone = waitingPrefixes.contains(where: keyword.hasPrefix) ? .warning : .accent
        }
        return MarkdownBadge(
            text: keyword,
            label: keyword.lowercased().capitalized,
            tone: tone,
            control: line.map { ReaderTaskControl(kind: .state, line: $0) }
        )
    }

    /// The state control of a heading without a state, for a reader that can
    /// save its file. It draws nothing, so plain headings stay plain: the reader
    /// offers it from the heading's text menu and as a VoiceOver action.
    static func addState(line: Int) -> MarkdownBadge {
        MarkdownBadge(
            text: "",
            label: "",
            tone: .quiet,
            shape: .marker,
            control: ReaderTaskControl(kind: .state, line: line)
        )
    }

    static func priority(_ priority: String) -> MarkdownBadge {
        MarkdownBadge(text: "#\(priority)", label: "priority \(priority)", tone: .neutral)
    }

    /// `2/5` or `40%`; a complete cookie reads as finished.
    static func progress(_ cookie: String) -> MarkdownBadge {
        let parts = cookie.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]) {
            return MarkdownBadge(
                text: cookie,
                label: "\(done) of \(total) done",
                tone: total > 0 && done >= total ? .success : .neutral
            )
        }
        if cookie.hasSuffix("%"), let percent = Int(cookie.dropLast()) {
            return MarkdownBadge(
                text: cookie,
                label: "\(percent) percent done",
                tone: percent >= 100 ? .success : .neutral
            )
        }
        // `[/]` and `[%]` before Org has counted anything.
        return MarkdownBadge(text: cookie, label: "progress not counted yet", tone: .neutral)
    }

    static func tag(_ tag: String) -> MarkdownBadge {
        MarkdownBadge(text: tag, label: "tag \(tag)", tone: .quiet, shape: .capsule)
    }

    // MARK: - Planning

    /// A planning entry as a dated segment. A deadline still open after it
    /// passed warns.
    static func planning(
        _ entry: OrgPlanningEntry,
        headingIsDone: Bool,
        clock: Clock,
        headingLine: Int? = nil
    ) -> MarkdownBadge {
        // Scheduled and Deadline change under the heading; Closed is a record.
        let control = headingLine.flatMap { line in
            entry.kind == .closed ? nil : ReaderTaskControl(kind: .date(entry.kind), line: line)
        }
        guard let date = OrgDate(entry.timestamp.text, calendar: clock.calendar) else {
            return MarkdownBadge(
                text: entry.timestamp.text,
                label: "\(entry.kind.label) \(entry.timestamp.text)",
                tone: .neutral,
                symbol: symbol(for: entry.kind, overdue: false),
                control: control
            )
        }
        let overdue = entry.kind == .deadline && !headingIsDone && date.hasPassed(clock: clock)
        let tone: MarkdownBadge.Tone = switch entry.kind {
        case .scheduled: .neutral
        case .deadline: overdue ? .danger : .neutral
        case .closed: .quiet
        }
        var label = "\(entry.kind.label) \(date.spoken(clock: clock))"
        if overdue { label += ", overdue" }
        return MarkdownBadge(
            text: date.shown(clock: clock),
            label: label,
            tone: tone,
            symbol: symbol(for: entry.kind, overdue: overdue),
            control: control
        )
    }

    private static func symbol(for kind: OrgPlanningKind, overdue: Bool) -> String {
        switch kind {
        case .scheduled: "calendar"
        case .deadline: overdue ? "exclamationmark.triangle.fill" : "flag"
        case .closed: "checkmark"
        }
    }
}

/// The date, time and repeater of an Org timestamp's text
/// (`2026-11-13 Fri 17:00 +1w`).
private struct OrgDate {
    let date: Date
    let hasTime: Bool
    /// `+1w`, `.+1d`, `++1m`.
    let repeater: String?

    init?(_ text: String, calendar: Calendar) {
        let tokens = text.split(separator: " ")
        let day = tokens.first?.split(separator: "-").compactMap { Int($0) } ?? []
        guard day.count == 3 else { return nil }
        var components = DateComponents(year: day[0], month: day[1], day: day[2])
        var hasTime = false
        var repeater: String?
        for token in tokens.dropFirst() {
            if token.first == "+" || token.hasPrefix(".+") {
                repeater = String(token)
            } else if !hasTime, let colon = token.firstIndex(of: ":"),
                      let hour = Int(token[..<colon]),
                      let minute = Int(token[token.index(after: colon)...].prefix(2)) {
                components.hour = hour
                components.minute = minute
                hasTime = true
            }
        }
        guard let date = calendar.date(from: components) else { return nil }
        self.date = date
        self.hasTime = hasTime
        self.repeater = repeater
    }

    /// A date without a time lasts the whole day.
    func hasPassed(clock: OrgBadges.Clock) -> Bool {
        hasTime ? date < clock.now : date < clock.calendar.startOfDay(for: clock.now)
    }

    private func style(_ clock: OrgBadges.Clock) -> Date.FormatStyle {
        Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: clock.calendar.locale ?? .autoupdatingCurrent,
            calendar: clock.calendar,
            timeZone: clock.calendar.timeZone
        )
    }

    /// `Fri, Nov 13, 5:00 PM ↻1w`; the year only when it is not this year.
    func shown(clock: OrgBadges.Clock) -> String {
        var day = style(clock).weekday(.abbreviated).month(.abbreviated).day()
        if clock.calendar.component(.year, from: date) != clock.calendar.component(.year, from: clock.now) {
            day = day.year()
        }
        var text = date.formatted(day)
        if hasTime { text += ", " + date.formatted(style(clock).hour().minute()) }
        if let repeater { text += " ↻" + repeater.trimmingCharacters(in: CharacterSet(charactersIn: ".+")) }
        return text
    }

    /// `Friday, November 13, 2026 at 5:00 PM, repeats every 1 week`.
    func spoken(clock: OrgBadges.Clock) -> String {
        var text = date.formatted(style(clock).weekday(.wide).month(.wide).day().year())
        if hasTime { text += " at " + date.formatted(style(clock).hour().minute()) }
        if let repeater, let interval = Self.spokenInterval(repeater) { text += ", repeats every \(interval)" }
        return text
    }

    private static func spokenInterval(_ repeater: String) -> String? {
        let body = repeater.trimmingCharacters(in: CharacterSet(charactersIn: ".+"))
        guard let unit = body.last, let count = Int(body.dropLast()) else { return nil }
        let name: String
        switch unit {
        case "h": name = "hour"
        case "d": name = "day"
        case "w": name = "week"
        case "m": name = "month"
        case "y": name = "year"
        default: return nil
        }
        return "\(count) \(name)\(count == 1 ? "" : "s")"
    }
}
