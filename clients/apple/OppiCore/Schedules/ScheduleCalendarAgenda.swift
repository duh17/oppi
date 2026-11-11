import Foundation

/// A calendar entry's state, from the server's facts about its run and session.
///
/// Blocked kinds reuse `SessionStatusKind`, so the calendar and session rows never
/// disagree. Unlike a session row, the calendar shows an outcome whether or not this
/// device has seen it: a calendar is history.
enum ScheduleCalendarOutcome: Hashable, Sendable {
    /// A future occurrence of an active schedule.
    case upcoming
    /// The run exists but its session has not started yet.
    case starting
    /// The run failed to dispatch: no session ran.
    case didNotStart
    case running
    /// Blocked on the person: `.needsApproval`, `.question`, or `.signIn`.
    case needsYou(SessionStatusKind)
    case failed
    case done
    /// A prompt delivered into an existing session that is not working on it now.
    case sent

    var label: String {
        switch self {
        case .upcoming: String(localized: "Upcoming")
        case .starting: String(localized: "Starting")
        case .didNotStart: String(localized: "Didn't start")
        case .running: String(localized: "Running")
        case .needsYou: String(localized: "Needs you")
        case .failed: String(localized: "Failed")
        case .done: String(localized: "Done")
        case .sent: String(localized: "Sent")
        }
    }

    /// Spoken: a blocked run says what it waits on ("Question").
    var spokenLabel: String {
        if case .needsYou(let kind) = self { return "\(label), \(kind.label)" }
        return label
    }

    /// Settled and fine: folds into a night cluster or a quiet one-line row.
    var isClean: Bool { self == .done || self == .sent }

    var isFailure: Bool { self == .failed || self == .didNotStart }

    var isNeedsYou: Bool {
        if case .needsYou = self { return true }
        return false
    }

    var isActive: Bool { self == .running || self == .starting }

    /// The run is over or in progress: it has a session to open, or a reason it has none.
    var isPast: Bool { self != .upcoming }

    /// What one live session says about a run, for a new-session run or an existing one.
    static func resolve(
        run: ScheduleCalendarRun?,
        session: ScheduleCalendarAgenda.SessionFacts?,
        sendsIntoExistingSession: Bool
    ) -> ScheduleCalendarOutcome {
        guard let run else { return .upcoming }
        if run.status == .failed { return .didNotStart }
        guard let session else {
            switch run.status {
            case .pending, .claimed, .running: return .starting
            case .completed, .failed: return sendsIntoExistingSession ? .sent : .done
            }
        }
        let kind: SessionStatusKind? = session.programStatus.flatMap {
            // Unseen on purpose: done and error stay what they were.
            SessionStatusKind.resolve(programStatus: $0, isStopped: session.status == .stopped, seenAt: nil)
        }
        switch kind {
        case .working:
            return .running
        case .needsApproval, .question, .signIn:
            return .needsYou(kind ?? .question)
        case .error:
            return sendsIntoExistingSession ? .sent : .failed
        case .done, .idle, .stopped:
            return sendsIntoExistingSession ? .sent : .done
        case nil:
            switch session.status {
            case .starting, .busy: return .running
            case .error: return sendsIntoExistingSession ? .sent : .failed
            case .ready, .stopping, .stopped: return sendsIntoExistingSession ? .sent : .done
            }
        }
    }
}

/// One day of the calendar: the night band, the day's rows, and the "now" line, built
/// from the server's answer for a range. Pure, so every width and the Mac share it.
struct ScheduleCalendarAgenda: Sendable {
    /// What a session says now. The server's answer, or the app's live copy of it.
    struct SessionFacts: Equatable, Sendable {
        var status: SessionStatus
        var programStatus: ProgramStatus?
        var cost: Double
    }

    /// One run or upcoming occurrence, ready to draw.
    struct Item: Hashable, Sendable, Identifiable {
        /// `<scheduleId>.<slotKey>`: unique within one answer.
        let id: String
        let scheduleId: String
        let slotKey: String
        let at: Date
        let name: String
        let outcome: ScheduleCalendarOutcome
        let runId: String?
        let runKind: AgentScheduleRunKind?
        let sessionId: String?
        let workspaceId: String
        let model: String?
        /// The session's cost, nil before a session exists.
        let cost: Double?
        /// When the run's work began: the run's start, else its creation.
        let startedAt: Date?
        /// When the session last settled.
        let settledAt: Date?
        /// The dispatch error of a run that never started.
        let runError: String?
        /// The session's one line for a failed run (its error) or a blocked one (what it
        /// asks). Never a prompt or model output (`ProgramStatus.message`).
        let sessionMessage: String?
        let trigger: AgentScheduleTrigger
        let sendsIntoExistingSession: Bool

        /// How long the run took, for a settled one; how long it has run, for a running one.
        func duration(now: Date) -> TimeInterval? {
            guard let startedAt else { return nil }
            switch outcome {
            case .running, .starting: return max(0, now.timeIntervalSince(startedAt))
            case .done, .failed, .sent:
                return settledAt.map { max(0, $0.timeIntervalSince(startedAt)) }
            case .needsYou, .didNotStart, .upcoming: return nil
            }
        }
    }

