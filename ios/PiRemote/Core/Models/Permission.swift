import Foundation

/// Risk level for a permission request.
enum RiskLevel: String, Codable, Sendable {
    case low
    case medium
    case high
    case critical
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
}

extension PermissionRequest: Codable {
    enum CodingKeys: String, CodingKey {
        case id, sessionId, tool, input, displaySummary, risk, reason, timeoutAt
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
    }
}

/// User's response to a permission request.
enum PermissionAction: String, Codable, Sendable {
    case allow
    case deny
}
