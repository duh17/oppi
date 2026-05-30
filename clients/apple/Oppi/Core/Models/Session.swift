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

enum SessionRuntimeKind: String, Codable, Sendable {
    case oppi
    case piTui = "pi-tui"
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

/// Session model matching server's `Session` type.
///
/// Server sends timestamps as Unix milliseconds (not ISO 8601).
/// Manual Decodable handles the conversion.
struct Session: Identifiable, Sendable, Equatable {
    let id: String
    var workspaceId: String?
    var workspaceName: String?
    var name: String?
    var status: SessionStatus
    let createdAt: Date
    var lastActivity: Date
    var lastAgentReplyAt: Date? = nil
    var currentTurnStartedAt: Date? = nil
    var model: String?

    var messageCount: Int
    var tokens: TokenUsage
    var cost: Double
    var changeStats: SessionChangeStats? = nil

    // Context usage (pi TUI-style status bar)
    var contextTokens: Int?    // input+output+cacheRead+cacheWrite from last message
    var contextWindow: Int?    // model's total context window

    var firstMessage: String?
    var lastMessage: String?

    // Agent config state (synced from pi get_state)
    var thinkingLevel: String?

    // Runtime ownership
    var runtime: SessionRuntimeKind? = nil
    var mirror: PiTuiMirrorSessionMetadata? = nil

    // Privacy / persistence
    var ephemeral: Bool?

    // Parent-child tree (spawn_agent)
    var parentSessionId: String?



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
    var pendingPermissionCount: Int
    var pendingAskCount: Int

    static let none = SessionSummaryAttentionCounts(
        pendingPermissionCount: 0,
        pendingAskCount: 0
    )

    var hasAttention: Bool {
        pendingPermissionCount > 0 || pendingAskCount > 0
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
    var name: String?
    var status: SessionStatus
    let createdAt: Date
    var lastActivity: Date
    var lastAgentReplyAt: Date?
    var currentTurnStartedAt: Date?
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
    var mirror: PiTuiMirrorSessionMetadata? = nil
    var ephemeral: Bool?
    var parentSessionId: String?
    var pendingPermissionCount: Int
    var pendingAskCount: Int

    var attentionCounts: SessionSummaryAttentionCounts {
        SessionSummaryAttentionCounts(
            pendingPermissionCount: pendingPermissionCount,
            pendingAskCount: pendingAskCount
        )
    }

    var session: Session {
        Session(
            id: id,
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            name: name,
            status: status,
            createdAt: createdAt,
            lastActivity: lastActivity,
            lastAgentReplyAt: lastAgentReplyAt,
            currentTurnStartedAt: currentTurnStartedAt,
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
            ephemeral: ephemeral,
            parentSessionId: parentSessionId
        )
    }
}

extension SessionSummary {
    init(from session: Session) {
        self.id = session.id
        self.workspaceId = session.workspaceId
        self.workspaceName = session.workspaceName
        self.name = session.name
        self.status = session.status
        self.createdAt = session.createdAt
        self.lastActivity = session.lastActivity
        self.lastAgentReplyAt = session.lastAgentReplyAt
        self.currentTurnStartedAt = session.currentTurnStartedAt
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
        self.ephemeral = session.ephemeral
        self.parentSessionId = session.parentSessionId
        self.pendingPermissionCount = 0
        self.pendingAskCount = 0
    }
}

private enum SessionWireCodingKeys: String, CodingKey {
    case id, workspaceId, workspaceName
    case name, status, createdAt, lastActivity, lastAgentReplyAt, currentTurnStartedAt
    case model, messageCount, tokens, cost, changeStats
    case contextTokens, contextWindow, firstMessage, lastMessage
    case thinkingLevel, runtime, mirror, ephemeral, parentSessionId
    case pendingPermissionCount, pendingAskCount
}

private struct DecodedSessionWireFields {
    let id: String
    let workspaceId: String?
    let workspaceName: String?
    let name: String?
    let status: SessionStatus
    let createdAt: Date
    let lastActivity: Date
    let lastAgentReplyAt: Date?
    let currentTurnStartedAt: Date?
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
    let ephemeral: Bool?
    let parentSessionId: String?

    init(from container: KeyedDecodingContainer<SessionWireCodingKeys>) throws {
        id = try container.decode(String.self, forKey: .id)
        workspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId)
        workspaceName = try container.decodeIfPresent(String.self, forKey: .workspaceName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        status = try container.decode(SessionStatus.self, forKey: .status)
        createdAt = try container.decodeUnixMilliseconds(forKey: .createdAt)
        lastActivity = try container.decodeUnixMilliseconds(forKey: .lastActivity)
        lastAgentReplyAt = try container.decodeUnixMillisecondsIfPresent(forKey: .lastAgentReplyAt)
        currentTurnStartedAt = try container.decodeUnixMillisecondsIfPresent(forKey: .currentTurnStartedAt)
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
        ephemeral = try container.decodeIfPresent(Bool.self, forKey: .ephemeral)
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
    }
}

private extension DecodedSessionWireFields {
    func makeSession() -> Session {
        Session(
            id: id,
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            name: name,
            status: status,
            createdAt: createdAt,
            lastActivity: lastActivity,
            lastAgentReplyAt: lastAgentReplyAt,
            currentTurnStartedAt: currentTurnStartedAt,
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
            ephemeral: ephemeral,
            parentSessionId: parentSessionId
        )
    }

    func makeSummary(pendingPermissionCount: Int, pendingAskCount: Int) -> SessionSummary {
        var summary = SessionSummary(from: makeSession())
        summary.pendingPermissionCount = pendingPermissionCount
        summary.pendingAskCount = pendingAskCount
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
            pendingPermissionCount: try container.decodeIfPresent(Int.self, forKey: .pendingPermissionCount) ?? 0,
            pendingAskCount: try container.decodeIfPresent(Int.self, forKey: .pendingAskCount) ?? 0
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
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(messageCount, forKey: .messageCount)
        try c.encode(tokens, forKey: .tokens)
        try c.encode(cost, forKey: .cost)
        try c.encodeIfPresent(changeStats, forKey: .changeStats)
        try c.encodeIfPresent(contextTokens, forKey: .contextTokens)
        try c.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try c.encodeIfPresent(firstMessage, forKey: .firstMessage)
        try c.encodeIfPresent(lastMessage, forKey: .lastMessage)
        try c.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(mirror, forKey: .mirror)
        try c.encodeIfPresent(ephemeral, forKey: .ephemeral)
        try c.encodeIfPresent(parentSessionId, forKey: .parentSessionId)

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
}
