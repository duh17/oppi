import Foundation

// MARK: - Agent Definitions

enum AgentDefinitionStatus: String, Codable, Sendable, Equatable {
    case active
    case archived
}

enum AgentInstructionMode: String, Codable, CaseIterable, Sendable, Equatable {
    case append
    case replace
}

struct AgentInstructions: Codable, Sendable, Equatable {
    var mode: AgentInstructionMode
    var text: String

    init(mode: AgentInstructionMode = .append, text: String) {
        self.mode = mode
        self.text = text
    }
}

/// One MCP server's tools: every one it reports, or the exact names it may call.
enum AgentMcpTools: Codable, Sendable, Equatable, Hashable {
    case all
    case tools([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self), value == "all" {
            self = .all
            return
        }
        self = .tools(try container.decode([String].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all: try container.encode("all")
        case .tools(let names): try container.encode(names)
        }
    }

    var toolNames: [String]? {
        guard case .tools(let names) = self else { return nil }
        return names
    }
}

/// What an Agent may do, not how Pi is wired to do it. Every field is optional and
/// omitted means the server's default: a normal session's tools, all enabled plugins,
/// every configured MCP server.
struct AgentCapabilities: Codable, Sendable, Equatable {
    /// The Pi tools this Agent's sessions start with, named as Pi's `defaultTools` names them.
    /// Omitted follows the server's Pi Tools setting; a list is this Agent's own set.
    var tools: [String]?
    var ask: Bool?
    var notify: Bool?
    var subagent: Bool?
    /// Plugin names. `[]` is none; omitted is every enabled plugin.
    var plugins: [String]?
    /// MCP servers by `mcp.json` name, and the tools each may call. `[:]` is none;
    /// omitted is every configured server.
    var mcp: [String: AgentMcpTools]?

    init(
        tools: [String]? = nil,
        ask: Bool? = nil,
        notify: Bool? = nil,
        subagent: Bool? = nil,
        plugins: [String]? = nil,
        mcp: [String: AgentMcpTools]? = nil
    ) {
        self.tools = tools
        self.ask = ask
        self.notify = notify
        self.subagent = subagent
        self.plugins = plugins
        self.mcp = mcp
    }

    /// The two Pi tools that change files: an Agent without them cannot write.
    static let writeToolNames = ["write", "edit"]

    /// Whether these tools leave the Agent unable to change files. Read-only is that, never a tier.
    var canEditFiles: Bool {
        guard let tools else { return true }
        return tools.contains { Self.writeToolNames.contains($0) }
    }

    var canAsk: Bool { ask ?? true }
    var canNotify: Bool { notify ?? true }
    var canDelegate: Bool { subagent ?? true }
}

/// What an Agent's session reads besides its own prompt.
struct AgentContext: Codable, Sendable, Equatable {
    /// Skill names: the folder that holds `SKILL.md`. Omitted is everything Pi discovers.
    var skills: [String]?
    /// The workspace's `AGENTS.md` and prompt. Default true.
    var contextFiles: Bool?
    /// `history://` and `agent://` reads. Default true.
    var sessionHistory: Bool?

    init(skills: [String]? = nil, contextFiles: Bool? = nil, sessionHistory: Bool? = nil) {
        self.skills = skills
        self.contextFiles = contextFiles
        self.sessionHistory = sessionHistory
    }

    var readsContextFiles: Bool { contextFiles ?? true }
    var readsSessionHistory: Bool { sessionHistory ?? true }
}

struct AgentLaunchConstraints: Codable, Sendable, Equatable {
    var allowedWorkspaceIds: [String]?
    var requiredRuntime: WorkspaceRuntime?
    /// Every launch runs on this engine; the server refuses another. Only `.durable` is set.
    var requiredEngine: SessionEngine?

    init(
        allowedWorkspaceIds: [String]? = nil,
        requiredRuntime: WorkspaceRuntime? = nil,
        requiredEngine: SessionEngine? = nil
    ) {
        self.allowedWorkspaceIds = allowedWorkspaceIds
        self.requiredRuntime = requiredRuntime
        self.requiredEngine = requiredEngine
    }

