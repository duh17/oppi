import AppIntents
import OSLog

private let intentCatalogLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "IntentEntityQuery"
)
private let pairedServersLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "IntentPairedServers"
)

/// Shortcuts and Siri list servers, workspaces, and Agents through these queries
/// without showing Oppi; while Oppi is locked they list nothing and contact
/// no server.
private func intentQueriesAreLocked() async -> Bool {
    await MainActor.run { AppLockService.shared.requiresUnlock() }
}

/// Paired servers for Siri and Shortcuts. Their Keychain items need the device
/// unlocked; an unreadable Keychain must not read as "no paired servers".
enum IntentPairedServers {
    static let unavailableDialog = "Unlock your device, then try again. Nothing was sent."

    /// Thrown when the paired servers cannot be read, so queries tell the
    /// user to unlock instead of listing nothing.
    struct Unavailable: Error, CustomLocalizedStringResourceConvertible {
        var localizedStringResource: LocalizedStringResource {
            "Unlock your device to use your Oppi servers."
        }
    }

    static func load() throws(Unavailable) -> [PairedServer] {
        do {
            return try KeychainService.loadServers().records
        } catch {
            pairedServersLogger.error(
                "Paired servers unavailable to intent: \(error.localizedDescription, privacy: .public)"
            )
            throw Unavailable()
        }
    }
}

/// Workspaces and Agents a saved Shortcut names, resolved from their ids without a server.
///
/// The name is the one Shortcuts last listed. While Oppi is locked, entities show only a
/// generic name and no server, like the empty lists: a locked Oppi names nothing.
enum IntentSavedEntities {
    struct Resolved {
        let serverId: String
        let itemId: String
        let name: String
        let serverName: String
        let showsServerSubtitle: Bool
    }

    private static let namesKey = "\(AppIdentifiers.subsystem).intentEntityNames"

    static func resolve<Entity>(
        _ identifiers: [String],
        fallbackName: String,
        make: (Resolved) -> Entity
    ) async throws -> [Entity] {
        let locked = await intentQueriesAreLocked()
        let servers = try IntentPairedServers.load()
        let names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        return identifiers.compactMap { identifier in
            guard let decoded = ServerScopedEntityID.decode(identifier),
                  let server = servers.first(where: { $0.id == decoded.serverId }) else { return nil }
            return make(Resolved(
                serverId: decoded.serverId,
                itemId: decoded.itemId,
                name: locked ? fallbackName : names[identifier] ?? fallbackName,
                serverName: server.name,
                showsServerSubtitle: !locked && servers.count > 1
            ))
        }
    }

    /// Adds the names a full listing just returned; names from servers not in `servers` go.
    static func rememberNames(_ namesById: [String: String], servers: [PairedServer]) {
        let paired = Set(servers.map(\.id))
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        names.merge(namesById) { _, new in new }
        names = names.filter { id, _ in
            ServerScopedEntityID.decode(id).map { paired.contains($0.serverId) } ?? false
        }
        UserDefaults.standard.set(names, forKey: namesKey)
    }
}

// MARK: - Thinking Level

/// AppEnum for thinking level selection in Shortcuts.
enum ThinkingLevelEnum: String, AppEnum {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Thinking Level"

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .off: "Off",
        .minimal: "Minimal",
        .low: "Low",
        .medium: "Medium",
        .high: "High",
        .xhigh: "Extra High",
        .max: "Max",
    ]

}

// MARK: - Paired server entity

/// Lightweight entity representing a paired Oppi server for Siri disambiguation.
struct PairedServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Server"
    static let defaultQuery = PairedServerEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PairedServerEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PairedServerEntity] {
        let all = try await suggested()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PairedServerEntity] {
        try await suggested()
    }

    private func suggested() async throws -> [PairedServerEntity] {
        guard await !intentQueriesAreLocked() else { return [] }
        let servers = try IntentPairedServers.load().map {
            PairedServerEntity(id: $0.id, name: $0.name)
        }
        return IntentSessionRanking.rank(
            servers,
            id: \.id,
            name: \.name,
            lastUsedId: RestorationState.load()?.activeServerId,
            defaultId: nil
        )
    }
}

