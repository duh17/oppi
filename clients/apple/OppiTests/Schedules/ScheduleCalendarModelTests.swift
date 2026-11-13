import Foundation
import Testing
@testable import Oppi

/// The calendar's loads against a scripted server and a clock the test sets: when a load
/// starts, when it does not, and what the screen may say while one is out. No test waits
/// on time; each lets the model's load run to its end on the main actor.
@Suite("Schedule calendar model")
@MainActor
struct ScheduleCalendarModelTests {
    /// The server: counts the fetches, answers from `answer`, and can hold them.
    @MainActor
    final class Server {
        var calls: [DateInterval] = []
        var answer: (DateInterval) throws -> ScheduleCalendarResponse
        var holds = false
        private var held: [CheckedContinuation<Void, Never>] = []

        init(answer: @escaping (DateInterval) throws -> ScheduleCalendarResponse) {
            self.answer = answer
        }

        var heldCount: Int { held.count }

        func fetch(from: Date, to: Date) async throws -> ScheduleCalendarResponse {
            let range = DateInterval(start: from, end: to)
            calls.append(range)
            if holds { await withCheckedContinuation { held.append($0) } }
            return try answer(range)
        }

        func release() {
            let waiting = held
            held = []
            holds = false
            waiting.forEach { $0.resume() }
        }
    }

    @MainActor
    final class TestClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    struct Offline: Error {}

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    /// Wed Nov 11 2026, 8:59:30 AM Pacific; the Nanny run is due at 9:00.
    private static let morning = date("2026-11-11T16:59:30Z")
    private static let nine = date("2026-11-11T17:00:00Z")

    private static let nanny = ScheduleCalendarSchedule(
        id: "nanny", name: "Nanny", status: .active,
        trigger: .cron(expression: "0 9 * * *", timeZone: "America/Los_Angeles"),
        action: AgentScheduleActionSummary(type: .newSession, workspaceId: "home", promptChars: 10),
        upcomingTruncated: false
    )

    private static func response(
        _ range: DateInterval,
        now: Date,
        entries: [ScheduleCalendarEntry] = []
    ) -> ScheduleCalendarResponse {
        ScheduleCalendarResponse(from: range.start, to: range.end, now: now, schedules: [nanny], entries: entries)
    }

    private static func nineOClock(_ run: ScheduleCalendarRun? = nil) -> ScheduleCalendarEntry {
        ScheduleCalendarEntry(scheduleId: "nanny", slotKey: "cron:9", at: nine, run: run)
    }

    private static func run(_ status: AgentScheduleRunStatus, session: Bool = false) -> ScheduleCalendarRun {
        ScheduleCalendarRun(
            id: "run-nanny", kind: .due, status: status, createdAt: nine,
            session: session ? ScheduleCalendarSession(id: "sess-nanny", status: .busy, cost: 0.1) : nil
        )
    }

    private func model(_ server: Server, _ clock: TestClock) -> ScheduleCalendarModel {
        ScheduleCalendarModel(calendar: Self.calendar, clock: { clock.now }, fetch: { from, to in
            try await server.fetch(from: from, to: to)
        })
    }