    func allows(_ workspace: Workspace) -> Bool {
        let actualRuntime = workspace.runtime ?? .host
        return (allowedWorkspaceIds?.contains(workspace.id) ?? true)
            && (requiredRuntime.map { $0 == actualRuntime } ?? true)
    }

    var isEmpty: Bool {
        allowedWorkspaceIds == nil && requiredRuntime == nil && requiredEngine == nil
    }
}

struct AgentSessionDefaults: Codable, Sendable, Equatable {
    var model: String?
    var thinkingLevel: ThinkingLevel?

    init(model: String? = nil, thinkingLevel: ThinkingLevel? = nil) {
        self.model = model
        self.thinkingLevel = thinkingLevel
    }

    var isEmpty: Bool {
        model?.isEmpty ?? true && thinkingLevel == nil
    }
}

struct AgentDefinition: Codable, Sendable, Equatable {
    var name: String
    var icon: IconChoice
    var description: String?
    var instructions: AgentInstructions?
    var capabilities: AgentCapabilities?
    var context: AgentContext?
    var sessionDefaults: AgentSessionDefaults?
    var launchConstraints: AgentLaunchConstraints?

    init(
        name: String,
        icon: IconChoice = .defaultValue,
        description: String? = nil,
        instructions: AgentInstructions? = nil,
        capabilities: AgentCapabilities? = nil,
        context: AgentContext? = nil,
        sessionDefaults: AgentSessionDefaults? = nil,
        launchConstraints: AgentLaunchConstraints? = nil
    ) {
        self.name = name
        self.icon = icon
        self.description = description
        self.instructions = instructions
        self.capabilities = capabilities
        self.context = context
        self.sessionDefaults = sessionDefaults
        self.launchConstraints = launchConstraints
    }

    private enum CodingKeys: String, CodingKey {
        case name, icon, description, instructions, capabilities, context, sessionDefaults, launchConstraints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(IconChoice.self, forKey: .icon) ?? .defaultValue
        description = try container.decodeIfPresent(String.self, forKey: .description)
        instructions = try container.decodeIfPresent(AgentInstructions.self, forKey: .instructions)
        capabilities = try container.decodeIfPresent(AgentCapabilities.self, forKey: .capabilities)
        context = try container.decodeIfPresent(AgentContext.self, forKey: .context)
        sessionDefaults = try container.decodeIfPresent(AgentSessionDefaults.self, forKey: .sessionDefaults)
        launchConstraints = try container.decodeIfPresent(AgentLaunchConstraints.self, forKey: .launchConstraints)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encodeIfPresent(sessionDefaults, forKey: .sessionDefaults)
        try container.encodeIfPresent(launchConstraints, forKey: .launchConstraints)
    }
}

struct AgentDefinitionSummary: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var icon: IconChoice
    var description: String?
    var launchConstraints: AgentLaunchConstraints? = nil
    var sessionDefaults: AgentSessionDefaults? = nil
    var status: AgentDefinitionStatus
    var version: Int
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
}

struct StoredAgentDefinition: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var icon: IconChoice
    var description: String?
    var status: AgentDefinitionStatus
    var version: Int
    var definition: AgentDefinition
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
}

extension AgentDefinitionSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, description, launchConstraints, sessionDefaults, status, version, createdAt, updatedAt, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(IconChoice.self, forKey: .icon) ?? .defaultValue
        description = try c.decodeIfPresent(String.self, forKey: .description)
        launchConstraints = try c.decodeIfPresent(AgentLaunchConstraints.self, forKey: .launchConstraints)
        sessionDefaults = try c.decodeIfPresent(AgentSessionDefaults.self, forKey: .sessionDefaults)
        status = try c.decode(AgentDefinitionStatus.self, forKey: .status)
        version = try c.decode(Int.self, forKey: .version)
        createdAt = try c.decodeUnixMilliseconds(forKey: .createdAt)
        updatedAt = try c.decodeUnixMilliseconds(forKey: .updatedAt)
        archivedAt = try c.decodeUnixMillisecondsIfPresent(forKey: .archivedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(launchConstraints, forKey: .launchConstraints)
        try c.encodeIfPresent(sessionDefaults, forKey: .sessionDefaults)
        try c.encode(status, forKey: .status)
        try c.encode(version, forKey: .version)
        try c.encodeUnixMilliseconds(createdAt, forKey: .createdAt)
        try c.encodeUnixMilliseconds(updatedAt, forKey: .updatedAt)
        try c.encodeUnixMillisecondsIfPresent(archivedAt, forKey: .archivedAt)
    }
}

