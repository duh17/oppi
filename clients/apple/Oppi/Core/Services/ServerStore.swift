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

    /// Add a new paired server, or update an existing one's credentials
    /// (re-pair). Non-throwing UI convenience: a Keychain write failure is
    /// logged. Use `persistServer(_:)` when the caller must fail safely on a
    /// persistence failure (device-key migration).
    func addOrUpdate(_ server: PairedServer) {
        do {
            try persistServer(server)
        } catch {
            logger.error("Failed to save server \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persist a paired server, throwing when the Keychain write fails.
    ///
    /// The record is written through BEFORE the in-memory list is mutated, so a
    /// caller that catches the error observes the previous durable state (no
    /// half-applied in-memory credential).
    func persistServer(_ server: PairedServer) throws {
        let toSave: PairedServer
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            var existing = servers[idx]
            existing.updateCredentials(from: server.credentials)
            toSave = existing
        } else {
            var newServer = server
            newServer.sortOrder = servers.count
            toSave = newServer
        }

        try save(toSave)

        if let idx = servers.firstIndex(where: { $0.id == toSave.id }) {
            servers[idx] = toSave
        } else {
            servers.append(toSave)
        }
        saveIndex()
    }

    // periphery:ignore - used by ServerStoreTests via @testable import
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
        logger.warning("Removed server \(id.prefix(16), privacy: .public)")
    }

    /// Update the badge icon for a server.
    func setBadgeIcon(id: String, to icon: ServerBadgeIcon) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].badgeIcon = icon
        do {
            try save(servers[idx])
        } catch {
            logger.error("Failed to save badge icon for \(id.prefix(16), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persist a device-credential refresh, merging against the latest stored
    /// Keychain record so a concurrent writer in another process cannot roll it back.
    @discardableResult
    func persistDeviceCredentialRefresh(
        id: String,
        result: DeviceAuthRefreshResult
    ) throws -> DeviceCredential {
        guard servers.contains(where: { $0.id == id }) else {
            throw KeychainCredentialMergeError.itemNotFound
        }
        let merged = try KeychainDeviceCredentialMerger.mergeRefresh(
            serverId: id,
            accessToken: result.accessToken,
            expiresAt: Int64(result.expiresAt),
            refreshChallenge: result.refreshChallenge
        )
        if let idx = servers.firstIndex(where: { $0.id == id }) {
            servers[idx].deviceCredential = merged
        }
        saveIndex()
        return merged
    }

    /// Look up a server by fingerprint ID.
    func server(for id: String) -> PairedServer? {
        servers.first { $0.id == id }
    }

    // periphery:ignore - used by ServerStoreTests via @testable import
    /// Look up which server owns a given host:port combination.
    func server(forHost host: String, port: Int) -> PairedServer? {
        servers.first { $0.host == host && $0.port == port }
    }

    // MARK: - Persistence

    private func load() {
        servers = KeychainService.loadServers()
        servers.sort { $0.sortOrder < $1.sortOrder }
    }

    private func save(_ server: PairedServer) throws {
        try KeychainService.saveServer(server)
    }

    /// Persist the ordered list of server IDs to both shared and standard UserDefaults.
    ///
    /// Shared suite: readable by widget extension for Live Activity intents.
    /// Standard: backward-compatible fallback.
    private func saveIndex() {
        let ids = servers.map(\.id)
        SharedConstants.sharedDefaults.set(ids, forKey: SharedConstants.pairedServerIdsKey)
        UserDefaults.standard.set(ids, forKey: SharedConstants.pairedServerIdsKey)
    }
}
