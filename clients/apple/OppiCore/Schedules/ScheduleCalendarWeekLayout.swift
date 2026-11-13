import CoreGraphics
import Foundation

/// Where each run sits in the Week grid: hours down, one column per day. Pure, so every
/// width and the Mac share it.
///
/// - The night (midnight to 6 AM) is compressed: `nightHourHeight` an hour against
///   `dayHourHeight` by day. Each night's clean runs (a future night's occurrences) fold into
///   one cluster block at the band's top; anything else breaks out at its time.
/// - Finished runs are fixed-height blocks at their start, never duration bars: a session's
///   duration includes any later follow-up in it, and an 18-hour bar would bury the grid.
/// - A running run is the one bar: from its start to the now line. Blocks over it are inset
///   by `runningIndent` so the bar stays visible.
/// - Runs at the same minute sit side by side when a column is at least
///   `sideBySideMinWidth` wide; narrower, they merge into one "2 runs" block showing the worst
///   outcome.
/// - A block that would overlap the one above it in its column moves down under it.
/// - Calendar events (`EventBlock`) sit behind the runs across their real duration; a run
///   block over one is inset by `runningIndent`, so the event's edge stays visible.
struct ScheduleCalendarWeekLayout: Sendable {
    struct Metrics: Equatable, Sendable {
        var columnWidth: CGFloat
        var nightHourHeight: CGFloat = 18
        var dayHourHeight: CGFloat = 56
        /// A one-line block; a column wide enough for side-by-side runs gets two lines.
        var compactBlockHeight: CGFloat = 26
        var tallBlockHeight: CGFloat = 38
        var sideBySideMinWidth: CGFloat = 120
        var runningIndent: CGFloat = 9
        var gap: CGFloat = 2

        var isWideColumn: Bool { columnWidth >= sideBySideMinWidth }
        var blockHeight: CGFloat { isWideColumn ? tallBlockHeight : compactBlockHeight }
        var nightHeight: CGFloat { CGFloat(ScheduleCalendarAgenda.nightBandEndHour) * nightHourHeight }
        var dayHeight: CGFloat { nightHeight + CGFloat(24 - ScheduleCalendarAgenda.nightBandEndHour) * dayHourHeight }
    }

    enum Content: Hashable, Sendable {
        case entry(ScheduleCalendarAgenda.Item)
        /// A night's clean runs, or a future night's occurrences.
        case cluster(ScheduleCalendarAgenda.Cluster)
        /// Runs at one minute in a column too narrow to show them side by side.
        case merged([ScheduleCalendarAgenda.Item])

        var items: [ScheduleCalendarAgenda.Item] {
            switch self {
            case .entry(let item): [item]
            case .cluster(let cluster): cluster.items
            case .merged(let items): items
            }
        }

        /// The outcome the block wears: its own, or the worst of its runs.
        var outcome: ScheduleCalendarOutcome {
            switch self {
            case .entry(let item): item.outcome
            case .cluster(let cluster): cluster.isUpcoming ? .upcoming : .done
            case .merged(let items): ScheduleCalendarWeekLayout.worst(items.map(\.outcome))
            }
        }
    }

    struct Block: Hashable, Sendable, Identifiable {
        /// An entry's id, `cluster.<day>`, or `merged.<first entry's id>`.
        let id: String
        /// 0 to 6, the week's day.
        let day: Int
        let content: Content
        /// In its column: x from the column's leading edge, y from the grid's top.
        let frame: CGRect
        /// A running run's bar, from its start to now.
        var isRunningBar: Bool { if case .entry(let item) = content { return item.outcome == .running } else { return false } }
    }

    let metrics: Metrics
    let blocks: [Block]
    /// The week's timed calendar events, drawn behind `blocks`.
    let eventBlocks: [EventBlock]
    let contentHeight: CGFloat

    /// `events` are this device's calendar events for the week; all-day ones are not placed
    /// in the grid.
    init(
        agenda: ScheduleCalendarAgenda?,
        week: [Date],
        now: Date,
        calendar: Calendar,
        metrics: Metrics,
        events: [ScheduleCalendarEvent] = []
    ) {
        self.metrics = metrics
        var blocks: [Block] = []
        var eventBlocks: [EventBlock] = []
        for (index, day) in week.enumerated() {
            let timed = ScheduleCalendarEvent.on(day, in: events, calendar: calendar).timed
            let dayEvents = Self.eventColumn(timed, day: day, index: index, calendar: calendar, metrics: metrics)
            eventBlocks += dayEvents
            blocks += Self.column(
                agenda: agenda, day: day, index: index, now: now, calendar: calendar, metrics: metrics,
                events: dayEvents.map(\.frame)
            )
        }
        self.blocks = blocks
        self.eventBlocks = eventBlocks
        let bottom = (blocks.map(\.frame.maxY) + eventBlocks.map(\.frame.maxY)).max() ?? 0
        contentHeight = max(metrics.dayHeight, bottom + metrics.gap)
    }

