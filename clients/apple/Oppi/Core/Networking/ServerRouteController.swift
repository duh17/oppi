import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Connection")

private enum TransportFailureDisposition {
    case retryable
    case failClosed
}

private final class WeakAPIClientReference: @unchecked Sendable {
    weak var client: APIClient?
}

/// What route selection reads from its connection, and the composition changes
/// only the connection makes: installing a committed route, tearing the
/// composition down, and rebinding streams after a rebuild.
@MainActor
protocol ServerRouteHost: AnyObject {
    /// Credentials of the installed composition.
    var credentials: ServerCredentials? { get }
    var apiClient: APIClient? { get }
    var transportPath: ConnectionTransportPath { get }
    var endpointSelection: EndpointSelection? { get }
    /// Work a route rebuild must never interrupt.
    var hasActiveWork: Bool { get }
    /// The focused-session stream or the app-event stream is connected.
    var hasConnectedPersistentStream: Bool { get }
    /// Fence pending sends: a new route never carries them.
    func advanceSendGeneration()
    /// A candidate's API client with the device auth session attached.
    func makeCandidateClient(
        selection: EndpointSelection,
        credentials: ServerCredentials,
        availabilityObserver: @escaping APIClientAvailabilityObserver,
        factory: ServerConnectionAPIClientFactory
    ) -> APIClient
    /// Install the composition of a route that completed authenticated bootstrap.
    func installRoute(
        credentials: ServerCredentials,
        selection: EndpointSelection,
        apiClient: APIClient,
        serverInfo: ServerInfo,
        streamGeneration: UInt64
    )
    /// Tear the composition down before a rebuild. Returns the focused stream
    /// target to rebind once the next route commits.
    func tearDownForRouteRebuild() -> (sessionId: String, routeScope: SessionRouteScope)?
    func rebindAfterRouteRebuild(_ focusedTarget: (sessionId: String, routeScope: SessionRouteScope)?)
    func tearDownAfterTerminalFailure()
    func refreshListsAfterRouteRecovery() async
}

/// Route selection for one server connection: which candidate (LAN or paired
/// HTTPS) carries it, when LAN is promoted or demoted, Tailnet rebuilds, the
/// transport generations that fence late results, and recovery after a
/// persistent stream or an API request reports the route unavailable.
///
/// `LANEndpointSelection` and `ServerTransportPlanResolver` stay the pure
/// policy. The connection installs what this controller commits
/// (`ServerRouteHost`) and keeps the stream and app-event lifecycles.
@MainActor @Observable
final class ServerRouteController {
    nonisolated static let httpCandidateTimeoutDefault: Duration = .milliseconds(1_500)

    /// Weak: the connection owns this controller. Every entry point resolves it
    /// once and holds it for the call, as the connection's own tasks did.
    @ObservationIgnored private weak var host: ServerRouteHost?

    // Injected policy inputs (the coordinator sets `networkPathType`).
    @ObservationIgnored var networkPathType: () -> String = { NetworkPathTelemetry.pathType }
    @ObservationIgnored var automaticRouteReachabilityProbe: @MainActor (
        EndpointSelection, ServerCredentials, TailnetTransportRoute.Snapshot
    ) async -> Bool = { selection, credentials, route in
        await ServerRouteController.probeAutomaticRoute(selection, credentials: credentials, route: route)
    }
    @ObservationIgnored var lanBootstrapDeadline: ServerConnectionBootstrapDeadlineFactory = { .after(.seconds(1)) }
    @ObservationIgnored var prepareTailnetProxy: @MainActor () async throws -> Void = {
        guard AppPreferences.Tailnet.isEnabled else { return }
        let node = TailnetNodeController.shared
        node.startIfEnabled()
        try await node.waitUntilCurrentGenerationProxyReady(timeout: .seconds(6))
    }

