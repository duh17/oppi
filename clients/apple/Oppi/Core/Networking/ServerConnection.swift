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
    var sessionAudioStreamAvailable = false
    private(set) var missingRequiredSplitStreamCapabilities: [String] = []
    private var streamCapabilitiesLoaded = false
    private var streamCapabilitiesRefreshFailed = false
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
        serverDictationAvailable || dictationStreamAvailable || sessionAudioStreamAvailable
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
        sessionAudioStreamAvailable = false
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
    let permissionStore = PermissionStore()
    let askRequestStore = AskRequestStore()
    let workspaceStore = WorkspaceStore()
    let gitStatusStore = GitStatusStore()
    let fileIndexStore = FileIndexStore()
    let messageQueueStore = MessageQueueStore()
    let activityStore = SessionActivityStore()

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

    /// Test seam: observe refresh breadcrumbs emitted by list refresh paths.
    var _onRefreshBreadcrumbForTesting: ((_ message: String, _ metadata: [String: String], _ level: ClientLogLevel) -> Void)?

    // periphery:ignore - test seam used by ServerConnectionStreamTests via @testable import
    /// Test seam: replace WebSocket opening with a deterministic stream.
    var _connectStreamForTesting: (() -> AsyncStream<StreamFrameEvent>)?

    /// User-wide attention stream for local notifications while the app is launched.
    private var attentionWsClient: WebSocketClient?
    private var attentionStreamTask: Task<Void, Never>?
    private var attentionStreamGeneration: UInt64 = 0

    /// Test seam: override the cache actor used by list refresh paths.
    var _cacheForTesting: TimelineCache?

    /// Test seam: observe view-driven session re-entry preparation.
    var _onPrepareForSessionReentryForTesting: ((String) -> Void)?

    // periphery:ignore - used by ServerConnectionPermissionTests via @testable import
    /// Test seam: override REST permission responses without opening a real HTTP server.
    var _respondToPermissionRESTForTesting: ((String, PermissionAction, PermissionScope, Int?) async throws -> Void)?

    // Extension UI
    var activeExtensionDialog: ExtensionUIRequest?
    /// Pending generic extension dialogs for sessions the user is not currently viewing.
    /// Restored when focus returns, matching ask request behavior.
    var pendingExtensionDialogs: [String: ExtensionUIRequest] = [:]
    var extensionToast: String?
    var extensionSurfaceBySession: [String: ExtensionSurfaceState] = [:]

    // Ask extension
    var activeAskRequest: AskRequest?
    /// Pending ask requests for sessions the user isn't currently viewing.
    /// Restored to activeAskRequest when the user enters the session.
    var pendingAskRequests: [String: AskRequest] = [:]

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
        self.splitSessionStreamAvailable = false
        self.dictationStreamAvailable = false
        self.sessionAudioStreamAvailable = false
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
        self.attentionWsClient?.disconnect()
        self.attentionWsClient = WebSocketClient(
            credentials: credentials,
            preferredEndpoint: selection,
            diagnosticRole: "user_events"
        )
        self.attentionWsClient?.setStreamURL(makeUserEventsStreamURL(selection: selection))
        sender.wsClient = self.wsClient
        sender.focusedSessionProvider = { [weak self] in
            self?.focusedSessionStore.focused
        }
        startAttentionStreamIfNeeded()

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
        attentionWsClient?.setPreferredEndpoint(selection)
        attentionWsClient?.setStreamURL(makeUserEventsStreamURL(selection: selection))

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
            restartAttentionStreamIfNeeded()
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
        ClientLog.warning("Network", "Force stream reconnect after path change", metadata: pathChangeMetadata)

        // Tear down old WS + consumption task. Per-session continuations
        // are preserved; the active endpoint will be reopened below.
        streamConsumptionTask?.cancel()
        streamConsumptionTask = nil
        wsClient.disconnect()

        refreshPreparedFocusedSessionEndpointAfterEndpointChange()

        // Reconnect with the updated (Tailscale) endpoint.
        connectStream()
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

    private func makeUserEventsStreamURL(selection: EndpointSelection) -> URL? {
        guard var components = URLComponents(url: selection.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = selection.baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/user/events/stream"
        return components.url
    }

    private func startAttentionStreamIfNeeded() {
        guard ReleaseFeatures.localAttentionNotificationsEnabled,
              let attentionWsClient else {
            return
        }
        if let task = attentionStreamTask, !task.isCancelled,
           attentionWsClient.status != .disconnected {
            return
        }

        let stream = attentionWsClient.connect()
        attentionStreamGeneration &+= 1
        let generation = attentionStreamGeneration
        attentionStreamTask = Task { [weak self] in
            for await frameEvent in stream {
                guard let self, !Task.isCancelled else { break }
                self.handleAttentionStreamMessage(frameEvent)
            }
            await MainActor.run { [weak self] in
                guard let self, self.attentionStreamGeneration == generation else { return }
                self.attentionStreamTask = nil
            }
        }
    }

    private func restartAttentionStreamIfNeeded() {
        guard ReleaseFeatures.localAttentionNotificationsEnabled else { return }
        attentionStreamTask?.cancel()
        attentionStreamTask = nil
        attentionWsClient?.disconnect()
        startAttentionStreamIfNeeded()
    }

    private func handleAttentionStreamMessage(_ frameEvent: StreamFrameEvent) {
        if case .streamConnected(_, let available) = frameEvent.message {
            serverDictationAvailable = available
            return
        }

        guard let sessionId = frameEvent.sessionId,
              !isFocusedSession(sessionId) else {
            return
        }
        handleCrossSessionMessage(frameEvent.message, sessionId: sessionId)
    }

    func refreshStreamCapabilitiesIfNeeded() async {
        guard !streamCapabilitiesLoaded else { return }
        await refreshStreamCapabilities()
    }

    func refreshStreamCapabilities() async {
        guard let apiClient else { return }
        let hadLoadedCapabilities = streamCapabilitiesLoaded
        do {
            let info = try await apiClient.serverInfo()
            let capabilities = info.capabilities
            splitSessionStreamAvailable = capabilities?.sessionStream?.version ?? 0 >= 1
            dictationStreamAvailable = capabilities?.dictationStream?.version ?? 0 >= 1
            sessionAudioStreamAvailable = capabilities?.sessionAudioStream?.version ?? 0 >= 1
            missingRequiredSplitStreamCapabilities = ServerInfo.Capabilities
                .missingRequiredSplitStreamCapabilities(in: capabilities)
            streamCapabilitiesRefreshFailed = false
            if dictationStreamAvailable || sessionAudioStreamAvailable {
                setServerDictationAvailableFromCapabilities(true)
            }
            streamCapabilitiesLoaded = true
        } catch {
            // Do not let a transient handoff failure permanently poison stream
            // capability state. If we already had a good capability snapshot,
            // keep using it; otherwise leave the state unloaded so the next
            // session entry retries /server/info instead of returning nil forever.
            streamCapabilitiesRefreshFailed = true
            if !hadLoadedCapabilities {
                splitSessionStreamAvailable = false
                dictationStreamAvailable = false
                sessionAudioStreamAvailable = false
                missingRequiredSplitStreamCapabilities = []
                streamCapabilitiesLoaded = false
            }

            var metadata = ClientLog.networkErrorMetadata(error)
            metadata["hadLoadedCapabilities"] = hadLoadedCapabilities ? "true" : "false"
            metadata["capabilityStatus"] = requiredSplitStreamCapabilitiesStatusForDiagnostics
            metadata["transport"] = transportPath.rawValue
            let apiBaseURL = await apiClient.baseURL
            metadata.merge(ClientLog.endpointMetadata(apiBaseURL, prefix: "api")) { current, _ in current }
            ClientLog.warning("Network", "Stream capability refresh failed", metadata: metadata)
        }
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

        // Also process events from non-focused sessions. If a
        // non-focused full session has its own live consumer, let that
        // per-session pipeline own destructive permission-store updates so
        // its reducer still receives resolution metadata.
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
            syncLiveActivityPermissions()
        default:
            break
        }
    }

    private func shouldDeferSharedStoreUpdateToLiveSessionConsumer(_ message: ServerMessage) -> Bool {
        switch message {
        case .permissionRequest,
             .permissionExpired,
             .permissionCancelled,
             .permissionResolved,
             .permissionAutoReviewed,
             .agentStart,
             .agentEnd,
             .toolStart,
             .toolUpdate,
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
            ClientLog.warning("Network", "Focused stream endpoint changed", metadata: metadata)
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

    /// Focus the connection on a session for command routing (prompt/stop/etc).
    ///
    /// Unlike `disconnectSession`, this does NOT close the previous session stream
    /// continuations or tear down streams. The previous session's ChatSessionManager keeps
    /// receiving events via its per-session continuation and coalescer/reducer.
    func focusSession(_ sessionId: String) {
        cancelDeferredPlaybackDisconnect(for: sessionId)
        let previousSessionId = focusedSessionId
        if previousSessionId != sessionId {
            // Hand off session-scoped control-plane state before switching the
            // focused command target. Without this, an ask from the previous
            // session can be lost and its watchdog can keep running against
            // the newly focused session.
            stashActiveAskIfNeeded()
            stashActiveExtensionDialogIfNeeded()
            silenceWatchdog.stop()
        }

        let workspaceId = sessionStore.sessions.first(where: { $0.id == sessionId })?.workspaceId
        focusedSessionStore.focus(sessionId: sessionId, workspaceId: workspaceId)
        // Reset per-connection UI state for the new focused session
        activeExtensionDialog = nil
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
        chatState.resetSessionState()

        // Restore pending user-blocking UI for this session.
        restorePendingAskRequestIfNeeded(for: sessionId)
        restorePendingExtensionDialogIfNeeded(for: sessionId)
    }

    /// Re-establish command routing before a session view re-enters foreground interaction.
    ///
    /// If we already know the split-stream endpoint for an active session, eagerly
    /// reopen the transport so toolbar actions like Stop work immediately while the
    /// chat view's async connect loop is still spinning up its per-session timeline.
    func prepareForSessionReentry(_ sessionId: String) {
        _onPrepareForSessionReentryForTesting?(sessionId)
        focusSession(sessionId)

        guard hasRequiredSplitStreamCapabilities,
              let session = sessionStore.sessions.first(where: { $0.id == sessionId }),
              session.status != .stopped,
              let workspaceId = session.workspaceId,
              !workspaceId.isEmpty else {
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

        // Stash pending user-blocking UI before clearing focus so it can
        // be restored on focusSession(). Without this, navigating away loses
        // in-flight client/server UI state permanently.
        stashActiveAskIfNeeded()
        stashActiveExtensionDialogIfNeeded()

        focusedSessionStore.clear()
        sessionStreamCoordinator.noteStreamDisconnected()
        Task {
            await SentryService.shared.setSessionContext(sessionId: nil, workspaceId: nil)
        }
        // Clear stale extension dialog — it's tied to the active session stream
        activeExtensionDialog = nil
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
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

    /// Respond to a permission request (has store side effects — stays on ServerConnection).
    func respondToPermission(id: String, action: PermissionAction, scope: PermissionScope = .once, expiresInMs: Int? = nil) async throws {
        let tool = permissionStore.pending.first(where: { $0.id == id })?.tool ?? ""
        let normalizedChoice = PermissionApprovalPolicy.normalizedChoice(
            tool: tool,
            choice: PermissionResponseChoice(action: action, scope: scope, expiresInMs: expiresInMs)
        )

        do {
            try await sender.dispatchSend(
                .permissionResponse(
                    id: id,
                    action: normalizedChoice.action,
                    scope: normalizedChoice.scope == .once ? nil : normalizedChoice.scope,
                    expiresInMs: normalizedChoice.expiresInMs,
                    requestId: nil
                )
            )
        } catch {
            if let respondToPermissionREST = _respondToPermissionRESTForTesting {
                try await respondToPermissionREST(
                    id,
                    normalizedChoice.action,
                    normalizedChoice.scope,
                    normalizedChoice.expiresInMs
                )
            } else if let apiClient {
                try await apiClient.respondToPermission(
                    id: id,
                    action: normalizedChoice.action,
                    scope: normalizedChoice.scope,
                    expiresInMs: normalizedChoice.expiresInMs
                )
            } else {
                throw error
            }
        }

        let outcome: PermissionOutcome = normalizedChoice.action == .allow ? .allowed : .denied
        if let request = permissionStore.take(id: id) {
            if let workspaceId = attentionWorkspaceId(
                explicitWorkspaceId: request.workspaceId,
                sessionId: request.sessionId
            ) {
                syncWorkspaceSummary(workspaceId: workspaceId)
            }
            if isFocusedSession(request.sessionId) {
                onPermissionResolved?(id, outcome, request.tool, request.displaySummary)
            }
        }
        if ReleaseFeatures.localAttentionNotificationsEnabled {
            PermissionNotificationService.shared.cancelNotification(permissionId: id)
        }
        syncLiveActivityPermissions()
    }

    /// Respond to an extension UI dialog (has UI side effects — stays on ServerConnection).
    func respondToExtensionUI(
        id: String,
        sessionId: String,
        value: String? = nil,
        confirmed: Bool? = nil,
        cancelled: Bool? = nil
    ) async throws {
        try await sender.dispatchSend(
            .extensionUIResponse(id: id, value: value, confirmed: confirmed, cancelled: cancelled),
            sessionIdOverride: sessionId
        )
        activeExtensionDialog = nil
        pendingExtensionDialogs.removeValue(forKey: sessionId)
        clearAskState(for: sessionId)
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
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

    func makeLegacyDictationStreamClient(workspaceId: String, sessionId: String) -> DictationStreamClient? {
        guard sessionAudioStreamAvailable,
              let selection = endpointSelection,
              let credentials else { return nil }
        return DictationStreamClient(
            baseURL: selection.baseURL,
            token: credentials.token,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            legacyWorkspaceId: workspaceId,
            legacySessionId: sessionId
        )
    }

    func makeLegacyDictationStreamClientForFocusedSession() -> DictationStreamClient? {
        guard let context = focusedSessionStore.focused,
              let workspaceId = context.workspaceId else { return nil }
        return makeLegacyDictationStreamClient(
            workspaceId: workspaceId,
            sessionId: context.sessionId
        )
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
        dictationStream: Bool? = nil,
        sessionAudioStream: Bool = false
    ) {
        splitSessionStreamAvailable = sessionStream
        dictationStreamAvailable = dictationStream ?? sessionAudioStream
        sessionAudioStreamAvailable = sessionAudioStream
        var missing: [String] = []
        if !sessionStream { missing.append("sessionStream") }
        missingRequiredSplitStreamCapabilities = missing
        streamCapabilitiesLoaded = true
    }
#endif
}
