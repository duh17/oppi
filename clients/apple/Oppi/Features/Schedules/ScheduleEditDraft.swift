import Foundation
import Observation

/// What Edit Schedule edits: the draft Save sends and Cancel drops. Fields of
/// both kinds of schedule live here; the editor shows the ones its action uses.
///
/// Made from a calendar event (`init(event:…)`), it is a new one-time schedule
/// that starts a session: the event's time, its title as the name, and its details
/// as the prompt's context. Save creates it.
@MainActor @Observable
final class ScheduleEditDraft {
    /// The saved schedule this edits; nil for a new one.
    let schedule: AgentSchedule?
    /// The calendar event a new schedule is for.
    let event: ScheduleCalendarEvent?
    let connection: ServerConnection
    /// The server the schedule runs on, for the page's scope sentence.
    let serverName: String

    var name: String
    var triggerDraft: ScheduleTriggerDraft
    var prompt: String
    var workspaceId: String
    var agentId: String
    var model: String
    var thinkingLevel: ThinkingLevel?
    var sessionName: String
    var targetSessionId: String
    var streamingBehavior: ExistingSessionStreamingBehavior?
    private(set) var agents: [AgentDefinitionSummary] = []
    private(set) var isSaving = false
    var error: String?

    private static let commonIntervals: [Int64] = [
        15 * 60_000,
        60 * 60_000,
        6 * 60 * 60_000,
        24 * 60 * 60_000,
        7 * 24 * 60 * 60_000,
    ]

    init(schedule: AgentSchedule, connection: ServerConnection, serverName: String, now: Date = Date()) {
        self.schedule = schedule
        event = nil
        self.connection = connection
        self.serverName = serverName
        name = schedule.name
        triggerDraft = ScheduleTriggerDraft(trigger: schedule.trigger, now: now)
        prompt = schedule.action.prompt
        switch schedule.action {
        case .newSession(let workspaceId, _, let agentId, let model, let thinkingLevel, _, let name):
            self.workspaceId = workspaceId
            self.agentId = agentId ?? ""
            self.model = model ?? ""
            self.thinkingLevel = thinkingLevel
            sessionName = name ?? ""
            targetSessionId = ""
            streamingBehavior = nil
        case .existingSession(let workspaceId, let sessionId, _, let streamingBehavior):
            self.workspaceId = workspaceId
            agentId = ""
            model = ""
            thinkingLevel = nil
            sessionName = ""
            targetSessionId = sessionId
            self.streamingBehavior = streamingBehavior
        }
    }

    /// A new one-time schedule for `event`, run 30 minutes before it (`ScheduleEventOffset.initialDate`)
    /// in this device's time zone, in the first workspace the server lists.
    init(
        event: ScheduleCalendarEvent,
        connection: ServerConnection,
        serverName: String,
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date()
    ) {
        schedule = nil
        self.event = event
        self.connection = connection
        self.serverName = serverName
        name = event.title
        triggerDraft = ScheduleTriggerDraft(
            trigger: .at(ScheduleEventOffset.initialDate(for: event, now: now), timeZone: calendar.timeZone.identifier),
            now: now
        )
        prompt = String(localized: "Help me prepare for this event.") + "\n\n" + event.promptContext(calendar: calendar)
        workspaceId = connection.workspaceStore.workspaces.first?.id ?? ""
        agentId = ""
        model = ""
        thinkingLevel = nil
        sessionName = ""
        targetSessionId = ""
        streamingBehavior = nil
    }

    // MARK: - What the editor shows

    var isNewSessionAction: Bool {
        guard let schedule else { return true }
        if case .newSession = schedule.action { return true }
        return false
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workspaceId.isEmpty
            && (isNewSessionAction || !targetSessionId.isEmpty)
            && triggerDraft.canSave
            // An event's schedule runs once: a time already past would never run.
            && (event == nil || triggerDraft.oneTimeDate > Date())
            && !isSaving
    }

    /// The offset from the event the run time matches, if any; nil once Run At was set
    /// by hand.
    var eventOffset: ScheduleEventOffset? {
        guard let event else { return nil }
        return ScheduleEventOffset.allCases.first { $0.date(for: event) == triggerDraft.oneTimeDate }
    }

    func chooseEventOffset(_ offset: ScheduleEventOffset) {
        guard let event else { return }
        triggerDraft.oneTimeDate = offset.date(for: event)
    }

