import Foundation

/// Messages received from the server over WebSocket.
///
/// Manual Decodable with `type` discriminator. Unknown types decode to
/// `.unknown` instead of throwing — future server additions remain non-fatal.
enum ServerMessage: Sendable, Equatable {
    // Connection lifecycle
    case streamConnected(userName: String)
    case connected(session: Session)
    case state(session: Session)
    case sessionEnded(reason: String)
    case stopRequested(source: StopLifecycleSource, reason: String?)
    case stopConfirmed(source: StopLifecycleSource, reason: String?)
    case stopFailed(source: StopLifecycleSource, reason: String)

    // Agent streaming
    case agentStart
    case agentEnd
    case messageEnd(role: String, content: String)
    case textDelta(delta: String)
    case thinkingDelta(delta: String)

    // Tool execution
    case toolStart(tool: String, args: [String: JSONValue], toolCallId: String?, callSegments: [StyledSegment]?)
    case toolOutput(output: String, isError: Bool, toolCallId: String?)
    case toolEnd(tool: String, toolCallId: String?, details: JSONValue?, isError: Bool, resultSegments: [StyledSegment]?)

    // Turn delivery acknowledgements
    case turnAck(command: String, clientTurnId: String, stage: TurnAckStage, requestId: String?, duplicate: Bool)

    // Command responses (from forwarded commands)
    case commandResult(command: String, requestId: String?, success: Bool, data: JSONValue?, error: String?)

    // Compaction
    case compactionStart(reason: String)
    case compactionEnd(aborted: Bool, willRetry: Bool, summary: String?, tokensBefore: Int?)

    // Retry
    case retryStart(attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String)
    case retryEnd(success: Bool, attempt: Int, finalError: String?)

    // Permissions
    case permissionRequest(PermissionRequest)
    case permissionExpired(id: String, reason: String)
    case permissionCancelled(id: String)

    // Extension UI
    case extensionUIRequest(ExtensionUIRequest)
    case extensionUINotification(method: String, message: String?, notifyType: String?, statusKey: String?, statusText: String?)

    // Git status (workspace-level, pushed after file-mutating tool calls)
    case gitStatus(workspaceId: String, status: GitStatus)

    // Errors
    case error(message: String, code: String?, fatal: Bool)

    // Unknown server message types are skipped, not fatal.
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

enum TurnAckStage: String, Codable, Sendable {
    case accepted
    case dispatched
    case started

