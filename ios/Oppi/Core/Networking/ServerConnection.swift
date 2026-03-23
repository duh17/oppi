import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Connection")

/// Top-level connection coordinator.
///
/// Owns the APIClient and WebSocketClient and shared stores.
/// Timeline pipeline (coalescer/reducer/correlator) is per-session,
/// owned by ChatSessionManager.
@MainActor @Observable
final class ServerConnection {
    // Public state
    private(set) var credentials: ServerCredentials?

    // Networking
    private(set) var apiClient: APIClient?
    private(set) var wsClient: WebSocketClient?
    private(set) var transportPath: ConnectionTransportPath = .paired

    private var discoveredLANEndpoint: LANDiscoveredEndpoint?
    private var endpointSelection: EndpointSelection?

    // periphery:ignore - used by ServerConnectionTests via @testable import
    /// Derived connection state for UI badges.
    var isConnected: Bool {
        wsClient?.status == .connected
    }

    // Stores
    let sessionStore = SessionStore()
    let permissionStore = PermissionStore()
    let workspaceStore = WorkspaceStore()
    let gitStatusStore = GitStatusStore()
    let fileIndexStore = FileIndexStore()
    let messageQueueStore = MessageQueueStore()

    // Audio
    let audioPlayer = AudioPlayerService()

    // Screen awake — injectable for tests; defaults to the process-wide singleton.
    var screenAwakeController: ScreenAwakeController = .shared

    // Runtime pipeline — coalescer/reducer/correlator moved to per-session
    // ChatSessionManager. Connection retains only connection-level state.
    //
    // The reducer/coalescer/correlator below exist solely for backward-compatible
    // test support. Production code (ChatView, OppiApp) no longer references them.
    // Tests that use ServerConnectionScenario get proper per-session pipelines.
    // periphery:ignore - test seam used by OppiTests via @testable import
    let reducer = TimelineReducer()
    // periphery:ignore - test seam used by OppiTests via @testable import
    let coalescer = DeltaCoalescer()
    // periphery:ignore - test seam used by OppiTests via @testable import
    let toolCallCorrelator = ToolCallCorrelator()

    // Stream lifecycle
    var activeSessionId: String?
    let sessionStreamCoordinator = SessionStreamCoordinator()

    /// Send protocol — turn ack, command correlation, retry.
    let sender = MessageSender()

    /// Convenience accessor for command tracker (owned by sender).
    var commands: CommandTracker { sender.commands }
    static let initialQueueSyncTimeout: Duration = .seconds(1)
    static let deferredQueueSyncTimeout: Duration = .seconds(3)
    static let deferredQueueSyncDelay: Duration = .milliseconds(250)

    struct SessionUsageMetricSnapshot: Equatable {
        let provider: String
        let model: String
        let messageCount: Int
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let mutatingToolCalls: Int
        let filesChanged: Int
        let addedLines: Int
        let removedLines: Int
        let contextTokens: Int
        let contextWindow: Int
    }

    // periphery:ignore - test seam used by ServerConnection*Tests via @testable import
    /// Test seam: override outbound send path without opening a real WebSocket.
    var _sendMessageForTesting: ((ClientMessage) async throws -> Void)? {
        get { sender._sendMessageForTesting }
        set { sender._sendMessageForTesting = newValue }
    }

    // periphery:ignore - test seam used by ServerConnection*Tests via @testable import
    /// Test seam: shorten ack timeout in integration-style tests.
    var _sendAckTimeoutForTesting: Duration? {
        get { sender._sendAckTimeoutForTesting }
        set { sender._sendAckTimeoutForTesting = newValue }
    }

    /// Test seam: observe refresh breadcrumbs emitted by list refresh paths.
    var _onRefreshBreadcrumbForTesting: ((_ message: String, _ metadata: [String: String], _ level: ClientLogLevel) -> Void)?

    // Extension UI
    var activeExtensionDialog: ExtensionUIRequest?
    var extensionToast: String?

    /// Per-connection chat UI state (composer, caches, thinking level).
    /// Views observe this directly via `@Environment(ChatSessionState.self)`.
    let chatState = ChatSessionState()