// MARK: - Workspace Entity

/// Workspace on a specific paired server. `id` is `(serverId, workspaceId)`.
struct WorkspaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workspace"
    static let defaultQuery = WorkspaceEntityQuery()

    var id: String
    var serverId: String
    var workspaceId: String
    var name: String
    var serverName: String
    var showsServerSubtitle: Bool

    init(
        serverId: String,
        workspaceId: String,
        name: String,
        serverName: String,
        showsServerSubtitle: Bool
    ) {
        self.id = ServerScopedEntityID.encode(serverId: serverId, itemId: workspaceId)
        self.serverId = serverId
        self.workspaceId = workspaceId
        self.name = name
        self.serverName = serverName
        self.showsServerSubtitle = showsServerSubtitle
    }

    var displayRepresentation: DisplayRepresentation {
        if showsServerSubtitle {
            DisplayRepresentation(title: "\(name)", subtitle: "\(serverName)")
        } else {
            DisplayRepresentation(title: "\(name)")
        }
    }
}

/// Fetches workspaces from every paired server. One unreachable host does not empty the picker.
struct WorkspaceEntityQuery: EntityQuery, EntityStringQuery {
    /// A saved Shortcut's workspace resolves from its id alone, so it runs while Oppi is
    /// locked or a paired server is offline; the sheet checks the workspace after unlock.
    /// Only a bare workspace id (no server) needs the servers' lists to find its server.
    func entities(for identifiers: [String]) async throws -> [WorkspaceEntity] {
        let saved = try await IntentSavedEntities.resolve(identifiers, fallbackName: "Workspace") {
            WorkspaceEntity(
                serverId: $0.serverId,
                workspaceId: $0.itemId,
                name: $0.name,
                serverName: $0.serverName,
                showsServerSubtitle: $0.showsServerSubtitle
            )
        }
        let bare = identifiers.filter { ServerScopedEntityID.decode($0) == nil }
        guard !bare.isEmpty else { return saved }
        let all = try await fetchWorkspaces()
        return saved + bare.compactMap { identifier in
            let matches = all.filter { $0.workspaceId == identifier }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    func suggestedEntities() async throws -> [WorkspaceEntity] {
        try await fetchWorkspaces()
    }

    func entities(matching string: String) async throws -> [WorkspaceEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try await fetchWorkspaces()
        guard !needle.isEmpty else { return all }
        let exact = all.filter {
            $0.name.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if !exact.isEmpty {
            return exact
        }
        return all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private func fetchWorkspaces() async throws -> [WorkspaceEntity] {
        guard await !intentQueriesAreLocked() else { return [] }
        let servers = try IntentPairedServers.load()
        let snapshots = await IntentPairedWorkspaceCatalog.loadReachable(servers: servers)
        let showSubtitle = servers.count > 1
        let entities = snapshots.flatMap { snapshot in
            snapshot.workspaces.map { workspace in
                WorkspaceEntity(
                    serverId: snapshot.server.id,
                    workspaceId: workspace.id,
                    name: workspace.name,
                    serverName: snapshot.server.name,
                    showsServerSubtitle: showSubtitle
                )
            }
        }
        IntentSavedEntities.rememberNames(
            Dictionary(entities.map { ($0.id, $0.name) }) { first, _ in first },
            servers: servers
        )
        return IntentSessionRanking.rank(
            entities,
            id: \.workspaceId,
            name: \.name,
            lastUsedId: AppPreferences.QuickSession.lastWorkspaceId,
            defaultId: AppPreferences.QuickSession.defaultWorkspaceId
        )
    }
}

enum IntentPairedWorkspaceCatalog {
    struct Snapshot: Sendable {
        let server: PairedServer
        let workspaces: [Workspace]
    }

    static func loadReachable(servers: [PairedServer]) async -> [Snapshot] {
        await IntentPairedServerCatalog.loadReachable(servers: servers) { api in
            try await api.listWorkspaces()
        }.map { Snapshot(server: $0.server, workspaces: $0.value) }
    }
}

/// Reads one list from every paired server at once, in pairing order. An unreachable
/// server is skipped, so one offline host does not empty a Shortcuts picker.
enum IntentPairedServerCatalog {
    struct Entry<Value: Sendable>: Sendable {
        let server: PairedServer
        let value: Value
    }

    static func loadReachable<Value: Sendable>(
        servers: [PairedServer],
        _ fetch: @escaping @Sendable (APIClient) async throws -> Value
    ) async -> [Entry<Value>] {
        guard !servers.isEmpty else { return [] }

        let entries = await withTaskGroup(of: Entry<Value>?.self) { group in
            for server in servers {
                group.addTask {
                    do {
                        let value = try await ServerTransportAPIClient.withClient(for: server, operation: fetch)
                        return Entry(server: server, value: value)
                    } catch {
                        intentCatalogLogger.error(
                            "Skipping unreachable server \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                        return nil
                    }
                }
            }
            var collected: [Entry<Value>] = []
            for await entry in group {
                if let entry {
                    collected.append(entry)
                }
            }
            return collected
        }

        let order = Dictionary(uniqueKeysWithValues: servers.enumerated().map { ($0.element.id, $0.offset) })
        return entries.sorted {
            (order[$0.server.id] ?? .max) < (order[$1.server.id] ?? .max)
        }
    }
}

// MARK: - Agent Entity

/// Saved Agent on a specific paired server. `id` is `(serverId, agentId)`.
struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentEntityQuery()

    var id: String
    var serverId: String
    var agentId: String
    var name: String
    var serverName: String
    var showsServerSubtitle: Bool

    init(serverId: String, agentId: String, name: String, serverName: String, showsServerSubtitle: Bool) {
        self.id = ServerScopedEntityID.encode(serverId: serverId, itemId: agentId)
        self.serverId = serverId
        self.agentId = agentId
        self.name = name
        self.serverName = serverName
        self.showsServerSubtitle = showsServerSubtitle
    }

    var displayRepresentation: DisplayRepresentation {
        if showsServerSubtitle {
            DisplayRepresentation(title: "\(name)", subtitle: "\(serverName)")
        } else {
            DisplayRepresentation(title: "\(name)")
        }
    }
}

/// Active saved Agents from every paired server, last Quick Session pick first.
struct AgentEntityQuery: EntityQuery, EntityStringQuery {
    /// A saved Shortcut's Agent resolves from its id alone, so it runs while Oppi is locked
    /// or a paired server is offline; the sheet checks the Agent after unlock.
    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        try await IntentSavedEntities.resolve(identifiers, fallbackName: "Agent") {
            AgentEntity(
                serverId: $0.serverId,
                agentId: $0.itemId,
                name: $0.name,
                serverName: $0.serverName,
                showsServerSubtitle: $0.showsServerSubtitle
            )
        }
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        try await fetchAgents()
    }

    func entities(matching string: String) async throws -> [AgentEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try await fetchAgents()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private func fetchAgents() async throws -> [AgentEntity] {
        guard await !intentQueriesAreLocked() else { return [] }
        let servers = try IntentPairedServers.load()
        let entries = await IntentPairedServerCatalog.loadReachable(servers: servers) { api in
            try await api.listAgents()
        }
        let showSubtitle = servers.count > 1
        let entities = entries.flatMap { entry in
            entry.value.filter { $0.status == .active }.map { agent in
                AgentEntity(
                    serverId: entry.server.id,
                    agentId: agent.id,
                    name: agent.name,
                    serverName: entry.server.name,
                    showsServerSubtitle: showSubtitle
                )
            }
        }
        IntentSavedEntities.rememberNames(
            Dictionary(entities.map { ($0.id, $0.name) }) { first, _ in first },
            servers: servers
        )
        return IntentSessionRanking.rank(
            entities,
            id: \.agentId,
            name: \.name,
            lastUsedId: AppPreferences.QuickSession.lastAgentId,
            defaultId: nil
        )
    }
}
