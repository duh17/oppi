import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.PiRemote", category: "Connection")

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
    private let coalescer = DeltaCoalescer()
    private let toolMapper = ToolEventMapper()

    // Stream lifecycle
    private var activeSessionId: String?

    /// Pending prompt/steer/follow-up acknowledgements keyed by requestId.
    /// Resolved by `turn_ack` stage progress (preferred) and `rpc_result` fallback.
    private var pendingTurnSendsByRequestId: [String: PendingTurnSend] = [:]
    private var pendingTurnRequestIdByClientTurnId: [String: String] = [:]
    private static let sendAckTimeoutDefault: Duration = .seconds(4)
    private static let turnSendRetryDelay: Duration = .milliseconds(250)
    private static let turnSendMaxAttempts = 2
    private static let turnSendRequiredStage: TurnAckStage = .dispatched

    /// Pending generic RPC requests keyed by requestId.
    /// Used for request/response commands like `get_fork_messages`.
    private var pendingRPCRequestsByRequestId: [String: PendingRPCRequest] = [:]
    private static let rpcRequestTimeoutDefault: Duration = .seconds(8)

    /// Test seam: override outbound send path without opening a real WebSocket.
    var _sendMessageForTesting: ((ClientMessage) async throws -> Void)?

    /// Test seam: shorten ack timeout in integration-style tests.
    var _sendAckTimeoutForTesting: Duration?

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
    private(set) var slashCommands: [SlashCommand] = []
    private var slashCommandsCacheKey: String?
    private var slashCommandsRequestId: String?
    private var slashCommandsTask: Task<Void, Never>?

    /// Timer that auto-dismisses extension dialogs after their timeout expires.
    private var extensionTimeoutTask: Task<Void, Never>?

    /// Watchdog: if the session reports busy but no stream events arrive for
    /// this duration, trigger a state reconciliation.
    private static let silenceTimeout: Duration = .seconds(15)
    /// Tracks the last time a meaningful stream event was routed.
    private var lastEventTime: ContinuousClock.Instant?
    /// Watchdog task — monitors for silence during busy sessions.
    private var silenceWatchdog: Task<Void, Never>?

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

    // MARK: - Setup

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

    private func sendRPCCommandAwaitingResult(
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

    private func getForkMessages() async throws -> [ForkMessage] {
        let data = try await sendRPCCommandAwaitingResult(command: "get_fork_messages") { requestId in
            .getForkMessages(requestId: requestId)
        }

        guard let values = data?.objectValue?["messages"]?.arrayValue else {
            return []
        }

        return values.compactMap { value in
            guard let object = value.objectValue,
                  let entryId = object["entryId"]?.stringValue,
                  !entryId.isEmpty else {
                return nil
            }

            return ForkMessage(
                entryId: entryId,
                text: object["text"]?.stringValue ?? ""
            )
        }
    }

    private func resolvePendingRPCResult(
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

    private func resolveTurnAck(
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

    private func resolveTurnRpcResult(
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

    func setModel(provider: String, modelId: String) async throws {
        try await send(.setModel(provider: provider, modelId: modelId))
    }

    func cycleModel() async throws {
        try await send(.cycleModel())
    }

    // ── Thinking ──

    func setThinkingLevel(_ level: ThinkingLevel) async throws {
        try await send(.setThinkingLevel(level: level))
    }

    func cycleThinkingLevel() async throws {
        try await send(.cycleThinkingLevel())
    }

    /// Sync thinking level from a session state update (connected/state messages).
    private func syncThinkingLevel(from session: Session) {
        guard let levelStr = session.thinkingLevel,
              let level = ThinkingLevel(rawValue: levelStr),
              thinkingLevel != level else { return }
        thinkingLevel = level
    }

    private func slashCommandCacheKey(for session: Session) -> String {
        "\(session.id)|\(session.workspaceId ?? "")"
    }

    private func scheduleSlashCommandsRefresh(for session: Session, force: Bool) {
        slashCommandsTask?.cancel()
        slashCommandsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSlashCommands(for: session, force: force)
        }
    }

    private func refreshSlashCommands(for session: Session, force: Bool) async {
        let cacheKey = slashCommandCacheKey(for: session)
        if !force,
           slashCommandsCacheKey == cacheKey,
           !slashCommands.isEmpty {
            return
        }

        let requestId = UUID().uuidString
        slashCommandsRequestId = requestId

        do {
            try await send(.getCommands(requestId: requestId))
        } catch {
            slashCommandsRequestId = nil
        }
    }

    private func handleSlashCommandsResult(
        requestId: String?,
        success: Bool,
        data: JSONValue?,
        error: String?,
        sessionId: String
    ) {
        if let expectedRequestId = slashCommandsRequestId,
           let requestId,
           requestId != expectedRequestId {
            return
        }

        defer { slashCommandsRequestId = nil }

        guard success else {
            return
        }

        slashCommands = Self.parseSlashCommands(from: data)

        if let session = sessionStore.sessions.first(where: { $0.id == sessionId }) {
            slashCommandsCacheKey = slashCommandCacheKey(for: session)
        } else {
            slashCommandsCacheKey = nil
        }
    }

    private static func parseSlashCommands(from data: JSONValue?) -> [SlashCommand] {
        guard let commandValues = data?.objectValue?["commands"]?.arrayValue else {
            return []
        }

        var deduped: [String: SlashCommand] = [:]
        for value in commandValues {
            guard let command = SlashCommand(value) else { continue }
            let key = command.name.lowercased()
            if deduped[key] == nil {
                deduped[key] = command
            }
        }

        return deduped.values.sorted { lhs, rhs in
            let lhsName = lhs.name.lowercased()
            let rhsName = rhs.name.lowercased()
            if lhsName == rhsName {
                return lhs.source.sortRank < rhs.source.sortRank
            }
            return lhsName < rhsName
        }
    }

    // ── Session ──

    func newSession() async throws {
        try await send(.newSession())
    }

    func setSessionName(_ name: String) async throws {
        try await send(.setSessionName(name: name))
    }

    func compact(instructions: String? = nil) async throws {
        try await send(.compact(customInstructions: instructions))
    }

    /// Fork from a canonical session entry ID (mirrors pi CLI behavior).
    ///
    /// Flow:
    /// 1. `get_fork_messages` to resolve valid fork entry IDs
    /// 2. Verify requested entry is in that server-authored list
    /// 3. `fork(entryId)` with correlated requestId
    func forkFromTimelineEntry(_ entryId: String) async throws {
        guard UUID(uuidString: entryId) == nil else {
            throw ForkRequestError.turnInProgress
        }

        let forkMessages = try await getForkMessages()
        guard !forkMessages.isEmpty else {
            throw ForkRequestError.noForkableMessages
        }

        guard forkMessages.contains(where: { $0.entryId == entryId }) else {
            throw ForkRequestError.entryNotForkable
        }

        _ = try await sendRPCCommandAwaitingResult(command: "fork") { requestId in
            .fork(entryId: entryId, requestId: requestId)
        }
    }

    // ── Bash ──

    func runBash(_ command: String) async throws {
        try await send(.bash(command: command))
    }

    // MARK: - Reconnect (foreground)

    /// Reentrancy guard — prevents concurrent `reconnectIfNeeded` calls
    /// from rapid background→foreground cycling.
    private(set) var foregroundRecoveryInFlight = false

    /// Called when app returns to foreground.
    ///
    /// Refreshes session list, workspaces, and session metadata.
    /// Does NOT touch the timeline — `ChatSessionManager` owns trace loading,
    /// catch-up, and reconnect. Mixing both paths causes double-load races
    /// and visual flashes.
    func reconnectIfNeeded() async {
        guard let apiClient else { return }
        guard !foregroundRecoveryInFlight else { return }
        foregroundRecoveryInFlight = true
        defer { foregroundRecoveryInFlight = false }

        // 1. Refresh session list (always, even without active session)
        if sessionStore.sessions.isEmpty,
           let cached = await TimelineCache.shared.loadSessionList() {
            sessionStore.applyServerSnapshot(cached)
        }

        sessionStore.markSyncStarted()
        do {
            let sessions = try await apiClient.listSessions()
            sessionStore.applyServerSnapshot(sessions)
            sessionStore.markSyncSucceeded()
            Task.detached { await TimelineCache.shared.saveSessionList(sessions) }
        } catch {
            sessionStore.markSyncFailed()
            logger.error("Failed to refresh sessions: \(error)")
        }

        // 2. Refresh workspaces + skills (cache-backed)
        await workspaceStore.load(api: apiClient)

        // 3. Sweep expired permissions (safety net for missed WS messages)
        let expiredRequests = permissionStore.sweepExpired()
        for request in expiredRequests {
            reducer.resolvePermission(
                id: request.id, outcome: .expired,
                tool: request.tool, summary: request.displaySummary
            )
            PermissionNotificationService.shared.cancelNotification(permissionId: request.id)
        }

        // 4. Refresh active session metadata (not timeline — ChatSessionManager owns that)
        guard let sessionId = activeSessionId else { return }
        guard let workspaceId = sessionStore.sessions.first(where: { $0.id == sessionId })?.workspaceId,
              !workspaceId.isEmpty else {
            logger.error("Missing workspaceId for active session \(sessionId)")
            return
        }

        let streamAttached = wsClient?.connectedSessionId == sessionId
        let streamAlive: Bool
        if streamAttached {
            switch wsClient?.status {
            case .connected, .connecting, .reconnecting:
                streamAlive = true
            default:
                streamAlive = false
            }
        } else {
            streamAlive = false
        }

        if !streamAlive {
            // Clear stale extension dialog — server will re-send if still pending.
            // Timeline recovery is handled by ChatSessionManager auto-reconnect.
            activeExtensionDialog = nil
            extensionTimeoutTask?.cancel()
            extensionTimeoutTask = nil

            do {
                let (session, _) = try await apiClient.getSession(workspaceId: workspaceId, id: sessionId)
                sessionStore.upsert(session)
            } catch {
                logger.error("Failed to refresh session \(sessionId): \(error)")
            }
        } else {
            // Stream alive — refresh session metadata
            do {
                let (session, _) = try await apiClient.getSession(workspaceId: workspaceId, id: sessionId)
                sessionStore.upsert(session)
            } catch {
                logger.error("Failed to refresh session metadata: \(error)")
            }
        }

        // 5. Ask server for freshest state once the active stream is connected.
        if streamAttached, wsClient?.status == .connected {
            try? await requestState()
        }
    }

    // MARK: - Message Router

    /// Route a ServerMessage to the appropriate store or pipeline.
    /// Ignores messages for non-active sessions (stale stream race).
    func handleServerMessage(_ message: ServerMessage, sessionId: String) {
        guard sessionId == activeSessionId else {
            return
        }

        if handleStopLifecycleMessage(message, sessionId: sessionId) {
            return
        }

        switch message {
        // Direct state updates (not timeline events)
        case .connected(let session):
            handleConnected(session)

        case .state(let session):
            handleState(session)

        case .extensionUIRequest(let request):
            extensionTimeoutTask?.cancel()
            activeExtensionDialog = request
            scheduleExtensionTimeout(request)

        case .extensionUINotification(_, let message, _, _, _):
            extensionToast = message

        case .turnAck(let command, let clientTurnId, let stage, let requestId, _):
            _ = resolveTurnAck(command: command, clientTurnId: clientTurnId, stage: stage, requestId: requestId)

        case .unknown, .stopRequested, .stopConfirmed, .stopFailed:
            break  // Already logged in WebSocketClient / handled earlier

        // Permission events → store + overlay (NOT inline timeline)
        case .permissionRequest(let perm):
            permissionStore.add(perm)
            // Feed coalescer for Live Activity badge count, but NOT the reducer timeline.
            coalescer.receive(.permissionRequest(perm))
            PermissionNotificationService.shared.notifyIfBackgrounded(perm)

        case .permissionExpired(let id, _):
            if let request = permissionStore.take(id: id) {
                reducer.resolvePermission(
                    id: id, outcome: .expired,
                    tool: request.tool, summary: request.displaySummary
                )
            }
            coalescer.receive(.permissionExpired(id: id))
            PermissionNotificationService.shared.cancelNotification(permissionId: id)

        case .permissionCancelled(let id):
            if let request = permissionStore.take(id: id) {
                reducer.resolvePermission(
                    id: id, outcome: .cancelled,
                    tool: request.tool, summary: request.displaySummary
                )
            }
            PermissionNotificationService.shared.cancelNotification(permissionId: id)

        // Agent events → pipeline
        case .agentStart:
            coalescer.receive(.agentStart(sessionId: sessionId))
            startSilenceWatchdog()

        case .agentEnd:
            coalescer.receive(.agentEnd(sessionId: sessionId))
            stopSilenceWatchdog()

        case .messageEnd(let role, let content):
            if role == "assistant" {
                coalescer.receive(.messageEnd(sessionId: sessionId, content: content))
            }

        case .textDelta(let delta):
            lastEventTime = .now
            coalescer.receive(.textDelta(sessionId: sessionId, delta: delta))

        case .thinkingDelta(let delta):
            lastEventTime = .now
            coalescer.receive(.thinkingDelta(sessionId: sessionId, delta: delta))

        case .toolStart(let tool, let args, let toolCallId):
            lastEventTime = .now
            coalescer.receive(toolMapper.start(sessionId: sessionId, tool: tool, args: args, toolCallId: toolCallId))

        case .toolOutput(let output, let isError, let toolCallId):
            lastEventTime = .now
            coalescer.receive(toolMapper.output(sessionId: sessionId, output: output, isError: isError, toolCallId: toolCallId))

        case .toolEnd(_, let toolCallId):
            lastEventTime = .now
            coalescer.receive(toolMapper.end(sessionId: sessionId, toolCallId: toolCallId))

        case .sessionEnded(let reason):
            stopSilenceWatchdog()
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                current.status = .stopped
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            coalescer.receive(.sessionEnded(sessionId: sessionId, reason: reason))

        case .error(let msg, _, let fatal):
            coalescer.receive(.error(sessionId: sessionId, message: msg))
            // Fatal setup errors (e.g. session limit reached) — stop auto-reconnect.
            // The server closed the WS after this; retrying would just loop.
            fatalSetupError = fatalSetupError || fatal

        // Compaction events → pipeline
        case .compactionStart(let reason):
            coalescer.receive(.compactionStart(sessionId: sessionId, reason: reason))

        case .compactionEnd(let aborted, let willRetry, let summary, let tokensBefore):
            coalescer.receive(
                .compactionEnd(
                    sessionId: sessionId,
                    aborted: aborted,
                    willRetry: willRetry,
                    summary: summary,
                    tokensBefore: tokensBefore
                )
            )

        // Retry events → pipeline
        case .retryStart(let attempt, let maxAttempts, let delayMs, let errorMessage):
            coalescer.receive(.retryStart(sessionId: sessionId, attempt: attempt, maxAttempts: maxAttempts, delayMs: delayMs, errorMessage: errorMessage))

        case .retryEnd(let success, let attempt, let finalError):
            coalescer.receive(.retryEnd(sessionId: sessionId, success: success, attempt: attempt, finalError: finalError))

        // RPC results → pipeline (for model changes, stats, etc.)
        case .rpcResult(let command, let requestId, let success, let data, let error):
            handleRPCResult(
                command: command,
                requestId: requestId,
                success: success,
                data: data,
                error: error,
                sessionId: sessionId
            )
        }
    }
    private func handleConnected(_ session: Session) {
        sessionStore.upsert(session)
        syncThinkingLevel(from: session)
        scheduleSlashCommandsRefresh(for: session, force: true)
    }
    private func handleState(_ session: Session) {
        let previousWorkspaceId = sessionStore.sessions.first(where: { $0.id == session.id })?.workspaceId
        sessionStore.upsert(session)
        syncThinkingLevel(from: session)
        if previousWorkspaceId != session.workspaceId {
            scheduleSlashCommandsRefresh(for: session, force: true)
        }
    }
    private func handleStopLifecycleMessage(_ message: ServerMessage, sessionId: String) -> Bool {
        switch message {
        case .stopRequested(_, let reason):
            updateStopStatus(sessionId, status: .stopping)
            reducer.appendSystemEvent(reason ?? "Stopping…")
            return true
        case .stopConfirmed(_, let reason):
            updateStopStatus(sessionId, status: .ready, onlyFrom: .stopping)
            reducer.appendSystemEvent(reason ?? "Stop confirmed")
            return true
        case .stopFailed(_, let reason):
            updateStopStatus(sessionId, status: .busy, onlyFrom: .stopping)
            reducer.process(.error(sessionId: sessionId, message: "Stop failed: \(reason)"))
            return true
        default:
            return false
        }
    }

    private func updateStopStatus(
        _ sessionId: String,
        status: SessionStatus,
        onlyFrom: SessionStatus? = nil
    ) {
        guard var current = sessionStore.sessions.first(where: { $0.id == sessionId }) else { return }
        if let onlyFrom, current.status != onlyFrom { return }
        current.status = status
        current.lastActivity = Date()
        sessionStore.upsert(current)
    }

    private func handleRPCResult(
        command: String,
        requestId: String?,
        success: Bool,
        data: JSONValue?,
        error: String?,
        sessionId: String
    ) {
        // Resolve prompt/steer/follow-up acceptance acks first.
        // These are local send-path control messages, not timeline events.
        if let requestId,
           command == "prompt" || command == "steer" || command == "follow_up",
           resolveTurnRpcResult(command: command, requestId: requestId, success: success, error: error) {
            return
        }

        if command == "get_commands" {
            handleSlashCommandsResult(
                requestId: requestId,
                success: success,
                data: data,
                error: error,
                sessionId: sessionId
            )
            return
        }

        if let requestId,
           resolvePendingRPCResult(
            command: command,
            requestId: requestId,
            success: success,
            data: data,
            error: error
           ) {
            return
        }

        syncThinkingLevelFromRPC(command: command, success: success, data: data)

        coalescer.receive(
            .rpcResult(
                sessionId: sessionId,
                command: command,
                requestId: requestId,
                success: success,
                data: data,
                error: error
            )
        )
    }

    private func syncThinkingLevelFromRPC(command: String, success: Bool, data: JSONValue?) {
        guard success, command == "cycle_thinking_level" || command == "set_thinking_level" else {
            return
        }

        if let levelStr = data?.objectValue?["level"]?.stringValue,
           let level = ThinkingLevel(rawValue: levelStr) {
            thinkingLevel = level
        } else if command == "cycle_thinking_level" {
            // Server didn't return data — cycle locally
            thinkingLevel = thinkingLevel.next
        }
    }

    // MARK: - Silence Watchdog

    /// Start monitoring for silence during an active agent turn.
    ///
    /// Two tiers:
    /// 1. After `silenceTimeout` (15s): send `requestState()` as a probe.
    /// 2. After `silenceReconnectTimeout` (45s): the WS receive path is likely
    ///    zombie (TCP alive but no frames delivered). Force a full reconnect
    ///    via `sessionManager.reconnect()` to recover.
    private static let silenceReconnectTimeout: Duration = .seconds(45)

    /// Callback for the silence watchdog to trigger a full reconnection.
    /// Set by `ChatSessionManager` when connecting.
    var onSilenceReconnect: (() -> Void)?

    private func startSilenceWatchdog() {
        lastEventTime = .now
        silenceWatchdog?.cancel()
        silenceWatchdog = Task { @MainActor [weak self] in
            var probed = false
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.silenceTimeout)
                guard !Task.isCancelled, let self else { return }
                guard let lastEvent = self.lastEventTime else { break }

                let elapsed = ContinuousClock.now - lastEvent
                if elapsed >= Self.silenceReconnectTimeout {
                    // Tier 2: WS is zombie — force full reconnect
                    logger.error("Silence watchdog: no events for \(elapsed) — forcing WS reconnect")
                    self.onSilenceReconnect?()
                    break
                } else if elapsed >= Self.silenceTimeout && !probed {
                    // Tier 1: probe — maybe the agent is just thinking
                    try? await self.requestState()
                    probed = true
                }
            }
        }
    }

    /// Stop the silence watchdog (agent turn ended normally).
    private func stopSilenceWatchdog() {
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        lastEventTime = nil
    }

    // MARK: - Extension Timeout

    /// Auto-dismiss extension dialog after its timeout expires.
    /// The server has already given up waiting — we just clean up the UI.
    private func scheduleExtensionTimeout(_ request: ExtensionUIRequest) {
        guard let timeout = request.timeout, timeout > 0 else { return }
        extensionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            guard let self, self.activeExtensionDialog?.id == request.id else { return }
            self.activeExtensionDialog = nil
            self.extensionToast = "Extension request timed out"
        }
    }
}

