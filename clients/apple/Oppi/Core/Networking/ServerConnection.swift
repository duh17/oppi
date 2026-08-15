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
typealias ServerConnectionCredentialGrantObserver = @MainActor (CredentialTransportGrant) -> Void

private enum TransportFailureDisposition {
    case retryable
    case failClosed
}

enum IrohForegroundRecoveryResult: Equatable, Sendable {
    case notActive
    case retained
    case availabilityFailure
    case terminalFailure
}

private final class WeakAPIClientReference: @unchecked Sendable {
    weak var client: APIClient?
}

private struct PreparedIrohCandidate: Sendable {
    let manager: IrohConnectionManager?
    let selection: EndpointSelection
    let apiClient: APIClient
    let apiIdentity: UUID
    let serverInfo: ServerInfo
    let evidence: IrohSelectedPathEvidence?
}

private struct ForegroundIrohRebuild: Sendable {
    let selection: EndpointSelection
    let apiClient: APIClient
    let apiIdentity: UUID
    let serverInfo: ServerInfo
}

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

    // Networking
    private(set) var apiClient: APIClient?
    private(set) var iconAssetCache: IconAssetCache?
    private(set) var wsClient: WebSocketClient?
    private var irohManager: IrohConnectionManager?
    private var irohBackgroundPreparationTask: Task<Void, Never>?
    private var configuredIrohProxyFactory: (@MainActor (
        IrohServerTransport,
        String
    ) async throws -> (IrohConnectionManager?, URL))?
    private var configuredRouteMode: PairedServerRouteMode = .automatic
    private var usesSynchronousCompatibilityConfiguration = false
    private var configuredHTTPBootstrapDeadlineFactory: ServerConnectionBootstrapDeadlineFactory = {
        .after(ServerConnection.httpCandidateTimeoutDefault)
    }
    private var configuredIrohCandidateDeadlineFactory: ServerConnectionBootstrapDeadlineFactory = {
        .after(ServerConnection.irohReachabilityTimeoutDefault)
    }
    private var configuredAPIClientFactory: ServerConnectionAPIClientFactory = { environment, observer in
        APIClient(environment: environment, availabilityObserver: observer)
    }
    private var configuredServerInfoBootstrap: ServerConnectionInfoBootstrap = { client, deadline in
        try await client.serverInfo(bootstrapDeadline: deadline)
    }
    private var irohBoundaryReevaluationInFlight = false
    private var pendingBoundaryReevaluation = false
    private var pendingBoundaryExclusions: Set<ServerRouteCandidateKind> = []
    private var transportFailureDisposition: TransportFailureDisposition?
    private var configuredCredentialGrantObserver: ServerConnectionCredentialGrantObserver?

    var canAutomaticallyRetryInitialTransport: Bool {
        transportFailureDisposition != .failClosed
    }
    private var configuredIrohReachabilityTimeout = ServerConnection.irohReachabilityTimeoutDefault
    private var installedAPIClientIdentity: UUID?
    private var installedAPIClientConfigurationGeneration: UInt64?
    private var persistentHealthRecoveryTask: (id: UUID, task: Task<Void, Never>)?
    private var pendingPersistentHealthRecovery: (
        failure: PersistentStreamHealthFailure,
        expectedGeneration: UInt64?,
        failedRoute: ServerRouteCandidateKind?
    )?
    private var persistentStreamGeneration: UInt64 = 0
    private var automaticIrohRecoveryAttempt = 0
    private var automaticIrohRecoveryNextAllowedAt: Date?
    private var automaticIrohRecoveryRetryTask: Task<Void, Never>?
    private var lanCandidateGeneration: UInt64 = 0
    private var transportConfigurationGeneration: UInt64 = 0
    private var activeTransportConfigurationGenerations: Set<UInt64> = []
    private var supersededIrohManagers: [IrohConnectionManager] = []
    private var pendingSupersededManagerCleanup: (id: UUID, task: Task<Void, Never>)?
    var dictationStreamAvailable = false
    var appEventStreamAvailable = false
    private(set) var appEventStreamTransportState: ServerHealth.TransportState = .disconnected
    /// Identity of the current connected app-event window. Equality only.
    private(set) var appEventStreamConnectedAt: Date?
    var appEventListRepairFollowUpUsed = false
    var appEventListPendingExternalFailure = false
    /// Bumped when a repair owner is installed or the stream tears down so a
    /// cancelled owner's defer cannot clear a newer owner's slot.
    var appEventListRepairGeneration: UInt64 = 0
    private(set) var missingRequiredSplitStreamCapabilities: [String] = []
    private var streamCapabilitiesLoaded = false
    private var streamCapabilitiesRefreshFailed = false
    private var streamCapabilitiesRefreshTask: Task<Void, Never>?
    private var streamCapabilitiesGeneration: UInt64 = 0
    private(set) var focusedSessionStreamEndpointKind = "none"
    private var focusedSessionStreamSessionId: String?
    private var focusedSessionStreamWorkspaceId: String?
    private var focusedSessionStreamRouteScope: SessionRouteScope?
    private var focusedSessionStreamURL: URL?
    private(set) var transportPath: ConnectionTransportPath = .paired
    /// True while a route demotion/reconfigure has torn down composition and a
    /// replacement commit (or budgeted retry) is still outstanding. UI and stream
    /// open paths treat this as recovering, not settled offline-on-LAN.
    private(set) var isTransportDemoting = false

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
        if isTransportDemoting {
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

    /// Whether the server has server dictation configured (remote dictation server or another STT backend).
    /// Updated from server capabilities and `stream_connected` messages.
    private(set) var serverDictationAvailable = false
    private(set) var controlSessionsAvailable = false

    // Stores
    let sessionStore = SessionStore()
    let askRequestStore = AskRequestStore()
    let workspaceStore = WorkspaceStore()
    let serverResourceStore = ServerResourceStore()
    let gitStatusStore = GitStatusStore(environment: .app)
    let fileIndexStore = FileIndexStore(environment: .app)
    let messageQueueStore = MessageQueueStore(telemetry: .appMetrics)

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
    nonisolated static let httpCandidateTimeoutDefault: Duration = .milliseconds(1_500)
    nonisolated static let irohReachabilityTimeoutDefault: Duration = .seconds(8)
    nonisolated static let automaticIrohRecoveryMaximumAttempts = 5
    nonisolated static let automaticIrohRecoveryMaximumBackoff: TimeInterval = 16
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

    /// Test seam: replace WebSocket opening with a deterministic stream.
    var _connectStreamForTesting: (() -> AsyncStream<StreamFrameEvent>)?

    /// Test seam: observe app-event stream start without opening a real socket.
    var _startAppEventStreamForTesting: ((URL) -> Void)?

    /// Test seam: override the cache actor used by list refresh paths.
    var _cacheForTesting: TimelineCache?

    /// Test seam: observe view-driven session re-entry preparation.
    var _onPrepareForSessionReentryForTesting: ((String) -> Void)?

    /// Test seam: inspect bounded focus-arbitration telemetry.
    var _onFocusArbitrationForTesting: ((_ outcome: String, _ metadata: [String: String]) -> Void)?

    /// Test seam: replace compact sidebar Git summary HTTP fetches.
    var _getWorkspaceGitSummaryForTesting: ((String) async throws -> WorkspaceGitSummary)?

    #if DEBUG
    var _automaticIrohRecoveryNowForTesting: (() -> Date)?
    var _foregroundIrohProxyURLForTesting: (@MainActor (
        IrohConnectionManager,
        String
    ) async throws -> URL)?
    var _refreshAfterAutomaticIrohRecoveryForTesting: (() async -> Void)?
    var _onCommittedCompositionForTesting: ((ConnectionTransportPath) -> Void)?
    #endif

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

    /// Synchronous compatibility entry point for HTTP credentials and tests.
    /// Iroh setup must await an ephemeral listener; production callers use
    /// `configureForUse(credentials:)`.
    @discardableResult
    func configure(credentials: ServerCredentials) -> Bool {
        usesSynchronousCompatibilityConfiguration = true
        sender.advanceTransportGeneration()
        guard let selection = LANEndpointSelection.select(
            credentials: credentials,
            discoveredEndpoint: discoveredLANEndpoint
        ) else {
            if credentials.transports.authorizedTransports == [.iroh] {
                logger.error("Iroh configuration requires asynchronous proxy startup")
            } else {
                logger.error(
                    "Invalid server credentials: host=\(credentials.host) port=\(credentials.port)"
                )
            }
            return false
        }
        return configureHTTP(credentials: credentials, selection: selection)
    }

    /// Walk authorized candidates serially and commit only the first candidate
    /// that completes authenticated bootstrap. Candidate exclusions are local to
    /// this invocation and are never retained as route memory.
    @discardableResult
    func configureForUse(
        credentials: ServerCredentials,
        routeMode: PairedServerRouteMode = .automatic,
        excluding: Set<ServerRouteCandidateKind> = [],
        irohReachabilityTimeout: Duration = ServerConnection.irohReachabilityTimeoutDefault,
        httpBootstrapDeadline: @escaping ServerConnectionBootstrapDeadlineFactory = {
            .after(ServerConnection.httpCandidateTimeoutDefault)
        },
        irohCandidateDeadline: @escaping ServerConnectionBootstrapDeadlineFactory = {
            .after(ServerConnection.irohReachabilityTimeoutDefault)
        },
        apiClientFactory: @escaping ServerConnectionAPIClientFactory = { environment, observer in
            APIClient(environment: environment, availabilityObserver: observer)
        },
        serverInfoBootstrap: @escaping ServerConnectionInfoBootstrap = { client, deadline in
            try await client.serverInfo(bootstrapDeadline: deadline)
        },
        irohProxyFactory: @escaping @MainActor (IrohServerTransport, String) async throws -> (IrohConnectionManager?, URL) = { iroh, token in
            let (manager, url) = try await IrohTransportRegistry.shared.startProxy(iroh: iroh, token: token)
            return (manager, url)
        },
        credentialGrantDidChange: ServerConnectionCredentialGrantObserver? = nil
    ) async -> Bool {
        usesSynchronousCompatibilityConfiguration = false
        transportConfigurationGeneration &+= 1
        let configurationGeneration = transportConfigurationGeneration
        activeTransportConfigurationGenerations.insert(configurationGeneration)
        configuredRouteMode = routeMode.effective(for: credentials.transports.authorizedTransports)
        configuredIrohProxyFactory = irohProxyFactory
        configuredIrohReachabilityTimeout = irohReachabilityTimeout
        configuredHTTPBootstrapDeadlineFactory = httpBootstrapDeadline
        configuredIrohCandidateDeadlineFactory = irohCandidateDeadline
        configuredAPIClientFactory = apiClientFactory
        configuredServerInfoBootstrap = serverInfoBootstrap
        if let credentialGrantDidChange {
            configuredCredentialGrantObserver = credentialGrantDidChange
        }
        sender.advanceTransportGeneration()

        while let cleanup = pendingSupersededManagerCleanup {
            await cleanup.task.value
            if pendingSupersededManagerCleanup?.id == cleanup.id {
                pendingSupersededManagerCleanup = nil
            }
        }
        guard transportConfigurationGeneration == configurationGeneration else {
            return await finishTransportConfiguration(false, generation: configurationGeneration)
        }

        let result = await configureForUseAttempt(
            credentials: credentials,
            routeMode: configuredRouteMode,
            excluding: excluding,
            configurationGeneration: configurationGeneration,
            irohReachabilityTimeout: irohReachabilityTimeout,
            httpBootstrapDeadline: httpBootstrapDeadline,
            irohCandidateDeadline: irohCandidateDeadline,
            apiClientFactory: apiClientFactory,
            serverInfoBootstrap: serverInfoBootstrap,
            irohProxyFactory: irohProxyFactory
        )
        return await finishTransportConfiguration(result, generation: configurationGeneration)
    }

    /// Explicit Retry starts a fresh pass with no exclusions by default while
    /// preserving focused-session and app-event subscription intent.
    @discardableResult
    func reconfigureForExplicitRetry(
        credentials: ServerCredentials,
        routeMode: PairedServerRouteMode = .automatic,
        excluding: Set<ServerRouteCandidateKind> = [],
        irohReachabilityTimeout: Duration = ServerConnection.irohReachabilityTimeoutDefault,
        httpBootstrapDeadline: @escaping ServerConnectionBootstrapDeadlineFactory = {
            .after(ServerConnection.httpCandidateTimeoutDefault)
        },
        irohCandidateDeadline: @escaping ServerConnectionBootstrapDeadlineFactory = {
            .after(ServerConnection.irohReachabilityTimeoutDefault)
        },
        apiClientFactory: @escaping ServerConnectionAPIClientFactory = { environment, observer in
            APIClient(environment: environment, availabilityObserver: observer)
        },
        serverInfoBootstrap: @escaping ServerConnectionInfoBootstrap = { client, deadline in
            try await client.serverInfo(bootstrapDeadline: deadline)
        },
        irohProxyFactory: @escaping @MainActor (IrohServerTransport, String) async throws -> (IrohConnectionManager?, URL) = { iroh, token in
            let (manager, url) = try await IrohTransportRegistry.shared.startProxy(iroh: iroh, token: token)
            return (manager, url)
        },
        credentialGrantDidChange: ServerConnectionCredentialGrantObserver? = nil
    ) async -> Bool {
        automaticIrohRecoveryRetryTask?.cancel()
        automaticIrohRecoveryRetryTask = nil

        let focusedTarget = (
            sessionId: focusedSessionStreamSessionId,
            routeScope: focusedSessionStreamRouteScope
        )

        isTransportDemoting = true
        streamConsumptionTask?.cancel()
        streamConsumptionTask = nil
        wsClient?.disconnect()
        wsClient = nil
        disconnectAppEventStream()
        installAPIClient(nil)
        endpointSelection = nil
        let previousIrohManager = irohManager
        irohManager = nil
        await previousIrohManager?.shutdown()

        let configured = await configureForUse(
            credentials: credentials,
            routeMode: routeMode,
            excluding: excluding,
            irohReachabilityTimeout: irohReachabilityTimeout,
            httpBootstrapDeadline: httpBootstrapDeadline,
            irohCandidateDeadline: irohCandidateDeadline,
            apiClientFactory: apiClientFactory,
            serverInfoBootstrap: serverInfoBootstrap,
            irohProxyFactory: irohProxyFactory,
            credentialGrantDidChange: credentialGrantDidChange
        )
        guard configured else {
            // Leave `isTransportDemoting` set when the caller will schedule a
            // budgeted retry; clear it only when this was a terminal failed pass.
            return false
        }

        // Always reopen a prepared focused stream after route demotion. Sampling
        // the previous socket status is wrong on Wi‑Fi→cell handoff: the LAN WS
        // often reaches `.disconnected` before path monitor demotes the route.
        if let sessionId = focusedTarget.sessionId,
           let routeScope = focusedTarget.routeScope {
            prepareFocusedSessionStreamEndpoint(sessionId: sessionId, routeScope: routeScope)
            connectStream()
        }
        if appEventStreamAvailable {
            startAppEventStreamIfAvailable()
        }
        isTransportDemoting = false
        return true
    }

    private func configureForUseAttempt(
        credentials: ServerCredentials,
        routeMode: PairedServerRouteMode,
        excluding: Set<ServerRouteCandidateKind>,
        configurationGeneration: UInt64,
        irohReachabilityTimeout: Duration,
        httpBootstrapDeadline: @escaping ServerConnectionBootstrapDeadlineFactory,
        irohCandidateDeadline: @escaping ServerConnectionBootstrapDeadlineFactory,
        apiClientFactory: @escaping ServerConnectionAPIClientFactory,
        serverInfoBootstrap: @escaping ServerConnectionInfoBootstrap,
        irohProxyFactory: @escaping @MainActor (IrohServerTransport, String) async throws -> (IrohConnectionManager?, URL)
    ) async -> Bool {
        do {
            let candidates = try ServerTransportPlanResolver.candidates(
                credentials: credentials,
                mode: routeMode,
                discoveredLANEndpoint: discoveredLANEndpoint,
                excluding: excluding
            )
            for candidate in candidates {
                guard transportConfigurationGeneration == configurationGeneration else { return false }

                switch candidate {
                case .http(let selection):
                    let prepared = makeCandidateAPIClient(
                        credentials: credentials,
                        selection: selection,
                        tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
                        configurationGeneration: configurationGeneration,
                        apiClientFactory: apiClientFactory
                    )
                    do {
                        let info = try await serverInfoBootstrap(
                            prepared.client,
                            httpBootstrapDeadline()
                        )
                        guard transportConfigurationGeneration == configurationGeneration else { return false }
                        await commitCandidate(
                            credentials: credentials,
                            selection: selection,
                            manager: nil,
                            apiClient: prepared.client,
                            apiIdentity: prepared.identity,
                            serverInfo: info,
                            configurationGeneration: configurationGeneration
                        )
                        return true
                    } catch where isRouteAvailabilityFailure(error) {
                        continue
                    }

                case .iroh(let iroh):
                    try IrohPeerValidator.validate(iroh, requiredALPN: IrohTunnelProtocol.alpn)
                    var attemptedManager: IrohConnectionManager?
                    do {
                        let deadline = irohCandidateDeadline()
                        let operation = Task { @MainActor in
                            let (manager, localURL) = try await irohProxyFactory(iroh, credentials.token)
                            attemptedManager = manager
                            if Task.isCancelled {
                                await self.shutdownSetupManager(manager)
                                throw CancellationError()
                            }
                            let evidence = try await manager?.selectedPathEvidence(
                                timeout: irohReachabilityTimeout
                            )
                            if Task.isCancelled {
                                await self.shutdownSetupManager(manager)
                                throw CancellationError()
                            }
                            let selection = EndpointSelection(baseURL: localURL, transportPath: .iroh)
                            let api = self.makeCandidateAPIClient(
                                credentials: credentials,
                                selection: selection,
                                tlsCertFingerprint: nil,
                                configurationGeneration: configurationGeneration,
                                apiClientFactory: apiClientFactory
                            )
                            let info = try await serverInfoBootstrap(api.client, deadline)
                            if Task.isCancelled {
                                await self.shutdownSetupManager(manager)
                                throw CancellationError()
                            }
                            return PreparedIrohCandidate(
                                manager: manager,
                                selection: selection,
                                apiClient: api.client,
                                apiIdentity: api.identity,
                                serverInfo: info,
                                evidence: evidence
                            )
                        }
                        let prepared = try await waitForIrohCandidate(
                            operation,
                            deadline: deadline
                        )
                        guard transportConfigurationGeneration == configurationGeneration else {
                            queueSupersededIrohManager(prepared.manager)
                            return false
                        }
                        await commitCandidate(
                            credentials: credentials,
                            selection: prepared.selection,
                            manager: prepared.manager,
                            apiClient: prepared.apiClient,
                            apiIdentity: prepared.apiIdentity,
                            serverInfo: prepared.serverInfo,
                            configurationGeneration: configurationGeneration
                        )
                        ClientLog.info("Iroh", "Transparent tunnel selected", metadata: [
                            "transport": "iroh",
                            "path": prepared.evidence?.pathKind.rawValue ?? IrohPathKind.unknown.rawValue,
                            "rttMs": prepared.evidence.map { String($0.rttMs) } ?? "unknown",
                            "metadataVersion": String(iroh.version),
                            "addressMode": iroh.addressMode.rawValue,
                            "fallback": "none",
                        ])
                        return true
                    } catch let APIError.codedServer(_, _, code)
                        where code.removesIrohCredentialGrant {
                        await shutdownSetupManager(attemptedManager)
                        narrowIrohCredentialGrant(for: credentials)
                        return false
                    } catch where isRouteAvailabilityFailure(error) {
                        await shutdownSetupManager(attemptedManager)
                        continue
                    } catch {
                        await shutdownSetupManager(attemptedManager)
                        throw error
                    }
                }
            }

            transportFailureDisposition = .retryable
            logger.warning("Transport candidate pass exhausted")
            return false
        } catch is CancellationError {
            return false
        } catch {
            guard transportConfigurationGeneration == configurationGeneration else { return false }
            transportFailureDisposition = .failClosed
            let activeManager = irohManager
            irohManager = nil
            await shutdownSetupManager(activeManager)
            invalidateTransportAfterTerminalFailure(error)
            logger.error("Transport setup failed closed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func waitForIrohCandidate(
        _ operation: Task<PreparedIrohCandidate, Error>,
        deadline: APIClient.BootstrapDeadline
    ) async throws -> PreparedIrohCandidate {
        try await withThrowingTaskGroup(of: PreparedIrohCandidate.self) { group in
            group.addTask { try await operation.value }
            group.addTask {
                try await deadline.waitForExpiry()
                try Task.checkCancellation()
                throw URLError(.timedOut)
            }
            defer {
                group.cancelAll()
                operation.cancel()
            }
            guard let result = try await group.next() else {
                throw APIError.invalidResponse
            }
            return result
        }
    }

    private func waitForForegroundIrohRebuild(
        _ operation: Task<ForegroundIrohRebuild?, Error>,
        deadline: APIClient.BootstrapDeadline
    ) async throws -> ForegroundIrohRebuild? {
        try await withThrowingTaskGroup(of: ForegroundIrohRebuild?.self) { group in
            group.addTask { try await operation.value }
            group.addTask {
                try await deadline.waitForExpiry()
                try Task.checkCancellation()
                throw URLError(.timedOut)
            }
            defer {
                group.cancelAll()
                operation.cancel()
            }
            guard let result = try await group.next() else {
                throw APIError.invalidResponse
            }
            return result
        }
    }

    private func isRouteAvailabilityFailure(_ error: Error) -> Bool {
        ServerRouteFailure.mayAdvance(after: error)
    }

    private func queueSupersededIrohManager(_ manager: IrohConnectionManager?) {
        guard let manager,
              manager !== irohManager,
              !supersededIrohManagers.contains(where: { $0 === manager }) else {
            return
        }
        supersededIrohManagers.append(manager)
    }

    private func finishTransportConfiguration(_ result: Bool, generation: UInt64) async -> Bool {
        activeTransportConfigurationGenerations.remove(generation)
        await cleanupSupersededManagersIfIdle()
        return result
    }

    private func cleanupSupersededManagersIfIdle() async {
        guard activeTransportConfigurationGenerations.isEmpty else { return }

        let managers = supersededIrohManagers.filter { $0 !== irohManager }
        supersededIrohManagers.removeAll()
        guard !managers.isEmpty else { return }
        await runSerializedManagerCleanup {
            for manager in managers {
                await manager.shutdown()
            }
        }
    }

    private func shutdownSetupManager(_ manager: IrohConnectionManager?) async {
        guard let manager else { return }
        await runSerializedManagerCleanup {
            await manager.shutdown()
        }
    }

    private func runSerializedManagerCleanup(
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        let predecessor = pendingSupersededManagerCleanup?.task
        let cleanupID = UUID()
        let cleanupTask = Task {
            await predecessor?.value
            await operation()
        }
        pendingSupersededManagerCleanup = (cleanupID, cleanupTask)
        await cleanupTask.value
        if pendingSupersededManagerCleanup?.id == cleanupID {
            pendingSupersededManagerCleanup = nil
        }
    }

    private func configureHTTP(
        credentials: ServerCredentials,
        selection: EndpointSelection? = nil
    ) -> Bool {
        guard let selection = selection ?? LANEndpointSelection.select(
            credentials: credentials,
            discoveredEndpoint: discoveredLANEndpoint
        ) else {
            logger.error("Invalid server credentials: host=\(credentials.host) port=\(credentials.port)")
            return false
        }
        let prepared = makeCandidateAPIClient(
            credentials: credentials,
            selection: selection,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            configurationGeneration: transportConfigurationGeneration,
            apiClientFactory: configuredAPIClientFactory
        )
        irohManager = nil
        configureClients(
            credentials: credentials,
            selection: selection,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            apiClient: prepared.client,
            apiIdentity: prepared.identity,
            serverInfo: nil,
            configurationGeneration: transportConfigurationGeneration
        )
        return true
    }

    private func makeCandidateAPIClient(
        credentials: ServerCredentials,
        selection: EndpointSelection,
        tlsCertFingerprint: String?,
        configurationGeneration: UInt64,
        apiClientFactory: ServerConnectionAPIClientFactory
    ) -> (client: APIClient, identity: UUID) {
        let identity = UUID()
        let reference = WeakAPIClientReference()
        let observer: APIClientAvailabilityObserver = { [weak self, reference] failure in
            guard let client = reference.client else { return }
            await self?.handleAPIClientAvailabilityFailure(
                failure,
                client: client,
                identity: identity,
                configurationGeneration: configurationGeneration
            )
        }
        let client = apiClientFactory(
            makeClientEnvironment(
                selection: selection,
                credentials: credentials,
                tlsCertFingerprint: tlsCertFingerprint
            ),
            observer
        )
        reference.client = client
        client.setResponseFailureObserver { [weak self, reference] error in
            guard let client = reference.client else { return }
            await self?.handleAPIClientResponseFailure(
                error,
                client: client,
                identity: identity,
                configurationGeneration: configurationGeneration
            )
        }
        return (client, identity)
    }

    private func commitCandidate(
        credentials: ServerCredentials,
        selection: EndpointSelection,
        manager: IrohConnectionManager?,
        apiClient: APIClient,
        apiIdentity: UUID,
        serverInfo: ServerInfo,
        configurationGeneration: UInt64
    ) async {
        let previousManager = irohManager
        if previousManager !== manager {
            await shutdownSetupManager(previousManager)
        }
        await installActiveIrohFailureHandler(on: manager)
        irohManager = manager
        configureClients(
            credentials: credentials,
            selection: selection,
            tlsCertFingerprint: selection.transportPath == .iroh
                ? nil
                : credentials.normalizedTLSCertFingerprint,
            apiClient: apiClient,
            apiIdentity: apiIdentity,
            serverInfo: serverInfo,
            configurationGeneration: configurationGeneration
        )
    }

    private func configureClients(
        credentials: ServerCredentials,
        selection: EndpointSelection,
        tlsCertFingerprint: String?,
        apiClient: APIClient,
        apiIdentity: UUID,
        serverInfo: ServerInfo?,
        configurationGeneration: UInt64
    ) {
        persistentStreamGeneration &+= 1
        let clientGeneration = persistentStreamGeneration
        transportFailureDisposition = nil
        resetTransportState(
            credentials: credentials,
            endpointSelection: selection,
            transportPath: selection.transportPath
        )
        installedAPIClientIdentity = apiIdentity
        installedAPIClientConfigurationGeneration = configurationGeneration
        installAPIClient(apiClient)
        if let serverInfo {
            applyStreamCapabilities(serverInfo, startAppEventStream: false)
        }

        // WebSocket composition is created only after authenticated bootstrap
        // succeeds and the exact winning API client is installed.
        let wsClient = WebSocketClient(
            credentials: credentials,
            preferredEndpoint: selection,
            diagnosticRole: "focused_session",
            diagnosticRemoteIdentity: selection.transportPath == .iroh ? "iroh" : nil,
            tlsCertFingerprint: tlsCertFingerprint,
            tlsServerName: selection.tlsServerName
        )
        wsClient.onTransportHealthFailure = { @MainActor [weak self, weak wsClient] failure in
            guard let self,
                  let wsClient,
                  self.wsClient === wsClient else { return }
            await self.handlePersistentStreamHealthFailure(
                failure,
                expectedGeneration: clientGeneration
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
        #if DEBUG
        _onCommittedCompositionForTesting?(selection.transportPath)
        #endif
    }

    private func resetTransportState(
        credentials: ServerCredentials,
        endpointSelection: EndpointSelection?,
        transportPath: ConnectionTransportPath
    ) {
        disconnectAppEventStream()
        streamCapabilitiesRefreshTask?.cancel()
        streamCapabilitiesRefreshTask = nil
        workspaceGitSummaryRefreshTasks.values.forEach { $0.cancel() }
        workspaceGitSummaryRefreshTasks.removeAll()
        workspaceGitSummaryRefreshGeneration.removeAll()
        streamCapabilitiesGeneration &+= 1

        self.credentials = credentials
        self.currentServerId = credentials.normalizedServerFingerprint
        if let serverId = credentials.normalizedServerFingerprint {
            self.serverResourceStore.switchServer(to: serverId)
        }
        self.endpointSelection = endpointSelection
        self.dictationStreamAvailable = false
        self.appEventStreamAvailable = false
        self.appEventStreamTransportState = .disconnected
        self.missingRequiredSplitStreamCapabilities = []
        self.streamCapabilitiesLoaded = false
        self.streamCapabilitiesRefreshFailed = false
        self.clearFocusedSessionStreamEndpoint()
        self.transportPath = transportPath
    }

    private func installAPIClient(_ client: APIClient?) {
        // Route epoch + stream teardown are one structural invariant: any new
        // API client invalidates in-flight list work and the app-event window.
        listRefreshGeneration &+= 1
        sessionListRefreshTask?.cancel()
        sessionListRefreshTask = nil
        workspaceCatalogRefreshTask?.cancel()
        workspaceCatalogRefreshTask = nil
        disconnectAppEventStream()
        if client == nil {
            installedAPIClientIdentity = nil
            installedAPIClientConfigurationGeneration = nil
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
            bearerToken: credentials.token,
            pinnedCertificateFingerprint: selection.transportPath == .iroh
                ? nil
                : (tlsCertFingerprint ?? credentials.normalizedTLSCertFingerprint),
            tlsServerName: selection.tlsServerName,
            processOwnership: .clientOnly
        )
    }

    func fetchSessionAttachmentWhenReady(
        sessionId: String,
        attachmentId: String,
        routeScope: SessionRouteScope? = nil
    ) async throws -> Data {
        let apiClient = try await waitForAPIClient()
        return try await apiClient.fetchSessionAttachment(
            scope: routeScope,
            sessionId: sessionId,
            attachmentId: attachmentId
        )
    }

    func makeSessionAttachmentMediaSourceWhenReady(
        sessionId: String,
        attachmentId: String,
        contentTypeHint: String?,
        sourceFileExtension: String?,
        routeScope: SessionRouteScope? = nil
    ) async throws -> AuthenticatedMediaSource {
        let apiClient = try await waitForAPIClient()
        return try await apiClient.makeSessionAttachmentMediaSource(
            scope: routeScope,
            sessionId: sessionId,
            attachmentId: attachmentId,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    func fetchSessionFileDataWhenReady(
        workspaceId: String?,
        sessionId: String,
        path: String
    ) async throws -> Data {
        let context = try await waitForSessionFileContext(
            workspaceId: workspaceId,
            sessionId: sessionId
        )
        return try await context.apiClient.getSessionFileData(
            workspaceId: context.workspaceId,
            sessionId: sessionId,
            path: path
        )
    }

    func makeSessionFileMediaSourceWhenReady(
        workspaceId: String?,
        sessionId: String,
        path: String,
        contentTypeHint: String?,
        sourceFileExtension: String?
    ) async throws -> AuthenticatedMediaSource {
        let context = try await waitForSessionFileContext(
            workspaceId: workspaceId,
            sessionId: sessionId
        )
        return try await context.apiClient.makeSessionFileMediaSource(
            workspaceId: context.workspaceId,
            sessionId: sessionId,
            path: path,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    private func waitForAPIClient() async throws -> APIClient {
        for _ in 0..<50 {
            if let apiClient {
                return apiClient
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }

        throw APIError.server(status: 503, message: "Server client is not ready")
    }

    private func waitForSessionFileContext(
        workspaceId: String?,
        sessionId: String
    ) async throws -> (apiClient: APIClient, workspaceId: String) {
        for _ in 0..<50 {
            let resolvedWorkspaceId = normalizedWorkspaceId(workspaceId)
                ?? normalizedWorkspaceId(sessionStore.workspaceId(for: sessionId))
            if let apiClient, let resolvedWorkspaceId {
                return (apiClient, resolvedWorkspaceId)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }

        throw APIError.server(status: 503, message: "Session file client is not ready")
    }

    @discardableResult
    func setDiscoveredLANEndpoint(
        _ endpoint: LANDiscoveredEndpoint?
    ) -> Task<Void, Never>? {
        guard endpoint != discoveredLANEndpoint else { return nil }
        discoveredLANEndpoint = endpoint
        lanCandidateGeneration &+= 1
        guard transportFailureDisposition != .failClosed else { return nil }
        guard let credentials,
              configuredRouteMode.requestedTransports.contains(.https),
              credentials.transports.authorizedTransports.contains(.https) else {
            return nil
        }

        if usesSynchronousCompatibilityConfiguration, endpoint == nil, transportPath == .lan {
            guard let paired = LANEndpointSelection.select(
                credentials: credentials,
                discoveredEndpoint: nil
            ) else { return nil }
            sender.advanceTransportGeneration()
            _ = configureHTTP(credentials: credentials, selection: paired)
            return nil
        }

        if let endpoint,
           let candidate = LANEndpointSelection.select(
               credentials: credentials,
               discoveredEndpoint: endpoint
           ), endpointSelection == candidate {
            return nil
        }
        guard endpoint != nil || transportPath == .lan else {
            // Healthy paired/Iroh routes stay sticky when Bonjour disappears.
            return nil
        }

        let exclusions: Set<ServerRouteCandidateKind> = endpoint == nil ? [.lan] : []
        return Task { @MainActor [weak self] in
            await self?.reevaluateIrohPreferredTransportAtBoundary(excluding: exclusions)
        }
    }

    #if DEBUG
    func _adoptVerifiedLANEndpointForTesting(_ endpoint: LANDiscoveredEndpoint) {
        guard let credentials,
              let selection = LANEndpointSelection.select(
                  credentials: credentials,
                  discoveredEndpoint: endpoint
              ), selection.transportPath == .lan else { return }
        discoveredLANEndpoint = endpoint
        lanCandidateGeneration &+= 1
        sender.advanceTransportGeneration()
        let prepared = makeCandidateAPIClient(
            credentials: credentials,
            selection: selection,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            configurationGeneration: transportConfigurationGeneration,
            apiClientFactory: configuredAPIClientFactory
        )
        configureClients(
            credentials: credentials,
            selection: selection,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            apiClient: prepared.client,
            apiIdentity: prepared.identity,
            serverInfo: nil,
            configurationGeneration: transportConfigurationGeneration
        )
    }
    #endif

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

        if transportFailureDisposition == .failClosed {
            discoveredLANEndpoint = nil
            return
        }

        if wasOnLAN {
            // LAN is tied to this network context. Stop burning reconnect
            // attempts against the dead private IP immediately, then start one
            // fresh selection pass (paired HTTPS / Iroh). Stream rebind happens
            // inside reconfigureForExplicitRetry once the next route commits.
            isTransportDemoting = true
            streamConsumptionTask?.cancel()
            streamConsumptionTask = nil
            if let wsClient {
                wsClient.cancelReconnectBackoff()
                wsClient.disconnect()
            }

            let transition = setDiscoveredLANEndpoint(nil)
            if transition == nil {
                if apiClient != nil {
                    // Synchronous HTTP seam already rebound composition.
                    isTransportDemoting = false
                } else {
                    // Endpoint already cleared or HTTPS not currently requested — still
                    // force a demotion pass so we do not return with the socket down
                    // and no replacement scheduled.
                    Task { @MainActor [weak self] in
                        await self?.reevaluateIrohPreferredTransportAtBoundary(excluding: [.lan])
                    }
                }
            }
            return
        }

        if apiClient == nil {
            Task { @MainActor [weak self] in
                await self?.reevaluateIrohPreferredTransportAtBoundary()
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
        pathChangeMetadata.merge(diagnosticEndpointMetadata(focusedSessionStreamURL, prefix: "stream")) { current, _ in current }
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

                self.applyStreamCapabilities(info, startAppEventStream: true)
            } catch {
                guard self.streamCapabilitiesGeneration == generation else { return }
                // Do not let a transient handoff failure permanently poison stream
                // capability state. If we already had a good capability snapshot,
                // keep using it; otherwise leave the state unloaded so the next
                // session entry retries /server/info instead of returning nil forever.
                self.streamCapabilitiesRefreshFailed = true
                if !hadLoadedCapabilities {
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
                let apiBaseURL = apiClient.baseURL
                metadata.merge(self.diagnosticEndpointMetadata(apiBaseURL, prefix: "api")) { current, _ in current }
                ClientLog.warning("Network", "Stream capability refresh failed", metadata: metadata)
            }
        }

        streamCapabilitiesRefreshTask = task
        await task.value
    }

    private func applyStreamCapabilities(
        _ info: ServerInfo,
        startAppEventStream: Bool
    ) {
        let capabilities = info.capabilities
        dictationStreamAvailable = capabilities?.dictationStream?.version ?? 0 >= 1
        appEventStreamAvailable = capabilities?.appEventStream?.version ?? 0 >= 1
        controlSessionsAvailable = capabilities?.controlSessions?.version ?? 0 >= 1
        missingRequiredSplitStreamCapabilities = ServerInfo.Capabilities
            .missingRequiredSplitStreamCapabilities(in: capabilities)
        streamCapabilitiesRefreshFailed = false
        streamCapabilitiesLoaded = true
        if dictationStreamAvailable {
            setServerDictationAvailableFromCapabilities(true)
        }
        if startAppEventStream {
            if appEventStreamAvailable {
                startAppEventStreamIfAvailable()
            } else {
                disconnectAppEventStream()
            }
        }
    }

    /// Reconsider authorized routes only at an explicit network or foreground
    /// boundary. A healthy route remains sticky between these boundaries,
    /// preventing timer-driven transport oscillation.
    func reevaluateIrohPreferredTransportAtBoundary(
        excluding explicitExclusions: Set<ServerRouteCandidateKind> = []
    ) async {
        guard let credentials else { return }

        var exclusions = explicitExclusions

        // Healthy paired and Iroh routes own network mobility. A no-op
        // boundary stays sticky unless verified LAN appeared or the caller
        // identifies a failed route for this pass.
        let hasVerifiedLANCandidate = LANEndpointSelection.select(
            credentials: credentials,
            discoveredEndpoint: discoveredLANEndpoint
        )?.transportPath == .lan
        let hasLiveComposition = apiClient != nil
        if hasLiveComposition,
           exclusions.isEmpty,
           transportPath != .lan,
           !hasVerifiedLANCandidate {
            return
        }
        if hasLiveComposition,
           exclusions.isEmpty,
           transportPath == .lan,
           endpointSelection == LANEndpointSelection.select(
               credentials: credentials,
               discoveredEndpoint: discoveredLANEndpoint
           ) {
            return
        }
        if transportPath == .lan, discoveredLANEndpoint == nil {
            exclusions.insert(.lan)
        }

        if irohBoundaryReevaluationInFlight {
            pendingBoundaryReevaluation = true
            pendingBoundaryExclusions.formUnion(exclusions)
            return
        }

        irohBoundaryReevaluationInFlight = true
        defer { irohBoundaryReevaluationInFlight = false }

        var nextExclusions = exclusions
        var demotionSucceeded = false
        repeat {
            pendingBoundaryReevaluation = false
            pendingBoundaryExclusions.removeAll()
            demotionSucceeded = await reconfigureForExplicitRetry(
                credentials: credentials,
                routeMode: configuredRouteMode,
                excluding: nextExclusions,
                irohReachabilityTimeout: configuredIrohReachabilityTimeout,
                httpBootstrapDeadline: configuredHTTPBootstrapDeadlineFactory,
                irohCandidateDeadline: configuredIrohCandidateDeadlineFactory,
                apiClientFactory: configuredAPIClientFactory,
                serverInfoBootstrap: configuredServerInfoBootstrap,
                irohProxyFactory: configuredIrohProxyFactory ?? { _, _ in
                    throw IrohTransportError.unavailable("Iroh proxy factory unavailable")
                }
            )
            nextExclusions = pendingBoundaryExclusions
        } while pendingBoundaryReevaluation || !nextExclusions.isEmpty

        if demotionSucceeded {
            return
        }
        // Boundary demotion tore composition down and failed to commit a
        // replacement. Arm the shared automatic recovery budget instead of
        // settling with nil clients until the user taps Retry.
        scheduleAutomaticRecoveryAfterFailedDemotion(credentials: credentials)
    }

    private func scheduleAutomaticRecoveryAfterFailedDemotion(credentials: ServerCredentials) {
        guard canAutomaticallyRetryInitialTransport else {
            isTransportDemoting = false
            return
        }
        if automaticIrohRecoveryAttempt == 0 {
            guard reserveAutomaticIrohRecoveryAttempt() else {
                isTransportDemoting = false
                return
            }
        } else if automaticIrohRecoveryAttempt >= Self.automaticIrohRecoveryMaximumAttempts {
            isTransportDemoting = false
            return
        } else if automaticIrohRecoveryNextAllowedAt == nil {
            automaticIrohRecoveryNextAllowedAt = automaticIrohRecoveryNow().addingTimeInterval(
                Self.automaticIrohRecoveryBackoff(attempt: automaticIrohRecoveryAttempt)
            )
        }
        // Keep demoting=true while a budgeted retry is outstanding.
        isTransportDemoting = true
        scheduleAutomaticIrohRecoveryRetry(credentials: credentials)
    }

    private func installActiveIrohFailureHandler(
        on manager: IrohConnectionManager?
    ) async {
        guard let manager else { return }
        await manager.setAvailabilityFailureHandlers(
            tunnelOpen: { @MainActor [weak self, weak manager] in
                guard let self,
                      let manager,
                      self.irohManager === manager,
                      self.transportPath == .iroh else {
                    return
                }
                ClientLog.warning("Iroh", "Active tunnel unavailable; recovering transport", metadata: [
                    "transport": "iroh",
                    "fallback": "pending",
                ])
                await self.handlePersistentStreamHealthFailure(
                    .tunnelOpenFailure,
                    expectedGeneration: self.persistentStreamGeneration
                )
            },
            establishedStream: { @MainActor [weak self, weak manager] in
                guard let self,
                      let manager,
                      self.irohManager === manager,
                      self.transportPath == .iroh else {
                    return
                }
                await self.handlePersistentStreamHealthFailure(
                    .establishedStreamFailure,
                    expectedGeneration: self.persistentStreamGeneration
                )
            }
        )
    }

    private func handleAPIClientAvailabilityFailure(
        _ failure: APIClientAvailabilityFailure,
        client: APIClient,
        identity: UUID,
        configurationGeneration: UInt64
    ) async {
        guard apiClient === client,
              installedAPIClientIdentity == identity,
              installedAPIClientConfigurationGeneration == configurationGeneration,
              transportConfigurationGeneration == configurationGeneration,
              transportFailureDisposition != .failClosed else {
            return
        }

        // The failed operation is not replayed. Recovery only prepares a route
        // for future work and is coalesced with stream/Iroh health failures.
        await handlePersistentStreamHealthFailure(
            .reconnectThreshold(attempt: 0),
            expectedGeneration: persistentStreamGeneration,
            failedRoute: routeCandidateKind(for: transportPath)
        )
    }

    private func handleAPIClientResponseFailure(
        _ error: APIError,
        client: APIClient,
        identity: UUID,
        configurationGeneration: UInt64
    ) async {
        guard apiClient === client,
              installedAPIClientIdentity == identity,
              installedAPIClientConfigurationGeneration == configurationGeneration,
              transportConfigurationGeneration == configurationGeneration else {
            return
        }
        guard case .codedServer(_, _, let code) = error else { return }

        if code.removesIrohCredentialGrant, let credentials {
            narrowIrohCredentialGrant(for: credentials)
            await handlePersistentStreamHealthFailure(
                .reconnectThreshold(attempt: 0),
                expectedGeneration: persistentStreamGeneration,
                failedRoute: .iroh
            )
            return
        }

        let activeManager = irohManager
        irohManager = nil
        await shutdownSetupManager(activeManager)
        invalidateTransportAfterTerminalFailure(error)
    }

    private func narrowIrohCredentialGrant(for credentials: ServerCredentials) {
        var grant = credentials.credentialGrant
            ?? .inferred(from: credentials.transports.authorizedTransports)
        grant.remove(.iroh)
        if self.credentials?.token == credentials.token {
            self.credentials = credentials.withCredentialGrant(grant)
        }
        configuredCredentialGrantObserver?(grant)
        transportFailureDisposition = .retryable
        ClientLog.warning("Iroh", "Credential no longer authorizes Iroh", metadata: [
            "transport": "iroh",
            "repair": "pairing_required",
        ])
    }

    func handlePersistentStreamHealthFailure(
        _ failure: PersistentStreamHealthFailure,
        expectedGeneration: UInt64? = nil,
        failedRoute: ServerRouteCandidateKind? = nil
    ) async {
        guard expectedGeneration == nil || expectedGeneration == persistentStreamGeneration else {
            return
        }
        let route = failedRoute ?? routeCandidateKind(for: transportPath)

        if persistentHealthRecoveryTask != nil {
            // Do not await the in-flight task here. APIClient can report a
            // failure from a refresh owned by that same recovery task; awaiting
            // itself would deadlock. The owner loop drains this one follow-up.
            pendingPersistentHealthRecovery = (failure, expectedGeneration, route)
            return
        }

        let recoveryID = UUID()
        let recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var request: (
                failure: PersistentStreamHealthFailure,
                expectedGeneration: UInt64?,
                failedRoute: ServerRouteCandidateKind?
            )? = (failure, expectedGeneration, route)
            while let current = request {
                if current.expectedGeneration == nil ||
                    current.expectedGeneration == self.persistentStreamGeneration {
                    await self.performPersistentStreamHealthRecovery(
                        current.failure,
                        failedRoute: current.failedRoute
                    )
                }
                request = self.pendingPersistentHealthRecovery
                self.pendingPersistentHealthRecovery = nil
            }
            if self.persistentHealthRecoveryTask?.id == recoveryID {
                self.persistentHealthRecoveryTask = nil
            }
        }
        persistentHealthRecoveryTask = (recoveryID, recoveryTask)
        await recoveryTask.value
    }

    private func performPersistentStreamHealthRecovery(
        _ failure: PersistentStreamHealthFailure,
        failedRoute: ServerRouteCandidateKind?
    ) async {
        guard transportFailureDisposition != .failClosed, credentials != nil else { return }
        let route = failedRoute ?? routeCandidateKind(for: transportPath)

        ClientLog.warning("Network", "Persistent transport reported unavailable", metadata: [
            "transport": transportPath.rawValue,
            "reason": persistentStreamHealthReason(failure),
        ])

        if route == .lan {
            discoveredLANEndpoint = nil
            lanCandidateGeneration &+= 1
        }
        await performAutomaticRouteRecovery(excluding: [route])
    }

    private func routeCandidateKind(
        for path: ConnectionTransportPath
    ) -> ServerRouteCandidateKind {
        switch path {
        case .lan: .lan
        case .paired: .paired
        case .iroh: .iroh
        }
    }

    private func persistentStreamHealthReason(
        _ failure: PersistentStreamHealthFailure
    ) -> String {
        switch failure {
        case .tunnelOpenFailure:
            "tunnel_open_failure"
        case .establishedStreamFailure:
            "established_stream_failure"
        case .pingTimeout:
            "ping_timeout"
        case .pingFailures:
            "ping_failure"
        case .reconnectThreshold(let attempt):
            attempt == 0 ? "http_availability_failure" : "reconnect_threshold"
        }
    }

    private func performAutomaticRouteRecovery(
        excluding: Set<ServerRouteCandidateKind>
    ) async {
        guard let credentials,
              let factory = configuredIrohProxyFactory else {
            return
        }
        guard reserveAutomaticIrohRecoveryAttempt() else {
            if automaticIrohRecoveryAttempt < Self.automaticIrohRecoveryMaximumAttempts {
                scheduleAutomaticIrohRecoveryRetry(credentials: credentials)
            }
            return
        }

        let attempt = automaticIrohRecoveryAttempt
        let configured = await reconfigureForExplicitRetry(
            credentials: credentials,
            routeMode: configuredRouteMode,
            excluding: excluding,
            irohReachabilityTimeout: configuredIrohReachabilityTimeout,
            httpBootstrapDeadline: configuredHTTPBootstrapDeadlineFactory,
            irohCandidateDeadline: configuredIrohCandidateDeadlineFactory,
            apiClientFactory: configuredAPIClientFactory,
            serverInfoBootstrap: configuredServerInfoBootstrap,
            irohProxyFactory: factory
        )
        guard self.credentials == credentials else { return }

        guard configured else {
            if canAutomaticallyRetryInitialTransport,
               automaticIrohRecoveryAttempt < Self.automaticIrohRecoveryMaximumAttempts {
                isTransportDemoting = true
                scheduleAutomaticIrohRecoveryRetry(credentials: credentials)
            } else {
                automaticIrohRecoveryRetryTask?.cancel()
                automaticIrohRecoveryRetryTask = nil
                isTransportDemoting = false
            }
            return
        }

        #if DEBUG
        if let refresh = _refreshAfterAutomaticIrohRecoveryForTesting {
            await refresh()
        } else {
            // Only recovery may retry once after joining a failed pre-recovery pass.
            await refreshWorkspaceAndSessionLists(force: true, retryAfterJoinedFailure: true)
        }
        #else
        await refreshWorkspaceAndSessionLists(force: true, retryAfterJoinedFailure: true)
        #endif

        if transportPath != .iroh,
           !workspaceStore.lastSyncFailed,
           !sessionStore.lastSyncFailed {
            noteAutomaticIrohRecoverySucceeded()
        }
        ClientLog.info("Network", "Automatic route recovery completed", metadata: [
            "transport": transportPath.rawValue,
            "attempt": Self.automaticIrohRecoveryAttemptTag(attempt),
        ])
    }

    /// A scheduled retry is a new selection pass and therefore starts with no
    /// exclusions. This is what makes route demotion pass-local.
    private func performAutomaticIrohFullReconfiguration() async {
        await performAutomaticRouteRecovery(excluding: [])
    }

    private func reserveAutomaticIrohRecoveryAttempt() -> Bool {
        guard automaticIrohRecoveryAttempt < Self.automaticIrohRecoveryMaximumAttempts else {
            ClientLog.warning("Iroh", "Automatic transport rebuild budget exhausted", metadata: [
                "transport": transportPath.rawValue,
                "recovery": "full_reconfigure",
                "attempt": Self.automaticIrohRecoveryAttemptTag(automaticIrohRecoveryAttempt),
            ])
            return false
        }

        let now = automaticIrohRecoveryNow()
        if let nextAllowedAt = automaticIrohRecoveryNextAllowedAt,
           now < nextAllowedAt {
            ClientLog.info("Iroh", "Automatic transport rebuild remains in backoff", metadata: [
                "transport": transportPath.rawValue,
                "recovery": "full_reconfigure",
                "attempt": Self.automaticIrohRecoveryAttemptTag(automaticIrohRecoveryAttempt),
            ])
            return false
        }

        automaticIrohRecoveryAttempt += 1
        automaticIrohRecoveryNextAllowedAt = now.addingTimeInterval(
            Self.automaticIrohRecoveryBackoff(attempt: automaticIrohRecoveryAttempt)
        )
        automaticIrohRecoveryRetryTask?.cancel()
        automaticIrohRecoveryRetryTask = nil
        return true
    }

    private func scheduleAutomaticIrohRecoveryRetry(credentials: ServerCredentials) {
        guard automaticIrohRecoveryAttempt < Self.automaticIrohRecoveryMaximumAttempts,
              automaticIrohRecoveryRetryTask == nil,
              let nextAllowedAt = automaticIrohRecoveryNextAllowedAt else {
            return
        }
        let configurationGeneration = transportConfigurationGeneration
        let delay = max(0, nextAllowedAt.timeIntervalSince(automaticIrohRecoveryNow()))
        automaticIrohRecoveryRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.credentials == credentials,
                  self.transportConfigurationGeneration == configurationGeneration else {
                return
            }
            self.automaticIrohRecoveryRetryTask = nil
            await self.performAutomaticIrohFullReconfiguration()
        }
    }

    private func noteAutomaticIrohRecoverySucceeded() {
        automaticIrohRecoveryAttempt = 0
        automaticIrohRecoveryNextAllowedAt = nil
        automaticIrohRecoveryRetryTask?.cancel()
        automaticIrohRecoveryRetryTask = nil
        isTransportDemoting = false
    }

    private func automaticIrohRecoveryNow() -> Date {
        #if DEBUG
        if let now = _automaticIrohRecoveryNowForTesting {
            return now()
        }
        #endif
        return Date()
    }

    nonisolated static func automaticIrohRecoveryBackoff(attempt: Int) -> TimeInterval {
        switch attempt {
        case ..<2: 1
        case 2: 2
        case 3: 4
        case 4: 8
        default: automaticIrohRecoveryMaximumBackoff
        }
    }

    nonisolated private static func automaticIrohRecoveryAttemptTag(_ attempt: Int) -> String {
        String(min(automaticIrohRecoveryMaximumAttempts, max(1, attempt)))
    }

    private func invalidateTransportAfterTerminalFailure(_ error: Error) {
        sender.advanceTransportGeneration()
        disconnectStream()
        disconnectAppEventStream()
        installAPIClient(nil)
        wsClient = nil
        endpointSelection = nil
        irohManager = nil
        isTransportDemoting = false
        transportFailureDisposition = .failClosed
        ClientLog.error("Network", "Terminal transport failure; fallback disabled", metadata: [
            "transport": transportPath.rawValue,
            "errorKind": IrohTransportTelemetry.errorKind(error),
        ])
    }

    /// Recycle an active Iroh endpoint in place after real suspension. Healthy
    /// paired routes do nothing here; alternatives are walked only when this
    /// in-place proof reports an availability failure.
    func resetIrohTransportForForegroundRecoveryIfNeeded() async -> IrohForegroundRecoveryResult {
        guard transportPath == .iroh,
              let credentials,
              let manager = irohManager else {
            return .notActive
        }

        // Fence mutations against the generation that owned this attempt so a
        // concurrent reconfigure is neither overwritten nor terminally invalidated.
        let configurationGeneration = transportConfigurationGeneration
        let expectedCredentials = credentials
        let expectedManager = manager
        let stillCurrent = { [self] in
            self.transportConfigurationGeneration == configurationGeneration
                && self.credentials == expectedCredentials
                && self.irohManager === expectedManager
                && self.transportPath == .iroh
                && self.transportFailureDisposition != .failClosed
        }

        if let backgroundPreparation = irohBackgroundPreparationTask {
            await backgroundPreparation.value
            irohBackgroundPreparationTask = nil
        }
        guard stillCurrent() else { return .notActive }

        let focusedTarget = (
            sessionId: focusedSessionStreamSessionId,
            routeScope: focusedSessionStreamRouteScope
        )
        let shouldReconnectFocused = focusedTarget.sessionId.map { sessionId in
            hasActiveFocusedSessionStreamTransport()
                || sessionEventContinuations[sessionId] != nil
        } ?? false

        disconnectAppEventStream()
        streamConsumptionTask?.cancel()
        streamConsumptionTask = nil
        wsClient?.disconnect()

        do {
            let deadline = configuredIrohCandidateDeadlineFactory()
            let operation = Task { @MainActor () async throws -> ForegroundIrohRebuild? in
                try await manager.recycleEndpointAfterSuspension(
                    timeout: self.configuredIrohReachabilityTimeout
                )
                _ = try await manager.selectedPathEvidence(
                    timeout: self.configuredIrohReachabilityTimeout
                )
                try Task.checkCancellation()
                guard stillCurrent() else { throw CancellationError() }
                let localURL: URL
                #if DEBUG
                if let proxyURLForTesting = self._foregroundIrohProxyURLForTesting {
                    localURL = try await proxyURLForTesting(manager, credentials.token)
                } else {
                    localURL = try await manager.startProxy(token: credentials.token)
                }
                #else
                localURL = try await manager.startProxy(token: credentials.token)
                #endif
                try Task.checkCancellation()
                guard stillCurrent() else { throw CancellationError() }
                guard localURL != self.endpointSelection?.baseURL else { return nil }

                let selection = EndpointSelection(baseURL: localURL, transportPath: .iroh)
                let api = self.makeCandidateAPIClient(
                    credentials: credentials,
                    selection: selection,
                    tlsCertFingerprint: nil,
                    configurationGeneration: configurationGeneration,
                    apiClientFactory: self.configuredAPIClientFactory
                )
                let info = try await self.configuredServerInfoBootstrap(api.client, deadline)
                try Task.checkCancellation()
                return ForegroundIrohRebuild(
                    selection: selection,
                    apiClient: api.client,
                    apiIdentity: api.identity,
                    serverInfo: info
                )
            }
            let rebuilt = try await waitForForegroundIrohRebuild(operation, deadline: deadline)
            guard stillCurrent() else { return .notActive }

            if let rebuilt {
                sender.advanceTransportGeneration()
                await commitCandidate(
                    credentials: credentials,
                    selection: rebuilt.selection,
                    manager: manager,
                    apiClient: rebuilt.apiClient,
                    apiIdentity: rebuilt.apiIdentity,
                    serverInfo: rebuilt.serverInfo,
                    configurationGeneration: configurationGeneration
                )
            }
            if let sessionId = focusedTarget.sessionId,
               let routeScope = focusedTarget.routeScope {
                prepareFocusedSessionStreamEndpoint(sessionId: sessionId, routeScope: routeScope)
                if shouldReconnectFocused { connectStream() }
            }
            if rebuilt == nil, appEventStreamAvailable {
                startAppEventStreamIfAvailable()
            }
            ClientLog.info("Iroh", "Foreground endpoint retained", metadata: [
                "transport": "iroh",
                "loopbackRebuilt": rebuilt == nil ? "false" : "true",
            ])
            return .retained
        } catch is CancellationError {
            return .notActive
        } catch {
            guard stillCurrent() else { return .notActive }
            if isRouteAvailabilityFailure(error) {
                ClientLog.warning("Iroh", "Foreground endpoint unavailable", metadata: [
                    "transport": "iroh",
                    "errorKind": IrohTransportTelemetry.errorKind(error),
                ])
                return .availabilityFailure
            }
            await shutdownSetupManager(manager)
            invalidateTransportAfterTerminalFailure(error)
            return .terminalFailure
        }
    }

    /// Send a graceful WS close frame before iOS suspends the app and release
    /// the reusable QUIC connection. The endpoint/listener remain available so
    /// foreground recovery keeps the same Keychain-backed endpoint identity.
    func prepareForBackground() {
        wsClient?.prepareForBackground()
        if let irohManager, irohBackgroundPreparationTask == nil {
            irohBackgroundPreparationTask = Task { @MainActor [weak self] in
                await irohManager.prepareForBackground()
                self?.irohBackgroundPreparationTask = nil
            }
        }
    }

    /// Permanently tear down app-local and Iroh state for unpair/reconfigure.
    func shutdownTransport() async {
        guard let iroh = credentials?.transports.iroh else { return }
        irohManager = nil
        await IrohTransportRegistry.shared.remove(nodeID: iroh.nodeId)
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
                meta: frameEvent.meta
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
        noteAutomaticIrohRecoverySucceeded()
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

    // MARK: - Session Streaming

    private func clearFocusedSessionStreamEndpoint() {
        focusedSessionStreamEndpointKind = "none"
        focusedSessionStreamSessionId = nil
        focusedSessionStreamWorkspaceId = nil
        focusedSessionStreamRouteScope = nil
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

    private func focusedSessionStreamTargetMatches(sessionId: String, routeScope: SessionRouteScope) -> Bool {
        focusedSessionStreamEndpointKind == "split_session"
            && focusedSessionStreamSessionId == sessionId
            && focusedSessionStreamRouteScope == routeScope
    }

    /// Open the URL-bound focused session stream.
    func streamSession(_ sessionId: String, workspaceId: String) async -> AsyncStream<SessionStreamEvent>? {
        await streamSession(sessionId, routeScope: .workspace(workspaceId))
    }

    func streamSession(_ sessionId: String, routeScope: SessionRouteScope) async -> AsyncStream<SessionStreamEvent>? {
        await refreshStreamCapabilitiesIfNeeded()
        await waitWhileTransportDemotingIfNeeded()
        guard hasRequiredSplitStreamCapabilities else {
            recordSessionStreamUnavailable(reason: streamCapabilityUnavailableReason())
            return nil
        }
        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, routeScope: routeScope)
        return await sessionStreamCoordinator.streamSession(
            connection: self,
            sessionId: sessionId,
            routeScope: routeScope
        )
    }

    /// Silence watchdog and session re-entry can race a Wi‑Fi→cell demotion.
    /// Wait briefly for the replacement route instead of failing open on the
    /// mid-reconfigure hole (`endpointSelection == nil`, stale `transport=lan`).
    private func waitWhileTransportDemotingIfNeeded() async {
        guard isTransportDemoting || (endpointSelection == nil && automaticIrohRecoveryRetryTask != nil) else {
            return
        }
        for _ in 0..<50 {
            if !isTransportDemoting, endpointSelection != nil {
                return
            }
            if transportFailureDisposition == .failClosed {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func prepareFocusedSessionStreamEndpoint(sessionId: String, routeScope: SessionRouteScope) {
        let previousBoundSessionId = focusedSessionStreamSessionId
        if previousBoundSessionId != sessionId {
            recordFocusArbitration(
                outcome: "requested",
                previousSessionId: previousBoundSessionId,
                nextSessionId: sessionId,
                context: "stream_bind"
            )
        }

        if focusedSessionStreamTargetMatches(sessionId: sessionId, routeScope: routeScope) {
            // Keep a live/reconnecting transport for the same bound endpoint,
            // but still recompute the URL below. Endpoint selection may have
            // changed after Wi-Fi/cellular handoff while the session target did not.
        } else if focusedSessionStreamEndpointKind == "split_session",
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
        guard let sessionStreamURL = makeFocusedSessionStreamURL(
            selection: selection,
            sessionId: sessionId,
            routeScope: routeScope
        ) else {
            recordSessionStreamUnavailable(reason: "invalidStreamURL")
            return
        }

        let previousURL = focusedSessionStreamURL
        focusedSessionStreamEndpointKind = "split_session"
        focusedSessionStreamSessionId = sessionId
        focusedSessionStreamWorkspaceId = routeScope.workspaceId
        focusedSessionStreamRouteScope = routeScope
        focusedSessionStreamURL = sessionStreamURL
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

    private func makeFocusedSessionStreamURL(
        selection: EndpointSelection,
        sessionId: String,
        routeScope: SessionRouteScope
    ) -> URL? {
        guard var components = URLComponents(url: selection.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = selection.baseURL.scheme == "https" ? "wss" : "ws"
        switch routeScope {
        case .workspace(let workspaceId):
            components.path = "/workspaces/\(workspaceId)/sessions/\(sessionId)/stream"
        case .control:
            components.path = "/control-sessions/\(sessionId)/stream"
        }
        return components.url
    }

    private func refreshPreparedFocusedSessionEndpointAfterEndpointChange() {
        guard focusedSessionStreamEndpointKind == "split_session",
              let sessionId = focusedSessionStreamSessionId,
              let routeScope = focusedSessionStreamRouteScope else {
            return
        }

        prepareFocusedSessionStreamEndpoint(sessionId: sessionId, routeScope: routeScope)
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
            "reason": isTransportDemoting ? "transportDemoting" : reason,
            "capabilityStatus": requiredSplitStreamCapabilitiesStatusForDiagnostics,
            "transport": isTransportDemoting ? "demoting" : transportPath.rawValue,
            "demoting": isTransportDemoting ? "true" : "false",
            "hasWebSocketClient": wsClient == nil ? "false" : "true",
        ]
        metadata.merge(diagnosticEndpointMetadata(endpointSelection?.baseURL, prefix: "api")) { current, _ in current }
        metadata.merge(diagnosticEndpointMetadata(focusedSessionStreamURL, prefix: "stream")) { current, _ in current }
        ClientLog.warning("Network", "Session stream unavailable", metadata: metadata)
    }

    private func diagnosticEndpointMetadata(_ url: URL?, prefix: String) -> [String: String] {
        if transportPath == .iroh {
            return ["\(prefix)Transport": "iroh"]
        }
        return ClientLog.endpointMetadata(url, prefix: prefix)
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
        if transportPath == .iroh {
            return "iroh"
        }
        return ClientLog.hostKind(endpointSelection?.baseURL.host ?? credentials?.host)
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
    func focusSession(_ sessionId: String) {
        cancelDeferredPlaybackDisconnect(for: sessionId)
        let previousSessionId = focusedSessionId
        if previousSessionId != sessionId {
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

        focusedSessionStore.focus(sessionId: sessionId)
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
    func prepareForSessionReentry(
        _ sessionId: String,
        workspaceIdHint: String? = nil,
        routeScope: SessionRouteScope? = nil
    ) {
        _onPrepareForSessionReentryForTesting?(sessionId)
        focusSession(sessionId)

        let session = sessionStore.session(id: sessionId)
        guard hasRequiredSplitStreamCapabilities, session?.status != .stopped else {
            return
        }

        let resolvedScope: SessionRouteScope?
        if routeScope == .control || session?.control != nil {
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

    /// Split streams bind the destination in the URL, so the envelope override
    /// cannot redirect a frame. Repair a stale binding before any turn command.
    private func prepareFocusedSessionBindingForSendIfNeeded(
        sessionIdOverride: String?
    ) throws {
        guard let requestedSessionId = sessionIdOverride,
              focusedSessionStreamEndpointKind == "split_session",
              let boundSessionId = focusedSessionStreamSessionId,
              boundSessionId != requestedSessionId else {
            return
        }

        prepareForSessionReentry(
            requestedSessionId,
            workspaceIdHint: sessionReentryWorkspaceId(for: requestedSessionId),
            routeScope: sessionStore.routeScope(for: requestedSessionId)
        )

        guard focusedSessionStreamEndpointKind == "split_session",
              focusedSessionStreamSessionId == requestedSessionId else {
            throw FocusedSessionBindingError.rebindUnavailable(
                requestedSessionId: requestedSessionId,
                boundSessionId: boundSessionId
            )
        }
    }

    func sendPrompt(_ text: String, attachments: [ChatAttachmentRef]? = nil, clientTurnId: String? = nil, sessionIdOverride: String? = nil, onAckStage: ((TurnAckStage) -> Void)? = nil) async throws {
        try prepareFocusedSessionBindingForSendIfNeeded(sessionIdOverride: sessionIdOverride)
        try await sender.sendPrompt(text, attachments: attachments, clientTurnId: clientTurnId, sessionIdOverride: sessionIdOverride, onAckStage: onAckStage)
    }

    func sendSteer(_ text: String, attachments: [ChatAttachmentRef]? = nil, clientTurnId: String? = nil, sessionIdOverride: String? = nil, onAckStage: ((TurnAckStage) -> Void)? = nil) async throws {
        try prepareFocusedSessionBindingForSendIfNeeded(sessionIdOverride: sessionIdOverride)
        try await sender.sendSteer(text, attachments: attachments, clientTurnId: clientTurnId, sessionIdOverride: sessionIdOverride, onAckStage: onAckStage)
    }

    func sendFollowUp(_ text: String, attachments: [ChatAttachmentRef]? = nil, clientTurnId: String? = nil, sessionIdOverride: String? = nil, onAckStage: ((TurnAckStage) -> Void)? = nil) async throws {
        try prepareFocusedSessionBindingForSendIfNeeded(sessionIdOverride: sessionIdOverride)
        try await sender.sendFollowUp(text, attachments: attachments, clientTurnId: clientTurnId, sessionIdOverride: sessionIdOverride, onAckStage: onAckStage)
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
            tlsCertFingerprint: transportPath == .iroh ? nil : credentials.normalizedTLSCertFingerprint,
            tlsServerName: selection.tlsServerName
        )
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

        let clientGeneration = persistentStreamGeneration
        let client = AppEventStreamClient(
            url: streamURL,
            token: credentials.token,
            tlsCertFingerprint: transportPath == .iroh ? nil : credentials.normalizedTLSCertFingerprint,
            tlsServerName: selection.tlsServerName,
            diagnosticRemoteIdentity: transportPath == .iroh ? "iroh" : nil
        )
        client.onTransportHealthFailure = { @MainActor [weak self, weak client] failure in
            guard let self,
                  let client,
                  self.appEventStreamCoordinator.isCurrentClient(client) else { return }
            await self.handlePersistentStreamHealthFailure(
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
        appEventListRepairGeneration &+= 1
        appEventListRepairTask?.cancel()
        appEventListRepairTask = nil
        appEventListRepairFollowUpUsed = false
        appEventListPendingExternalFailure = false
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
        appEventListRepairFollowUpUsed = false
        appEventListPendingExternalFailure = false
        noteAutomaticIrohRecoverySucceeded()
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
    var appEventListRepairTask: Task<Void, Never>?
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

    // periphery:ignore - used by VoiceInputManagerTests via @testable import
    /// Override server dictation availability for testing.
    func setServerDictationAvailableForTesting(_ available: Bool) {
        serverDictationAvailable = available
    }

    // periphery:ignore - used by stream coordinator tests via @testable import
    func setFocusedSessionStreamEndpointKindForTesting(_ kind: String) {
        focusedSessionStreamEndpointKind = kind
    }

    func setAPIClientForTesting(_ client: APIClient?) {
        installAPIClient(client)
    }

    func failTransportTerminallyForTesting() {
        transportFailureDisposition = .failClosed
        invalidateTransportAfterTerminalFailure(
            IrohTransportError.authentication("test terminal failure")
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

    var focusedSessionStreamURLForTesting: URL? {
        focusedSessionStreamURL
    }

    var hasScheduledAutomaticRouteRecoveryForTesting: Bool {
        automaticIrohRecoveryRetryTask != nil
    }

    var persistentStreamGenerationForTesting: UInt64 {
        persistentStreamGeneration
    }

    var transportConfigurationGenerationForTesting: UInt64 {
        transportConfigurationGeneration
    }

    var configuredRouteModeForTesting: PairedServerRouteMode {
        configuredRouteMode
    }

    var irohManagerIdentityForTesting: ObjectIdentifier? {
        irohManager.map(ObjectIdentifier.init)
    }

    var persistentHealthRecoveryPendingForTesting: Bool {
        pendingPersistentHealthRecovery != nil
    }

    /// Wait until fire-and-forget availability recovery has started and finished.
    func awaitPersistentHealthRecoveryForTesting(timeoutMs: Int = 1_000) async {
        let attempts = max(1, timeoutMs / 5)
        for _ in 0..<attempts {
            if let recovery = persistentHealthRecoveryTask {
                await recovery.task.value
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        if let recovery = persistentHealthRecoveryTask {
            await recovery.task.value
        }
    }

    func reportFocusedStreamHealthFailureForTesting(
        _ failure: PersistentStreamHealthFailure
    ) async {
        await wsClient?.onTransportHealthFailure?(failure)
    }

    func setSplitStreamCapabilitiesForTesting(
        sessionStream: Bool = true,
        dictationStream: Bool = false,
        appEventStream: Bool = false
    ) {
        dictationStreamAvailable = dictationStream
        appEventStreamAvailable = appEventStream
        var missing: [String] = []
        if !sessionStream { missing.append("sessionStream") }
        missingRequiredSplitStreamCapabilities = missing
        streamCapabilitiesLoaded = true
    }
#endif
}