    /// Runs the main actor until `condition` holds: the model's load is a task on it.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
    }

    private func settle(_ model: ScheduleCalendarModel) async {
        await until { !model.isLoading }
    }

    // MARK: - A failed load

    @Test("a failed load waits for Retry or for the client to arrive; nothing asks again on its own")
    func failedLoadIsNotRetried() async {
        let server = Server { _ in throw Offline() }
        let clock = TestClock(Self.morning)
        let model = model(server, clock)

        model.clientAvailable(true)
        await settle(model)
        #expect(server.calls.count == 1)
        #expect(model.failure != nil && model.response == nil)

        // The container's pass runs again for every change it observes, the failure included.
        for _ in 0..<5 { model.clientAvailable(true) }
        clock.now += 60
        model.tick()
        await settle(model)
        #expect(server.calls.count == 1, "A failure is not a reason to load")

        // The connection lost its client and got one back.
        model.clientAvailable(false)
        model.clientAvailable(true)
        await settle(model)
        #expect(server.calls.count == 2)

        // Retry.
        server.answer = { Self.response($0, now: clock.now) }
        model.reload()
        #expect(model.failure == nil, "Retry shows loading, not the old failure")
        await settle(model)
        #expect(model.response != nil && model.failure == nil)
    }

    // MARK: - A run coming due

    @Test("a slot that came due is fetched each minute until its run has dispatched, then no more")
    func dueSlotIsFetchedUntilItsRunSettles() async {
        let clock = TestClock(Self.morning)
        var entry = Self.nineOClock()
        let server = Server { Self.response($0, now: clock.now, entries: [entry]) }
        let model = model(server, clock)
        model.appear()
        await settle(model)
        #expect(server.calls.count == 1)

        clock.now = Self.nine.addingTimeInterval(-1)
        model.tick()
        await settle(model)
        #expect(server.calls.count == 1, "Not due yet")

        // 9:00. The server's runner has not ticked: the slot comes back with no run.
        clock.now = Self.nine
        model.tick()
        await settle(model)
        #expect(server.calls.count == 2)
        #expect(model.agenda(live: [:])?.items.map(\.outcome) == [.upcoming], "The row stays while the server owes its run")

        // 9:01. The run exists, not dispatched yet.
        entry = Self.nineOClock(Self.run(.pending))
        clock.now += 60
        model.tick()
        await settle(model)
        #expect(server.calls.count == 3)
        #expect(model.agenda(live: [:])?.items.map(\.outcome) == [.starting])

        // 9:02. Still starting, so asked again; now it launched its session.
        entry = Self.nineOClock(Self.run(.completed, session: true))
        clock.now += 60
        model.tick()
        await settle(model)
        #expect(server.calls.count == 4)
        #expect(model.agenda(live: [:])?.items.map(\.outcome) == [.running])

        // 9:03. Nothing owed: the session's changes arrive through the app's own events.
        clock.now += 60
        model.tick()
        await settle(model)
        #expect(server.calls.count == 4)
    }

    @Test("what is due is the server's call: a phone running ahead does not poll for it")
    func aheadPhoneDoesNotPoll() async {
        // The phone reads 9:09:30 when the server reads 8:59:30.
        let clock = TestClock(Self.morning.addingTimeInterval(600))
        let server = Server { Self.response($0, now: clock.now.addingTimeInterval(-600), entries: [Self.nineOClock()]) }
        let model = model(server, clock)
        model.appear()
        await settle(model)

        clock.now += 15
        model.tick()
        await settle(model)
        #expect(server.calls.count == 1, "9:00 is past on the phone and still to come on the server")

        clock.now += 15
        model.tick()
        await settle(model)
        #expect(server.calls.count == 2, "Now it is 9:00 on the server")
    }

    @Test("coming back on screen fetches again, and a pull returns when its answer lands")
    func appearAndPullFetch() async {
        let clock = TestClock(Self.morning)
        let server = Server { Self.response($0, now: clock.now) }
        let model = model(server, clock)
        model.appear()
        await settle(model)

        clock.now += 300
        model.appear()
        #expect(model.now == clock.now, "The clock is read on appearing")
        await settle(model)
        #expect(server.calls.count == 2)

        server.holds = true
        var pulled = false
        let pull = Task { @MainActor in
            await model.refresh()
            pulled = true
        }
        await until { server.heldCount == 1 }
        #expect(!pulled, "The pull's spinner stays while the load is out")
        server.release()
        await pull.value
        #expect(pulled && !model.isLoading && server.calls.count == 3)
    }

    // MARK: - Another week

    @Test("a day outside the loaded range is loading, not empty, until its week lands")
    func anotherWeekIsLoadingUntilItLands() async throws {
        let clock = TestClock(Self.morning)
        let server = Server { Self.response($0, now: clock.now) }
        let model = model(server, clock)
        model.appear()
        await settle(model)
        #expect(model.isSelectedDayLoaded)

        server.holds = true
        model.step(days: 7)
        #expect(model.isLoading)
        #expect(!model.isSelectedDayLoaded, "The old week's answer says nothing about this day")
        await until { server.heldCount == 1 }
        server.release()
        await settle(model)
        #expect(model.isSelectedDayLoaded)
        #expect(try #require(model.response).to == server.calls.last?.end)
    }

    @Test("a week's failed load leaves its day unloaded with the failure; the week before stays shown")
    func anotherWeekFailing() async {
        let clock = TestClock(Self.morning)
        let server = Server { Self.response($0, now: clock.now, entries: [Self.nineOClock()]) }
        let model = model(server, clock)
        model.appear()
        await settle(model)

        server.answer = { _ in throw Offline() }
        model.step(days: 7)
        await settle(model)
        #expect(!model.isSelectedDayLoaded && model.failure != nil)

        model.step(days: -7)
        await settle(model)
        #expect(model.isSelectedDayLoaded, "The week already loaded needs no load")
        #expect(model.agenda(live: [:])?.items.count == 1)
        #expect(server.calls.count == 2)
    }

    @Test("going back before another week lands keeps this week's answer")
    func leavingAWeekDropsItsLoad() async {
        let clock = TestClock(Self.morning)
        let server = Server { Self.response($0, now: clock.now) }
        let model = model(server, clock)
        model.appear()
        await settle(model)
        let loaded = model.loadedRange

        server.holds = true
        model.step(days: 7)
        await until { server.heldCount == 1 }
        model.step(days: -7)
        #expect(!model.isLoading && model.isSelectedDayLoaded)
        server.release()
        // The dropped load runs out.
        for _ in 0..<100 { await Task.yield() }
        #expect(model.loadedRange == loaded, "The answer for the week since left is dropped")
        #expect(model.isSelectedDayLoaded)
    }

    // MARK: - Run Now

    @Test("a Run Now's Starting row leaves by its key when the load after the server accepted it lands")
    func startingRowLeavesByKey() async {
        // The phone runs an hour ahead of the server, so no comparison of clocks can clear it.
        let clock = TestClock(Self.morning.addingTimeInterval(3_600))
        let server = Server { Self.response($0, now: clock.now.addingTimeInterval(-3_600)) }
        let model = model(server, clock)
        model.appear()
        await settle(model)

        let key = model.insertStarting(scheduleId: "nanny")
        #expect(model.agenda(live: [:])?.items.map(\.outcome) == [.starting])

        // A load that is not the Run Now's (a pull) leaves it: the server has not answered.
        await model.refresh()
        #expect(model.startingEntries.count == 1)

        // Accepted, but the load after it fails: the row stays, and the next minute asks again.
        server.answer = { _ in throw Offline() }
        model.startingAccepted(key)
        await settle(model)
        #expect(model.startingEntries.count == 1)
        let calls = server.calls.count

        server.answer = { Self.response($0, now: clock.now.addingTimeInterval(-3_600), entries: [Self.nineOClock(Self.run(.completed, session: true))]) }
        clock.now += 60
        model.tick()
        await settle(model)
        #expect(server.calls.count == calls + 1)
        #expect(model.startingEntries.isEmpty, "The answer holds the real run; the ghost is gone")
        #expect(model.agenda(live: [:])?.items.map(\.runId) == ["run-nanny"])
    }

    @Test("a Run Now that failed takes its Starting row with it and leaves another's alone")
    func failedRunNowRemovesItsRow() async {
        let clock = TestClock(Self.morning)
        let server = Server { Self.response($0, now: clock.now) }
        let model = model(server, clock)
        model.appear()
        await settle(model)

        let failed = model.insertStarting(scheduleId: "nanny")
        let waiting = model.insertStarting(scheduleId: "nanny")
        model.removeStarting(failed)
        #expect(model.startingEntries.map(\.slotKey) == [waiting])
    }
}
