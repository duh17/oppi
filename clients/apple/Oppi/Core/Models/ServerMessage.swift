import Foundation

/// Messages received from the server over WebSocket.
///
/// Manual Decodable with `type` discriminator. Unknown types decode to
/// `.unknown` instead of throwing — future server additions remain non-fatal.
/// Server-provided STT backend metadata, sent with `dictation_ready`.
/// Used to tag client metrics with the actual provider/model the server is using.
struct DictationProviderInfo: Sendable, Equatable {
    let sttProvider: String
    let sttModel: String
}

struct DictationTranscriptSplit: Sendable, Equatable {
    let committedText: String?
    let activeText: String?
}

enum AudioPlaybackBehavior: String, Codable, Sendable, Equatable {
    case tapToPlay
    case playNow
}

struct AudioStreamMessage: Sendable, Equatable {
    enum StreamEvent: String, Codable, Sendable {
        case metadata
        case chunk
        case done
        case error
    }

    let id: String
    let event: StreamEvent
    let mimeType: String
    let sampleRate: Int?
    let channels: Int?
    let chunkIndex: Int?
    let audioBase64: String?
    let text: String?
    let durationSeconds: Double?
    let playbackBehavior: AudioPlaybackBehavior?
}

enum ServerMessage: Sendable, Equatable {
    // Connection lifecycle
    case streamConnected(userName: String, serverDictationAvailable: Bool)
    case connected(session: Session)
    case state(session: Session)
    case sessionSummary(SessionSummary)
    case sessionEnded(reason: String)
    case sessionDeleted(sessionId: String)
    case stopRequested(source: StopLifecycleSource, reason: String?)
    case stopConfirmed(source: StopLifecycleSource, reason: String?)
    case stopFailed(source: StopLifecycleSource, reason: String)

    // Agent streaming
    case agentStart
    case agentEnd
    case messageEnd(role: String, content: String)
    case textDelta(delta: String)
    case thinkingDelta(delta: String, contentIndex: Int? = nil)
    case audioStream(AudioStreamMessage)

    // Tool execution
    case toolStart(tool: String, args: [String: JSONValue], toolCallId: String?, callSegments: [StyledSegment]?)
    case toolUpdate(tool: String, args: [String: JSONValue], toolCallId: String?, callSegments: [StyledSegment]?)
    case toolOutput(output: String, isError: Bool, toolCallId: String?, mode: ToolOutputMode, truncated: Bool, totalBytes: Int?, details: JSONValue?)
    case toolEnd(tool: String, toolCallId: String?, details: JSONValue?, isError: Bool, resultSegments: [StyledSegment]?)

    // Message queue
    case queueState(queue: MessageQueueState)
    case queueItemStarted(kind: MessageQueueKind, item: MessageQueueItem, queueVersion: Int)

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

    // Extension UI
    case extensionUIRequest(ExtensionUIRequest)
    case extensionUINotification(ExtensionUINotification)
    case extensionUISettled(id: String, sessionId: String)

    // Git status (workspace-level, pushed after file-mutating tool calls)
    case gitStatus(workspaceId: String, status: GitStatus)

    // Dictation (session audio stream)
    case dictationReady(provider: DictationProviderInfo?)
    case dictationResult(text: String, snap: Bool, split: DictationTranscriptSplit? = nil)
    case dictationFinal(text: String, split: DictationTranscriptSplit? = nil)
    case dictationError(error: String, fatal: Bool)

    // Errors
    case error(message: String, code: String?, fatal: Bool)

    // Unknown server message types are skipped, not fatal.
    case unknown(type: String)
}

// MARK: - Tool Output Mode

/// Transport mode for tool output: append (default delta) or replace (bounded tail preview).
enum ToolOutputMode: String, Codable, Sendable {
    case append
    case replace
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
    var timeoutAt: Date?
    // Ask extension fields (method: "ask")
    var askQuestions: [AskQuestion]?
    var allowCustom: Bool?

    init(
        id: String,
        sessionId: String,
        method: String,
        title: String? = nil,
        options: [String]? = nil,
        message: String? = nil,
        placeholder: String? = nil,
        prefill: String? = nil,
        timeout: Int? = nil,
        timeoutAt: Date? = nil,
        askQuestions: [AskQuestion]? = nil,
        allowCustom: Bool? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.method = method
        self.title = title
        self.options = options
        self.message = message
        self.placeholder = placeholder
        self.prefill = prefill
        self.timeout = timeout
        self.timeoutAt = timeoutAt
        self.askQuestions = askQuestions
        self.allowCustom = allowCustom
    }
}

