import Foundation

/// A workspace's stopped history: the recent calendar days as day groups,
/// then older history loaded on demand (archive buckets), with importable host
/// Pi sessions mixed in by date. The workspace screen draws the groups.
///
/// The recent days follow All Sessions (`SessionInboxStoppedDayPolicy`): they
/// start at a local midnight, and the workspace asks the server for older
/// history from that same instant back, so no day is both a recent group and
/// an older section.
enum WorkspaceStoppedSessionGrouping {
    enum Item: Equatable {
        case entry(SessionListEntry)
        case local(LocalSession)

        var sortDate: Date {
            switch self {
            case .entry(let entry): entry.representative.lastActivity
            case .local(let local): local.lastModified
            }
        }
    }

    typealias Group = SessionInboxStoppedDayGroup<Item>

    /// Day groups from `rangeStart` on, newest first, items newest first.
    /// Older items belong to the server's older sections and are dropped here.
    static func groups(
        stoppedEntries: [SessionListEntry],
        localSessions: [LocalSession],
        rangeStart: Date,
        calendar: Calendar
    ) -> [Group] {
        let items = (stoppedEntries.map(Item.entry) + localSessions.map(Item.local))
            .sorted { $0.sortDate > $1.sortDate }
        return SessionInboxStoppedDayPolicy.groups(
            items,
            rangeStart: rangeStart,
            calendar: calendar,
            activityDate: \.sortDate
        )
    }

    /// `workspace.stoppedGroup.<id>` names a day group's header; UI tests match the `day-` prefix.
    static func groupID(for day: Date) -> String {
        "day-\(Int(day.timeIntervalSince1970))"
    }

    /// An archive bucket's loaded rows, newest first.
    static func archiveItems(entries: [SessionListEntry], localSessions: [LocalSession]) -> [Item] {
        (entries.map(Item.entry) + localSessions.map(Item.local)).sorted { $0.sortDate > $1.sortDate }
    }

    static func title(_ bucket: WorkspaceSessionArchiveBucket, now: Date, calendar: Calendar) -> String {
        switch bucket.kind {
        case .day: SessionInboxStoppedDayPolicy.title(for: bucket.startAt, now: now, calendar: calendar)
        case .month: bucket.startAt.formatted(.dateTime.month(.wide).year())
        }
    }
}
