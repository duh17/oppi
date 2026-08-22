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

enum QuietWorkBucketKind: String, CaseIterable, Equatable {
    case read
    case tooling
    case write
    case edit

    var symbolName: String {
        switch self {
        case .read: return "magnifyingglass"
        case .write: return "pencil"
        case .edit: return "arrow.left.arrow.right"
        case .tooling: return "wrench.fill"
        }
    }
}

struct QuietWorkBucket: Equatable {
    struct EditStats: Equatable {
        let added: Int
        let removed: Int
    }

    let kind: QuietWorkBucketKind
    let count: Int
    let editStats: EditStats?

    init(kind: QuietWorkBucketKind, count: Int, editStats: EditStats? = nil) {
        self.kind = kind
        self.count = count
        self.editStats = editStats
    }

    var words: String {
        switch kind {
        case .read:
            return "read \(count) \(count == 1 ? "file" : "files")"
        case .write:
            return "write \(count) \(count == 1 ? "file" : "files")"
        case .edit:
            if let editStats {
                return "edit +\(editStats.added) −\(editStats.removed)"
            }
            return "edit \(count)"
        case .tooling:
            return "run \(count) \(count == 1 ? "tool" : "tools")"
        }
    }
}

struct QuietTimelineWorkLine: Equatable, Identifiable {
    let id: String
    /// First folded source item ID. Stable when the following assistant message arrives.
    let turnID: String
    let sourceItemIDs: [String]
    let buckets: [QuietWorkBucket]
    let displayStyle: AppPreferences.ChatDisplay.WorkStripStyle
    let isExpanded: Bool
    let isLive: Bool
    /// Interval start: preceding assistant or user timestamp.
    let liveStartedAt: Date?
    /// Interval end. Nil while live; settled strips freeze here.
    let intervalEndedAt: Date?

    init(
        id: String,
        turnID: String,
        sourceItemIDs: [String],
        buckets: [QuietWorkBucket],
        displayStyle: AppPreferences.ChatDisplay.WorkStripStyle,
        isExpanded: Bool,
        isLive: Bool,
        liveStartedAt: Date?,
        intervalEndedAt: Date? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.sourceItemIDs = sourceItemIDs
        self.buckets = buckets
        self.displayStyle = displayStyle
        self.isExpanded = isExpanded
        self.isLive = isLive
        self.liveStartedAt = liveStartedAt
        self.intervalEndedAt = intervalEndedAt
    }

    var isThinkingOnly: Bool { buckets.isEmpty }

    var workSummary: String {
        if isThinkingOnly {
            return isLive ? "Thinking…" : "Thought"
        }
        return buckets.map(\.words).joined(separator: "  ")
    }

    func durationString(now: Date) -> String? {
        guard let liveStartedAt else { return nil }
        let end: Date
        if isLive {
            end = now
        } else if let intervalEndedAt {
            end = intervalEndedAt
        } else {
            return nil
        }
        return Self.liveDurationString(since: liveStartedAt, now: end)
    }

    func wordsSummary(now: Date) -> String {
        let work = workSummary
        guard let duration = durationString(now: now) else { return work }
        return work.isEmpty ? duration : "\(work) · \(duration)"
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

    var accessibilityValue: String { isExpanded ? "Expanded" : "Collapsed" }
}

/// Projects the complete reducer timeline for Compact turns without deleting
/// or rewriting reducer rows. Tools and thinking fold together, including a
/// finished thinking-only strip so the thought does not vanish after settle.
/// Each strip keeps a durable interval clock. The Working row stays separate.
/// Ask cards and non-tool errors stay visible.
struct QuietTimelineProjection: Equatable {
    let rows: [TimelineDisplayRow]
    let fullTimelineItemIDs: [String]

