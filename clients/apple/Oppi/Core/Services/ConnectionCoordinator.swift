import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Coordinator")

@MainActor
enum PreparedServerActivation {
    static func run<Prepared>(
        prepare: () async -> Prepared?,
        shouldActivate: () -> Bool,
        activate: (Prepared) -> Void
    ) async -> Bool {
        guard let prepared = await prepare(), shouldActivate() else { return false }
        activate(prepared)
        return true
    }
}

enum ServerPairingOutcome: Equatable {
    case failed
    case pairedWithoutSelection
    case selected
}

private struct ConnectionPreparation {
    let id: UUID
    let credentials: ServerCredentials
    let isForced: Bool
    let task: Task<ServerConnection?, Never>
}

enum NetworkPathRecoveryDecision {
    static func isRecoveryBoundary(
        previousSignature: String?,
        previousWasSatisfied: Bool?,
        nextSignature: String,
        nextIsSatisfied: Bool
    ) -> Bool {
        guard nextIsSatisfied,
              let previousSignature,
              let previousWasSatisfied else { return false }
        return !previousWasSatisfied || previousSignature != nextSignature
    }
}

/// Orchestrates concurrent multi-server connections.
///
/// Each paired server gets its own `ServerConnection` with a persistent
/// focused session stream, its own stores, reducer, and coalescer. The
/// coordinator manages the pool and tracks which server is "focused"
/// (shown in the UI).
///
/// Views use `@Environment(ConnectionCoordinator.self)` for multi-server operations
/// and `@Environment(ServerConnection.self)` for active-connection operations.
@MainActor @Observable
final class ConnectionCoordinator {
    let serverStore: ServerStore

    /// Currently focused server ID (fingerprint). The server whose data
    /// is displayed in the main UI.
    private(set) var activeServerId: String?
    private var selectionRevision = 0

    /// Per-server connections. Each has its own WS, stores, reducer.
    private(set) var connections: [String: ServerConnection] = [:]

    /// The focused server's connection.
    /// Falls back to a disconnected sentinel if no server is active.
    var activeConnection: ServerConnection {
        if let id = activeServerId, let conn = connections[id] {
            return conn
        }
        // Fallback: return the first connection or a disconnected sentinel.
        // This should not happen in normal operation (always have an active server).
        return connections.values.first ?? disconnectedSentinel
    }

    /// Sentinel connection used when no servers are configured.
    /// Prevents crashes from nil environment injection.
    private let disconnectedSentinel = ServerConnection()

    /// Single-flight task for `refreshAllServers()` — prevents concurrent
    /// refresh races between inbox/root `.task` and `reconnectOnLaunch`.
    private var refreshAllTask: Task<Void, Never>?

    #if DEBUG
    var _onRefreshAllServersForTesting: (() -> Void)?
    var _onRefreshInactiveServerForTesting: ((String) -> Void)?
    var _onConnectionPreparedForTesting: ((String, ServerConnection) -> Void)?
    var _onConnectionPreparationJoinedForTesting: ((String) async -> Void)?
    var _initialLANEndpointForTesting: (@MainActor (String) async -> LANDiscoveredEndpoint?)?
    var _serverInfoBootstrapForTesting: ServerConnectionInfoBootstrap?
    var _apiClientFactoryForTesting: ServerConnectionAPIClientFactory?
    #endif

    private let lanDiscovery = LANDiscovery()

    /// NWPathMonitor detects network interface changes (WiFi→cellular, LAN→Tailscale)
    /// so we can clear stale LAN endpoints and force-reconnect immediately instead of
    /// burning reconnect attempts against an unreachable LAN IP.
    private var pathMonitor: NWPathMonitor?
    private var lastPathInterfaceSignature: String?
    private var lastPathWasSatisfied: Bool?
    private var pathChangeDebounceTask: Task<Void, Never>?

    private static let pathMonitorQueueLabel = "oppi.path-monitor"
    private static let pathChangeDebounceDelay: Duration = .milliseconds(200)

    // periphery:ignore - used by RestorationStateTests via @testable import
    var connection: ServerConnection { activeConnection }

    init(serverStore: ServerStore) {
        self.serverStore = serverStore
        lanDiscovery.onUpdate = { [weak self] endpoints in
            self?.applyLANDiscovery(endpoints)
        }
    }

    // MARK: - Connection Pool

    /// Server IDs whose transport is being prepared. Views keep showing their
    /// current connection until the requested server's API surface is ready.
    private(set) var preparingServerIds: Set<String> = []
    private var connectionPreparationTasks: [String: ConnectionPreparation] = [:]
    private var retryPreparationAfterBoundaryServerIds: Set<String> = []
    private var serverLifetimes: [String: UUID] = [:]

    private func serverLifetime(for id: String) -> UUID {
        if let lifetime = serverLifetimes[id] { return lifetime }
        let lifetime = UUID()
        serverLifetimes[id] = lifetime
        return lifetime
    }

    private func isCurrentPreparation(_ id: UUID, serverId: String) -> Bool {
        !Task.isCancelled && connectionPreparationTasks[serverId]?.id == id
            && serverStore.server(for: serverId) != nil
    }

    #if DEBUG
    /// Synchronous HTTP-only seam retained for tests that exercise LAN endpoint
    /// mutation. Production navigation never calls this path.
    @discardableResult
    func ensureConnection(for server: PairedServer) -> ServerConnection {
        return ensureHTTPConnectionForTesting(for: server)
    }

