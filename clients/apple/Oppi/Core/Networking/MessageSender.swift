import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "MessageSender")

/// Encapsulates the send/ack/retry protocol for client-to-server messages.
///
/// Extracted from `ServerConnection` to isolate the transport send path
/// (message framing, turn ack correlation, command request/response, retry)
/// from session lifecycle, store orchestration, and stream routing.
///
/// Owned by `ServerConnection` as a `let` property. Higher-level code
/// calls convenience methods (sendPrompt, sendStop, etc.) which delegate
/// to the core `dispatchSend` → `wsClient.send` path.
@MainActor
final class MessageSender {

    // MARK: - Dependencies

    /// The command tracker for ack/result correlation.
    let commands: CommandTracker

    /// WebSocket client — set/cleared by ServerConnection on connect/disconnect.
    weak var wsClient: WebSocketClient?

    /// Active session ID — read from ServerConnection for envelope framing.
    var activeSessionId: String?

    // MARK: - Constants

    static let sendAckTimeoutDefault: Duration = .seconds(4)
    static let turnSendRetryDelay: Duration = .milliseconds(250)
    static let turnSendMaxAttempts = 2
    static let turnSendRequiredStage: TurnAckStage = .dispatched

    /// Baseline request timeout for fast RPC-style commands.
    static let commandRequestTimeoutDefault: Duration = .seconds(8)

    /// Route-specific timeout presets for long-running commands.
    static let commandRequestTimeoutTreeNavigateSummarize: Duration = .seconds(60)
    static let commandRequestTimeoutCompact: Duration = .seconds(60)
    static let commandRequestTimeoutShareSessionPrepare: Duration = .seconds(45)
    static let commandRequestTimeoutShareSessionPublish: Duration = .seconds(90)

    static let stopRetryDelay: Duration = .milliseconds(250)
    static let stopMaxAttempts = 3
    static let stopCommandTimeout: Duration = .seconds(1)

    // MARK: - Test Hooks

    var _sendMessageForTesting: ((ClientMessage) async throws -> Void)?
    var _sendAckTimeoutForTesting: Duration?

    // MARK: - Init

    init(commands: CommandTracker = CommandTracker()) {
        self.commands = commands
    }

    // MARK: - Core Send

    /// Send any client message through the WebSocket.
    func send(_ message: ClientMessage) async throws {
        try await dispatchSend(message)
    }

    func dispatchSend(_ message: ClientMessage, sessionIdOverride: String? = nil) async throws {
        if let sendHook = _sendMessageForTesting {
            try await sendHook(message)
            return
        }

        guard let wsClient else { throw WebSocketError.notConnected }

        let targetSessionId = sessionIdOverride ?? activeSessionId

        // Session-scoped messages require a valid session envelope.
        // During the reconnect gap (disconnectSession clears it, streamSession
        // re-sets it), messages sent without session scope reach the server but
        // can't be routed — the server silently drops them, no ack arrives,
        // and the user waits for the full ack timeout with no feedback.
        // Fail fast so the error handler can restore the text immediately.
        if targetSessionId == nil, !Self.isSessionLevelCommand(message) {
            logger.error("SEND blocked: targetSessionId is nil for session-scoped \(message.typeLabel, privacy: .public)")
            throw WebSocketError.notConnected
        }

        try await wsClient.send(message, sessionId: targetSessionId)
    }

    /// Returns true for messages that don't require a session envelope
    /// (subscribe, unsubscribe, permission responses).
    private static func isSessionLevelCommand(_ message: ClientMessage) -> Bool {
        switch message {
        case .subscribe, .unsubscribe, .permissionResponse:
            return true
        default:
            return false
        }
    }