    /// The y of `date`'s wall-clock time on its day.
    static func y(for date: Date, calendar: Calendar, metrics: Metrics) -> CGFloat {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hours = CGFloat(parts.hour ?? 0) + CGFloat(parts.minute ?? 0) / 60
        let band = CGFloat(ScheduleCalendarAgenda.nightBandEndHour)
        return hours < band
            ? hours * metrics.nightHourHeight
            : metrics.nightHeight + (hours - band) * metrics.dayHourHeight
    }

    /// The y of the top of `hour` (0–23).
    static func y(hour: Int, metrics: Metrics) -> CGFloat {
        let band = ScheduleCalendarAgenda.nightBandEndHour
        return hour < band
            ? CGFloat(hour) * metrics.nightHourHeight
            : metrics.nightHeight + CGFloat(hour - band) * metrics.dayHourHeight
    }

    /// Failed beats needs you beats running beats done beats upcoming.
    static func worst(_ outcomes: [ScheduleCalendarOutcome]) -> ScheduleCalendarOutcome {
        func rank(_ outcome: ScheduleCalendarOutcome) -> Int {
            switch outcome {
            case .failed, .didNotStart: 6
            case .needsYou: 5
            case .running: 4
            case .starting: 3
            case .other: 2
            case .done, .sent: 1
            case .upcoming: 0
            }
        }
        return outcomes.max { rank($0) < rank($1) } ?? .upcoming
    }

    private static func column(
        agenda: ScheduleCalendarAgenda?,
        day: Date,
        index: Int,
        now: Date,
        calendar: Calendar,
        metrics: Metrics,
        events: [CGRect]
    ) -> [Block] {
        guard let agenda else { return [] }
        let items = agenda.items(on: day, calendar: calendar)
        guard !items.isEmpty else { return [] }
        let start = calendar.startOfDay(for: day)
        let bandEnd = calendar.date(bySettingHour: ScheduleCalendarAgenda.nightBandEndHour, minute: 0, second: 0, of: start) ?? start
        let isFuture = start > now
        let folds: (ScheduleCalendarAgenda.Item) -> Bool = { isFuture ? $0.outcome == .upcoming : $0.outcome.isClean }
        let folded = items.filter { $0.at < bandEnd && folds($0) }
        let width = metrics.columnWidth
        let height = metrics.blockHeight

        // Content and the y it wants, in time order.
        var wanted: [(id: String, content: Content, y: CGFloat)] = []
        var rest = items
        if folded.count >= 2 {
            let id = "cluster.\(ScheduleCalendarAgenda.dayKey(day, calendar: calendar))"
            wanted.append((id, .cluster(.init(id: id, items: folded, isUpcoming: isFuture, isExpanded: false)), 0))
            let foldedIds = Set(folded.map(\.id))
            rest.removeAll { foldedIds.contains($0.id) }
        }
        var running: [Block] = []
        // Same-minute runs together; a running run is its own bar.
        var groups: [(at: Date, items: [ScheduleCalendarAgenda.Item])] = []
        for item in rest {
            if item.outcome == .running {
                let top = y(for: item.at, calendar: calendar, metrics: metrics)
                let bottom = max(top + height, y(for: now, calendar: calendar, metrics: metrics))
                running.append(Block(
                    id: item.id, day: index, content: .entry(item),
                    frame: CGRect(x: 0, y: top, width: width, height: bottom - top)
                ))
                continue
            }
            if let last = groups.indices.last, groups[last].at == item.at {
                groups[last].items.append(item)
            } else {
                groups.append((item.at, [item]))
            }
        }
        for group in groups {
            let top = y(for: group.at, calendar: calendar, metrics: metrics)
            if group.items.count == 1 || metrics.isWideColumn {
                for item in group.items { wanted.append((item.id, .entry(item), top)) }
            } else {
                wanted.append(("merged.\(group.items[0].id)", .merged(group.items), top))
            }
        }

        // Lay out top to bottom: a row of same-minute entries shares one y; each row starts
        // under the one above it.
        var placed: [Block] = []
        var floor: CGFloat = -metrics.gap
        var index0 = 0
        while index0 < wanted.count {
            let y0 = wanted[index0].y
            var row = [wanted[index0]]
            var next = index0 + 1
            if case .entry = wanted[index0].content {
                while next < wanted.count, wanted[next].y == y0, case .entry = wanted[next].content {
                    row.append(wanted[next])
                    next += 1
                }
            }
            let top = max(y0, floor + metrics.gap)
            let covers = { (frame: CGRect) in frame.minY <= top + height && frame.maxY > top }
            let indent = running.map(\.frame).contains(where: covers) || events.contains(where: covers) ? metrics.runningIndent : 0
            let laneWidth = (width - indent) / CGFloat(row.count)
            for (lane, entry) in row.enumerated() {
                placed.append(Block(
                    id: entry.id, day: index, content: entry.content,
                    frame: CGRect(x: indent + CGFloat(lane) * laneWidth, y: top, width: laneWidth, height: height)
                ))
            }
            floor = top + height
            index0 = next
        }
        // The bar first, so the blocks over it draw on top.
        return running + placed
    }
}