    private func ensureHTTPConnectionForTesting(for server: PairedServer) -> ServerConnection {
        let serverId = server.id
        if let existing = connections[serverId] {
            if existing.hasSameTransportIdentity(as: server.credentials) {
                existing.applyPersistedSameRouteCredentials(server.credentials)
                if existing.hasViableConfiguredTransport {
                    return existing
                }
            }
            if existing.credentials != server.credentials || !existing.hasViableConfiguredTransport {
                existing.disconnectStream()
                existing.disconnectAppEventStream()
                existing.setDiscoveredLANEndpoint(bestLANEndpoint(forServerId: serverId))
                guard existing.configure(credentials: server.credentials) else { return disconnectedSentinel }
            }
            return existing
        }

        let connection = ServerConnection()
        guard connection.configure(credentials: server.credentials) else { return disconnectedSentinel }
        initializeStores(for: connection, serverId: serverId)
        connections[serverId] = connection
        return connection
    }
    #endif

    /// Publish the paired server's stores and make them active before its
    /// network transport is ready. Cold launch can render cached content from
    /// this connection while `ensureConnectionReady` performs bounded HTTPS/LAN
    /// selection in the background.
    @discardableResult
    func activatePairedServerShell(_ server: PairedServer) -> ServerConnection {
        let connection = stagePairedServerConnection(server)
        activeServerId = server.id
        selectionRevision += 1
        MetricKitService.shared.setUploadClient(connection.apiClient)
        return connection
    }

    /// Restore the focused server immediately from paired credentials.
    /// Used after AVKit fullscreen so Back cannot land on a foreign inbox
    /// while HTTPS preparation is still in flight.
    @discardableResult
    func restoreActiveServer(_ serverId: String) -> Bool {
        guard let server = serverStore.server(for: serverId) else { return false }
        if server.id == activeServerId { return true }
        _ = activatePairedServerShell(server)
        return true
    }

    /// Finish a picker selection without letting a late transport result choose the host.
    func prepareSelectedServerShell(for server: PairedServer) async {
        let connection = stagePairedServerConnection(server)
        await connection.workspaceStore.loadCachedCatalog(serverId: server.id, isCurrent: {
            self.serverStore.server(for: server.id) != nil
                && self.connections[server.id] === connection
        })
        let prepared = await ensureConnectionReady(for: server)
        if activeServerId == server.id,
           serverStore.server(for: server.id) != nil,
           prepared !== disconnectedSentinel {
            MetricKitService.shared.setUploadClient(prepared.apiClient)
        }
    }

    private func stagePairedServerConnection(_ server: PairedServer) -> ServerConnection {
        if let existing = connections[server.id] {
            return existing
        }
        let staged = ServerConnection()
        initializeStores(for: staged, serverId: server.id)
        connections[server.id] = staged
        return staged
    }

    /// Await HTTPS endpoint setup before exposing the connection to navigation.
    @discardableResult
    func ensureConnectionReady(
        for server: PairedServer,
        forceReconfigure: Bool = false
    ) async -> ServerConnection {
        let serverId = server.id
        guard serverStore.server(for: serverId) != nil else { return disconnectedSentinel }
        let lifetime = serverLifetime(for: serverId)
        if let preparation = connectionPreparationTasks[serverId] {
            #if DEBUG
            await _onConnectionPreparationJoinedForTesting?(serverId)
            #endif
            let prepared = await preparation.task.value ?? disconnectedSentinel
            guard !Task.isCancelled,
                  serverLifetimes[serverId] == lifetime,
                  let latestServer = serverStore.server(for: serverId) else { return disconnectedSentinel }
            let requestChanged = preparation.credentials.transportIdentity != latestServer.credentials.transportIdentity
            if let current = connectionPreparationTasks[serverId], current.id != preparation.id {
                // Another waiter replaced this flight. Join its result rather than
                // returning the obsolete flight's sentinel to the new pairing.
                return await ensureConnectionReady(for: latestServer, forceReconfigure: forceReconfigure)
            }
            if prepared === disconnectedSentinel,
               retryPreparationAfterBoundaryServerIds.contains(serverId),
               connections[serverId]?.canAutomaticallyRetryInitialTransport == true {
                retryPreparationAfterBoundaryServerIds.remove(serverId)
                finishConnectionPreparation(serverId: serverId, id: preparation.id)
                return await ensureConnectionReady(for: latestServer, forceReconfigure: forceReconfigure)
            }
            if requestChanged || (forceReconfigure && !preparation.isForced) {
                finishConnectionPreparation(serverId: serverId, id: preparation.id)
                return await ensureConnectionReady(
                    for: latestServer,
                    forceReconfigure: forceReconfigure || requestChanged
                )
            }
            if connectionPreparationTasks[serverId] == nil {
                // The owner consumed this flight; it may already be retrying
                // a coalesced network boundary. Follow that new flight if present.
                guard connections[serverId] === prepared,
                      prepared.hasViableConfiguredTransport else { return disconnectedSentinel }
            }
            return prepared
        }
        let latestServer = serverStore.server(for: serverId) ?? server
        if !forceReconfigure, let existing = connections[serverId] {
            if existing.hasSameTransportIdentity(as: latestServer.credentials) {
                existing.applyPersistedSameRouteCredentials(latestServer.credentials)
                if existing.hasViableConfiguredTransport {
                    return existing
                }
            }
        }

        preparingServerIds.insert(serverId)
        let preparationID = UUID()
        let task = Task<ServerConnection?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            return await self.prepareConnection(
                for: self.serverStore.server(for: serverId) ?? latestServer,
                forceReconfigure: forceReconfigure,
                preparationID: preparationID
            )
        }
        connectionPreparationTasks[serverId] = ConnectionPreparation(
            id: preparationID,
            credentials: latestServer.credentials,
            isForced: forceReconfigure,
            task: task
        )
        let prepared = await task.value
        guard serverLifetimes[serverId] == lifetime,
              connectionPreparationTasks[serverId]?.id == preparationID else { return disconnectedSentinel }
        finishConnectionPreparation(serverId: serverId, id: preparationID)
        guard let currentServer = serverStore.server(for: serverId) else { return disconnectedSentinel }

