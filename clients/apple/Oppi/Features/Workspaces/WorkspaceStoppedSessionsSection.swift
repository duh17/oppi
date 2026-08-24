import SwiftUI

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

struct WorkspaceStoppedSessionsSection: View {
    let stoppedSessions: [Session]
    let localSessions: [LocalSession]
    let hasSearchQuery: Bool
    let isImportingLocal: Bool
    let sessionPresentation: (Session) -> SessionRowPresentation
    let onOpenSession: (Session) -> Void
    let onResumeSession: (Session) -> Void
    let onDeleteSession: (Session) -> Void
    let onImportLocal: (LocalSession) -> Void

    @Binding var expandedGroupIDs: Set<String>
    @Binding var collapsedGroupIDs: Set<String>

    let archiveBuckets: [WorkspaceSessionArchiveBucket]
    let archiveStoppedSessions: (WorkspaceSessionArchiveBucket) -> [Session]
    let archiveLocalSessions: (WorkspaceSessionArchiveBucket) -> [LocalSession]
    let loadingArchiveBucketIDs: Set<String>
    let onExpandArchiveBucket: (WorkspaceSessionArchiveBucket) -> Void

    private enum StoppedItem: Identifiable {
        case session(Session)
        case local(LocalSession)

        var id: String {
            switch self {
            case .session(let session):
                return session.id
            case .local(let local):
                return "local-\(local.id)"
            }
        }

        var sortDate: Date {
            switch self {
            case .session(let session):
                return session.lastActivity
            case .local(let local):
                return local.lastModified
            }
        }
    }

    private struct StoppedSessionGroup: Identifiable {
        enum Bucket: Hashable {
            case day(Date)
            case month(Date)
        }

        let bucket: Bucket
        let items: [StoppedItem]

        var id: String {
            switch bucket {
            case .day(let day):
                return "day-\(Int(day.timeIntervalSince1970))"
            case .month(let month):
                return "month-\(Int(month.timeIntervalSince1970))"
            }
        }
    }