private extension ServerConnection {
    func registerPendingTurnSend(_ pending: PendingTurnSend) {
        pendingTurnSendsByRequestId[pending.requestId] = pending
        pendingTurnRequestIdByClientTurnId[pending.clientTurnId] = pending.requestId
    }

    func unregisterPendingTurnSend(requestId: String, clientTurnId: String) {
        pendingTurnSendsByRequestId.removeValue(forKey: requestId)
        if pendingTurnRequestIdByClientTurnId[clientTurnId] == requestId {
            pendingTurnRequestIdByClientTurnId.removeValue(forKey: clientTurnId)
        }
    }

    func registerPendingRPCRequest(_ pending: PendingRPCRequest) {
        pendingRPCRequestsByRequestId[pending.requestId] = pending
    }

    func unregisterPendingRPCRequest(requestId: String) {
        pendingRPCRequestsByRequestId.removeValue(forKey: requestId)
    }

    func failPendingSendAcks(error: Error) {
        let pending = Array(pendingTurnSendsByRequestId.values)
        pendingTurnSendsByRequestId.removeAll()
        pendingTurnRequestIdByClientTurnId.removeAll()

        for send in pending {
            send.waiter.resolve(.failure(error))
        }
    }

    func failPendingRPCRequests(error: Error) {
        let pending = Array(pendingRPCRequestsByRequestId.values)
        pendingRPCRequestsByRequestId.removeAll()

        for request in pending {
            request.waiter.resolve(.failure(error))
        }
    }

