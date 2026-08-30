import Foundation

enum MacCatalogAgentRow: Equatable, Identifiable {
    case pi
    case saved(AgentDefinitionSummary)

    var id: String {
        switch self {
        case .pi: "pi"
        case .saved(let agent): agent.id
        }
    }

    var title: String {
        switch self {
        case .pi: "Pi"
        case .saved(let agent): agent.name
        }
    }

    var subtitle: String {
        switch self {
        case .pi:
            return "Server global configuration"
        case .saved(let agent):
            let description = agent.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let description, !description.isEmpty {
                return description
            }
            return "Saved Agent"
        }
    }
}

struct MacCatalogAgentListPresentation: Equatable {
    let query: String
    let rows: [MacCatalogAgentRow]

    static let emptyMessage = "No saved Agents on this server yet."

    init(agents: [AgentDefinitionSummary], query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = normalized
        let saved = agents.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return $0.id < $1.id
        }
        let matches = saved.filter { Self.matches($0, query: normalized) }
        var rows: [MacCatalogAgentRow] = []
        if normalized.isEmpty || "Pi".localizedCaseInsensitiveContains(normalized)
            || "global".localizedCaseInsensitiveContains(normalized) {
            rows.append(.pi)
        }
        rows.append(contentsOf: matches.map(MacCatalogAgentRow.saved))
        self.rows = rows
    }

    var isFilteredNoResults: Bool {
        !query.isEmpty && rows.isEmpty
    }

    var emptyMessage: String { Self.emptyMessage }

    private static func matches(_ agent: AgentDefinitionSummary, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [agent.name, agent.description]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct MacCatalogScheduleListPresentation: Equatable {
    let status: AgentScheduleStatus
    let query: String
    let rows: [AgentScheduleSummary]

    init(schedules: [AgentScheduleSummary], status: AgentScheduleStatus, query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = status
        self.query = normalized
        rows = schedules
            .filter { $0.status == status }
            .filter { Self.matches($0, query: normalized) }
            .sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                return $0.id < $1.id
            }
    }

    var isEmpty: Bool { rows.isEmpty && query.isEmpty }
    var isFilteredNoResults: Bool { !query.isEmpty && rows.isEmpty }

    func selectedID(keeping current: String?) -> String? {
        if let current, rows.contains(where: { $0.id == current }) {
            return current
        }
        return rows.first?.id
    }

    static func emptyMessage(for status: AgentScheduleStatus) -> String {
        switch status {
        case .active: "No active schedules on this server yet."
        case .paused: "No paused schedules."
        case .archived: "No archived schedules."
        }
    }

    var emptyMessage: String { Self.emptyMessage(for: status) }

    private static func matches(_ schedule: AgentScheduleSummary, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [
            schedule.name,
            schedule.trigger.displaySummary,
            schedule.trigger.scheduleScreenTiming(),
            schedule.action.type.displayName,
        ].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct MacCatalogListSection<Item: Identifiable & Equatable>: Equatable {
    let title: String
    let items: [Item]
}

struct MacCatalogSkillListPresentation: Equatable {
    let query: String
    let sections: [MacCatalogListSection<ServerSkillSummary>]

    static let emptyMessage = "Pi did not resolve any Skills on this server."

    init(skills: [ServerSkillSummary], query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = normalized
        let filtered = skills.filter { Self.matches($0, query: normalized) }
        let attention = Self.sorted(filtered.filter { $0.state == .error || $0.state == .unknown })
        let enabled = Self.sorted(filtered.filter { $0.state == .enabled })
        let disabled = Self.sorted(filtered.filter { $0.state == .disabled })
        sections = [
            attention.isEmpty ? nil : MacCatalogListSection(title: "Needs Attention", items: attention),
            enabled.isEmpty ? nil : MacCatalogListSection(title: "Enabled", items: enabled),
            disabled.isEmpty ? nil : MacCatalogListSection(title: "Disabled", items: disabled),
        ].compactMap { $0 }
    }

    var visible: [ServerSkillSummary] { sections.flatMap(\.items) }
    var isCatalogEmpty: Bool { sections.isEmpty && query.isEmpty }
    var isFilteredNoResults: Bool { !query.isEmpty && visible.isEmpty }
    var emptyMessage: String { Self.emptyMessage }

    static func stateLabel(for state: ServerSkillState) -> String {
        switch state {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .error, .unknown: "Error"
        }
    }

    private static func matches(_ skill: ServerSkillSummary, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var fields = [
            skill.name,
            skill.description,
            skill.provenance.label,
            stateLabel(for: skill.state),
        ]
        if let packageName = skill.packageName {
            fields.append(packageName)
        }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func sorted(_ skills: [ServerSkillSummary]) -> [ServerSkillSummary] {
        skills.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return $0.id < $1.id
        }
    }
}

struct MacCatalogExtensionListPresentation: Equatable {
    let query: String
    let sections: [MacCatalogListSection<ServerExtensionSummary>]

    static let emptyMessage = "Configure Pi extensions in ~/.pi/agent/extensions."

    init(extensions: [ServerExtensionSummary], query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = normalized
        let filtered = extensions.filter { Self.matches($0, query: normalized) }
        let builtIn = Self.sorted(filtered.filter { $0.kind == .builtIn })
        let normal = filtered.filter { $0.kind != .builtIn }
        let attention = Self.sorted(normal.filter { $0.state == .error || $0.state == .unknown })
        let enabled = Self.sorted(normal.filter { $0.state == .on })
        let disabled = Self.sorted(normal.filter { $0.state == .off })
        sections = [
            builtIn.isEmpty ? nil : MacCatalogListSection(title: "Built-in", items: builtIn),
            attention.isEmpty ? nil : MacCatalogListSection(title: "Needs Attention", items: attention),
            enabled.isEmpty ? nil : MacCatalogListSection(title: "Enabled Pi Extensions", items: enabled),
            disabled.isEmpty ? nil : MacCatalogListSection(title: "Disabled Pi Extensions", items: disabled),
        ].compactMap { $0 }
    }

    var visible: [ServerExtensionSummary] { sections.flatMap(\.items) }
    var hasNoPiExtensions: Bool {
        query.isEmpty && visible.allSatisfy { $0.kind == .builtIn } && !visible.isEmpty
    }
    var isFilteredNoResults: Bool { !query.isEmpty && visible.isEmpty }
    var emptyMessage: String { Self.emptyMessage }

    static func stateLabel(for state: ServerExtensionState) -> String {
        switch state {
        case .on: "On"
        case .off: "Off"
        case .error, .unknown: "Error"
        }
    }

    private static func matches(_ resource: ServerExtensionSummary, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [
            resource.name,
            resource.description,
            resource.packageName,
            resource.provenance.label,
            stateLabel(for: resource.state),
        ].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func sorted(_ resources: [ServerExtensionSummary]) -> [ServerExtensionSummary] {
        resources.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return $0.id < $1.id
        }
    }
}

enum MacCatalogContentState: Equatable {
    case loading
    case unavailable
    case empty
    case filteredNoResults
    case content

    static func resolve(
        hasLoaded: Bool,
        isLoading: Bool,
        lastError: String?,
        hasVisibleRows: Bool,
        isFilteredNoResults: Bool
    ) -> Self {
        if !hasLoaded {
            if lastError != nil { return .unavailable }
            return .loading
        }
        if isFilteredNoResults { return .filteredNoResults }
        if !hasVisibleRows {
            return lastError == nil ? .empty : .unavailable
        }
        return .content
    }
}

struct MacAgentEditorDraft: Equatable {
    var name: String
    var description: String
    var instructionMode: AgentInstructionMode
    var instructionText: String

    static func blank() -> Self {
        MacAgentEditorDraft(
            name: "",
            description: "",
            instructionMode: .append,
            instructionText: ""
        )
    }

    static func from(_ agent: StoredAgentDefinition) -> Self {
        MacAgentEditorDraft(
            name: agent.definition.name,
            description: agent.definition.description ?? "",
            instructionMode: agent.definition.instructions?.mode ?? .append,
            instructionText: agent.definition.instructions?.text ?? ""
        )
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func makeDefinition(preserving base: AgentDefinition? = nil) -> AgentDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        var definition = base ?? AgentDefinition(name: trimmedName)
        definition.name = trimmedName
        definition.description = trimmedDescription.isEmpty ? nil : trimmedDescription
        definition.instructions = trimmedInstructions.isEmpty
            ? nil
            : AgentInstructions(mode: instructionMode, text: trimmedInstructions)
        return definition
    }
}

struct MacScheduleEditorDraft: Equatable {
    enum Cadence: String, CaseIterable, Identifiable {
        case daily
        case hourly
        case everySixHours

        var id: String { rawValue }

        var title: String {
            switch self {
            case .daily: "Every day at 9:00"
            case .hourly: "Every hour"
            case .everySixHours: "Every 6 hours"
            }
        }

        var trigger: AgentScheduleTrigger {
            let timeZone = TimeZone.current.identifier
            switch self {
            case .daily:
                return .cron(expression: "0 9 * * *", timeZone: timeZone)
            case .hourly:
                return .every(intervalMs: 3_600_000, timeZone: timeZone)
            case .everySixHours:
                return .every(intervalMs: 21_600_000, timeZone: timeZone)
            }
        }

        static func matching(_ trigger: AgentScheduleTrigger) -> Self? {
            switch trigger {
            case .every(let intervalMs, _):
                if intervalMs == 3_600_000 { return .hourly }
                if intervalMs == 21_600_000 { return .everySixHours }
                return nil
            case .cron(let expression, _):
                let fields = expression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if fields == ["0", "9", "*", "*", "*"] { return .daily }
                return nil
            case .at:
                return nil
            }
        }
    }

    var name: String
    var prompt: String
    var workspaceId: String
    var cadence: Cadence
    var existingTrigger: AgentScheduleTrigger?
    var existingAction: AgentScheduleAction?

    static func blank(workspaceId: String) -> Self {
        MacScheduleEditorDraft(
            name: "",
            prompt: "",
            workspaceId: workspaceId,
            cadence: .daily
        )
    }

    static func from(_ schedule: AgentSchedule, fallbackWorkspaceId: String) -> Self {
        MacScheduleEditorDraft(
            name: schedule.name,
            prompt: schedule.action.prompt,
            workspaceId: schedule.action.workspaceId.isEmpty ? fallbackWorkspaceId : schedule.action.workspaceId,
            cadence: Cadence.matching(schedule.trigger) ?? .daily,
            existingTrigger: schedule.trigger,
            existingAction: schedule.action
        )
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workspaceId.isEmpty
    }

    var trigger: AgentScheduleTrigger {
        existingTrigger ?? cadence.trigger
    }

    var action: AgentScheduleAction {
        switch existingAction {
        case .newSession(_, _, let agentId, let model, let thinkingLevel, let worktreeId, let sessionName):
            return .newSession(
                workspaceId: workspaceId,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                agentId: agentId,
                model: model,
                thinkingLevel: thinkingLevel,
                worktreeId: worktreeId,
                name: sessionName
            )
        case .existingSession(_, let sessionId, _, let streamingBehavior):
            return .existingSession(
                workspaceId: workspaceId,
                sessionId: sessionId,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                streamingBehavior: streamingBehavior
            )
        case nil:
            return .newSession(
                workspaceId: workspaceId,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                agentId: nil,
                model: nil,
                thinkingLevel: nil,
                worktreeId: nil,
                name: nil
            )
        }
    }
}

enum MacControlSessionLaunchError: LocalizedError, Equatable {
    case unavailable
    case missingWorkspace
    case missingRequest
    case missingControlMetadata

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Local server is unavailable."
        case .missingWorkspace:
            "Choose a workspace first."
        case .missingRequest:
            "Describe the outcome you want."
        case .missingControlMetadata:
            "Server did not create a control session."
        }
    }
}