    /// Timer that auto-dismisses extension dialogs after their timeout expires.
    var extensionTimeoutTask: Task<Void, Never>?

    /// Deferred queue refresh retry when initial streamSession queue sync times out.
    var deferredQueueSyncTask: Task<Void, Never>?

    /// Silence watchdog — detects zombie WS connections during busy sessions.
    let silenceWatchdog = SilenceWatchdog()

    /// Set when server sends a fatal error (e.g. session limit).
    /// ChatSessionManager checks this to suppress auto-reconnect.
    var fatalSetupError = false

    /// Callback for permission resolution UI feedback.
    /// Set by the active ChatSessionManager so `respondToPermission` can
    /// update the per-session reducer immediately (before the server echoes
    /// the event back over WS).
    var onPermissionResolved: ((_ id: String, _ outcome: PermissionOutcome, _ tool: String, _ summary: String) -> Void)?

    /// Tracked unsubscribe tasks — keyed by sessionId.
    /// Cancelled before resubscribing the same session to prevent the
    /// fire-and-forget unsubscribe from racing past the new subscribe.
    var pendingUnsubscribeTasks: [String: Task<Void, Never>] = [:]

    /// Sessions we intentionally keep at notification-level subscription.
    /// Excludes the current `activeSessionId` (which is subscribed at full level).
    var notificationSessionIds: Set<String> = []

    /// Notification-level subscribes in flight; prevents duplicate subscribe storms
    /// when `syncNotificationSubscriptions()` is triggered repeatedly.
    var pendingNotificationSubscriptionIds: Set<String> = []

    /// Debounce timer for notification subscription sync.
    /// Coalesces rapid-fire calls (every server message triggers
    /// syncLiveActivityPermissions) into a single WS subscribe batch.
    var pendingNotificationSyncTask: Task<Void, Never>?

    /// In-flight auto-recovery when server rejects a command because the
    /// session lost full subscription level on `/stream`.
    var fullSubscriptionRecoveryTask: Task<Void, Never>?
    var lastFullSubscriptionRecoveryAt: Date?

    /// Last emitted per-session usage snapshot to avoid duplicate metric spam.
    @ObservationIgnored var sessionUsageMetricSnapshots: [String: SessionUsageMetricSnapshot] = [:]

    init() {
        // Wire test-compat coalescer → reducer for backward-compatible tests.
        // Production code uses per-session pipelines on ChatSessionManager.
        coalescer.onFlush = { [weak self] events in
            guard let self else { return }
            self.reducer.processBatch(events)
        }

        // Wire silence watchdog probe to request a state refresh.
        silenceWatchdog.onProbe = { [weak self] in
            try? await self?.requestState()
        }
    }

    /// Fingerprint of the currently connected server (set after configure).
    private(set) var currentServerId: String?

    /// Stable key used by LiveActivityManager to merge multi-server snapshots.
    var liveActivityConnectionId: String {
        currentServerId ?? "default"
    }

    // MARK: - Setup

    // periphery:ignore - used by ServerConnectionTests via @testable import
    /// Reconfigure to target a different server.
    ///
    /// Tears down any active session stream and WebSocket, then configures
    /// the new server's credentials. Returns `false` on policy/URL failure.
    @discardableResult
    func switchServer(to server: PairedServer) -> Bool {
        guard server.id != currentServerId else { return true } // Already targeting this server
        disconnectSession()
        disconnectStream()
        discoveredLANEndpoint = nil
        endpointSelection = nil
        transportPath = .paired
        return configure(credentials: server.credentials)
    }

    /// Configure the connection with validated credentials.
    /// Returns `false` if the credentials contain a malformed host.
    @discardableResult
    func configure(credentials: ServerCredentials) -> Bool {
        guard let selection = LANEndpointSelection.select(
            credentials: credentials,
            discoveredEndpoint: discoveredLANEndpoint
        ) else {
            logger.error("Invalid server credentials: host=\(credentials.host) port=\(credentials.port)")
            return false
        }

        self.credentials = credentials
        self.currentServerId = credentials.normalizedServerFingerprint
        self.endpointSelection = selection
        self.transportPath = selection.transportPath

        self.apiClient = APIClient(
            baseURL: selection.baseURL,
            token: credentials.token,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint
        )
        self.wsClient = WebSocketClient(
            credentials: credentials,
            preferredEndpoint: selection
        )
        sender.wsClient = self.wsClient

        return true
    }

