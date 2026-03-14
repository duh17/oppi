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
    static let commandRequestTimeoutDefault: Duration = .seconds(8)

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

    func dispatchSend(_ message: ClientMessage) async throws {
        if let sendHook = _sendMessageForTesting {
            try await sendHook(message)
            return
        }

        guard let wsClient else { throw WebSocketError.notConnected }

        // Session-scoped messages require a valid activeSessionId.
        // During the reconnect gap (disconnectSession clears it, streamSession
        // re-sets it), messages sent without session scope reach the server but
        // can't be routed — the server silently drops them, no ack arrives,
        // and the user waits for the full ack timeout with no feedback.
        // Fail fast so the error handler can restore the text immediately.
        if activeSessionId == nil, !Self.isSessionLevelCommand(message) {
            logger.error("SEND blocked: activeSessionId is nil for session-scoped \(String(describing: message).prefix(40), privacy: .public)")
            throw WebSocketError.notConnected
        }

        try await wsClient.send(message, sessionId: activeSessionId)
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
    func sendCommandAwaitingResult(
        command: String,
        timeout: Duration = MessageSender.commandRequestTimeoutDefault,
        message: (String) -> ClientMessage
    ) async throws -> JSONValue? {
        if _sendMessageForTesting == nil, wsClient == nil {
            throw WebSocketError.notConnected
        }

        let requestId = UUID().uuidString
        let pending = PendingCommand(command: command, requestId: requestId)
        commands.registerCommand(pending)

        do {
            try await dispatchSend(message(requestId))
        } catch {
            commands.unregisterCommand(requestId: requestId)
            pending.waiter.resolve(.failure(error))
            throw error
        }

        do {
            let response = try await waitForCommandResult(waiter: pending.waiter, command: command, timeout: timeout)
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
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.stop(), sessionId: activeSessionId)
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
