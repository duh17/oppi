import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Messages sent from the iOS client to the server over WebSocket.
///
/// Manual Encodable to match server's `ClientMessage` union type with `type` discriminator.
/// Every case includes an optional `requestId` for response correlation — the server
/// returns `command_result` with the same `requestId` for forwarded commands.
enum ClientMessage: Sendable {
    // ── Prompting ──
    case prompt(message: String, images: [ImageAttachment]? = nil, streamingBehavior: StreamingBehavior? = nil, requestId: String? = nil, clientTurnId: String? = nil)
    case steer(message: String, images: [ImageAttachment]? = nil, requestId: String? = nil, clientTurnId: String? = nil)
    case followUp(message: String, images: [ImageAttachment]? = nil, requestId: String? = nil, clientTurnId: String? = nil)
    case stop(requestId: String? = nil)       // Abort current turn only
    case abort(requestId: String? = nil)
    case stopSession(requestId: String? = nil) // Kill session process entirely

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
    case permissionResponse(
        id: String,
        action: PermissionAction,
        scope: PermissionScope? = nil,
        expiresInMs: Int? = nil,
        requestId: String? = nil
    )

    // ── Extension UI ──
    case extensionUIResponse(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil, requestId: String? = nil)

    // ── Stream multiplexing (/stream protocol) ──
    case subscribe(sessionId: String, level: StreamSubscriptionLevel = .full, sinceSeq: Int? = nil, requestId: String? = nil)
    case unsubscribe(sessionId: String, requestId: String? = nil)
}

/// Subscription level for the `/stream` multiplexed WebSocket.
enum StreamSubscriptionLevel: String, Codable, Sendable {
    /// Full event streaming (text deltas, tool output, etc.). One session per connection.
    case full
    /// Notification-level events only (permissions, state, agent start/end).
    case notifications
}

// MARK: - Supporting Types

struct ImageAttachment: Codable, Sendable, Equatable {
    let data: String      // base64
    let mimeType: String  // image/jpeg, image/png, etc.

#if canImport(UIKit)
    /// Decode base64 data to UIImage for display.
    var decodedImage: UIImage? {
        guard let imageData = Data(base64Encoded: data) else { return nil }
        return UIImage(data: imageData)
    }
#endif
}

enum StreamingBehavior: String, Codable, Sendable {
    case steer
    case followUp
}

enum ThinkingLevel: String, Codable, Sendable {
    case off, minimal, low, medium, high, xhigh

    /// Next level in the standard cycle: off → low → medium → high → off.
    var next: Self {
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
        case .prompt(let message, let images, let behavior, let reqId, let turnId):
            try c.encode("prompt", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(images, forKey: .images)
            try c.encodeIfPresent(behavior, forKey: .streamingBehavior)
            try c.encodeIfPresent(reqId, forKey: .requestId)
            try c.encodeIfPresent(turnId, forKey: .clientTurnId)

        case .steer(let message, let images, let reqId, let turnId):
            try c.encode("steer", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(images, forKey: .images)
            try c.encodeIfPresent(reqId, forKey: .requestId)
            try c.encodeIfPresent(turnId, forKey: .clientTurnId)

        case .followUp(let message, let images, let reqId, let turnId):
            try c.encode("follow_up", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(images, forKey: .images)
            try c.encodeIfPresent(reqId, forKey: .requestId)
            try c.encodeIfPresent(turnId, forKey: .clientTurnId)

        case .stop(let reqId):
            try c.encode("stop", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .abort(let reqId):
            try c.encode("abort", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .stopSession(let reqId):
            try c.encode("stop_session", forKey: .type)
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
        case .permissionResponse(let id, let action, let scope, let expiresInMs, let reqId):
            try c.encode("permission_response", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(scope, forKey: .scope)
            try c.encodeIfPresent(expiresInMs, forKey: .expiresInMs)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Extension UI ──
        case .extensionUIResponse(let id, let value, let confirmed, let cancelled, let reqId):
            try c.encode("extension_ui_response", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(value, forKey: .value)
            try c.encodeIfPresent(confirmed, forKey: .confirmed)
            try c.encodeIfPresent(cancelled, forKey: .cancelled)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Stream multiplexing ──
        case .subscribe(let sessionId, let level, let sinceSeq, let reqId):
            try c.encode("subscribe", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(level, forKey: .level)
            try c.encodeIfPresent(sinceSeq, forKey: .sinceSeq)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .unsubscribe(let sessionId, let reqId):
            try c.encode("unsubscribe", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encodeIfPresent(reqId, forKey: .requestId)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, message, images, streamingBehavior, requestId, clientTurnId
        case id, action, scope, expiresInMs, value, confirmed, cancelled
        case provider, modelId, level, name, mode, enabled
        case customInstructions, entryId, sessionPath, command
        case sessionId, sinceSeq
    }
}

// MARK: - Stream Envelope

/// Wraps a `ClientMessage` with a `sessionId` for the `/stream` multiplexed protocol.
///
/// On the per-session WebSocket, the session is implicit in the URL.
/// On `/stream`, session-scoped commands must include `sessionId` at the top level.
struct SessionScopedMessage: Encodable, Sendable {
    let sessionId: String
    let message: ClientMessage

    func encode(to encoder: Encoder) throws {
        // Encode the inner message first (creates the keyed container)
        try message.encode(to: encoder)
        // Then add sessionId to the same container
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
    }

    func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    func jsonString() throws -> String {
        let data = try jsonData()
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(data, .init(codingPath: [], debugDescription: "JSON data is not valid UTF-8"))
        }
        return string
    }
}

// MARK: - Convenience

extension ClientMessage {
    /// Short type label for logging (avoids associated-value noise).
    var typeLabel: String {
        switch self {
        case .prompt: return "prompt"
        case .steer: return "steer"
        case .followUp: return "follow_up"
        case .stop: return "stop"
        case .abort: return "abort"
        case .stopSession: return "stop_session"
        case .getState: return "get_state"
        case .getMessages: return "get_messages"
        case .getSessionStats: return "get_session_stats"
        case .setModel: return "set_model"
        case .cycleModel: return "cycle_model"
        case .getAvailableModels: return "get_available_models"
        case .setThinkingLevel: return "set_thinking_level"
        case .cycleThinkingLevel: return "cycle_thinking_level"
        case .newSession: return "new_session"
        case .setSessionName: return "set_session_name"
        case .compact: return "compact"
        case .setAutoCompaction: return "set_auto_compaction"
        case .fork: return "fork"
        case .getForkMessages: return "get_fork_messages"
        case .switchSession: return "switch_session"
        case .setSteeringMode: return "set_steering_mode"
        case .setFollowUpMode: return "set_follow_up_mode"
        case .setAutoRetry: return "set_auto_retry"
        case .abortRetry: return "abort_retry"
        case .bash: return "bash"
        case .abortBash: return "abort_bash"
        case .getCommands: return "get_commands"
        case .permissionResponse: return "permission_response"
        case .extensionUIResponse: return "extension_ui_response"
        case .subscribe: return "subscribe"
        case .unsubscribe: return "unsubscribe"
        }
    }

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