    // The setup inputs of the current configuration, reused by every rebuild.
    @ObservationIgnored private var configuredHTTPBootstrapDeadlineFactory: ServerConnectionBootstrapDeadlineFactory = {
        .after(ServerRouteController.httpCandidateTimeoutDefault)
    }
    @ObservationIgnored private var configuredAPIClientFactory: ServerConnectionAPIClientFactory = { environment, observer in
        APIClient(environment: environment, availabilityObserver: observer)
    }
    @ObservationIgnored private var configuredServerInfoBootstrap: ServerConnectionInfoBootstrap = { client, deadline in
        try await client.serverInfo(bootstrapDeadline: deadline)
    }
    /// Called when the device auth session refreshes its credential.
    private(set) var deviceCredentialDidChange: ServerConnectionDeviceCredentialObserver?

    private var transportFailureDisposition: TransportFailureDisposition?
    /// Whether the last `.retryable` setup pass ended on a failure waiting can
    /// clear (unreachable, timeout, 408, 5xx), not an answer like 401 or 404.
    private var retryableFailureIsTransient = false
    private(set) var configuredTailnetRoute: TailnetTransportRoute.Snapshot = .direct
    var configuredSOCKSGeneration: UInt64 { configuredTailnetRoute.generation }
    private var lanDemotionTask: (id: UUID, task: Task<Void, Never>)?
    private var pendingLANPromotion = false
    private var lanDemoted = false
    /// Automatic rebuilds spent chasing a moving SOCKS generation in the current
    /// configuration. Past the budget the bootstrap is kept and the next route
    /// notification rebuilds, so a flapping node cannot loop forever.
    private static let maxTailnetRestarts = 2
    private var tailnetRestartsUsed = 0
    /// Captured when a configuration starts, before the transport-generation
    /// fence fails pending sends: LAN promotion is deferred for active work, so
    /// this pass must not pick LAN.
    private var lanDeferredForActiveWork = false
    private var installedAPIClientIdentity: UUID?
    private var installedAPIClientConfigurationGeneration: UInt64?
    private var persistentHealthRecoveryTask: (id: UUID, task: Task<Void, Never>)?
    private var pendingPersistentHealthRecovery: (
        failure: PersistentStreamHealthFailure,
        expectedGeneration: UInt64?,
        failedRoute: ServerRouteCandidateKind?
    )?
    /// Bumped by every committed route; stream health reports from an older
    /// composition are ignored.
    private(set) var persistentStreamGeneration: UInt64 = 0
    private var lanCandidateGeneration: UInt64 = 0
    /// Bumped by every setup pass; a result from an older pass never commits.
    private(set) var transportConfigurationGeneration: UInt64 = 0
    private var activeTransportConfigurationGenerations: Set<UInt64> = []
    private var discoveredLANEndpoint: LANDiscoveredEndpoint?
    /// True while a route demotion/reconfigure has torn down composition and a
    /// replacement commit (or budgeted retry) is still outstanding. UI and stream
    /// open paths treat this as recovering, not settled offline-on-LAN.
    private(set) var isTransportDemoting = false

    init(host: ServerRouteHost) {
        self.host = host
    }

    var needsTailnetRouteRebuild: Bool {
        guard let host else { return true }
        return host.credentials == nil || (host.transportPath != .lan && configuredTailnetRoute != .current)
    }

    var canAutomaticallyRetryInitialTransport: Bool {
        transportFailureDisposition != .failClosed
    }

    /// Setup got a terminal answer: no automatic route change until the next
    /// explicit configuration.
    var hasFailedClosed: Bool {
        transportFailureDisposition == .failClosed
    }

    /// Whether a timer may retry first setup after its last pass. Boundaries
    /// (path, route, foreground) retry on `canAutomaticallyRetryInitialTransport`.
    var canRetryInitialTransportOnTimer: Bool {
        transportFailureDisposition == .retryable && retryableFailureIsTransient
    }

    /// A setup pass is outstanding now: the attempt it started has neither
    /// committed nor given up, so a client can appear with no boundary and no
    /// timer doing more (the first connect after launch, a rebuild).
    var isConfiguringTransport: Bool {
        !activeTransportConfigurationGenerations.isEmpty
    }

