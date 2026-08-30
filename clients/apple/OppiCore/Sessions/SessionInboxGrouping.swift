import Foundation

struct SessionInboxStoppedDayGroup<Item>: Identifiable {
    let day: Date
    let items: [Item]

    var id: String { SessionInboxStoppedDayPolicy.groupID(for: day) }
}

/// Calendar-day window and labels for the global session inbox stopped groups.
///
/// The root inbox shows stopped sessions from the three most recent calendar
/// days. Today's group starts expanded; earlier days start collapsed.
/// Stopped incognito sessions are omitted because they have no resumable history.
struct SessionInboxStoppedDayPolicy {
    static let visibleDayCount = 3

    static func includesStoppedSession(_ session: Session) -> Bool {
        session.ephemeral != true
    }

    static func visibleRangeStart(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(visibleDayCount - 1), to: today) ?? today
    }

    static func groups<Item>(
        _ items: [Item],
        now: Date,
        calendar: Calendar,
        activityDate: (Item) -> Date
    ) -> [SessionInboxStoppedDayGroup<Item>] {
        let rangeStart = visibleRangeStart(now: now, calendar: calendar)
        var itemsByDay: [Date: [Item]] = [:]
        itemsByDay.reserveCapacity(visibleDayCount)

        for item in items {
            let date = activityDate(item)
            guard date >= rangeStart else { continue }
            let day = calendar.startOfDay(for: date)
            itemsByDay[day, default: []].append(item)
        }

        return itemsByDay.keys.sorted(by: >).map { day in
            SessionInboxStoppedDayGroup(day: day, items: itemsByDay[day] ?? [])
        }
    }

    static func groupID(for day: Date) -> String {
        "stopped-day-\(Int(day.timeIntervalSince1970))"
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func isExpandedByDefault(day: Date, now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(day, inSameDayAs: now)
    }
}

enum SessionInboxSectionTitle {
    static let yourTurn = "Your Turn"
    static let working = "Working"

    static func stopped(day: Date, now: Date, calendar: Calendar) -> String {
        "Stopped · \(SessionInboxStoppedDayPolicy.title(for: day, now: now, calendar: calendar))"
    }
}

struct SessionInboxSections<Item> {
    var yourTurn: [Item]
    var working: [Item]
    var stoppedGroups: [SessionInboxStoppedDayGroup<Item>]

    var isEmpty: Bool {
        yourTurn.isEmpty && working.isEmpty && stoppedGroups.isEmpty
    }
}

/// Shared inbox sectioning for iOS and Mac home lists.
enum SessionInboxGrouping {
    static func make<Item>(
        items: [Item],
        now: Date,
        calendar: Calendar,
        session: (Item) -> Session,
        attention: (Item) -> SessionListAttentionCounts
    ) -> SessionInboxSections<Item> {
        var yourTurn: [Item] = []
        var working: [Item] = []
        var stopped: [Item] = []

        for item in items {
            let sessionValue = session(item)
            switch SessionListPresentation.activeSectionKind(
                for: sessionValue,
                attention: attention(item)
            ) {
            case .yourTurn:
                yourTurn.append(item)
            case .working:
                working.append(item)
            case nil:
                if SessionInboxStoppedDayPolicy.includesStoppedSession(sessionValue) {
                    stopped.append(item)
                }
            }
        }

        yourTurn.sort { lhs, rhs in
            SessionListPresentation.compareYourTurn(
                session(lhs),
                lhsAttention: attention(lhs),
                session(rhs),
                rhsAttention: attention(rhs)
            )
        }
        working.sort { SessionListPresentation.compareWorking(session($0), session($1)) }
        stopped.sort {
            let lhs = session($0)
            let rhs = session($1)
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.id < rhs.id
        }

        return SessionInboxSections(
            yourTurn: yourTurn,
            working: working,
            stoppedGroups: SessionInboxStoppedDayPolicy.groups(
                stopped,
                now: now,
                calendar: calendar,
                activityDate: { session($0).lastActivity }
            )
        )
    }
}
