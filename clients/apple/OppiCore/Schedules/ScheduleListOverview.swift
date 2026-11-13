import Foundation

/// What the Schedules list says of each schedule beyond its definition, from the calendar's
/// answer: when it runs next, and how its latest run went and what it cost (its subagents'
/// included, as the calendar counts it). Pure, so the Mac shares it.
struct ScheduleListOverview: Sendable {
    struct Facts: Hashable, Sendable {
        /// The next occurrence still to come in the range.
        var next: Date?
        /// The latest run at or before now, running and waiting ones included.
        var last: ScheduleCalendarAgenda.Item?
        /// The model a run asks for, as the server's dispatch picks it.
        var model: String?
    }

    /// The list's sections for active schedules, by when each runs next.
    enum Group: Int, CaseIterable, Comparable, Sendable {
        case today
        case tomorrow
        case thisWeek
        case later
        /// Nothing in the range: a one-time run that already ran, or a rule that skips it.
        case notScheduled

        var title: String {
            switch self {
            case .today: String(localized: "Today")
            case .tomorrow: String(localized: "Tomorrow")
            case .thisWeek: String(localized: "This Week")
            case .later: String(localized: "Later")
            case .notScheduled: String(localized: "Not Scheduled")
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let facts: [String: Facts]

    init(agenda: ScheduleCalendarAgenda, now: Date) {
        var facts: [String: Facts] = [:]
        for schedule in agenda.schedules.values {
            facts[schedule.id] = Facts(model: schedule.model)
        }
        // Items are oldest first: the last past one wins, the first upcoming one does.
        for item in agenda.items {
            if item.outcome == .upcoming {
                if item.at > now, facts[item.scheduleId]?.next == nil { facts[item.scheduleId]?.next = item.at }
            } else if item.at <= now {
                facts[item.scheduleId]?.last = item
            }
        }
        self.facts = facts
    }

    static func group(next: Date?, now: Date, calendar: Calendar) -> Group {
        guard let next else { return .notScheduled }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: next)).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .tomorrow
        case 2..<7: return .thisWeek
        default: return .later
        }
    }

    /// Active schedules in their groups, each by its next run, then by name.
    func grouped(_ ids: [(id: String, name: String)], now: Date, calendar: Calendar) -> [(Group, [String])] {
        var groups: [Group: [(id: String, name: String, next: Date?)]] = [:]
        for schedule in ids {
            let next = facts[schedule.id]?.next
            groups[Self.group(next: next, now: now, calendar: calendar), default: []].append((schedule.id, schedule.name, next))
        }
        return Group.allCases.compactMap { group in
            guard let members = groups[group], !members.isEmpty else { return nil }
            let sorted = members.sorted { lhs, rhs in
                switch (lhs.next, rhs.next) {
                case let (left?, right?) where left != right: left < right
                default: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
            return (group, sorted.map(\.id))
        }
    }
}
