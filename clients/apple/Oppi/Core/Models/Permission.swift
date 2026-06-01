import Foundation

/// Rule persistence scope for permission responses.
enum PermissionScope: String, Codable, Sendable {
    case once
    case session
    case global
}

/// Historical permission request model retained for local fixtures and old cached timeline rows.
struct PermissionRequest: Identifiable, Sendable, Equatable {
    let id: String
    let sessionId: String
    let workspaceId: String?
    let tool: String
    let input: [String: JSONValue]
    let displaySummary: String
    let reason: String
    let timeoutAt: Date
    let expires: Bool

    init(
        id: String,
        sessionId: String,
        tool: String,
        input: [String: JSONValue],
        displaySummary: String,
        reason: String,
        timeoutAt: Date,
        expires: Bool = true,
        workspaceId: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.tool = tool
        self.input = input
        self.displaySummary = displaySummary
        self.reason = reason
        self.timeoutAt = timeoutAt
        self.expires = expires
    }

    var hasExpiry: Bool { expires }
}

extension PermissionRequest: Codable {
    enum CodingKeys: String, CodingKey {
        case id, sessionId, workspaceId, tool, input, displaySummary, reason, timeoutAt, expires
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        tool = try c.decode(String.self, forKey: .tool)
        input = try c.decode([String: JSONValue].self, forKey: .input)
        displaySummary = try c.decode(String.self, forKey: .displaySummary)
        reason = try c.decode(String.self, forKey: .reason)

        let timeoutMs = try c.decode(Double.self, forKey: .timeoutAt)
        timeoutAt = Date(timeIntervalSince1970: timeoutMs / 1000)
        expires = try c.decodeIfPresent(Bool.self, forKey: .expires) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try c.encode(tool, forKey: .tool)
        try c.encode(input, forKey: .input)
        try c.encode(displaySummary, forKey: .displaySummary)
        try c.encode(reason, forKey: .reason)
        try c.encode(timeoutAt.timeIntervalSince1970 * 1000, forKey: .timeoutAt)
        try c.encode(expires, forKey: .expires)
    }
}

/// User's response to a permission request (wire type, sent to server).
enum PermissionAction: String, Codable, Sendable {
    case allow
    case deny
}

/// Rich client-side permission response containing scope + optional TTL.
struct PermissionResponseChoice: Sendable, Equatable {
    let action: PermissionAction
    let scope: PermissionScope
    let expiresInMs: Int?

    init(action: PermissionAction, scope: PermissionScope = .once, expiresInMs: Int? = nil) {
        self.action = action
        self.scope = scope
        self.expiresInMs = expiresInMs
    }

    static func allowOnce() -> Self {
        Self(action: .allow, scope: .once, expiresInMs: nil)
    }

    static func denyOnce() -> Self {
        Self(action: .deny, scope: .once, expiresInMs: nil)
    }
}

struct PermissionApprovalOption: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let choice: PermissionResponseChoice
}

enum PermissionApprovalPolicy {
    static func isPolicyTool(_ tool: String) -> Bool {
        tool.lowercased().hasPrefix("policy.")
    }

    static func options(for request: PermissionRequest) -> [PermissionApprovalOption] {
        guard !isPolicyTool(request.tool) else { return [] }

        return [
            PermissionApprovalOption(
                id: "allow-session",
                title: String(localized: "Allow this session"),
                systemImage: "clock",
                isDestructive: false,
                choice: PermissionResponseChoice(action: .allow, scope: .session)
            ),
            PermissionApprovalOption(
                id: "allow-global",
                title: String(localized: "Allow always"),
                systemImage: "checkmark.circle",
                isDestructive: false,
                choice: PermissionResponseChoice(action: .allow, scope: .global)
            ),
            PermissionApprovalOption(
                id: "deny-global",
                title: String(localized: "Deny always"),
                systemImage: "xmark.circle",
                isDestructive: true,
                choice: PermissionResponseChoice(action: .deny, scope: .global)
            ),
        ]
    }

    static func normalizedChoice(tool: String, choice: PermissionResponseChoice) -> PermissionResponseChoice {
        if isPolicyTool(tool) {
            return PermissionResponseChoice(action: choice.action, scope: .once, expiresInMs: nil)
        }

        if choice.action == .deny, choice.scope == .session {
            return PermissionResponseChoice(action: .deny, scope: .once, expiresInMs: nil)
        }

        return choice
    }

    static func normalizedChoice(for request: PermissionRequest, choice: PermissionResponseChoice) -> PermissionResponseChoice {
        normalizedChoice(tool: request.tool, choice: choice)
    }
}

/// Client-side resolved state for display. Richer than `PermissionAction`
/// because it includes states the server communicates via separate events
/// (expiry, cancellation) rather than as action values.
enum PermissionOutcome: String, Codable, Sendable, Equatable {
    case allowed
    case autoAllowed
    case autoAsked
    case denied
    case expired
    case cancelled
}

enum AutoReviewOutcome: String, Codable, Sendable, Equatable {
    case allow
    case ask

    var permissionOutcome: PermissionOutcome {
        switch self {
        case .allow: .autoAllowed
        case .ask: .autoAsked
        }
    }
}

struct AutoReviewTimelineItem: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let timestamp: Date
    let tool: String
    let displaySummary: String
    let outcome: AutoReviewOutcome
    let status: String
    let reason: String
    let model: String?
    let riskLevel: String?
    let confidence: Double?
    let durationMs: Int?
    let tokens: Int?
    let promptHash: String?

    var permissionOutcome: PermissionOutcome { outcome.permissionOutcome }

    var timelineSummary: String {
        [displaySummary, reason]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    init(
        id: String,
        timestamp: Date,
        tool: String,
        displaySummary: String,
        outcome: AutoReviewOutcome,
        status: String,
        reason: String,
        model: String? = nil,
        riskLevel: String? = nil,
        confidence: Double? = nil,
        durationMs: Int? = nil,
        tokens: Int? = nil,
        promptHash: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tool = tool
        self.displaySummary = displaySummary
        self.outcome = outcome
        self.status = status
        self.reason = reason
        self.model = model
        self.riskLevel = riskLevel
        self.confidence = confidence
        self.durationMs = durationMs
        self.tokens = tokens
        self.promptHash = promptHash
    }


}