    /// Promotion triggers are only Bonjour arrival (`setDiscoveredLANEndpoint`)
    /// and foreground (`retryLANAtForegroundBoundary`); both are gated by
    /// `hasActiveWork`. There is no idle-edge resume: work that ends leaves the
    /// remote route in place until the next foreground.
    func promoteLANAtIdleBoundary() async {
        guard let host else { return }
        guard pendingLANPromotion, !host.hasActiveWork,
              NetworkPathTelemetry.allowsLAN(pathType: networkPathType()) else { return }
        pendingLANPromotion = false
        await reevaluateNetworkEndpointAtBoundary()
    }

    func retryLANAtForegroundBoundary() async {
        guard let host else { return }
        if lanDemoted {
            lanDemoted = false
            pendingLANPromotion = discoveredLANEndpoint != nil && host.transportPath != .lan
        }
        await promoteLANAtIdleBoundary()
    }

    /// The installed client went away (terminal failure, rebuild, or a test
    /// replacement): its availability reports no longer match any route.
    func forgetInstalledClient() {
        installedAPIClientIdentity = nil
        installedAPIClientConfigurationGeneration = nil
    }

    // MARK: - Setup

    /// Walk authorized candidates serially and commit only the first candidate
    /// that completes authenticated bootstrap. Candidate exclusions are local to
    /// this invocation and are never retained as route memory.
    @discardableResult
    func configureForUse(
        credentials: ServerCredentials,
        excluding: Set<ServerRouteCandidateKind> = [],
        httpBootstrapDeadline: @escaping ServerConnectionBootstrapDeadlineFactory = {
            .after(ServerRouteController.httpCandidateTimeoutDefault)
        },
        apiClientFactory: @escaping ServerConnectionAPIClientFactory = { environment, observer in
            APIClient(environment: environment, availabilityObserver: observer)
        },
        serverInfoBootstrap: @escaping ServerConnectionInfoBootstrap = { client, deadline in
            try await client.serverInfo(bootstrapDeadline: deadline)
        },
        deviceCredentialDidChange: ServerConnectionDeviceCredentialObserver? = nil,
        tailnetRestartsUsed: Int = 0,
        lanDeferredForActiveWork: Bool? = nil
    ) async -> Bool {
        guard let host else { return false }
        self.tailnetRestartsUsed = tailnetRestartsUsed
        self.lanDeferredForActiveWork = lanDeferredForActiveWork ?? (pendingLANPromotion && host.hasActiveWork)
        transportConfigurationGeneration &+= 1
        let generation = transportConfigurationGeneration
        activeTransportConfigurationGenerations.insert(generation)
        configuredHTTPBootstrapDeadlineFactory = httpBootstrapDeadline
        configuredAPIClientFactory = apiClientFactory
        configuredServerInfoBootstrap = serverInfoBootstrap
        self.deviceCredentialDidChange = deviceCredentialDidChange
        host.advanceSendGeneration()
        let result = await configureForUseAttempt(
            credentials: credentials,
            excluding: excluding,
            configurationGeneration: generation,
            httpBootstrapDeadline: httpBootstrapDeadline,
            apiClientFactory: apiClientFactory,
            serverInfoBootstrap: serverInfoBootstrap,
            host: host
        )
        return await finishTransportConfiguration(result, generation: generation, host: host)
    }

