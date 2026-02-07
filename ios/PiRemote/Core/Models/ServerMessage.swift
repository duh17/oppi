import Foundation

/// Messages received from the server over WebSocket.
///
/// Manual Decodable with `type` discriminator. Unknown types decode to
/// `.unknown` instead of throwing — forward-compatible with server additions.
enum ServerMessage: Sendable, Equatable {
    // Connection lifecycle
    case connected(session: Session)
    case state(session: Session)
    case sessionEnded(reason: String)

    // Agent streaming
    case agentStart
    case agentEnd
    case textDelta(delta: String)
    case thinkingDelta(delta: String)

    // Tool execution
    case toolStart(tool: String, args: [String: JSONValue])
    case toolOutput(output: String, isError: Bool)
    case toolEnd(tool: String)

    // Permissions
    case permissionRequest(PermissionRequest)
    case permissionExpired(id: String, reason: String)
    case permissionCancelled(id: String)

    // Extension UI
    case extensionUIRequest(ExtensionUIRequest)
    case extensionUINotification(method: String, message: String?, notifyType: String?, statusKey: String?, statusText: String?)

    // Errors
    case error(message: String)

    // Forward-compatibility: unknown server message types are skipped, not fatal.
    case unknown(type: String)
}

// MARK: - Extension UI Request

struct ExtensionUIRequest: Sendable, Equatable, Identifiable {
    let id: String
    let sessionId: String
    let method: String
    var title: String?
    var options: [String]?
    var message: String?
    var placeholder: String?
    var prefill: String?
    var timeout: Int?
}

// MARK: - Manual Decodable

extension ServerMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case type
        // connected / state
        case session
        // session_ended
        case reason
        // text_delta / thinking_delta
        case delta
        // tool_start / tool_end
        case tool, args
        // tool_output
        case output, isError
        // error
        case error
        // permission_request
        case id, sessionId, input, displaySummary, risk, timeoutAt
        // extension_ui_request
        case method, title, options, message, placeholder, prefill, timeout
        // extension_ui_notification
        case notifyType, statusKey, statusText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)

        switch type {
        case "connected":
            let session = try c.decode(Session.self, forKey: .session)
            self = .connected(session: session)

        case "state":
            let session = try c.decode(Session.self, forKey: .session)
            self = .state(session: session)

        case "session_ended":
            let reason = try c.decode(String.self, forKey: .reason)
            self = .sessionEnded(reason: reason)

        case "agent_start":
            self = .agentStart

        case "agent_end":
            self = .agentEnd

        case "text_delta":
            let delta = try c.decode(String.self, forKey: .delta)
            self = .textDelta(delta: delta)

        case "thinking_delta":
            let delta = try c.decode(String.self, forKey: .delta)
            self = .thinkingDelta(delta: delta)

        case "tool_start":
            let tool = try c.decode(String.self, forKey: .tool)
            let args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
            self = .toolStart(tool: tool, args: args)

        case "tool_output":
            let output = try c.decode(String.self, forKey: .output)
            let isErr = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            self = .toolOutput(output: output, isError: isErr)

        case "tool_end":
            let tool = try c.decode(String.self, forKey: .tool)
            self = .toolEnd(tool: tool)

        case "error":
            let msg = try c.decode(String.self, forKey: .error)
            self = .error(message: msg)

        case "permission_request":
            let perm = PermissionRequest(
                id: try c.decode(String.self, forKey: .id),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                tool: try c.decode(String.self, forKey: .tool),
                input: try c.decode([String: JSONValue].self, forKey: .input),
                displaySummary: try c.decode(String.self, forKey: .displaySummary),
                risk: try c.decode(RiskLevel.self, forKey: .risk),
                reason: try c.decode(String.self, forKey: .reason),
                timeoutAt: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .timeoutAt) / 1000)
            )
            self = .permissionRequest(perm)

        case "permission_expired":
            let id = try c.decode(String.self, forKey: .id)
            let reason = try c.decode(String.self, forKey: .reason)
            self = .permissionExpired(id: id, reason: reason)

        case "permission_cancelled":
            let id = try c.decode(String.self, forKey: .id)
            self = .permissionCancelled(id: id)

        case "extension_ui_request":
            let req = ExtensionUIRequest(
                id: try c.decode(String.self, forKey: .id),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                method: try c.decode(String.self, forKey: .method),
                title: try c.decodeIfPresent(String.self, forKey: .title),
                options: try c.decodeIfPresent([String].self, forKey: .options),
                message: try c.decodeIfPresent(String.self, forKey: .message),
                placeholder: try c.decodeIfPresent(String.self, forKey: .placeholder),
                prefill: try c.decodeIfPresent(String.self, forKey: .prefill),
                timeout: try c.decodeIfPresent(Int.self, forKey: .timeout)
            )
            self = .extensionUIRequest(req)

        case "extension_ui_notification":
            let method = try c.decode(String.self, forKey: .method)
            let msg = try c.decodeIfPresent(String.self, forKey: .message)
            let notifyType = try c.decodeIfPresent(String.self, forKey: .notifyType)
            let statusKey = try c.decodeIfPresent(String.self, forKey: .statusKey)
            let statusText = try c.decodeIfPresent(String.self, forKey: .statusText)
            self = .extensionUINotification(method: method, message: msg, notifyType: notifyType, statusKey: statusKey, statusText: statusText)

        default:
            self = .unknown(type: type)
        }
    }
}

// MARK: - Decode from raw WebSocket data

extension ServerMessage {
    /// Decode a `ServerMessage` from raw WebSocket text data.
    static func decode(from text: String) throws -> ServerMessage {
        guard let data = text.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid UTF-8 in WebSocket message")
            )
        }
        return try JSONDecoder().decode(ServerMessage.self, from: data)
    }
}