    private var stoppedSessionGroups: [StoppedSessionGroup] {
        // Merge and sort all items by date descending (single pass)
        let stoppedItems = stoppedSessions.map { StoppedItem.session($0) }
        let localItems = localSessions.map { StoppedItem.local($0) }
        var allItems = stoppedItems + localItems
        guard !allItems.isEmpty else { return [] }
        allItems.sort { $0.sortDate > $1.sortDate }

        let now = Date()
        let recentCutoffTs = now.timeIntervalSince1970 - 30 * 86400
        let calendar = Calendar.current

        // Int-keyed grouping: positive = local day-start timestamp, negative = -YYYYMM.
        // Calendar-derived day starts remain correct across 23/25-hour DST days.
        var bucketItems: [Int: [StoppedItem]] = [:]
        var bucketDates: [Int: Date] = [:]
        bucketItems.reserveCapacity(40)
        bucketDates.reserveCapacity(40)

        for item in allItems {
            let ts = item.sortDate.timeIntervalSince1970
            let key: Int
            let bucketDate: Date
            if ts >= recentCutoffTs {
                bucketDate = WorkspaceStoppedSessionExpansionPolicy.dayBucket(
                    for: item.sortDate,
                    calendar: calendar
                )
                key = Int(bucketDate.timeIntervalSince1970)
            } else {
                let comps = calendar.dateComponents([.year, .month], from: item.sortDate)
                let year = comps.year ?? 2000
                let month = comps.month ?? 1
                key = -(year * 100 + month)
                bucketDate = calendar.date(from: DateComponents(year: year, month: month))
                    ?? item.sortDate
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
                let bucket: StoppedSessionGroup.Bucket = key >= 0
                    ? .day(bucketDate)
                    : .month(bucketDate)
                // Items are already sorted descending from the pre-sorted input.
                return StoppedSessionGroup(bucket: bucket, items: items)
            }
    }

    var body: some View {
        ForEach(Array(stoppedSessionGroups.enumerated()), id: \.element.id) { index, group in
            Section {
                if isGroupExpanded(group) {
                    ForEach(group.items) { item in
                        stoppedItemRow(for: item)
                    }
                }
            } header: {
                Button {
                    toggleGroupExpansion(group)
                } label: {
                    HStack(spacing: 8) {
                        Text(index == 0 ? "Stopped · \(stoppedGroupTitle(group.bucket))" : stoppedGroupTitle(group.bucket))
                        Spacer()
                        Image(systemName: isGroupExpanded(group) ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeComment)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workspace.stoppedGroup.\(group.id)")
                .accessibilityValue(isGroupExpanded(group) ? "Expanded" : "Collapsed")
            }
        }

        ForEach(archiveBuckets) { bucket in
            Section {
                if isArchiveBucketExpanded(bucket) {
                    if loadingArchiveBucketIDs.contains(bucket.id) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading older sessions…")
                                .foregroundStyle(.themeComment)
                            Spacer()
                        }
                        .themedListRowBackground()
                    } else {
                        ForEach(archiveItems(for: bucket)) { item in
                            stoppedItemRow(for: item)
                        }
                    }
                }
            } header: {
                Button {
                    toggleArchiveBucketExpansion(bucket)
                } label: {
                    HStack(spacing: 8) {
                        Text("Stopped · \(stoppedGroupTitle(bucket))")
                        Spacer()
                        Text("\(bucket.itemCount)")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                        Image(systemName: isArchiveBucketExpanded(bucket) ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeComment)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stoppedGroupTitle(_ bucket: StoppedSessionGroup.Bucket) -> String {
        let cal = Calendar.current
        switch bucket {
        case .day(let day):
            if cal.isDateInToday(day) {
                return "Today"
            }
            if cal.isDateInYesterday(day) {
                return "Yesterday"
            }
            return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())

        case .month(let month):
            return month.formatted(.dateTime.month(.wide).year())
        }
    }

    private func stoppedGroupTitle(_ bucket: WorkspaceSessionArchiveBucket) -> String {
        switch bucket.kind {
        case .day:
            return stoppedGroupTitle(.day(bucket.startAt))
        case .month:
            return stoppedGroupTitle(.month(bucket.startAt))
        }
    }

    @ViewBuilder
    private func stoppedItemRow(for item: StoppedItem) -> some View {
        switch item {
        case .session(let session):
            Button {
                onOpenSession(session)
            } label: {
                SessionRow(presentation: sessionPresentation(session))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("session.nav.\(session.id)")
            .themedListRowBackground()
            .swipeActions(edge: .leading) {
                if session.ephemeral != true {
                    Button {
                        onResumeSession(session)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .tint(.themeGreen)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: SessionDeleteConfirmationPolicy.swipeButtonRole) {
                    onDeleteSession(session)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("session.delete.\(session.id)")
                .tint(.themeRed)
            }

        case .local(let local):
            Button {
                onImportLocal(local)
            } label: {
                LocalSessionRow(session: local)
            }
            .accessibilityIdentifier("localSession.nav.\(local.piSessionId)")
            .themedListRowBackground()
            .disabled(isImportingLocal)
        }
    }

    private func archiveItems(for bucket: WorkspaceSessionArchiveBucket) -> [StoppedItem] {
        let managed = archiveStoppedSessions(bucket).map(StoppedItem.session)
        let local = archiveLocalSessions(bucket).map(StoppedItem.local)
        return (managed + local).sorted { $0.sortDate > $1.sortDate }
    }

    private func isGroupExpanded(_ group: StoppedSessionGroup) -> Bool {
        if hasSearchQuery {
            return true
        }
        if expandedGroupIDs.contains(group.id) {
            return true
        }
        if collapsedGroupIDs.contains(group.id) {
            return false
        }
        return isGroupExpandedByDefault(group.bucket)
    }

    private func toggleGroupExpansion(_ group: StoppedSessionGroup) {
        if isGroupExpanded(group) {
            expandedGroupIDs.remove(group.id)
            collapsedGroupIDs.insert(group.id)
        } else {
            collapsedGroupIDs.remove(group.id)
            expandedGroupIDs.insert(group.id)
        }
    }

    private func isArchiveBucketExpanded(_ bucket: WorkspaceSessionArchiveBucket) -> Bool {
        if expandedGroupIDs.contains(bucket.id) {
            return true
        }
        if collapsedGroupIDs.contains(bucket.id) {
            return false
        }
        return false
    }

    private func toggleArchiveBucketExpansion(_ bucket: WorkspaceSessionArchiveBucket) {
        if isArchiveBucketExpanded(bucket) {
            expandedGroupIDs.remove(bucket.id)
            collapsedGroupIDs.insert(bucket.id)
        } else {
            collapsedGroupIDs.remove(bucket.id)
            expandedGroupIDs.insert(bucket.id)
            onExpandArchiveBucket(bucket)
        }
    }

    private func isGroupExpandedByDefault(_ bucket: StoppedSessionGroup.Bucket) -> Bool {
        switch bucket {
        case .day(let day):
            WorkspaceStoppedSessionExpansionPolicy.isDayExpandedByDefault(day)
        case .month:
            false
        }
    }
}
