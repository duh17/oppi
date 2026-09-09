import Foundation

/// Messages sent from the iOS client to the server over WebSocket.
///
/// Manual Encodable to match server's `ClientMessage` union type with `type` discriminator.
/// Every case includes an optional `requestId` for response correlation — the server
/// returns `command_result` with the same `requestId` for forwarded commands.
enum ClientMessage: Sendable {
    // ── Prompting ──
    case prompt(message: String, attachments: [ChatAttachmentRef]? = nil, streamingBehavior: StreamingBehavior? = nil, requestId: String? = nil, clientTurnId: String? = nil)
    case steer(message: String, attachments: [ChatAttachmentRef]? = nil, requestId: String? = nil, clientTurnId: String? = nil)
    case followUp(message: String, attachments: [ChatAttachmentRef]? = nil, requestId: String? = nil, clientTurnId: String? = nil)
    case stop(requestId: String? = nil)       // Abort current turn only
    case abort(requestId: String? = nil)
    case stopSession(requestId: String? = nil) // Kill session process entirely

    // ── State ──
    case getState(requestId: String? = nil)
    case getMessages(requestId: String? = nil)
    case getSessionStats(requestId: String? = nil)

    // ── Message queue ──
    case getQueue(requestId: String? = nil)
    case setQueue(baseVersion: Int, steering: [MessageQueueDraftItem], followUp: [MessageQueueDraftItem], requestId: String? = nil)

    // ── Model ──
    case setModel(provider: String, modelId: String, requestId: String? = nil, persist: Bool? = nil)
    case cycleModel(requestId: String? = nil)

    // ── Thinking ──
    case setThinkingLevel(level: ThinkingLevel, requestId: String? = nil, persist: Bool? = nil)
    case cycleThinkingLevel(requestId: String? = nil)

    // ── Session ──
    case reload(requestId: String? = nil)
    case newSession(requestId: String? = nil)
    case setSessionName(name: String, requestId: String? = nil)
    case compact(customInstructions: String? = nil, requestId: String? = nil)
    case setAutoCompaction(enabled: Bool, requestId: String? = nil)
    case fork(entryId: String, requestId: String? = nil)
    case getForkMessages(requestId: String? = nil)
    case getSessionTree(filterMode: SessionTreeFilterMode? = nil, requestId: String? = nil)
    case navigateTree(
        targetId: String,
        summarize: Bool,
        customInstructions: String? = nil,
        replaceInstructions: Bool? = nil,
        label: String? = nil,
        requestId: String? = nil
    )

    // ── Queue modes ──
    case setSteeringMode(mode: QueueMode, requestId: String? = nil)
    case setFollowUpMode(mode: QueueMode, requestId: String? = nil)

    // ── Retry ──
    case setAutoRetry(enabled: Bool, requestId: String? = nil)
    case abortRetry(requestId: String? = nil)

    // ── Bash ──
    case abortBash(requestId: String? = nil)

    // ── Commands ──
    case getCommands(requestId: String? = nil)
    case shareSession(
        action: ShareSessionAction? = nil,
        redactionPolicy: ShareSessionRedactionPolicy? = nil,
        requestId: String? = nil
    )

    // ── Extension UI ──
    case extensionUIResponse(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil, requestId: String? = nil)

    // ── Dictation (session audio stream) ──
    case dictationStart(contextualStrings: [String] = [])
    case dictationStop
    case dictationCancel
}

// MARK: - Supporting Types

enum AttachmentSource: String, Codable, Sendable {
    case upload
    case workspace
}

enum AttachmentKind: String, Codable, Sendable {
    case image
    case text
    case pdf
    case audio
    case video
    case archive
    case unknown
}

struct ChatAttachmentRef: Codable, Sendable, Equatable, Identifiable {
    let type: String
    let id: String
    let source: AttachmentSource
    let name: String
    let mimeType: String
    let sizeBytes: Int
    let sha256: String?
    let kind: AttachmentKind?
    let workspacePath: String?

}

enum StreamingBehavior: String, Codable, Sendable {
    case steer
    case followUp
}

enum ThinkingLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, minimal, low, medium, high, xhigh, max

    var id: String { rawValue }

    /// Parse a session-stored thinking-level string.
    /// Trims whitespace/newlines, lowercases, then `ThinkingLevel(rawValue:)`.
    /// Missing or unknown values become `.medium`.
    init(sessionValue: String?) {
        guard let normalized = sessionValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let value = Self(rawValue: normalized) else {
            self = .medium
            return
        }
        self = value
    }

    var displayTitle: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "XHigh"
        case .max: "Max"
        }
    }

    var compactTitle: String {
        switch self {
        case .off: "off"
        case .minimal: "min"
        case .low: "low"
        case .medium: "med"
        case .high: "high"
        case .xhigh: "xhigh"
        case .max: "max"
        }
    }

    /// Next level in the standard cycle: off → low → medium → high → off.
    var next: Self {
        switch self {
        case .off: return .low
        case .minimal: return .low
        case .low: return .medium
        case .medium: return .high
        case .high: return .off
        case .xhigh: return .off
        case .max: return .off
        }
    }
}