struct ExtensionUINotification: Sendable, Equatable {
    let method: String
    let message: String?
    let notifyType: String?
    let statusKey: String?
    let statusText: String?
    let title: String?
    let text: String?
    let widgetKey: String?
    let widgetLines: [String]?
    let widgetPlacement: String?
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
        case userName, serverDictationAvailable
        // connected / state / session projection
        case session
        // session_ended / stop lifecycle
        case reason, source
        // message_end / text_delta / thinking_delta / audio_stream
        case role, content, delta, contentIndex, event, mimeType, sampleRate, channels, chunkIndex, audioBase64, durationSeconds, playbackBehavior
        // tool_start / tool_update / tool_end
        case tool, args, toolCallId, details, callSegments, resultSegments
        // tool_output
        case output, isError, mode, truncated, totalBytes
        // turn_ack
        case stage, clientTurnId, duplicate
        // error
        case error, code, fatal
        case id, sessionId, timeoutAt
        // extension_ui_request
        case method, title, options, message, placeholder, prefill, timeout
        // ask extension (extension_ui_request with method: "ask")
        case questions, allowCustom
        // extension_ui_notification
        case notifyType, statusKey, statusText, widgetKey, widgetLines, widgetPlacement
        // command_result
        case command, requestId, success, data
        // message queue
        case queue, kind, item, queueVersion
        // compaction
        case aborted, willRetry, summary, tokensBefore
        // retry
        case attempt, maxAttempts, delayMs, errorMessage, finalError
        // git_status
        case workspaceId, status
        // dictation
        case sttProvider, sttModel
        case text, snap, committedText, activeText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)

        switch type {
        case "stream_connected":
            let userName = try c.decode(String.self, forKey: .userName)
            let serverDictationAvailable = try c.decode(Bool.self, forKey: .serverDictationAvailable)
            self = .streamConnected(userName: userName, serverDictationAvailable: serverDictationAvailable)

        case "connected":
            let session = try c.decode(Session.self, forKey: .session)
            self = .connected(session: session)

        case "state":
            let session = try c.decode(Session.self, forKey: .session)
            self = .state(session: session)

        case "session_summary":
            let summary = try c.decode(SessionSummary.self, forKey: .summary)
            self = .sessionSummary(summary)

        case "session_ended":
            let reason = try c.decode(String.self, forKey: .reason)
            self = .sessionEnded(reason: reason)

        case "session_deleted":
            let sid = try c.decode(String.self, forKey: .sessionId)
            self = .sessionDeleted(sessionId: sid)

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
            let contentIndex = try c.decodeIfPresent(Int.self, forKey: .contentIndex)
            self = .thinkingDelta(delta: delta, contentIndex: contentIndex)

        case "audio_stream":
            let stream = AudioStreamMessage(
                id: try c.decode(String.self, forKey: .id),
                event: try c.decode(AudioStreamMessage.StreamEvent.self, forKey: .event),
                mimeType: try c.decode(String.self, forKey: .mimeType),
                sampleRate: try c.decodeIfPresent(Int.self, forKey: .sampleRate),
                channels: try c.decodeIfPresent(Int.self, forKey: .channels),
                chunkIndex: try c.decodeIfPresent(Int.self, forKey: .chunkIndex),
                audioBase64: try c.decodeIfPresent(String.self, forKey: .audioBase64),
                text: try c.decodeIfPresent(String.self, forKey: .text),
                durationSeconds: try c.decodeIfPresent(Double.self, forKey: .durationSeconds),
                playbackBehavior: try c.decodeIfPresent(AudioPlaybackBehavior.self, forKey: .playbackBehavior)
            )
            self = .audioStream(stream)

        case "tool_start":
            let tool = try c.decode(String.self, forKey: .tool)
            let args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
            let tcId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
            let callSegs = try c.decodeIfPresent([StyledSegment].self, forKey: .callSegments)
            self = .toolStart(tool: tool, args: args, toolCallId: tcId, callSegments: callSegs)

        case "tool_update":
            let tool = try c.decode(String.self, forKey: .tool)
            let args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
            let tcId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
            let callSegs = try c.decodeIfPresent([StyledSegment].self, forKey: .callSegments)
            self = .toolUpdate(tool: tool, args: args, toolCallId: tcId, callSegments: callSegs)

        case "tool_output":
            let output = try c.decode(String.self, forKey: .output)
            let isErr = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            let tcId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
            let mode = try c.decodeIfPresent(ToolOutputMode.self, forKey: .mode) ?? .append
            let truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
            let totalBytes = try c.decodeIfPresent(Int.self, forKey: .totalBytes)
            let details = try c.decodeIfPresent(JSONValue.self, forKey: .details)
            self = .toolOutput(output: output, isError: isErr, toolCallId: tcId, mode: mode, truncated: truncated, totalBytes: totalBytes, details: details)

        case "tool_end":
            let tool = try c.decode(String.self, forKey: .tool)
            let tcId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
            let details = try c.decodeIfPresent(JSONValue.self, forKey: .details)
            let isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            let resultSegs = try c.decodeIfPresent([StyledSegment].self, forKey: .resultSegments)
            self = .toolEnd(tool: tool, toolCallId: tcId, details: details, isError: isError, resultSegments: resultSegs)

        case "queue_state":
            let queue = try c.decode(MessageQueueState.self, forKey: .queue)
            self = .queueState(queue: queue)

        case "queue_item_started":
            let kind = try c.decode(MessageQueueKind.self, forKey: .kind)
            let item = try c.decode(MessageQueueItem.self, forKey: .item)
            let queueVersion = try c.decode(Int.self, forKey: .queueVersion)
            self = .queueItemStarted(kind: kind, item: item, queueVersion: queueVersion)

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

        case "command_result":
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

        case "extension_ui_request":
            let askQuestions = try c.decodeIfPresent([AskQuestion].self, forKey: .questions)
            let allowCustom = try c.decodeIfPresent(Bool.self, forKey: .allowCustom)
            let req = ExtensionUIRequest(
                id: try c.decode(String.self, forKey: .id),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                method: try c.decode(String.self, forKey: .method),
                title: try c.decodeIfPresent(String.self, forKey: .title),
                options: try c.decodeIfPresent([String].self, forKey: .options),
                message: try c.decodeIfPresent(String.self, forKey: .message),
                placeholder: try c.decodeIfPresent(String.self, forKey: .placeholder),
                prefill: try c.decodeIfPresent(String.self, forKey: .prefill),
                timeout: try c.decodeIfPresent(Int.self, forKey: .timeout),
                timeoutAt: try c.decodeIfPresent(Double.self, forKey: .timeoutAt).map { Date(timeIntervalSince1970: $0 / 1000) },
                askQuestions: askQuestions,
                allowCustom: allowCustom
            )
            self = .extensionUIRequest(req)

        case "extension_ui_settled":
            let id = try c.decode(String.self, forKey: .id)
            let sessionId = try c.decode(String.self, forKey: .sessionId)
            self = .extensionUISettled(id: id, sessionId: sessionId)

        case "extension_ui_notification":
            let method = try c.decode(String.self, forKey: .method)
            let msg = try c.decodeIfPresent(String.self, forKey: .message)
            let notifyType = try c.decodeIfPresent(String.self, forKey: .notifyType)
            let statusKey = try c.decodeIfPresent(String.self, forKey: .statusKey)
            let statusText = try c.decodeIfPresent(String.self, forKey: .statusText)
            let title = try c.decodeIfPresent(String.self, forKey: .title)
            let text = try c.decodeIfPresent(String.self, forKey: .text)
            let widgetKey = try c.decodeIfPresent(String.self, forKey: .widgetKey)
            let widgetLines = try c.decodeIfPresent([String].self, forKey: .widgetLines)
            let widgetPlacement = try c.decodeIfPresent(String.self, forKey: .widgetPlacement)
            self = .extensionUINotification(
                ExtensionUINotification(
                    method: method,
                    message: msg,
                    notifyType: notifyType,
                    statusKey: statusKey,
                    statusText: statusText,
                    title: title,
                    text: text,
                    widgetKey: widgetKey,
                    widgetLines: widgetLines,
                    widgetPlacement: widgetPlacement
                )
            )

        case "git_status":
            let workspaceId = try c.decode(String.self, forKey: .workspaceId)
            let status = try c.decode(GitStatus.self, forKey: .status)
            self = .gitStatus(workspaceId: workspaceId, status: status)

        // ── Dictation ──
        case "dictation_ready":
            let providerName = try c.decodeIfPresent(String.self, forKey: .sttProvider)
            let model = try c.decodeIfPresent(String.self, forKey: .sttModel)
            let info: DictationProviderInfo?
            if let providerName, let model {
                info = DictationProviderInfo(
                    sttProvider: providerName,
                    sttModel: model
                )
            } else {
                info = nil
            }
            self = .dictationReady(provider: info)

        case "dictation_result":
            let text = try c.decode(String.self, forKey: .text)
            let snap = try c.decodeIfPresent(Bool.self, forKey: .snap) ?? false
            let split = DictationTranscriptSplit(
                committedText: try c.decodeIfPresent(String.self, forKey: .committedText),
                activeText: try c.decodeIfPresent(String.self, forKey: .activeText)
            )
            self = .dictationResult(
                text: text,
                snap: snap,
                split: split.committedText == nil && split.activeText == nil ? nil : split
            )

        case "dictation_final":
            let text = try c.decode(String.self, forKey: .text)
            let split = DictationTranscriptSplit(
                committedText: try c.decodeIfPresent(String.self, forKey: .committedText),
                activeText: try c.decodeIfPresent(String.self, forKey: .activeText)
            )
            self = .dictationFinal(
                text: text,
                split: split.committedText == nil && split.activeText == nil ? nil : split
            )

        case "dictation_error":
            let errorMsg = try c.decode(String.self, forKey: .error)
            let fatal = try c.decodeIfPresent(Bool.self, forKey: .fatal) ?? false
            self = .dictationError(error: errorMsg, fatal: fatal)

        default:
            self = .unknown(type: type)
        }
    }
}