    /// Standard timeout policy for command requests.
    ///
    /// Keep short defaults for snappy RPCs and assign longer budgets to known
    /// long-running routes.
    static func defaultCommandTimeout(command: String, message: ClientMessage) -> Duration {
        switch command {
        case "navigate_tree":
            if case .navigateTree(_, let summarize, _, _, _, _) = message,
               summarize {
                return commandRequestTimeoutTreeNavigateSummarize
            }
            return commandRequestTimeoutDefault

        case "compact":
            return commandRequestTimeoutCompact

        case "share_session":
            if case .shareSession(let action, _, _) = message,
               action == .prepare {
                return commandRequestTimeoutShareSessionPrepare
            }
            return commandRequestTimeoutShareSessionPublish

        default:
            return commandRequestTimeoutDefault
        }
    }

    // MARK: - Turn Send with Ack

    /// Send a turn message (prompt/steer/follow_up) and await server ack.
    ///
    /// Retries on reconnectable send errors up to `turnSendMaxAttempts`.
    /// Uses request/response correlation (`requestId`) plus `clientTurnId`
    /// idempotency so reconnect retries do not duplicate work.
    func sendTurnWithAck(
        requestId: String,
        clientTurnId: String,
        command: String,
        onAckStage: ((TurnAckStage) -> Void)? = nil,
        message: () -> ClientMessage
    ) async throws {
        if _sendMessageForTesting == nil {
            guard wsClient != nil else { throw WebSocketError.notConnected }
            guard activeSessionId != nil else {
                logger.error("SEND \(command, privacy: .public) blocked: no active session (reconnect gap)")
                throw WebSocketError.notConnected
            }
        }

        let pending = PendingTurnSend(
            command: command,
            requestId: requestId,
            clientTurnId: clientTurnId,
            onAckStage: onAckStage
        )
        commands.registerTurnSend(pending)

        var lastError: Error?

        for attempt in 1...Self.turnSendMaxAttempts {
            if attempt > 1 {
                pending.resetWaiter()
                try? await Task.sleep(for: Self.turnSendRetryDelay)

                // Re-check after sleep: activeSessionId may have been cleared
                // by disconnectSession() during the retry delay.
                if _sendMessageForTesting == nil, activeSessionId == nil {
                    let error = WebSocketError.notConnected
                    pending.waiter.resolve(.failure(error))
                    commands.unregisterTurnSend(requestId: requestId, clientTurnId: clientTurnId)
                    throw error
                }
            }

            do {
                try await dispatchSend(message())
            } catch {
                lastError = error
                if attempt < Self.turnSendMaxAttempts, CommandTracker.isReconnectableSendError(error) {
                    continue
                }
                pending.waiter.resolve(.failure(error))
                commands.unregisterTurnSend(requestId: requestId, clientTurnId: clientTurnId)
                throw error
            }

            do {
                try await waitForSendAck(waiter: pending.waiter, command: command)

                commands.unregisterTurnSend(requestId: requestId, clientTurnId: clientTurnId)
                return
            } catch {
                lastError = error
                if attempt < Self.turnSendMaxAttempts, CommandTracker.isReconnectableSendError(error) {
                    continue
                }
                commands.unregisterTurnSend(requestId: requestId, clientTurnId: clientTurnId)
                throw error
            }
        }

        commands.unregisterTurnSend(requestId: requestId, clientTurnId: clientTurnId)
        throw lastError ?? SendAckError.timeout(command: command)
    }

    private func waitForSendAck(waiter: SendAckWaiter, command: String) async throws {
        let timeout = _sendAckTimeoutForTesting ?? Self.sendAckTimeoutDefault
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await waiter.wait()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SendAckError.timeout(command: command)
            }