    func setDiscoveredLANEndpoint(_ endpoint: LANDiscoveredEndpoint?) {
        discoveredLANEndpoint = endpoint
        guard let credentials else { return }
        guard let selection = LANEndpointSelection.select(
            credentials: credentials,
            discoveredEndpoint: endpoint
        ) else {
            return
        }

        let previousSelection = endpointSelection
        endpointSelection = selection
        transportPath = selection.transportPath

        if previousSelection?.transportPath != selection.transportPath {
            ClientLog.info(
                "Network",
                "Transport path changed",
                metadata: [
                    "from": previousSelection?.transportPath.rawValue ?? "unknown",
                    "to": selection.transportPath.rawValue,
                    "fromHost": previousSelection?.baseURL.host ?? "unknown",
                    "toHost": selection.baseURL.host ?? "unknown",
                ]
            )
        }

        wsClient?.setPreferredEndpoint(selection)

        if previousSelection?.baseURL != selection.baseURL {
            apiClient = APIClient(
                baseURL: selection.baseURL,
                token: credentials.token,
                tlsCertFingerprint: credentials.normalizedTLSCertFingerprint
            )
        }
    }

    // MARK: - Network Path Change

    /// Handle a network interface change (WiFi→cellular, LAN→Tailscale).
    ///
    /// Called by `ConnectionCoordinator` when `NWPathMonitor` detects the
    /// device changed networks. Clears the stale LAN endpoint (falls back
    /// to paired/Tailscale) and forces a WebSocket reconnect when needed.
    ///
    /// Without this, the WS would burn all reconnect attempts against the
    /// dead LAN IP, then fully disconnect — requiring an app restart.
    func handleNetworkPathChange() {
        let wasOnLAN = transportPath == .lan

        // Clear stale LAN endpoint — falls back to paired/Tailscale address
        setDiscoveredLANEndpoint(nil)

        guard let wsClient else { return }

        let statusBeforePathChange = wsClient.status

        let shouldReconnect: Bool
        switch statusBeforePathChange {
        case .reconnecting:
            // Stale backoff accumulated against the old LAN IP.
            // Cancel and reconnect immediately with the new endpoint.
            wsClient.cancelReconnectBackoff()
            shouldReconnect = true

        case .connected where wasOnLAN:
            // Connected to a LAN IP that's now unreachable.
            // Force reconnect rather than waiting 30-60s for the
            // ping watchdog to detect the zombie TCP connection.
            shouldReconnect = true

        case .disconnected:
            // Dead — try to reconnect with the updated endpoint.
            shouldReconnect = true

        default:
            // Connected via Tailscale or still connecting — leave it.
            // Tailscale handles network mobility internally.
            shouldReconnect = false
        }

        guard shouldReconnect else { return }

        ClientLog.info("Network", "Force stream reconnect after path change", metadata: [
            "wasLAN": wasOnLAN ? "true" : "false",
            "wsStatus": String(describing: statusBeforePathChange),
            "activeSession": activeSessionId ?? "none",
        ])

        // Tear down old WS + consumption task. Per-session continuations
        // are preserved — they'll resume receiving events after the new
        // WS connects and resubscribeTrackedSessions() runs.
        streamConsumptionTask?.cancel()
        streamConsumptionTask = nil
        wsClient.disconnect()

        // Reconnect with the updated (Tailscale) endpoint.
        connectStream()
    }

    // MARK: - Stream Lifecycle

    /// Background task consuming the multiplexed `/stream` WebSocket.
    internal var streamConsumptionTask: Task<Void, Never>?

    /// Monotonic generation for consumption task ownership.
    /// Prevents a stale task's cleanup from nil-ing a newer task reference
    /// when `handleNetworkPathChange` or `reconnectIfNeeded` tears down
    /// and recreates the stream in quick succession.
    private var streamConsumptionGeneration: UInt64 = 0

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

