import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Connection")

typealias ServerConnectionAPIClientFactory = @MainActor (
    OppiClientEnvironment,
    APIClientAvailabilityObserver?
) -> APIClient
typealias ServerConnectionInfoBootstrap = @MainActor (
    APIClient,
    APIClient.BootstrapDeadline
) async throws -> ServerInfo
typealias ServerConnectionBootstrapDeadlineFactory = @Sendable () -> APIClient.BootstrapDeadline
typealias ServerConnectionDeviceCredentialObserver = @MainActor (DeviceAuthRefreshResult) -> Void

enum ServerListRefreshOrigin: Equatable {
    case external
    case appEventReconciliation
}

/// Top-level connection coordinator.
///
/// Owns the APIClient and WebSocketClient and shared stores.
/// Timeline pipeline (coalescer/reducer/correlator) is per-session,
/// owned by ChatSessionManager.
@MainActor @Observable
final class ServerConnection {
    // Public state
    private(set) var credentials: ServerCredentials?
    /// `GET /server/info` version from the last successful bootstrap or capability refresh.
    private(set) var connectedServerVersion: String?
    /// Pending pairing approvals for this server (`GET /auth/pairing-approvals` + app events).
    let pairingApprovals = PairingApprovalList()
    /// `serverMetrics.enabled` from `GET /server/metrics/settings`, read once per
    /// connection and updated by the toggle. Nil until known: the host pill hides
    /// Server Metrics for nil and false alike. Filled by `ConnectionCoordinator`.
    var serverMetricsEnabled: Bool?
    @ObservationIgnored var isLoadingServerMetricsEnabled = false

    // Networking
    private(set) var apiClient: APIClient?
    private(set) var iconAssetCache: IconAssetCache?
    private(set) var wsClient: WebSocketClient?
    private var httpAuthSession: DeviceAuthSession?
    private var deviceKeyProvider = DeviceKeyProvider.shared
    /// Route selection: candidates, LAN promotion and demotion, Tailnet
    /// rebuilds, transport generations, and route recovery.
    @ObservationIgnored private(set) lazy var route = ServerRouteController(host: self)

    /// Live dictation socket handed out by `makeDictationStreamClient`. Promotion
    /// is deferred while it is open (rather than rebinding it mid-recording), so
    /// a recording never straddles two routes.
    private weak var activeDictationClient: DictationStreamClient?

    /// Work a route rebuild must never interrupt: a starting/busy/stopping
    /// session, a turn send that has not been acknowledged yet (the session is
    /// not `.busy` until `agentStart`), or a live dictation recording.
    var hasActiveWork: Bool {
        sessionStore.sessions.contains { $0.status == .starting || $0.status.isRunning }
            || !commands.pendingTurnSendsByRequestId.isEmpty
            || (activeDictationClient?.status ?? .disconnected) != .disconnected
    }

    private(set) var appEventStreamTransportState: ServerHealth.TransportState = .disconnected
    /// Identity of the current connected app-event window. Equality only.
    private(set) var appEventStreamConnectedAt: Date?
    /// REST list repair for the current app-event window (owner slot, follow-up budget).
    var appEventListRepair = AppEventListRepair()
    private(set) var missingRequiredSplitStreamCapabilities: [String] = []
    private var streamCapabilitiesLoaded = false
    private var streamCapabilitiesRefreshFailed = false
    private var streamCapabilitiesRefreshTask: Task<Void, Never>?
    private var streamCapabilitiesGeneration: UInt64 = 0
    /// The one `/server/info` read scheduled after a load found a voice backend still
    /// `checking` or `unreachable` (`scheduleVoiceBackendFollowUpIfNeeded`).
    private var voiceBackendFollowUpTask: Task<Void, Never>?
    /// The focused-session stream binding: endpoint, parked frames, external-open
    /// claim, recovery presentation owner, deferred playback disconnects.
    let focusedStreamBinder = FocusedSessionStreamBinder()
    private(set) var transportPath: ConnectionTransportPath = .paired

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
        dictationStreamUnsupportedByEndpoint = true
        missingRequiredSplitStreamCapabilities = ServerInfo.Capabilities.requiredSplitStreamCapabilityNames
        streamCapabilitiesRefreshFailed = false
        clearFocusedSessionStreamEndpoint()
        if let selection = endpointSelection {
            wsClient?.setPreferredEndpoint(selection)
        }
        wsClient?.setStreamURL(nil)
    }

    func focusedSessionStreamEndpointIsUnsupported() -> Bool {
        focusedStreamBinder.isBound
            && isUnsupportedSplitStreamStatus(wsClient?.lastHTTPStatusCode)
    }

    private(set) var endpointSelection: EndpointSelection?

    // periphery:ignore - used by ServerConnectionTests via @testable import
    /// Derived focused-session stream state. Server badges should use `serverHealth(forServer:)`.
    var isConnected: Bool {
        wsClient?.status == .connected
    }

    func serverHealth(forServer serverId: String? = nil) -> ServerHealth {
        let resolvedServerId = serverId ?? currentServerId ?? workspaceStore.activeServerId ?? ""
        let workspaceCatalog = workspaceStore.workspacesByServer[resolvedServerId] ?? []
        return ServerHealth.derive(
            freshnessState: workspaceStore.freshnessState(forServer: resolvedServerId),
            freshnessLabel: workspaceStore.freshnessLabel(forServer: resolvedServerId),
            transportStates: [
                focusedSessionTransportState(),
                appEventStreamTransportState,
            ],
            hasCachedCatalog: !workspaceCatalog.isEmpty
        )
    }

    private func focusedSessionTransportState() -> ServerHealth.TransportState {
        if route.isTransportDemoting {
            return .connecting
        }
        switch wsClient?.status {
        case .connected:
            return .connected
        case .connecting, .reconnecting:
            return .connecting
        case .disconnected, nil:
            return .disconnected
        }
    }

    /// Last capabilities snapshot from `/server/info`; nil until loaded and after a transport reset.
    /// The `*Available` flags below read it.
    private(set) var serverCapabilities: ServerInfo.Capabilities?
    /// Each voice feature's backend from the same snapshot; the AI sharing consent names
    /// where dictation and Live Voice audio goes from it.
    private(set) var voiceBackends: [ServerInfo.VoiceBackend]?
    /// Set when the dictation stream endpoint answered 404/405/426/501. Overrides the snapshot's
    /// dictation flag until the next capabilities load or transport reset.
    private var dictationStreamUnsupportedByEndpoint = false
    /// Server dictation can take a recording: the server's dictation backend answers
    /// (`capabilities.dictationStream`). The one source for dictation routing;
    /// `stream_connected.serverDictationAvailable` only says dictation is configured.
    var dictationStreamAvailable: Bool {
        !dictationStreamUnsupportedByEndpoint && serverCapabilities?.dictationStream?.version ?? 0 >= 1
    }
    var appEventStreamAvailable: Bool { serverCapabilities?.appEventStream?.version ?? 0 >= 1 }
    /// The server accepts durable-engine creates. With the experiment on, new sessions default durable.
    var durableSessionsAvailable: Bool { serverCapabilities?.durableSessions?.version ?? 0 >= 1 }
    /// The server replicates durable conversations on the focused socket (`capabilities.conversationStream`).
    var conversationStreamAvailable: Bool { serverCapabilities?.conversationStream?.version ?? 0 >= 1 }
    /// v2: `attach { mode: live }` streams the live tails of a session's subagents on its socket.
    var conversationStreamLiveTailsAvailable: Bool { serverCapabilities?.conversationStream?.version ?? 0 >= 2 }
    /// The server reads messages aloud (`capabilities.speech`, `POST /speech`).
    var speechAvailable: Bool { serverCapabilities?.speech?.version ?? 0 >= 1 }
    /// A Live Voice call can start (`capabilities.liveVoice`). A server that does not
    /// advertise it, such as one older than 0.53.0, cannot run a call.
    var liveVoiceAvailable: Bool { serverCapabilities?.liveVoice?.version ?? 0 >= 1 }
    /// Relay the server pushes through (`capabilities.pushNotifications`); nil when it does not.
    var pushRelay: URL? { serverCapabilities?.pushRelay }

    /// The server pushes and the user turned push on for it, so it skips this device's push
    /// only while this device holds a live stream.
    var pushNotificationsAvailable: Bool {
        guard pushRelay != nil, let currentServerId else { return false }
        return PushRegistration.isEnabled(serverId: currentServerId)
    }

    // Stores
    let sessionStore: SessionStore
    let askRequestStore = AskRequestStore()
    let workspaceStore = WorkspaceStore()
    let serverResourceStore = ServerResourceStore()
    let gitStatusStore = GitStatusStore(environment: .app)
    @ObservationIgnored private(set) lazy var fileIndexStore: FileIndexStore = {
        let store = FileIndexStore(
            environment: .app(serverId: { [weak self] in self?.currentServerId })
        )
        store.onSuggestionRankerInstalled = { [weak self] in
            self?.replayPendingFileSuggestionQuery()
        }
        return store
    }()
    let messageQueueStore = MessageQueueStore(telemetry: .appMetrics)

    /// Session content access for assistant/tool rows. It reads this connection's
    /// current API client and server id on demand; the connection keeps client
    /// installation, authentication, and lifecycle authority.
    @ObservationIgnored private(set) lazy var sessionContent = SessionContentAccess(
        apiClient: { [weak self] in self?.apiClient },
        serverId: { [weak self] in self?.currentServerId },
        // A failed read aloud may mean its backend went away: reload `capabilities.speech`
        // (single-flight with every other capability refresh).
        speechRequestFailed: { [weak self] in
            Task { await self?.refreshStreamCapabilities() }
        },
        sessionStore: sessionStore,
        workspaceStore: workspaceStore
    )

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

    /// Test seam: replace WebSocket opening with a deterministic stream.
    var _connectStreamForTesting: (() -> AsyncStream<StreamFrameEvent>)?

    /// Test seam: observe app-event stream start without opening a real socket.
    var _startAppEventStreamForTesting: ((URL) -> Void)?
    var _appEventWebSocketFactoryForTesting: ((URLRequest) -> AppEventWebSocketTransport)?

    /// Test seam: override the cache actor used by list refresh paths.
    var _cacheForTesting: TimelineCache?

    /// Test seam: observe view-driven session re-entry preparation.
    var _onPrepareForSessionReentryForTesting: ((String) -> Void)?

    /// Test seam: inspect bounded focus-arbitration telemetry.
    var _onFocusArbitrationForTesting: ((_ outcome: String, _ metadata: [String: String]) -> Void)?

    /// Test seam: shorten the bounded external-open claim window.
    var _externalSessionOpenClaimWindowForTesting: Duration?

    /// Test seam: shorten how long `streamSession` waits for the socket to report connected.
    var _connectedStreamWaitTimeoutForTesting: Duration?

    /// Test seam: shorten how long `setModel` waits for the session's `connected` bootstrap.
    var _sessionBootstrapWaitTimeoutForTesting: Duration?

    /// Test seam: shorten the wait before the voice backend follow-up read.
    var _voiceBackendFollowUpDelayForTesting: Duration?

    /// Test seam: replace compact sidebar Git summary HTTP fetches.
    var _getWorkspaceGitSummaryForTesting: ((String) async throws -> WorkspaceGitSummary)?
    /// Test seam: replace `GET /auth/pairing-approvals`.
    var _listPairingApprovalsForTesting: (() async throws -> [PendingPairingApproval])?

    /// Test seam: replace session dialog hydration HTTP fetches.
    var _getSessionDialogsForTesting: ((String) async throws -> APIClient.SessionDialogsResponse)?

    /// Test seam: replace generic `GET /sessions/:id` during external open.
    var _getSessionRecordForTesting: ((String) async throws -> Session)?