        let retryAfterBoundary = retryPreparationAfterBoundaryServerIds.remove(serverId) != nil
        if prepared?.credentials == nil,
           retryAfterBoundary,
           connections[serverId]?.canAutomaticallyRetryInitialTransport == true {
            return await ensureConnectionReady(for: currentServer)
        }
        guard let prepared,
              connections[serverId] === prepared,
              prepared.hasSameTransportIdentity(as: currentServer.credentials) else {
            return disconnectedSentinel
        }
        return prepared
    }

    private func finishConnectionPreparation(serverId: String, id: UUID) {
        guard connectionPreparationTasks[serverId]?.id == id else { return }
        connectionPreparationTasks.removeValue(forKey: serverId)
        preparingServerIds.remove(serverId)
    }

    private func prepareConnection(
        for server: PairedServer,
        forceReconfigure: Bool = false,
        preparationID: UUID
    ) async -> ServerConnection? {
        if ServerTLSTrustPolicy.isTailscaleHostname(server.host) {
            TailnetNodeController.shared.startIfEnabled()
        }
        let serverId = server.id
        let initialLANEndpoint = await initialLANEndpoint(for: server)
        guard isCurrentPreparation(preparationID, serverId: serverId) else { return nil }
        if let existing = connections[serverId] {
            let sameRoute = existing.hasSameTransportIdentity(as: server.credentials)
            if sameRoute {
                existing.applyPersistedSameRouteCredentials(server.credentials)
            }
            if !forceReconfigure, sameRoute, existing.hasViableConfiguredTransport {
                #if DEBUG
                _onConnectionPreparedForTesting?(serverId, existing)
                #endif
                return existing
            }
            if forceReconfigure || !sameRoute || !existing.hasViableConfiguredTransport {
                if existing.credentials == nil {
                    logger.info("Preparing transport for paired server")
                } else {
                    logger.warning("Reconfiguring paired server transport")
                }
                if !forceReconfigure {
                    existing.disconnectStream()
                    existing.disconnectAppEventStream()
                }
                existing.setDiscoveredLANEndpoint(initialLANEndpoint)
                guard await configureConnection(
                    existing,
                    credentials: server.credentials,
                    preservingPersistentStreams: forceReconfigure,
                    preparationID: preparationID
                ) else {
                    logger.error("Failed to prepare paired server transport")
                    return nil
                }
                guard isCurrentPreparation(preparationID, serverId: serverId),
                      connections[serverId] === existing else { return nil }
                await reconcileLANDiscoveredDuringTransportSetup(
                    connection: existing,
                    server: server,
                    initialEndpoint: initialLANEndpoint,
                    preparationID: preparationID
                )
                guard isCurrentPreparation(preparationID, serverId: serverId),
                      connections[serverId] === existing else { return nil }
                adoptLatestSameRouteCredentials(on: existing, serverId: serverId)
            }
            guard isCurrentPreparation(preparationID, serverId: serverId),
                  connections[serverId] === existing else { return nil }
            #if DEBUG
            _onConnectionPreparedForTesting?(serverId, existing)
            #endif
            return existing
        }

        let connection = ServerConnection()
        // Feed verified discovery into the HTTPS endpoint selection before initial configuration.
        connection.setDiscoveredLANEndpoint(initialLANEndpoint)
        guard await configureConnection(
            connection,
            credentials: server.credentials,
            preparationID: preparationID
        ) else {
            logger.error("Failed to configure connection for \(server.name, privacy: .public)")
            return nil
        }
        guard isCurrentPreparation(preparationID, serverId: serverId) else { return nil }
        await reconcileLANDiscoveredDuringTransportSetup(
            connection: connection,
            server: server,
            initialEndpoint: initialLANEndpoint,
            preparationID: preparationID
        )
        guard isCurrentPreparation(preparationID, serverId: serverId) else { return nil }
        adoptLatestSameRouteCredentials(on: connection, serverId: serverId)
        initializeStores(for: connection, serverId: serverId)
        #if DEBUG
        _onConnectionPreparedForTesting?(serverId, connection)
        #endif
        connections[serverId] = connection
        logger.warning("Created ready connection for \(server.name, privacy: .public) (\(serverId.prefix(16), privacy: .public))")
        return connection
    }

    private func initialLANEndpoint(for server: PairedServer) async -> LANDiscoveredEndpoint? {
        let endpoint = bestLANEndpoint(forServerId: server.id)
        #if DEBUG
        if endpoint == nil, let testEndpoint = _initialLANEndpointForTesting {
            return await testEndpoint(server.id)
        }
        #endif
        return endpoint
    }

    private func reconcileLANDiscoveredDuringTransportSetup(
        connection: ServerConnection,
        server: PairedServer,
        initialEndpoint: LANDiscoveredEndpoint?,
        preparationID: UUID
    ) async {
        var reconciledEndpoint = initialEndpoint
        while true {
            let latestEndpoint = await initialLANEndpoint(for: server)
            guard isCurrentPreparation(preparationID, serverId: server.id) else { return }
            guard latestEndpoint != reconciledEndpoint else { return }

            // Bonjour can change again while an asynchronous transport setup
            // is in flight. Repeat after each transition to close that window.
            let transition = connection.setDiscoveredLANEndpoint(latestEndpoint)
            await transition?.value
            reconciledEndpoint = latestEndpoint
        }
    }

    /// A refresh during bootstrap can land in the store before `credentials`
    /// is committed on the connection. Adopt that snapshot without rebuilding.
    private func adoptLatestSameRouteCredentials(on connection: ServerConnection, serverId: String) {
        guard let latest = serverStore.server(for: serverId)?.credentials else { return }
        connection.applyPersistedSameRouteCredentials(latest)
    }

    private func configureConnection(
        _ connection: ServerConnection,
        credentials: ServerCredentials,
        preservingPersistentStreams: Bool = false,
        preparationID: UUID
    ) async -> Bool {
        let deviceCredentialObserver: ServerConnectionDeviceCredentialObserver = { [weak self, weak connection] result in
            guard let self, let connection,
                  let serverId = credentials.normalizedServerFingerprint,
                  let expectedDeviceId = credentials.deviceCredential?.deviceId,
                  self.serverStore.server(for: serverId) != nil,
                  (self.isCurrentPreparation(preparationID, serverId: serverId)
                    || self.connections[serverId] === connection) else { return }
            do {
                let merged = try self.serverStore.persistDeviceCredentialRefresh(
                    id: serverId,
                    expectedDeviceId: expectedDeviceId,
                    result: result
                )
                connection.applyPersistedDeviceCredential(merged)
            } catch {
                ClientLog.error("DeviceCredential", "Failed to persist device-credential refresh", metadata: [
                    "serverId": serverId,
                    "error": error.localizedDescription,
                ])
            }
        }
        #if DEBUG
        let bootstrap = _serverInfoBootstrapForTesting ?? { client, deadline in
            try await client.serverInfo(bootstrapDeadline: deadline)
        }
        let apiFactory = _apiClientFactoryForTesting ?? { environment, observer in
            APIClient(environment: environment, availabilityObserver: observer)
        }
        #else
        let bootstrap: ServerConnectionInfoBootstrap = { client, deadline in
            try await client.serverInfo(bootstrapDeadline: deadline)
        }
        let apiFactory: ServerConnectionAPIClientFactory = { environment, observer in
            APIClient(environment: environment, availabilityObserver: observer)
        }
        #endif
        if preservingPersistentStreams {
            return await connection.reconfigureForExplicitRetry(
                credentials: credentials,
                apiClientFactory: apiFactory,
                serverInfoBootstrap: bootstrap,
                deviceCredentialDidChange: deviceCredentialObserver
            )
        }
        return await connection.configureForUse(
            credentials: credentials,
            apiClientFactory: apiFactory,
            serverInfoBootstrap: bootstrap,
            deviceCredentialDidChange: deviceCredentialObserver
        )
    }

    private func initializeStores(for connection: ServerConnection, serverId: String) {
        connection.sessionStore.switchServer(to: serverId)
        connection.askRequestStore.switchServer(to: serverId)
        connection.workspaceStore.switchServer(to: serverId)
        connection.serverResourceStore.switchServer(to: serverId)
    }

    func prepareInactiveConnectionsReady(excluding selectedServerId: String) async {
        for server in serverStore.servers where server.id != selectedServerId {
            _ = stagePairedServerConnection(server)
            _ = await ensureConnectionReady(for: server)
        }
    }

    // MARK: - Network Path Monitoring

    /// Start monitoring network interface changes.
    ///
    /// Detects WiFi→cellular, LAN→Tailscale, and other interface transitions
    /// that make the current WebSocket endpoint unreachable. On change, clears
    /// stale LAN endpoints and forces an immediate reconnect to the paired
    /// (Tailscale) address — prevents burning reconnect attempts against a
    /// dead LAN IP when walking out of WiFi range.
    func startNetworkPathMonitor() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handleNetworkPathUpdate(path)
            }
        }

        let queue = DispatchQueue(label: Self.pathMonitorQueueLabel, qos: .utility)
        monitor.start(queue: queue)
    }

    // periphery:ignore - used by NetworkPathChangeTests via @testable import
    func stopNetworkPathMonitor() {
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        pathChangeDebounceTask?.cancel()
        pathChangeDebounceTask = nil
        lastPathInterfaceSignature = nil
        lastPathWasSatisfied = nil
    }

    private func handleNetworkPathUpdate(_ path: NWPath) {
        handleNetworkPathState(
            signature: Self.interfaceSignature(path),
            isSatisfied: path.status == .satisfied
        )
    }

    private func handleNetworkPathState(signature: String, isSatisfied: Bool) {
        // Skip the initial callback, but retain satisfaction independently of
        // interface identity. A transient unsatisfied path can recover with the
        // exact same interfaces and still requires a transport boundary.
        guard let previous = lastPathInterfaceSignature,
              let previousWasSatisfied = lastPathWasSatisfied else {
            lastPathInterfaceSignature = signature
            lastPathWasSatisfied = isSatisfied
            return
        }

        let isRecoveryBoundary = NetworkPathRecoveryDecision.isRecoveryBoundary(
            previousSignature: previous,
            previousWasSatisfied: previousWasSatisfied,
            nextSignature: signature,
            nextIsSatisfied: isSatisfied
        )
        lastPathInterfaceSignature = signature
        lastPathWasSatisfied = isSatisfied

        guard isSatisfied else {
            pathChangeDebounceTask?.cancel()
            pathChangeDebounceTask = nil
            if previousWasSatisfied || signature != previous {
                logger.warning("Network path unsatisfied (\(previous, privacy: .public) -> \(signature, privacy: .public))")
                ClientLog.info("Network", "Path unsatisfied", metadata: [
                    "from": previous,
                    "to": signature,
                ])
            }
            return
        }
        guard isRecoveryBoundary else { return }

        logger.warning("Network path changed: \(previous, privacy: .public) -> \(signature, privacy: .public)")
        ClientLog.info("Network", "Path changed", metadata: [
            "from": previous,
            "to": signature,
        ])

        // Debounce rapid interface bounces (WiFi association flicker)
        pathChangeDebounceTask?.cancel()
        pathChangeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pathChangeDebounceDelay)
            guard !Task.isCancelled else { return }
            self?.applyNetworkPathChange()
        }
    }

    private func applyNetworkPathChange() {
        // 1. Force reconnect on all connections BEFORE restarting LAN discovery.
        //    handleNetworkPathChange captures `wasOnLAN` before clearing the
        //    endpoint, so order matters — call it before lanDiscovery.stop()
        //    which also clears endpoints via the onUpdate callback.
        for (serverId, connection) in connections {
            if connection.credentials == nil {
                // A paired shell can exist before its first transport succeeds.
                // A new interface/VPN is a recovery boundary for that setup too.
                Task { @MainActor [weak self] in
                    await self?.recoverUnconfiguredServerAfterBoundary(serverId)
                }
            } else {
                connection.handleNetworkPathChange()
            }
        }

        // 2. Restart LAN discovery on the new network interface.
        //    stop() publishes [] which clears LAN endpoints (already done above).
        //    start() begins a fresh Bonjour search on the current interface.
        lanDiscovery.stop()
        lanDiscovery.start()
    }

    /// The embedded Tailscale node's SOCKS route appeared, moved, or went away.
    /// Transports read `TailnetTransportRoute` only when they build their
    /// URLSession, so rebuild every paired `*.ts.net` server that is not on LAN.
    func handleTailnetRouteChange() async {
        let serverIds = serverStore.servers
            .filter { ServerTLSTrustPolicy.isTailscaleHostname($0.host) }
            .filter { connections[$0.id]?.transportPath != .lan }
            .map(\.id)
        // Rebuild concurrently; one slow server must not delay the others.
        let retries = serverIds.map { serverId in
            Task { await retryServerConnection(serverId) }
        }
        for retry in retries { await retry.value }
    }

    /// Build a signature from non-loopback interface types + names.
    ///
    /// Changes when interfaces appear/disappear (WiFi→cellular, VPN up/down).
    /// Does NOT change for same-interface roaming (AP handoff on same WiFi).
    nonisolated static func interfaceSignature(_ path: NWPath) -> String {
        let sig = path.availableInterfaces
            .filter { $0.type != .loopback }
            .map { Self.interfaceTypeLabel($0.type) + ":" + $0.name }
            .sorted()
            .joined(separator: ",")
        return sig.isEmpty ? "none" : sig
    }

    nonisolated private static func interfaceTypeLabel(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cell"
        case .wiredEthernet: return "eth"
        case .loopback: return "lo"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    // MARK: - LAN Discovery

    func startLANDiscovery() {
        lanDiscovery.start()
    }

    private func applyLANDiscovery(_ endpoints: [LANDiscoveredEndpoint]) {
        for server in serverStore.servers {
            let endpoint = bestLANEndpoint(forServerId: server.id, candidates: endpoints)
            if let conn = connections[server.id] {
                conn.setDiscoveredLANEndpoint(endpoint)
            }
        }
    }

#if DEBUG
    // periphery:ignore - used by OppiTests via @testable import
    func _applyLANDiscoveryForTesting(_ endpoints: [LANDiscoveredEndpoint]) {
        for server in serverStore.servers {
            let endpoint = bestLANEndpoint(forServerId: server.id, candidates: endpoints)
            guard let connection = connections[server.id] else { continue }
            if let endpoint {
                connection._adoptVerifiedLANEndpointForTesting(endpoint)
            } else {
                connection.setDiscoveredLANEndpoint(nil)
            }
        }
    }

    // periphery:ignore - used by OppiTests via @testable import
    func _applyNetworkPathChangeForTesting() {
        applyNetworkPathChange()
    }
#endif

    private func bestLANEndpoint(forServerId serverId: String, candidates: [LANDiscoveredEndpoint]? = nil) -> LANDiscoveredEndpoint? {
        guard let server = serverStore.server(for: serverId) else {
            return nil
        }

        let normalizedServerId = normalizeFingerprint(server.id)
        guard !normalizedServerId.isEmpty else { return nil }

        let credentials = server.credentials
        let normalizedPinnedTLS = normalizeOptionalFingerprint(credentials.normalizedTLSCertFingerprint)
        let pool = candidates ?? lanDiscovery.endpoints

        let rankedCandidates = pool
            .filter { endpoint in
                let prefix = normalizeFingerprint(endpoint.serverFingerprintPrefix)
                return !prefix.isEmpty && normalizedServerId.hasPrefix(prefix)
            }
            .sorted { lhs, rhs in
                let lhsServerSpecificity = normalizeFingerprint(lhs.serverFingerprintPrefix).count
                let rhsServerSpecificity = normalizeFingerprint(rhs.serverFingerprintPrefix).count
                if lhsServerSpecificity != rhsServerSpecificity {
                    return lhsServerSpecificity > rhsServerSpecificity
                }

                let lhsTLSSpecificity = tlsPrefixSpecificityScore(
                    endpointTLSPrefix: lhs.tlsCertFingerprintPrefix,
                    normalizedPinnedTLS: normalizedPinnedTLS
                )
                let rhsTLSSpecificity = tlsPrefixSpecificityScore(
                    endpointTLSPrefix: rhs.tlsCertFingerprintPrefix,
                    normalizedPinnedTLS: normalizedPinnedTLS
                )
                if lhsTLSSpecificity != rhsTLSSpecificity {
                    return lhsTLSSpecificity > rhsTLSSpecificity
                }

                if lhs.host != rhs.host {
                    return lhs.host < rhs.host
                }
                return lhs.port < rhs.port
            }

        for candidate in rankedCandidates {
            guard let selection = LANEndpointSelection.select(
                credentials: credentials,
                discoveredEndpoint: candidate
            ) else {
                continue
            }

            if selection.transportPath == .lan {
                return candidate
            }
        }

        return nil
    }

    private func tlsPrefixSpecificityScore(
        endpointTLSPrefix: String?,
        normalizedPinnedTLS: String?
    ) -> Int {
        guard let normalizedPrefix = normalizeOptionalFingerprint(endpointTLSPrefix) else {
            return 0
        }

        guard let normalizedPinnedTLS else {
            return -1
        }

        return normalizedPinnedTLS.hasPrefix(normalizedPrefix) ? normalizedPrefix.count : -1
    }

    private func normalizeOptionalFingerprint(_ value: String?) -> String? {
        guard let value else { return nil }

        let normalized = normalizeFingerprint(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizeFingerprint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sha256:") {
            return String(trimmed.dropFirst("sha256:".count))
        }
        return trimmed
    }

    #if DEBUG
    // periphery:ignore - deterministic NWPath state seam for recovery tests
    func _handleNetworkPathStateForTesting(signature: String, isSatisfied: Bool) {
        handleNetworkPathState(signature: signature, isSatisfied: isSatisfied)
    }
    #endif

    // MARK: - Server Switching

    /// Prepare and switch the focused server. The previous server remains active
    /// while an unprepared HTTPS endpoint starts, so navigation never receives a
    /// disconnected sentinel.
    @discardableResult
    func switchToServerReady(
        _ serverId: String,
        shouldActivate: @escaping @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard let server = serverStore.server(for: serverId) else {
            logger.error("Cannot switch to unknown server \(serverId.prefix(16), privacy: .public)")
            return false
        }
        return await switchToServerReady(server, shouldActivate: shouldActivate)
    }

    @discardableResult
    func switchToServerReady(
        _ server: PairedServer,
        shouldActivate: @escaping @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard serverStore.server(for: server.id) != nil else { return false }
        if server.id == activeServerId, let connection = connections[server.id],
           connection.hasSameTransportIdentity(as: server.credentials),
           connection.hasViableConfiguredTransport {
            guard shouldActivate() else { return false }
            connection.applyPersistedSameRouteCredentials(server.credentials)
            return true
        }
        guard shouldActivate() else { return false }
        // Claim only a real pending selection; completion order must not override request order.
        selectionRevision += 1
        let requestedRevision = selectionRevision
        return await PreparedServerActivation.run(
            prepare: {
                let connection = await self.ensureConnectionReady(for: server)
                guard connection !== self.disconnectedSentinel,
                      connection.apiClient != nil else {
                    return nil
                }
                return connection
            },
            shouldActivate: {
                self.serverStore.server(for: server.id) != nil
                    && self.selectionRevision == requestedRevision
                    && shouldActivate()
            },
            activate: { connection in
                self.activatePreparedConnection(connection, server: server)
            }
        )
    }

    private func activatePreparedConnection(_ connection: ServerConnection, server: PairedServer) {
        activeServerId = server.id
        selectionRevision += 1
        MetricKitService.shared.setUploadClient(connection.apiClient)
        logger.warning("Switched to server \(server.name, privacy: .public) (\(server.id.prefix(16), privacy: .public))")
    }

    #if DEBUG
    /// Test-only synchronous switch for HTTP fixtures. HTTPS fixtures must use
    /// `switchToServerReady` to cover production behavior.
    @discardableResult
    func switchToServer(_ serverId: String) -> Bool {
        guard let server = serverStore.server(for: serverId) else { return false }
        return switchToServer(server)
    }

    @discardableResult
    func switchToServer(_ server: PairedServer) -> Bool {
        let connection = ensureConnection(for: server)
        guard connection !== disconnectedSentinel, connection.apiClient != nil else { return false }
        activatePreparedConnection(connection, server: server)
        return true
    }

    func addServer(_ server: PairedServer, switchTo: Bool = true) {
        serverStore.addOrUpdate(server)
        let connection = ensureConnection(for: server)
        if switchTo, connection !== disconnectedSentinel {
            activatePreparedConnection(connection, server: server)
        }
    }

    func prepareAllConnections() {
        for server in serverStore.servers {
            _ = ensureConnection(for: server)
        }
    }
    #endif

    // MARK: - API Clients

    func apiClient(for serverId: String) -> APIClient? {
        connections[serverId]?.apiClient
    }

    func apiClientReady(for serverId: String) async -> APIClient? {
        guard let server = serverStore.server(for: serverId) else { return nil }
        let connection = await ensureConnectionReady(for: server)
        guard connection !== disconnectedSentinel else { return nil }
        return connection.apiClient
    }

    // MARK: - Server Lifecycle

    @discardableResult
    func addServerReady(_ server: PairedServer, switchTo: Bool = true) async -> ServerPairingOutcome {
        if switchTo { selectionRevision += 1 }
        let requestedRevision = selectionRevision
        let previous = serverStore.server(for: server.id)
        serverStore.addOrUpdate(
            server,
            replacingStoredDeviceCredential: server.deviceCredential == nil && !server.token.isEmpty
        )
        // Re-pair preserves local badge via ServerStore. Configure from
        // that canonical merged row, not the incoming automatic PairedServer.
        guard let canonical = serverStore.server(for: server.id) else { return .failed }
        let lifetime = serverLifetime(for: server.id)
        let connection = await ensureConnectionReady(for: canonical)
        guard serverLifetimes[server.id] == lifetime else { return .failed }
        guard connection !== disconnectedSentinel else {
            // Transport setup failed closed. Do not leave unusable replacement
            // credentials persisted; restore the prior pairing when this was a re-pair.
            // Removal or a newer re-pair may have replaced this row while
            // preparation was suspended; never resurrect/overwrite either.
            if serverStore.server(for: server.id) == canonical {
                if let previous {
                    // Restore the prior pairing, including a stored at_ that a
                    // failed dt_-only re-pair must not leave discarded.
                    serverStore.addOrUpdate(
                        previous,
                        replacingStoredDeviceCredential: previous.deviceCredential != nil
                            || !previous.token.isEmpty
                    )
                } else {
                    serverStore.remove(id: server.id)
                }
            }
            return .failed
        }
        if switchTo {
            guard selectionRevision == requestedRevision,
                  serverStore.server(for: server.id) != nil else { return .pairedWithoutSelection }
            activatePreparedConnection(connection, server: canonical)
            return .selected
        }
        return .pairedWithoutSelection
    }

    /// Remove a server. Cleans up all associated data.
    func removeServer(id: String) async {
        // Revoke pending activation even when an inactive pairing is removed.
        selectionRevision += 1
        serverStore.remove(id: id)
        let removedLifetime = UUID()
        serverLifetimes[id] = removedLifetime
        connectionPreparationTasks.removeValue(forKey: id)?.task.cancel()
        preparingServerIds.remove(id)
        retryPreparationAfterBoundaryServerIds.remove(id)
        // Remove identity before suspension so a re-pair cannot observe or reuse it.
        let removedConnection = connections.removeValue(forKey: id)
        if let conn = removedConnection {
            conn.disconnectSession()
            conn.disconnectStream()
            conn.disconnectAppEventStream()
            await conn.shutdownTransport()
        }

        logger.warning("Removed server \(id.prefix(16), privacy: .public)")

        // If re-paired during shutdown, this removal no longer owns the row.
        guard serverLifetimes[id] == removedLifetime,
              serverStore.server(for: id) == nil else { return }
        // If we removed the active server, switch to the first remaining
        if id == activeServerId {
            activeServerId = nil
            if let firstServer = serverStore.servers.first {
                _ = restoreActiveServer(firstServer.id)
                await prepareSelectedServerShell(for: firstServer)
            }
        }
    }

    // MARK: - Multi-Server Refresh

    /// Retry setup for a shell that has never established a usable transport.
    /// Boundaries coalesce with an in-flight attempt and request one fresh pass
    /// afterward, while terminal integrity/auth failures remain user-controlled.
    func recoverUnconfiguredServerAfterBoundary(_ serverId: String) async {
        guard let connection = connections[serverId], connection.credentials == nil else {
            return
        }
        guard connection.canAutomaticallyRetryInitialTransport else { return }
        if connectionPreparationTasks[serverId] != nil {
            retryPreparationAfterBoundaryServerIds.insert(serverId)
            return
        }
        await refreshServer(serverId, force: true)
    }

    /// User-requested retry may re-attempt a terminal setup failure. Configured
    /// connections first run their normal transport-boundary recovery, then
    /// refresh cached projections against the selected lane.
    func retryServerConnection(_ serverId: String) async {
        guard let server = serverStore.server(for: serverId) else { return }
        let connection = await ensureConnectionReady(
            for: server,
            forceReconfigure: true
        )
        guard connection.credentials != nil, connection.apiClient != nil else {
            // HTTPS/WSS is not ready yet. Leave lastSyncFailed unchanged so a
            // later catalog/session request can still be the first failure.
            return
        }
        await refreshServer(serverId, force: true)
    }

    /// Refresh workspace + session data for one paired server.
    ///
    /// Server-scoped surfaces use this instead of waiting on every paired host.
    /// A slow or outdated inactive server must not delay the selected server's inbox.
    func refreshServer(_ serverId: String, force: Bool = true) async {
        guard let server = serverStore.server(for: serverId) else {
            logger.error("Cannot refresh unknown server \(serverId.prefix(16), privacy: .public)")
            return
        }

        let connection = await ensureConnectionReady(for: server)
        guard connection !== disconnectedSentinel, connection.apiClient != nil else {
            logger.error("Cannot refresh server without a configured API client")
            // Missing apiClient means the request was not attempted. Do not
            // treat transport preparation as a workspace/session sync failure.
            return
        }

        if serverId == activeServerId {
            MetricKitService.shared.setUploadClient(connection.apiClient)
        }
        await connection.refreshWorkspaceAndSessionLists(force: force)
    }

    /// Refresh workspace + session data from ALL paired servers.
    ///
    /// Uses single-flight coalescing: concurrent callers share one refresh
    /// cycle. Prevents the double-refresh race between `OppiApp.reconnectOnLaunch`
    /// and inbox/root `.task` from overwriting freshness state.
    func refreshAllServers() async {
        if let inFlight = refreshAllTask {
            await inFlight.value
            return
        }

        let task = Task { @MainActor in
            #if DEBUG
            _onRefreshAllServersForTesting?()
            #endif
            await _refreshAllServersImpl()
        }
        refreshAllTask = task
        await task.value
        refreshAllTask = nil
    }

    private func _refreshAllServersImpl() async {
        // Keep refresh order deterministic. `refreshServer` creates connections
        // as needed, while selected-server callers avoid this fan-out entirely.
        for server in serverStore.servers {
            await refreshServer(server.id, force: true)
        }
    }

    /// Refresh non-focused servers (called on foreground recovery).
    /// The focused server is handled by `ServerConnection.reconnectIfNeeded()`.
    func refreshInactiveServers() async {
        for (serverId, connection) in connections where serverId != activeServerId {
            #if DEBUG
            _onRefreshInactiveServerForTesting?(serverId)
            #endif
            guard connection.apiClient != nil else { continue }
            await connection.refreshWorkspaceAndSessionLists(force: true)
        }
    }

    // MARK: - Push Registration

    /// Register push token with all paired servers.
    func registerPushWithAllServers() async {
        guard ReleaseFeatures.remotePushNotificationsEnabled else {
            return
        }
        await PushRegistration.shared.registerWithAllServers(using: self)
    }

    // MARK: - Cross-Server Queries

    struct SessionLookupResult {
        let serverId: String
        let connection: ServerConnection
    }

    // periphery:ignore - used by ConnectionCoordinatorTests via @testable import
    /// All sessions across all servers, ordered by last activity.
    var allSessions: [Session] {
        connections.values
            .flatMap { $0.sessionStore.listProjectionSessions }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Whether any server has work whose live streams should remain eligible for
    /// the app's background keep-alive window.
    var hasActiveAgentTransport: Bool {
        BackgroundKeepAlive.hasActiveAgent(in: connections.values)
    }

    /// Whether any active playback still depends on live focused-session delivery.
    var hasActiveAudioTransportPlayback: Bool {
        connections.values.contains { $0.audioPlayer.hasActiveLiveTransportPlayback }
    }

    func prepareAllForBackground() {
        for connection in connections.values {
            connection.prepareForBackground()
        }
    }

    /// Find a session by ID across all servers.
    func findSession(id: String) -> SessionLookupResult? {
        for (serverId, conn) in connections {
            if conn.sessionStore.session(id: id) != nil {
                return SessionLookupResult(serverId: serverId, connection: conn)
            }
        }
        return nil
    }

    /// Test seam: replace generic `GET /sessions/:id` during deep-link resolve.
    var _getSessionRecordForTesting: ((_ serverId: String, _ sessionId: String) async throws -> Session)?

    /// Resolve a deep-linked session from cache, then from hinted-server HTTP.
    func findOrFetchSession(id: String) async -> SessionLookupResult? {
        if let found = findSession(id: id) {
            return found
        }

        let hintedServerIds = SessionDeepLinkSessionResolution.fetchServerIds(
            activeServerId: activeServerId,
            serverIdsWithPendingAsk: connections.compactMap { serverId, connection in
                connection.askRequestStore.hasPending(for: id) ? serverId : nil
            }
        )

        for serverId in hintedServerIds {
            guard let connection = connections[serverId] else { continue }
            do {
                let session: Session
                if let fetchHook = _getSessionRecordForTesting {
                    session = try await fetchHook(serverId, id)
                } else if let api = await apiClientReady(for: serverId) {
                    session = try await api.getSessionRecord(sessionId: id)
                } else {
                    continue
                }
                connection.sessionStore.upsert(session)
                return SessionLookupResult(serverId: serverId, connection: connection)
            } catch {
                continue
            }
        }

        return nil
    }

    /// Get the connection for a specific server.
    func connection(for serverId: String) -> ServerConnection? {
        connections[serverId]
    }
}
