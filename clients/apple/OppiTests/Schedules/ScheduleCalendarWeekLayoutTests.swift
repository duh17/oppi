import CoreGraphics
import Foundation
import Testing
@testable import Oppi

/// Where the Week grid puts runs: the compressed night, folded nights, the running bar and
/// the blocks inset over it, same-minute runs side by side or merged by column width, and no
/// block on top of another.
@Suite("Schedule calendar week layout")
struct ScheduleCalendarWeekLayoutTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// Wed Nov 11 2026 at `hour`:`minute` Pacific, `days` later.
    private static func at(_ hour: Int, _ minute: Int, days: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11 + days, hour: hour, minute: minute)) ?? .distantPast
        return base
    }

    private static let now = at(8, 42)

    private static var week: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 3, to: calendar.startOfDay(for: now)) }
    }

    private enum Kind { case done, failed, running, upcoming }

    /// A schedule per name, each run or occurrence as `(name, time, kind)`.
    private static func agenda(_ runs: [(String, Date, Kind)]) -> ScheduleCalendarAgenda {
        let names = Array(Set(runs.map(\.0))).sorted()
        let schedules = names.map { name in
            ScheduleCalendarSchedule(
                id: name, name: name, status: .active,
                trigger: .cron(expression: "0 9 * * *", timeZone: "America/Los_Angeles"),
                action: AgentScheduleActionSummary(type: .newSession, workspaceId: "w", promptChars: 1),
                upcomingTruncated: false
            )
        }
        let entries = runs.enumerated().map { index, run -> ScheduleCalendarEntry in
            let (name, at, kind) = run
            guard kind != .upcoming else { return ScheduleCalendarEntry(scheduleId: name, slotKey: "s\(index)", at: at) }
            let program: ProgramStatus = switch kind {
            case .done: ProgramStatus(state: .done, since: at.addingTimeInterval(60))
            case .failed: ProgramStatus(state: .error, since: at.addingTimeInterval(60))
            default: ProgramStatus(state: .working, since: at)
            }
            return ScheduleCalendarEntry(
                scheduleId: name, slotKey: "s\(index)", at: at,
                run: ScheduleCalendarRun(
                    id: "r\(index)", kind: .due, status: .completed, createdAt: at,
                    session: ScheduleCalendarSession(
                        id: "sess\(index)", status: kind == .running ? .busy : .stopped, programStatus: program, cost: 1
                    )
                )
            )
        }
        return ScheduleCalendarAgenda(response: ScheduleCalendarResponse(
            from: week[0], to: week[6].addingTimeInterval(86_400), now: now, schedules: schedules,
            entries: entries.sorted { $0.at < $1.at }
        ))
    }

    private static func layout(_ runs: [(String, Date, Kind)], columnWidth: CGFloat) -> ScheduleCalendarWeekLayout {
        ScheduleCalendarWeekLayout(
            agenda: agenda(runs), week: week, now: now, calendar: calendar,
            metrics: .init(columnWidth: columnWidth)
        )
    }

    @Test("the night takes 18 pt an hour and the day 56")
    func compressedNight() {
        let metrics = ScheduleCalendarWeekLayout.Metrics(columnWidth: 100)
        #expect(ScheduleCalendarWeekLayout.y(for: Self.at(3, 30), calendar: Self.calendar, metrics: metrics) == 63)
        #expect(ScheduleCalendarWeekLayout.y(for: Self.at(6, 0), calendar: Self.calendar, metrics: metrics) == 108)
        #expect(ScheduleCalendarWeekLayout.y(for: Self.at(8, 30), calendar: Self.calendar, metrics: metrics) == 108 + 2.5 * 56)
        #expect(abs(metrics.dayHeight - 1116) < 0.001)
    }

    @Test("a night's clean runs fold into one block at the band's top; a failure breaks out at its time")
    func nightFolds() {
        let layout = Self.layout([
            ("kypu", Self.at(0, 5), .done), ("journal", Self.at(0, 15), .done),
            ("dream", Self.at(3, 0), .failed),
        ], columnWidth: 100)
        let today = layout.blocks.filter { $0.day == 3 }
        #expect(today.map(\.id) == ["cluster.2026-11-11", "dream.s2"])
        #expect(today[0].frame.minY == 0)
        #expect(today[0].content.items.map(\.name) == ["kypu", "journal"])
        #expect(today[1].frame.minY == 54, "The failure sits at 3:00 AM")
    }

    @Test("a future night folds its occurrences too")
    func futureNightFolds() {
        let layout = Self.layout([
            ("kypu", Self.at(0, 5, days: 1), .upcoming), ("night", Self.at(3, 30, days: 1), .upcoming),
        ], columnWidth: 100)
        guard case .cluster(let cluster) = layout.blocks.first(where: { $0.day == 4 })?.content else {
            Issue.record("Thursday's night is one cluster: \(layout.blocks)")
            return
        }
        #expect(cluster.isUpcoming)
    }

    @Test("a running run is a bar to now, and the blocks over it are inset")
    func runningBar() throws {
        let layout = Self.layout([
            ("night", Self.at(3, 30), .running), ("digest", Self.at(7, 0), .failed), ("nanny", Self.at(9, 0), .upcoming),
        ], columnWidth: 100)
        let today = Dictionary(uniqueKeysWithValues: layout.blocks.filter { $0.day == 3 }.map { ($0.id, $0) })
        let bar = try #require(today["night.s0"])
        #expect(bar.isRunningBar)
        #expect(bar.frame.minY == 63)
        #expect(abs(bar.frame.maxY - (108 + (2 + 42.0 / 60) * 56)) < 0.001, "The bar ends at the now line")
        #expect(today["digest.s1"]?.frame.minX == 9, "A block over the bar is inset")
        #expect(today["nanny.s2"]?.frame.minX == 0, "A block after now is not")
        let order = layout.blocks.map(\.id)
        #expect((order.firstIndex(of: "night.s0") ?? 99) < (order.firstIndex(of: "digest.s1") ?? 0), "The bar draws first")
    }

    @Test("same-minute runs sit side by side in a wide column and merge in a narrow one")
    func sameMinute() {
        let runs: [(String, Date, Kind)] = [("mirror", Self.at(6, 0), .done), ("testflight", Self.at(6, 0), .failed)]
        let wide = Self.layout(runs, columnWidth: 140).blocks.filter { $0.day == 3 }
        #expect(wide.map(\.frame.minX) == [0, 70])
        #expect(wide.map(\.frame.width) == [70, 70])
        #expect(wide.allSatisfy { $0.frame.height == 38 }, "A wide column's blocks have two lines")

        let narrow = Self.layout(runs, columnWidth: 97).blocks.filter { $0.day == 3 }
        #expect(narrow.count == 1)
        #expect(narrow.first?.content.outcome == .failed, "The merged block wears the worst outcome")
        #expect(narrow.first?.frame.height == 26)
    }

    @Test("a block that would overlap the one above moves under it")
    func noOverlap() {
        let layout = Self.layout([
            ("a", Self.at(8, 0), .done), ("b", Self.at(8, 10), .done), ("c", Self.at(8, 20), .done),
        ], columnWidth: 100)
        let frames = layout.blocks.filter { $0.day == 3 }.map(\.frame)
        #expect(frames.count == 3)
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            #expect(lower.minY >= upper.maxY, "\(lower) overlaps \(upper)")
        }
        #expect(abs(frames[0].minY - 220) < 0.001, "The first block sits at 8:00 AM")
    }
}
