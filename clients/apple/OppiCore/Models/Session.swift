import Foundation

/// Session status matching server's `Session.status`.
enum SessionStatus: String, Codable, Sendable {
    case starting
    case ready
    case busy
    case stopping
    case stopped
    case error

    var isRunning: Bool {
        self == .busy || self == .stopping
    }

    var isTerminal: Bool {
        self == .ready || self == .stopped || self == .error
    }
}

/// OSC 7501 program status state, matching the server's `ProgramStatusState`.
///
/// Lifecycle `SessionStatus` drives controls; status surfaces read this. A value a later
/// server adds decodes as `.unknown` instead of failing the session row.
enum ProgramStatusState: Sendable, Hashable, Codable {
    case idle
    case working
    case done
    case blocked
    case error
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "idle": self = .idle
        case "working": self = .working
        case "done": self = .done
        case "blocked": self = .blocked
        case "error": self = .error
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .blocked: "blocked"
        case .error: "error"
        case .unknown(let value): value
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Why a `blocked` program waits, matching the server's `ProgramStatusKind`.
/// Unknown future kinds decode as `.unknown`.
enum ProgramStatusKind: Sendable, Hashable, Codable {
    case permission
    case question
    case auth
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "permission": self = .permission
        case "question": self = .question
        case "auth": self = .auth
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .permission: "permission"
        case .question: "question"
        case .auth: "auth"
        case .unknown(let value): value
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Server-derived OSC 7501 program status for a session. `message` is one line (session
/// name, dialog title, or first error line) and is never a prompt or model output.
/// `since` arrives as Unix milliseconds.
struct ProgramStatus: Sendable, Equatable, Codable {
    var state: ProgramStatusState
    /// Present for `blocked` only.
    var kind: ProgramStatusKind?
    var message: String?
    var since: Date

    init(
        state: ProgramStatusState,
        kind: ProgramStatusKind? = nil,
        message: String? = nil,
        since: Date
    ) {
        self.state = state
        self.kind = kind
        self.message = message
        self.since = since
    }

    private enum CodingKeys: String, CodingKey {
        case state, kind, message, since
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(ProgramStatusState.self, forKey: .state)
        // A kind that is not a string is malformed; the field is optional detail, so drop it.
        kind = (try? container.decodeIfPresent(ProgramStatusKind.self, forKey: .kind)) ?? nil
        message = try container.decodeIfPresent(String.self, forKey: .message)
        since = Date(
            timeIntervalSince1970: try container.decode(Double.self, forKey: .since) / 1000
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encode(since.timeIntervalSince1970 * 1000, forKey: .since)
    }
}

/// Agent engine behind a managed session. Summaries carry `engine: "durable"`;
/// full `Session` payloads mark the durable engine with `serverDurable`. The control
/// conversation also carries `serverDurable.role: "control"` on both. Absent is classic.
enum SessionEngine: String, Codable, Sendable {
    case classic
    case durable
}

enum SessionRuntimeKind: String, Codable, Sendable {
    case oppi
    case piTui = "pi-tui"

    /// Persist writes Pi user settings. Mirrored TUI sessions cannot do that through Oppi.
    var supportsPersistingDefaults: Bool { self != .piTui }

    static let persistUnsupportedMessage = "Mirrored Pi sessions cannot save a global default."
}

struct PiTuiMirrorTerminalInfo: Codable, Sendable, Equatable {
    var bridgeId: String?
    var hostname: String?
    var pid: Int?
    var cwd: String?
    var connectedAt: Double?
    var lastSeenAt: Double?
    var disconnectedAt: Double?
}

struct PiTuiMirrorSessionMetadata: Codable, Sendable, Equatable {
    var status: String
    var terminal: PiTuiMirrorTerminalInfo?
    var capabilities: [String]?
    var protocolVersion: Int?
}

enum ControlSessionDomain: String, Codable, Sendable {
    case agents
    case schedules
    case skills
    case workspaces
}

enum ControlSessionIntent: String, Codable, Sendable {
    case create
    case revise
}

struct ControlSessionMetadata: Codable, Sendable, Equatable {
    let domain: ControlSessionDomain
    let intent: ControlSessionIntent
    let targetId: String?
    let targetName: String?
}

/// Presentation-only subset of immutable session launch metadata.
/// Execution identity remains server-owned through Agent ID and version.
struct SessionLaunchMetadata: Codable, Sendable, Equatable {
    var agentId: String?
    var agentIcon: IconChoice?
}

/// Selects the server route family for operations on a focused session.
enum SessionRouteScope: Sendable, Hashable {
    case workspace(String)
    case control

    var workspaceId: String? {
        guard case .workspace(let id) = self else { return nil }
        return id
    }

    var composerDraftScopeID: String {
        switch self {
        case .workspace(let id): id
        case .control: "__oppi_control__"
        }
    }
}

enum ControlSessionStarterPrompt {
    static func make(
        domain: ControlSessionDomain,
        intent: ControlSessionIntent,
        targetId: String? = nil,
        targetName: String? = nil,
        targetPath: String? = nil,
        workspaceId: String? = nil,
        workspaceName: String? = nil,
        userRequest: String? = nil
    ) -> String {
        let subject = switch domain {
        case .agents: "saved Agent"
        case .schedules: "Schedule"
        case .skills: "Skill"
        case .workspaces: "Workspace"
        }
        let target = intent == .revise
            ? "\nCanonical target ID: \(targetId ?? "unknown")\nCanonical target name: \(targetName ?? "unknown")"
            : ""
        let workspace = workspaceId.map {
            "\nCanonical workspace ID: \($0)\nCanonical workspace name: \(workspaceName ?? "unknown")"
        } ?? ""
        let selectedHostFile = domain == .skills
            ? "\nSelected existing host file: \(targetPath ?? "unknown")"
            : ""
        let workflow = switch domain {
        case .agents:
            "Use the `oppi agent` command family to list and inspect existing definitions, then create or update the proposed definition. If Agent behavior is ambiguous, ask focused questions about responsibilities, boundaries, resources, defaults, and success criteria."
        case .schedules:
            "Use the `oppi schedule` command family to list and inspect existing schedules, then create or update the proposed schedule. If schedule behavior or timing is ambiguous, ask focused questions about the task, target workspace or session, cadence, time zone, safety constraints, and expected output. Every model change must use a canonical `provider/model` ID. If the user omits the provider and inspected server state does not identify it, ask one focused provider question before proposing the change; do not guess. Once the provider is known, name the canonical ID and use `oppi schedule update <id> --model <provider/model>` for a model-only update instead of embedding the model in definition JSON."
        case .skills:
            "Use stock `read` to inspect the selected launch file. Staged review comments carry absolute source paths; use each comment’s path when it refers to another file, and use stock `edit` for precise replacements in those existing files. Do not use `oppi` to read or update Skill files."
        case .workspaces:
            "Use the `oppi workspace` command family to inspect existing workspaces, then create or update the proposed workspace. Ask focused questions about paths, runtime, and access when they are ambiguous."
        }
        let definitionRequirement = switch (domain, intent) {
        case (.agents, _):
            " Pass definition changes directly with `--definition-json`; do not use a definition file."
        case (.schedules, .revise):
            " Pass non-model definition changes directly with `--definition-json`; do not use a definition file."
        default:
            ""
        }

        let request = userRequest?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestBlock = request.flatMap { $0.isEmpty ? nil : "\n\nUser request:\n\($0)" } ?? ""

        return """
        Help the user \(intent == .create ? "create" : "revise") an Oppi \(subject).\(target)\(workspace)\(selectedHostFile)

        \(domain == .skills ? "Act as Oppi. " : "Act as Oppi. First inspect the current server state using only approved `oppi` commands. ")\(workflow)\(domain == .skills ? " Summarize the exact proposed changes before editing." : " Summarize the exact proposed changes and wait for the user's explicit approval before invoking the appropriate `oppi` command.")\(definitionRequirement)

        \(domain == .skills ? "Do not use `write`, `bash`, or temporary files for this task. Do not edit paths other than the selected launch file or the absolute paths carried by staged review comments." : "Do not use filesystem tools or temporary files for this task.")\(requestBlock)
        """
    }
}

/// Session model matching server's `Session` type.
///
/// Server sends timestamps as Unix milliseconds (not ISO 8601).
/// Manual Decodable handles the conversion.
struct Session: Identifiable, Sendable, Equatable {
    let id: String
    var workspaceId: String?
    var workspaceName: String?
    var worktreeId: String? = nil
    var name: String?
    var status: SessionStatus
    let createdAt: Date
    var lastActivity: Date
    var lastAgentReplyAt: Date? = nil
    var currentTurnStartedAt: Date? = nil
    /// Server-derived program status; absent on servers that predate it.
    var programStatus: ProgramStatus? = nil
    var model: String?

    var messageCount: Int
    var tokens: TokenUsage
    var cost: Double
    var changeStats: SessionChangeStats? = nil

    // Context usage (pi TUI-style status bar)
    var contextTokens: Int?    // context size the server derived from the last message usage
    var contextWindow: Int?    // model's total context window

    var firstMessage: String?
    var lastMessage: String?

    // Agent config state (synced from pi get_state)
    var thinkingLevel: String?

    // Runtime ownership
    var runtime: SessionRuntimeKind? = nil
    var supportsPersistingDefaults: Bool { runtime != .piTui }
    var mirror: PiTuiMirrorSessionMetadata? = nil
    var control: ControlSessionMetadata? = nil
    var launch: SessionLaunchMetadata? = nil
    /// Launching session; the inbox groups session threads by this edge.
    var parentSessionId: String? = nil

    // Privacy / persistence
    var ephemeral: Bool?

    /// Non-fatal session notices from the server. Not part of SessionSummary.
    var warnings: [String]? = nil

    var engine: SessionEngine = .classic

    /// `serverDurable.role` when the server sent one. `"control"` is the durable
    /// control conversation. Unknown roles stay stored and are not a control route.
    var serverDurableRole: String? = nil

    /// Durable control conversation. Distinct from a declared Pi Control session (`control != nil`).
    var isControlConversation: Bool { serverDurableRole == "control" }

    /// Display title: name, first message preview, or session ID prefix.
    var displayTitle: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let firstMessage = firstMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstMessage.isEmpty {
            return String(firstMessage.prefix(80))
        }
        return "Session \(String(id.prefix(8)))"
    }

    /// Newly created draft session with no prompt sent yet.
    ///
    /// Older servers persisted these as `.starting`, while newer ones return
    /// `.ready`. In both cases the user-facing state is idle / awaiting input,
    /// not actively working.
    var isAwaitingFirstPrompt: Bool {
        guard messageCount == 0 else { return false }
        guard firstMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else {
            return false
        }
        guard lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else {
            return false
        }

        switch status {
        case .starting, .ready:
            return true
        case .busy, .stopping, .stopped, .error:
            return false
        }
    }
}

struct TokenUsage: Codable, Sendable, Equatable {
    var input: Int
    var output: Int
    var cacheRead: Int?
    var cacheWrite: Int?
}

struct SessionChangeStats: Codable, Sendable, Equatable {
    var mutatingToolCalls: Int
    var compactionCount: Int? = nil
    var filesChanged: Int
    var changedFiles: [String]
    var changedFilesOverflow: Int?
    var addedLines: Int
    var removedLines: Int
}

struct SessionSummaryAttentionCounts: Sendable, Equatable {
    var pendingAskCount: Int

    static let none = SessionSummaryAttentionCounts(pendingAskCount: 0)

    var hasAttention: Bool {
        pendingAskCount > 0
    }
}

/// Cold-lane projection for workspace lists and cross-session status surfaces.
///
/// Unlike full `Session` state, summaries are intended to be sparse and
/// low-frequency. Timeline deltas should not require this model to change.
struct SessionSummary: Sendable, Equatable {
    let id: String
    var workspaceId: String?
    var workspaceName: String?
    var worktreeId: String? = nil
    var name: String?
    var status: SessionStatus
    let createdAt: Date
    var lastActivity: Date
    var lastAgentReplyAt: Date?
    var currentTurnStartedAt: Date?
    var programStatus: ProgramStatus? = nil
    var model: String?
    var messageCount: Int
    var tokens: TokenUsage
    var cost: Double
    var changeStats: SessionChangeStats?
    var contextTokens: Int?
    var contextWindow: Int?
    var firstMessage: String?
    var lastMessage: String?
    var thinkingLevel: String?
    var runtime: SessionRuntimeKind? = nil
    var supportsPersistingDefaults: Bool { runtime != .piTui }
    var mirror: PiTuiMirrorSessionMetadata? = nil
    var control: ControlSessionMetadata? = nil
    var agentId: String? = nil
    var agentIcon: IconChoice? = nil
    var parentSessionId: String? = nil
    var ephemeral: Bool?
    var engine: SessionEngine = .classic
    var serverDurableRole: String? = nil
    var pendingAskCount: Int {
        didSet { hasPendingAskCount = true }
    }
    fileprivate(set) var hasPendingAskCount: Bool

    var attentionCounts: SessionSummaryAttentionCounts {
        SessionSummaryAttentionCounts(pendingAskCount: pendingAskCount)
    }

    var session: Session {
        Session(
            id: id,
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            worktreeId: worktreeId,
            name: name,
            status: status,
            createdAt: createdAt,
            lastActivity: lastActivity,
            lastAgentReplyAt: lastAgentReplyAt,
            currentTurnStartedAt: currentTurnStartedAt,
            programStatus: programStatus,
            model: model,
            messageCount: messageCount,
            tokens: tokens,
            cost: cost,
            changeStats: changeStats,
            contextTokens: contextTokens,
            contextWindow: contextWindow,
            firstMessage: firstMessage,
            lastMessage: lastMessage,
            thinkingLevel: thinkingLevel,
            runtime: runtime,
            mirror: mirror,
            control: control,
            launch: agentId.map { SessionLaunchMetadata(agentId: $0, agentIcon: agentIcon) },
            parentSessionId: parentSessionId,
            ephemeral: ephemeral,
            engine: engine,
            serverDurableRole: serverDurableRole
        )
    }
}

extension SessionSummary {
    init(from session: Session) {
        self.id = session.id
        self.workspaceId = session.workspaceId
        self.workspaceName = session.workspaceName
        self.worktreeId = session.worktreeId
        self.name = session.name
        self.status = session.status
        self.createdAt = session.createdAt
        self.lastActivity = session.lastActivity
        self.lastAgentReplyAt = session.lastAgentReplyAt
        self.currentTurnStartedAt = session.currentTurnStartedAt
        self.programStatus = session.programStatus
        self.model = session.model
        self.messageCount = session.messageCount
        self.tokens = session.tokens
        self.cost = session.cost
        self.changeStats = session.changeStats
        self.contextTokens = session.contextTokens
        self.contextWindow = session.contextWindow
        self.firstMessage = session.firstMessage
        self.lastMessage = session.lastMessage
        self.thinkingLevel = session.thinkingLevel
        self.runtime = session.runtime
        self.mirror = session.mirror
        self.control = session.control
        self.agentId = session.launch?.agentId
        self.agentIcon = session.launch?.agentIcon
        self.parentSessionId = session.parentSessionId
        self.ephemeral = session.ephemeral
        self.engine = session.engine
        self.serverDurableRole = session.serverDurableRole
        self.pendingAskCount = 0
        self.hasPendingAskCount = false
    }
}

private enum SessionWireCodingKeys: String, CodingKey {
    case id, workspaceId, workspaceName, worktreeId
    case name, status, createdAt, lastActivity, lastAgentReplyAt, currentTurnStartedAt
    case programStatus
    case model, messageCount, tokens, cost, changeStats
    case contextTokens, contextWindow, firstMessage, lastMessage
    case thinkingLevel, runtime, mirror, control, launch, agentId, agentIcon, parentSessionId, ephemeral, warnings
    case pendingAskCount
    case engine, serverDurable
}

private struct LaunchParentWire: Decodable {
    let parentSessionId: String?
}

private struct DecodedSessionWireFields {
    let id: String
    let workspaceId: String?
    let workspaceName: String?
    let worktreeId: String?
    let name: String?
    let status: SessionStatus
    let createdAt: Date
    let lastActivity: Date
    let lastAgentReplyAt: Date?
    let currentTurnStartedAt: Date?
    let programStatus: ProgramStatus?
    let model: String?
    let messageCount: Int
    let tokens: TokenUsage
    let cost: Double
    let changeStats: SessionChangeStats?
    let contextTokens: Int?
    let contextWindow: Int?
    let firstMessage: String?
    let lastMessage: String?
    let thinkingLevel: String?
    let runtime: SessionRuntimeKind?
    let mirror: PiTuiMirrorSessionMetadata?
    let control: ControlSessionMetadata?
    let launch: SessionLaunchMetadata?
    let agentId: String?
    let agentIcon: IconChoice?
    let parentSessionId: String?
    let ephemeral: Bool?
    let warnings: [String]?
    let engine: SessionEngine
    let serverDurableRole: String?

    init(from container: KeyedDecodingContainer<SessionWireCodingKeys>) throws {
        id = try container.decode(String.self, forKey: .id)
        workspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId)
        workspaceName = try container.decodeIfPresent(String.self, forKey: .workspaceName)
        worktreeId = try container.decodeIfPresent(String.self, forKey: .worktreeId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        status = try container.decode(SessionStatus.self, forKey: .status)
        createdAt = try container.decodeUnixMilliseconds(forKey: .createdAt)
        lastActivity = try container.decodeUnixMilliseconds(forKey: .lastActivity)
        lastAgentReplyAt = try container.decodeUnixMillisecondsIfPresent(forKey: .lastAgentReplyAt)
        currentTurnStartedAt = try container.decodeUnixMillisecondsIfPresent(forKey: .currentTurnStartedAt)
        // Malformed program status loses that field, never the row: status surfaces are display-only.
        programStatus = (try? container.decodeIfPresent(ProgramStatus.self, forKey: .programStatus)) ?? nil
        model = try container.decodeIfPresent(String.self, forKey: .model)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        tokens = try container.decode(TokenUsage.self, forKey: .tokens)
        cost = try container.decode(Double.self, forKey: .cost)
        changeStats = try container.decodeIfPresent(SessionChangeStats.self, forKey: .changeStats)
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        firstMessage = try container.decodeIfPresent(String.self, forKey: .firstMessage)
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
        thinkingLevel = try container.decodeIfPresent(String.self, forKey: .thinkingLevel)
        runtime = try container.decodeIfPresent(SessionRuntimeKind.self, forKey: .runtime)
        mirror = try container.decodeIfPresent(PiTuiMirrorSessionMetadata.self, forKey: .mirror)
        control = try container.decodeIfPresent(ControlSessionMetadata.self, forKey: .control)
        launch = try container.decodeIfPresent(SessionLaunchMetadata.self, forKey: .launch)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        agentIcon = try container.decodeIfPresent(IconChoice.self, forKey: .agentIcon)
        // Summaries carry the parent at the top level; full `Session` records
        // (connected/state) carry it under `launch`.
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
            ?? container.decodeIfPresent(LaunchParentWire.self, forKey: .launch)?.parentSessionId
        ephemeral = try container.decodeIfPresent(Bool.self, forKey: .ephemeral)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings)
        let serverDurable = try container.decodeIfPresent(ServerDurableWire.self, forKey: .serverDurable)
        // A present non-string role fails the session. An absent role is not the control conversation.
        serverDurableRole = serverDurable?.role
        // Summaries name the engine; full sessions carry the `serverDurable` enrollment.
        // An unknown future engine is not durable, so it reads as classic.
        if let engineName = try container.decodeIfPresent(String.self, forKey: .engine) {
            engine = SessionEngine(rawValue: engineName) ?? .classic
        } else if serverDurable != nil {
            engine = .durable
        } else {
            engine = .classic
        }
    }
}

private struct ServerDurableWire: Codable {
    var role: String?

