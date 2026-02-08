import Foundation

/// Messages sent from the iOS client to the server over WebSocket.
///
/// Manual Encodable to match server's `ClientMessage` union type with `type` discriminator.
/// Every case includes an optional `requestId` for response correlation — the server
/// returns `rpc_result` with the same `requestId` for commands forwarded to pi RPC.
enum ClientMessage: Sendable {
    // ── Prompting ──
    case prompt(message: String, images: [ImageAttachment]? = nil, streamingBehavior: StreamingBehavior? = nil, requestId: String? = nil)
    case steer(message: String, images: [ImageAttachment]? = nil, requestId: String? = nil)
    case followUp(message: String, images: [ImageAttachment]? = nil, requestId: String? = nil)
    case stop(requestId: String? = nil)
    case abort(requestId: String? = nil)

    // ── State ──
    case getState(requestId: String? = nil)
    case getMessages(requestId: String? = nil)
    case getSessionStats(requestId: String? = nil)

    // ── Model ──
    case setModel(provider: String, modelId: String, requestId: String? = nil)
    case cycleModel(requestId: String? = nil)
    case getAvailableModels(requestId: String? = nil)

    // ── Thinking ──
    case setThinkingLevel(level: ThinkingLevel, requestId: String? = nil)
    case cycleThinkingLevel(requestId: String? = nil)

    // ── Session ──
    case newSession(requestId: String? = nil)
    case setSessionName(name: String, requestId: String? = nil)
    case compact(customInstructions: String? = nil, requestId: String? = nil)
    case setAutoCompaction(enabled: Bool, requestId: String? = nil)
    case fork(entryId: String, requestId: String? = nil)
    case getForkMessages(requestId: String? = nil)
    case switchSession(sessionPath: String, requestId: String? = nil)

    // ── Queue modes ──
    case setSteeringMode(mode: QueueMode, requestId: String? = nil)
    case setFollowUpMode(mode: QueueMode, requestId: String? = nil)

    // ── Retry ──
    case setAutoRetry(enabled: Bool, requestId: String? = nil)
    case abortRetry(requestId: String? = nil)

    // ── Bash ──
    case bash(command: String, requestId: String? = nil)
    case abortBash(requestId: String? = nil)

    // ── Commands ──
    case getCommands(requestId: String? = nil)

    // ── Permission gate ──
    case permissionResponse(id: String, action: PermissionAction, requestId: String? = nil)

    // ── Extension UI ──
    case extensionUIResponse(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil, requestId: String? = nil)
}

// MARK: - Supporting Types

struct ImageAttachment: Codable, Sendable {
    let data: String      // base64
    let mimeType: String  // image/jpeg, image/png, etc.
}

enum StreamingBehavior: String, Codable, Sendable {
    case steer
    case followUp
}

enum ThinkingLevel: String, Codable, Sendable {
    case off, minimal, low, medium, high, xhigh

    /// Next level in the standard cycle: off → low → medium → high → off.
    var next: ThinkingLevel {
        switch self {
        case .off: return .low
        case .minimal: return .low
        case .low: return .medium
        case .medium: return .high
        case .high: return .off
        case .xhigh: return .off
        }
    }
}

enum QueueMode: String, Codable, Sendable {
    case all
    case oneAtATime = "one-at-a-time"
}

// MARK: - Manual Encodable

extension ClientMessage: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        // ── Prompting ──
        case .prompt(let message, let images, let behavior, let reqId):
            try c.encode("prompt", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(images, forKey: .images)
            try c.encodeIfPresent(behavior, forKey: .streamingBehavior)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .steer(let message, let images, let reqId):
            try c.encode("steer", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(images, forKey: .images)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .followUp(let message, let images, let reqId):
            try c.encode("follow_up", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(images, forKey: .images)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .stop(let reqId):
            try c.encode("stop", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .abort(let reqId):
            try c.encode("abort", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── State ──
        case .getState(let reqId):
            try c.encode("get_state", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .getMessages(let reqId):
            try c.encode("get_messages", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .getSessionStats(let reqId):
            try c.encode("get_session_stats", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Model ──
        case .setModel(let provider, let modelId, let reqId):
            try c.encode("set_model", forKey: .type)
            try c.encode(provider, forKey: .provider)
            try c.encode(modelId, forKey: .modelId)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .cycleModel(let reqId):
            try c.encode("cycle_model", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .getAvailableModels(let reqId):
            try c.encode("get_available_models", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Thinking ──
        case .setThinkingLevel(let level, let reqId):
            try c.encode("set_thinking_level", forKey: .type)
            try c.encode(level, forKey: .level)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .cycleThinkingLevel(let reqId):
            try c.encode("cycle_thinking_level", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Session ──
        case .newSession(let reqId):
            try c.encode("new_session", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .setSessionName(let name, let reqId):
            try c.encode("set_session_name", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .compact(let instructions, let reqId):
            try c.encode("compact", forKey: .type)
            try c.encodeIfPresent(instructions, forKey: .customInstructions)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .setAutoCompaction(let enabled, let reqId):
            try c.encode("set_auto_compaction", forKey: .type)
            try c.encode(enabled, forKey: .enabled)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .fork(let entryId, let reqId):
            try c.encode("fork", forKey: .type)
            try c.encode(entryId, forKey: .entryId)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .getForkMessages(let reqId):
            try c.encode("get_fork_messages", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .switchSession(let sessionPath, let reqId):
            try c.encode("switch_session", forKey: .type)
            try c.encode(sessionPath, forKey: .sessionPath)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Queue modes ──
        case .setSteeringMode(let mode, let reqId):
            try c.encode("set_steering_mode", forKey: .type)
            try c.encode(mode, forKey: .mode)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .setFollowUpMode(let mode, let reqId):
            try c.encode("set_follow_up_mode", forKey: .type)
            try c.encode(mode, forKey: .mode)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Retry ──
        case .setAutoRetry(let enabled, let reqId):
            try c.encode("set_auto_retry", forKey: .type)
            try c.encode(enabled, forKey: .enabled)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .abortRetry(let reqId):
            try c.encode("abort_retry", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Bash ──
        case .bash(let command, let reqId):
            try c.encode("bash", forKey: .type)
            try c.encode(command, forKey: .command)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .abortBash(let reqId):
            try c.encode("abort_bash", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Commands ──
        case .getCommands(let reqId):
            try c.encode("get_commands", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Permission gate ──
        case .permissionResponse(let id, let action, let reqId):
            try c.encode("permission_response", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Extension UI ──
        case .extensionUIResponse(let id, let value, let confirmed, let cancelled, let reqId):
            try c.encode("extension_ui_response", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(value, forKey: .value)
            try c.encodeIfPresent(confirmed, forKey: .confirmed)
            try c.encodeIfPresent(cancelled, forKey: .cancelled)
            try c.encodeIfPresent(reqId, forKey: .requestId)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, message, images, streamingBehavior, requestId
        case id, action, value, confirmed, cancelled
        case provider, modelId, level, name, mode, enabled
        case customInstructions, entryId, sessionPath, command
    }
}

// MARK: - Convenience

extension ClientMessage {
    /// Encode to JSON data for WebSocket send.
    func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Encode to JSON string for WebSocket send.
    func jsonString() throws -> String {
        let data = try jsonData()
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(data, .init(codingPath: [], debugDescription: "JSON data is not valid UTF-8"))
        }
        return string
    }
}