#if DEBUG
    var _focusedStreamReadinessPollForTesting: Duration?
    var _onFocusedStreamReadinessWaitForTesting: (() -> Void)?
#endif

    // Extension UI
    var activeExtensionDialog: ExtensionUIRequest? {
        get {
            // Read the queue before the focus guard. The window root observes this
            // from its `updateProperties()`, and a getter that returns early while
            // nothing is focused registers no dependency on the queue: the first
            // dialog to arrive then never invalidates the root, so its sheet never
            // presents and the extension waits for an answer that cannot be given.
            let queues = extensionDialogs.queues
            guard let focusedSessionId else { return nil }
            return queues[focusedSessionId]?.first
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
    let extensionDialogs = ExtensionDialogQueue()
    var extensionToast: String?
    /// Per-session extension `notify` chip. App-originated `extensionToast` stays a sheet.
    let extensionNotifyChipStore = ExtensionNotifyChipStore()
    /// Observed per session, not as one value: see `SessionExtensionSurface`.
    let extensionSurfaces = ExtensionSurfaceStore()
    /// Server, workspace, and session locks: hide ask text, forget deleted sessions.
    @ObservationIgnored var scopedLocks: ScopedLockService = .shared

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

    /// Per-session `AppSessionUsage` telemetry and its de-duplication state.
    let sessionUsageMetrics = SessionUsageMetricsReporter()

    init(seenStorage: SessionSeenLedgerStorage? = nil) {
        sessionStore = SessionStore(seenStorage: seenStorage)
        // Opening a session clears its notifications; the app icon badge counts down with the seen ledger.
        sessionStore.onMarkSeen = { serverId, sessionIds in
            AttentionNotificationService.shared.removeDeliveredNotifications(serverId: serverId, sessionIds: sessionIds)
        }
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

    // MARK: - Setup

    /// Update the in-memory device-credential snapshot for the same device ID.
    /// Does not disconnect, reconfigure, bump generations, or replace sessions.
    @discardableResult
    func applyPersistedDeviceCredential(_ credential: DeviceCredential) -> Bool {
        guard let current = credentials,
              let existing = current.deviceCredential,
              existing.deviceId == credential.deviceId else {
            return false
        }
        if existing != credential {
            credentials = current.withDeviceCredential(credential)
        }
        return true
    }

    /// Adopt the complete incoming snapshot when the HTTPS/WSS route is unchanged.
    @discardableResult
    func applyPersistedSameRouteCredentials(_ incoming: ServerCredentials) -> Bool {
        guard hasSameTransportIdentity(as: incoming) else { return false }
        if credentials != incoming {
            credentials = incoming
        }
        return true
    }

    func hasSameTransportIdentity(as incoming: ServerCredentials) -> Bool {
        credentials?.transportIdentity == incoming.transportIdentity
    }

    /// Configured HTTPS/WSS clients and a selected endpoint. A disconnected
    /// socket can still be reused; a missing client or endpoint cannot.
    var hasViableConfiguredTransport: Bool {
        credentials != nil && apiClient != nil && wsClient != nil && endpointSelection != nil
    }

    /// What this connection is doing while it has no API client: whether a client
    /// is on its way by itself, which is what a failed page may promise.
    var availability: ConnectionAvailability {
        // A terminal answer stops every automatic fallback: only configuring the
        // route again brings its client back.
        if route.hasFailedClosed { return .offline }
        // An attempt really is outstanding or scheduled: a rebuild between its
        // teardown and its commit, a setup pass running now, or a failure the
        // timer retries. A pass that failed otherwise waits for a foreground or
        // path boundary, and its page's own Retry cannot start one either, so the
        // page says the server is offline instead of promising an attempt.
        let attemptIsComing = route.isTransportDemoting
            || route.isConfiguringTransport
            || route.canRetryInitialTransportOnTimer
        return attemptIsComing ? .reconnecting : .offline
    }

    var isFocusedSessionStreamRecovering: Bool {
        focusedStreamBinder.isRecovering(focusedSessionId: focusedSessionId)
    }

    func setFocusedSessionStreamRecovering(_ recovering: Bool, sessionId: String) {
        focusedStreamBinder.setRecovering(recovering, sessionId: sessionId, focusedSessionId: focusedSessionId)
    }

    private func attachHTTPAuthSession(to client: APIClient, credentials: ServerCredentials) {
        httpAuthSession = nil
        guard let credential = credentials.deviceCredential else { return }
        do {
            let session = DeviceAuthSession(
                credential: credential,
                key: try deviceKeyProvider.loadOrCreate(),
                transport: client,
                onRefresh: { result in
                    Task { @MainActor in
                        self.route.deviceCredentialDidChange?(result)
                    }
                }
            )
            httpAuthSession = session
            client.attachAuthSession(session)
        } catch {
            logger.error("Device-key setup failed; HTTPS auth will fail closed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resetTransportState(
        credentials: ServerCredentials,
        endpointSelection: EndpointSelection?,
        transportPath: ConnectionTransportPath
    ) {
        disconnectAppEventStream()
        streamCapabilitiesRefreshTask?.cancel()
        streamCapabilitiesRefreshTask = nil
        voiceBackendFollowUpTask?.cancel()
        voiceBackendFollowUpTask = nil
        workspaceGitSummaryRefreshTasks.values.forEach { $0.cancel() }
        workspaceGitSummaryRefreshTasks.removeAll()
        workspaceGitSummaryRefreshGeneration.removeAll()
        streamCapabilitiesGeneration &+= 1

        self.credentials = credentials
        self.currentServerId = credentials.normalizedServerFingerprint
        // Bind the catalog stores before the app-event stream starts: its
        // events refresh the catalog, which is cached per server only.
        if let serverId = credentials.normalizedServerFingerprint {
            self.workspaceStore.switchServer(to: serverId)
            self.serverResourceStore.switchServer(to: serverId)
        }
        self.endpointSelection = endpointSelection
        self.connectedServerVersion = nil
        self.serverCapabilities = nil
        self.voiceBackends = nil
        self.dictationStreamUnsupportedByEndpoint = false
        self.appEventStreamTransportState = .disconnected
        self.missingRequiredSplitStreamCapabilities = []
        self.streamCapabilitiesLoaded = false
        self.streamCapabilitiesRefreshFailed = false
        self.clearFocusedSessionStreamEndpoint()
        self.transportPath = transportPath
    }

    /// Invalidate in-flight session-list and workspace-catalog refreshes so a
    /// late result is neither applied nor written to the cache.
    func cancelListRefreshWork() {
        listRefreshGeneration &+= 1
        sessionListRefreshTask?.cancel()
        sessionListRefreshTask = nil
        workspaceCatalogRefreshTask?.cancel()
        workspaceCatalogRefreshTask = nil
    }

    private func installAPIClient(_ client: APIClient?) {
        // Route epoch + stream teardown are one structural invariant: any new
        // API client invalidates in-flight list work and the app-event window.
        cancelListRefreshWork()
        disconnectAppEventStream()
        if client == nil {
            route.forgetInstalledClient()
        }
        apiClient = client
        iconAssetCache?.removeAll()
        iconAssetCache = client.map(IconAssetCache.init(apiClient:))
    }

    private func makeClientEnvironment(
        selection: EndpointSelection,
        credentials: ServerCredentials,
        tlsCertFingerprint: String? = nil
    ) -> OppiClientEnvironment {
        OppiClientEnvironment(
            baseURL: selection.baseURL,
            bearerToken: credentials.effectiveAccessToken,
            pinnedCertificateFingerprint: tlsCertFingerprint ?? credentials.normalizedTLSCertFingerprint,
            tlsServerName: selection.tlsServerName,
            processOwnership: .clientOnly
        )
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
        guard route.beginNetworkPathChange() else { return }

        if wasOnLAN {
            // LAN is tied to this network context. Stop burning reconnect
            // attempts against the dead private IP immediately, then start one
            // fresh HTTPS selection pass. Stream rebind happens
            // inside reconfigureForExplicitRetry once the next route commits.
            route.demoteLANAfterPathChange {
                streamConsumptionTask?.cancel()
                streamConsumptionTask = nil
                if let wsClient {
                    wsClient.cancelReconnectBackoff()
                    wsClient.disconnect()
                }
            }
            return
        }

        if apiClient == nil {
            Task { @MainActor [weak self] in
                await self?.route.reevaluateNetworkEndpointAtBoundary()
            }
            return
        }

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
        pathChangeMetadata.merge(diagnosticEndpointMetadata(endpointSelection?.baseURL, prefix: "api")) { current, _ in current }
        pathChangeMetadata.merge(diagnosticEndpointMetadata(focusedStreamBinder.streamURL, prefix: "stream")) { current, _ in current }
        ClientLog.info("Network", "Force stream reconnect after path change", metadata: pathChangeMetadata)

        // Tear down old WS + consumption task. Per-session continuations
        // are preserved; the active endpoint will be reopened below.
        // Drop parks from the dying socket so attach does not replay two
        // bootstrap generations after a path-change reconnect.
        streamConsumptionTask?.cancel()
        streamConsumptionTask = nil
        focusedStreamBinder.dropAllParkedFrames()
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
        focusedStreamBinder.dropAllParkedFrames()
        for (_, cont) in sessionEventContinuations {
            cont.finish()
        }
        sessionEventContinuations.removeAll()
        sessionUsageMetrics.forgetAll()
        clearFocusedSessionStreamEndpoint()
        wsClient?.disconnect()

        if let currentServerId {
            LiveActivityManager.shared.removeConnection(currentServerId)
        }
    }

    /// Single-flight `/server/info` load. A caller that joins a load in flight gets that
    /// load's behavior; `schedulesVoiceBackendFollowUp` applies to a load this call starts.
    func refreshStreamCapabilities(schedulesVoiceBackendFollowUp: Bool = true) async {
        guard let apiClient else { return }
        if let inFlight = streamCapabilitiesRefreshTask {
            await inFlight.value
            return
        }

        let generation = streamCapabilitiesGeneration
        let task = Task { @MainActor [weak self, apiClient] in
            guard let self else { return }
            defer { self.streamCapabilitiesRefreshTask = nil }

            do {
                let info = try await apiClient.serverInfo()
                guard self.streamCapabilitiesGeneration == generation else { return }

                // Capabilities are loaded whenever a client is installed (setup reads
                // /server/info first), so a reload leaves a running app-event stream
                // alone; foreground recovery restarts a stopped one.
                self.applyStreamCapabilities(info)
                if schedulesVoiceBackendFollowUp {
                    self.scheduleVoiceBackendFollowUpIfNeeded(info.voiceBackends)
                }
            } catch {
                guard self.streamCapabilitiesGeneration == generation else { return }
                // A transient failure keeps the snapshot setup loaded.
                self.streamCapabilitiesRefreshFailed = true

                var metadata = ClientLog.networkErrorMetadata(error)
                metadata["hadLoadedCapabilities"] = "true"
                metadata["capabilityStatus"] = self.requiredSplitStreamCapabilitiesStatusForDiagnostics
                metadata["transport"] = self.transportPath.rawValue
                let apiBaseURL = apiClient.baseURL
                metadata.merge(self.diagnosticEndpointMetadata(apiBaseURL, prefix: "api")) { current, _ in current }
                ClientLog.warning("Network", "Stream capability refresh failed", metadata: metadata)
            }
        }

        streamCapabilitiesRefreshTask = task
        await task.value
    }

    static let voiceBackendFollowUpDelay: Duration = .seconds(2)

    /// `/server/info` never waits for a voice backend probe: a read that finds a backend
    /// `checking` or `unreachable` may only have started one (1.5 s timeout on the server).
    /// Read once more after it settles, so a backend that came back shows its features on
    /// this foreground rather than the next. The follow-up read schedules nothing, so a
    /// backend that stays down costs one extra request, never a loop.
    private func scheduleVoiceBackendFollowUpIfNeeded(_ backends: [ServerInfo.VoiceBackend]?) {
        guard voiceBackendFollowUpTask == nil,
              backends?.contains(where: { $0.health == .checking || $0.health == .unreachable }) == true
        else { return }
        let generation = streamCapabilitiesGeneration
        let delay = _voiceBackendFollowUpDelayForTesting ?? Self.voiceBackendFollowUpDelay
        voiceBackendFollowUpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // A transport reset cancels this task and bumps the generation.
            guard let self, !Task.isCancelled, self.streamCapabilitiesGeneration == generation else {
                return
            }
            self.voiceBackendFollowUpTask = nil
            await self.refreshStreamCapabilities(schedulesVoiceBackendFollowUp: false)
        }
    }

    func noteServerVersionAfterUpdate(_ version: String) {
        connectedServerVersion = version
    }

    /// The Durable Sessions setting as the server stored it. The server applies a save at
    /// once, so the loaded capabilities follow it until the next `/server/info` read.
    func noteDurableSessionsAvailable(_ available: Bool) {
        serverCapabilities?.durableSessions = available ? ServerInfo.CapabilityVersion(version: 1) : nil
    }

    private func applyStreamCapabilities(_ info: ServerInfo) {
        connectedServerVersion = info.version
        let capabilities = info.capabilities
        let previousRelay = pushRelay
        serverCapabilities = capabilities
        voiceBackends = info.voiceBackends
        dictationStreamUnsupportedByEndpoint = false
        // Only a server that pushes, and that the user opted in for, gets this device's push
        // key, once per configuration. Otherwise the app never registers with APNs or the
        // relay, and never asks for notification permission.
        if let pushRelay, pushRelay != previousRelay, let apiClient {
            PushRegistration.shared.serverAdvertisesPush(
                api: apiClient,
                serverId: currentServerId,
                deviceId: credentials?.deviceCredential?.deviceId,
                relay: pushRelay
            )
        }
        missingRequiredSplitStreamCapabilities = ServerInfo.Capabilities
            .missingRequiredSplitStreamCapabilities(in: capabilities)
        streamCapabilitiesRefreshFailed = false
        streamCapabilitiesLoaded = true
    }

    func prepareForBackground() {
        wsClient?.prepareForBackground()
    }

    func routeStreamMessage(_ frameEvent: StreamFrameEvent) {
        let message = frameEvent.message
        // Conversation stream frames carry no sessionId: they belong to the session the
        // focused socket is bound to.
        let sessionId: String? = if case .conversationStream = message {
            frameEvent.sessionId ?? focusedStreamBinder.boundSessionId
        } else {
            frameEvent.sessionId
        }

        // Handle stream-level events (no sessionId)
        if case .streamConnected = message {
            sessionStreamCoordinator.clearSessionBootstrap()
            declareStreamSurfaceCapabilities()
            handleStreamReconnected()
            return
        }

        // Record bootstrap here, in socket order next to the clear above. Downstream
        // `connected` handling can be delayed by catch-up past a newer socket's
        // `stream_connected`, and must not re-mark a session whose new runtime failed.
        if case .connected(let session) = message, isFocusedSession(session.id) {
            sessionStreamCoordinator.noteSessionBootstrapped(sessionId: session.id)
        }

        // Resolve pending command waiters directly at the stream boundary,
        // BEFORE yielding to the per-session stream. Semantic effects still
        // flow downstream, but request waiters do not depend on a session
        // consumer being attached and running.
        resolveBoundaryCommandResult(message, meta: frameEvent.meta)

        // Route to per-session continuation if active. Metadata stays attached
        // to the message through SessionStreamEvent. If the session is already
        // focused but ChatViewController has not attached yet, park the frame so the
        // bootstrap is not lost.
        if let sessionId {
            let event = SessionStreamEvent(
                sessionId: sessionId,
                message: message,
                meta: frameEvent.meta
            )
            if let cont = sessionEventContinuations[sessionId] {
                cont.yield(event)
            } else if isFocusedSession(sessionId) {
                focusedStreamBinder.park(event)
            }
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
        let transport = meta?.transportPath ?? transportPath
        Telemetry.record(
            AppCommandResolveLag(
                lagMs: Double(lagMs),
                command: command,
                transport: transport.commandResolveLagTransport,
                status: success ? .ok : .error
            )
        )
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
            return
        }

        let result = applySharedStoreUpdate(for: message, sessionId: sessionId)
        handleInactiveSessionUI(message, sessionId: sessionId)

        if result.handled {
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
            syncLiveActivityState()
        default:
            break
        }
    }

    private func shouldDeferSharedStoreUpdateToLiveSessionConsumer(_ message: ServerMessage) -> Bool {
        switch message {
        case .agentStart,
             .agentEnd,
             .agentSettled,
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

    // MARK: - External Session Open Claim

    private var effectiveExternalSessionOpenClaimWindow: Duration {
        _externalSessionOpenClaimWindowForTesting ?? FocusedSessionStreamBinder.externalOpenClaimWindow
    }

    /// A scoped-lock prompt was cancelled after `prepareExternalSessionOpen`
    /// (only pending dialogs named the locked workspace): the open never
    /// navigates. Its claim must not keep refusing other sessions, the
    /// active-session pointer goes back, and focus and the stream return to
    /// the session this connection had before, or close.
    func abandonExternalSessionOpen(
        sessionId: String,
        restoringActiveSessionId previousActive: String?,
        restoringFocusedSessionId previousFocused: String?
    ) {
        focusedStreamBinder.resolveExternalOpenClaim(for: sessionId)
        if sessionStore.activeSessionId == sessionId {
            sessionStore.activeSessionId = previousActive
        }
        guard focusedSessionId == sessionId else { return }
        if let previousFocused, previousFocused != sessionId {
            prepareForSessionReentry(previousFocused)
        } else {
            disconnectSession(sessionId: sessionId)
        }
    }

    private func recordExternalSessionOpenClaimRefusal(_ sessionId: String, context: String) {
        recordFocusArbitration(
            outcome: "refused",
            previousSessionId: focusedStreamBinder.externalOpenClaimSessionId,
            nextSessionId: sessionId,
            context: context
        )
    }

    // MARK: - Session Streaming

    private func clearFocusedSessionStreamEndpoint() {
        focusedStreamBinder.clearBinding()
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

    /// Open the URL-bound focused session stream for the holder of `claim`.
    /// Every rebind or socket side effect happens only while `claim` is current.
    func streamSession(
        _ sessionId: String,
        routeScope: SessionRouteScope,
        claim: FocusedSessionContext
    ) async -> AsyncStream<SessionStreamEvent>? {
        guard !focusedStreamBinder.externalOpenClaimBlocks(sessionId) else {
            recordExternalSessionOpenClaimRefusal(sessionId, context: "stream_bind")
            return nil
        }
        guard !Task.isCancelled else { return nil }
        await waitForFocusedStreamBindReadinessIfNeeded(sessionId: sessionId)
        // Cancellation can retain the claim when the same runtime reconnects.
        // Do not let its old opener rebind or reopen the replacement socket.
        guard !Task.isCancelled else { return nil }
        // The owner may have been superseded while waiting. Refuse before the
        // endpoint is rebound and the shared socket reconnected underneath the
        // newer owner (this or another session). The coordinator checks again
        // right before its own focus/attach/connect side effects.
        if !focusedSessionStore.isCurrent(claim) {
            recordFocusArbitration(
                outcome: "stale_open_refused",
                previousSessionId: claim.sessionId,
                nextSessionId: focusedSessionId ?? "none",
                context: "stream_bind"
            )
            return nil
        }
        guard hasRequiredSplitStreamCapabilities else {
            recordSessionStreamUnavailable(reason: streamCapabilityUnavailableReason())
            return nil
        }
        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, routeScope: routeScope)
        // The tapped session's own timeline now owns the stream; ordinary focus
        // arbitration resumes for later navigation.
        focusedStreamBinder.resolveExternalOpenClaim(for: sessionId)
        guard !Task.isCancelled else { return nil }
        return await sessionStreamCoordinator.streamSession(
            connection: self,
            claim: claim,
            sessionId: sessionId,
            routeScope: routeScope
        )
    }

    /// Silence watchdog and session re-entry can race a Wi‑Fi→cell demotion or
    /// cold-launch capability load. Wait for a bindable route instead of failing
    /// open on that hole. Loaded-missing capability and fail-closed stay terminal.
    func waitForFocusedStreamBindReadinessIfNeeded(sessionId: String) async {
        if isFocusedStreamBindReady() || isFocusedStreamBindTerminal() {
            return
        }
        setFocusedSessionStreamRecovering(true, sessionId: sessionId)
#if DEBUG
        _onFocusedStreamReadinessWaitForTesting?()
#endif
        let poll = focusedStreamReadinessPoll()
        defer {
            setFocusedSessionStreamRecovering(false, sessionId: sessionId)
        }
        for _ in 0..<50 {
            if Task.isCancelled { return }
            if isFocusedStreamBindReady() || isFocusedStreamBindTerminal() {
                return
            }
            do {
                try await Task.sleep(for: poll)
            } catch {
                return
            }
        }
    }

    func isFocusedStreamBindReady() -> Bool {
        !route.isTransportDemoting
            && endpointSelection != nil
            && wsClient != nil
            && hasRequiredSplitStreamCapabilities
    }

    func isFocusedStreamBindTerminal() -> Bool {
        route.hasFailedClosed
            || (streamCapabilitiesLoaded && !missingRequiredSplitStreamCapabilities.isEmpty)
            || focusedSessionStreamEndpointIsUnsupported()
    }

    private func focusedStreamReadinessPoll() -> Duration {
#if DEBUG
        if let poll = _focusedStreamReadinessPollForTesting {
            return poll
        }
#endif
        return .milliseconds(100)
    }

    private func prepareFocusedSessionStreamEndpoint(sessionId: String, routeScope: SessionRouteScope) {
        let previousBoundSessionId = focusedStreamBinder.boundSessionId
        if previousBoundSessionId != sessionId {
            recordFocusArbitration(
                outcome: "requested",
                previousSessionId: previousBoundSessionId,
                nextSessionId: sessionId,
                context: "stream_bind"
            )
        }

        if focusedStreamBinder.isBound(sessionId: sessionId, routeScope: routeScope) {
            // Keep a live/reconnecting transport for the same bound endpoint,
            // but still recompute the URL below. Endpoint selection may have
            // changed after Wi-Fi/cellular handoff while the session target did not.
        } else if focusedStreamBinder.isBound,
                  hasActiveFocusedSessionStreamTransport() {
            recordFocusArbitration(
                outcome: "cancelled",
                previousSessionId: previousBoundSessionId,
                nextSessionId: sessionId,
                context: "stream_bind"
            )
            disconnectStream()
        } else {
            clearFocusedSessionStreamEndpoint()
        }

        guard hasRequiredSplitStreamCapabilities, let selection = endpointSelection else {
            recordSessionStreamUnavailable(reason: hasRequiredSplitStreamCapabilities ? "missingEndpointSelection" : streamCapabilityUnavailableReason())
            return
        }
        guard let sessionStreamURL = FocusedSessionStreamBinder.streamURL(
            selection: selection,
            sessionId: sessionId,
            routeScope: routeScope
        ) else {
            recordSessionStreamUnavailable(reason: "invalidStreamURL")
            return
        }

        let previousURL = focusedStreamBinder.streamURL
        focusedStreamBinder.bind(sessionId: sessionId, routeScope: routeScope, url: sessionStreamURL)
        wsClient?.setPreferredEndpoint(selection)
        wsClient?.setStreamURL(sessionStreamURL, sessionId: sessionId, workspaceId: routeScope.workspaceId)

        if previousBoundSessionId != sessionId {
            recordFocusArbitration(
                outcome: "won",
                previousSessionId: previousBoundSessionId,
                nextSessionId: sessionId,
                context: "stream_bind"
            )
        }

        if let previousURL, previousURL != sessionStreamURL {
            var metadata: [String: String] = [
                "transport": selection.transportPath.rawValue,
                "urlChanged": "true",
            ]
            metadata.merge(diagnosticEndpointMetadata(previousURL, prefix: "previousStream")) { current, _ in current }
            metadata.merge(diagnosticEndpointMetadata(sessionStreamURL, prefix: "nextStream")) { current, _ in current }
            ClientLog.info("Network", "Focused stream endpoint changed", metadata: metadata)
        }
    }

    private func refreshPreparedFocusedSessionEndpointAfterEndpointChange() {
        guard focusedStreamBinder.isBound,
              let sessionId = focusedStreamBinder.boundSessionId,
              let routeScope = focusedStreamBinder.boundRouteScope else {
            return
        }

        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, routeScope: routeScope)
    }

    private func streamCapabilityUnavailableReason() -> String {
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
            "reason": route.isTransportDemoting ? "transportDemoting" : reason,
            "capabilityStatus": requiredSplitStreamCapabilitiesStatusForDiagnostics,
            "transport": route.isTransportDemoting ? "demoting" : transportPath.rawValue,
            "demoting": route.isTransportDemoting ? "true" : "false",
            "hasWebSocketClient": wsClient == nil ? "false" : "true",
        ]
        metadata.merge(diagnosticEndpointMetadata(endpointSelection?.baseURL, prefix: "api")) { current, _ in current }
        metadata.merge(diagnosticEndpointMetadata(focusedStreamBinder.streamURL, prefix: "stream")) { current, _ in current }
        ClientLog.warning("Network", "Session stream unavailable", metadata: metadata)
    }

    private func diagnosticEndpointMetadata(_ url: URL?, prefix: String) -> [String: String] {
        ClientLog.endpointMetadata(url, prefix: prefix)
    }

    private func recordFocusArbitration(
        outcome: String,
        previousSessionId: String?,
        nextSessionId: String,
        context: String
    ) {
        let metadata = [
            "outcome": outcome,
            "previousSessionId": previousSessionId ?? "none",
            "nextSessionId": nextSessionId,
            "context": context,
            "transport": transportPath.rawValue,
        ]
        ClientLog.info("Focus", "Focused stream arbitration", metadata: metadata)
        _onFocusArbitrationForTesting?(outcome, metadata)
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

    func streamEndpointHostKindForMetrics() -> String {
        ClientLog.hostKind(endpointSelection?.baseURL.host ?? credentials?.host)
    }

    /// Close local continuations for a specific session stream.
    func closeSessionStreamContinuations(_ sessionId: String) {
        focusedStreamBinder.dropParkedFrames(for: sessionId)
        sessionEventContinuations[sessionId]?.finish()
        sessionEventContinuations.removeValue(forKey: sessionId)
    }

    /// Attach the live consumer and replay any frames parked while the socket
    /// was already bound. Drain happens before later `connectStream()` work so
    /// bootstrap stays ahead of newly arriving live frames.
    func attachSessionEventContinuation(
        _ sessionId: String,
        _ continuation: AsyncStream<SessionStreamEvent>.Continuation
    ) {
        if wsClient?.status == .connected, !focusedStreamBinder.hasParkedBootstrap(for: sessionId) {
            // A connected socket is not reusable by a new runtime unless its
            // bootstrap can be delivered to that consumer. It may have gone to
            // an old continuation or been dropped during a focus change. Reopen
            // the socket before attaching; disconnectStream() would also clear
            // the bound endpoint and finish the new consumer.
            ClientLog.info("Stream", "Reopening focused socket for missing consumer bootstrap", metadata: [
                "sessionId": sessionId,
            ])
            cancelDeferredQueueSync()
            streamConsumptionTask?.cancel()
            streamConsumptionTask = nil
            focusedStreamBinder.dropAllParkedFrames()
            wsClient?.disconnect()
        }
        sessionEventContinuations[sessionId]?.finish()
        sessionEventContinuations[sessionId] = continuation
        drainParkedFocusedSessionFrames(for: sessionId)
    }

    private func drainParkedFocusedSessionFrames(for sessionId: String) {
        guard let continuation = sessionEventContinuations[sessionId] else { return }
        let parked = focusedStreamBinder.takeParkedFrames(for: sessionId)
        guard !parked.isEmpty else { return }
        ClientLog.info("Stream", "Draining parked focused session frames", metadata: [
            "sessionId": sessionId,
            "count": String(parked.count),
        ])
        for event in parked {
            continuation.yield(event)
        }
    }

    private func deferDisconnectSessionUntilLiveAudioStreamFinishes(_ claim: FocusedSessionContext) {
        let sessionId = claim.sessionId
        focusedStreamBinder.cancelDeferredDisconnect(of: sessionId)
        focusedStreamBinder.deferDisconnect(of: sessionId, until: Task { @MainActor [weak self] in
            while let self,
                  !Task.isCancelled,
                  self.audioPlayer.activeLiveTransportSessionID == sessionId {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled else { return }
            self.focusedStreamBinder.finishDeferredDisconnect(of: sessionId)
            // Re-validate after the wait: a newer owner may have claimed this
            // same session while audio drained, and its stream must survive.
            // (Focus on another session keeps the old per-session teardown.)
            if let focused = self.focusedSessionStore.focused,
               focused.sessionId == sessionId,
               focused != claim {
                return
            }
            self.disconnectSession(sessionId: sessionId)
        })
    }

    private func disconnectSessionResources(for sessionId: String) {
        closeSessionStreamContinuations(sessionId)
        messageQueueStore.clear(sessionId: sessionId)
        sessionUsageMetrics.forget(sessionId: sessionId)
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
        return extensionDialogs.requests(for: sessionId)
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
    func focusSession(_ sessionId: String) {
        applyFocus(sessionId, startsClaim: false)
    }

    /// Focus `sessionId` and start a new ownership claim on it. Only the holder
    /// of the returned claim may release the focus with `releaseFocusedSession`;
    /// an older claim on the same session (a stale chat runtime) stops matching
    /// until that newer claim is released (see `releaseFocusedSession`).
    func claimFocusedSession(
        _ sessionId: String,
        holder: FocusClaimHolder? = nil
    ) -> FocusedSessionContext? {
        applyFocus(sessionId, startsClaim: true, holder: holder)
    }

    /// Release focus and its session stream only if `claim` is still current.
    /// A stale claim is a no-op for the stream, so a destroyed or superseded
    /// chat runtime can never tear down the stream of a newer owner of the same
    /// session. When an older runtime for the same session is still mounted
    /// (a layout swap briefly mounted a duplicate chat that is now leaving),
    /// focus and the stream go back to it instead of being closed.
    func releaseFocusedSession(_ claim: FocusedSessionContext) {
        guard focusedSessionStore.isCurrent(claim) else {
            focusedSessionStore.forget(claim)
            recordFocusArbitration(
                outcome: "stale_release_ignored",
                previousSessionId: claim.sessionId,
                nextSessionId: focusedSessionId ?? "none",
                context: "release"
            )
            return
        }
        if !focusedStreamBinder.externalOpenClaimBlocks(claim.sessionId),
           let holder = focusedSessionStore.handBack(from: claim) {
            recordFocusArbitration(
                outcome: "handed_back",
                previousSessionId: claim.sessionId,
                nextSessionId: claim.sessionId,
                context: "release"
            )
            holder.regain()
            return
        }
        if audioPlayer.activeLiveTransportSessionID == claim.sessionId {
            // Focus stays on the released claim until audio drains, but its
            // runtime is gone: it must never be kept for a later hand-back.
            focusedSessionStore.detachHolder(from: claim)
            deferDisconnectSessionUntilLiveAudioStreamFinishes(claim)
            return
        }
        disconnectSession(sessionId: claim.sessionId)
    }

    /// Whether `sessionId` is focused and its URL-bound socket is live. A chat
    /// can still read `.streaming` after the socket dropped or focus moved; turn
    /// dispatch checks this instead of the runtime's entry state alone.
    func focusedStreamLiveness(sessionId: String) -> FocusedStreamLiveness {
        guard focusedSessionStore.isFocused(sessionId),
              focusedStreamBinder.isBound,
              focusedStreamBinder.boundSessionId == sessionId,
              let wsClient else {
            return .down
        }
        switch wsClient.status {
        case .connected:
            return .connected
        case .connecting, .reconnecting:
            return .recovering
        case .disconnected:
            return .down
        }
    }

    @discardableResult
    private func applyFocus(
        _ sessionId: String,
        startsClaim: Bool,
        holder: FocusClaimHolder? = nil
    ) -> FocusedSessionContext? {
        guard !focusedStreamBinder.externalOpenClaimBlocks(sessionId) else {
            recordExternalSessionOpenClaimRefusal(sessionId, context: "focus")
            return nil
        }
        focusedStreamBinder.cancelDeferredDisconnect(of: sessionId)
        let previousSessionId = focusedSessionId
        if previousSessionId != sessionId {
            if let previousSessionId {
                focusedStreamBinder.dropParkedFrames(for: previousSessionId)
            }
            recordFocusArbitration(
                outcome: "requested",
                previousSessionId: previousSessionId,
                nextSessionId: sessionId,
                context: "focus"
            )
            // Stop the old focused-session watchdog before switching command
            // routing. Pending AskCard state already lives in AskRequestStore.
            silenceWatchdog.stop()
        }

        let context = startsClaim
            ? focusedSessionStore.claim(sessionId: sessionId, holder: holder)
            : focusedSessionStore.focus(sessionId: sessionId)
        sessionStore.setViewingSession(sessionId)
        // Reset per-connection chat state for a newly focused session. Re-focusing the
        // session already in focus (a chat coming back from a reader pushed over it)
        // keeps its state: the stream never dropped, so no `connected` follows to refill
        // the slash command list the reset would empty.
        // Sheet-backed extension dialogs are derived from extensionDialogs.
        if previousSessionId != sessionId {
            chatState.resetSessionState()
        }

        syncActiveAskWorkspaceSummary()
        return context
    }

    /// Re-establish command routing before a session view re-enters foreground interaction.
    ///
    /// If we already know the split-stream endpoint for an active session, eagerly
    /// reopen the transport so toolbar actions like Stop work immediately while the
    /// chat view's async connect loop is still spinning up its per-session timeline.
    func prepareForSessionReentry(
        _ sessionId: String,
        workspaceIdHint: String? = nil,
        routeScope: SessionRouteScope? = nil
    ) {
        // Do not settle the claim here. Same-session re-entry is already
        // unblocked; releasing on appear re-opens the steal window before
        // streamSession binds.
        bindSessionForReentry(
            sessionId,
            workspaceIdHint: workspaceIdHint,
            routeScope: routeScope
        )
    }

    private func bindSessionForReentry(
        _ sessionId: String,
        workspaceIdHint: String?,
        routeScope: SessionRouteScope?
    ) {
        _onPrepareForSessionReentryForTesting?(sessionId)
        guard !focusedStreamBinder.externalOpenClaimBlocks(sessionId) else {
            recordExternalSessionOpenClaimRefusal(sessionId, context: "reentry")
            return
        }
        focusSession(sessionId)

        let session = sessionStore.session(id: sessionId)
        guard hasRequiredSplitStreamCapabilities, session?.status != .stopped else {
            return
        }

        let resolvedScope: SessionRouteScope?
        if routeScope == .control || session?.usesControlRoutes == true {
            resolvedScope = .control
        } else {
            resolvedScope = sessionReentryWorkspaceId(
                for: sessionId,
                workspaceIdHint: workspaceIdHint
            ).map(SessionRouteScope.workspace)
        }
        guard let resolvedScope else { return }

        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, routeScope: resolvedScope)
        connectStream()
    }

    /// Notification / deep-link open: focus first, then hydrate pending dialogs.
    ///
    /// If `/dialogs` is the first place we learn the workspace, re-enter so a
    /// live session can bind its stream after the ask card is restored.
    /// The caller refreshes the session record first
    /// (`refreshSessionRecordIfPossible`), so its scoped-lock gate runs before
    /// anything here focuses the session.
    func prepareExternalSessionOpen(
        sessionId: String,
        workspaceIdHint: String? = nil
    ) async {
        // Claim before the first await: the timeline prefetch and dialog
        // hydration below are exactly the window in which a still-mounted
        // ChatViewController for another session re-enters and steals the transport.
        focusedStreamBinder.beginExternalOpenClaim(for: sessionId, window: effectiveExternalSessionOpenClaimWindow)
        sessionStore.activeSessionId = sessionId
        await prefetchSessionTimelineIfPossible(sessionId: sessionId)
        let initialWorkspaceId = sessionReentryWorkspaceId(
            for: sessionId,
            workspaceIdHint: workspaceIdHint
        )
        bindSessionForReentry(
            sessionId,
            workspaceIdHint: initialWorkspaceId,
            routeScope: nil
        )
        await hydrateSessionDialogs(sessionId: sessionId)
        let resolvedWorkspaceId = sessionReentryWorkspaceId(
            for: sessionId,
            workspaceIdHint: initialWorkspaceId
        )
        if resolvedWorkspaceId != initialWorkspaceId {
            bindSessionForReentry(
                sessionId,
                workspaceIdHint: resolvedWorkspaceId,
                routeScope: nil
            )
        }
        // Re-assert the active session: a losing ChatViewController's connect loop can
        // still have overwritten this pointer during the awaits above.
        sessionStore.activeSessionId = sessionId
    }

    /// The open of a session whose record and workspace are already loaded:
    /// everything `prepareExternalSessionOpen` does before its first network
    /// read, so the route can be pushed now. The claim keeps a still-mounted
    /// chat for another session from stealing the transport until the target
    /// mounts. `completeExternalSessionOpen` finishes the rest.
    func beginExternalSessionOpen(sessionId: String, workspaceIdHint: String? = nil) {
        focusedStreamBinder.beginExternalOpenClaim(for: sessionId, window: effectiveExternalSessionOpenClaimWindow)
        sessionStore.activeSessionId = sessionId
        bindSessionForReentry(
            sessionId,
            workspaceIdHint: sessionReentryWorkspaceId(for: sessionId, workspaceIdHint: workspaceIdHint),
            routeScope: nil
        )
    }

    /// The network half of `prepareExternalSessionOpen` for an open that
    /// `beginExternalSessionOpen` already routed: hydrate pending dialogs,
    /// binding again when they name a new workspace. The chat on screen loads
    /// its own timeline, so this does not prefetch one: a late prefetch could
    /// overwrite a newer cache. It does not re-assert the active session: the
    /// route is up, and the person may have moved on while the read ran.
    func completeExternalSessionOpen(sessionId: String, workspaceIdHint: String? = nil) async {
        let initialWorkspaceId = sessionReentryWorkspaceId(for: sessionId, workspaceIdHint: workspaceIdHint)
        await hydrateSessionDialogs(sessionId: sessionId)
        let resolvedWorkspaceId = sessionReentryWorkspaceId(for: sessionId, workspaceIdHint: initialWorkspaceId)
        if resolvedWorkspaceId != initialWorkspaceId {
            bindSessionForReentry(sessionId, workspaceIdHint: resolvedWorkspaceId, routeScope: nil)
        }
    }

    /// Load current session JSON so tap does not trust a stale cached status.
    /// Failure keeps the cached row; it must not block ask-card hydration.
    func refreshSessionRecordIfPossible(sessionId: String) async {
        _ = await loadSessionRecord(sessionId: sessionId)
    }

    /// What reading one session record from the server came to.
    enum SessionRecordLoad: Equatable {
        /// The record is in the session store.
        case loaded
        /// The server answered that it has no such session (404).
        case notFound
        /// No answer: no client, a network error, or another failure.
        case failed
    }

    /// `refreshSessionRecordIfPossible` that says how the read ended, for a caller that must tell a
    /// session the server does not have from a server it could not ask.
    func loadSessionRecord(sessionId: String) async -> SessionRecordLoad {
        do {
            let session: Session
            if let fetchHook = _getSessionRecordForTesting {
                session = try await fetchHook(sessionId)
            } else if let apiClient {
                session = try await apiClient.getSessionRecord(sessionId: sessionId)
            } else {
                return .failed
            }
            sessionStore.upsert(session)
            return .loaded
        } catch {
            recordRefreshEvent(
                "session_record.refresh_failed",
                level: .warning,
                metadata: Self.refreshErrorMetadata(error)
            )
            if case APIError.server(let status, _) = error, status == 404 { return .notFound }
            if case APIError.codedServer(let status, _, _) = error, status == 404 { return .notFound }
            return .failed
        }
    }

    /// Warm the timeline cache so ChatViewController's normal connect path is not blank
    /// while the focused session WebSocket is opening.
    func prefetchSessionTimelineIfPossible(sessionId: String) async {
        // A trace is cached under its server so Remove Server can delete it.
        guard let serverId = currentServerId,
              let apiClient,
              let routeScope = sessionStore.routeScope(for: sessionId) else { return }
        do {
            let session: Session
            let trace: [TraceEvent]
            var page: TracePageMetadata?
            do {
                let response = try await apiClient.getSessionTracePage(
                    scope: routeScope,
                    sessionId: sessionId,
                    previewBytes: 4_096
                )
                session = response.session
                trace = response.trace
                page = response.page
            } catch {
                guard IOSChatSessionRuntimeAdapter.shouldFallbackToFullTrace(error) else { throw error }
                let fallback = try await apiClient.getSession(
                    scope: routeScope,
                    sessionId: sessionId,
                    traceView: .full
                )
                session = fallback.session
                trace = fallback.trace
                page = nil
            }
            sessionStore.upsert(session)
            await TimelineCache.shared.saveTrace(
                sessionId,
                serverId: serverId,
                events: trace,
                page: page
            )
        } catch {
            recordRefreshEvent(
                "session_trace.prefetch_failed",
                level: .warning,
                metadata: Self.refreshErrorMetadata(error)
            )
        }
    }

    func disconnectSession(sessionId: String) {
        focusedStreamBinder.cancelDeferredDisconnect(of: sessionId)
        let isFocusedSession = focusedSessionId == sessionId

        if isFocusedSession {
            cancelDeferredQueueSync()
            commands.failAllTurnSends(error: WebSocketError.notConnected)
            commands.failAllCommands(error: WebSocketError.notConnected)
            setFocusedSessionStreamRecovering(false, sessionId: sessionId)
        }

        disconnectSessionResources(for: sessionId)

        guard isFocusedSession else { return }

        // Pending AskCard state already lives in AskRequestStore and will be
        // visible again when focus returns to this session.

        focusedSessionStore.clear()
        sessionStore.setViewingSession(nil)
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

    /// Split streams bind the destination in the URL, so the envelope override
    /// cannot redirect a frame. Repair a stale binding before any turn command.
    private func prepareFocusedSessionBindingForSendIfNeeded(
        sessionIdOverride: String?
    ) throws {
        guard let requestedSessionId = sessionIdOverride,
              focusedStreamBinder.isBound,
              let boundSessionId = focusedStreamBinder.boundSessionId,
              boundSessionId != requestedSessionId else {
            return
        }

        prepareForSessionReentry(
            requestedSessionId,
            workspaceIdHint: sessionReentryWorkspaceId(for: requestedSessionId),
            routeScope: sessionStore.routeScope(for: requestedSessionId)
        )

        guard focusedStreamBinder.isBound,
              focusedStreamBinder.boundSessionId == requestedSessionId else {
            throw FocusedSessionBindingError.rebindUnavailable(
                requestedSessionId: requestedSessionId,
                boundSessionId: boundSessionId
            )
        }
    }

    func sendPrompt(_ text: String, attachments: [ChatAttachmentRef]? = nil, streamingBehavior: StreamingBehavior? = nil, clientTurnId: String? = nil, sessionIdOverride: String? = nil, onAckStage: ((TurnAckStage) -> Void)? = nil) async throws {
        try prepareFocusedSessionBindingForSendIfNeeded(sessionIdOverride: sessionIdOverride)
        try await sender.sendPrompt(text, attachments: attachments, streamingBehavior: streamingBehavior, clientTurnId: clientTurnId, sessionIdOverride: sessionIdOverride, onAckStage: onAckStage)
    }

    func sendStop(sessionIdOverride: String? = nil) async throws {
        try prepareFocusedSessionBindingForSendIfNeeded(sessionIdOverride: sessionIdOverride)
        try await sender.sendStop(sessionIdOverride: sessionIdOverride)
    }

    func sendStopSession(sessionIdOverride: String? = nil) async throws {
        try prepareFocusedSessionBindingForSendIfNeeded(sessionIdOverride: sessionIdOverride)
        try await sender.sendStopSession(sessionIdOverride: sessionIdOverride)
    }

    func send(_ message: ClientMessage) async throws { try await sender.send(message) }

    /// Sends one action on a composable surface at the revision the client holds, and shows the
    /// action's declared pending state until `extension_ui_settled` names the request or a frame
    /// newer than that revision answers it.
    func sendExtensionSurfaceAction(_ intent: ExtensionSurfaceActionIntent, sessionId: String) {
        let surface = extensionSurfaces.surface(for: sessionId).state.composableSurfaces[intent.surfaceId]?.surface
        // A closed composite's pending state is declared in the action table; a node's is on the
        // node that offered it, and the intent carries that one.
        let definition = surface?.actions[intent.actionId]
        let pending = intent.pending ?? definition?.pending
        let requestId = UUID().uuidString
        extensionSurfaces.beginAction(
            ExtensionSurfacePendingAction(
                requestId: requestId,
                surfaceId: intent.surfaceId,
                compositeId: intent.compositeId,
                actionId: intent.actionId,
                rowId: intent.rowId,
                nodeId: intent.nodeId,
                revision: intent.revision,
                title: pending?.title,
                disabledActionIds: Set(pending?.disabled ?? [])
            ),
            sessionId: sessionId
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await send(.extensionUIAction(
                    surfaceId: intent.surfaceId,
                    compositeId: intent.compositeId,
                    actionId: intent.actionId,
                    rowId: intent.rowId,
                    nodeId: intent.nodeId,
                    revision: intent.revision,
                    values: intent.values,
                    requestId: requestId
                ))
            } catch {
                // Nothing reached the server, so nothing will settle it.
                extensionSurfaces.settle(requestId: requestId, sessionId: sessionId)
            }
        }
    }

    func requestState() async throws { try await sender.requestState() }

    func requestMessageQueue(timeout: Duration = MessageSender.commandRequestTimeoutDefault, sessionIdOverride: String? = nil) async throws {
        try await sender.requestMessageQueue(timeout: timeout, sessionIdOverride: sessionIdOverride)
    }

    func removeQueuedMessage(itemId: String, sessionIdOverride: String? = nil) async throws {
        try await sender.removeQueuedMessage(itemId: itemId, sessionIdOverride: sessionIdOverride)
    }

    func takeMessageQueue(sessionIdOverride: String? = nil) async throws -> MessageQueueState {
        try await sender.takeMessageQueue(sessionIdOverride: sessionIdOverride)
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
        let routeScope = sessionStore.routeScope(for: sessionId)

        let focusedStreamReady = isFocusedSession(sessionId) && wsClient?.status == .connected
        if !focusedStreamReady, let routeScope, apiClient != nil {
            try await respondToExtensionUI(
                routeScope: routeScope,
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
            focusedSessionStore.focus(sessionId: sessionId)
            sessionStore.setViewingSession(sessionId)
        } else {
            focusedSessionStore.clear()
            sessionStore.setViewingSession(nil)
        }
    }

    func makeDictationStreamClient() -> DictationStreamClient? {
        guard let selection = endpointSelection,
              let credentials else { return nil }
        let session = httpAuthSession
        let currentTokenProvider: (@Sendable () async throws -> String)?
        let refreshTokenProvider: (@Sendable () async throws -> String)?
        if let session {
            currentTokenProvider = { try await session.currentAccessToken() }
            refreshTokenProvider = { try await session.refreshAccessToken() }
        } else {
            currentTokenProvider = nil
            refreshTokenProvider = nil
        }
        let client = DictationStreamClient(
            baseURL: selection.baseURL,
            token: credentials.effectiveAccessToken,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            tlsServerName: selection.tlsServerName,
            tailnetRoute: route.configuredTailnetRoute,
            currentTokenProvider: currentTokenProvider,
            refreshTokenProvider: refreshTokenProvider
        )
        activeDictationClient = client
        return client
    }

    /// A second stream to a session that carries its Live Voice call and audio. It must not
    /// steal the focused chat WebSocket, and the connection keeps no reference to it: the
    /// call's channel owns it, so changing the focused session or the active server never
    /// touches a running call.
    func makeLiveVoiceWebSocketClient(sessionId: String, routeScope: SessionRouteScope) -> WebSocketClient? {
        guard let selection = endpointSelection,
              let credentials,
              let streamURL = FocusedSessionStreamBinder.streamURL(
                  selection: selection,
                  sessionId: sessionId,
                  routeScope: routeScope
              ) else {
            return nil
        }

        let client = WebSocketClient(
            credentials: credentials,
            preferredEndpoint: selection,
            diagnosticRole: "live_voice",
            diagnosticRemoteIdentity: nil,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            tlsServerName: selection.tlsServerName,
            authSession: httpAuthSession
        )
        client.setPreferredEndpoint(selection)
        client.setStreamURL(streamURL, sessionId: sessionId, workspaceId: routeScope.workspaceId)
        return client
    }

    func startAppEventStreamIfAvailable() {
        guard appEventStreamAvailable,
              let selection = endpointSelection,
              let credentials,
              let streamURL = makeAppEventStreamURL(selection: selection) else {
            appEventStreamTransportState = .disconnected
            return
        }

        appEventStreamTransportState = .connecting

        #if DEBUG
        if let startAppEventStreamForTesting = _startAppEventStreamForTesting {
            startAppEventStreamForTesting(streamURL)
            return
        }
        #endif

        let clientGeneration = route.persistentStreamGeneration
        let session = httpAuthSession
        let currentTokenProvider: (@Sendable () async throws -> String)?
        let refreshTokenProvider: (@Sendable () async throws -> String)?
        if let session {
            currentTokenProvider = { try await session.currentAccessToken() }
            refreshTokenProvider = { try await session.refreshAccessToken() }
        } else {
            currentTokenProvider = nil
            refreshTokenProvider = nil
        }
        #if DEBUG
        let webSocketFactory = _appEventWebSocketFactoryForTesting
        #else
        let webSocketFactory: ((URLRequest) -> AppEventWebSocketTransport)? = nil
        #endif
        let client = AppEventStreamClient(
            url: streamURL,
            token: credentials.effectiveAccessToken,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            tlsServerName: selection.tlsServerName,
            transportPath: selection.transportPath,
            tailnetRoute: route.configuredTailnetRoute,
            diagnosticRemoteIdentity: nil,
            leftoverExpiresAtMs: credentials.deviceCredential?.expiresAt,
            currentTokenProvider: currentTokenProvider,
            refreshTokenProvider: refreshTokenProvider,
            webSocketFactory: webSocketFactory
        )
        client.onTransportHealthFailure = { @MainActor [weak self, weak client] failure in
            guard let self,
                  let client,
                  self.appEventStreamCoordinator.isCurrentClient(client) else { return }
            await self.route.handlePersistentStreamHealthFailure(
                failure,
                expectedGeneration: clientGeneration
            )
        }
        appEventStreamCoordinator.start(
            connection: self,
            client: client,
            streamURL: streamURL
        )
    }

    func disconnectAppEventStream() {
        appEventListRepair.streamStopped()
        appEventStreamConnectedAt = nil
        appEventStreamCoordinator.disconnect()
        appEventStreamTransportState = .disconnected
    }

    func setAppEventStreamTransportState(_ state: ServerHealth.TransportState) {
        appEventStreamTransportState = state
        guard state == .connected else {
            appEventStreamConnectedAt = nil
            return
        }

        appEventStreamConnectedAt = Date()
        appEventListRepair.streamConnected()
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
    var listRefreshGeneration: UInt64 = 0

    var workspaceGitSummaryRefreshTasks: [String: Task<Void, Never>] = [:]

    var workspaceGitSummaryRefreshGeneration: [String: UInt64] = [:]
    var workspaceGitSummaryRefreshDebounce: Duration = .seconds(2)

#if DEBUG
    /// Set the server ID for screenshot preview harness (no real credentials needed).
    func setPreviewServerId(_ id: String) {
        currentServerId = id
        workspaceStore.setActiveServer(id)
    }

    /// Install a fixture-backed client so API-driven pages render without a server.
    func setPreviewAPIClient(_ client: APIClient) {
        apiClient = client
    }

    func setAPIClientForTesting(_ client: APIClient?) {
        installAPIClient(client)
    }

    func failTransportTerminallyForTesting() {
        route.invalidateTransportAfterTerminalFailure(
            APIError.server(status: 503, message: "test terminal failure")
        )
    }

    func setIconAssetCacheForTesting(_ cache: IconAssetCache?) {
        iconAssetCache = cache
    }

    func prepareFocusedSessionStreamEndpointForTesting(sessionId: String, workspaceId: String) {
        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, routeScope: .workspace(workspaceId))
    }

    func prepareFocusedSessionStreamEndpointForTesting(sessionId: String, routeScope: SessionRouteScope) {
        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, routeScope: routeScope)
    }

    func setSplitStreamCapabilitiesForTesting(
        sessionStream: Bool = true,
        dictationStream: Bool = false,
        appEventStream: Bool = false,
        durableSessions: Bool = false,
        conversationStream: Bool = false,
        conversationStreamVersion: Int = 1,
        speech: Bool = false,
        liveVoice: Bool = false,
        pushRelay: URL? = nil,
        extensionNativeUICapabilities: [String]? = nil
    ) {
        func version(_ enabled: Bool) -> ServerInfo.CapabilityVersion? {
            enabled ? ServerInfo.CapabilityVersion(version: 1) : nil
        }
        let capabilities = ServerInfo.Capabilities(
            sessionStream: version(sessionStream),
            dictationStream: version(dictationStream),
            appEventStream: version(appEventStream),
            extensionNativeUI: extensionNativeUICapabilities.map {
                ServerInfo.ExtensionNativeUICapability(version: 1, capabilities: $0)
            },
            durableSessions: version(durableSessions),
            conversationStream: conversationStream ? .init(version: conversationStreamVersion) : nil,
            speech: version(speech),
            liveVoice: version(liveVoice),
            pushNotifications: pushRelay.map {
                ServerInfo.PushNotificationsCapability(version: 1, relay: $0.absoluteString)
            }
        )
        serverCapabilities = capabilities
        dictationStreamUnsupportedByEndpoint = false
        missingRequiredSplitStreamCapabilities = capabilities.missingRequiredSplitStreamCapabilities
        streamCapabilitiesLoaded = true
    }
#endif
}

// MARK: - Route host

extension ServerConnection: ServerRouteHost {
    var hasConnectedPersistentStream: Bool {
        wsClient?.status == .connected || appEventStreamTransportState == .connected
    }

    func advanceSendGeneration() {
        sender.advanceTransportGeneration()
    }

    func makeCandidateClient(
        selection: EndpointSelection,
        credentials: ServerCredentials,
        availabilityObserver: @escaping APIClientAvailabilityObserver,
        factory: ServerConnectionAPIClientFactory
    ) -> APIClient {
        let client = factory(
            makeClientEnvironment(
                selection: selection,
                credentials: credentials,
                tlsCertFingerprint: credentials.normalizedTLSCertFingerprint
            ),
            availabilityObserver
        )
        attachHTTPAuthSession(to: client, credentials: credentials)
        return client
    }

    func installRoute(
        credentials: ServerCredentials,
        selection: EndpointSelection,
        apiClient: APIClient,
        serverInfo: ServerInfo,
        streamGeneration: UInt64
    ) {
        resetTransportState(
            credentials: credentials,
            endpointSelection: selection,
            transportPath: selection.transportPath
        )
        installAPIClient(apiClient)
        applyStreamCapabilities(serverInfo)

        // WebSocket composition is created only after authenticated bootstrap
        // succeeds and the exact winning API client is installed.
        let wsClient = WebSocketClient(
            credentials: credentials,
            preferredEndpoint: selection,
            diagnosticRole: "focused_session",
            diagnosticRemoteIdentity: nil,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            tlsServerName: selection.tlsServerName,
            authSession: httpAuthSession,
            tailnetRoute: route.configuredTailnetRoute
        )
        wsClient.onTransportHealthFailure = { @MainActor [weak self, weak wsClient] failure in
            guard let self,
                  let wsClient,
                  self.wsClient === wsClient else { return }
            await self.route.handlePersistentStreamHealthFailure(
                failure,
                expectedGeneration: streamGeneration
            )
        }
        self.wsClient = wsClient
        wsClient.setStreamURL(nil)
        sender.wsClient = wsClient
        sender.focusedSessionProvider = { [weak self] in
            self?.focusedSessionStore.focused
        }
        if appEventStreamAvailable {
            startAppEventStreamIfAvailable()
        }
    }

    func tearDownForRouteRebuild() -> (sessionId: String, routeScope: SessionRouteScope)? {
        let focusedTarget = focusedStreamBinder.boundTarget
        streamConsumptionTask?.cancel()
        streamConsumptionTask = nil
        wsClient?.disconnect()
        wsClient = nil
        disconnectAppEventStream()
        installAPIClient(nil)
        endpointSelection = nil
        return focusedTarget
    }

    func rebindAfterRouteRebuild(_ focusedTarget: (sessionId: String, routeScope: SessionRouteScope)?) {
        if let focusedTarget {
            prepareFocusedSessionStreamEndpoint(sessionId: focusedTarget.sessionId, routeScope: focusedTarget.routeScope)
            connectStream()
        }
        if appEventStreamAvailable { startAppEventStreamIfAvailable() }
    }

    func tearDownAfterTerminalFailure() {
        sender.advanceTransportGeneration()
        disconnectStream()
        disconnectAppEventStream()
        installAPIClient(nil)
        wsClient = nil
        endpointSelection = nil
    }

    func refreshListsAfterRouteRecovery() async {
        await refreshWorkspaceAndSessionLists(force: true, retryAfterJoinedFailure: true)
    }
}