    /// The sessions an existing-session schedule can target: the workspace's,
    /// plus the current target when it is not among them, latest first.
    var availableSessions: [Session] {
        var sessions = connection.sessionStore.listProjectionSessions(workspaceId: workspaceId)
        if let current = connection.sessionStore.session(id: targetSessionId),
           !sessions.contains(where: { $0.id == current.id }) {
            sessions.append(current)
        }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    var workspaces: [Workspace] { connection.workspaceStore.workspaces }

    /// The repeat intervals offered: the common ones and the schedule's own.
    var intervalOptions: [Int64] {
        Array(Set(Self.commonIntervals + [triggerDraft.intervalMs])).sorted()
    }

    var modelDisplayName: String {
        guard let model = model.managementNilIfBlank else { return "Agent or server default" }
        return SessionFormatting.shortModelName(model) ?? model
    }

    // MARK: - Changes

    /// Picks the workspace; an existing-session schedule moves to that
    /// workspace's most recent session.
    func selectWorkspace(_ id: String) {
        workspaceId = id
        guard !isNewSessionAction else { return }
        targetSessionId = connection.sessionStore.listProjectionSessions(workspaceId: id).first?.id ?? ""
    }

    func loadAgents(apiClient: APIClient?) async {
        guard let apiClient else { return }
        do {
            agents = try await apiClient.listAgents()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Saving

    /// The saved schedule and its summary, as the server returned them. Nil
    /// when the save failed; `error` says why.
    struct Saved {
        let schedule: AgentSchedule
        let summary: AgentScheduleSummary
    }

    func save(apiClient: APIClient?) async -> Saved? {
        guard let apiClient else {
            error = "Server is offline"
            return nil
        }
        guard let trigger = triggerDraft.makeTrigger() else {
            error = "Choose a supported schedule cadence"
            return nil
        }

        guard let schedule else { return await create(trigger: trigger, apiClient: apiClient) }
        let action: AgentScheduleAction
        switch schedule.action {
        case .newSession(_, _, _, _, _, let worktreeId, _):
            action = .newSession(
                workspaceId: workspaceId,
                prompt: prompt,
                agentId: agentId.managementNilIfBlank,
                model: model.managementNilIfBlank,
                thinkingLevel: thinkingLevel,
                worktreeId: worktreeId,
                name: sessionName.managementNilIfBlank
            )
        case .existingSession:
            action = .existingSession(
                workspaceId: workspaceId,
                sessionId: targetSessionId,
                prompt: prompt,
                streamingBehavior: streamingBehavior
            )
        }

        isSaving = true
        defer { isSaving = false }
        do {
            let summary = try await apiClient.updateAgentScheduleNative(
                scheduleId: schedule.id,
                name: name,
                trigger: trigger,
                action: action,
                // The version this form opened: a prompt edited elsewhere meanwhile
                // is a conflict, not a silent overwrite.
                expectedVersion: schedule.version
            )
            var updated = schedule
            updated.name = summary.name
            updated.trigger = trigger
            updated.action = action
            updated.version = summary.version
            updated.updatedAt = summary.updatedAt
            return Saved(schedule: updated, summary: summary)
        } catch {
            self.error = RecordVersionConflict.message(for: error) ?? error.localizedDescription
            return nil
        }
    }

    /// A new schedule that starts a session in the chosen workspace.
    private func create(trigger: AgentScheduleTrigger, apiClient: APIClient) async -> Saved? {
        let action = AgentScheduleAction.newSession(
            workspaceId: workspaceId,
            prompt: prompt,
            agentId: agentId.managementNilIfBlank,
            model: model.managementNilIfBlank,
            thinkingLevel: thinkingLevel,
            worktreeId: nil,
            name: sessionName.managementNilIfBlank
        )
        isSaving = true
        defer { isSaving = false }
        do {
            let summary = try await apiClient.createAgentSchedule(name: name, trigger: trigger, action: action)
            let created = AgentSchedule(
                id: summary.id,
                name: summary.name,
                status: summary.status,
                trigger: trigger,
                action: action,
                version: summary.version,
                createdAt: summary.createdAt,
                updatedAt: summary.updatedAt,
                archivedAt: summary.archivedAt
            )
            return Saved(schedule: created, summary: summary)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
