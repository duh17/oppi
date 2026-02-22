import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Connection")

/// Top-level connection coordinator.
///
/// Owns the APIClient and WebSocketClient, manages the event pipeline,
/// and routes server messages to stores and the timeline reducer.
@MainActor @Observable
final class ServerConnection {
    // Public state
    private(set) var credentials: ServerCredentials?

    // Networking
    private(set) var apiClient: APIClient?
    private(set) var wsClient: WebSocketClient?

    /// Derived connection state for UI badges.
    var isConnected: Bool {
        wsClient?.status == .connected
    }

    // Stores
    let sessionStore = SessionStore()
    let permissionStore = PermissionStore()
    let workspaceStore = WorkspaceStore()
    let gitStatusStore = GitStatusStore()

    // Audio
    let audioPlayer = AudioPlayerService()

    // Runtime pipeline
    let reducer = TimelineReducer()
    let coalescer = DeltaCoalescer()
    let toolCallCorrelator = ToolCallCorrelator()

    var toolMapper: ToolCallCorrelator { toolCallCorrelator }

    // Stream lifecycle
    var activeSessionId: String?

    /// Command correlation tracker — owns pending turn sends and command requests.
    let commands = CommandTracker()
    static let sendAckTimeoutDefault: Duration = .seconds(4)
    static let turnSendRetryDelay: Duration = .milliseconds(250)
    static let turnSendMaxAttempts = 2
    static let turnSendRequiredStage: TurnAckStage = .dispatched
    static let commandRequestTimeoutDefault: Duration = .seconds(8)

    /// Test seam: override outbound send path without opening a real WebSocket.
    var _sendMessageForTesting: ((ClientMessage) async throws -> Void)?

    /// Test seam: shorten ack timeout in integration-style tests.
    var _sendAckTimeoutForTesting: Duration?

    /// Test seam: observe refresh breadcrumbs emitted by list refresh paths.
    var _onRefreshBreadcrumbForTesting: ((_ message: String, _ metadata: [String: String], _ level: ClientLogLevel) -> Void)?

    // Extension UI
    var activeExtensionDialog: ExtensionUIRequest?
    var extensionToast: String?

    /// Composer draft text — saved/restored across background cycles.
    var composerDraft: String?

    /// Scroll position shuttle — written by ChatView, read by RestorationState.
    /// `@ObservationIgnored` so scroll tracking doesn't trigger view re-evaluations.
    @ObservationIgnored var scrollAnchorItemId: String?
    @ObservationIgnored var scrollWasNearBottom: Bool = true

    /// Current thinking level — synced from server session state on connect,
    /// then updated by `cycle_thinking_level` / `set_thinking_level` command responses.
    var thinkingLevel: ThinkingLevel = .medium

    /// Cached slash command metadata for composer autocomplete.
    var slashCommands: [SlashCommand] = []

    /// Cached model list — populated eagerly on connect, survives sheet open/close.
    var cachedModels: [ModelInfo] = []
    /// Whether models have been fetched at least once this connection.
    var modelsCacheReady = false
    var slashCommandsCacheKey: String?
    var slashCommandsRequestId: String?
    var slashCommandsTask: Task<Void, Never>?

    /// Timer that auto-dismisses extension dialogs after their timeout expires.
    var extensionTimeoutTask: Task<Void, Never>?

    /// Model prefetch task — eagerly loaded on connect.
    var modelPrefetchTask: Task<Void, Never>?

    /// Silence watchdog — detects zombie WS connections during busy sessions.
    let silenceWatchdog = SilenceWatchdog()

    /// Set when server sends a fatal error (e.g. session limit).
    /// ChatSessionManager checks this to suppress auto-reconnect.
    var fatalSetupError = false

    /// Tracked unsubscribe tasks — keyed by sessionId.
    /// Cancelled before resubscribing the same session to prevent the
    /// fire-and-forget unsubscribe from racing past the new subscribe.
    var pendingUnsubscribeTasks: [String: Task<Void, Never>] = [:]

    init() {
        // Wire coalescer to reducer (batch) + Live Activity (throttled).
        // Single renderVersion bump per flush, not per event.
        coalescer.onFlush = { [weak self] events in
            guard let self else { return }
            self.reducer.processBatch(events)
            if ReleaseFeatures.liveActivitiesEnabled {
                for event in events {
                    LiveActivityManager.shared.updateFromEvent(event)
                }
            }
        }

        // Wire silence watchdog probe to request a state refresh.
        silenceWatchdog.onProbe = { [weak self] in
            try? await self?.requestState()
        }
    }

