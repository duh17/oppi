import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "ServerStore")

/// Manages the list of paired servers.
///
/// Pure data store — no networking, no health checks.
/// Persists via `KeychainService` (tokens) + UserDefaults (order/index).
@MainActor @Observable
final class ServerStore {
    private(set) var servers: [PairedServer] = []

    init() {
        load()
    }

    // MARK: - CRUD

    /// Add a new paired server. If a server with the same fingerprint exists,
    /// updates its credentials instead (re-pair scenario).
    func addOrUpdate(_ server: PairedServer) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            // Re-pair: update credentials, preserve local metadata
            var existing = servers[idx]
            existing.updateCredentials(from: server.credentials)
            servers[idx] = existing
            save(existing)
            logger.info("Updated server \(server.name, privacy: .public) (re-pair)")
        } else {
            var newServer = server
            newServer.sortOrder = servers.count
            servers.append(newServer)
            save(newServer)
            logger.info("Added server \(server.name, privacy: .public)")
        }
        saveIndex()
    }

    /// Add or update from validated `ServerCredentials`.
    /// Returns the `PairedServer` (new or updated), or `nil` if credentials lack a fingerprint.
    @discardableResult
    func addOrUpdate(from credentials: ServerCredentials) -> PairedServer? {
        guard let server = PairedServer(from: credentials, sortOrder: servers.count) else {
            logger.error("Cannot add server: credentials missing fingerprint")
            return nil
        }
        addOrUpdate(server)
        return self.server(for: server.id)
    }

    /// Remove a paired server by ID.
    func remove(id: String) {
        servers.removeAll { $0.id == id }
        KeychainService.deleteServer(id: id)
        saveIndex()
        logger.info("Removed server \(id, privacy: .public)")
    }

    /// Rename a server.
    func rename(id: String, to name: String) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].name = name
        save(servers[idx])
    }

    /// Update the badge icon for a server.
    func setBadgeIcon(id: String, to icon: ServerBadgeIcon) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].badgeIcon = icon
        save(servers[idx])
    }

    /// Update the badge color for a server.
    func setBadgeColor(id: String, to color: ServerBadgeColor) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].badgeColor = color
        save(servers[idx])
    }

    /// Look up a server by fingerprint ID.
    func server(for id: String) -> PairedServer? {
        servers.first { $0.id == id }
    }

    /// Look up which server owns a given host:port combination.
    func server(forHost host: String, port: Int) -> PairedServer? {
        servers.first { $0.host == host && $0.port == port }
    }

    // MARK: - Persistence

    private func load() {
        servers = KeychainService.loadServers()
        servers.sort { $0.sortOrder < $1.sortOrder }
    }

    private func save(_ server: PairedServer) {
        do {
            try KeychainService.saveServer(server)
        } catch {
            logger.error("Failed to save server \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persist the ordered list of server IDs to UserDefaults.
    private func saveIndex() {
        let ids = servers.map(\.id)
        UserDefaults.standard.set(ids, forKey: "pairedServerIds")
    }
}