struct MacControlSessionLaunchDraft: Equatable {
    var domain: ControlSessionDomain
    var intent: ControlSessionIntent
    var targetId: String?
    var targetName: String?
    var workspaceId: String
    var workspaceName: String
    var userRequest: String
    var allowsEmptyRequest: Bool

    var canSubmit: Bool {
        if domain != .workspaces,
           workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        let trimmed = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowsEmptyRequest || !trimmed.isEmpty
    }

    var domainTitle: String {
        switch domain {
        case .agents: "Agent"
        case .schedules: "Schedule"
        case .skills: "Skill"
        case .workspaces: "Workspace"
        }
    }

    var title: String {
        intent == .revise ? "Revise \(targetName ?? domainTitle)" : "Create \(domainTitle)"
    }

    var placeholder: String {
        switch (domain, intent) {
        case (.agents, .create): "Describe a new Agent…"
        case (.agents, .revise): "Describe how this Agent should change…"
        case (.schedules, .create): "Describe what should happen and when…"
        case (.schedules, .revise): "Describe how this Schedule should change…"
        case (.workspaces, .create): "Describe a new Workspace…"
        case (.workspaces, .revise): "Describe how this Workspace should change…"
        default: "Describe the outcome you want…"
        }
    }

    var sessionName: String {
        if intent == .revise {
            return "Revise \(targetName ?? domainTitle)"
        }
        let request = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Create \(domainTitle)"
        guard !request.isEmpty else { return fallback }
        return "\(domainTitle): \(String(request.prefix(48)))"
    }