extension StoredAgentDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, description, status, version, definition, createdAt, updatedAt, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(IconChoice.self, forKey: .icon) ?? .defaultValue
        description = try c.decodeIfPresent(String.self, forKey: .description)
        status = try c.decode(AgentDefinitionStatus.self, forKey: .status)
        version = try c.decode(Int.self, forKey: .version)
        definition = try c.decode(AgentDefinition.self, forKey: .definition)
        createdAt = try c.decodeUnixMilliseconds(forKey: .createdAt)
        updatedAt = try c.decodeUnixMilliseconds(forKey: .updatedAt)
        archivedAt = try c.decodeUnixMillisecondsIfPresent(forKey: .archivedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(status, forKey: .status)
        try c.encode(version, forKey: .version)
        try c.encode(definition, forKey: .definition)
        try c.encodeUnixMilliseconds(createdAt, forKey: .createdAt)
        try c.encodeUnixMilliseconds(updatedAt, forKey: .updatedAt)
        try c.encodeUnixMillisecondsIfPresent(archivedAt, forKey: .archivedAt)
    }
}

struct AgentListResponse: Decodable, Sendable, Equatable {
    let agents: [AgentDefinitionSummary]
}

struct AgentResponse: Decodable, Sendable, Equatable {
    let agent: StoredAgentDefinition
}

struct AgentLaunchReceipt: Decodable, Sendable, Equatable {
    var accepted: Bool
    var agentId: String?
    var agentVersion: Int?
    var sessionId: String?
    var parentSessionId: String?
    var idempotencyKey: String?
    var existing: Bool?
    var promptDispatch: String?
    var promptError: String?
    var retryable: Bool?
    var reason: String?
    var retryAfterMs: Int?

    init(
        accepted: Bool,
        agentId: String? = nil,
        agentVersion: Int? = nil,
        sessionId: String? = nil,
        parentSessionId: String? = nil,
        idempotencyKey: String? = nil,
        existing: Bool? = nil,
        promptDispatch: String? = nil,
        promptError: String? = nil,
        retryable: Bool? = nil,
        reason: String? = nil,
        retryAfterMs: Int? = nil
    ) {
        self.accepted = accepted
        self.agentId = agentId
        self.agentVersion = agentVersion
        self.sessionId = sessionId
        self.parentSessionId = parentSessionId
        self.idempotencyKey = idempotencyKey
        self.existing = existing
        self.promptDispatch = promptDispatch
        self.promptError = promptError
        self.retryable = retryable
        self.reason = reason
        self.retryAfterMs = retryAfterMs
    }
}

struct AgentSessionLaunchResponse: Decodable, Sendable, Equatable {
    let receipt: AgentLaunchReceipt
    let session: Session?
}

enum AgentLaunchRecoveryAction: String, Decodable, Sendable, Equatable {
    case editAgent = "edit_agent"
    case chooseWorkspace = "choose_workspace"
}

struct AgentLaunchRecovery: Decodable, Sendable, Equatable {
    let actions: [AgentLaunchRecoveryAction]
    let agentId: String
    let workspaceId: String
    let missingTools: [String]?
    let unavailableExtensions: [String]?
    let unavailableSkills: [String]?
    let allowedWorkspaceIds: [String]?
    let requiredRuntime: WorkspaceRuntime?
    let actualRuntime: WorkspaceRuntime?
}

struct AgentLaunchFailureResponse: Decodable, LocalizedError, Sendable, Equatable {
    let error: String
    let code: String
    let sessionId: String?
    let receipt: AgentLaunchReceipt
    let recovery: AgentLaunchRecovery