    init(role: String?) {
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Absent role stays nil. A present non-string role is malformed.
        role = try container.decodeIfPresent(String.self, forKey: .role)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
    }

    private enum CodingKeys: String, CodingKey {
        case role
    }
}

private extension DecodedSessionWireFields {
    func makeSession() -> Session {
        let presentationLaunch = launch ?? agentId.map {
            SessionLaunchMetadata(agentId: $0, agentIcon: agentIcon)
        }
        return Session(
            id: id,
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            worktreeId: worktreeId,
            name: name,
            status: status,
            createdAt: createdAt,
            lastActivity: lastActivity,
            lastAgentReplyAt: lastAgentReplyAt,
            currentTurnStartedAt: currentTurnStartedAt,
            programStatus: programStatus,
            model: model,
            messageCount: messageCount,
            tokens: tokens,
            cost: cost,
            changeStats: changeStats,
            contextTokens: contextTokens,
            contextWindow: contextWindow,
            firstMessage: firstMessage,
            lastMessage: lastMessage,
            thinkingLevel: thinkingLevel,
            runtime: runtime,
            mirror: mirror,
            control: control,
            launch: presentationLaunch,
            parentSessionId: parentSessionId,
            ephemeral: ephemeral,
            warnings: warnings,
            engine: engine,
            serverDurableRole: serverDurableRole
        )
    }

