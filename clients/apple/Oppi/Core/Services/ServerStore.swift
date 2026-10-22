import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "ServerStore")

/// Manages the list of paired servers.
///
/// Pure data store — no networking, no health checks.
/// Persists via `KeychainService` (tokens) + UserDefaults (order/index).
///
/// The store does not read the Keychain when it is created: iOS can launch
/// Oppi in the background while the device is locked, when paired-server items
/// cannot be read. Launch calls `load()` once protected data is available.
@MainActor @Observable
final class ServerStore {
    enum LoadState: Equatable, Sendable {
        /// `load()` has not run.
        case unloaded
        /// The Keychain could not be read. `servers` is not the pairing list.
        case unavailable
        /// `servers` is the pairing list (possibly empty).
        case loaded
    }

    enum StoreError: LocalizedError, Equatable {
        case notLoaded

        var errorDescription: String? {
            "Paired servers are not loaded"
        }
    }

    private(set) var servers: [PairedServer] = []
    private(set) var loadState: LoadState = .unloaded
    /// Indexed servers whose Keychain record could not be read. They are
    /// still paired: index writes keep them, so a transient read failure
    /// cannot unpair them.
    @ObservationIgnored private var unreadableServerIds: [String] = []
    @ObservationIgnored private let loadServers: () throws -> PairedServerKeychain.Read<PairedServer>

    init(loadServers: @escaping () throws -> PairedServerKeychain.Read<PairedServer> = KeychainService.loadServers) {
        self.loadServers = loadServers
    }

    #if DEBUG
    /// Screenshot previews only: an in-memory server list that never touches the Keychain.
    func replaceServersForPreview(_ servers: [PairedServer]) {
        self.servers = servers
    }
    #endif

    /// Read the pairing list. A read failure leaves `servers` as it was and
    /// marks the store `.unavailable`; it never stands in for "no servers".
    /// One unreadable record is skipped; the others load.
    func load() {
        do {
            let read = try loadServers()
            servers = read.records.sorted { $0.sortOrder < $1.sortOrder }
            unreadableServerIds = read.unreadableIds
            loadState = .loaded
        } catch {
            loadState = .unavailable
            logger.error("Paired servers unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - CRUD

    /// Add a new paired server, or update an existing one's credentials
    /// (re-pair). Non-throwing UI convenience: a Keychain write failure is
    /// logged. Use `persistServer(_:)` when the caller must fail safely on a
    /// persistence failure (for example, a credential refresh).
    func addOrUpdate(
        _ server: PairedServer,
        replacingStoredDeviceCredential: Bool = false
    ) {
        do {
            try persistServer(
                server,
                replacingStoredDeviceCredential: replacingStoredDeviceCredential
            )
        } catch {
            logger.error("Failed to save server \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persist a paired server, throwing when the store is not loaded or the
    /// Keychain write fails.
    ///
    /// The record is written through BEFORE the in-memory list is mutated, so a
    /// caller that catches the error observes the previous durable state (no
    /// half-applied in-memory credential).
    func persistServer(
        _ server: PairedServer,
        replacingStoredDeviceCredential: Bool = false
    ) throws {
        try requireLoaded()
        let toSave: PairedServer
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            var existing = servers[idx]
            existing.updateCredentials(
                from: server.credentials,
                replacingStoredDeviceCredential: replacingStoredDeviceCredential
            )
            toSave = existing
        } else {
            var newServer = server
            newServer.sortOrder = servers.count
            toSave = newServer
        }

        try save(toSave, replacingStoredDeviceCredential: replacingStoredDeviceCredential)
        // Adopt Keychain's merged credential so a stale writer cannot restore
        // older auth in memory. An explicit re-pair may replace the stored identity.
        let persisted = try KeychainService.loadServer(id: toSave.id) ?? toSave

        if let idx = servers.firstIndex(where: { $0.id == persisted.id }) {
            servers[idx] = persisted
        } else {
            servers.append(persisted)
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
        guard loadState == .loaded else {
            logger.error("Refusing to remove server \(id.prefix(16), privacy: .public): paired servers not loaded")
            return
        }
        servers.removeAll { $0.id == id }
        unreadableServerIds.removeAll { $0 == id }
        KeychainService.deleteServer(id: id)
        saveIndex()
        logger.warning("Removed server \(id.prefix(16), privacy: .public)")
    }

    /// Update the badge icon for a server.
    func setBadgeIcon(id: String, to icon: ServerBadgeIcon) {
        guard loadState == .loaded,
              let idx = servers.firstIndex(where: { $0.id == id }) else { return }
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
        expectedDeviceId: String,
        result: DeviceAuthRefreshResult
    ) throws -> DeviceCredential {
        try requireLoaded()
        guard servers.contains(where: { $0.id == id }) else {
            throw KeychainCredentialMergeError.itemNotFound
        }
        let merged = try KeychainDeviceCredentialMerger.mergeRefresh(
            serverId: id,
            expectedDeviceId: expectedDeviceId,
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

    /// Every paired server: the loaded ones and those whose record could not
    /// be read. Decide "is this server still paired?" here, never from
    /// `servers`, so an unreadable record is not treated as unpaired.
    var pairedServerIds: [String] {
        let loadedIds = servers.map(\.id)
        return loadedIds + unreadableServerIds.filter { !loadedIds.contains($0) }
    }

    func isPaired(_ id: String) -> Bool {
        server(for: id) != nil || unreadableServerIds.contains(id)
    }

    /// Look up which server owns a given host:port combination.
    func server(forHost host: String, port: Int) -> PairedServer? {
        servers.first { $0.host == host && $0.port == port }
    }

    // MARK: - Persistence

    /// Writes from a store that never read the pairing list would replace the
    /// durable index with a partial one and hide the other servers.
    private func requireLoaded() throws {
        guard loadState == .loaded else { throw StoreError.notLoaded }
    }

    private func save(
        _ server: PairedServer,
        replacingStoredDeviceCredential: Bool = false
    ) throws {
        try KeychainService.saveServer(
            server,
            replacingStoredDeviceCredential: replacingStoredDeviceCredential
        )
    }

    /// Persist the ordered list of server IDs to both shared and standard UserDefaults.
    ///
    /// Shared suite: readable by widget extension for Live Activity intents.
    /// Standard: backward-compatible fallback.
    /// An unreadable server keeps its place in the index, after the nearest
    /// server that preceded it, so readers that take the index order see the
    /// same order once its record reads again.
    private func saveIndex() {
        guard loadState == .loaded else { return }
        let key = SharedConstants.pairedServerIdsKey
        let previous = SharedConstants.sharedDefaults.stringArray(forKey: key)
            ?? UserDefaults.standard.stringArray(forKey: key)
            ?? []
        var ids = servers.map(\.id)
        for id in unreadableServerIds where !ids.contains(id) {
            guard let position = previous.firstIndex(of: id) else {
                ids.append(id)
                continue
            }
            let anchor = previous[..<position].last { ids.contains($0) }
            let insertAt = anchor.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            ids.insert(id, at: insertAt)
        }
        SharedConstants.sharedDefaults.set(ids, forKey: SharedConstants.pairedServerIdsKey)
        UserDefaults.standard.set(ids, forKey: SharedConstants.pairedServerIdsKey)
    }
}