    var errorDescription: String? { error }
}

// MARK: - Schedules

enum AgentScheduleStatus: String, Codable, Sendable, Equatable {
    case active
    case paused
    case archived
}

enum AgentScheduleRunStatus: String, Codable, Sendable, Equatable {
    case pending
    case claimed
    case running
    case completed
    case failed
}

enum AgentScheduleRunKind: String, Codable, Sendable, Equatable {
    case due
    case manual
}

enum ExistingSessionStreamingBehavior: String, Codable, CaseIterable, Sendable, Equatable {
    case steer
    case followUp

    var displayName: String {
        switch self {
        case .steer:
            return "Steer"
        case .followUp:
            return "Follow-up"
        }
    }
}

enum AgentScheduleTrigger: Sendable, Hashable {
    case at(Date, timeZone: String)
    case every(intervalMs: Int64, timeZone: String)
    case cron(expression: String, timeZone: String)

    var timeZone: String {
        switch self {
        case .at(_, let timeZone), .every(_, let timeZone), .cron(_, let timeZone):
            return timeZone
        }
    }

    var displaySummary: String {
        switch self {
        case .at(let date, let timeZone):
            return "At \(date.formatted(date: .abbreviated, time: .shortened)) · \(timeZone)"
        case .every(let intervalMs, let timeZone):
            return "Every \(Self.intervalSummary(intervalMs)) · \(timeZone)"
        case .cron(let expression, let timeZone):
            return "Cron \(expression) · \(timeZone)"
        }
    }

    static func intervalSummary(_ intervalMs: Int64) -> String {
        let seconds = max(1, intervalMs / 1000)
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    /// How often it runs, without times: "One time", "Every 15m", "Weekdays", "Mondays".
    func scheduleScreenDays(locale: Locale = .current) -> String {
        switch self {
        case .at:
            return String(localized: "One time")
        case .every(let intervalMs, _):
            return "Every \(Self.intervalSummary(intervalMs))"
        case .cron:
            return cronDescription(locale: locale)?.days ?? String(localized: "Custom schedule")
        }
    }

    /// It runs on most days (at least five a week): a routine that a month view leaves
    /// unmarked, where a one-time or weekly run is an occasion.
    var runsMostDays: Bool {
        switch self {
        case .at: false
        case .every(let intervalMs, _): intervalMs <= 86_400_000
        case .cron: cronDescription(locale: .current)?.runsMostDays ?? false
        }
    }

    /// "Weekdays · 8:30 AM", "Every day · 9:00 AM & 5:00 PM", "Nov 11, 9:00 AM", "Every 2h".
    func scheduleScreenTiming(locale: Locale = .current) -> String {
        switch self {
        case .at(let date, let timeZone):
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
            formatter.setLocalizedDateFormatFromTemplate("MMMdhm")
            return formatter.string(from: date)
        case .every(let intervalMs, _):
            return "Every \(Self.intervalSummary(intervalMs))"
        case .cron:
            return cronDescription(locale: locale)?.text ?? String(localized: "Custom schedule")
        }
    }

    private func cronDescription(locale: Locale) -> ScheduleCronDescription? {
        guard case .cron(let expression, let timeZone) = self else { return nil }
        return ScheduleCronDescription(
            expression: expression, timeZone: TimeZone(identifier: timeZone) ?? .current, locale: locale
        )
    }

    /// Human timing for schedule detail. Never surfaces cron expressions.
    /// Appends a friendly timezone label when the schedule TZ differs from the device.
    func detailTimingSummary(
        locale: Locale = .current,
        deviceTimeZone: TimeZone = .current
    ) -> String {
        let timing = scheduleScreenTiming(locale: locale)
        guard let scheduleTimeZone = TimeZone(identifier: timeZone) else { return timing }
        if scheduleTimeZone.identifier == deviceTimeZone.identifier {
            return timing
        }
        let zoneLabel = Self.friendlyTimeZoneLabel(scheduleTimeZone, locale: locale)
        return zoneLabel.map { "\(timing) · \($0)" } ?? timing
    }

    private static func friendlyTimeZoneLabel(_ timeZone: TimeZone, locale: Locale) -> String? {
        if let city = timeZone.localizedName(for: .generic, locale: locale), !city.isEmpty {
            return city
        }
        let identifier = timeZone.identifier
        if let city = identifier.split(separator: "/").last.map(String.init)?
            .replacingOccurrences(of: "_", with: " "),
           !city.isEmpty {
            return city
        }
        return nil
    }

}

extension AgentScheduleTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, at, intervalMs, expression, timeZone
    }

    private enum TriggerType: String, Codable {
        case at
        case every
        case cron
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(TriggerType.self, forKey: .type)
        let timeZone = try c.decode(String.self, forKey: .timeZone)
        switch type {
        case .at:
            self = .at(try c.decodeUnixMilliseconds(forKey: .at), timeZone: timeZone)
        case .every:
            self = .every(intervalMs: try c.decode(Int64.self, forKey: .intervalMs), timeZone: timeZone)
        case .cron:
            self = .cron(expression: try c.decode(String.self, forKey: .expression), timeZone: timeZone)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .at(let date, let timeZone):
            try c.encode(TriggerType.at, forKey: .type)
            try c.encodeUnixMilliseconds(date, forKey: .at)
            try c.encode(timeZone, forKey: .timeZone)
        case .every(let intervalMs, let timeZone):
            try c.encode(TriggerType.every, forKey: .type)
            try c.encode(intervalMs, forKey: .intervalMs)
            try c.encode(timeZone, forKey: .timeZone)
        case .cron(let expression, let timeZone):
            try c.encode(TriggerType.cron, forKey: .type)
            try c.encode(expression, forKey: .expression)
            try c.encode(timeZone, forKey: .timeZone)
        }
    }
}