    /// Explicit Retry starts a fresh pass with no exclusions by default while
    /// preserving focused-session and app-event subscription intent.
    @discardableResult
    func reconfigureForExplicitRetry(
        credentials: ServerCredentials,
        excluding: Set<ServerRouteCandidateKind> = [],
        httpBootstrapDeadline: @escaping ServerConnectionBootstrapDeadlineFactory = {
            .after(ServerRouteController.httpCandidateTimeoutDefault)
        },
        apiClientFactory: @escaping ServerConnectionAPIClientFactory = { environment, observer in
            APIClient(environment: environment, availabilityObserver: observer)
        },
        serverInfoBootstrap: @escaping ServerConnectionInfoBootstrap = { client, deadline in
            try await client.serverInfo(bootstrapDeadline: deadline)
        },
        deviceCredentialDidChange: ServerConnectionDeviceCredentialObserver? = nil,
        tailnetRestartsUsed: Int = 0
    ) async -> Bool {
        guard let host else { return false }
        let lanDeferred = pendingLANPromotion && host.hasActiveWork
        isTransportDemoting = true
        let focusedTarget = host.tearDownForRouteRebuild()
        let configured = await configureForUse(
            credentials: credentials,
            excluding: excluding,
            httpBootstrapDeadline: httpBootstrapDeadline,
            apiClientFactory: apiClientFactory,
            serverInfoBootstrap: serverInfoBootstrap,
            deviceCredentialDidChange: deviceCredentialDidChange,
            tailnetRestartsUsed: tailnetRestartsUsed,
            lanDeferredForActiveWork: lanDeferred
        )
        guard configured else { return false }
        host.rebindAfterRouteRebuild(focusedTarget)
        isTransportDemoting = false
        return true
    }

