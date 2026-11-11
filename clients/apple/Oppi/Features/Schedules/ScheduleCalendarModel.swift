import Foundation
import Observation

/// The calendar's data for one Schedules screen: the server's answer for the weeks
/// around the selected day, the selected day, the minute the screen shows as now,
/// and the Run Now runs still waiting on the server.
///
/// One per Schedules container, bound to the connection it was made for. A load for a
/// new range cancels the one in flight, and an answer for a range no longer wanted is
/// dropped. A failed refresh keeps what is shown.
@MainActor
@Observable
final class ScheduleCalendarModel {
    /// The server's answer. Nil until the first load lands.
    private(set) var response: ScheduleCalendarResponse?
    private(set) var isLoading = false
    /// Why the last load failed; cleared by the next one that lands.
    private(set) var failure: String?
    /// The day the agenda shows, as any instant in it.
    private(set) var selectedDay: Date
    /// The minute the screen draws as now: countdowns, the now line, running times.
    private(set) var now: Date
    /// Night clusters opened in place, by `ScheduleCalendarAgenda.Cluster.id`.
    var expandedClusters: Set<String> = []
    /// Run Now entries drawn as Starting until the server's answer holds the real run.
    private(set) var startingEntries: [ScheduleCalendarEntry] = []

    let calendar: Calendar
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let fetch: @MainActor (Date, Date) async throws -> ScheduleCalendarResponse
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadedRange: DateInterval?

    init(
        calendar: Calendar = .autoupdatingCurrent,
        clock: @escaping @MainActor () -> Date = ScheduleCalendarModel.systemClock,
        fetch: @escaping @MainActor (Date, Date) async throws -> ScheduleCalendarResponse
    ) {
        self.calendar = calendar
        self.clock = clock
        let start = clock()
        now = start
        selectedDay = start
        self.fetch = fetch
    }

    /// The device's clock, or under a screenshot preview the time it poses.
    static func systemClock() -> Date {
        #if DEBUG
        if let previewOffset { return Date().addingTimeInterval(previewOffset) }
        #endif
        return Date()
    }

    #if DEBUG
    /// Seconds a screenshot preview moves the calendar's clock, so a capture shows the
    /// morning it was drawn for whatever the simulator's time.
    static var previewOffset: TimeInterval?
    #endif

    /// The agenda for drawing, with the app's live copy of followed sessions.
    func agenda(live: [String: ScheduleCalendarAgenda.SessionFacts]) -> ScheduleCalendarAgenda? {
        guard var response else { return nil }
        response.entries += startingEntries
        return ScheduleCalendarAgenda(response: response, live: live)
    }

    /// The selected day's week, first weekday first.
    var week: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: selectedDay)?.start ?? calendar.startOfDay(for: selectedDay)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var isShowingToday: Bool { calendar.isDate(selectedDay, inSameDayAs: now) }

    func select(_ day: Date) {
        selectedDay = day
        loadIfNeeded()
    }

    func step(days: Int) {
        guard let day = calendar.date(byAdding: .day, value: days, to: selectedDay) else { return }
        select(day)
    }

    func showToday() { select(now) }

    /// The selected week and the one before it (the menu's last seven outcomes), unless
    /// already loaded.
    func loadIfNeeded() {
        guard let range = wantedRange, loadedRange.map({ $0.contains(range.start) && $0.end >= range.end }) != true else {
            return
        }
        reload()
    }

    /// Fetches the wanted range again: a pull, a countdown that reached zero, after Run
    /// Now or Pause.
    func reload() {
        guard let range = wantedRange else { return }
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self, fetch] in
            do {
                let answer = try await fetch(range.start, range.end)
                guard !Task.isCancelled, let self else { return }
                response = answer
                loadedRange = range
                failure = nil
                isLoading = false
                // The server now has every Run Now that asked before this answer.
                startingEntries.removeAll { $0.at <= answer.now }
            } catch {
                guard !Task.isCancelled, let self else { return }
                failure = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// The minute changed. An upcoming occurrence that came due since the last tick has a
    /// run on the server now, so the range is fetched again.
    func tick() {
        let previous = now
        let date = clock()
        now = date
        guard let response else { return }
        if response.entries.contains(where: { $0.run == nil && $0.at > previous && $0.at <= date }) {
            reload()
        }
    }

    /// A Run Now the server has not answered yet: drawn as Starting at now.
    func insertStarting(scheduleId: String) -> String {
        let key = "starting:\(UUID().uuidString)"
        startingEntries.append(ScheduleCalendarEntry(
            scheduleId: scheduleId,
            slotKey: key,
            at: now,
            run: ScheduleCalendarRun(id: key, kind: .manual, status: .pending, createdAt: now)
        ))
        return key
    }

    func removeStarting(_ key: String) {
        startingEntries.removeAll { $0.slotKey == key }
    }

    private var wantedRange: DateInterval? {
        guard let weekStart = week.first,
              let from = calendar.date(byAdding: .day, value: -7, to: weekStart),
              let to = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return nil }
        return DateInterval(start: from, end: to)
    }
}