enum AgentScheduleAction: Sendable, Equatable {
    case newSession(
        workspaceId: String,
        prompt: String,
        agentId: String?,
        model: String?,
        thinkingLevel: ThinkingLevel?,
        worktreeId: String?,
        name: String?
    )
    case existingSession(
        workspaceId: String,
        sessionId: String,
        prompt: String,
        streamingBehavior: ExistingSessionStreamingBehavior?
    )

    var workspaceId: String {
        switch self {
        case .newSession(let workspaceId, _, _, _, _, _, _),
             .existingSession(let workspaceId, _, _, _):
            return workspaceId
        }
    }

    var prompt: String {
        switch self {
        case .newSession(_, let prompt, _, _, _, _, _),
             .existingSession(_, _, let prompt, _):
            return prompt
        }
    }

    var summaryType: AgentScheduleActionKind {
        switch self {
        case .newSession:
            return .newSession
        case .existingSession:
            return .existingSession
        }
    }
}

enum AgentScheduleActionKind: String, Codable, Sendable, Equatable {
    case newSession = "new_session"
    case existingSession = "existing_session"

    var displayName: String {
        switch self {
        case .newSession:
            return "New session"
        case .existingSession:
            return "Existing session"
        }
    }
}

extension AgentScheduleAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, workspaceId, sessionId, prompt, agentId, model, thinkingLevel, worktreeId, name, streamingBehavior
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(AgentScheduleActionKind.self, forKey: .type)
        switch type {
        case .newSession:
            self = .newSession(
                workspaceId: try c.decode(String.self, forKey: .workspaceId),
                prompt: try c.decode(String.self, forKey: .prompt),
                agentId: try c.decodeIfPresent(String.self, forKey: .agentId),
                model: try c.decodeIfPresent(String.self, forKey: .model),
                thinkingLevel: try c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel),
                worktreeId: try c.decodeIfPresent(String.self, forKey: .worktreeId),
                name: try c.decodeIfPresent(String.self, forKey: .name)
            )
        case .existingSession:
            self = .existingSession(
                workspaceId: try c.decode(String.self, forKey: .workspaceId),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                prompt: try c.decode(String.self, forKey: .prompt),
                streamingBehavior: try c.decodeIfPresent(ExistingSessionStreamingBehavior.self, forKey: .streamingBehavior)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .newSession(
            let workspaceId,
            let prompt,
            let agentId,
            let model,
            let thinkingLevel,
            let worktreeId,
            let name
        ):
            try c.encode(AgentScheduleActionKind.newSession, forKey: .type)
            try c.encode(workspaceId, forKey: .workspaceId)
            try c.encode(prompt, forKey: .prompt)
            try c.encodeIfPresent(agentId, forKey: .agentId)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
            try c.encodeIfPresent(worktreeId, forKey: .worktreeId)
            try c.encodeIfPresent(name, forKey: .name)
        case .existingSession(let workspaceId, let sessionId, let prompt, let streamingBehavior):
            try c.encode(AgentScheduleActionKind.existingSession, forKey: .type)
            try c.encode(workspaceId, forKey: .workspaceId)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(prompt, forKey: .prompt)
            try c.encodeIfPresent(streamingBehavior, forKey: .streamingBehavior)
        }
    }
}