    /// Fingerprint of the currently connected server (set after configure).
    private(set) var currentServerId: String?

    // MARK: - Setup

    /// Reconfigure to target a different server.
    ///
    /// Tears down any active session stream and WebSocket, then configures
    /// the new server's credentials. Returns `false` on policy/URL failure.
    @discardableResult
    func switchServer(to server: PairedServer) -> Bool {
        guard server.id != currentServerId else { return true } // Already targeting this server
        disconnectSession()
        disconnectStream()
        reducer.reset()
        return configure(credentials: server.credentials)
    }

    /// Configure the connection with validated credentials.
    /// Returns `false` if the credentials contain a malformed host.
    @discardableResult
    func configure(credentials: ServerCredentials) -> Bool {
        guard let baseURL = credentials.baseURL else {
            logger.error("Invalid server credentials: host=\(credentials.host) port=\(credentials.port)")
            return false
        }
        self.credentials = credentials
        self.currentServerId = credentials.normalizedServerFingerprint
        self.apiClient = APIClient(baseURL: baseURL, token: credentials.token)
        self.wsClient = WebSocketClient(credentials: credentials)
        return true
    }

    // MARK: - Stream Lifecycle

    /// Background task consuming the multiplexed `/stream` WebSocket.
    internal var streamConsumptionTask: Task<Void, Never>?

    /// Per-session continuations for routing multiplexed messages.
    internal var sessionContinuations: [String: AsyncStream<ServerMessage>.Continuation] = [:]

    /// Connect the persistent `/stream` WebSocket.
    ///
    /// Opens the WS and starts a consumption task that routes messages
    /// to per-session streams. Safe to call multiple times (idempotent
    /// if already connected). If the previous consumption task finished
    /// (e.g., WS gave up after max reconnect attempts), a new one is created.
    func connectStream() {
        guard let wsClient else { return }

        // If consumption task is still running, nothing to do
        if let task = streamConsumptionTask, !task.isCancelled {
            // Check if the WS is in a terminal state (disconnected after max retries)
            if wsClient.status != .disconnected {
                return
            }
            // WS is dead but task is waiting on a finished stream — clean up
            task.cancel()
            streamConsumptionTask = nil
        }

        let stream = wsClient.connect()

        streamConsumptionTask = Task { [weak self] in
            for await streamMessage in stream {
                guard let self, !Task.isCancelled else { break }
                self.routeStreamMessage(streamMessage)
            }
            // Stream ended (WS disconnected or max reconnect attempts).
            // Nil out so future connectStream() calls can restart.
            await MainActor.run { [weak self] in
                self?.streamConsumptionTask = nil
            }
        }
    }

    /// Disconnect the persistent `/stream` WebSocket.
    func disconnectStream() {
        streamConsumptionTask?.cancel()
        streamConsumptionTask = nil
        for (_, cont) in sessionContinuations {
            cont.finish()
        }
        sessionContinuations.removeAll()
        for (_, task) in pendingUnsubscribeTasks {
            task.cancel()
        }
        pendingUnsubscribeTasks.removeAll()
        wsClient?.disconnect()
    }

    /// Route a message from the multiplexed stream to the appropriate session.
    func routeStreamMessage(_ streamMessage: StreamMessage) {
        let sessionId = streamMessage.sessionId
        let message = streamMessage.message

        // Handle stream-level events (no sessionId)
        if case .streamConnected = message {
            handleStreamReconnected()
            return
        }

        // Resolve pending subscribe/unsubscribe waiters directly from stream
        // routing, BEFORE yielding to the per-session stream. This prevents a
        // deadlock where streamSession() awaits a subscribe command_result
        // that only gets consumed after the per-session stream loop starts —
        // which can't start until streamSession() returns.
        resolveSubscribeWaiters(message)

        // Route to per-session continuation if active
        if let sessionId, let cont = sessionContinuations[sessionId] {
            cont.yield(message)
        }

        // Also route notification-level events to the active session handler
        // (permissions from other sessions still need processing)
        if let sessionId, sessionId != activeSessionId {
            handleCrossSessionMessage(message, sessionId: sessionId)
        }
    }