    /// Clean night runs folded into one row; expands in place.
    struct Cluster: Hashable, Sendable, Identifiable {
        /// `cluster.<day>`.
        let id: String
        let items: [Item]
        /// A future night's occurrences rather than finished runs.
        let isUpcoming: Bool
        let isExpanded: Bool
        var totalCost: Double { items.compactMap(\.cost).reduce(0, +) }
    }

    enum Row: Hashable, Sendable {
        case entry(Item)
        case cluster(Cluster)
        /// The current time, on today only. Not an accessibility element.
        case now(Date)
    }

    struct Summary: Hashable, Sendable {
        var done = 0
        var running = 0
        var failed = 0
        var needsYou = 0
        var upcoming = 0
        var cost: Double = 0
        var isEmpty: Bool { done + running + failed + needsYou + upcoming == 0 }
    }

    /// One day's mark in the week strip.
    struct DayHealth: Hashable, Sendable {
        var hasFailure = false
        var needsYou = false
        /// Something ran that day.
        var ran = false
        /// Something is still to run that day.
        var hasUpcoming = false
    }

    /// The night band: midnight to 6 AM.
    static let nightBandEndHour = 6

    let items: [Item]
    let schedules: [String: ScheduleCalendarSchedule]

    /// `live` patches the sessions the app follows (running and blocked changes arrive there
    /// before the next fetch).
    init(response: ScheduleCalendarResponse, live: [String: SessionFacts] = [:]) {
        let schedules = Dictionary(response.schedules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.schedules = schedules
        var seen = Set<String>()
        items = response.entries.compactMap { entry in
            guard let schedule = schedules[entry.scheduleId], seen.insert(entry.key).inserted else { return nil }
            let run = entry.run
            let served = run?.session.map {
                SessionFacts(status: $0.status, programStatus: $0.programStatus, cost: $0.cost)
            }
            let session = run?.session.flatMap { live[$0.id] } ?? served
            let existing = schedule.action.type == .existingSession
            let outcome = ScheduleCalendarOutcome.resolve(run: run, session: session, sendsIntoExistingSession: existing)
            return Item(
                id: entry.key,
                scheduleId: entry.scheduleId,
                slotKey: entry.slotKey,
                at: entry.at,
                name: schedule.name,
                outcome: outcome,
                runId: run?.id,
                runKind: run?.kind,
                sessionId: run?.session?.id,
                workspaceId: run?.session?.workspaceId ?? schedule.action.workspaceId,
                model: run?.session?.model ?? schedule.model,
                cost: session?.cost,
                startedAt: run.map { $0.startedAt ?? $0.createdAt },
                settledAt: run?.session?.settledAt,
                runError: run?.status == .failed ? run?.error : nil,
                sessionMessage: Self.message(session: session, outcome: outcome),
                trigger: schedule.trigger,
                sendsIntoExistingSession: existing
            )
        }.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
    }

    /// What the session says, for the outcomes that show it: failed and needs you.
    private static func message(session: SessionFacts?, outcome: ScheduleCalendarOutcome) -> String? {
        guard outcome == .failed || outcome.isNeedsYou,
              let message = session?.programStatus?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return nil }
        return message
    }