    var rank: Int {
        switch self {
        case .accepted: return 1
        case .dispatched: return 2
        case .started: return 3
        }
    }
}

enum StopLifecycleSource: String, Codable, Sendable {
    case user
    case timeout
    case server
}

// MARK: - Manual Decodable

extension ServerMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case type
        // stream_connected
        case userName
        // connected / state
        case session
        // session_ended / stop lifecycle
        case reason, source
        // message_end / text_delta / thinking_delta
        case role, content, delta
        // tool_start / tool_end
        case tool, args, toolCallId, details, callSegments, resultSegments
        // tool_output
        case output, isError
        // turn_ack
        case stage, clientTurnId, duplicate
        // error
        case error, code, fatal
        // permission_request
        case id, sessionId, input, displaySummary, timeoutAt, expires
        // extension_ui_request
        case method, title, options, message, placeholder, prefill, timeout
        // extension_ui_notification
        case notifyType, statusKey, statusText
        // command_result
        case command, requestId, success, data
        // compaction
        case aborted, willRetry, summary, tokensBefore
        // retry
        case attempt, maxAttempts, delayMs, errorMessage, finalError
        // git_status
        case workspaceId, status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)

        switch type {
        case "stream_connected":
            let userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
            self = .streamConnected(userName: userName)

        case "connected":
            let session = try c.decode(Session.self, forKey: .session)
            self = .connected(session: session)

        case "state":
            let session = try c.decode(Session.self, forKey: .session)
            self = .state(session: session)

        case "session_ended":
            let reason = try c.decode(String.self, forKey: .reason)
            self = .sessionEnded(reason: reason)

        case "stop_requested":
            let source = try c.decode(StopLifecycleSource.self, forKey: .source)
            let reason = try c.decodeIfPresent(String.self, forKey: .reason)
            self = .stopRequested(source: source, reason: reason)

        case "stop_confirmed":
            let source = try c.decode(StopLifecycleSource.self, forKey: .source)
            let reason = try c.decodeIfPresent(String.self, forKey: .reason)
            self = .stopConfirmed(source: source, reason: reason)

        case "stop_failed":
            let source = try c.decode(StopLifecycleSource.self, forKey: .source)
            let reason = try c.decode(String.self, forKey: .reason)
            self = .stopFailed(source: source, reason: reason)

        case "agent_start":
            self = .agentStart

        case "agent_end":
            self = .agentEnd

        case "message_end":
            let role = try c.decode(String.self, forKey: .role)
            let content = try c.decode(String.self, forKey: .content)
            self = .messageEnd(role: role, content: content)

        case "text_delta":
            let delta = try c.decode(String.self, forKey: .delta)
            self = .textDelta(delta: delta)

        case "thinking_delta":
            let delta = try c.decode(String.self, forKey: .delta)
            self = .thinkingDelta(delta: delta)

        case "tool_start":
            let tool = try c.decode(String.self, forKey: .tool)
            let args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
            let tcId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
            let callSegs = try c.decodeIfPresent([StyledSegment].self, forKey: .callSegments)
            self = .toolStart(tool: tool, args: args, toolCallId: tcId, callSegments: callSegs)

        case "tool_output":
            let output = try c.decode(String.self, forKey: .output)
            let isErr = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            let tcId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
            self = .toolOutput(output: output, isError: isErr, toolCallId: tcId)

        case "tool_end":
            let tool = try c.decode(String.self, forKey: .tool)
            let tcId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
            let details = try c.decodeIfPresent(JSONValue.self, forKey: .details)
            let isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            let resultSegs = try c.decodeIfPresent([StyledSegment].self, forKey: .resultSegments)
            self = .toolEnd(tool: tool, toolCallId: tcId, details: details, isError: isError, resultSegments: resultSegs)

        case "turn_ack":
            let command = try c.decode(String.self, forKey: .command)
            let clientTurnId = try c.decode(String.self, forKey: .clientTurnId)
            let stage = try c.decode(TurnAckStage.self, forKey: .stage)
            let requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
            let duplicate = try c.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
            self = .turnAck(
                command: command,
                clientTurnId: clientTurnId,
                stage: stage,
                requestId: requestId,
                duplicate: duplicate
            )

        case "command_result", "rpc_result":
            let cmd = try c.decode(String.self, forKey: .command)
            let reqId = try c.decodeIfPresent(String.self, forKey: .requestId)
            let success = try c.decode(Bool.self, forKey: .success)
            let data = try c.decodeIfPresent(JSONValue.self, forKey: .data)
            let error = try c.decodeIfPresent(String.self, forKey: .error)
            self = .commandResult(command: cmd, requestId: reqId, success: success, data: data, error: error)

        case "compaction_start":
            let reason = try c.decode(String.self, forKey: .reason)
            self = .compactionStart(reason: reason)

        case "compaction_end":
            let aborted = try c.decodeIfPresent(Bool.self, forKey: .aborted) ?? false
            let willRetry = try c.decodeIfPresent(Bool.self, forKey: .willRetry) ?? false
            let summary = try c.decodeIfPresent(String.self, forKey: .summary)
            let tokensBefore = try c.decodeIfPresent(Int.self, forKey: .tokensBefore)
            self = .compactionEnd(aborted: aborted, willRetry: willRetry, summary: summary, tokensBefore: tokensBefore)

        case "retry_start":
            let attempt = try c.decode(Int.self, forKey: .attempt)
            let maxAttempts = try c.decode(Int.self, forKey: .maxAttempts)
            let delayMs = try c.decode(Int.self, forKey: .delayMs)
            let errorMessage = try c.decode(String.self, forKey: .errorMessage)
            self = .retryStart(attempt: attempt, maxAttempts: maxAttempts, delayMs: delayMs, errorMessage: errorMessage)

        case "retry_end":
            let success = try c.decode(Bool.self, forKey: .success)
            let attempt = try c.decode(Int.self, forKey: .attempt)
            let finalError = try c.decodeIfPresent(String.self, forKey: .finalError)
            self = .retryEnd(success: success, attempt: attempt, finalError: finalError)

        case "error":
            let msg = try c.decode(String.self, forKey: .error)
            let code = try c.decodeIfPresent(String.self, forKey: .code)
            let fatal = try c.decodeIfPresent(Bool.self, forKey: .fatal) ?? false
            self = .error(message: msg, code: code, fatal: fatal)

        case "permission_request":
            let perm = PermissionRequest(
                id: try c.decode(String.self, forKey: .id),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                tool: try c.decode(String.self, forKey: .tool),
                input: try c.decode([String: JSONValue].self, forKey: .input),
                displaySummary: try c.decode(String.self, forKey: .displaySummary),
                reason: try c.decode(String.self, forKey: .reason),
                timeoutAt: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .timeoutAt) / 1000),
                expires: try c.decodeIfPresent(Bool.self, forKey: .expires) ?? true
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

        case "git_status":
            let workspaceId = try c.decode(String.self, forKey: .workspaceId)
            let status = try c.decode(GitStatus.self, forKey: .status)
            self = .gitStatus(workspaceId: workspaceId, status: status)

        default:
            self = .unknown(type: type)
        }
    }
}

