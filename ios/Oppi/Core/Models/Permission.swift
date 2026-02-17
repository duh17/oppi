import Foundation

/// Risk level for a permission request.
enum RiskLevel: String, Codable, Sendable {
    case low
    case medium
    case high
    case critical
}

/// Rule persistence scope for permission responses.
enum PermissionScope: String, Codable, Sendable {
    case once
    case session
    case workspace
    case global
}

/// Server-advertised choices for how a permission can be resolved.
struct PermissionResolutionOptions: Codable, Sendable, Equatable {
    let allowSession: Bool
    let allowAlways: Bool
    let alwaysDescription: String?
    let denyAlways: Bool
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
    let risk: RiskLevel
    let reason: String
    let timeoutAt: Date
    let expires: Bool
    let resolutionOptions: PermissionResolutionOptions?

    init(
        id: String,
        sessionId: String,
        tool: String,
        input: [String: JSONValue],
        displaySummary: String,
        risk: RiskLevel,
        reason: String,
        timeoutAt: Date,
        expires: Bool = true,
        resolutionOptions: PermissionResolutionOptions? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.tool = tool
        self.input = input
        self.displaySummary = displaySummary
        self.risk = risk
        self.reason = reason
        self.timeoutAt = timeoutAt
        self.expires = expires
        self.resolutionOptions = resolutionOptions
    }

    var hasExpiry: Bool { expires }
}

extension PermissionRequest: Codable {
    enum CodingKeys: String, CodingKey {
        case id, sessionId, tool, input, displaySummary, risk, reason, timeoutAt, expires, resolutionOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        tool = try c.decode(String.self, forKey: .tool)
        input = try c.decode([String: JSONValue].self, forKey: .input)
        displaySummary = try c.decode(String.self, forKey: .displaySummary)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        reason = try c.decode(String.self, forKey: .reason)

        let timeoutMs = try c.decode(Double.self, forKey: .timeoutAt)
        timeoutAt = Date(timeIntervalSince1970: timeoutMs / 1000)
        expires = try c.decodeIfPresent(Bool.self, forKey: .expires) ?? true
        resolutionOptions = try c.decodeIfPresent(PermissionResolutionOptions.self, forKey: .resolutionOptions)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(tool, forKey: .tool)
        try c.encode(input, forKey: .input)
        try c.encode(displaySummary, forKey: .displaySummary)
        try c.encode(risk, forKey: .risk)
        try c.encode(reason, forKey: .reason)
        try c.encode(timeoutAt.timeIntervalSince1970 * 1000, forKey: .timeoutAt)
        try c.encode(expires, forKey: .expires)
        try c.encodeIfPresent(resolutionOptions, forKey: .resolutionOptions)
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

    static func allowOnce() -> PermissionResponseChoice {
        PermissionResponseChoice(action: .allow, scope: .once, expiresInMs: nil)
    }

    static func denyOnce() -> PermissionResponseChoice {
        PermissionResponseChoice(action: .deny, scope: .once, expiresInMs: nil)
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