    /// Eagerly resolve subscribe/unsubscribe command results from stream routing.
    ///
    /// Only these two commands need eager resolution — they're sent in
    /// `streamSession()` before the per-session stream consumer starts.
    /// Other commands (set_model, get_fork_messages, etc.) are sent while
    /// the consumer is running and resolve normally through `handleCommandResult`.
    private func resolveSubscribeWaiters(_ message: ServerMessage) {
        guard case .commandResult(let command, let requestId, let success, let data, let error) = message,
              let requestId,
              command == "subscribe" || command == "unsubscribe" else {
            return
        }
        _ = commands.resolveCommandResult(
            command: command, requestId: requestId,
            success: success, data: data, error: error
        )
    }

    /// Handle `/stream` (re)connection — re-subscribe all tracked sessions.
    ///
    /// Retries the active session subscribe with backoff. If all retries
    /// fail, surfaces a system event so the user can tap to reconnect.
    /// Notification-level sessions are best-effort (single attempt).
    private func handleStreamReconnected() {
        guard wsClient != nil else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resubscribeTrackedSessions()
        }
    }

    private static let resubscribeMaxAttempts = 3
    private static let resubscribeBaseDelay: Duration = .milliseconds(500)

    private func resubscribeTrackedSessions() async {
        guard wsClient != nil else { return }

        // Re-subscribe active session at full level (most important)
        if let activeSessionId {
            let ok = await resubscribeWithRetry(
                sessionId: activeSessionId,
                level: .full,
                maxAttempts: Self.resubscribeMaxAttempts
            )
            if !ok {
                logger.error("Resubscription failed for active session \(activeSessionId, privacy: .public)")
                ClientLog.error(
                    "WebSocket",
                    "Resubscription failed for active session",
                    metadata: ["sessionId": activeSessionId]
                )
                reducer.appendSystemEvent("Connection recovered but session sync failed")
            }
        }

        // Re-subscribe notification-level sessions (best-effort, single attempt)
        for (sessionId, _) in sessionContinuations where sessionId != activeSessionId {
            _ = await resubscribeWithRetry(
                sessionId: sessionId,
                level: .notifications,
                maxAttempts: 1
            )
        }
    }

    /// Send a subscribe command with retry.
    ///
    /// Returns `true` if the send succeeded on any attempt.
    /// Only retries the WebSocket *send* — server-side subscribe failures
    /// (session not found, etc.) come back as `command_result` errors and are
    /// handled by the existing message routing.
    private func resubscribeWithRetry(
        sessionId: String,
        level: StreamSubscriptionLevel,
        maxAttempts: Int
    ) async -> Bool {
        for attempt in 1...maxAttempts {
            guard let wsClient else { return false }
            do {
                try await wsClient.send(.subscribe(
                    sessionId: sessionId,
                    level: level,
                    requestId: UUID().uuidString
                ))
                return true
            } catch {
                let delayMs = Int(500 * attempt)
                logger.warning(
                    "Resubscribe attempt \(attempt)/\(maxAttempts) failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
            }
        }
        return false
    }

    /// Handle notification-level events from non-active sessions
    /// (e.g., permissions from other sessions on this server).
    private func handleCrossSessionMessage(_ message: ServerMessage, sessionId: String) {
        switch message {
        case .permissionRequest(let perm):
            permissionStore.add(perm)
            if ReleaseFeatures.pushNotificationsEnabled {
                PermissionNotificationService.shared.notifyIfNeeded(
                    perm,
                    activeSessionId: sessionStore.activeSessionId
                )
            }
            syncLiveActivityPermissions()

        case .permissionExpired(let id, _):
            if let request = permissionStore.take(id: id) {
                // Don't add to reducer timeline (not the active session)
                _ = request
            }
            if ReleaseFeatures.pushNotificationsEnabled {
                PermissionNotificationService.shared.cancelNotification(permissionId: id)
            }
            syncLiveActivityPermissions()

        case .permissionCancelled(let id):
            permissionStore.remove(id: id)
            if ReleaseFeatures.pushNotificationsEnabled {
                PermissionNotificationService.shared.cancelNotification(permissionId: id)
            }
            syncLiveActivityPermissions()

        case .state(let session):
            sessionStore.upsert(session)

        case .sessionEnded(let reason):
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                current.status = .stopped
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            _ = reason

        default:
            break
        }
    }

    // MARK: - Session Streaming

    /// Subscribe to a session at full streaming level.
    ///
    /// Returns an `AsyncStream<ServerMessage>` that yields events for this session.
    /// The `/stream` WebSocket is opened if not already connected.
    /// The caller owns stream consumption and task lifecycle.
    ///
    /// Awaits the subscribe `command_result` before returning so that
    /// subsequent commands (prompt, stop, etc.) never race ahead of the
    /// subscription on the server side.
    func streamSession(_ sessionId: String, workspaceId: String) async -> AsyncStream<ServerMessage>? {
        guard let wsClient else { return nil }

        // Unsubscribe previous full session (if any)
        if let previousSessionId = activeSessionId, previousSessionId != sessionId {
            unsubscribeSession(previousSessionId)
        }

        // Cancel any pending unsubscribe for THIS session to prevent a
        // fire-and-forget unsubscribe (from disconnectSession) from racing
        // past the subscribe we're about to send.
        if let pendingUnsub = pendingUnsubscribeTasks.removeValue(forKey: sessionId) {
            pendingUnsub.cancel()
        }

        activeSessionId = sessionId
        toolCallCorrelator.reset()
        thinkingLevel = .medium  // Reset to default; overwritten by session.thinkingLevel on connect
        Task {
            await SentryService.shared.setSessionContext(sessionId: sessionId, workspaceId: workspaceId)
        }

        // Ensure /stream is connected
        connectStream()

        // Create per-session stream
        let perSessionStream = AsyncStream<ServerMessage> { continuation in
            self.sessionContinuations[sessionId] = continuation

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.sessionContinuations.removeValue(forKey: sessionId)
                }
            }
        }

        // Subscribe at full level — await server confirmation before returning
        // so commands sent after this call don't race the subscription.
        do {
            _ = try await sendCommandAwaitingResult(
                command: "subscribe",
                timeout: .seconds(10)
            ) { requestId in
                .subscribe(sessionId: sessionId, level: .full, requestId: requestId)
            }
        } catch {
            logger.error("Subscribe failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        return perSessionStream
    }

    /// Unsubscribe from a specific session.
    ///
    /// The send is tracked so `streamSession()` can cancel it before
    /// resubscribing the same session — preventing the fire-and-forget
    /// unsubscribe from arriving after a newer subscribe.
    private func unsubscribeSession(_ sessionId: String) {
        sessionContinuations[sessionId]?.finish()
        sessionContinuations.removeValue(forKey: sessionId)

        pendingUnsubscribeTasks[sessionId]?.cancel()
        pendingUnsubscribeTasks[sessionId] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            try? await self?.wsClient?.send(.unsubscribe(
                sessionId: sessionId,
                requestId: UUID().uuidString
            ))
            self?.pendingUnsubscribeTasks.removeValue(forKey: sessionId)
        }
    }

    /// Disconnect from the current session stream.
    func disconnectSession() {
        coalescer.flushNow()
        commands.failAllTurnSends(error: WebSocketError.notConnected)
        commands.failAllCommands(error: WebSocketError.notConnected)

        if let activeSessionId {
            unsubscribeSession(activeSessionId)
        }

        activeSessionId = nil
        Task {
            await SentryService.shared.setSessionContext(sessionId: nil, workspaceId: nil)
        }
        // Clear stale extension dialog — it's tied to the active session stream
        activeExtensionDialog = nil
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
        silenceWatchdog.stop()
        slashCommandsTask?.cancel()
        slashCommandsTask = nil
        slashCommandsRequestId = nil
        slashCommandsCacheKey = nil
        slashCommands = []
        // Don't end Live Activity on disconnect — it should persist
        // on Lock Screen until the session actually ends.
        // Don't disconnect /stream WS — it stays open for other subscriptions.
    }

    /// Flush pending deltas on background transition.
    /// Does NOT disconnect — the OS will suspend the stream, and
    /// `reconnectIfNeeded` handles recovery on foreground.
    func flushAndSuspend() {
        coalescer.flushNow()
    }

    // MARK: - Actions

    /// Send a prompt to the connected session and await server acceptance.
    ///
    /// Uses request/response correlation (`requestId`) plus `clientTurnId`
    /// idempotency so reconnect retries do not duplicate work.
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

    /// Send a steering message to a busy session and await acceptance.
    func sendSteer(
        _ text: String,
        images: [ImageAttachment]? = nil,
        onAckStage: ((TurnAckStage) -> Void)? = nil
    ) async throws {
        let requestId = UUID().uuidString
        let clientTurnId = UUID().uuidString
        try await sendTurnWithAck(
            requestId: requestId,
            clientTurnId: clientTurnId,
            command: "steer",
            onAckStage: onAckStage
        ) {
            .steer(message: text, images: images, requestId: requestId, clientTurnId: clientTurnId)
        }
    }

    /// Queue a follow-up message and await acceptance.
    func sendFollowUp(
        _ text: String,
        images: [ImageAttachment]? = nil,
        onAckStage: ((TurnAckStage) -> Void)? = nil
    ) async throws {
        let requestId = UUID().uuidString
        let clientTurnId = UUID().uuidString
        try await sendTurnWithAck(
            requestId: requestId,
            clientTurnId: clientTurnId,
            command: "follow_up",
            onAckStage: onAckStage
        ) {
            .followUp(message: text, images: images, requestId: requestId, clientTurnId: clientTurnId)
        }
    }

    /// Abort the current turn. The session stays alive for the next prompt.
    func sendStop() async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.stop(), sessionId: activeSessionId)
    }

    /// Kill the session process entirely. Requires explicit user action.
    func sendStopSession() async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.stopSession(), sessionId: activeSessionId)
    }

    /// Respond to a permission request.
    func respondToPermission(id: String, action: PermissionAction, scope: PermissionScope = .once, expiresInMs: Int? = nil) async throws {
        let tool = permissionStore.pending.first(where: { $0.id == id })?.tool ?? ""
        let normalizedChoice = PermissionApprovalPolicy.normalizedChoice(
            tool: tool,
            choice: PermissionResponseChoice(action: action, scope: scope, expiresInMs: expiresInMs)
        )

        // permission_response is a stream-level command — no sessionId envelope needed
        try await dispatchSend(
            .permissionResponse(
                id: id,
                action: normalizedChoice.action,
                scope: normalizedChoice.scope == .once ? nil : normalizedChoice.scope,
                expiresInMs: normalizedChoice.expiresInMs,
                requestId: nil
            )
        )

        let outcome: PermissionOutcome = normalizedChoice.action == .allow ? .allowed : .denied
        if let request = permissionStore.take(id: id) {
            // Only inject the resolved marker into the timeline if this permission
            // belongs to the currently active session. Otherwise we'd pollute the
            // wrong session's timeline (cross-session permission approval).
            if request.sessionId == activeSessionId {
                reducer.resolvePermission(id: id, outcome: outcome, tool: request.tool, summary: request.displaySummary)
            }
        }
        if ReleaseFeatures.pushNotificationsEnabled {
            PermissionNotificationService.shared.cancelNotification(permissionId: id)
        }
        syncLiveActivityPermissions()
    }

    /// Respond to an extension UI dialog.
    func respondToExtensionUI(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil) async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.extensionUIResponse(id: id, value: value, confirmed: confirmed, cancelled: cancelled), sessionId: activeSessionId)
        activeExtensionDialog = nil
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
    }

    /// Request current state from server.
    func requestState() async throws {
        try await send(.getState())
    }

    /// Send any client message.
    func send(_ message: ClientMessage) async throws {
        try await dispatchSend(message)
    }

    /// Test seam: set active stream session without opening a real socket.
    func _setActiveSessionIdForTesting(_ sessionId: String?) {
        activeSessionId = sessionId
    }

    private func dispatchSend(_ message: ClientMessage) async throws {
        if let sendHook = _sendMessageForTesting {
            try await sendHook(message)
            return
        }

        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(message, sessionId: activeSessionId)
    }

    private func sendTurnWithAck(
        requestId: String,
        clientTurnId: String,
        command: String,
        onAckStage: ((TurnAckStage) -> Void)? = nil,
        message: () -> ClientMessage
    ) async throws {
        if _sendMessageForTesting == nil, wsClient == nil {
            throw WebSocketError.notConnected
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

    func sendCommandAwaitingResult(
        command: String,
        timeout: Duration = ServerConnection.commandRequestTimeoutDefault,
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
                // Same continuation-drain guard as send acks.
                if let cmdError = error as? CommandRequestError,
                   case .timeout = cmdError {
                    waiter.resolve(.failure(cmdError))
                }
                group.cancelAll()
                throw error
            }
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



    // ── Model ──

    // Model, thinking, slash commands, session commands, fork, and bash
    // operations are in ServerConnection+ModelCommands.swift and
    // ServerConnection+Fork.swift extensions.

    // MARK: - Reconnect State (used by ServerConnection+Refresh)

    /// Reentrancy guard — prevents concurrent `reconnectIfNeeded` calls.
    var foregroundRecoveryInFlight = false

    /// Skip expensive list refreshes when data was synced very recently.
    static let listRefreshMinimumInterval: TimeInterval = 120

    /// Shared in-flight tasks to coalesce overlapping refresh requests.
    var sessionListRefreshTask: Task<Void, Never>?
    var workspaceCatalogRefreshTask: Task<Void, Never>?
}