        // Don't tear down a healthy connection. wsClient.connect() calls
        // disconnect() internally, which would drop a working socket just
        // to re-establish it — causing an 8s+ re-entry delay while
        // waitForConnection() blocks subscribe/get_queue sends.
        if wsClient.status == .connected {
            return
        }

        let stream = wsClient.connect()

        streamConsumptionGeneration &+= 1
        let generation = streamConsumptionGeneration

        streamConsumptionTask = Task { [weak self] in
            for await streamMessage in stream {
                guard let self, !Task.isCancelled else { break }
                self.routeStreamMessage(streamMessage)
            }
            // Stream ended (WS disconnected or max reconnect attempts).
            // Nil out so future connectStream() calls can restart.
            // Guard on generation to prevent a stale task from nil-ing
            // a newer task created by handleNetworkPathChange/reconnectIfNeeded.
            await MainActor.run { [weak self] in
                guard let self, self.streamConsumptionGeneration == generation else { return }
                self.streamConsumptionTask = nil
            }
        }
    }

    /// Disconnect the persistent `/stream` WebSocket.
    func disconnectStream() {
        cancelDeferredQueueSync()
        Task {
            await sessionStreamCoordinator.noteStreamDisconnected()
        }
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
        pendingNotificationSyncTask?.cancel()
        pendingNotificationSyncTask = nil
        notificationSessionIds.removeAll()
        pendingNotificationSubscriptionIds.removeAll()
        sessionUsageMetricSnapshots.removeAll()
        wsClient?.disconnect()

        if ReleaseFeatures.liveActivitiesEnabled {
            LiveActivityManager.shared.removeConnection(liveActivityConnectionId)
        }
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

        // Resolve pending command waiters directly from stream routing,
        // BEFORE yielding to the per-session stream. Commands sent during
        // streamSession() setup (subscribe, get_queue) block before the
        // consumer loop starts, so their results must be resolved eagerly.
        resolveEagerCommands(message)

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

    /// Eagerly resolve command results from stream routing for commands
    /// sent during `streamSession()` setup.
    ///
    /// Without this, `command_result` messages buffer in the per-session
    /// `AsyncStream` (nobody consuming it yet) while `sendCommandAwaitingResult`
    /// waits for the waiter to resolve — causing an 8s timeout.
    private func resolveEagerCommands(_ message: ServerMessage) {
        guard case .commandResult(let command, let requestId, let success, let data, let error) = message,
              let requestId,
              sessionStreamCoordinator.shouldResolveEagerly(command: command) else {
            return
        }
        _ = commands.resolveCommandResult(
            command: command, requestId: requestId,
            success: success, data: data, error: error
        )
    }

    /// Handle `/stream` (re)connection — coordinator re-subscribes tracked sessions.
    private func handleStreamReconnected() {
        Task { [weak self] in
            guard let self else { return }
            await self.sessionStreamCoordinator.handleStreamReconnected(connection: self)
        }
    }

    static let resubscribeMaxAttempts = 3
    static let resubscribeAckTimeout: Duration = .seconds(6)
    /// Typed stream error code emitted by server/src/stream.ts when a command
    /// arrives for a session without full-level subscription.
    static let missingFullSubscriptionErrorCode = "stream_not_subscribed_full"

    /// Keep non-active sessions subscribed at notification level so cross-session
    /// state transitions (agent_start/agent_end/permissions) continue flowing.
    ///
    /// Debounced: coalesces rapid calls (server messages trigger this on every
    /// state/permission/lifecycle event) into a single subscribe batch after
    /// a 400ms quiet period. Eliminates the feedback loop where subscribe
    /// responses trigger more syncs, which trigger more subscribes.
    func syncNotificationSubscriptions() {
        pendingNotificationSyncTask?.cancel()
        pendingNotificationSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.sessionStreamCoordinator.syncNotificationSubscriptions(connection: self)
        }
    }

    func triggerFullSubscriptionRecovery(sessionId: String, serverError: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.sessionStreamCoordinator.triggerFullSubscriptionRecovery(
                connection: self,
                sessionId: sessionId,
                serverError: serverError
            )
        }
    }

    /// Handle notification-level events from non-active sessions
    /// (e.g., permissions from other sessions on this server).
    ///
    /// Delegates store mutations to `applySharedStoreUpdate` (same logic
    /// as the active-session path), then records Live Activity events
    /// directly (cross-session events bypass the coalescer).
    private func handleCrossSessionMessage(_ message: ServerMessage, sessionId: String) {
        let result = applySharedStoreUpdate(for: message, sessionId: sessionId)

        if result.handled {
            recordCrossSessionLiveActivityEvent(message, sessionId: sessionId)
            return
        }

        // Events not handled by the shared helper
        switch message {
        case .error(let errorMessage, _, _):
            if !errorMessage.hasPrefix("Retrying ("),
               var current = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                current.status = .error
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            if ReleaseFeatures.liveActivitiesEnabled {
                LiveActivityManager.shared.recordEvent(
                    connectionId: liveActivityConnectionId,
                    event: .error(sessionId: sessionId, message: errorMessage)
                )
            }
            syncLiveActivityPermissions()
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
        await sessionStreamCoordinator.streamSession(
            connection: self,
            sessionId: sessionId,
            workspaceId: workspaceId
        )
    }

    func cancelDeferredQueueSync() {
        deferredQueueSyncTask?.cancel()
        deferredQueueSyncTask = nil
    }

    func waitForConnectedStream(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> Bool {
        let startedAt = ContinuousClock.now

        while wsClient?.status != .connected {
            if Task.isCancelled {
                return false
            }

            if ContinuousClock.now - startedAt >= timeout {
                return false
            }

            try? await Task.sleep(for: pollInterval)
        }

        return true
    }

    func streamEndpointHostForMetrics() -> String {
        endpointSelection?.baseURL.host ?? credentials?.host ?? "unknown"
    }

    /// Unsubscribe from a specific session.
    ///
    /// The send is tracked so `streamSession()` can cancel it before
    /// resubscribing the same session — preventing the fire-and-forget
    /// unsubscribe from arriving after a newer subscribe.
    func unsubscribeSession(_ sessionId: String) {
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

    /// Focus the connection on a session for command routing (prompt/stop/etc).
    ///
    /// Unlike `disconnectSession`, this does NOT unsubscribe the previous session
    /// or tear down streams. The previous session's ChatSessionManager keeps
    /// receiving events via its per-session continuation and coalescer/reducer.
    func focusSession(_ sessionId: String) {
        activeSessionId = sessionId
        sender.activeSessionId = sessionId
        // Reset per-connection UI state for the new focused session
        activeExtensionDialog = nil
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
        chatState.resetSessionState()
    }

    /// Disconnect from the current session stream.
    func disconnectSession() {
        cancelDeferredQueueSync()
        commands.failAllTurnSends(error: WebSocketError.notConnected)
        commands.failAllCommands(error: WebSocketError.notConnected)

        if let activeSessionId {
            unsubscribeSession(activeSessionId)
            messageQueueStore.clear(sessionId: activeSessionId)
            sessionUsageMetricSnapshots.removeValue(forKey: activeSessionId)
            screenAwakeController.clearSessionActivity(sessionId: activeSessionId)
        }

        activeSessionId = nil
        sender.activeSessionId = nil
        Task {
            await sessionStreamCoordinator.noteStreamDisconnected()
            await SentryService.shared.setSessionContext(sessionId: nil, workspaceId: nil)
        }
        // Clear stale extension dialog — it's tied to the active session stream
        activeExtensionDialog = nil
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
        silenceWatchdog.stop()
        chatState.resetSessionState()

        syncNotificationSubscriptions()

        // Don't end Live Activity on disconnect — it should persist
        // on Lock Screen until the session actually ends.
        // Don't disconnect /stream WS — it stays open for other subscriptions.
    }

    /// Background transition hook.
    /// Production coalescers are per-session (on ChatSessionManager) — flushed
    /// via ChatView's scenePhase handler. This flushes the test-compat coalescer
    /// so tests using handleServerMessage() can verify timeline state.
    func flushAndSuspend() {
        coalescer.flushNow()
    }

    // MARK: - Actions (delegated to MessageSender)

    func sendPrompt(_ text: String, images: [ImageAttachment]? = nil, onAckStage: ((TurnAckStage) -> Void)? = nil) async throws {
        try await sender.sendPrompt(text, images: images, onAckStage: onAckStage)
    }

    func sendSteer(_ text: String, images: [ImageAttachment]? = nil, onAckStage: ((TurnAckStage) -> Void)? = nil) async throws {
        try await sender.sendSteer(text, images: images, onAckStage: onAckStage)
    }

    func sendFollowUp(_ text: String, images: [ImageAttachment]? = nil, onAckStage: ((TurnAckStage) -> Void)? = nil) async throws {
        try await sender.sendFollowUp(text, images: images, onAckStage: onAckStage)
    }

    func sendStop() async throws { try await sender.sendStop() }
    func sendStopSession() async throws { try await sender.sendStopSession() }

    func send(_ message: ClientMessage) async throws { try await sender.send(message) }

    func requestState() async throws { try await sender.requestState() }

    func requestMessageQueue(timeout: Duration = MessageSender.commandRequestTimeoutDefault) async throws {
        try await sender.requestMessageQueue(timeout: timeout)
    }

    func setMessageQueue(baseVersion: Int, steering: [MessageQueueDraftItem], followUp: [MessageQueueDraftItem]) async throws {
        try await sender.setMessageQueue(baseVersion: baseVersion, steering: steering, followUp: followUp)
    }

    func sendCommandAwaitingResult(
        command: String,
        timeout: Duration = MessageSender.commandRequestTimeoutDefault,
        message: (String) -> ClientMessage
    ) async throws -> JSONValue? {
        try await sender.sendCommandAwaitingResult(command: command, timeout: timeout, message: message)
    }

    func getForkMessages() async throws -> [ForkMessage] { try await sender.getForkMessages() }

    /// Respond to a permission request (has store side effects — stays on ServerConnection).
    func respondToPermission(id: String, action: PermissionAction, scope: PermissionScope = .once, expiresInMs: Int? = nil) async throws {
        let tool = permissionStore.pending.first(where: { $0.id == id })?.tool ?? ""
        let normalizedChoice = PermissionApprovalPolicy.normalizedChoice(
            tool: tool,
            choice: PermissionResponseChoice(action: action, scope: scope, expiresInMs: expiresInMs)
        )

        try await sender.dispatchSend(
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
            if request.sessionId == activeSessionId {
                onPermissionResolved?(id, outcome, request.tool, request.displaySummary)
            }
        }
        if ReleaseFeatures.pushNotificationsEnabled {
            PermissionNotificationService.shared.cancelNotification(permissionId: id)
        }
        syncLiveActivityPermissions()
    }

    /// Respond to an extension UI dialog (has UI side effects — stays on ServerConnection).
    func respondToExtensionUI(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil) async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.extensionUIResponse(id: id, value: value, confirmed: confirmed, cancelled: cancelled), sessionId: activeSessionId)
        activeExtensionDialog = nil
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
    }

    func _setActiveSessionIdForTesting(_ sessionId: String?) {
        activeSessionId = sessionId
        sender.activeSessionId = sessionId
        coalescer.sessionId = sessionId
    }

    func telemetryErrorKind(from error: Error) -> String {
        MessageSender.telemetryErrorKind(from: error)
    }

    // MARK: - Reconnect State (used by ServerConnection+Refresh)

    /// Reentrancy guard — prevents concurrent `reconnectIfNeeded` calls.
    var foregroundRecoveryInFlight = false

    /// Skip expensive list refreshes when data was synced very recently.
    static let listRefreshMinimumInterval: TimeInterval = 120

    /// Shared in-flight tasks to coalesce overlapping refresh requests.
    var sessionListRefreshTask: Task<Void, Never>?
    var workspaceCatalogRefreshTask: Task<Void, Never>?

#if DEBUG
    /// Set the server ID for screenshot preview harness (no real credentials needed).
    func setPreviewServerId(_ id: String) {
        currentServerId = id
    }
#endif
}
