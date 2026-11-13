import Foundation

/// `GET /schedules/calendar`: what ran and what will run in `[from, to)`.
///
/// Mirrors the server's `ScheduleCalendarResponse` (`server/src/agent-schedule-calendar.ts`).
/// Past entries are runs joined to their sessions on the server; upcoming entries are expanded
/// from active schedules' triggers there, so the app keeps no cron parser of its own. Times
/// arrive as Unix milliseconds. Contract: `protocol/schedule-calendar.json`.
struct ScheduleCalendarResponse: Sendable, Equatable {
    var from: Date
    var to: Date
    var now: Date
    var schedules: [ScheduleCalendarSchedule]
    /// Oldest first.
    var entries: [ScheduleCalendarEntry]
}

struct ScheduleCalendarSchedule: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var status: AgentScheduleStatus
    var trigger: AgentScheduleTrigger
    var action: AgentScheduleActionSummary
    /// The model a run asks for, as the server's dispatch picks it.
    var model: String?
    /// The range held more upcoming occurrences than the server listed.
    var upcomingTruncated: Bool
}

struct ScheduleCalendarEntry: Sendable, Equatable {
    var scheduleId: String
    var slotKey: String
    /// The slot's time (a manual run's creation).
    var at: Date
    /// Nil for an occurrence with no run yet: one still to come, or one that just came due
    /// (`at` at or before the answer's `now`) and waits for the server's runner to record it.
    var run: ScheduleCalendarRun?

    /// Unique within one response: one run per schedule and slot.
    var key: String { "\(scheduleId).\(slotKey)" }
}

struct ScheduleCalendarRun: Sendable, Equatable {
    var id: String
    var kind: AgentScheduleRunKind
    /// Dispatch status only: `completed` means the session launched or the prompt was sent.
    /// Nil for a status this app version does not know, so a newer server's run draws as
    /// neutral instead of failing the whole calendar.
    var status: AgentScheduleRunStatus?
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var error: String?
    var promptDispatch: String?
    var session: ScheduleCalendarSession?
}

/// The run's session as the server holds it now. `cost` and `programStatus` cover the whole
/// session, any later follow-up in it included; `cost` is the session's own, without its
/// descendants'.
struct ScheduleCalendarSession: Sendable, Equatable {
    var id: String
    var workspaceId: String?
    var status: SessionStatus
    var programStatus: ProgramStatus?
    var cost: Double
    var model: String?
    /// When the session last settled (its done, error, or idle program status began).
    var settledAt: Date?
    /// The sessions it launched, theirs, and so on, oldest first, as session list rows. The
    /// server leaves out a descendant that is another scheduled run's session, with everything
    /// under it, and sends none for a run sent into an existing session.
    var descendants: [Session] = []
}

// MARK: - Coding

extension ScheduleCalendarResponse: Decodable {
    private enum CodingKeys: String, CodingKey { case from, to, now, schedules, entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeMilliseconds(.from)
        to = try c.decodeMilliseconds(.to)
        now = try c.decodeMilliseconds(.now)
        schedules = try c.decode([ScheduleCalendarSchedule].self, forKey: .schedules)
        entries = try c.decode([ScheduleCalendarEntry].self, forKey: .entries)
    }
}

extension ScheduleCalendarSchedule: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, status, trigger, action, model, upcomingTruncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(AgentScheduleStatus.self, forKey: .status)
        trigger = try c.decode(AgentScheduleTrigger.self, forKey: .trigger)
        action = try c.decode(AgentScheduleActionSummary.self, forKey: .action)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        upcomingTruncated = try c.decodeIfPresent(Bool.self, forKey: .upcomingTruncated) ?? false
    }
}

extension ScheduleCalendarEntry: Decodable {
    private enum CodingKeys: String, CodingKey { case scheduleId, slotKey, at, run }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scheduleId = try c.decode(String.self, forKey: .scheduleId)
        slotKey = try c.decode(String.self, forKey: .slotKey)
        at = try c.decodeMilliseconds(.at)
        run = try c.decodeIfPresent(ScheduleCalendarRun.self, forKey: .run)
    }
}

extension ScheduleCalendarRun: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, status, createdAt, startedAt, completedAt, error, promptDispatch, session
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(AgentScheduleRunKind.self, forKey: .kind)
        status = AgentScheduleRunStatus(rawValue: try c.decode(String.self, forKey: .status))
        createdAt = try c.decodeMilliseconds(.createdAt)
        startedAt = try c.decodeMillisecondsIfPresent(.startedAt)
        completedAt = try c.decodeMillisecondsIfPresent(.completedAt)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        promptDispatch = try c.decodeIfPresent(String.self, forKey: .promptDispatch)
        session = try c.decodeIfPresent(ScheduleCalendarSession.self, forKey: .session)
    }
}

extension ScheduleCalendarSession: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, workspaceId, status, programStatus, cost, model, settledAt, descendants
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        status = try c.decode(SessionStatus.self, forKey: .status)
        programStatus = try c.decodeIfPresent(ProgramStatus.self, forKey: .programStatus)
        cost = try c.decode(Double.self, forKey: .cost)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        settledAt = try c.decodeMillisecondsIfPresent(.settledAt)
        descendants = try c.decodeIfPresent([SessionSummary].self, forKey: .descendants)?.map(\.session) ?? []
    }
}

private extension KeyedDecodingContainer {
    func decodeMilliseconds(_ key: Key) throws -> Date {
        Date(timeIntervalSince1970: try decode(Double.self, forKey: key) / 1000)
    }

    func decodeMillisecondsIfPresent(_ key: Key) throws -> Date? {
        try decodeIfPresent(Double.self, forKey: key).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