// MARK: - Stream Message Wrapper

/// Wraps a `ServerMessage` with stream routing metadata.
///
/// Split session streams bind the session in the URL, and the server may still
/// emit `sessionId` so the client can use the same decoder and router.
struct StreamMessage: Sendable, Equatable {
    let sessionId: String?
    let seq: Int?
    let currentSeq: Int?
    let message: ServerMessage
}

/// Transport metadata attached to the same frame as a server message.
struct InboundStreamMeta: Sendable, Equatable {
    let seq: Int?
    let currentSeq: Int?
    let receivedAtMs: Int64?
    let transportPath: ConnectionTransportPath

    init(
        seq: Int?,
        currentSeq: Int?,
        receivedAtMs: Int64? = nil,
        transportPath: ConnectionTransportPath = .paired
    ) {
        self.seq = seq
        self.currentSeq = currentSeq
        self.receivedAtMs = receivedAtMs
        self.transportPath = transportPath
    }
}

/// A decoded JSON WebSocket stream frame with its metadata kept in-band.
struct StreamFrameEvent: Sendable, Equatable {
    let sessionId: String?
    let message: ServerMessage
    let meta: InboundStreamMeta?
}

/// A session-routed stream event. Chat session consumers receive this instead
/// of reconstructing metadata from a side queue.
struct SessionStreamEvent: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case live
        case catchUp
        case replay
    }

    let sessionId: String
    let message: ServerMessage
    let meta: InboundStreamMeta?
    let source: Source
}