    func makeSummary(pendingAskCount: Int?) -> SessionSummary {
        var summary = SessionSummary(from: makeSession())
        summary.pendingAskCount = pendingAskCount ?? 0
        summary.hasPendingAskCount = pendingAskCount != nil
        return summary
    }
}

private extension KeyedDecodingContainer where Key == SessionWireCodingKeys {
    func decodeUnixMilliseconds(forKey key: Key) throws -> Date {
        let milliseconds = try decode(Double.self, forKey: key)
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    func decodeUnixMillisecondsIfPresent(forKey key: Key) throws -> Date? {
        guard let milliseconds = try decodeIfPresent(Double.self, forKey: key) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

extension SessionSummary: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SessionWireCodingKeys.self)
        let fields = try DecodedSessionWireFields(from: container)
        self = fields.makeSummary(
            pendingAskCount: try container.decodeIfPresent(Int.self, forKey: .pendingAskCount)
        )
    }
}

// MARK: - Codable (Unix millisecond timestamps)

extension Session: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SessionWireCodingKeys.self)
        let fields = try DecodedSessionWireFields(from: container)
        self = fields.makeSession()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: SessionWireCodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try c.encodeIfPresent(workspaceName, forKey: .workspaceName)
        try c.encodeIfPresent(worktreeId, forKey: .worktreeId)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(messageCount, forKey: .messageCount)
        try c.encode(tokens, forKey: .tokens)
        try c.encode(cost, forKey: .cost)
        try c.encodeIfPresent(changeStats, forKey: .changeStats)
        try c.encodeIfPresent(programStatus, forKey: .programStatus)
        try c.encodeIfPresent(contextTokens, forKey: .contextTokens)
        try c.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try c.encodeIfPresent(firstMessage, forKey: .firstMessage)
        try c.encodeIfPresent(lastMessage, forKey: .lastMessage)
        try c.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(mirror, forKey: .mirror)
        try c.encodeIfPresent(control, forKey: .control)
        try c.encodeIfPresent(launch, forKey: .launch)
        try c.encodeIfPresent(parentSessionId, forKey: .parentSessionId)
        try c.encodeIfPresent(ephemeral, forKey: .ephemeral)
        try c.encodeIfPresent(warnings, forKey: .warnings)
        if engine == .durable {
            try c.encode(engine, forKey: .engine)
        }
        if let serverDurableRole {
            try c.encode(ServerDurableWire(role: serverDurableRole), forKey: .serverDurable)
        }

