import Foundation
import Observation

/// The calendar's data for one Schedules screen: the server's answer for the weeks
/// around the selected day, the selected day, the minute the screen shows as now,
/// and the Run Now runs still waiting on the server.
///
/// One per Schedules container, bound to the connection it was made for. A load for a
/// new range cancels the one in flight, and an answer for a range no longer wanted is
/// dropped. A failed refresh keeps what is shown.
///
/// Nothing here retries a failed load on its own. A load starts when the screen appears,
/// the person asks (pull, Retry, another week, Run Now, Pause), the connection gains its
/// API client, or a minute passes while the server still owes a run: an occurrence that
/// came due with no run yet, or a run whose dispatch has not finished.
@MainActor
@Observable
final class ScheduleCalendarModel {
    /// How much around the selected day the shown view needs: Day and Week need its week
    /// (and the one before, for the menu's last seven outcomes); Month needs its month.
    enum Span: Equatable {
        case week
        case month
    }

    /// Set by the container for the view it shows; a wider span loads what it adds.
    var span: Span = .week {
        didSet { if span != oldValue { loadIfNeeded() } }
    }

    /// The server's answer. Nil until the first load lands.
    private(set) var response: ScheduleCalendarResponse?
    private(set) var isLoading = false
    /// Why the last load failed; cleared when the next one starts.
    private(set) var failure: String?
    /// The range `response` answers. A day outside it has nothing to show yet.
    private(set) var loadedRange: DateInterval?
    /// The day the agenda shows, as any instant in it.
    private(set) var selectedDay: Date
    /// The minute the screen draws as now: countdowns, the now line, running times.
    private(set) var now: Date
    /// Night clusters opened in place, by `ScheduleCalendarAgenda.Cluster.id`.
    var expandedClusters: Set<String> = []
    /// Run Now entries drawn as Starting until a load that began after the server accepted
    /// the run lands: that answer holds the real run.
    private(set) var startingEntries: [ScheduleCalendarEntry] = []

