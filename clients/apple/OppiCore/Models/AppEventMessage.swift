import Foundation

/// Messages received from the global `/app/events/stream` WebSocket.
///
/// This protocol is intentionally separate from `ServerMessage`: app events
/// update app/store surfaces and must never enter focused-session timeline paths.
enum AppEventMessage: Sendable, Equatable {
    case connected(serverTime: Int64, snapshotRequired: Bool)

    case sessionCreated(sessionId: String, workspaceId: String?, emittedAt: Int64, summary: SessionSummary)
    case sessionImported(sessionId: String, workspaceId: String?, emittedAt: Int64, summary: SessionSummary)
    case sessionDiscovered(sessionId: String, workspaceId: String?, emittedAt: Int64, summary: SessionSummary)
    case sessionSummary(sessionId: String, workspaceId: String?, emittedAt: Int64, summary: SessionSummary)
    case sessionDeleted(sessionId: String, workspaceId: String?, emittedAt: Int64)
    case sessionEnded(sessionId: String, workspaceId: String?, emittedAt: Int64, reason: String)

    case stopRequested(sessionId: String, workspaceId: String?, emittedAt: Int64, source: String?, reason: String?)
    case stopConfirmed(sessionId: String, workspaceId: String?, emittedAt: Int64, source: String?, reason: String?)
    case stopFailed(sessionId: String, workspaceId: String?, emittedAt: Int64, source: String?, reason: String?)

    case sessionError(sessionId: String, workspaceId: String?, emittedAt: Int64, message: String, code: String?, fatal: Bool)

    case extensionUIRequest(request: ExtensionUIRequest, workspaceId: String?, emittedAt: Int64)
    case extensionUISettled(id: String, sessionId: String, workspaceId: String?, emittedAt: Int64)
    case extensionUINotification(notification: ExtensionUINotification, sessionId: String, workspaceId: String?, emittedAt: Int64)

    case workspaceGitChanged(workspaceId: String, worktreeId: String?, emittedAt: Int64, sessionId: String?, reason: String?)

    /// Unknown or explicitly focused-stream-only frame types are decoded but ignored.
    case ignored(type: String)
}

