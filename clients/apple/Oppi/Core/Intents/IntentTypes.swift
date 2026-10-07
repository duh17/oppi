import AppIntents
import OSLog

private let workspaceEntityLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "WorkspaceEntityQuery"
)

/// Shortcuts and Siri list servers and workspaces through these queries
/// without showing Oppi; while Oppi is locked they list nothing and contact
/// no server.
private func intentQueriesAreLocked() async -> Bool {
    await MainActor.run { AppLockService.shared.requiresUnlock() }
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
        let all = await suggested()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PairedServerEntity] {
        await suggested()
    }

    private func suggested() async -> [PairedServerEntity] {
        guard await !intentQueriesAreLocked() else { return [] }
        let servers = KeychainService.loadServers().map {
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
        self.id = WorkspaceEntityID.encode(serverId: serverId, workspaceId: workspaceId)
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
    func entities(for identifiers: [String]) async throws -> [WorkspaceEntity] {
        let all = await fetchWorkspaces()
        return identifiers.compactMap { identifier in
            if let decoded = WorkspaceEntityID.decode(identifier) {
                return all.first {
                    $0.serverId == decoded.serverId && $0.workspaceId == decoded.workspaceId
                }
            }
            let matches = all.filter { $0.workspaceId == identifier }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    func suggestedEntities() async throws -> [WorkspaceEntity] {
        await fetchWorkspaces()
    }

    func entities(matching string: String) async throws -> [WorkspaceEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await fetchWorkspaces()
        guard !needle.isEmpty else { return all }
        let exact = all.filter {
            $0.name.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if !exact.isEmpty {
            return exact
        }
        return all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private func fetchWorkspaces() async -> [WorkspaceEntity] {
        guard await !intentQueriesAreLocked() else { return [] }
        let snapshots = await IntentPairedWorkspaceCatalog.loadReachable()
        let pairedCount = KeychainService.loadServers().count
        let showSubtitle = pairedCount > 1
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

    static func loadReachable() async -> [Snapshot] {
        let servers = KeychainService.loadServers()
        guard !servers.isEmpty else { return [] }

        let snapshots = await withTaskGroup(of: Snapshot?.self) { group in
            for server in servers {
                group.addTask {
                    do {
                        let workspaces = try await ServerTransportAPIClient.withClient(for: server) { api in
                            try await api.listWorkspaces()
                        }
                        return Snapshot(server: server, workspaces: workspaces)
                    } catch {
                        workspaceEntityLogger.error(
                            "Skipping unreachable server \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                        return nil
                    }
                }
            }
            var collected: [Snapshot] = []
            for await snapshot in group {
                if let snapshot {
                    collected.append(snapshot)
                }
            }
            return collected
        }

        let order = Dictionary(uniqueKeysWithValues: servers.enumerated().map { ($0.element.id, $0.offset) })
        return snapshots.sorted {
            (order[$0.server.id] ?? .max) < (order[$1.server.id] ?? .max)
        }
    }
}