struct AgentScheduleActionSummary: Codable, Sendable, Equatable {
    var type: AgentScheduleActionKind
    var workspaceId: String
    var sessionId: String?
    var agentId: String?
    var promptChars: Int
}

struct AgentScheduleSummary: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var status: AgentScheduleStatus
    var trigger: AgentScheduleTrigger
    var action: AgentScheduleActionSummary
    /// The definition's version, bumped when the definition changes. Nil on a
    /// server from before schedules had one: an edit then sends no
    /// `expectedVersion`, and a prompt has no pencil (no tag to condition on).
    var version: Int? = nil
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
}

struct AgentSchedule: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var status: AgentScheduleStatus
    var trigger: AgentScheduleTrigger
    var action: AgentScheduleAction
    /// The definition's version, bumped when the definition changes. Nil on a
    /// server from before schedules had one: an edit then sends no
    /// `expectedVersion`, and a prompt has no pencil (no tag to condition on).
    var version: Int? = nil
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
}

extension AgentScheduleSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, status, trigger, action, version, createdAt, updatedAt, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(AgentScheduleStatus.self, forKey: .status)
        trigger = try c.decode(AgentScheduleTrigger.self, forKey: .trigger)
        action = try c.decode(AgentScheduleActionSummary.self, forKey: .action)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        createdAt = try c.decodeUnixMilliseconds(forKey: .createdAt)
        updatedAt = try c.decodeUnixMilliseconds(forKey: .updatedAt)
        archivedAt = try c.decodeUnixMillisecondsIfPresent(forKey: .archivedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeUnixMilliseconds(createdAt, forKey: .createdAt)
        try c.encodeUnixMilliseconds(updatedAt, forKey: .updatedAt)
        try c.encodeUnixMillisecondsIfPresent(archivedAt, forKey: .archivedAt)
    }
}

extension AgentSchedule: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, status, trigger, action, version, createdAt, updatedAt, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(AgentScheduleStatus.self, forKey: .status)
        trigger = try c.decode(AgentScheduleTrigger.self, forKey: .trigger)
        action = try c.decode(AgentScheduleAction.self, forKey: .action)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        createdAt = try c.decodeUnixMilliseconds(forKey: .createdAt)
        updatedAt = try c.decodeUnixMilliseconds(forKey: .updatedAt)
        archivedAt = try c.decodeUnixMillisecondsIfPresent(forKey: .archivedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeUnixMilliseconds(createdAt, forKey: .createdAt)
        try c.encodeUnixMilliseconds(updatedAt, forKey: .updatedAt)
        try c.encodeUnixMillisecondsIfPresent(archivedAt, forKey: .archivedAt)
    }
}

struct AgentScheduleListResponse: Decodable, Sendable, Equatable {
    let schedules: [AgentScheduleSummary]
}

struct AgentScheduleSummaryResponse: Decodable, Sendable, Equatable {
    let schedule: AgentScheduleSummary
}

struct AgentScheduleResponse: Decodable, Sendable, Equatable {
    let schedule: AgentSchedule
}