extension StreamMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case sessionId, seq, currentSeq
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
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
        case .sessionSummary: "sessionSummary"
        case .sessionEnded: "sessionEnded"
        case .sessionDeleted: "sessionDeleted"
        case .stopRequested: "stopRequested"
        case .stopConfirmed: "stopConfirmed"
        case .stopFailed: "stopFailed"
        case .agentStart: "agentStart"
        case .agentEnd: "agentEnd"
        case .messageEnd: "messageEnd"
        case .textDelta: "textDelta"
        case .thinkingDelta: "thinkingDelta"
        case .audioStream: "audioStream"
        case .toolStart: "toolStart"
        case .toolUpdate: "toolUpdate"
        case .toolOutput: "toolOutput"
        case .toolEnd: "toolEnd"
        case .queueState: "queueState"
        case .queueItemStarted: "queueItemStarted"
        case .turnAck: "turnAck"
        case .commandResult: "commandResult"
        case .compactionStart: "compactionStart"
        case .compactionEnd: "compactionEnd"
        case .retryStart: "retryStart"
        case .retryEnd: "retryEnd"
        case .extensionUIRequest: "extensionUIRequest"
        case .extensionUINotification: "extensionUINotification"
        case .extensionUISettled: "extensionUISettled"
        case .gitStatus: "gitStatus"
        case .dictationReady: "dictationReady"
        case .dictationResult: "dictationResult"
        case .dictationFinal: "dictationFinal"
        case .dictationError: "dictationError"
        case .error: "error"
        case .unknown(let type): "unknown(\(type))"
        }
    }

    // periphery:ignore - used by OppiTests via @testable import
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
