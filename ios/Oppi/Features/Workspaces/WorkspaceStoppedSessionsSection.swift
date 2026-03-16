import SwiftUI

struct WorkspaceStoppedSessionsSection: View {
    let stoppedSessions: [Session]
    let localSessions: [LocalSession]
    let hasSearchQuery: Bool
    let isImportingLocal: Bool
    let lineageHint: (Session) -> String?
    let onResumeSession: (Session) -> Void
    let onDeleteSession: (Session) -> Void
    let onImportLocal: (LocalSession) -> Void

    @Binding var expandedGroupIDs: Set<String>
    @Binding var collapsedGroupIDs: Set<String>

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
        // Fast local-timezone day boundary using fixed UTC offset.
        // Ignores DST transitions within the 30-day window (±1 hour shift at most)
        // — acceptable for display-only grouping.
        let tzOffset = Double(TimeZone.current.secondsFromGMT(for: now))

        // Int-keyed grouping: positive = day index, negative = -YYYYMM for month buckets.
        // Avoids String allocation and hashing per item.
        var bucketItems: [Int: [StoppedItem]] = [:]
        var bucketDates: [Int: Date] = [:]  // bucket → Date for Bucket enum reconstruction
        bucketItems.reserveCapacity(40)
        bucketDates.reserveCapacity(40)

        for item in allItems {
            let ts = item.sortDate.timeIntervalSince1970
            let key: Int
            if ts >= recentCutoffTs {
                let localTs = ts + tzOffset
                key = Int(floor(localTs / 86400))  // day index since epoch
            } else {
                let cal = Calendar.current
                let comps = cal.dateComponents([.year, .month], from: item.sortDate)
                let year = comps.year ?? 2000
                let month = comps.month ?? 1
                key = -(year * 100 + month)
            }
            bucketItems[key, default: []].append(item)
            if bucketDates[key] == nil {
                // First item per bucket is the max date (input is pre-sorted descending)
                bucketDates[key] = item.sortDate
            }
        }

        // Sort buckets by max date descending, convert to StoppedSessionGroup
        return bucketItems
            .sorted { lhs, rhs in
                (bucketDates[lhs.key] ?? .distantPast) > (bucketDates[rhs.key] ?? .distantPast)
            }
            .map { key, items in
                let bucket: StoppedSessionGroup.Bucket
                if key >= 0 {
                    // Day bucket: reconstruct Date from day index
                    let dayStart = Double(key) * 86400 - tzOffset
                    bucket = .day(Date(timeIntervalSince1970: dayStart))
                } else {
                    // Month bucket: reconstruct Date via Calendar (only a few month groups)
                    let encoded = -key
                    let year = encoded / 100
                    let month = encoded % 100
                    let cal = Calendar.current
                    let monthStart = cal.date(from: DateComponents(year: year, month: month)) ?? items[0].sortDate
                    bucket = .month(monthStart)
                }
                // Items are already sorted descending from the pre-sorted input
                return StoppedSessionGroup(bucket: bucket, items: items)
            }
    }

    var body: some View {
        ForEach(Array(stoppedSessionGroups.enumerated()), id: \.element.id) { index, group in
            Section {
                if isGroupExpanded(group) {
                    ForEach(group.items) { item in
                        switch item {
                        case .session(let session):
                            NavigationLink(value: session.id) {
                                SessionRow(
                                    session: session,
                                    pendingCount: 0,
                                    lineageHint: lineageHint(session)
                                )
                            }
                            .listRowBackground(Color.themeBg)
                            .swipeActions(edge: .leading) {
                                Button {
                                    onResumeSession(session)
                                } label: {
                                    Label("Resume", systemImage: "play.fill")
                                }
                                .tint(.themeGreen)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onDeleteSession(session)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }

                        case .local(let local):
                            Button {
                                onImportLocal(local)
                            } label: {
                                LocalSessionRow(session: local)
                            }
                            .listRowBackground(Color.themeBg)
                            .disabled(isImportingLocal)
                        }
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
            }
        }
    }

    private func stoppedGroupSortDate(_ bucket: StoppedSessionGroup.Bucket) -> Date {
        switch bucket {
        case .day(let day):
            return day
        case .month(let month):
            return month
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

    private func isGroupExpandedByDefault(_ bucket: StoppedSessionGroup.Bucket) -> Bool {
        switch bucket {
        case .day(let day):
            // Fast: today - 2 days in seconds
            let now = Date()
            let tzOffset = Double(TimeZone.current.secondsFromGMT(for: now))
            let localNow = now.timeIntervalSince1970 + tzOffset
            let todayStart = floor(localNow / 86400) * 86400 - tzOffset
            let expandedCutoff = todayStart - 2 * 86400
            return day.timeIntervalSince1970 >= expandedCutoff
        case .month:
            return false
        }
    }
}