struct AgentScheduleRunSummary: Identifiable, Sendable, Equatable {
    let id: String
    var scheduleId: String
    var kind: AgentScheduleRunKind
    var slotKey: String
    var idempotencyKey: String
    var status: AgentScheduleRunStatus
    var action: AgentScheduleActionSummary
    var createdAt: Date
    var updatedAt: Date
    var claimedAt: Date?
    var leaseOwner: String?
    var leaseExpiresAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    var sessionId: String?
    var promptDispatch: String?
    var error: String?
}

extension AgentScheduleRunSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, scheduleId, kind, slotKey, idempotencyKey, status, action
        case createdAt, updatedAt, claimedAt, leaseOwner, leaseExpiresAt, startedAt, completedAt
        case sessionId, promptDispatch, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        scheduleId = try c.decode(String.self, forKey: .scheduleId)
        kind = try c.decode(AgentScheduleRunKind.self, forKey: .kind)
        slotKey = try c.decode(String.self, forKey: .slotKey)
        idempotencyKey = try c.decode(String.self, forKey: .idempotencyKey)
        status = try c.decode(AgentScheduleRunStatus.self, forKey: .status)
        action = try c.decode(AgentScheduleActionSummary.self, forKey: .action)
        createdAt = try c.decodeUnixMilliseconds(forKey: .createdAt)
        updatedAt = try c.decodeUnixMilliseconds(forKey: .updatedAt)
        claimedAt = try c.decodeUnixMillisecondsIfPresent(forKey: .claimedAt)
        leaseOwner = try c.decodeIfPresent(String.self, forKey: .leaseOwner)
        leaseExpiresAt = try c.decodeUnixMillisecondsIfPresent(forKey: .leaseExpiresAt)
        startedAt = try c.decodeUnixMillisecondsIfPresent(forKey: .startedAt)
        completedAt = try c.decodeUnixMillisecondsIfPresent(forKey: .completedAt)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        promptDispatch = try c.decodeIfPresent(String.self, forKey: .promptDispatch)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(scheduleId, forKey: .scheduleId)
        try c.encode(kind, forKey: .kind)
        try c.encode(slotKey, forKey: .slotKey)
        try c.encode(idempotencyKey, forKey: .idempotencyKey)
        try c.encode(status, forKey: .status)
        try c.encode(action, forKey: .action)
        try c.encodeUnixMilliseconds(createdAt, forKey: .createdAt)
        try c.encodeUnixMilliseconds(updatedAt, forKey: .updatedAt)
        try c.encodeUnixMillisecondsIfPresent(claimedAt, forKey: .claimedAt)
        try c.encodeIfPresent(leaseOwner, forKey: .leaseOwner)
        try c.encodeUnixMillisecondsIfPresent(leaseExpiresAt, forKey: .leaseExpiresAt)
        try c.encodeUnixMillisecondsIfPresent(startedAt, forKey: .startedAt)
        try c.encodeUnixMillisecondsIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(promptDispatch, forKey: .promptDispatch)
        try c.encodeIfPresent(error, forKey: .error)
    }
}

struct AgentScheduleRunsResponse: Decodable, Sendable, Equatable {
    let runs: [AgentScheduleRunSummary]
}

struct AgentScheduleRunResponse: Decodable, Sendable, Equatable {
    let run: AgentScheduleRunSummary
}

// MARK: - Millisecond date coding

private extension KeyedDecodingContainer {
    func decodeUnixMilliseconds(forKey key: Key) throws -> Date {
        let milliseconds = try decode(Double.self, forKey: key)
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    func decodeUnixMillisecondsIfPresent(forKey key: Key) throws -> Date? {
        guard let milliseconds = try decodeIfPresent(Double.self, forKey: key) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeUnixMilliseconds(_ date: Date, forKey key: Key) throws {
        try encode(date.timeIntervalSince1970 * 1000, forKey: key)
    }

    mutating func encodeUnixMillisecondsIfPresent(_ date: Date?, forKey key: Key) throws {
        guard let date else { return }
        try encodeUnixMilliseconds(date, forKey: key)
    }
}