    /// Frozen interval ends for settled (not live) work lines, keyed by strip ID.
    /// Remakes reuse these so a later `now` cannot restamp the muted clock.
    var settledEnds: [String: Date] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard case .quietWork(let line) = row, !line.isLive, let end = line.intervalEndedAt else {
                return nil
            }
            return (line.id, end)
        })
    }

    static func make(
        items: [ChatItem],
        isQuiet: Bool,
        isBusy: Bool,
        expandedTurnIDs: Set<String>,
        displayStyle: AppPreferences.ChatDisplay.WorkStripStyle = .icons,
        toolArgs: (String) -> [String: JSONValue]? = { _ in nil },
        now: Date = Date(),
        settledEnds: [String: Date] = [:]
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

        func appendWorkLine(endedAt: Date?) {
            guard let firstSourceID = pending.first?.id else { return }
            defer { pending.removeAll(keepingCapacity: true) }

            let buckets = Self.buckets(for: pending, toolArgs: toolArgs)
            let hasThinking = pending.contains {
                if case .thinking = $0 { return true }
                return false
            }
            guard !buckets.isEmpty || hasThinking else { return }

            let sourceItemIDs = pending.map(\.id)
            // A trace-page prepend can reveal earlier rows in the same folded
            // group. While expanded, retain the already-selected source key so
            // the synthetic header and its toggle state do not change identity.
            let turnID = sourceItemIDs.first(where: expandedTurnIDs.contains) ?? firstSourceID
            let isExpanded = sourceItemIDs.contains(where: expandedTurnIDs.contains)
            let workLine = QuietTimelineWorkLine(
                id: syntheticWorkLineID(for: turnID),
                turnID: turnID,
                sourceItemIDs: sourceItemIDs,
                buckets: buckets,
                displayStyle: displayStyle,
                isExpanded: isExpanded,
                isLive: false,
                liveStartedAt: precedingTimestamp,
                intervalEndedAt: endedAt
            )
            rows.append(.quietWork(workLine))
            if isExpanded {
                rows.append(contentsOf: pending.map(TimelineDisplayRow.item))
            }
        }

        var precedingTimestamp: Date?
        for item in items {
            if isQuietlyCollapsible(item) {
                pending.append(item)
                continue
            }
            // Every visible row is a chronology boundary. Flushing before it
            // keeps an ask/system/error/cache/audio row in place when a user
            // expands either adjacent folded group.
            appendWorkLine(endedAt: item.timestamp)
            rows.append(.item(item))
            if let timestamp = item.timestamp {
                precedingTimestamp = timestamp
            }
        }
        // A trailing settled group has no following user/assistant row to
        // close the interval. Reuse a previous freeze for this strip ID so a
        // later remake cannot restamp · Xs. Live trailing strips stay unfrozen.
        let trailingEndedAt: Date?
        if isBusy {
            trailingEndedAt = nil
        } else if let firstSourceID = pending.first?.id {
            let sourceItemIDs = pending.map(\.id)
            let turnID = sourceItemIDs.first(where: expandedTurnIDs.contains) ?? firstSourceID
            trailingEndedAt = settledEnds[syntheticWorkLineID(for: turnID)] ?? now
        } else {
            trailingEndedAt = nil
        }
        appendWorkLine(endedAt: trailingEndedAt)

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
                        buckets: workLine.buckets,
                        displayStyle: workLine.displayStyle,
                        isExpanded: workLine.isExpanded,
                        isLive: true,
                        liveStartedAt: workLine.liveStartedAt,
                        intervalEndedAt: nil
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

    private static func buckets(
        for items: [ChatItem],
        toolArgs: (String) -> [String: JSONValue]?
    ) -> [QuietWorkBucket] {
        var counts: [QuietWorkBucketKind: Int] = [:]
        var editAdded = 0
        var editRemoved = 0
        var hasCompleteEditStats = true

        for item in items {
            guard case .toolCall(let id, let tool, _, _, _, _, _) = item else { continue }
            let kind: QuietWorkBucketKind
            switch ToolCallFormatting.normalized(tool) {
            case "read": kind = .read
            case "write": kind = .write
            case "edit": kind = .edit
            default: kind = .tooling
            }
            counts[kind, default: 0] += 1

            if kind == .edit {
                if let stats = ToolCallFormatting.editDiffStats(from: toolArgs(id)) {
                    editAdded += stats.added
                    editRemoved += stats.removed
                } else {
                    hasCompleteEditStats = false
                }
            }
        }

        return QuietWorkBucketKind.allCases.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            let editStats: QuietWorkBucket.EditStats?
            if kind == .edit, hasCompleteEditStats {
                editStats = .init(added: editAdded, removed: editRemoved)
            } else {
                editStats = nil
            }
            return QuietWorkBucket(kind: kind, count: count, editStats: editStats)
        }
    }

    private static func isQuietlyCollapsible(_ item: ChatItem) -> Bool {
        switch item {
        case .toolCall(_, let tool, _, _, _, _, _):
            // Ask cards remain visible, while every other tool stays
            // inspectable inside the strip regardless of success or failure.
            return ToolCallFormatting.normalized(tool) != "ask"
        case .thinking:
            return true
        case .userMessage, .assistantMessage, .audioClip, .systemEvent,
             .cacheMiss, .customEvent, .error:
            return false
        }
    }
}