// MARK: - Stream Message Wrapper

/// Wraps a `ServerMessage` with the `sessionId` from the multiplexed `/stream` endpoint.
///
/// On the per-session WebSocket, `sessionId` is implicit (the URL determines it).
/// On `/stream`, every message includes `sessionId` at the top level.
struct StreamMessage: Sendable, Equatable {
    let sessionId: String?
    let streamSeq: Int?
    let seq: Int?
    let currentSeq: Int?
    let message: ServerMessage
}

extension StreamMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case sessionId, streamSeq, seq, currentSeq
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        streamSeq = try c.decodeIfPresent(Int.self, forKey: .streamSeq)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        currentSeq = try c.decodeIfPresent(Int.self, forKey: .currentSeq)
        message = try ServerMessage(from: decoder)
    }

    static func decode(from text: String) throws -> StreamMessage {
        guard let data = text.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid UTF-8 in WebSocket message")
            )
        }
        return try JSONDecoder().decode(StreamMessage.self, from: data)
    }
}

// MARK: - Decode from raw WebSocket data

extension ServerMessage {
    var typeLabel: String {
        switch self {
        case .streamConnected: "streamConnected"
        case .connected: "connected"
        case .state: "state"
        case .sessionEnded: "sessionEnded"
        case .stopRequested: "stopRequested"
        case .stopConfirmed: "stopConfirmed"
        case .stopFailed: "stopFailed"
        case .agentStart: "agentStart"
        case .agentEnd: "agentEnd"
        case .messageEnd: "messageEnd"
        case .textDelta: "textDelta"
        case .thinkingDelta: "thinkingDelta"
        case .toolStart: "toolStart"
        case .toolOutput: "toolOutput"
        case .toolEnd: "toolEnd"
        case .turnAck: "turnAck"
        case .commandResult: "commandResult"
        case .compactionStart: "compactionStart"
        case .compactionEnd: "compactionEnd"
        case .retryStart: "retryStart"
        case .retryEnd: "retryEnd"
        case .permissionRequest: "permissionRequest"
        case .permissionExpired: "permissionExpired"
        case .permissionCancelled: "permissionCancelled"
        case .extensionUIRequest: "extensionUIRequest"
        case .extensionUINotification: "extensionUINotification"
        case .gitStatus: "gitStatus"
        case .error: "error"
        case .unknown(let type): "unknown(\(type))"
        }
    }

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