extension AppEventMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, serverTime, snapshotRequired
        case sessionId, workspaceId, worktreeId, emittedAt, summary
        case reason, source, message, code, fatal, id
        case seq, currentSeq
    }

    private static let focusedStreamOnlyTypes: Set<String> = [
        "state",
        "connected",
        "stream_connected",
        "agent_start",
        "agent_end",
        "text_delta",
        "thinking_delta",
        "message_end",
        "tool_start",
        "tool_update",
        "tool_output",
        "tool_end",
        "command_result",
        "turn_ack",
        "queue_state",
        "queue_item_started",
        "audio_stream",
        "dictation_ready",
        "dictation_result",
        "dictation_final",
        "dictation_error",
        "error",
        "git_status",
    ]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)

        if Self.focusedStreamOnlyTypes.contains(type) {
            self = .ignored(type: type)
            return
        }

        if c.contains(.seq) || c.contains(.currentSeq) {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [CodingKeys.type],
                    debugDescription: "App event frames must not include focused stream sequence metadata"
                )
            )
        }

        switch type {
        case "app_events_connected":
            self = .connected(
                serverTime: try c.decode(Int64.self, forKey: .serverTime),
                snapshotRequired: try c.decodeIfPresent(Bool.self, forKey: .snapshotRequired) ?? false
            )

        case "session_created":
            self = try Self.decodeSessionSummaryEvent(from: c, kind: .created)
        case "session_imported":
            self = try Self.decodeSessionSummaryEvent(from: c, kind: .imported)
        case "session_discovered":
            self = try Self.decodeSessionSummaryEvent(from: c, kind: .discovered)
        case "session_summary":
            self = try Self.decodeSessionSummaryEvent(from: c, kind: .summary)

        case "session_deleted":
            self = .sessionDeleted(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                workspaceId: try c.decodeIfPresent(String.self, forKey: .workspaceId),
                emittedAt: try c.decode(Int64.self, forKey: .emittedAt)
            )

        case "session_ended":
            self = .sessionEnded(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                workspaceId: try c.decodeIfPresent(String.self, forKey: .workspaceId),
                emittedAt: try c.decode(Int64.self, forKey: .emittedAt),
                reason: try c.decode(String.self, forKey: .reason)
            )

        case "stop_requested":
            self = try Self.decodeStopEvent(from: c, kind: .requested)
        case "stop_confirmed":
            self = try Self.decodeStopEvent(from: c, kind: .confirmed)
        case "stop_failed":
            self = try Self.decodeStopEvent(from: c, kind: .failed)

        case "session_error":
            self = .sessionError(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                workspaceId: try c.decodeIfPresent(String.self, forKey: .workspaceId),
                emittedAt: try c.decode(Int64.self, forKey: .emittedAt),
                message: try c.decode(String.self, forKey: .message),
                code: try c.decodeIfPresent(String.self, forKey: .code),
                fatal: try c.decodeIfPresent(Bool.self, forKey: .fatal) ?? false
            )

        case "extension_ui_request":
            let request = try ExtensionUIRequest(from: decoder)
            self = .extensionUIRequest(
                request: request,
                workspaceId: try c.decodeIfPresent(String.self, forKey: .workspaceId),
                emittedAt: try c.decode(Int64.self, forKey: .emittedAt)
            )

        case "extension_ui_settled":
            self = .extensionUISettled(
                id: try c.decode(String.self, forKey: .id),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                workspaceId: try c.decodeIfPresent(String.self, forKey: .workspaceId),
                emittedAt: try c.decode(Int64.self, forKey: .emittedAt)
            )

        case "extension_ui_notification":
            let notification = try ExtensionUINotification(from: decoder)
            self = .extensionUINotification(
                notification: notification,
                sessionId: try c.decode(String.self, forKey: .sessionId),
                workspaceId: try c.decodeIfPresent(String.self, forKey: .workspaceId),
                emittedAt: try c.decode(Int64.self, forKey: .emittedAt)
            )

        case "workspace_git_changed":
            self = .workspaceGitChanged(
                workspaceId: try c.decode(String.self, forKey: .workspaceId),
                worktreeId: try c.decodeIfPresent(String.self, forKey: .worktreeId),
                emittedAt: try c.decode(Int64.self, forKey: .emittedAt),
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId),
                reason: try c.decodeIfPresent(String.self, forKey: .reason)
            )

        default:
            self = .ignored(type: type)
        }
    }

    private enum SessionSummaryKind {
        case created, imported, discovered, summary
    }

    private static func decodeSessionSummaryEvent(
        from c: KeyedDecodingContainer<CodingKeys>,
        kind: SessionSummaryKind
    ) throws -> AppEventMessage {
        let sessionId = try c.decode(String.self, forKey: .sessionId)
        let workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        let emittedAt = try c.decode(Int64.self, forKey: .emittedAt)
        let summary = try c.decode(SessionSummary.self, forKey: .summary)

        switch kind {
        case .created:
            return .sessionCreated(sessionId: sessionId, workspaceId: workspaceId, emittedAt: emittedAt, summary: summary)
        case .imported:
            return .sessionImported(sessionId: sessionId, workspaceId: workspaceId, emittedAt: emittedAt, summary: summary)
        case .discovered:
            return .sessionDiscovered(sessionId: sessionId, workspaceId: workspaceId, emittedAt: emittedAt, summary: summary)
        case .summary:
            return .sessionSummary(sessionId: sessionId, workspaceId: workspaceId, emittedAt: emittedAt, summary: summary)
        }
    }

    private enum StopKind {
        case requested, confirmed, failed
    }

    private static func decodeStopEvent(
        from c: KeyedDecodingContainer<CodingKeys>,
        kind: StopKind
    ) throws -> AppEventMessage {
        let sessionId = try c.decode(String.self, forKey: .sessionId)
        let workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        let emittedAt = try c.decode(Int64.self, forKey: .emittedAt)
        let source = try c.decodeIfPresent(String.self, forKey: .source)
        let reason = try c.decodeIfPresent(String.self, forKey: .reason)

        switch kind {
        case .requested:
            return .stopRequested(sessionId: sessionId, workspaceId: workspaceId, emittedAt: emittedAt, source: source, reason: reason)
        case .confirmed:
            return .stopConfirmed(sessionId: sessionId, workspaceId: workspaceId, emittedAt: emittedAt, source: source, reason: reason)
        case .failed:
            return .stopFailed(sessionId: sessionId, workspaceId: workspaceId, emittedAt: emittedAt, source: source, reason: reason)
        }
    }

    static func decode(from text: String) throws -> AppEventMessage {
        guard let data = text.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid UTF-8 in app event stream message")
            )
        }
        return try JSONDecoder().decode(AppEventMessage.self, from: data)
    }
}
