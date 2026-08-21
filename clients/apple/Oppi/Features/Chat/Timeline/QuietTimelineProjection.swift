import Foundation

/// A presentation-only row. Quiet work lines deliberately do not use ChatItem
/// identity: reducer rows remain the source of truth and synthetic IDs cannot
/// accidentally become timeline or outline targets.
enum TimelineDisplayRow: Equatable, Identifiable {
    case item(ChatItem)
    case quietWork(QuietTimelineWorkLine)

    var id: String {
        switch self {
        case .item(let item): return item.id
        case .quietWork(let workLine): return workLine.id
        }
    }

    var sourceItemIDs: [String] {
        switch self {
        case .item(let item): return [item.id]
        case .quietWork(let workLine): return workLine.sourceItemIDs
        }
    }
}

struct QuietTimelineWorkLine: Equatable, Identifiable {
    /// Keep the icon sample bounded so very long turns don't bloat the
    /// Equatable diff; the strip only ever shows the most recent activity.
    static let activitySampleLimit = 12

    let id: String
    /// First folded source item ID. Stable when the following assistant message arrives.
    let turnID: String
    let sourceItemIDs: [String]
    let toolCount: Int
    let thinkingCount: Int
    /// Aggregate activity counts for VoiceOver. Unlike the bounded sample,
    /// these totals cover every folded item in the strip.
    let activityCounts: [String: Int]
    /// Ordered activity kinds folded into this strip — "thinking" or the
    /// normalized tool name per source item, capped to the most recent
    /// `activitySampleLimit`. Drives the leading tool icon and VoiceOver.
    let activities: [String]

    let isExpanded: Bool
    let isLive: Bool
    let liveStartedAt: Date?

    var summary: String {
        displaySummary(now: Date())
    }

    func displaySummary(now: Date) -> String {
        var parts: [String] = []
        if toolCount > 0 {
            parts.append("\(toolCount) \(toolCount == 1 ? "tool" : "tools")")
        }
        if thinkingCount > 0 {
            parts.append("\(thinkingCount) thinking \(thinkingCount == 1 ? "block" : "blocks")")
        }
        let counts = parts.joined(separator: ", ")
        guard isLive, let liveStartedAt else { return counts }
        let duration = Self.liveDurationString(since: liveStartedAt, now: now)
        if counts.isEmpty { return duration }
        return "\(counts) · \(duration)"
    }

    /// Keep seconds visible; Compact turns has room and SessionRow's compact
    /// `5m` form would hide the live tick.
    static func liveDurationString(since date: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        if elapsed < 60 { return "\(elapsed)s" }
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        if minutes < 60 { return "\(minutes)m \(seconds)s" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m \(seconds)s"
    }

    var accessibilityLabel: String { summary }
    var accessibilityValue: String { isExpanded ? "Expanded" : "Collapsed" }
}

/// Projects the complete reducer timeline for Compact turns without deleting
/// or rewriting reducer rows. Tools and thinking fold into one counted strip
/// per assistant message, sitting immediately above that reply. The Working
/// row stays a separate extension-owned status. Actionable content stays verbatim.
struct QuietTimelineProjection: Equatable {
    let rows: [TimelineDisplayRow]
    let fullTimelineItemIDs: [String]