    private func configureForUseAttempt(
        credentials: ServerCredentials,
        excluding: Set<ServerRouteCandidateKind>,
        configurationGeneration: UInt64,
        httpBootstrapDeadline: @escaping ServerConnectionBootstrapDeadlineFactory,
        apiClientFactory: @escaping ServerConnectionAPIClientFactory,
        serverInfoBootstrap: @escaping ServerConnectionInfoBootstrap,
        host: ServerRouteHost
    ) async -> Bool {
        do {
            // A rebuild (e.g. a tailnet route change) is not a promotion trigger:
            // while promotion is deferred for active work it must not pick LAN.
            // A failover pass (non-empty exclusions) may still use LAN.
            let deferLAN = lanDeferredForActiveWork && excluding.isEmpty
            let candidates = try ServerTransportPlanResolver.candidates(
                credentials: credentials,
                discoveredLANEndpoint: lanDemoted || deferLAN ? nil : discoveredLANEndpoint,
                excluding: excluding,
                pathType: networkPathType()
            )
            var lastError: Error?
            for candidate in candidates {
                guard transportConfigurationGeneration == configurationGeneration else { return false }
                if candidate.transportPath == .paired,
                   ServerTLSTrustPolicy.isTailscaleHostname(credentials.host) {
                    do { try await prepareTailnetProxy() } catch is CancellationError { return false } catch {
                        ClientLog.info("Network", "In-app Tailscale not ready; using system resolver", metadata: [
                            "reason": String(describing: type(of: error)),
                        ])
                    }
                    guard !Task.isCancelled,
                          transportConfigurationGeneration == configurationGeneration else { return false }
                }
                let candidateLANGeneration = lanCandidateGeneration
                let prepared = makeCandidateAPIClient(
                    credentials: credentials,
                    selection: candidate,
                    configurationGeneration: configurationGeneration,
                    apiClientFactory: apiClientFactory,
                    host: host
                )
                let route = prepared.client.tailnetRoute
                let handshakeStarted = ContinuousClock.now
                do {
                    let info = try await serverInfoBootstrap(
                        prepared.client,
                        candidate.transportPath == .lan ? lanBootstrapDeadline() : httpBootstrapDeadline()
                    )
                    let handshakeMs = Double((ContinuousClock.now - handshakeStarted) / .milliseconds(1))
                    NetworkPathTelemetry.recordHandshake(
                        selection: candidate,
                        durationMs: handshakeMs,
                        socksGeneration: route.generation
                    )
                    guard transportConfigurationGeneration == configurationGeneration else { return false }
                    if candidate.transportPath == .lan,
                       candidateLANGeneration != lanCandidateGeneration || !NetworkPathTelemetry.allowsLAN(pathType: networkPathType()) {
                        continue
                    }
                    if candidate.transportPath == .paired,
                       ServerTLSTrustPolicy.isTailscaleHostname(credentials.host),
                       route != .current,
                       tailnetRestartsUsed < Self.maxTailnetRestarts {
                        // The API session already captured its proxy. Never bind streams
                        // from a newer generation to that old HTTP route.
                        tailnetRestartsUsed += 1
                        return await configureForUseAttempt(
                            credentials: credentials,
                            excluding: excluding,
                            configurationGeneration: configurationGeneration,
                            httpBootstrapDeadline: httpBootstrapDeadline,
                            apiClientFactory: apiClientFactory,
                            serverInfoBootstrap: serverInfoBootstrap,
                            host: host
                        )
                    }
                    if candidate.transportPath == .lan { pendingLANPromotion = false }
                    NetworkPathTelemetry.recordRouteCommitted(selection: candidate, socksGeneration: route.generation)
                    commit(
                        credentials: credentials,
                        selection: candidate,
                        apiClient: prepared.client,
                        apiIdentity: prepared.identity,
                        serverInfo: info,
                        configurationGeneration: configurationGeneration,
                        host: host
                    )
                    return true
                } catch is CancellationError {
                    return false
                } catch {
                    let handshakeMs = Double((ContinuousClock.now - handshakeStarted) / .milliseconds(1))
                    NetworkPathTelemetry.recordHandshake(
                        selection: candidate,
                        durationMs: handshakeMs,
                        error: error,
                        socksGeneration: route.generation
                    )
                    if candidate.transportPath == .lan,
                       transportConfigurationGeneration == configurationGeneration {
                        // Same eligibility rule as a demotion: no further LAN
                        // attempts until a path or foreground boundary.
                        lanDemoted = true
                        pendingLANPromotion = false
                    }
                    lastError = error
                    continue
                }
            }
            if let lastError, !isRouteAvailabilityFailure(lastError) {
                guard transportConfigurationGeneration == configurationGeneration else { return false }
                transportFailureDisposition = .failClosed
                invalidateTransportAfterTerminalFailure(lastError, host: host)
                logger.error("HTTPS setup failed closed: \(lastError.localizedDescription, privacy: .public)")
                return false
            }
            transportFailureDisposition = .retryable
            retryableFailureIsTransient = lastError.map(ServerRouteFailure.isTransient) ?? false
            logger.warning("HTTPS candidate pass exhausted")
            return false
        } catch is CancellationError {
            return false
        } catch {
            guard transportConfigurationGeneration == configurationGeneration else { return false }
            transportFailureDisposition = .failClosed
            invalidateTransportAfterTerminalFailure(error, host: host)
            logger.error("HTTPS setup failed closed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func isRouteAvailabilityFailure(_ error: Error) -> Bool {
        ServerRouteFailure.mayAdvance(after: error)
    }

    private func finishTransportConfiguration(
        _ result: Bool,
        generation: UInt64,
        host: ServerRouteHost
    ) async -> Bool {
        activeTransportConfigurationGenerations.remove(generation)
        if result, transportConfigurationGeneration == generation,
           let credentials = host.credentials, ServerTLSTrustPolicy.isTailscaleHostname(credentials.host),
           needsTailnetRouteRebuild,
           tailnetRestartsUsed < Self.maxTailnetRestarts {
            let rebuilt = await reconfigureForExplicitRetry(
                credentials: credentials,
                httpBootstrapDeadline: configuredHTTPBootstrapDeadlineFactory,
                apiClientFactory: configuredAPIClientFactory,
                serverInfoBootstrap: configuredServerInfoBootstrap,
                deviceCredentialDidChange: deviceCredentialDidChange,
                tailnetRestartsUsed: tailnetRestartsUsed + 1
            )
            if !rebuilt { isTransportDemoting = false }
            return rebuilt
        }
        return result
    }

    private func makeCandidateAPIClient(
        credentials: ServerCredentials,
        selection: EndpointSelection,
        configurationGeneration: UInt64,
        apiClientFactory: ServerConnectionAPIClientFactory,
        host: ServerRouteHost
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
        let client = host.makeCandidateClient(
            selection: selection,
            credentials: credentials,
            availabilityObserver: observer,
            factory: apiClientFactory
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

    private func commit(
        credentials: ServerCredentials,
        selection: EndpointSelection,
        apiClient: APIClient,
        apiIdentity: UUID,
        serverInfo: ServerInfo,
        configurationGeneration: UInt64,
        host: ServerRouteHost
    ) {
        persistentStreamGeneration &+= 1
        transportFailureDisposition = nil
        retryableFailureIsTransient = false
        configuredTailnetRoute = apiClient.tailnetRoute
        installedAPIClientIdentity = apiIdentity
        installedAPIClientConfigurationGeneration = configurationGeneration
        host.installRoute(
            credentials: credentials,
            selection: selection,
            apiClient: apiClient,
            serverInfo: serverInfo,
            streamGeneration: persistentStreamGeneration
        )
    }

    // MARK: - LAN discovery and network paths

    @discardableResult
    func setDiscoveredLANEndpoint(
        _ endpoint: LANDiscoveredEndpoint?
    ) -> Task<Void, Never>? {
        guard let host else { return nil }
        guard endpoint != discoveredLANEndpoint else {
            return endpoint == nil && host.transportPath == .lan ? lanDemotionTask?.task : nil
        }
        discoveredLANEndpoint = endpoint
        lanCandidateGeneration &+= 1
        guard transportFailureDisposition != .failClosed else { return nil }
        guard let credentials = host.credentials else { return nil }
        if endpoint == nil, host.transportPath == .lan {
            lanDemoted = true
            pendingLANPromotion = false
        }

        if let endpoint,
           let candidate = LANEndpointSelection.select(
               credentials: credentials,
               discoveredEndpoint: endpoint
           ), host.endpointSelection == candidate, !isTransportDemoting, lanDemotionTask == nil {
            return nil
        }
        guard endpoint != nil || host.transportPath == .lan else {
            // Healthy paired HTTPS routes stay sticky when Bonjour disappears.
            return nil
        }

        if let endpoint {
            guard LANEndpointSelection.select(credentials: credentials, discoveredEndpoint: endpoint)?.transportPath == .lan else { return nil }
            guard NetworkPathTelemetry.allowsLAN(pathType: networkPathType()), !lanDemoted else { return nil }
            pendingLANPromotion = true
            guard !host.hasActiveWork else { return nil }
        } else {
            pendingLANPromotion = false
        }
        if endpoint == nil { return scheduleLANDemotion() }
        return Task { @MainActor [weak self] in
            await self?.promoteLANAtIdleBoundary()
        }
    }

    private func scheduleLANDemotion() -> Task<Void, Never> {
        if let demotion = lanDemotionTask { return demotion.task }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.lanDemotionTask?.id == id { self.lanDemotionTask = nil }
            }
            await self.reevaluateNetworkEndpointAtBoundary(excluding: [.lan])
        }
        lanDemotionTask = (id, task)
        return task
    }

    /// A network path change resets LAN eligibility. Returns false when setup
    /// failed closed: there is no route to rebuild.
    func beginNetworkPathChange() -> Bool {
        lanDemoted = false
        pendingLANPromotion = false
        if transportFailureDisposition == .failClosed {
            discoveredLANEndpoint = nil
            return false
        }
        return true
    }

    /// LAN is tied to the network context that just went away. `stopStream`
    /// stops the dead LAN socket before the demotion starts one fresh HTTPS pass.
    func demoteLANAfterPathChange(stopStream: () -> Void) {
        isTransportDemoting = true
        stopStream()
        let transition = setDiscoveredLANEndpoint(nil)
        // This boundary invalidates the old advertisement; fresh Bonjour
        // results on the new path may be eligible again.
        lanDemoted = false
        if transition == nil { _ = scheduleLANDemotion() }
    }

    /// Reconsider HTTPS endpoints only at an explicit network or foreground boundary.
    func reevaluateNetworkEndpointAtBoundary(
        excluding exclusions: Set<ServerRouteCandidateKind> = []
    ) async {
        guard let credentials = host?.credentials else { return }
        let configured = await reconfigureForExplicitRetry(
            credentials: credentials,
            excluding: exclusions,
            httpBootstrapDeadline: configuredHTTPBootstrapDeadlineFactory,
            apiClientFactory: configuredAPIClientFactory,
            serverInfoBootstrap: configuredServerInfoBootstrap,
            deviceCredentialDidChange: deviceCredentialDidChange
        )
        if !configured { isTransportDemoting = false }
    }

    // MARK: - Recovery

    private func handleAPIClientAvailabilityFailure(
        _ failure: APIClientAvailabilityFailure,
        client: APIClient,
        identity: UUID,
        configurationGeneration: UInt64
    ) async {
        guard let host,
              host.apiClient === client,
              installedAPIClientIdentity == identity,
              installedAPIClientConfigurationGeneration == configurationGeneration,
              transportConfigurationGeneration == configurationGeneration,
              transportFailureDisposition != .failClosed else {
            return
        }

        // One failed HTTP operation is not stream-health evidence. A healthy
        // LAN WebSocket remains installed; the operation itself is never replayed.
        if host.transportPath == .lan, host.hasConnectedPersistentStream {
            return
        }

        // The failed operation is not replayed. Recovery only prepares a route
        // for future work and is coalesced with stream health failures.
        await handlePersistentStreamHealthFailure(
            .reconnectThreshold(attempt: 0),
            expectedGeneration: persistentStreamGeneration,
            failedRoute: Self.routeCandidateKind(for: host.transportPath)
        )
    }

    private func handleAPIClientResponseFailure(
        _ error: APIError,
        client: APIClient,
        identity: UUID,
        configurationGeneration: UInt64
    ) async {
        guard let host,
              host.apiClient === client,
              installedAPIClientIdentity == identity,
              installedAPIClientConfigurationGeneration == configurationGeneration,
              transportConfigurationGeneration == configurationGeneration else { return }
        invalidateTransportAfterTerminalFailure(error, host: host)
    }

    func handlePersistentStreamHealthFailure(
        _ failure: PersistentStreamHealthFailure,
        expectedGeneration: UInt64? = nil,
        failedRoute: ServerRouteCandidateKind? = nil
    ) async {
        guard let host else { return }
        guard expectedGeneration == nil || expectedGeneration == persistentStreamGeneration else {
            return
        }
        let route = failedRoute ?? Self.routeCandidateKind(for: host.transportPath)

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
        guard let host, transportFailureDisposition != .failClosed, host.credentials != nil else { return }
        let route = failedRoute ?? Self.routeCandidateKind(for: host.transportPath)

        ClientLog.warning("Network", "Persistent transport reported unavailable", metadata: [
            "transport": host.transportPath.rawValue,
            "reason": Self.persistentStreamHealthReason(failure),
        ])

        // Unix is Mac owner-socket only. iOS must not treat it as LAN or
        // paired recovery, and it is not an HTTPS route candidate.
        guard let route else { return }

        if route == .lan {
            lanDemoted = true
            pendingLANPromotion = false
            lanCandidateGeneration &+= 1
        }
        await performAutomaticRouteRecovery(excluding: [route], host: host)
    }

    static func routeCandidateKind(
        for path: ConnectionTransportPath
    ) -> ServerRouteCandidateKind? {
        switch path {
        case .lan: .lan
        case .paired: .paired
        case .unix: nil
        }
    }

    private static func persistentStreamHealthReason(
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

    /// An auth-free readiness check for automatic recovery only. TLS uses the
    /// paired pin/name policy; the body proves this is Oppi protocol 2. No bearer,
    /// credential storage, redirects, APIClient, or device refresh is involved.
    static func probeAutomaticRoute(
        _ selection: EndpointSelection,
        credentials: ServerCredentials,
        route: TailnetTransportRoute.Snapshot,
        configuration: URLSessionConfiguration? = nil
    ) async -> Bool {
        let configuration = configuration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        TailnetTransportRoute.apply(to: configuration, proxy: route.proxy)
        let delegate = PinnedServerTrustDelegate(
            pinnedLeafFingerprint: credentials.normalizedTLSCertFingerprint,
            expectedServerName: selection.tlsServerName,
            followsRedirects: false
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        struct Health: Decodable {
            let ok: Bool
            let `protocol`: Int
        }
        do {
            let url = selection.baseURL.appendingPathComponent("health")
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url == url,
                  let health = try? JSONDecoder().decode(Health.self, from: data) else { return false }
            return health.ok && health.protocol == 2
        } catch {
            return false
        }
    }

    @discardableResult
    private func performAutomaticRouteRecovery(
        excluding: Set<ServerRouteCandidateKind>,
        host: ServerRouteHost
    ) async -> Bool {
        guard let credentials = host.credentials, transportFailureDisposition != .failClosed else { return false }
        let generation = transportConfigurationGeneration
        guard !activeTransportConfigurationGenerations.contains(generation),
              let candidates = try? ServerTransportPlanResolver.candidates(
                credentials: credentials,
                discoveredLANEndpoint: lanDemoted ? nil : discoveredLANEndpoint,
                excluding: excluding,
                pathType: networkPathType()
              ) else { return false }

        // An unavailable stream is not permission to destroy its last retry
        // owner. Probe alternatives without creating auth sessions or consuming
        // refresh challenges; an empty/unhealthy pass leaves socket backoff alone.
        for candidate in candidates {
            let lanGeneration = lanCandidateGeneration
            let route = TailnetTransportRoute.Snapshot.forHost(candidate.baseURL.host)
            let isTailnet = candidate.transportPath == .paired
                && ServerTLSTrustPolicy.isTailscaleHostname(credentials.host)
            guard !isTailnet || route == .current else { continue }
            guard await automaticRouteReachabilityProbe(candidate, credentials, route) else { continue }
            guard let latestCredentials = host.credentials,
                  !Task.isCancelled,
                  transportConfigurationGeneration == generation,
                  transportFailureDisposition != .failClosed,
                  latestCredentials.transportIdentity == credentials.transportIdentity,
                  !isTailnet || route == .current,
                  candidate.transportPath != .lan
                    || (lanCandidateGeneration == lanGeneration
                        && NetworkPathTelemetry.allowsLAN(pathType: networkPathType())) else { return false }
            // No suspension between validating the probe and starting the
            // existing explicit handoff. Its bootstrap/failure policy is unchanged.
            let configured = await reconfigureForExplicitRetry(
                credentials: latestCredentials,
                excluding: excluding,
                httpBootstrapDeadline: configuredHTTPBootstrapDeadlineFactory,
                apiClientFactory: configuredAPIClientFactory,
                serverInfoBootstrap: configuredServerInfoBootstrap,
                deviceCredentialDidChange: deviceCredentialDidChange
            )
            // Once a healthy alternative hands off, authenticated bootstrap and
            // any failure keep the existing explicit-retry behavior. Do not replay.
            guard configured else {
                isTransportDemoting = false
                return false
            }
            await host.refreshListsAfterRouteRecovery()
            return true
        }
        return false
    }

    /// A terminal answer (credentials refused, protocol mismatch): tear the
    /// composition down and stop every automatic fallback.
    func invalidateTransportAfterTerminalFailure(_ error: Error) {
        guard let host else { return }
        invalidateTransportAfterTerminalFailure(error, host: host)
    }

    private func invalidateTransportAfterTerminalFailure(_ error: Error, host: ServerRouteHost) {
        host.tearDownAfterTerminalFailure()
        isTransportDemoting = false
        transportFailureDisposition = .failClosed
        ClientLog.error("Network", "Terminal HTTPS failure; fallback disabled", metadata: [
            "transport": host.transportPath.rawValue,
            "errorKind": String(describing: error),
        ])
    }
}
