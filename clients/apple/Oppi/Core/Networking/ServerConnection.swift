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
    var splitSessionStreamAvailable = false
    var dictationStreamAvailable = false
    var appEventStreamAvailable = false
    private(set) var missingRequiredSplitStreamCapabilities: [String] = []
    private var streamCapabilitiesLoaded = false
    private var streamCapabilitiesRefreshFailed = false
    private var streamCapabilitiesRefreshTask: Task<Void, Never>?
    private var streamCapabilitiesGeneration: UInt64 = 0
    private(set) var focusedSessionStreamEndpointKind = "none"
    private var focusedSessionStreamSessionId: String?
    private var focusedSessionStreamWorkspaceId: String?
    private var focusedSessionStreamURL: URL?
    private(set) var transportPath: ConnectionTransportPath = .paired

    /// True when the server can accept remote ASR dictation streams.
    ///
    /// `serverDictationAvailable` is normally learned from a focused session
    /// stream bootstrap. Pre-session composers rely on `/server/info` stream
    /// capabilities instead.
    var serverDictationTransportAvailable: Bool {
        serverDictationAvailable || dictationStreamAvailable
    }

    var requiredSplitStreamCapabilitiesStatusForDiagnostics: String {
        if streamCapabilitiesRefreshFailed, streamCapabilitiesLoaded, missingRequiredSplitStreamCapabilities.isEmpty {
            return "ready:refreshFailed"
        }
        if streamCapabilitiesRefreshFailed {
            return "refreshFailed"
        }
        if !streamCapabilitiesLoaded {
            return "loading"
        }
        if missingRequiredSplitStreamCapabilities.isEmpty {
            return "ready"
        }
        return "missing:\(missingRequiredSplitStreamCapabilities.joined(separator: ","))"
    }

    var hasRequiredSplitStreamCapabilities: Bool {
        streamCapabilitiesLoaded
            && missingRequiredSplitStreamCapabilities.isEmpty
    }

    private func isUnsupportedSplitStreamStatus(_ statusCode: Int?) -> Bool {
        guard let statusCode else { return false }
        return statusCode == 404 || statusCode == 405 || statusCode == 426 || statusCode == 501
    }

    func disableSplitStreamsForUnsupportedEndpoint() {
        splitSessionStreamAvailable = false
        dictationStreamAvailable = false
        missingRequiredSplitStreamCapabilities = ServerInfo.Capabilities.requiredSplitStreamCapabilityNames
        streamCapabilitiesRefreshFailed = false
        clearFocusedSessionStreamEndpoint()
        if let selection = endpointSelection {
            wsClient?.setPreferredEndpoint(selection)
        }
        wsClient?.setStreamURL(nil)
    }

    func focusedSessionStreamEndpointIsUnsupported() -> Bool {
        focusedSessionStreamEndpointKind == "split_session"
            && isUnsupportedSplitStreamStatus(wsClient?.lastHTTPStatusCode)
    }

    private var discoveredLANEndpoint: LANDiscoveredEndpoint?
    private var endpointSelection: EndpointSelection?

    // periphery:ignore - used by ServerConnectionTests via @testable import
    /// Derived connection state for UI badges.
    var isConnected: Bool {
        wsClient?.status == .connected
    }

    /// Whether the server has server dictation configured (remote dictation server or another STT backend).
    /// Updated from server capabilities and `stream_connected` messages.
    private(set) var serverDictationAvailable = false

    // Stores
    let sessionStore = SessionStore()
    let askRequestStore = AskRequestStore()
    let workspaceStore = WorkspaceStore()
    let gitStatusStore = GitStatusStore()
    let fileIndexStore = FileIndexStore()
    let messageQueueStore = MessageQueueStore()

    // Audio
    let audioPlayer = AudioPlayerService()

    // Screen awake — injectable for tests; defaults to the process-wide singleton.
    var screenAwakeController: ScreenAwakeController = .shared

    // Runtime pipeline — coalescer/reducer/correlator are per-session,
    // owned by ChatSessionManager. Tests use TestEventPipeline instead.

    // Stream lifecycle
    let focusedSessionStore = FocusedSessionStore()

    var focusedSessionId: String? {
        focusedSessionStore.focused?.sessionId
    }

    func isFocusedSession(_ sessionId: String) -> Bool {
        focusedSessionStore.isFocused(sessionId)
    }
    let sessionStreamCoordinator = SessionStreamCoordinator()
    let appEventStreamCoordinator = AppEventStreamCoordinator()
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

        var hasUsageSignal: Bool {
            messageCount > 0
                || totalTokens > 0
                || mutatingToolCalls > 0
                || filesChanged > 0
                || addedLines > 0
                || removedLines > 0
                || contextTokens > 0
        }
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

    // periphery:ignore - test seam used by ServerConnection*Tests via @testable import
    /// Test seam: shorten retry delay in integration-style tests.
    var _turnSendRetryDelayForTesting: Duration? {
        get { sender._turnSendRetryDelayForTesting }
        set { sender._turnSendRetryDelayForTesting = newValue }
    }

    /// Test seam: observe refresh events emitted by list refresh paths.
    var _onRefreshEventForTesting: ((_ message: String, _ metadata: [String: String], _ level: ClientLogLevel) -> Void)?

    // periphery:ignore - test seam used by ServerConnectionStreamTests via @testable import
    /// Test seam: replace WebSocket opening with a deterministic stream.
    var _connectStreamForTesting: (() -> AsyncStream<StreamFrameEvent>)?

    /// Test seam: observe app-event stream start without opening a real socket.
    var _startAppEventStreamForTesting: ((URL) -> Void)?

    /// Test seam: override the cache actor used by list refresh paths.
    var _cacheForTesting: TimelineCache?

    /// Test seam: observe view-driven session re-entry preparation.
    var _onPrepareForSessionReentryForTesting: ((String) -> Void)?

    // Extension UI
    var activeExtensionDialog: ExtensionUIRequest? {
        get {
            guard let focusedSessionId else { return nil }
            return pendingExtensionDialogQueues[focusedSessionId]?.first
        }
        set {
            if let newValue {
                replaceActiveExtensionDialog(newValue, for: newValue.sessionId)
            }
            // Sheet dismissal is a view lifecycle event, not authoritative
            // settlement. Responses and server settled messages clear by id.
        }
    }
    /// Queued sheet-backed generic extension dialogs keyed by session id.
    var pendingExtensionDialogQueues: [String: [ExtensionUIRequest]] = [:]
    /// Visible sheet-backed dialog per session, kept for existing callers/tests.
    var pendingExtensionDialogs: [String: ExtensionUIRequest] {
        get {
            Dictionary(uniqueKeysWithValues: pendingExtensionDialogQueues.compactMap { entry in
                guard let first = entry.value.first else { return nil }
                return (entry.key, first)
            })
        }
        set {
            pendingExtensionDialogQueues = newValue.mapValues { [$0] }
        }
    }
    var pendingExtensionDialogRequests: [ExtensionUIRequest] {
        pendingExtensionDialogQueues.values.flatMap { $0 }
    }
    var extensionToast: String?
    var extensionSurfaceBySession: [String: ExtensionSurfaceState] = [:]

    /// Per-connection chat UI state (composer, caches, thinking level).
    /// Views observe this directly via `@Environment(ChatSessionState.self)`.
    let chatState = ChatSessionState()

    /// Deferred queue refresh retry when initial streamSession queue sync times out.
    var deferredQueueSyncTask: Task<Void, Never>?

    /// Silence watchdog — detects zombie WS connections during busy sessions.
    let silenceWatchdog = SilenceWatchdog()

    /// Set when server sends a fatal error (e.g. session limit).
    /// ChatSessionManager checks this to suppress auto-reconnect.
    var fatalSetupError = false

    /// Deferred disconnects for hidden sessions that still need live audio-stream delivery.
    var deferredPlaybackDisconnectTasks: [String: Task<Void, Never>] = [:]

    /// Minimum spacing for repeated per-session usage snapshots. These are
    /// capacity/cost diagnostics, not live UX counters.
    static let sessionUsageMetricMinimumInterval: TimeInterval = 60

    /// Last emitted per-session usage snapshot to avoid duplicate metric spam.
    @ObservationIgnored var sessionUsageMetricSnapshots: [String: SessionUsageMetricSnapshot] = [:]
    @ObservationIgnored var sessionUsageMetricLastEmittedAt: [String: Date] = [:]

    init() {
        // Wire silence watchdog probe to request a state refresh.
        silenceWatchdog.onProbe = { [weak self] in
            try? await self?.requestState()
        }
        sender.transportPathProvider = { [weak self] in
            self?.transportPath ?? .paired
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
        disconnectAppEventStream()
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

        disconnectAppEventStream()
        streamCapabilitiesRefreshTask?.cancel()
        streamCapabilitiesRefreshTask = nil
        streamCapabilitiesGeneration &+= 1

        self.credentials = credentials
        self.currentServerId = credentials.normalizedServerFingerprint
        self.endpointSelection = selection
        self.splitSessionStreamAvailable = false
        self.dictationStreamAvailable = false
        self.appEventStreamAvailable = false
        self.missingRequiredSplitStreamCapabilities = []
        self.streamCapabilitiesLoaded = false
        self.streamCapabilitiesRefreshFailed = false
        self.clearFocusedSessionStreamEndpoint()
        self.transportPath = selection.transportPath

        self.apiClient = APIClient(
            baseURL: selection.baseURL,
            token: credentials.token,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint
        )
        self.wsClient = WebSocketClient(
            credentials: credentials,
            preferredEndpoint: selection,
            diagnosticRole: "focused_session"
        )
        self.wsClient?.setStreamURL(nil)
        sender.wsClient = self.wsClient
        sender.focusedSessionProvider = { [weak self] in
            self?.focusedSessionStore.focused
        }

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
        let shouldDeferEndpointSwitch = previousSelection?.transportPath == .paired
            && selection.transportPath == .lan
            && wsClient?.status == .connected

        wsClient?.setPreferredEndpoint(selection)

        if shouldDeferEndpointSwitch {
            ClientLog.info(
                "Network",
                "Deferring LAN API switch until transport reconnect",
                metadata: [
                    "from": previousSelection?.transportPath.rawValue ?? "unknown",
                    "to": selection.transportPath.rawValue,
                    "fromHost": previousSelection?.baseURL.host ?? "unknown",
                    "toHost": selection.baseURL.host ?? "unknown",
                ]
            )
            return
        }

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

        if previousSelection?.baseURL != selection.baseURL {
            apiClient = APIClient(
                baseURL: selection.baseURL,
                token: credentials.token,
                tlsCertFingerprint: credentials.normalizedTLSCertFingerprint
            )
            if appEventStreamAvailable {
                disconnectAppEventStream()
                startAppEventStreamIfAvailable()
            }
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

        var pathChangeMetadata: [String: String] = [
            "wasLAN": wasOnLAN ? "true" : "false",
            "wsStatus": String(describing: statusBeforePathChange),
            "hasFocusedSession": focusedSessionId == nil ? "false" : "true",
        ]
        pathChangeMetadata.merge(ClientLog.endpointMetadata(endpointSelection?.baseURL, prefix: "api")) { current, _ in current }
        pathChangeMetadata.merge(ClientLog.endpointMetadata(focusedSessionStreamURL, prefix: "stream")) { current, _ in current }
        ClientLog.info("Network", "Force stream reconnect after path change", metadata: pathChangeMetadata)

        // Tear down old WS + consumption task. Per-session continuations
        // are preserved; the active endpoint will be reopened below.
        streamConsumptionTask?.cancel()
        streamConsumptionTask = nil
        wsClient.disconnect()

        refreshPreparedFocusedSessionEndpointAfterEndpointChange()

        // Reconnect with the updated (Tailscale) endpoint.
        connectStream()
        if appEventStreamAvailable {
            disconnectAppEventStream()
            startAppEventStreamIfAvailable()
        }
    }

    // MARK: - Stream Lifecycle

    /// Background task consuming the active session WebSocket.
    internal var streamConsumptionTask: Task<Void, Never>?

    /// Monotonic generation for consumption task ownership.
    /// Prevents a stale task's cleanup from nil-ing a newer task reference
    /// when `handleNetworkPathChange` or `reconnectIfNeeded` tears down
    /// and recreates the stream in quick succession.
    private var streamConsumptionGeneration: UInt64 = 0

    /// Per-session continuations for routing stream messages with metadata in-band.
    internal var sessionEventContinuations: [String: AsyncStream<SessionStreamEvent>.Continuation] = [:]

    /// Connect the active session WebSocket endpoint.
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
        // waitForConnection() blocks command sends such as get_queue.
        if wsClient.status == .connected {
            return
        }

        let stream = _connectStreamForTesting?() ?? wsClient.connect()

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

    /// Disconnect the active session WebSocket endpoint.
    func disconnectStream() {
        cancelDeferredQueueSync()
        sessionStreamCoordinator.noteStreamDisconnected()
        streamConsumptionTask?.cancel()
        streamConsumptionTask = nil
        for (_, cont) in sessionEventContinuations {
            cont.finish()
        }
        sessionEventContinuations.removeAll()
        sessionUsageMetricSnapshots.removeAll()
        sessionUsageMetricLastEmittedAt.removeAll()
        serverDictationAvailable = false
        clearFocusedSessionStreamEndpoint()
        wsClient?.disconnect()

        if ReleaseFeatures.liveActivitiesEnabled {
            LiveActivityManager.shared.removeConnection(liveActivityConnectionId)
        }
    }

    func refreshStreamCapabilitiesIfNeeded() async {
        guard !streamCapabilitiesLoaded else { return }
        await refreshStreamCapabilities()
    }

    func refreshStreamCapabilities() async {
        guard let apiClient else { return }
        if let inFlight = streamCapabilitiesRefreshTask {
            await inFlight.value
            return
        }

        let generation = streamCapabilitiesGeneration
        let task = Task { @MainActor [weak self, apiClient] in
            guard let self else { return }
            defer { self.streamCapabilitiesRefreshTask = nil }

            let hadLoadedCapabilities = self.streamCapabilitiesLoaded
            do {
                let info = try await apiClient.serverInfo()
                guard self.streamCapabilitiesGeneration == generation else { return }

                let capabilities = info.capabilities
                self.splitSessionStreamAvailable = capabilities?.sessionStream?.version ?? 0 >= 1
                self.dictationStreamAvailable = capabilities?.dictationStream?.version ?? 0 >= 1
                self.appEventStreamAvailable = capabilities?.appEventStream?.version ?? 0 >= 1
                self.missingRequiredSplitStreamCapabilities = ServerInfo.Capabilities
                    .missingRequiredSplitStreamCapabilities(in: capabilities)
                self.streamCapabilitiesRefreshFailed = false
                if self.dictationStreamAvailable {
                    self.setServerDictationAvailableFromCapabilities(true)
                }
                self.streamCapabilitiesLoaded = true
                if self.appEventStreamAvailable {
                    self.startAppEventStreamIfAvailable()
                } else {
                    self.disconnectAppEventStream()
                }
            } catch {
                guard self.streamCapabilitiesGeneration == generation else { return }
                // Do not let a transient handoff failure permanently poison stream
                // capability state. If we already had a good capability snapshot,
                // keep using it; otherwise leave the state unloaded so the next
                // session entry retries /server/info instead of returning nil forever.
                self.streamCapabilitiesRefreshFailed = true
                if !hadLoadedCapabilities {
                    self.splitSessionStreamAvailable = false
                    self.dictationStreamAvailable = false
                    self.appEventStreamAvailable = false
                    self.disconnectAppEventStream()
                    self.missingRequiredSplitStreamCapabilities = []
                    self.streamCapabilitiesLoaded = false
                }

                var metadata = ClientLog.networkErrorMetadata(error)
                metadata["hadLoadedCapabilities"] = hadLoadedCapabilities ? "true" : "false"
                metadata["capabilityStatus"] = self.requiredSplitStreamCapabilitiesStatusForDiagnostics
                metadata["transport"] = self.transportPath.rawValue
                let apiBaseURL = await apiClient.baseURL
                metadata.merge(ClientLog.endpointMetadata(apiBaseURL, prefix: "api")) { current, _ in current }
                ClientLog.warning("Network", "Stream capability refresh failed", metadata: metadata)
            }
        }

        streamCapabilitiesRefreshTask = task
        await task.value
    }

    /// Send a graceful WS close frame before iOS suspends the app.
    /// Preserves subscriptions so `reconnectIfNeeded()` can reopen on foreground.
    func prepareForBackground() {
        wsClient?.prepareForBackground()
    }

    /// Route a message from the active session stream to the appropriate session.
    func routeStreamMessage(_ streamMessage: StreamMessage) {
        routeStreamMessage(StreamFrameEvent(
            sessionId: streamMessage.sessionId,
            message: streamMessage.message,
            meta: InboundStreamMeta(
                seq: streamMessage.seq,
                currentSeq: streamMessage.currentSeq,
                receivedAtMs: Date.nowMs(),
                transportPath: transportPath
            )
        ))
    }

    func routeStreamMessage(_ frameEvent: StreamFrameEvent) {
        let sessionId = frameEvent.sessionId
        let message = frameEvent.message

        // Handle stream-level events (no sessionId)
        if case .streamConnected(_, let available) = message {
            serverDictationAvailable = available
            handleStreamReconnected()
            return
        }

        // Resolve pending command waiters directly at the stream boundary,
        // BEFORE yielding to the per-session stream. Semantic effects still
        // flow downstream, but request waiters do not depend on a session
        // consumer being attached and running.
        resolveBoundaryCommandResult(message, meta: frameEvent.meta)

        // Route to per-session continuation if active. Metadata stays attached
        // to the message through SessionStreamEvent.
        if let sessionId, let cont = sessionEventContinuations[sessionId] {
            cont.yield(SessionStreamEvent(
                sessionId: sessionId,
                message: message,
                meta: frameEvent.meta,
                source: .live
            ))
        }

        // Also process events from non-focused sessions. If a non-focused full
        // session has its own live consumer, the per-session pipeline owns the
        // timeline-specific work.
        if let sessionId, !isFocusedSession(sessionId) {
            let hasLiveSessionConsumer = sessionEventContinuations[sessionId] != nil
            handleCrossSessionMessage(
                message,
                sessionId: sessionId,
                deferSharedStoreToLiveSession: hasLiveSessionConsumer
            )
        }
    }

    /// Resolve command waiters at the stream boundary for every command_result
    /// with a requestId. Semantic effects still flow through session routing.
    private func resolveBoundaryCommandResult(_ message: ServerMessage, meta: InboundStreamMeta?) {
        guard case .commandResult(let command, let requestId, let success, let data, let error) = message,
              let requestId else {
            return
        }

        let resolved: Bool
        if command == "prompt" || command == "steer" || command == "follow_up" {
            resolved = commands.resolveTurnCommandResult(
                command: command,
                requestId: requestId,
                success: success,
                error: error
            )
        } else {
            resolved = commands.resolveCommandResult(
                command: command,
                requestId: requestId,
                success: success,
                data: data,
                error: error
            )
        }

        guard resolved, let receivedAtMs = meta?.receivedAtMs else { return }
        let lagMs = max(0, Date.nowMs() - receivedAtMs)
        guard shouldRecordCommandResolveLag(command: command, success: success, lagMs: Int(lagMs)) else { return }
        let transport = meta?.transportPath.rawValue ?? transportPath.rawValue
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .commandResolveLagMs,
                value: Double(lagMs),
                unit: .ms,
                tags: [
                    "command": command,
                    "transport": transport,
                    "success": success ? "true" : "false",
                ]
            )
        }
    }

    private func shouldRecordCommandResolveLag(command: String, success: Bool, lagMs: Int) -> Bool {
        if !success { return true }
        guard command == "get_queue" else { return true }
        return lagMs >= 50
    }

    /// Handle focused session stream reconnection.
    private func handleStreamReconnected() {
        Task { [weak self] in
            guard let self else { return }
            await sessionStreamCoordinator.handleStreamReconnected(connection: self)
        }
    }

    /// Handle events from non-focused sessions delivered by active session streams.
    ///
    /// Delegates store mutations to `applySharedStoreUpdate` (same logic
    /// as the active-session path), then records Live Activity events
    /// directly (cross-session events bypass the coalescer).
    private func handleCrossSessionMessage(
        _ message: ServerMessage,
        sessionId: String,
        deferSharedStoreToLiveSession: Bool = false
    ) {
        if deferSharedStoreToLiveSession,
           shouldDeferSharedStoreUpdateToLiveSessionConsumer(message) {
            handleInactiveSessionUI(message, sessionId: sessionId)
            recordCrossSessionLiveActivityEvent(message, sessionId: sessionId)
            return
        }

        let result = applySharedStoreUpdate(for: message, sessionId: sessionId)
        handleInactiveSessionUI(message, sessionId: sessionId)

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
            syncLiveActivityState()
        default:
            break
        }
    }

    private func shouldDeferSharedStoreUpdateToLiveSessionConsumer(_ message: ServerMessage) -> Bool {
        switch message {
        case .agentStart,
             .agentEnd,
             .state,
             .sessionSummary,
             .sessionEnded,
             .sessionDeleted,
             .stopRequested,
             .stopConfirmed,
             .stopFailed:
            return true
        default:
            return false
        }
    }

    // MARK: - Session Streaming

    private func clearFocusedSessionStreamEndpoint() {
        focusedSessionStreamEndpointKind = "none"
        focusedSessionStreamSessionId = nil
        focusedSessionStreamWorkspaceId = nil
        focusedSessionStreamURL = nil
        wsClient?.setStreamURL(nil)
    }

    private func hasActiveFocusedSessionStreamTransport() -> Bool {
        if streamConsumptionTask != nil { return true }
        switch wsClient?.status {
        case .connected, .connecting, .reconnecting:
            return true
        case .disconnected, nil:
            return false
        }
    }

    private func focusedSessionStreamTargetMatches(sessionId: String, workspaceId: String) -> Bool {
        focusedSessionStreamEndpointKind == "split_session"
            && focusedSessionStreamSessionId == sessionId
            && focusedSessionStreamWorkspaceId == workspaceId
    }

    /// Open the URL-bound focused session stream.
    func streamSession(_ sessionId: String, workspaceId: String) async -> AsyncStream<SessionStreamEvent>? {
        await refreshStreamCapabilitiesIfNeeded()
        guard hasRequiredSplitStreamCapabilities else {
            recordSessionStreamUnavailable(reason: streamCapabilityUnavailableReason())
            return nil
        }
        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, workspaceId: workspaceId)
        return await sessionStreamCoordinator.streamSession(
            connection: self,
            sessionId: sessionId,
            workspaceId: workspaceId
        )
    }

    private func prepareFocusedSessionStreamEndpoint(sessionId: String, workspaceId: String) {
        if focusedSessionStreamTargetMatches(sessionId: sessionId, workspaceId: workspaceId) {
            // Keep a live/reconnecting transport for the same bound endpoint,
            // but still recompute the URL below. Endpoint selection may have
            // changed after Wi-Fi/cellular handoff while the session target did not.
        } else if focusedSessionStreamEndpointKind == "split_session",
                  hasActiveFocusedSessionStreamTransport() {
            disconnectStream()
        } else {
            clearFocusedSessionStreamEndpoint()
        }

        guard hasRequiredSplitStreamCapabilities, let selection = endpointSelection else {
            recordSessionStreamUnavailable(reason: hasRequiredSplitStreamCapabilities ? "missingEndpointSelection" : streamCapabilityUnavailableReason())
            return
        }
        guard let sessionStreamURL = makeFocusedSessionStreamURL(
            selection: selection,
            sessionId: sessionId,
            workspaceId: workspaceId
        ) else {
            recordSessionStreamUnavailable(reason: "invalidStreamURL")
            return
        }

        let previousURL = focusedSessionStreamURL
        focusedSessionStreamEndpointKind = "split_session"
        focusedSessionStreamSessionId = sessionId
        focusedSessionStreamWorkspaceId = workspaceId
        focusedSessionStreamURL = sessionStreamURL
        wsClient?.setPreferredEndpoint(selection)
        wsClient?.setStreamURL(sessionStreamURL, sessionId: sessionId, workspaceId: workspaceId)

        if let previousURL, previousURL != sessionStreamURL {
            var metadata: [String: String] = [
                "transport": selection.transportPath.rawValue,
                "urlChanged": "true",
            ]
            metadata.merge(ClientLog.endpointMetadata(previousURL, prefix: "previousStream")) { current, _ in current }
            metadata.merge(ClientLog.endpointMetadata(sessionStreamURL, prefix: "nextStream")) { current, _ in current }
            ClientLog.info("Network", "Focused stream endpoint changed", metadata: metadata)
        }
    }

    private func makeFocusedSessionStreamURL(
        selection: EndpointSelection,
        sessionId: String,
        workspaceId: String
    ) -> URL? {
        guard var components = URLComponents(url: selection.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = selection.baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/workspaces/\(workspaceId)/sessions/\(sessionId)/stream"
        return components.url
    }

    private func refreshPreparedFocusedSessionEndpointAfterEndpointChange() {
        guard focusedSessionStreamEndpointKind == "split_session",
              let sessionId = focusedSessionStreamSessionId,
              let workspaceId = focusedSessionStreamWorkspaceId else {
            return
        }

        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, workspaceId: workspaceId)
    }

    private func streamCapabilityUnavailableReason() -> String {
        if streamCapabilitiesRefreshFailed && !streamCapabilitiesLoaded {
            return "capabilityRefreshFailed"
        }
        if !streamCapabilitiesLoaded {
            return "capabilityNotLoaded"
        }
        if !missingRequiredSplitStreamCapabilities.isEmpty {
            return "missingCapability:\(missingRequiredSplitStreamCapabilities.joined(separator: ","))"
        }
        return "unknown"
    }

    private func recordSessionStreamUnavailable(reason: String) {
        var metadata: [String: String] = [
            "reason": reason,
            "capabilityStatus": requiredSplitStreamCapabilitiesStatusForDiagnostics,
            "transport": transportPath.rawValue,
            "hasWebSocketClient": wsClient == nil ? "false" : "true",
        ]
        metadata.merge(ClientLog.endpointMetadata(endpointSelection?.baseURL, prefix: "api")) { current, _ in current }
        metadata.merge(ClientLog.endpointMetadata(focusedSessionStreamURL, prefix: "stream")) { current, _ in current }
        ClientLog.warning("Network", "Session stream unavailable", metadata: metadata)
    }

    func cancelDeferredQueueSync() {
        deferredQueueSyncTask?.cancel()
        deferredQueueSyncTask = nil
    }

    func waitForFocusedFullSubscription(
        sessionId: String,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> Bool {
        let startedAt = ContinuousClock.now

        while !sessionStreamCoordinator.hasFullSubscription(sessionId: sessionId) {
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

    /// Close local continuations for a specific session stream.
    func closeSessionStreamContinuations(_ sessionId: String) {
        sessionEventContinuations[sessionId]?.finish()
        sessionEventContinuations.removeValue(forKey: sessionId)
    }

    private func cancelDeferredPlaybackDisconnect(for sessionId: String) {
        if let task = deferredPlaybackDisconnectTasks.removeValue(forKey: sessionId) {
            task.cancel()
        }
    }

    func deferDisconnectSessionUntilLiveAudioStreamFinishes(_ sessionId: String) {
        cancelDeferredPlaybackDisconnect(for: sessionId)
        deferredPlaybackDisconnectTasks[sessionId] = Task { @MainActor [weak self] in
            while let self,
                  !Task.isCancelled,
                  self.audioPlayer.activeLiveTransportSessionID == sessionId {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled else { return }
            self.deferredPlaybackDisconnectTasks.removeValue(forKey: sessionId)
            self.disconnectSession(sessionId: sessionId)
        }
    }

    private func disconnectSessionResources(for sessionId: String) {
        closeSessionStreamContinuations(sessionId)
        messageQueueStore.clear(sessionId: sessionId)
        sessionUsageMetricSnapshots.removeValue(forKey: sessionId)
        sessionUsageMetricLastEmittedAt.removeValue(forKey: sessionId)
        screenAwakeController.clearSessionActivity(sessionId: sessionId)
    }

    /// Resolve the workspace needed to bind a session stream during deep-link or notification re-entry.
    /// Permission-gate app events can arrive before the session summary is cached, so pending UI state is a valid source.
    func sessionReentryWorkspaceId(for sessionId: String, workspaceIdHint: String? = nil) -> String? {
        if let workspaceId = normalizedWorkspaceId(sessionStore.session(id: sessionId)?.workspaceId) {
            return workspaceId
        }
        if let workspaceId = normalizedWorkspaceId(workspaceIdHint) {
            return workspaceId
        }
        if let workspaceId = normalizedWorkspaceId(askRequestStore.pending(for: sessionId)?.workspaceId) {
            return workspaceId
        }
        return pendingExtensionDialogQueues[sessionId]?
            .compactMap { normalizedWorkspaceId($0.workspaceId) }
            .first
    }

    private func normalizedWorkspaceId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Focus the connection on a session for command routing (prompt/stop/etc).
    ///
    /// Unlike `disconnectSession`, this does NOT close the previous session stream
    /// continuations or tear down streams. The previous session's ChatSessionManager keeps
    /// receiving events via its per-session continuation and coalescer/reducer.
    func focusSession(_ sessionId: String, workspaceIdHint: String? = nil) {
        cancelDeferredPlaybackDisconnect(for: sessionId)
        let previousSessionId = focusedSessionId
        if previousSessionId != sessionId {
            // Stop the old focused-session watchdog before switching command
            // routing. Pending AskCard state already lives in AskRequestStore.
            silenceWatchdog.stop()
        }

        let workspaceId = sessionReentryWorkspaceId(for: sessionId, workspaceIdHint: workspaceIdHint)
        focusedSessionStore.focus(sessionId: sessionId, workspaceId: workspaceId)
        // Reset per-connection chat state for the new focused session.
        // Sheet-backed extension dialogs are derived from pendingExtensionDialogQueues.
        chatState.resetSessionState()

        syncActiveAskWorkspaceSummary()
    }

    /// Re-establish command routing before a session view re-enters foreground interaction.
    ///
    /// If we already know the split-stream endpoint for an active session, eagerly
    /// reopen the transport so toolbar actions like Stop work immediately while the
    /// chat view's async connect loop is still spinning up its per-session timeline.
    func prepareForSessionReentry(_ sessionId: String, workspaceIdHint: String? = nil) {
        _onPrepareForSessionReentryForTesting?(sessionId)
        focusSession(sessionId, workspaceIdHint: workspaceIdHint)

        let session = sessionStore.session(id: sessionId)
        guard hasRequiredSplitStreamCapabilities,
              session?.status != .stopped,
              let workspaceId = sessionReentryWorkspaceId(for: sessionId, workspaceIdHint: workspaceIdHint) else {
            return
        }

        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, workspaceId: workspaceId)
        connectStream()
    }

    func disconnectSession(sessionId: String) {
        cancelDeferredPlaybackDisconnect(for: sessionId)
        let isFocusedSession = focusedSessionId == sessionId

        if isFocusedSession {
            cancelDeferredQueueSync()
            commands.failAllTurnSends(error: WebSocketError.notConnected)
            commands.failAllCommands(error: WebSocketError.notConnected)
        }

        disconnectSessionResources(for: sessionId)

        guard isFocusedSession else { return }

        // Pending AskCard state already lives in AskRequestStore and will be
        // visible again when focus returns to this session.

        focusedSessionStore.clear()
        sessionStreamCoordinator.noteStreamDisconnected()
        silenceWatchdog.stop()
        chatState.resetSessionState()

        disconnectStream()

        // Don't end Live Activity on disconnect — it should persist
        // on Lock Screen until the session actually ends.
    }

    /// Disconnect from the current session stream.
    func disconnectSession() {
        guard let focusedSessionId else {
            cancelDeferredQueueSync()
            commands.failAllTurnSends(error: WebSocketError.notConnected)
            commands.failAllCommands(error: WebSocketError.notConnected)
            return
        }
        disconnectSession(sessionId: focusedSessionId)
    }

    // MARK: - Actions (delegated to MessageSender)

    func sendPrompt(_ text: String, attachments: [ChatAttachmentRef]? = nil, clientTurnId: String? = nil, sessionIdOverride: String? = nil, onAckStage: ((TurnAckStage) -> Void)? = nil) async throws {
        try await sender.sendPrompt(text, attachments: attachments, clientTurnId: clientTurnId, sessionIdOverride: sessionIdOverride, onAckStage: onAckStage)
    }

    func sendSteer(_ text: String, attachments: [ChatAttachmentRef]? = nil, clientTurnId: String? = nil, sessionIdOverride: String? = nil, onAckStage: ((TurnAckStage) -> Void)? = nil) async throws {
        try await sender.sendSteer(text, attachments: attachments, clientTurnId: clientTurnId, sessionIdOverride: sessionIdOverride, onAckStage: onAckStage)
    }

    func sendFollowUp(_ text: String, attachments: [ChatAttachmentRef]? = nil, clientTurnId: String? = nil, sessionIdOverride: String? = nil, onAckStage: ((TurnAckStage) -> Void)? = nil) async throws {
        try await sender.sendFollowUp(text, attachments: attachments, clientTurnId: clientTurnId, sessionIdOverride: sessionIdOverride, onAckStage: onAckStage)
    }

    func sendStop(sessionIdOverride: String? = nil) async throws { try await sender.sendStop(sessionIdOverride: sessionIdOverride) }
    func sendStopSession(sessionIdOverride: String? = nil) async throws { try await sender.sendStopSession(sessionIdOverride: sessionIdOverride) }

    func send(_ message: ClientMessage) async throws { try await sender.send(message) }

    func requestState() async throws { try await sender.requestState() }

    func requestMessageQueue(timeout: Duration = MessageSender.commandRequestTimeoutDefault, sessionIdOverride: String? = nil) async throws {
        try await sender.requestMessageQueue(timeout: timeout, sessionIdOverride: sessionIdOverride)
    }

    func setMessageQueue(baseVersion: Int, steering: [MessageQueueDraftItem], followUp: [MessageQueueDraftItem], sessionIdOverride: String? = nil) async throws {
        try await sender.setMessageQueue(baseVersion: baseVersion, steering: steering, followUp: followUp, sessionIdOverride: sessionIdOverride)
    }

    func sendCommandAwaitingResult(
        command: String,
        timeout: Duration = MessageSender.commandRequestTimeoutDefault,
        message: (String) -> ClientMessage
    ) async throws -> JSONValue? {
        try await sender.sendCommandAwaitingResult(command: command, timeout: timeout, message: message)
    }

    func getForkMessages() async throws -> [ForkMessage] { try await sender.getForkMessages() }

    func respondToExtensionUI(
        id: String,
        sessionId: String,
        payload: ExtensionUIResponsePayload
    ) async throws {
        let workspaceId = sessionReentryWorkspaceId(for: sessionId)

        let focusedStreamReady = isFocusedSession(sessionId) && wsClient?.status == .connected
        if !focusedStreamReady, let workspaceId, apiClient != nil {
            try await respondToExtensionUI(
                workspaceId: workspaceId,
                sessionId: sessionId,
                id: id,
                payload: payload
            )
            return
        }

        try await sender.dispatchSend(
            .extensionUIResponse(
                id: id,
                value: payload.value,
                confirmed: payload.confirmed,
                cancelled: payload.cancelled
            ),
            sessionIdOverride: sessionId
        )
        clearExtensionDialog(id: id)
        clearAskRequest(id: id)
    }

    func _setActiveSessionIdForTesting(_ sessionId: String?) {
        if let sessionId {
            focusedSessionStore.focus(sessionId: sessionId, workspaceId: nil)
        } else {
            focusedSessionStore.clear()
        }
    }

    func telemetryErrorKind(from error: Error) -> String {
        MessageSender.telemetryErrorKind(from: error)
    }

    func setServerDictationAvailableFromCapabilities(_ available: Bool) {
        serverDictationAvailable = available
    }

    func makeDictationStreamClient() -> DictationStreamClient? {
        guard let selection = endpointSelection,
              let credentials else { return nil }
        return DictationStreamClient(
            baseURL: selection.baseURL,
            token: credentials.token,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint
        )
    }

    func startAppEventStreamIfAvailable() {
        guard appEventStreamAvailable,
              let selection = endpointSelection,
              let credentials,
              let streamURL = makeAppEventStreamURL(selection: selection) else {
            return
        }

        #if DEBUG
        if let startAppEventStreamForTesting = _startAppEventStreamForTesting {
            startAppEventStreamForTesting(streamURL)
            return
        }
        #endif

        let client = AppEventStreamClient(
            url: streamURL,
            token: credentials.token,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint
        )
        appEventStreamCoordinator.start(
            connection: self,
            client: client,
            streamURL: streamURL
        )
    }

    func disconnectAppEventStream() {
        appEventStreamCoordinator.disconnect()
    }

    private func makeAppEventStreamURL(selection: EndpointSelection) -> URL? {
        guard var components = URLComponents(url: selection.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = selection.baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/app/events/stream"
        return components.url
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
        workspaceStore.setActiveServer(id)
    }

    // periphery:ignore - used by VoiceInputManagerTests via @testable import
    /// Override server dictation availability for testing.
    func setServerDictationAvailableForTesting(_ available: Bool) {
        serverDictationAvailable = available
    }

    // periphery:ignore - used by stream coordinator tests via @testable import
    func setFocusedSessionStreamEndpointKindForTesting(_ kind: String) {
        focusedSessionStreamEndpointKind = kind
    }

    func setAPIClientForTesting(_ client: APIClient) {
        apiClient = client
    }

    func prepareFocusedSessionStreamEndpointForTesting(sessionId: String, workspaceId: String) {
        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, workspaceId: workspaceId)
    }

    var focusedSessionStreamURLForTesting: URL? {
        focusedSessionStreamURL
    }

    func setSplitStreamCapabilitiesForTesting(
        sessionStream: Bool = true,
        dictationStream: Bool = false,
        appEventStream: Bool = false
    ) {
        splitSessionStreamAvailable = sessionStream
        dictationStreamAvailable = dictationStream
        appEventStreamAvailable = appEventStream
        var missing: [String] = []
        if !sessionStream { missing.append("sessionStream") }
        missingRequiredSplitStreamCapabilities = missing
        streamCapabilitiesLoaded = true
    }
#endif
}
