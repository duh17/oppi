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

enum AgentNoToolsMode: String, Codable, CaseIterable, Sendable, Equatable {
    case all
    case builtin

    var displayName: String {
        switch self {
        case .all:
            return "No tools"
        case .builtin:
            return "No built-in tools"
        }
    }
}

struct AgentInstructions: Codable, Sendable, Equatable {
    var mode: AgentInstructionMode
    var text: String

    init(mode: AgentInstructionMode = .append, text: String) {
        self.mode = mode
        self.text = text
    }
}

struct AgentResourceFile: Codable, Sendable, Equatable, Identifiable {
    var path: String
    var content: String

    var id: String { path }
}

struct AgentResources: Codable, Sendable, Equatable {
    var agentsFiles: [AgentResourceFile]?
    var noContextFiles: Bool?
    /// Omitted inherits Pi discovery; an array is the Agent's exact Skill selection.
    var skillPaths: [String]?
    /// Omitted inherits Pi discovery; an array is the Agent's exact Extension selection.
    var extensionIds: [String]?

    init(
        agentsFiles: [AgentResourceFile]? = nil,
        noContextFiles: Bool? = nil,
        skillPaths: [String]? = nil,
        extensionIds: [String]? = nil
    ) {
        self.agentsFiles = agentsFiles
        self.noContextFiles = noContextFiles
        self.skillPaths = skillPaths
        self.extensionIds = extensionIds
    }

    var isEmpty: Bool {
        (agentsFiles?.isEmpty ?? true)
            && noContextFiles != true
            && skillPaths == nil
            && extensionIds == nil
    }
}

struct AgentLaunchConstraints: Codable, Sendable, Equatable {
    var allowedWorkspaceIds: [String]?
    var requiredRuntime: WorkspaceRuntime?

    init(
        allowedWorkspaceIds: [String]? = nil,
        requiredRuntime: WorkspaceRuntime? = nil
    ) {
        self.allowedWorkspaceIds = allowedWorkspaceIds
        self.requiredRuntime = requiredRuntime
    }

    func allows(_ workspace: Workspace) -> Bool {
        let actualRuntime = workspace.runtime ?? .host
        return (allowedWorkspaceIds?.contains(workspace.id) ?? true)
            && (requiredRuntime.map { $0 == actualRuntime } ?? true)
    }

    var isEmpty: Bool {
        allowedWorkspaceIds == nil && requiredRuntime == nil
    }
}

struct AgentSessionDefaults: Codable, Sendable, Equatable {
    var model: String?
    var thinkingLevel: ThinkingLevel?
    var tools: [String]?
    var excludeTools: [String]?
    var noTools: AgentNoToolsMode?

    init(
        model: String? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        tools: [String]? = nil,
        excludeTools: [String]? = nil,
        noTools: AgentNoToolsMode? = nil
    ) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.excludeTools = excludeTools
        self.noTools = noTools
    }

    var isEmpty: Bool {
        model?.isEmpty ?? true
            && thinkingLevel == nil
            && (tools?.isEmpty ?? true)
            && (excludeTools?.isEmpty ?? true)
            && noTools == nil
    }
}

struct AgentDefinition: Codable, Sendable, Equatable {
    var name: String
    var icon: IconChoice
    var description: String?
    var instructions: AgentInstructions?
    var resources: AgentResources?
    var sessionDefaults: AgentSessionDefaults?
    var launchConstraints: AgentLaunchConstraints?

    init(
        name: String,
        icon: IconChoice = .defaultValue,
        description: String? = nil,
        instructions: AgentInstructions? = nil,
        resources: AgentResources? = nil,
        sessionDefaults: AgentSessionDefaults? = nil,
        launchConstraints: AgentLaunchConstraints? = nil
    ) {
        self.name = name
        self.icon = icon
        self.description = description
        self.instructions = instructions
        self.resources = resources
        self.sessionDefaults = sessionDefaults
        self.launchConstraints = launchConstraints
    }

    private enum CodingKeys: String, CodingKey {
        case name, icon, description, instructions, resources, sessionDefaults, launchConstraints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(IconChoice.self, forKey: .icon) ?? .defaultValue
        description = try container.decodeIfPresent(String.self, forKey: .description)
        instructions = try container.decodeIfPresent(AgentInstructions.self, forKey: .instructions)
        resources = try container.decodeIfPresent(AgentResources.self, forKey: .resources)
        sessionDefaults = try container.decodeIfPresent(AgentSessionDefaults.self, forKey: .sessionDefaults)
        launchConstraints = try container.decodeIfPresent(AgentLaunchConstraints.self, forKey: .launchConstraints)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encodeIfPresent(resources, forKey: .resources)
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
        case id, name, icon, description, launchConstraints, status, version, createdAt, updatedAt, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(IconChoice.self, forKey: .icon) ?? .defaultValue
        description = try c.decodeIfPresent(String.self, forKey: .description)
        launchConstraints = try c.decodeIfPresent(AgentLaunchConstraints.self, forKey: .launchConstraints)
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
    let sessionId: String
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

enum AgentScheduleTrigger: Sendable, Equatable {
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

