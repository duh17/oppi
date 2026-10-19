import Foundation

enum WorkspaceStoppedSessionExpansionPolicy {
    static func dayBucket(
        for date: Date,
        calendar: Calendar = .current
    ) -> Date {
        calendar.startOfDay(for: date)
    }

    static func isDayExpandedByDefault(
        _ day: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        calendar.isDate(day, inSameDayAs: now)
    }
}

/// A workspace's stopped history: recent days, then months, then older months
/// loaded on demand (archive buckets), with importable host Pi sessions mixed
/// in by date. The workspace screen draws the groups.
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

    enum Bucket: Hashable {
        case day(Date)
        case month(Date)
    }

    struct Group: Equatable {
        let bucket: Bucket
        /// Newest first.
        let items: [Item]

        /// `workspace.stoppedGroup.<id>` names the group's header.
        var id: String {
            switch bucket {
            case .day(let day): "day-\(Int(day.timeIntervalSince1970))"
            case .month(let month): "month-\(Int(month.timeIntervalSince1970))"
            }
        }

        var isExpandedByDefault: Bool {
            switch bucket {
            case .day(let day): WorkspaceStoppedSessionExpansionPolicy.isDayExpandedByDefault(day)
            case .month: false
            }
        }
    }

    /// Day groups for the last 30 days, then month groups, newest first.
    static func groups(
        stoppedEntries: [SessionListEntry],
        localSessions: [LocalSession],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Group] {
        var allItems = stoppedEntries.map(Item.entry) + localSessions.map(Item.local)
        guard !allItems.isEmpty else { return [] }
        allItems.sort { $0.sortDate > $1.sortDate }

        let recentCutoffTs = now.timeIntervalSince1970 - 30 * 86400

        // Int-keyed grouping: positive = local day-start timestamp, negative = -YYYYMM.
        // Calendar-derived day starts remain correct across 23/25-hour DST days.
        var bucketItems: [Int: [Item]] = [:]
        var bucketDates: [Int: Date] = [:]
        bucketItems.reserveCapacity(40)
        bucketDates.reserveCapacity(40)

        for item in allItems {
            let ts = item.sortDate.timeIntervalSince1970
            let key: Int
            let bucketDate: Date
            if ts >= recentCutoffTs {
                bucketDate = WorkspaceStoppedSessionExpansionPolicy.dayBucket(for: item.sortDate, calendar: calendar)
                key = Int(bucketDate.timeIntervalSince1970)
            } else {
                let comps = calendar.dateComponents([.year, .month], from: item.sortDate)
                let year = comps.year ?? 2000
                let month = comps.month ?? 1
                key = -(year * 100 + month)
                bucketDate = calendar.date(from: DateComponents(year: year, month: month)) ?? item.sortDate
            }
            bucketItems[key, default: []].append(item)
            bucketDates[key] = bucketDates[key] ?? bucketDate
        }

        return bucketItems
            .sorted { lhs, rhs in
                (bucketDates[lhs.key] ?? .distantPast) > (bucketDates[rhs.key] ?? .distantPast)
            }
            .map { key, items in
                let bucketDate = bucketDates[key] ?? items[0].sortDate
                // Items are already sorted descending from the pre-sorted input.
                return Group(bucket: key >= 0 ? .day(bucketDate) : .month(bucketDate), items: items)
            }
    }

    /// An archive bucket's loaded rows, newest first.
    static func archiveItems(entries: [SessionListEntry], localSessions: [LocalSession]) -> [Item] {
        (entries.map(Item.entry) + localSessions.map(Item.local)).sorted { $0.sortDate > $1.sortDate }
    }

    static func title(_ bucket: Bucket, calendar: Calendar = .current) -> String {
        switch bucket {
        case .day(let day):
            if calendar.isDateInToday(day) {
                return "Today"
            }
            if calendar.isDateInYesterday(day) {
                return "Yesterday"
            }
            return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .month(let month):
            return month.formatted(.dateTime.month(.wide).year())
        }
    }

    static func title(_ bucket: WorkspaceSessionArchiveBucket) -> String {
        switch bucket.kind {
        case .day: title(.day(bucket.startAt))
        case .month: title(.month(bucket.startAt))
        }
    }
}
