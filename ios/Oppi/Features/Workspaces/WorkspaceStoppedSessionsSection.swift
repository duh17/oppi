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
        let stoppedItems = stoppedSessions.map { StoppedItem.session($0) }
        let localItems = localSessions.map { StoppedItem.local($0) }
        let allItems = stoppedItems + localItems

        guard !allItems.isEmpty else { return [] }

        let now = Date()
        let recentCutoffTs = now.timeIntervalSince1970 - 30 * 86400
        // Fast local-timezone day boundary using fixed UTC offset.
        // This ignores DST transitions within the 30-day window, which can shift
        // a session's day bucket by ±1 hour — acceptable for a display-only grouping
        // that only needs "same local calendar day" granularity.
        let tzOffset = Double(TimeZone.current.secondsFromGMT(for: now))

        let grouped = Dictionary(grouping: allItems) { item -> StoppedSessionGroup.Bucket in
            let ts = item.sortDate.timeIntervalSince1970
            if ts >= recentCutoffTs {
                // Fast startOfDay: floor to day boundary in local time
                let localTs = ts + tzOffset
                let dayStart = floor(localTs / 86400) * 86400 - tzOffset
                return .day(Date(timeIntervalSince1970: dayStart))
            }
            // For older items, use Calendar for month grouping (called rarely — only for items >30 days old)
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month], from: item.sortDate)
            let monthStart = cal.date(from: comps) ?? item.sortDate
            return .month(monthStart)
        }

        return grouped
            .map { bucket, items in
                StoppedSessionGroup(
                    bucket: bucket,
                    items: items.sorted { $0.sortDate > $1.sortDate }
                )
            }
            .sorted { lhs, rhs in
                stoppedGroupSortDate(lhs.bucket) > stoppedGroupSortDate(rhs.bucket)
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