    var scheduleScreenCadence: String {
        switch self {
        case .at:
            return "ONE TIME"
        case .every:
            return "REPEATS"
        case .cron(let expression, _):
            let fields = Self.normalizedCronFields(expression)
            if Self.dailyCronTimes(fields) != nil { return "DAILY" }
            if Self.weeklyCronTime(fields) != nil { return "WEEKLY" }
            return "CUSTOM"
        }
    }

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
        case .cron(let expression, let timeZone):
            let fields = Self.normalizedCronFields(expression)
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
            formatter.setLocalizedDateFormatFromTemplate("hm")

            if let times = Self.dailyCronTimes(fields) {
                let formattedTimes = times.compactMap { time in
                    Self.timeOnlyDate(hour: time.hour, minute: time.minute, timeZone: formatter.timeZone)
                        .map(formatter.string(from:))
                }
                if formattedTimes.count == times.count {
                    return "Every day · \(formattedTimes.joined(separator: " & "))"
                }
            }
            if let weekly = Self.weeklyCronTime(fields),
               let date = Self.timeOnlyDate(hour: weekly.hour, minute: weekly.minute, timeZone: formatter.timeZone) {
                return "\(weekly.day) · \(formatter.string(from: date))"
            }
            return "Custom schedule"
        }
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

    private static func normalizedCronFields(_ expression: String) -> [String] {
        let fields = expression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return fields.count == 6 ? Array(fields.dropFirst()) : fields
    }

    private static func dailyCronTimes(_ fields: [String]) -> [(hour: Int, minute: Int)]? {
        guard fields.count == 5,
              fields[2] == "*", fields[3] == "*", fields[4] == "*",
              let minute = Int(fields[0]), (0...59).contains(minute) else { return nil }
        let hours = fields[1].split(separator: ",").compactMap { Int($0) }
        guard !hours.isEmpty,
              hours.count == fields[1].split(separator: ",").count,
              hours.allSatisfy({ (0...23).contains($0) }) else { return nil }
        return hours.map { (hour: $0, minute: minute) }
    }

    private static func weeklyCronTime(_ fields: [String]) -> (day: String, hour: Int, minute: Int)? {
        guard fields.count == 5,
              fields[2] == "*", fields[3] == "*",
              let rawDay = Int(fields[4]),
              let day = weekdayName(rawDay),
              let time = cronHourMinute(fields) else { return nil }
        return (day, time.hour, time.minute)
    }

    private static func cronHourMinute(_ fields: [String]) -> (hour: Int, minute: Int)? {
        guard fields.count >= 2,
              let minute = Int(fields[0]), (0...59).contains(minute),
              let hour = Int(fields[1]), (0...23).contains(hour) else { return nil }
        return (hour, minute)
    }

    private static func weekdayName(_ rawValue: Int) -> String? {
        switch rawValue == 7 ? 0 : rawValue {
        case 0: return "Sundays"
        case 1: return "Mondays"
        case 2: return "Tuesdays"
        case 3: return "Wednesdays"
        case 4: return "Thursdays"
        case 5: return "Fridays"
        case 6: return "Saturdays"
        default: return nil
        }
    }

    private static func timeOnlyDate(hour: Int, minute: Int, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute))
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
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
}

extension AgentScheduleSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, status, trigger, action, createdAt, updatedAt, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(AgentScheduleStatus.self, forKey: .status)
        trigger = try c.decode(AgentScheduleTrigger.self, forKey: .trigger)
        action = try c.decode(AgentScheduleActionSummary.self, forKey: .action)
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
        try c.encodeUnixMilliseconds(createdAt, forKey: .createdAt)
        try c.encodeUnixMilliseconds(updatedAt, forKey: .updatedAt)
        try c.encodeUnixMillisecondsIfPresent(archivedAt, forKey: .archivedAt)
    }
}

extension AgentSchedule: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, status, trigger, action, createdAt, updatedAt, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(AgentScheduleStatus.self, forKey: .status)
        trigger = try c.decode(AgentScheduleTrigger.self, forKey: .trigger)
        action = try c.decode(AgentScheduleAction.self, forKey: .action)
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
