import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Coordinator")

/// Orchestrates concurrent multi-server connections.
///
/// Each paired server gets its own `ServerConnection` with a persistent
/// `/stream` WebSocket, its own stores, reducer, and coalescer. The
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

    // Legacy compatibility: `connection` forwards to `activeConnection`.
    var connection: ServerConnection { activeConnection }

    init(serverStore: ServerStore) {
        self.serverStore = serverStore
    }

    // MARK: - Connection Pool

    /// Get or create a ServerConnection for a specific server.
    @discardableResult
    func ensureConnection(for server: PairedServer) -> ServerConnection {
        let serverId = server.id

        if let existing = connections[serverId] {
            return existing
        }

        let conn = ServerConnection()
        guard conn.configure(credentials: server.credentials) else {
            logger.error("Failed to configure connection for \(server.name, privacy: .public)")
            return disconnectedSentinel
        }

        // Initialize the stores' active partition to this server
        conn.sessionStore.switchServer(to: serverId)
        conn.permissionStore.switchServer(to: serverId)
        conn.workspaceStore.switchServer(to: serverId)

        connections[serverId] = conn
        logger.info("Created connection for \(server.name, privacy: .public) (\(serverId.prefix(16), privacy: .public))")
        return conn
    }

    /// Open `/stream` WebSocket for a server's connection (if not already connected).
    func connectStream(for serverId: String) {
        connections[serverId]?.connectStream()
    }

    /// Open `/stream` WebSocket for ALL paired servers.
    func connectAllStreams() {
        for server in serverStore.servers {
            let conn = ensureConnection(for: server)
            conn.connectStream()
        }
    }

    // MARK: - Server Switching

    /// Switch the focused server. The previous server's WS stays open.
    @discardableResult
    func switchToServer(_ serverId: String) -> Bool {
        guard serverId != activeServerId else { return true }

        guard let server = serverStore.server(for: serverId) else {
            logger.error("Cannot switch to unknown server \(serverId, privacy: .public)")
            return false
        }

        return switchToServer(server)
    }

    /// Switch to a specific PairedServer instance.
    @discardableResult
    func switchToServer(_ server: PairedServer) -> Bool {
        let serverId = server.id

        // Ensure connection exists and is configured
        let conn = ensureConnection(for: server)
        guard conn.credentials != nil else { return false }

        activeServerId = serverId

        logger.info("Switched to server \(server.name, privacy: .public) (\(serverId.prefix(16), privacy: .public))")
        return true
    }

    // MARK: - API Clients

    /// Get an API client for a specific server (from its connection).
    func apiClient(for serverId: String) -> APIClient? {
        connections[serverId]?.apiClient
    }

    // MARK: - Server Lifecycle

    /// Add a new server. Creates the connection and optionally switches to it.
    func addServer(_ server: PairedServer, switchTo: Bool = true) {
        serverStore.addOrUpdate(server)

        let conn = ensureConnection(for: server)
        conn.connectStream()

        if switchTo {
            switchToServer(server)
        }
    }

    /// Remove a server. Cleans up all associated data.
    func removeServer(id: String) {
        // Disconnect and remove the server's connection
        if let conn = connections[id] {
            conn.disconnectSession()
            conn.disconnectStream()
        }
        connections.removeValue(forKey: id)

        serverStore.remove(id: id)

        logger.info("Removed server \(id.prefix(16), privacy: .public)")

        // If we removed the active server, switch to the first remaining
        if id == activeServerId {
            activeServerId = nil
            if let firstServer = serverStore.servers.first {
                switchToServer(firstServer)
            }
        }
    }

    // MARK: - Multi-Server Refresh

    /// Refresh workspace + session data from ALL paired servers.
    func refreshAllServers() async {
        for (serverId, conn) in connections {
            guard let api = conn.apiClient else { continue }

            // Workspace + skill catalogs
            guard serverStore.server(for: serverId) != nil else { continue }
            await conn.workspaceStore.loadServer(serverId: serverId, api: api)

            // Sessions
            if serverId == activeServerId {
                await conn.refreshSessionList(force: true)
            } else {
                await refreshServerSessions(serverId: serverId, conn: conn, api: api)
            }
        }

        // Also load workspace catalogs from any servers not yet connected
        let servers = serverStore.servers
        await activeConnection.workspaceStore.loadAll(servers: servers)
    }

    /// Refresh non-focused servers (called on foreground recovery).
    /// The focused server is handled by `ServerConnection.reconnectIfNeeded()`.
    func refreshInactiveServers() async {
        for (serverId, conn) in connections where serverId != activeServerId {
            // Ensure the /stream WebSocket is alive. If it died during background
            // (max reconnect attempts exhausted), restart it.
            if conn.wsClient?.status == .disconnected {
                conn.connectStream()
            }

            guard let api = conn.apiClient else { continue }
            await conn.workspaceStore.loadServer(serverId: serverId, api: api)
            await refreshServerSessions(serverId: serverId, conn: conn, api: api)
        }
    }

    /// Refresh sessions for a specific server connection.
    private func refreshServerSessions(serverId: String, conn: ServerConnection, api: APIClient) async {
        do {
            let sessions = try await api.listSessions()
            conn.sessionStore.applyServerSnapshot(sessions)
        } catch {
            logger.error("Failed to refresh sessions from server \(serverId.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Push Registration

    /// Register push token with all paired servers.
    func registerPushWithAllServers() async {
        guard ReleaseFeatures.pushNotificationsEnabled else {
            return
        }
        await PushRegistration.shared.registerWithAllServers(serverStore.servers)
    }

    // MARK: - Cross-Server Queries

    struct SessionLookupResult {
        let session: Session
        let serverId: String
        let connection: ServerConnection
    }

    /// All sessions across all servers, ordered by last activity.
    var allSessions: [Session] {
        connections.values
            .flatMap { $0.sessionStore.sessions }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// All pending permissions across all servers.
    var allPendingPermissions: [PermissionRequest] {
        connections.values.flatMap { $0.permissionStore.pending }
    }

    /// Total pending permission count across all servers.
    var allPendingPermissionCount: Int {
        connections.values.reduce(0) { $0 + $1.permissionStore.count }
    }

    /// Find a session by ID across all servers.
    func findSession(id: String) -> SessionLookupResult? {
        for (serverId, conn) in connections {
            if let session = conn.sessionStore.session(id: id) {
                return SessionLookupResult(session: session, serverId: serverId, connection: conn)
            }
        }
        return nil
    }

    /// Get the connection for a specific server.
    func connection(for serverId: String) -> ServerConnection? {
        connections[serverId]
    }
}