        try c.encode(createdAt.timeIntervalSince1970 * 1000, forKey: .createdAt)
        try c.encode(lastActivity.timeIntervalSince1970 * 1000, forKey: .lastActivity)
        try c.encodeIfPresent(
            lastAgentReplyAt.map { $0.timeIntervalSince1970 * 1000 },
            forKey: .lastAgentReplyAt
        )
        try c.encodeIfPresent(
            currentTurnStartedAt.map { $0.timeIntervalSince1970 * 1000 },
            forKey: .currentTurnStartedAt
        )
    }
}

/// Model info returned by `GET /models`.
struct ModelInfo: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let provider: String
    let contextWindow: Int
    let thinkingLevels: [ThinkingLevel]?
    let isDefault: Bool

    init(
        id: String,
        name: String,
        provider: String,
        contextWindow: Int,
        thinkingLevels: [ThinkingLevel]? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.contextWindow = contextWindow
        self.thinkingLevels = thinkingLevels
        self.isDefault = isDefault
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(String.self, forKey: .provider)
        contextWindow = try c.decode(Int.self, forKey: .contextWindow)
        if let rawLevels = try c.decodeIfPresent([String].self, forKey: .thinkingLevels) {
            thinkingLevels = rawLevels.compactMap(ThinkingLevel.init(rawValue:))
        } else {
            thinkingLevels = nil
        }
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, contextWindow, thinkingLevels, isDefault
    }
}