    /// The items whose time falls on `day`'s calendar day.
    func items(on day: Date, calendar: Calendar) -> [Item] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return items.filter { $0.at >= start && $0.at < end }
    }

    /// `day`'s rows: the night band (clean runs folded into one cluster when there are
    /// two or more), then the rest by time, with the now line on today.
    func rows(
        on day: Date,
        now: Date,
        calendar: Calendar,
        expandedClusters: Set<String> = []
    ) -> (night: [Row], day: [Row]) {
        let start = calendar.startOfDay(for: day)
        let bandEnd = calendar.date(bySettingHour: Self.nightBandEndHour, minute: 0, second: 0, of: start) ?? start
        let dayItems = items(on: day, calendar: calendar)
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isFuture = start > now
        let nightItems = dayItems.filter { $0.at < bandEnd }
        let later = dayItems.filter { $0.at >= bandEnd }

        // Clean runs fold; on a future night every occurrence does. Problems, running,
        // and starting runs always break out at their time.
        let folds: (Item) -> Bool = { isFuture ? $0.outcome == .upcoming : $0.outcome.isClean }
        let folded = nightItems.filter(folds)
        var night: [Row]
        if folded.count >= 2, let first = folded.first {
            let id = "cluster.\(Self.dayKey(day, calendar: calendar))"
            let expanded = expandedClusters.contains(id)
            let cluster = Cluster(id: id, items: folded, isUpcoming: isFuture, isExpanded: expanded)
            // The cluster sits at its first run's time; expanded, its runs follow it as one
            // group, and the runs that broke out keep their places before or after it.
            let rest = nightItems.filter { !folds($0) }
            night = rest.filter { $0.at < first.at }.map { Row.entry($0) }
                + [.cluster(cluster)]
                + (expanded ? folded.map { Row.entry($0) } : [])
                + rest.filter { $0.at >= first.at }.map { Row.entry($0) }
        } else {
            night = nightItems.map { .entry($0) }
        }
        var dayRows = later.map { Row.entry($0) }

        if isToday {
            if now < bandEnd {
                night = Self.inserting(now: now, into: night)
            } else {
                dayRows = Self.inserting(now: now, into: dayRows)
            }
        }
        return (night, dayRows)
    }

    /// The now line goes before the first row that is still to come.
    private static func inserting(now: Date, into rows: [Row]) -> [Row] {
        var rows = rows
        let index = rows.firstIndex { row in
            switch row {
            case .entry(let item): item.at > now
            case .cluster(let cluster): (cluster.items.first?.at ?? .distantPast) > now
            case .now: false
            }
        } ?? rows.endIndex
        rows.insert(.now(now), at: index)
        return rows
    }

    /// `day`'s counts and spend. A session that several runs sent into counts its cost once.
    func summary(on day: Date, calendar: Calendar) -> Summary {
        var summary = Summary()
        var costedSessions = Set<String>()
        for item in items(on: day, calendar: calendar) {
            switch item.outcome {
            case .upcoming: summary.upcoming += 1
            case .running, .starting: summary.running += 1
            case .failed, .didNotStart: summary.failed += 1
            case .needsYou: summary.needsYou += 1
            case .done, .sent: summary.done += 1
            }
            if let cost = item.cost, let sessionId = item.sessionId, costedSessions.insert(sessionId).inserted {
                summary.cost += cost
            }
        }
        return summary
    }

    func health(on day: Date, calendar: Calendar) -> DayHealth {
        var health = DayHealth()
        for item in items(on: day, calendar: calendar) {
            health.hasFailure = health.hasFailure || item.outcome.isFailure
            health.needsYou = health.needsYou || item.outcome.isNeedsYou
            health.ran = health.ran || item.outcome.isPast
            health.hasUpcoming = health.hasUpcoming || item.outcome == .upcoming
        }
        return health
    }

    /// The schedule's latest outcomes before `now`, oldest first: the menu preview's row.
    func recentOutcomes(of scheduleId: String, before now: Date, limit: Int = 7) -> [ScheduleCalendarOutcome] {
        Array(items.filter { $0.scheduleId == scheduleId && $0.outcome.isPast && $0.at <= now }
            .suffix(limit).map(\.outcome))
    }

    /// The schedule's latest run that has a session, for "Last Run's Session".
    func lastSession(of scheduleId: String, before now: Date) -> Item? {
        items.last { $0.scheduleId == scheduleId && $0.sessionId != nil && $0.at <= now }
    }

    /// The first occurrence still to come, the one whose countdown is bold.
    func nextUpcoming(after now: Date) -> Item? {
        items.first { $0.outcome == .upcoming && $0.at > now }
    }

    /// `2026-11-11` in `calendar`'s zone: a day's stable identifier.
    static func dayKey(_ day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Times the calendar writes: countdowns, durations, and their spoken forms.
enum ScheduleCalendarText {
    /// "in 18m", "in 2h 05m"; a day or more away, the weekday and time ("Thu 7:00 AM").
    static func countdown(to date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes < 1 { return String(localized: "now") }
        if minutes < 60 { return String(localized: "in \(minutes)m") }
        if minutes < 24 * 60 {
            return String(localized: "in \(minutes / 60)h \(String(format: "%02d", minutes % 60))m")
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEhmm")
        return formatter.string(from: date)
    }

    /// "in 18 minutes", "in 2 hours, 5 minutes".
    static func spokenCountdown(to date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes < 1 { return String(localized: "now") }
        if minutes >= 24 * 60 { return countdown(to: date, now: now, calendar: calendar, locale: locale) }
        return String(localized: "in \(spokenDuration(TimeInterval(minutes * 60), calendar: calendar, locale: locale))")
    }

    /// "<1m", "2m", "1h 05m".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// "5 hours, 12 minutes"; "less than a minute".
    static func spokenDuration(_ interval: TimeInterval, calendar: Calendar, locale: Locale = .current) -> String {
        guard interval >= 60 else { return String(localized: "less than a minute") }
        let formatter = DateComponentsFormatter()
        var formatterCalendar = calendar
        formatterCalendar.locale = locale
        formatter.calendar = formatterCalendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = interval >= 3_600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: (interval / 60).rounded(.down) * 60) ?? duration(interval)
    }

    /// "8:42" and "AM" apart, for the time column; one string in a 24-hour locale.
    static func timeParts(_ date: Date, calendar: Calendar, locale: Locale = .current) -> (time: String, period: String?) {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let full = formatter.string(from: date)
        let symbols = [formatter.amSymbol ?? "AM", formatter.pmSymbol ?? "PM"]
        for symbol in symbols where full.contains(symbol) {
            let time = full.replacingOccurrences(of: symbol, with: "").trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{202F}")))
            return (time, symbol)
        }
        return (full, nil)
    }
}
