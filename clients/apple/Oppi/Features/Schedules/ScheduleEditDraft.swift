import Foundation
import Observation

/// What Edit Schedule edits: the draft Save sends and Cancel drops. Fields of
/// both kinds of schedule live here; the editor shows the ones its action uses.
@MainActor @Observable
final class ScheduleEditDraft {
    let schedule: AgentSchedule
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

    // MARK: - What the editor shows

    var isNewSessionAction: Bool {
        if case .newSession = schedule.action { return true }
        return false
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workspaceId.isEmpty
            && (isNewSessionAction || !targetSessionId.isEmpty)
            && triggerDraft.canSave
            && !isSaving
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
                action: action
            )
            var updated = schedule
            updated.name = summary.name
            updated.trigger = trigger
            updated.action = action
            updated.updatedAt = summary.updatedAt
            return Saved(schedule: updated, summary: summary)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