    var prompt: String {
        ControlSessionStarterPrompt.make(
            domain: domain,
            intent: intent,
            targetId: targetId,
            targetName: targetName,
            workspaceId: workspaceId.isEmpty ? nil : workspaceId,
            workspaceName: workspaceName.isEmpty ? nil : workspaceName,
            userRequest: userRequest
        )
    }
}

enum MacControlSessionLaunchPresentation {
    static func createAgent(workspace: Workspace?) -> MacControlSessionLaunchDraft {
        make(domain: .agents, intent: .create, workspace: workspace)
    }

    static func reviseAgent(_ agent: AgentDefinitionSummary, workspace: Workspace?) -> MacControlSessionLaunchDraft {
        make(
            domain: .agents,
            intent: .revise,
            targetId: agent.id,
            targetName: agent.name,
            workspace: workspace
        )
    }

    static func createSchedule(workspace: Workspace?) -> MacControlSessionLaunchDraft {
        make(domain: .schedules, intent: .create, workspace: workspace)
    }

    static func reviseSchedule(_ schedule: AgentScheduleSummary, workspace: Workspace?) -> MacControlSessionLaunchDraft {
        make(
            domain: .schedules,
            intent: .revise,
            targetId: schedule.id,
            targetName: schedule.name,
            workspace: workspace
        )
    }

    static func createWorkspace(workspace: Workspace?) -> MacControlSessionLaunchDraft {
        make(domain: .workspaces, intent: .create, workspace: workspace)
    }

    static func reviseWorkspace(_ workspace: Workspace) -> MacControlSessionLaunchDraft {
        make(
            domain: .workspaces,
            intent: .revise,
            targetId: workspace.id,
            targetName: workspace.name,
            workspace: workspace
        )
    }

    private static func make(
        domain: ControlSessionDomain,
        intent: ControlSessionIntent,
        targetId: String? = nil,
        targetName: String? = nil,
        workspace: Workspace?
    ) -> MacControlSessionLaunchDraft {
        MacControlSessionLaunchDraft(
            domain: domain,
            intent: intent,
            targetId: targetId,
            targetName: targetName,
            workspaceId: workspace?.id ?? "",
            workspaceName: workspace?.name ?? "",
            userRequest: "",
            allowsEmptyRequest: false
        )
    }
}
