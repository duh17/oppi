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
    var _initialLANEndpointForTesting: (@MainActor (String) async -> LANDiscoveredEndpoint?)?
    var _serverInfoBootstrapForTesting: ServerConnectionInfoBootstrap?
    var _apiClientFactoryForTesting: ServerConnectionAPIClientFactory?
    var _migrateDeviceIfNeededForTesting: (@MainActor (PairedServer, Bool) async -> PairedServer)?
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
            if existing.credentials != server.credentials {
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
        return connection
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
        if let preparation = connectionPreparationTasks[serverId] {
            let prepared = await preparation.task.value ?? disconnectedSentinel
            let latestServer = serverStore.server(for: serverId) ?? server
            let requestChanged = preparation.credentials != latestServer.credentials
            if forceReconfigure, !preparation.isForced || requestChanged {
                finishConnectionPreparation(serverId: serverId, id: preparation.id)
                return await ensureConnectionReady(
                    for: latestServer,
                    forceReconfigure: true
                )
            }
            if !forceReconfigure,
               latestServer.deviceCredential == nil,
               latestServer.token.hasPrefix("dt_") {
                // After an in-flight leftover prepare finishes, try once more
                // to bind a replacement at_ that arrived while we waited.
                // Do not force migrate or reconfigure: a failed leftover POST
                // must stay negatively cached, and the connection only rebinds
                // when this retry actually produces a replacement.
                finishConnectionPreparation(serverId: serverId, id: preparation.id)
                return await ensureConnectionReady(for: latestServer)
            }
            return prepared
        }
        let latestServer = serverStore.server(for: serverId) ?? server
        if !forceReconfigure,
           let existing = connections[serverId],
           existing.credentials == latestServer.credentials,
           existing.apiClient != nil,
           latestServer.deviceCredential != nil || !latestServer.token.hasPrefix("dt_") {
            return existing
        }

        preparingServerIds.insert(serverId)
        let task = Task<ServerConnection?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            let migrated = await self.migrateLegacyDeviceIfNeeded(
                self.serverStore.server(for: serverId) ?? latestServer,
                force: forceReconfigure
            )
            return await self.prepareConnection(for: migrated, forceReconfigure: forceReconfigure)
        }
        let preparationID = UUID()
        connectionPreparationTasks[serverId] = ConnectionPreparation(
            id: preparationID,
            credentials: latestServer.credentials,
            isForced: forceReconfigure,
            task: task
        )
        let prepared = await task.value
        finishConnectionPreparation(serverId: serverId, id: preparationID)

        let retryAfterBoundary = retryPreparationAfterBoundaryServerIds.remove(serverId) != nil
        if prepared?.credentials == nil,
           retryAfterBoundary,
           connections[serverId]?.canAutomaticallyRetryInitialTransport == true {
            return await ensureConnectionReady(for: serverStore.server(for: serverId) ?? server)
        }
        return prepared ?? disconnectedSentinel
    }

    private func finishConnectionPreparation(serverId: String, id: UUID) {
        guard connectionPreparationTasks[serverId]?.id == id else { return }
        connectionPreparationTasks.removeValue(forKey: serverId)
        preparingServerIds.remove(serverId)
    }

    private func prepareConnection(
        for server: PairedServer,
        forceReconfigure: Bool = false
    ) async -> ServerConnection? {
        let serverId = server.id
        let initialLANEndpoint = await initialLANEndpoint(for: server)
        if let existing = connections[serverId] {
            if forceReconfigure || existing.credentials != server.credentials {
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
                    preservingPersistentStreams: forceReconfigure
                ) else {
                    logger.error("Failed to prepare paired server transport")
                    return nil
                }
                await reconcileLANDiscoveredDuringTransportSetup(
                    connection: existing,
                    server: server,
                    initialEndpoint: initialLANEndpoint
                )
            }
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
        ) else {
            logger.error("Failed to configure connection for \(server.name, privacy: .public)")
            return nil
        }
        await reconcileLANDiscoveredDuringTransportSetup(
            connection: connection,
            server: server,
            initialEndpoint: initialLANEndpoint
        )
        initializeStores(for: connection, serverId: serverId)
        #if DEBUG
        _onConnectionPreparedForTesting?(serverId, connection)
        #endif
        connections[serverId] = connection
        logger.warning("Created ready connection for \(server.name, privacy: .public) (\(serverId.prefix(16), privacy: .public))")
        return connection
    }

    /// Migrate a leftover `dt_` paired server to a device-key credential before
    /// network use, including when a live connection already exists. The store
    /// is updated so later connections skip the one-time migration. Failure
    /// leaves the leftover token usable (compat window).
    private func migrateLegacyDeviceIfNeeded(
        _ server: PairedServer,
        force: Bool = false
    ) async -> PairedServer {
        #if DEBUG
        if let migrate = _migrateDeviceIfNeededForTesting {
            return await migrate(server, force)
        }
        #endif
        return await deviceAuthMigrationService().migrateIfNeeded(server, force: force)
    }

    private var cachedDeviceAuthMigrationService: DeviceAuthMigrationService?

    private func deviceAuthMigrationService() -> DeviceAuthMigrationService {
        if let cachedDeviceAuthMigrationService {
            return cachedDeviceAuthMigrationService
        }
        let service = DeviceAuthMigrationService(persist: { [weak self] migrated in
            guard let self else {
                throw KeychainCredentialMergeError.itemNotFound
            }
            try self.serverStore.persistServer(migrated)
        })
        cachedDeviceAuthMigrationService = service
        return service
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
        initialEndpoint: LANDiscoveredEndpoint?
    ) async {
        var reconciledEndpoint = initialEndpoint
        while true {
            let latestEndpoint = await initialLANEndpoint(for: server)
            guard latestEndpoint != reconciledEndpoint else { return }

            // Bonjour can change again while an asynchronous transport setup
            // is in flight. Repeat after each transition to close that window.
            let transition = connection.setDiscoveredLANEndpoint(latestEndpoint)
            await transition?.value
            reconciledEndpoint = latestEndpoint
        }
    }

    private func configureConnection(
        _ connection: ServerConnection,
        credentials: ServerCredentials,
        preservingPersistentStreams: Bool = false
    ) async -> Bool {
        let deviceCredentialObserver: ServerConnectionDeviceCredentialObserver = { [weak self] result in
            guard let self, let serverId = credentials.normalizedServerFingerprint else { return }
            do {
                try self.serverStore.persistDeviceCredentialRefresh(
                    id: serverId,
                    result: result
                )
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
        if server.id == activeServerId,
           let connection = connections[server.id],
           connection.credentials == server.credentials,
           connection.apiClient != nil {
            return shouldActivate()
        }

        return await PreparedServerActivation.run(
            prepare: {
                let connection = await self.ensureConnectionReady(for: server)
                guard connection !== self.disconnectedSentinel,
                      connection.apiClient != nil else {
                    return nil
                }
                return connection
            },
            shouldActivate: shouldActivate,
            activate: { connection in
                self.activatePreparedConnection(connection, server: server)
            }
        )
    }

    private func activatePreparedConnection(_ connection: ServerConnection, server: PairedServer) {
        activeServerId = server.id
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
    func addServerReady(_ server: PairedServer, switchTo: Bool = true) async -> Bool {
        let previous = serverStore.server(for: server.id)
        serverStore.addOrUpdate(
            server,
            replacingStoredDeviceCredential: server.deviceCredential == nil && !server.token.isEmpty
        )
        // Re-pair preserves local badge via ServerStore. Configure from
        // that canonical merged row, not the incoming automatic PairedServer.
        guard let canonical = serverStore.server(for: server.id) else { return false }
        let connection = await ensureConnectionReady(for: canonical)
        guard connection !== disconnectedSentinel else {
            // Transport setup failed closed. Do not leave unusable replacement
            // credentials persisted; restore the prior pairing when this was a re-pair.
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
            return false
        }
        if switchTo {
            activatePreparedConnection(connection, server: canonical)
        }
        return true
    }

    /// Remove a server. Cleans up all associated data.
    func removeServer(id: String) async {
        // Disconnect and remove the server's connection
        if let conn = connections[id] {
            conn.disconnectSession()
            conn.disconnectStream()
            conn.disconnectAppEventStream()
            await conn.shutdownTransport()
        }
        connections.removeValue(forKey: id)

        serverStore.remove(id: id)

        logger.warning("Removed server \(id.prefix(16), privacy: .public)")

        // If we removed the active server, switch to the first remaining
        if id == activeServerId {
            activeServerId = nil
            if let firstServer = serverStore.servers.first {
                _ = await switchToServerReady(firstServer)
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