    static func make(
        items: [ChatItem],
        isQuiet: Bool,
        isBusy: Bool,
        expandedTurnIDs: Set<String>,
        liveStartedAt: Date? = nil
    ) -> Self {
        let fullTimelineItemIDs = items.map(\.id)
        guard isQuiet, !items.isEmpty else {
            return Self(
                rows: items.map(TimelineDisplayRow.item),
                fullTimelineItemIDs: fullTimelineItemIDs
            )
        }

        var rows: [TimelineDisplayRow] = []
        rows.reserveCapacity(items.count)
        var pending: [ChatItem] = []

        func appendWorkLine() {
            guard let firstSourceID = pending.first?.id else { return }
            let sourceItemIDs = pending.map(\.id)
            // A trace-page prepend can reveal earlier rows in the same folded
            // group. While expanded, retain the already-selected source key so
            // the synthetic header and its toggle state do not change identity.
            let turnID = sourceItemIDs.first(where: expandedTurnIDs.contains) ?? firstSourceID
            let isExpanded = sourceItemIDs.contains(where: expandedTurnIDs.contains)
            let allActivities = pending.compactMap(Self.activityKind(for:))
            var activities = allActivities
            if activities.count > QuietTimelineWorkLine.activitySampleLimit {
                activities = Array(activities.suffix(QuietTimelineWorkLine.activitySampleLimit))
            }
            let activityCounts = allActivities.reduce(into: [String: Int]()) { counts, kind in
                counts[kind, default: 0] += 1
            }
            let workLine = QuietTimelineWorkLine(
                id: syntheticWorkLineID(for: turnID),
                turnID: turnID,
                sourceItemIDs: sourceItemIDs,
                toolCount: pending.reduce(into: 0) { count, item in
                    if case .toolCall = item { count += 1 }
                },
                thinkingCount: pending.reduce(into: 0) { count, item in
                    if case .thinking = item { count += 1 }
                },
                activityCounts: activityCounts,
                activities: activities,
                isExpanded: isExpanded,
                isLive: false,
                liveStartedAt: nil
            )
            rows.append(.quietWork(workLine))
            if isExpanded {
                rows.append(contentsOf: pending.map(TimelineDisplayRow.item))
            }
            pending.removeAll(keepingCapacity: true)
        }

        for item in items {
            if isQuietlyCollapsible(item) {
                pending.append(item)
                continue
            }
            // Every visible row is a chronology boundary. Flushing before it
            // keeps an ask/system/error/cache/audio row in place when a user
            // expands either adjacent folded group.
            appendWorkLine()
            rows.append(.item(item))
        }
        appendWorkLine()

        if isBusy,
           let workIndex = rows.lastIndex(where: {
               if case .quietWork = $0 { return true }
               return false
           }),
           case .quietWork(let workLine) = rows[workIndex] {
            // Only the final row can be live. A visible interruption after a
            // folded group must never inherit the current turn's clock.
            if workIndex == rows.index(before: rows.endIndex) {
                rows[workIndex] = .quietWork(
                    QuietTimelineWorkLine(
                        id: workLine.id,
                        turnID: workLine.turnID,
                        sourceItemIDs: workLine.sourceItemIDs,
                        toolCount: workLine.toolCount,
                        thinkingCount: workLine.thinkingCount,
                        activityCounts: workLine.activityCounts,
                        activities: workLine.activities,
                        isExpanded: workLine.isExpanded,
                        isLive: true,
                        liveStartedAt: liveStartedAt
                    )
                )
            }
        }

        return Self(rows: rows, fullTimelineItemIDs: fullTimelineItemIDs)
    }

    func renderedRowID(forSourceItemID sourceItemID: String) -> String? {
        if rows.contains(where: { $0.id == sourceItemID }) {
            return sourceItemID
        }
        return rows.first { row in
            if case .quietWork(let workLine) = row {
                return workLine.sourceItemIDs.contains(sourceItemID)
            }
            return false
        }?.id
    }

    /// Keep the render window in full ChatItem coordinates. This preserves the
    /// existing hidden-count/show-earlier contract while allowing a synthetic
    /// row to stand in for several source rows.
    func rows(forRenderedItemIDs renderedItemIDs: Set<String>) -> [TimelineDisplayRow] {
        rows.filter { row in
            row.sourceItemIDs.contains { renderedItemIDs.contains($0) }
        }
    }

    static func syntheticWorkLineID(for turnID: String) -> String {
        "quiet-work-line:\(turnID)"
    }

    /// Normalized activity kind for one collapsible source item.
    static func activityKind(for item: ChatItem) -> String? {
        switch item {
        case .thinking:
            return "thinking"
        case .toolCall(_, let tool, _, _, _, _, _):
            return ToolCallFormatting.normalized(tool)
        case .userMessage, .assistantMessage, .audioClip, .systemEvent,
             .cacheMiss, .customEvent, .error:
            return nil
        }
    }

    /// First collapsible item ID of the trailing fold group — the anchor the
    /// live strip would use. Nil when a visible row closes the last group,
    /// matching the chronology boundaries in `make`.
    static func trailingFoldGroupAnchorID(in items: [ChatItem]) -> String? {
        var anchor: String?
        for item in items {
            if isQuietlyCollapsible(item) {
                anchor = anchor ?? item.id
            } else {
                // This mirrors `make`: every visible interruption closes the
                // preceding folded group before it is rendered.
                anchor = nil
            }
        }
        return anchor
    }

    private static func isQuietlyCollapsible(_ item: ChatItem) -> Bool {
        switch item {
        case .toolCall(_, let tool, _, _, _, let isError, _):
            // Ask cards and failed tools stay actionable and visible. Successful
            // tools and thinking remain eligible for the presentation fold.
            return !isError && ToolCallFormatting.normalized(tool) != "ask"
        case .thinking:
            return true
        case .userMessage, .assistantMessage, .audioClip, .systemEvent,
             .cacheMiss, .customEvent, .error:
            return false
        }
    }
}
