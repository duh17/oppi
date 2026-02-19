import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Coordinator")

/// Orchestrates multi-server connections.
///
/// Owns the single `ServerConnection` (one WebSocket at a time) and coordinates
/// server switching across all stores. Each server gets isolated session/permission
/// data via the stores' internal partitioning.
///
/// Views use `@Environment(ConnectionCoordinator.self)` for multi-server operations
/// and `@Environment(ServerConnection.self)` for active-connection operations.
@MainActor @Observable
final class ConnectionCoordinator {
    let connection: ServerConnection
    let serverStore: ServerStore

    /// Currently active server ID (fingerprint).
    private(set) var activeServerId: String?

    /// API clients keyed by server ID — created on demand, cached for reuse.
    private var apiClients: [String: APIClient] = [:]

    init(serverStore: ServerStore) {
        self.serverStore = serverStore
        self.connection = ServerConnection()
    }

    // MARK: - Server Switching

    /// Switch all stores + connection to target a different server.
    ///
    /// Coordinates: SessionStore partition, PermissionStore partition,
    /// WorkspaceStore server context, and ServerConnection credentials.
    /// Returns false if the connection can't be configured (policy/URL failure).
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

        // Switch store partitions BEFORE connection so message routing
        // writes to the correct server's data.
        connection.sessionStore.switchServer(to: serverId)
        connection.permissionStore.switchServer(to: serverId)

        activeServerId = serverId

        // Configure connection (tears down WS if server changed)
        let result = connection.switchServer(to: server)

        // Cache API client for this server
        if apiClients[serverId] == nil, let baseURL = server.baseURL {
            apiClients[serverId] = APIClient(baseURL: baseURL, token: server.token)
        }

        logger.info("Switched to server \(server.name, privacy: .public) (\(serverId.prefix(16), privacy: .public))")
        return result
    }

    // MARK: - API Clients

    /// Get an API client for a specific server (creates on demand).
    func apiClient(for serverId: String) -> APIClient? {
        if let cached = apiClients[serverId] { return cached }

        guard let server = serverStore.server(for: serverId),
              let baseURL = server.baseURL else {
            return nil
        }

        let client = APIClient(baseURL: baseURL, token: server.token)
        apiClients[serverId] = client
        return client
    }

    /// Invalidate cached API client (e.g. after credential change).
    func invalidateAPIClient(for serverId: String) {
        apiClients.removeValue(forKey: serverId)
    }

    // MARK: - Server Lifecycle

    /// Add a new server. Creates the data partitions and optionally switches to it.
    func addServer(_ server: PairedServer, switchTo: Bool = true) {
        serverStore.addOrUpdate(server)

        // Ensure partitions exist
        connection.sessionStore.switchServer(to: server.id)
        connection.sessionStore.switchServer(to: activeServerId ?? server.id)

        connection.permissionStore.switchServer(to: server.id)
        connection.permissionStore.switchServer(to: activeServerId ?? server.id)

        if switchTo {
            switchToServer(server)
        }
    }

    /// Remove a server. Cleans up all associated data.
    func removeServer(id: String) {
        // Disconnect if removing the active server
        if id == activeServerId {
            connection.disconnectSession()
        }

        // Clean all stores
        serverStore.remove(id: id)
        connection.sessionStore.removeServer(id)
        connection.permissionStore.removeServer(id)
        connection.workspaceStore.removeServer(id)
        apiClients.removeValue(forKey: id)

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

    /// Refresh workspace + session data from ALL paired servers in parallel.
    ///
    /// The active server goes through the full ServerConnection refresh path.
    /// Non-active servers get lightweight REST-only refreshes.
    func refreshAllServers() async {
        let servers = serverStore.servers

        // Keep workspace server order in sync with server store
        connection.workspaceStore.serverOrder = servers.map(\.id)

        // Active server: full refresh through ServerConnection
        if let activeId = activeServerId {
            await connection.refreshWorkspaceAndSessionLists(force: true)

            // Sync single-server data into per-server slot
            connection.workspaceStore.workspacesByServer[activeId] = connection.workspaceStore.workspaces
            connection.workspaceStore.skillsByServer[activeId] = connection.workspaceStore.skills
            if !connection.workspaceStore.serverOrder.contains(activeId) {
                connection.workspaceStore.serverOrder.append(activeId)
            }
            connection.workspaceStore.serverFreshness[activeId] = ServerSyncState()
            connection.workspaceStore.serverFreshness[activeId]?.markSyncSucceeded()
        }

        // Non-active servers: REST-only refresh (sequential to avoid isolation issues)
        let inactiveServers = servers.filter { $0.id != activeServerId }
        for server in inactiveServers {
            await refreshInactiveServer(server)
        }

        // Sync flat lists for backward compat
        connection.workspaceStore.workspaces = connection.workspaceStore.allWorkspaces
        connection.workspaceStore.skills = connection.workspaceStore.allSkills
        connection.workspaceStore.isLoaded = true
    }

    /// Refresh only the non-active servers (lightweight REST).
    /// Called on foreground recovery — the active server is handled by
    /// `ServerConnection.reconnectIfNeeded()` separately.
    func refreshInactiveServers() async {
        let inactiveServers = serverStore.servers.filter { $0.id != activeServerId }
        for server in inactiveServers {
            await refreshInactiveServer(server)
        }

        // Sync flat lists
        connection.workspaceStore.workspaces = connection.workspaceStore.allWorkspaces
        connection.workspaceStore.skills = connection.workspaceStore.allSkills
    }

    /// Refresh workspace + session data from a single inactive server.
    private func refreshInactiveServer(_ server: PairedServer) async {
        let serverId = server.id
        guard let api = apiClient(for: serverId) else { return }

        // Workspaces + skills
        do {
            let workspaces = try await api.listWorkspaces()
            let skills = try await api.listSkills()

            connection.workspaceStore.workspacesByServer[serverId] = workspaces
            connection.workspaceStore.skillsByServer[serverId] = skills
            if !connection.workspaceStore.serverOrder.contains(serverId) {
                connection.workspaceStore.serverOrder.append(serverId)
            }
            connection.workspaceStore.serverFreshness[serverId] = ServerSyncState()
            connection.workspaceStore.serverFreshness[serverId]?.markSyncSucceeded()

            logger.info("Refreshed \(workspaces.count) workspaces from inactive server \(serverId.prefix(16), privacy: .public)")
        } catch {
            if connection.workspaceStore.serverFreshness[serverId] == nil {
                connection.workspaceStore.serverFreshness[serverId] = ServerSyncState()
            }
            connection.workspaceStore.serverFreshness[serverId]?.markSyncFailed()
            logger.error("Failed to refresh inactive server \(serverId.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Sessions — temporarily switch partition, then switch back
        do {
            let sessions = try await api.listSessions()
            let previousActiveServer = connection.sessionStore.activeServerId
            connection.sessionStore.switchServer(to: serverId)
            connection.sessionStore.applyServerSnapshot(sessions)
            if let prev = previousActiveServer {
                connection.sessionStore.switchServer(to: prev)
            }
        } catch {
            logger.error("Failed to refresh sessions from inactive server \(serverId.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
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
}