    static func isReconnectableSendError(_ error: Error) -> Bool {
        if let wsError = error as? WebSocketError {
            switch wsError {
            case .notConnected, .sendTimeout:
                return true
            }
        }

        if let ackError = error as? SendAckError {
            switch ackError {
            case .timeout:
                return true
            case .rejected:
                return false
            }
        }

        return false
    }
}

struct ForkMessage: Equatable, Sendable {
    let entryId: String
    let text: String
}

@MainActor
final class PendingRPCRequest {
    let command: String
    let requestId: String
    let waiter = RPCResultWaiter()

    init(command: String, requestId: String) {
        self.command = command
        self.requestId = requestId
    }
}

struct RPCResultPayload: Sendable {
    let data: JSONValue?
}

@MainActor
final class RPCResultWaiter {
    private var continuation: CheckedContinuation<RPCResultPayload, Error>?
    private var pendingResult: Result<RPCResultPayload, Error>?

    func wait() async throws -> RPCResultPayload {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RPCResultPayload, Error>) in
            if let pendingResult {
                continuation.resume(with: pendingResult)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(_ result: Result<RPCResultPayload, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
            return
        }

        pendingResult = result
    }
}

enum RPCRequestError: LocalizedError {
    case timeout(command: String)
    case rejected(command: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .timeout(let command):
            return "\(command) request timed out"
        case .rejected(let command, let reason):
            if let reason, !reason.isEmpty {
                return "\(command) rejected: \(reason)"
            }
            return "\(command) rejected"
        }
    }
}

enum ForkRequestError: LocalizedError, Equatable {
    case turnInProgress
    case noForkableMessages
    case entryNotForkable

    var errorDescription: String? {
        switch self {
        case .turnInProgress:
            return "Wait for this turn to finish before forking."
        case .noForkableMessages:
            return "No user messages available for forking yet."
        case .entryNotForkable:
            return "That message cannot be forked. Pick a user message from history."
        }
    }
}