            do {
                try await group.next()
                group.cancelAll()
            } catch {
                // CRITICAL: resolve waiter on timeout so task group can drain.
                // waiter.wait() uses a CheckedContinuation that ignores task
                // cancellation. Without explicit resolve, the waiter task blocks
                // forever and the task group never finishes (2026-02-09 hang fix).
                if let sendAckError = error as? SendAckError,
                   case .timeout = sendAckError {
                    waiter.resolve(.failure(sendAckError))
                }
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Command Request/Response

    /// Send a command and await its result via CommandTracker correlation.
    ///
    /// Timeout defaults are chosen via `defaultCommandTimeout(command:message:)`
    /// so long-running command routes can opt into larger budgets centrally.
    func sendCommandAwaitingResult(
        command: String,
        timeout: Duration? = nil,
        message: (String) -> ClientMessage
    ) async throws -> JSONValue? {
        if _sendMessageForTesting == nil, wsClient == nil {
            throw WebSocketError.notConnected
        }

        let requestId = UUID().uuidString
        let outboundMessage = message(requestId)
        let effectiveTimeout = timeout ?? Self.defaultCommandTimeout(
            command: command,
            message: outboundMessage
        )

        let pending = PendingCommand(command: command, requestId: requestId)
        commands.registerCommand(pending)

        do {
            try await dispatchSend(outboundMessage)
        } catch {
            commands.unregisterCommand(requestId: requestId)
            pending.waiter.resolve(.failure(error))
            throw error
        }

        do {
            let response = try await waitForCommandResult(
                waiter: pending.waiter,
                command: command,
                timeout: effectiveTimeout
            )
            commands.unregisterCommand(requestId: requestId)
            return response.data
        } catch {
            commands.unregisterCommand(requestId: requestId)
            throw error
        }
    }

    private func waitForCommandResult(
        waiter: CommandResultWaiter,
        command: String,
        timeout: Duration
    ) async throws -> CommandResultPayload {
        try await withThrowingTaskGroup(of: CommandResultPayload.self) { group in
            group.addTask {
                try await waiter.wait()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CommandRequestError.timeout(command: command)
            }

            do {
                guard let result = try await group.next() else {
                    throw CommandRequestError.timeout(command: command)
                }
                group.cancelAll()
                return result
            } catch {
                if let cmdError = error as? CommandRequestError,
                   case .timeout = cmdError {
                    waiter.resolve(.failure(cmdError))
                }
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Convenience: Turn Messages

    func sendPrompt(
        _ text: String,
        images: [ImageAttachment]? = nil,
        onAckStage: ((TurnAckStage) -> Void)? = nil
    ) async throws {
        let requestId = UUID().uuidString
        let clientTurnId = UUID().uuidString
        try await sendTurnWithAck(
            requestId: requestId,
            clientTurnId: clientTurnId,
            command: "prompt",
            onAckStage: onAckStage
        ) {
            .prompt(message: text, images: images, requestId: requestId, clientTurnId: clientTurnId)
        }
    }

    func sendSteer(
        _ text: String,
        images: [ImageAttachment]? = nil,
        onAckStage: ((TurnAckStage) -> Void)? = nil
    ) async throws {
        let requestId = UUID().uuidString
        let clientTurnId = UUID().uuidString
        let startedAt = ContinuousClock.now

        do {
            try await sendTurnWithAck(
                requestId: requestId,
                clientTurnId: clientTurnId,
                command: "steer",
                onAckStage: onAckStage
            ) {
                .steer(message: text, images: images, requestId: requestId, clientTurnId: clientTurnId)
            }
            Self.recordQueueAckMetric(command: "steer", startedAt: startedAt, status: "ok", sessionId: activeSessionId)
        } catch {
            Self.recordQueueAckMetric(
                command: "steer", startedAt: startedAt, status: "error",
                errorKind: Self.telemetryErrorKind(from: error), sessionId: activeSessionId
            )
            throw error
        }
    }

    func sendFollowUp(
        _ text: String,
        images: [ImageAttachment]? = nil,
        onAckStage: ((TurnAckStage) -> Void)? = nil
    ) async throws {
        let requestId = UUID().uuidString
        let clientTurnId = UUID().uuidString
        let startedAt = ContinuousClock.now

        do {
            try await sendTurnWithAck(
                requestId: requestId,
                clientTurnId: clientTurnId,
                command: "follow_up",
                onAckStage: onAckStage
            ) {
                .followUp(message: text, images: images, requestId: requestId, clientTurnId: clientTurnId)
            }
            Self.recordQueueAckMetric(command: "follow_up", startedAt: startedAt, status: "ok", sessionId: activeSessionId)
        } catch {
            Self.recordQueueAckMetric(
                command: "follow_up", startedAt: startedAt, status: "error",
                errorKind: Self.telemetryErrorKind(from: error), sessionId: activeSessionId
            )
            throw error
        }
    }

    func sendStop() async throws {
        var lastError: Error?

        for attempt in 1...Self.stopMaxAttempts {
            do {
                _ = try await sendCommandAwaitingResult(
                    command: "stop",
                    timeout: Self.stopCommandTimeout
                ) { requestId in
                    .stop(requestId: requestId)
                }
                return
            } catch {
                lastError = error
                guard attempt < Self.stopMaxAttempts,
                      Self.isRetryableStopError(error) else {
                    throw error
                }
                try? await Task.sleep(for: Self.stopRetryDelay)
            }
        }

        throw lastError ?? WebSocketError.notConnected
    }

    func sendStopSession() async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.stopSession(), sessionId: activeSessionId)
    }

    // MARK: - Convenience: Commands

    func requestState() async throws {
        try await send(.getState())
    }

    func requestMessageQueue(timeout: Duration = MessageSender.commandRequestTimeoutDefault) async throws {
        _ = try await sendCommandAwaitingResult(command: "get_queue", timeout: timeout) { requestId in
            .getQueue(requestId: requestId)
        }
    }

    func setMessageQueue(
        baseVersion: Int,
        steering: [MessageQueueDraftItem],
        followUp: [MessageQueueDraftItem]
    ) async throws {
        _ = try await sendCommandAwaitingResult(command: "set_queue") { requestId in
            .setQueue(
                baseVersion: baseVersion,
                steering: steering,
                followUp: followUp,
                requestId: requestId
            )
        }
    }

    func getForkMessages() async throws -> [ForkMessage] {
        let data = try await sendCommandAwaitingResult(command: "get_fork_messages") { requestId in
            .getForkMessages(requestId: requestId)
        }

        guard let values = data?.objectValue?["messages"]?.arrayValue else {
            return []
        }

        return values.compactMap { value in
            guard let object = value.objectValue else {
                return nil
            }

            let entryId =
                object["entryId"]?.stringValue
                ?? object["id"]?.stringValue
                ?? object["messageId"]?.stringValue

            guard let entryId,
                  !entryId.isEmpty else {
                return nil
            }

            return ForkMessage(
                entryId: entryId,
                text: object["text"]?.stringValue ?? object["content"]?.stringValue ?? ""
            )
        }
    }

    func getSessionTree(filterMode: SessionTreeFilterMode = .standard) async throws -> SessionTreeSnapshot {
        let data = try await sendCommandAwaitingResult(command: "get_session_tree") { requestId in
            .getSessionTree(filterMode: filterMode, requestId: requestId)
        }

        return try Self.parseSessionTreeSnapshot(from: data)
    }

    func navigateTree(
        targetId: String,
        summarize: Bool,
        customInstructions: String? = nil,
        replaceInstructions: Bool? = nil,
        label: String? = nil
    ) async throws -> NavigateTreeResult {
        let data = try await sendCommandAwaitingResult(command: "navigate_tree") { requestId in
            .navigateTree(
                targetId: targetId,
                summarize: summarize,
                customInstructions: customInstructions,
                replaceInstructions: replaceInstructions,
                label: label,
                requestId: requestId
            )
        }

        return try Self.parseNavigateTreeResult(from: data)
    }

    private static func parseSessionTreeSnapshot(from data: JSONValue?) throws -> SessionTreeSnapshot {
        let command = "get_session_tree"
        let root = try requireRootObject(data, command: command)

        let leafId = try readOptionalString(
            valueForAnyKey(["leafId", "leaf_id"], in: root),
            command: command,
            field: "leafId"
        )

        guard let rawNodes = root["nodes"]?.arrayValue else {
            throw invalidPayload(command: command, detail: "nodes must be an array")
        }

        let nodes = try rawNodes.enumerated().map { index, value in
            try parseSessionTreeNode(from: value, index: index)
        }

        return SessionTreeSnapshot(leafId: leafId, nodes: nodes)
    }

    private static func parseSessionTreeNode(
        from value: JSONValue,
        index: Int
    ) throws -> SessionTreeNodeSnapshot {
        let command = "get_session_tree"
        guard let object = value.objectValue else {
            throw invalidPayload(command: command, detail: "nodes[\(index)] must be an object")
        }

        let fieldPrefix = "nodes[\(index)]"
        let id = try readRequiredString(object["id"], command: command, field: "\(fieldPrefix).id")
        let parentIdRaw = try readOptionalString(
            valueForAnyKey(["parentId", "parent_id"], in: object),
            command: command,
            field: "\(fieldPrefix).parentId"
        )
        let type = try readRequiredString(
            object["type"],
            command: command,
            field: "\(fieldPrefix).type"
        )
        let timestamp = try readRequiredString(
            object["timestamp"],
            command: command,
            field: "\(fieldPrefix).timestamp"
        )
        let depth = try readRequiredInt(
            object["depth"],
            command: command,
            field: "\(fieldPrefix).depth"
        )
        let isLeafPath = try readRequiredBool(
            valueForAnyKey(["isLeafPath", "is_leaf_path"], in: object),
            command: command,
            field: "\(fieldPrefix).isLeafPath"
        )
        let defaultVisible = try readOptionalBool(
            valueForAnyKey(["defaultVisible", "default_visible"], in: object),
            command: command,
            field: "\(fieldPrefix).defaultVisible"
        ) ?? true
        let matchesFilter = try readOptionalBool(
            valueForAnyKey(["matchesFilter", "matches_filter"], in: object),
            command: command,
            field: "\(fieldPrefix).matchesFilter"
        ) ?? defaultVisible
        let role = try readOptionalString(
            object["role"],
            command: command,
            field: "\(fieldPrefix).role"
        )
        let textPreview = try readOptionalString(
            valueForAnyKey(["textPreview", "text_preview"], in: object),
            command: command,
            field: "\(fieldPrefix).textPreview"
        )
        let label = try readOptionalString(
            object["label"],
            command: command,
            field: "\(fieldPrefix).label"
        )

        return SessionTreeNodeSnapshot(
            id: id,
            parentId: parentIdRaw?.isEmpty == false ? parentIdRaw : nil,
            type: type,
            timestamp: timestamp,
            depth: depth,
            isLeafPath: isLeafPath,
            defaultVisible: defaultVisible,
            matchesFilter: matchesFilter,
            role: role,
            textPreview: textPreview,
            label: label
        )
    }

    private static func parseNavigateTreeResult(from data: JSONValue?) throws -> NavigateTreeResult {
        let command = "navigate_tree"
        let root = try requireRootObject(data, command: command)

        let editorText = try readOptionalString(
            valueForAnyKey(["editorText", "editor_text"], in: root),
            command: command,
            field: "editorText"
        )
        let cancelled = try readRequiredBool(
            root["cancelled"],
            command: command,
            field: "cancelled"
        )
        let aborted = try readOptionalBool(
            root["aborted"],
            command: command,
            field: "aborted"
        )
        let summaryEntry = try parseNavigateTreeSummaryEntry(
            valueForAnyKey(["summaryEntry", "summary_entry"], in: root),
            command: command
        )

        return NavigateTreeResult(
            editorText: editorText,
            cancelled: cancelled,
            aborted: aborted,
            summaryEntry: summaryEntry
        )
    }

    private static func parseNavigateTreeSummaryEntry(
        _ value: JSONValue?,
        command: String
    ) throws -> NavigateTreeSummaryEntrySnapshot? {
        guard let value else { return nil }
        if case .null = value {
            return nil
        }

        guard let object = value.objectValue else {
            throw invalidPayload(command: command, detail: "summaryEntry must be an object")
        }

        let id = try readRequiredString(object["id"], command: command, field: "summaryEntry.id")
        return NavigateTreeSummaryEntrySnapshot(id: id)
    }

    private static func requireRootObject(
        _ data: JSONValue?,
        command: String
    ) throws -> [String: JSONValue] {
        guard let data else {
            throw invalidPayload(command: command, detail: "missing data")
        }

        guard let root = data.objectValue else {
            throw invalidPayload(command: command, detail: "expected root object")
        }

        return root
    }

    private static func valueForAnyKey(
        _ keys: [String],
        in object: [String: JSONValue]
    ) -> JSONValue? {
        for key in keys {
            if let value = object[key] {
                return value
            }
        }
        return nil
    }

    private static func readRequiredString(
        _ value: JSONValue?,
        command: String,
        field: String
    ) throws -> String {
        guard let value else {
            throw invalidPayload(command: command, detail: "missing \(field)")
        }

        guard let text = value.stringValue else {
            throw invalidPayload(command: command, detail: "\(field) must be a string")
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalidPayload(command: command, detail: "\(field) cannot be empty")
        }

        return text
    }

    private static func readOptionalString(
        _ value: JSONValue?,
        command: String,
        field: String
    ) throws -> String? {
        guard let value else { return nil }
        if case .null = value {
            return nil
        }

        guard let text = value.stringValue else {
            throw invalidPayload(command: command, detail: "\(field) must be a string")
        }

        return text
    }

    private static func readRequiredInt(
        _ value: JSONValue?,
        command: String,
        field: String
    ) throws -> Int {
        guard let value else {
            throw invalidPayload(command: command, detail: "missing \(field)")
        }

        guard let number = value.numberValue,
              number.isFinite,
              number.rounded() == number,
              let int = Int(exactly: number) else {
            throw invalidPayload(command: command, detail: "\(field) must be an integer")
        }

        return int
    }

    private static func readRequiredBool(
        _ value: JSONValue?,
        command: String,
        field: String
    ) throws -> Bool {
        guard let value else {
            throw invalidPayload(command: command, detail: "missing \(field)")
        }

        guard let bool = value.boolValue else {
            throw invalidPayload(command: command, detail: "\(field) must be a boolean")
        }

        return bool
    }

    private static func readOptionalBool(
        _ value: JSONValue?,
        command: String,
        field: String
    ) throws -> Bool? {
        guard let value else { return nil }
        if case .null = value {
            return nil
        }

        guard let bool = value.boolValue else {
            throw invalidPayload(command: command, detail: "\(field) must be a boolean")
        }

        return bool
    }

    private static func invalidPayload(command: String, detail: String) -> CommandRequestError {
        CommandRequestError.rejected(command: command, reason: "invalid payload: \(detail)")
    }

    // MARK: - Retry Classification

    static func isRetryableStopError(_ error: Error) -> Bool {
        if let cmdError = error as? CommandRequestError {
            switch cmdError {
            case .timeout(let command):
                return command == "stop"
            case .rejected(let command, let reason):
                guard command == "stop" else { return false }
                return reason?.contains("not subscribed at level=full") == true
            }
        }

        return CommandTracker.isReconnectableSendError(error)
    }

    // MARK: - Telemetry Helpers

    static func telemetryErrorKind(from error: Error) -> String {
        if error is CommandRequestError { return "command_request" }
        if error is WebSocketError { return "websocket" }
        if error is URLError { return "url" }
        if error is CancellationError { return "cancelled" }
        return "other"
    }

    static func recordQueueAckMetric(
        command: String,
        startedAt: ContinuousClock.Instant,
        status: String,
        errorKind: String? = nil,
        sessionId: String?
    ) {
        let elapsedMs = Int((ContinuousClock.now - startedAt) / .milliseconds(1))
        Task.detached(priority: .utility) {
            var tags: [String: String] = [
                "command": command,
                "status": status,
            ]
            if let errorKind {
                tags["error_kind"] = errorKind
            }
            await ChatMetricsService.shared.record(
                metric: .messageQueueAckMs,
                value: Double(elapsedMs),
                unit: .ms,
                sessionId: sessionId,
                tags: tags
            )
        }
    }
}
