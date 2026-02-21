import Foundation

/// Session status matching server's `Session.status`.
enum SessionStatus: String, Codable, Sendable {
    case starting
    case ready
    case busy
    case stopping
    case stopped
    case error
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
}

struct TokenUsage: Codable, Sendable, Equatable {
    var input: Int
    var output: Int
}

struct SessionChangeStats: Codable, Sendable, Equatable {
    var mutatingToolCalls: Int
    var filesChanged: Int
    var changedFiles: [String]
    var changedFilesOverflow: Int?
    var addedLines: Int
    var removedLines: Int
}

// MARK: - Codable (Unix millisecond timestamps)

extension Session: Codable {
    enum CodingKeys: String, CodingKey {
        case id, workspaceId, workspaceName
        case name, status, createdAt, lastActivity
        case model, messageCount, tokens, cost, changeStats
        case contextTokens, contextWindow, firstMessage, lastMessage
        case thinkingLevel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        workspaceName = try c.decodeIfPresent(String.self, forKey: .workspaceName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        status = try c.decode(SessionStatus.self, forKey: .status)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        tokens = try c.decode(TokenUsage.self, forKey: .tokens)
        cost = try c.decode(Double.self, forKey: .cost)
        changeStats = try c.decodeIfPresent(SessionChangeStats.self, forKey: .changeStats)
        contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens)
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
        firstMessage = try c.decodeIfPresent(String.self, forKey: .firstMessage)
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
        thinkingLevel = try c.decodeIfPresent(String.self, forKey: .thinkingLevel)

        // Server sends Unix milliseconds
        let createdMs = try c.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: createdMs / 1000)

        let activityMs = try c.decode(Double.self, forKey: .lastActivity)
        lastActivity = Date(timeIntervalSince1970: activityMs / 1000)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
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
        try c.encode(createdAt.timeIntervalSince1970 * 1000, forKey: .createdAt)
        try c.encode(lastActivity.timeIntervalSince1970 * 1000, forKey: .lastActivity)
    }
}

/// Model info returned by `GET /models`.
struct ModelInfo: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let provider: String
    let contextWindow: Int
}

/// A stored message in a session (user or assistant turn).
struct SessionMessage: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let sessionId: String
    let role: MessageRole
    let content: String
    let timestamp: Date
    var model: String?
    var tokens: TokenUsage?
    var cost: Double?

    enum MessageRole: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionId, role, content, timestamp, model, tokens, cost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        role = try c.decode(MessageRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        tokens = try c.decodeIfPresent(TokenUsage.self, forKey: .tokens)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)

        let tsMs = try c.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: tsMs / 1000)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(tokens, forKey: .tokens)
        try c.encodeIfPresent(cost, forKey: .cost)
        try c.encode(timestamp.timeIntervalSince1970 * 1000, forKey: .timestamp)
    }
}
