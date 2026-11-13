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
    /// A prompt delivered into an existing session. That session's state and cost belong to
    /// everything sent into it, so the run says only that it was sent.
    case sent
    /// A run in a state this app version does not know (a newer server's): drawn neutral,
    /// with no claim about how it went.
    case other

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
        case .other: String(localized: "Unknown")
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

    /// A run's outcome. A new-session run reads its own session; a run that sent into an
    /// existing session never does, or every past send would turn Running whenever that
    /// session is busy.
    static func resolve(
        run: ScheduleCalendarRun?,
        session: ScheduleCalendarAgenda.SessionFacts?,
        sendsIntoExistingSession: Bool
    ) -> ScheduleCalendarOutcome {
        guard let run else { return .upcoming }
        guard let status = run.status else { return .other }
        if status == .failed { return .didNotStart }
        if sendsIntoExistingSession { return status == .completed ? .sent : .starting }
        guard let session else { return status == .completed ? .done : .starting }
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
            return .failed
        case .done, .idle, .stopped:
            return .done
        case nil:
            switch session.status {
            case .starting, .busy: return .running
            case .error: return .failed
            case .ready, .stopping, .stopped: return .done
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

    /// The sessions a run's session launched, and theirs: the server's list, each patched with
    /// the app's live copy. Equal lists hash alike by their ids.
    struct Subagents: Hashable, Sendable {
        let sessions: [Session]

        var isEmpty: Bool { sessions.isEmpty }
        var cost: Double { sessions.reduce(0) { $0 + $1.cost } }

        func hash(into hasher: inout Hasher) {
            hasher.combine(sessions.map(\.id))
        }
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
        /// The saved Agent the schedule launches, if any.
        let agentId: String?
        let model: String?
        /// What the run cost: its session's cost and its subagents'. Nil before a session
        /// exists, and for a run sent into an existing session (that session's cost is not
        /// this run's). Every total (a night cluster, the day) adds these.
        let cost: Double?
        /// What the run's session launched; empty for a run sent into an existing session.
        let subagents: Subagents
        /// When the run's work began: the run's start, else its creation.
        let startedAt: Date?
        /// When the run's own session last settled.
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
            case .done, .failed:
                return settledAt.map { max(0, $0.timeIntervalSince(startedAt)) }
            case .needsYou, .didNotStart, .upcoming, .sent, .other: return nil
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
        /// Something ran or is running: the day has outcomes and a cost to show.
        var hasRuns: Bool { done + running + failed + needsYou > 0 }
        var isEmpty: Bool { !hasRuns && upcoming == 0 }
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

    /// `live` is the app's copy of the sessions the answer names, runs' sessions and their
    /// subagents alike: running and blocked changes arrive there before the next fetch, so
    /// it wins over the answer.
    init(response: ScheduleCalendarResponse, live: [String: Session] = [:]) {
        let schedules = Dictionary(response.schedules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.schedules = schedules
        var seen = Set<String>()
        items = response.entries.compactMap { entry in
            guard let schedule = schedules[entry.scheduleId], seen.insert(entry.key).inserted else { return nil }
            let run = entry.run
            let served = run?.session.map {
                SessionFacts(status: $0.status, programStatus: $0.programStatus, cost: $0.cost)
            }
            let existing = schedule.action.type == .existingSession
            // An existing session's facts cover everything sent into it, not this run.
            let session = existing ? nil : run?.session.flatMap { served in
                live[served.id].map { SessionFacts(status: $0.status, programStatus: $0.programStatus, cost: $0.cost) }
            } ?? served
            let subagents = Subagents(sessions: existing ? [] : (run?.session?.descendants ?? []).map {
                live[$0.id] ?? $0
            })
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
                agentId: schedule.action.agentId,
                model: run?.session?.model ?? schedule.model,
                cost: session.map { $0.cost + subagents.cost },
                subagents: subagents,
                startedAt: run.map { $0.startedAt ?? $0.createdAt },
                settledAt: existing ? nil : run?.session?.settledAt,
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

    /// `day`'s counts and spend. A run in a state this version does not know counts nowhere.
    func summary(on day: Date, calendar: Calendar) -> Summary {
        var summary = Summary()
        for item in items(on: day, calendar: calendar) {
            switch item.outcome {
            case .upcoming: summary.upcoming += 1
            case .running, .starting: summary.running += 1
            case .failed, .didNotStart: summary.failed += 1
            case .needsYou: summary.needsYou += 1
            case .done, .sent: summary.done += 1
            case .other: break
            }
            summary.cost += item.cost ?? 0
        }
        return summary
    }

    /// The schedules whose later runs the server left out (`upcomingTruncated`) from `day`
    /// on: the names for the day's "more runs not shown" line. A truncated schedule's list
    /// stops at its last listed occurrence, so the line shows on that day and after it.
    func truncatedSchedules(on day: Date, now: Date, calendar: Calendar) -> [String] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start), end > now else { return [] }
        return schedules.values.filter { schedule in
            guard schedule.upcomingTruncated else { return false }
            let last = items.last { $0.scheduleId == schedule.id && $0.outcome == .upcoming }
            return (last?.at ?? now) < end
        }.map(\.name).sorted()
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

    /// A day's mark in Month, where ten daily routines make every day look alike, so it
    /// shows only the exceptions.
    enum MonthMark: Hashable, Sendable {
        /// Something ran: how it went and what it cost.
        case ran(hasFailure: Bool, needsYou: Bool, cost: Double)
        /// Still to come, and something that does not run most days falls on it: a weekly
        /// review, a monthly check, a one-time run.
        case occasion
    }

    /// `day`'s Month mark; nil for a day with nothing worth marking.
    func monthMark(on day: Date, calendar: Calendar) -> MonthMark? {
        let items = items(on: day, calendar: calendar)
        let ran = items.filter(\.outcome.isPast)
        if !ran.isEmpty {
            return .ran(
                hasFailure: ran.contains { $0.outcome.isFailure },
                needsYou: ran.contains { $0.outcome.isNeedsYou },
                cost: ran.compactMap(\.cost).reduce(0, +)
            )
        }
        let occasion = items.contains { $0.outcome == .upcoming && !$0.trigger.runsMostDays }
        return occasion ? .occasion : nil
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

    /// When the next occurrence still to come is due. Every occurrence at that time is
    /// next, and each one's countdown is bold.
    func nextUpcomingTime(after now: Date) -> Date? {
        items.first { $0.outcome == .upcoming && $0.at > now }?.at
    }

    /// `2026-11-11` in `calendar`'s zone: a day's stable identifier.
    static func dayKey(_ day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Times the calendar writes: countdowns, durations, and their spoken forms.
enum ScheduleCalendarText {
    /// "in 18m", "in 2h 05m"; a day or more away, the weekday and time ("Thu 7:00 AM");
    /// a week or more, the date ("Dec 1").
    static func countdown(to date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes < 1 { return String(localized: "now") }
        if minutes < 60 { return String(localized: "in \(minutes)m") }
        if minutes < 24 * 60 {
            return String(localized: "in \(minutes / 60)h \(String(format: "%02d", minutes % 60))m")
        }
        return format(date, template: minutes < 6 * 24 * 60 ? "EEEjmm" : "MMMd", calendar: calendar, locale: locale)
    }

    /// When a run comes next, under a heading that already names its day: "in 18m" within
    /// the hour, the time today or tomorrow ("5:00 PM"), the weekday and time within the
    /// week ("Thu 7:00 AM"), else the date ("Dec 1").
    static func nextRun(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        if date.timeIntervalSince(now) < 3_600 { return countdown(to: date, now: now, calendar: calendar, locale: locale) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days <= 1 { return format(date, template: "jmm", calendar: calendar, locale: locale) }
        return format(date, template: days < 7 ? "EEEjmm" : "MMMd", calendar: calendar, locale: locale)
    }

    /// When a run ran, as short as its distance allows: "7:00 AM" today, "Yesterday",
    /// "Mon" within the week, else "Nov 3".
    static func past(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return format(date, template: "jmm", calendar: calendar, locale: locale) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return String(localized: "Yesterday") }
        return format(date, template: days < 7 ? "EEE" : "MMMd", calendar: calendar, locale: locale)
    }

    private static func format(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
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
