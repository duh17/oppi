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

    // Audio
    let audioPlayer = AudioPlayerService()

    // Runtime pipeline
    let reducer = TimelineReducer()
    let coalescer = DeltaCoalescer()
    let toolMapper = ToolEventMapper()

    // Stream lifecycle
    var activeSessionId: String?

    /// Pending prompt/steer/follow-up acknowledgements keyed by requestId.
    /// Resolved by `turn_ack` stage progress (preferred) and `rpc_result` fallback.
    var pendingTurnSendsByRequestId: [String: PendingTurnSend] = [:]
    var pendingTurnRequestIdByClientTurnId: [String: String] = [:]
    static let sendAckTimeoutDefault: Duration = .seconds(4)
    static let turnSendRetryDelay: Duration = .milliseconds(250)
    static let turnSendMaxAttempts = 2
    static let turnSendRequiredStage: TurnAckStage = .dispatched

    /// Pending generic RPC requests keyed by requestId.
    /// Used for request/response commands like `get_fork_messages`.
    var pendingRPCRequestsByRequestId: [String: PendingRPCRequest] = [:]
    static let rpcRequestTimeoutDefault: Duration = .seconds(8)

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
    /// then updated by `cycle_thinking_level` / `set_thinking_level` RPC responses.
    var thinkingLevel: ThinkingLevel = .medium

    /// Cached slash command metadata for composer autocomplete.
    internal(set) var slashCommands: [SlashCommand] = []

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

    /// Watchdog: if the session reports busy but no stream events arrive for
    /// this duration, trigger a state reconciliation.
    static let silenceTimeout: Duration = .seconds(15)
    static let silenceReconnectTimeout: Duration = .seconds(45)
    /// Tracks the last time a meaningful stream event was routed.
    var lastEventTime: ContinuousClock.Instant?
    /// Watchdog task — monitors for silence during busy sessions.
    var silenceWatchdog: Task<Void, Never>?

    /// Callback for the silence watchdog to trigger a full reconnection.
    /// Set by `ChatSessionManager` when connecting.
    var onSilenceReconnect: (() -> Void)?

    /// Set when server sends a fatal error (e.g. session limit).
    /// ChatSessionManager checks this to suppress auto-reconnect.
    var fatalSetupError = false

    init() {
        // Wire coalescer to reducer (batch) + Live Activity (throttled).
        // Single renderVersion bump per flush, not per event.
        coalescer.onFlush = { [weak self] events in
            guard let self else { return }
            self.reducer.processBatch(events)
            for event in events {
                LiveActivityManager.shared.updateFromEvent(event)
            }
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
        reducer.reset()
        return configure(credentials: server.credentials)
    }

    /// Configure the connection with validated credentials.
    /// Returns `false` if the credentials contain a malformed host.
    @discardableResult
    func configure(credentials: ServerCredentials) -> Bool {
        if let violation = ConnectionSecurityPolicy.evaluate(credentials: credentials) {
            logger.error("Connection policy violation for host=\(credentials.host): \(violation.localizedDescription)")
            return false
        }

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

    // MARK: - Session Streaming

    /// Open a WebSocket stream for one session.
    ///
    /// The caller owns stream consumption and task lifecycle.
    /// On stream termination, `WebSocketClient` disconnects via `onTermination`.
    func streamSession(_ sessionId: String, workspaceId: String) -> AsyncStream<ServerMessage>? {
        guard let wsClient else { return nil }

        // v1 one-stream policy
        disconnectSession()

        activeSessionId = sessionId
        toolMapper.reset()
        thinkingLevel = .medium  // Reset to default; overwritten by session.thinkingLevel on connect
        Task {
            await SentryService.shared.setSessionContext(sessionId: sessionId, workspaceId: workspaceId)
        }
        return wsClient.connect(sessionId: sessionId, workspaceId: workspaceId)
    }

    /// Disconnect from the current session stream.
    func disconnectSession() {
        coalescer.flushNow()
        failPendingSendAcks(error: WebSocketError.notConnected)
        failPendingRPCRequests(error: WebSocketError.notConnected)
        wsClient?.disconnect()
        activeSessionId = nil
        Task {
            await SentryService.shared.setSessionContext(sessionId: nil, workspaceId: nil)
        }
        // Clear stale extension dialog — it's tied to the active session stream
        activeExtensionDialog = nil
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
        stopSilenceWatchdog()
        slashCommandsTask?.cancel()
        slashCommandsTask = nil
        slashCommandsRequestId = nil
        slashCommandsCacheKey = nil
        slashCommands = []
        // Don't end Live Activity on disconnect — it should persist
        // on Lock Screen until the session actually ends.
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
        try await wsClient.send(.stop())
    }

    /// Kill the session process entirely. Requires explicit user action.
    func sendStopSession() async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.stopSession())
    }

    /// Respond to a permission request.
    func respondToPermission(id: String, action: PermissionAction, scope: PermissionScope = .once, expiresInMs: Int? = nil) async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.permissionResponse(id: id, action: action, scope: scope == .once ? nil : scope, expiresInMs: expiresInMs, requestId: nil))
        let outcome: PermissionOutcome = action == .allow ? .allowed : .denied
        if let request = permissionStore.take(id: id) {
            reducer.resolvePermission(id: id, outcome: outcome, tool: request.tool, summary: request.displaySummary)
        }
        PermissionNotificationService.shared.cancelNotification(permissionId: id)
        syncLiveActivityPermissions()
    }

    /// Respond to an extension UI dialog.
    func respondToExtensionUI(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil) async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.extensionUIResponse(id: id, value: value, confirmed: confirmed, cancelled: cancelled))
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
        try await wsClient.send(message)
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
        registerPendingTurnSend(pending)

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
                if attempt < Self.turnSendMaxAttempts, Self.isReconnectableSendError(error) {
                    continue
                }
                pending.waiter.resolve(.failure(error))
                unregisterPendingTurnSend(requestId: requestId, clientTurnId: clientTurnId)
                throw error
            }

            do {
                try await waitForSendAck(waiter: pending.waiter, command: command)

                unregisterPendingTurnSend(requestId: requestId, clientTurnId: clientTurnId)
                return
            } catch {
                lastError = error
                if attempt < Self.turnSendMaxAttempts, Self.isReconnectableSendError(error) {
                    continue
                }
                unregisterPendingTurnSend(requestId: requestId, clientTurnId: clientTurnId)
                throw error
            }
        }

        unregisterPendingTurnSend(requestId: requestId, clientTurnId: clientTurnId)
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

    func sendRPCCommandAwaitingResult(
        command: String,
        timeout: Duration = ServerConnection.rpcRequestTimeoutDefault,
        message: (String) -> ClientMessage
    ) async throws -> JSONValue? {
        if _sendMessageForTesting == nil, wsClient == nil {
            throw WebSocketError.notConnected
        }

        let requestId = UUID().uuidString
        let pending = PendingRPCRequest(command: command, requestId: requestId)
        registerPendingRPCRequest(pending)

        do {
            try await dispatchSend(message(requestId))
        } catch {
            unregisterPendingRPCRequest(requestId: requestId)
            pending.waiter.resolve(.failure(error))
            throw error
        }

        do {
            let response = try await waitForRPCResult(waiter: pending.waiter, command: command, timeout: timeout)
            unregisterPendingRPCRequest(requestId: requestId)
            return response.data
        } catch {
            unregisterPendingRPCRequest(requestId: requestId)
            throw error
        }
    }

    private func waitForRPCResult(
        waiter: RPCResultWaiter,
        command: String,
        timeout: Duration
    ) async throws -> RPCResultPayload {
        try await withThrowingTaskGroup(of: RPCResultPayload.self) { group in
            group.addTask {
                try await waiter.wait()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RPCRequestError.timeout(command: command)
            }

            do {
                guard let result = try await group.next() else {
                    throw RPCRequestError.timeout(command: command)
                }
                group.cancelAll()
                return result
            } catch {
                // Same continuation-drain guard as send acks.
                if let rpcError = error as? RPCRequestError,
                   case .timeout = rpcError {
                    waiter.resolve(.failure(rpcError))
                }
                group.cancelAll()
                throw error
            }
        }
    }

    func getForkMessages() async throws -> [ForkMessage] {
        let data = try await sendRPCCommandAwaitingResult(command: "get_fork_messages") { requestId in
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

    func resolvePendingRPCResult(
        command: String,
        requestId: String,
        success: Bool,
        data: JSONValue?,
        error: String?
    ) -> Bool {
        guard let pending = pendingRPCRequestsByRequestId[requestId], pending.command == command else {
            return false
        }

        if success {
            pending.waiter.resolve(.success(RPCResultPayload(data: data)))
        } else {
            pending.waiter.resolve(.failure(RPCRequestError.rejected(command: command, reason: error)))
        }

        return true
    }

    func resolveTurnAck(
        command: String,
        clientTurnId: String,
        stage: TurnAckStage,
        requestId: String?
    ) -> Bool {
        let lookupRequestId = requestId ?? pendingTurnRequestIdByClientTurnId[clientTurnId]
        guard let lookupRequestId,
              let pending = pendingTurnSendsByRequestId[lookupRequestId],
              pending.command == command,
              pending.clientTurnId == clientTurnId else {
            return false
        }

        pending.latestStage = stage
        pending.notifyStage(stage)

        if stage.rank >= Self.turnSendRequiredStage.rank {
            pending.waiter.resolve(.success(()))
        }

        return true
    }

    func resolveTurnRpcResult(
        command: String,
        requestId: String,
        success: Bool,
        error: String?
    ) -> Bool {
        guard let pending = pendingTurnSendsByRequestId[requestId], pending.command == command else {
            return false
        }

        if success {
            // Backward compatibility for servers that only emit rpc_result.
            if pending.latestStage == nil {
                pending.latestStage = .dispatched
                pending.notifyStage(.dispatched)
                pending.waiter.resolve(.success(()))
            }
        } else {
            pending.waiter.resolve(.failure(SendAckError.rejected(command: command, reason: error)))
        }

        return true
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