enum QueueMode: String, Codable, Sendable {
    case all
    case oneAtATime = "one-at-a-time"
}

enum ShareSessionAction: String, Codable, Sendable {
    case prepare
    case publish
}

struct ShareSessionRedactionPolicy: Codable, Sendable, Equatable {
    var secrets: Bool
    var emails: Bool
    var phones: Bool
    var userPaths: Bool
    var ipAddresses: Bool
    var jwtAndBearer: Bool
    var namesHeuristic: Bool
    var skills: Bool

    static let recommended = ShareSessionRedactionPolicy(
        secrets: true,
        emails: true,
        phones: true,
        userPaths: true,
        ipAddresses: true,
        jwtAndBearer: true,
        namesHeuristic: false,
        skills: true
    )

    var normalized: ShareSessionRedactionPolicy {
        var policy = self
        policy.secrets = true
        return policy
    }
}

// MARK: - Manual Encodable

extension ClientMessage: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        // ── Prompting ──
        case .prompt(let message, let attachments, let behavior, let reqId, let turnId):
            try c.encode("prompt", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(attachments, forKey: .attachments)
            try c.encodeIfPresent(behavior, forKey: .streamingBehavior)
            try c.encodeIfPresent(reqId, forKey: .requestId)
            try c.encodeIfPresent(turnId, forKey: .clientTurnId)

        case .steer(let message, let attachments, let reqId, let turnId):
            try c.encode("steer", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(attachments, forKey: .attachments)
            try c.encodeIfPresent(reqId, forKey: .requestId)
            try c.encodeIfPresent(turnId, forKey: .clientTurnId)

        case .followUp(let message, let attachments, let reqId, let turnId):
            try c.encode("follow_up", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(attachments, forKey: .attachments)
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

        // ── Message queue ──
        case .getQueue(let reqId):
            try c.encode("get_queue", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .setQueue(let baseVersion, let steering, let followUp, let reqId):
            try c.encode("set_queue", forKey: .type)
            try c.encode(baseVersion, forKey: .baseVersion)
            try c.encode(steering, forKey: .steering)
            try c.encode(followUp, forKey: .followUp)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Model ──
        case .setModel(let provider, let modelId, let reqId, let persist):
            try c.encode("set_model", forKey: .type)
            try c.encode(provider, forKey: .provider)
            try c.encode(modelId, forKey: .modelId)
            try c.encodeIfPresent(reqId, forKey: .requestId)
            if persist == true {
                try c.encode(true, forKey: .persist)
            }

        case .cycleModel(let reqId):
            try c.encode("cycle_model", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Thinking ──
        case .setThinkingLevel(let level, let reqId, let persist):
            try c.encode("set_thinking_level", forKey: .type)
            try c.encode(level, forKey: .level)
            try c.encodeIfPresent(reqId, forKey: .requestId)
            if persist == true {
                try c.encode(true, forKey: .persist)
            }

        case .cycleThinkingLevel(let reqId):
            try c.encode("cycle_thinking_level", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Session ──
        case .reload(let reqId):
            try c.encode("reload", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

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

        case .getSessionTree(let filterMode, let reqId):
            try c.encode("get_session_tree", forKey: .type)
            try c.encodeIfPresent(filterMode?.rawValue, forKey: .filterMode)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .navigateTree(
            let targetId,
            let summarize,
            let customInstructions,
            let replaceInstructions,
            let label,
            let reqId
        ):
            try c.encode("navigate_tree", forKey: .type)
            try c.encode(targetId, forKey: .targetId)
            try c.encode(summarize, forKey: .summarize)
            try c.encodeIfPresent(customInstructions, forKey: .customInstructions)
            try c.encodeIfPresent(replaceInstructions, forKey: .replaceInstructions)
            try c.encodeIfPresent(label, forKey: .label)
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
        case .abortBash(let reqId):
            try c.encode("abort_bash", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Commands ──
        case .getCommands(let reqId):
            try c.encode("get_commands", forKey: .type)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        case .shareSession(let action, let redactionPolicy, let reqId):
            try c.encode("share_session", forKey: .type)
            try c.encodeIfPresent(action, forKey: .action)
            try c.encodeIfPresent(redactionPolicy?.normalized, forKey: .redactionPolicy)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Extension UI ──
        case .extensionUIResponse(let id, let value, let confirmed, let cancelled, let reqId):
            try c.encode("extension_ui_response", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(value, forKey: .value)
            try c.encodeIfPresent(confirmed, forKey: .confirmed)
            try c.encodeIfPresent(cancelled, forKey: .cancelled)
            try c.encodeIfPresent(reqId, forKey: .requestId)

        // ── Dictation ──
        case .dictationStart(let contextualStrings):
            try c.encode("dictation_start", forKey: .type)
            let prepared = DictationContextualStrings.prepared(contextualStrings)
            if !prepared.isEmpty {
                try c.encode(prepared, forKey: .contextualStrings)
            }
        case .dictationStop:
            try c.encode("dictation_stop", forKey: .type)
        case .dictationCancel:
            try c.encode("dictation_cancel", forKey: .type)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, message, attachments, streamingBehavior, requestId, clientTurnId
        case id, action, redactionPolicy, value, confirmed, cancelled
        case contextualStrings
        case provider, modelId, persist, level, name, mode, enabled
        case customInstructions, entryId, filterMode
        case targetId, summarize, replaceInstructions, label
        case baseVersion, steering, followUp
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
        case .getQueue: return "get_queue"
        case .setQueue: return "set_queue"
        case .setModel: return "set_model"
        case .cycleModel: return "cycle_model"
        case .setThinkingLevel: return "set_thinking_level"
        case .cycleThinkingLevel: return "cycle_thinking_level"
        case .newSession: return "new_session"
        case .setSessionName: return "set_session_name"
        case .reload: return "reload"
        case .compact: return "compact"
        case .setAutoCompaction: return "set_auto_compaction"
        case .fork: return "fork"
        case .getForkMessages: return "get_fork_messages"
        case .getSessionTree: return "get_session_tree"
        case .navigateTree: return "navigate_tree"
        case .setSteeringMode: return "set_steering_mode"
        case .setFollowUpMode: return "set_follow_up_mode"
        case .setAutoRetry: return "set_auto_retry"
        case .abortRetry: return "abort_retry"
        case .abortBash: return "abort_bash"
        case .getCommands: return "get_commands"
        case .shareSession: return "share_session"
        case .extensionUIResponse: return "extension_ui_response"
        case .dictationStart: return "dictation_start"
        case .dictationStop: return "dictation_stop"
        case .dictationCancel: return "dictation_cancel"
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

/// Wire bounds for per-take dictation vocabulary.
///
/// No current Apple source fills this list. Keep the encoder and `SpeechAnalyzer.setContext`
/// path so a future vocabulary source can attach phrases without a protocol change.
/// Do not send conversation text. Reintroduce an explicit Server opt-in if phrases leave the device.
///
/// Client code prepares a list that cannot violate these limits. The server
/// rejects malformed supplied context with a predictable error and does not
/// echo the phrases.
enum DictationContextualStrings {
    static let maxPhraseCount = 100
    static let maxPhraseUTF8Bytes = 256
    static let maxTotalUTF8Bytes = 8192

    /// Normalize phrases into a legal `dictation_start` payload.
    /// Control characters are judged on the supplied string; remaining phrases
    /// are trimmed with the shared blank policy before UTF-8 budgets.
    static func prepared(_ phrases: [String]) -> [String] {
        var result: [String] = []
        var totalBytes = 0
        result.reserveCapacity(min(maxPhraseCount, phrases.count))
        for raw in phrases {
            guard !containsControl(raw) else { continue }
            let phrase = trimBlanks(raw)
            guard !phrase.isEmpty else { continue }
            let bytes = phrase.utf8.count
            guard bytes <= maxPhraseUTF8Bytes else { continue }
            guard totalBytes + bytes <= maxTotalUTF8Bytes else { break }
            result.append(phrase)
            totalBytes += bytes
            if result.count == maxPhraseCount { break }
        }
        return result
    }

    private static let blankScalars: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D,
        0x20, 0x85, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
        0x200B, 0xFEFF,
    ]

    private static func containsControl(_ phrase: String) -> Bool {
        phrase.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
        }
    }

    private static func isBlank(_ value: UInt32) -> Bool {
        blankScalars.contains(value)
    }

    private static func trimBlanks(_ raw: String) -> String {
        let scalars = raw.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isBlank($0.value) }) else { return "" }
        guard let last = scalars.lastIndex(where: { !isBlank($0.value) }) else { return "" }
        return String(scalars[first...last])
    }
}
