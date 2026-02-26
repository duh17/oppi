import Foundation

/// Rule persistence scope for permission responses.
enum PermissionScope: String, Codable, Sendable {
    case once
    case session
    case global
}

/// A permission request from the agent, awaiting user approval.
///
/// Maps to server's `permission_request` WebSocket message.
struct PermissionRequest: Identifiable, Sendable, Equatable {
    let id: String
    let sessionId: String
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
        expires: Bool = true
    ) {
        self.id = id
        self.sessionId = sessionId
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
        case id, sessionId, tool, input, displaySummary, reason, timeoutAt, expires
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
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
enum PermissionOutcome: String, Sendable, Equatable {
    case allowed
    case denied
    case expired
    case cancelled
}