    let calendar: Calendar
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let fetch: @MainActor (Date, Date) async throws -> ScheduleCalendarResponse
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadingRange: DateInterval?
    /// The Starting entries whose Run Now the server accepted, by slot key.
    @ObservationIgnored private var acceptedStarting: Set<String> = []
    /// The server's clock minus this device's, from the last answer. What is due is the
    /// server's call: a phone running ahead must not poll for runs the server does not owe.
    @ObservationIgnored private var serverClockOffset: TimeInterval = 0
    @ObservationIgnored private var hadClient = false

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
    func agenda(live: [String: Session]) -> ScheduleCalendarAgenda? {
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

    /// Whether the answer covers the selected day. While it does not (another week is on
    /// its way), the day is loading, not empty.
    var isSelectedDayLoaded: Bool { loadedRange?.contains(selectedDay) == true }

    func select(_ day: Date) {
        selectedDay = day
        loadIfNeeded()
    }

    func step(days: Int) {
        guard let day = calendar.date(byAdding: .day, value: days, to: selectedDay) else { return }
        select(day)
    }

    func showToday() { select(now) }

    /// Moves to the month `months` away: today when it is in that month, else its first day.
    func step(months: Int) {
        guard let start = calendar.dateInterval(of: .month, for: selectedDay)?.start,
              let month = calendar.date(byAdding: .month, value: months, to: start) else { return }
        showMonth(containing: month)
    }

    /// Shows `day`'s month with today selected when it is in it, else the month's first day.
    func showMonth(containing day: Date) {
        if calendar.isDate(day, equalTo: now, toGranularity: .month) {
            select(now)
        } else if let first = calendar.dateInterval(of: .month, for: day)?.start {
            select(first)
        }
    }

    /// The selected week and the one before it (the menu's last seven outcomes), unless
    /// already loaded.
    func loadIfNeeded() {
        guard let range = wantedRange else { return }
        if isLoading, loadingRange == range { return }
        if loadedRange.map({ $0.contains(range.start) && $0.end >= range.end }) == true {
            // A load still out for a week since left would replace this week's answer.
            if isLoading {
                loadTask?.cancel()
                isLoading = false
            }
            return
        }
        reload()
    }

    /// Fetches the wanted range again: a pull, Retry, after Pause or a schedule's edit.
    func reload() {
        guard let range = wantedRange else { return }
        loadTask?.cancel()
        isLoading = true
        loadingRange = range
        failure = nil
        // Every Run Now accepted before this load began is in its answer.
        let settled = acceptedStarting
        loadTask = Task { [weak self, fetch] in
            do {
                let answer = try await fetch(range.start, range.end)
                guard !Task.isCancelled, let self else { return }
                response = answer
                loadedRange = range
                serverClockOffset = answer.now.timeIntervalSince(clock())
                isLoading = false
                // By key, never by comparing clocks: a phone ahead of the server would
                // keep a ghost row.
                startingEntries.removeAll { settled.contains($0.slotKey) }
                acceptedStarting.subtract(settled)
            } catch {
                guard !Task.isCancelled, let self else { return }
                failure = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// `reload`, returning when it lands or fails: a pull to refresh ends then.
    func refresh() async {
        reload()
        await loadTask?.value
    }

    /// The screen came on: the clock is read and the range fetched, since runs and their
    /// sessions moved on while it was away.
    func appear() {
        now = clock()
        if !isLoading { reload() }
    }

    /// Whether the connection has its API client, told on every pass of the container. Only
    /// the client's arrival loads, for a first load that failed for want of one; a failed
    /// load is otherwise left to Retry, so a server that keeps failing is not asked in a loop.
    func clientAvailable(_ available: Bool) {
        let arrived = available && !hadClient
        hadClient = available
        if arrived, response == nil, !isLoading { reload() }
    }

    /// The minute changed. While the server owes a run the range is fetched again, each
    /// minute until the answer holds it: the server's runner records a due run on its own
    /// tick, up to a few minutes after the slot, so one fetch on the minute usually lands
    /// before the run exists.
    func tick() {
        now = clock()
        guard let response, !isLoading else { return }
        let serverNow = now.addingTimeInterval(serverClockOffset)
        if !acceptedStarting.isEmpty || response.entries.contains(where: { Self.awaitsRun($0, serverNow: serverNow) }) {
            reload()
        }
    }

    /// An occurrence that came due with no run yet (the server lists it only while its
    /// runner can still record it), or a run whose dispatch has not finished.
    private static func awaitsRun(_ entry: ScheduleCalendarEntry, serverNow: Date) -> Bool {
        guard let run = entry.run else { return entry.at <= serverNow }
        switch run.status {
        case .pending, .claimed, .running: return true
        case .completed, .failed, nil: return false
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

    /// The Run Now failed: its Starting row goes.
    func removeStarting(_ key: String) {
        startingEntries.removeAll { $0.slotKey == key }
    }

    /// The server accepted the Run Now: the range is fetched, and that answer's real run
    /// replaces the Starting row. If that load fails, the row stays until one lands.
    func startingAccepted(_ key: String) {
        acceptedStarting.insert(key)
        reload()
    }

    /// The span's weeks, and the week before them. A month's six weeks and one more stay
    /// within the server's 62 days.
    private var wantedRange: DateInterval? {
        let first: Date?
        let last: Date?
        switch span {
        case .week:
            first = week.first
            last = week.first
        case .month:
            let month = calendar.dateInterval(of: .month, for: selectedDay)
            first = month.flatMap { calendar.dateInterval(of: .weekOfYear, for: $0.start)?.start }
            last = month.flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) }
                .flatMap { calendar.dateInterval(of: .weekOfYear, for: $0)?.start }
        }
        guard let first, let last,
              let from = calendar.date(byAdding: .day, value: -7, to: first),
              let to = calendar.date(byAdding: .day, value: 7, to: last) else { return nil }
        return DateInterval(start: from, end: to)
    }
}

/// One timer for a calendar view on screen, on each minute boundary of the model's clock:
/// countdowns, running times, and the now line. The view starts it when it appears and
/// stops it when it leaves.
@MainActor
final class ScheduleCalendarMinuteTicker {
    private var timer: Timer?

    func start(_ model: ScheduleCalendarModel) {
        timer?.invalidate()
        // The boundary of the model's minute, which a screenshot preview may shift.
        let now = model.now
        let next = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60
        let fire = Date().addingTimeInterval(next - now.timeIntervalSinceReferenceDate)
        let timer = Timer(fire: fire, interval: 60, repeats: true) { [weak model] _ in
            MainActor.assumeIsolated { model?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
