import Foundation

/// Composite identity for a workspace on a specific paired server.
enum WorkspaceEntityID {
    private static let separator: Character = "\u{1F}"

    static func encode(serverId: String, workspaceId: String) -> String {
        "\(serverId)\(separator)\(workspaceId)"
    }

    static func decode(_ id: String) -> (serverId: String, workspaceId: String)? {
        let parts = id.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let serverId = String(parts[0])
        let workspaceId = String(parts[1])
        guard !serverId.isEmpty, !workspaceId.isEmpty else { return nil }
        return (serverId, workspaceId)
    }
}

/// Siri/Shortcuts ranking: last used, then default, then name. Stale ids are ignored.
enum IntentSessionRanking {
    static func rank<T>(
        _ items: [T],
        id: (T) -> String,
        name: (T) -> String,
        lastUsedId: String?,
        defaultId: String?
    ) -> [T] {
        let present = Set(items.map(id))
        let lastUsed = lastUsedId.flatMap { present.contains($0) ? $0 : nil }
        let fallbackDefault = defaultId.flatMap {
            present.contains($0) && $0 != lastUsed ? $0 : nil
        }

        return items.sorted { lhs, rhs in
            let leftId = id(lhs)
            let rightId = id(rhs)
            if leftId == lastUsed, rightId != lastUsed { return true }
            if rightId == lastUsed, leftId != lastUsed { return false }
            if leftId == fallbackDefault, rightId != fallbackDefault { return true }
            if rightId == fallbackDefault, leftId != fallbackDefault { return false }
            return name(lhs).localizedCaseInsensitiveCompare(name(rhs)) == .orderedAscending
        }
    }
}

/// Pure Siri start-session target resolution. Network and App Intent prompts stay in the intent.
enum IntentSessionDisambiguation {
    struct ServerHit: Equatable, Sendable {
        var serverId: String
        var serverName: String
    }

    struct WorkspaceHit: Equatable, Sendable {
        var serverId: String
        var serverName: String
        var workspaceId: String
        var workspaceName: String
    }

    struct Catalog: Equatable, Sendable {
        var serverId: String
        var serverName: String
        var workspaces: [WorkspaceRef]

        struct WorkspaceRef: Equatable, Sendable {
            var id: String
            var name: String
        }
    }

    enum Decision: Equatable, Sendable {
        case resolved(WorkspaceHit)
        case askServer([ServerHit])
        case askWorkspace([WorkspaceHit], includeServerSubtitle: Bool)
        case noServers
        case noWorkspaces
        case namedWorkspaceMissing
        case serverUnreachable
    }

    static func decide(
        pairedServers: [ServerHit],
        catalogs: [Catalog],
        namedWorkspace: String?,
        selectedServerId: String?,
        selectedWorkspace: (serverId: String, workspaceId: String)?
    ) -> Decision {
        if pairedServers.isEmpty {
            return .noServers
        }

        let showServerSubtitle = pairedServers.count > 1

        if let selectedWorkspace {
            if let hit = workspaceHit(
                serverId: selectedWorkspace.serverId,
                workspaceId: selectedWorkspace.workspaceId,
                in: catalogs
            ) {
                return .resolved(hit)
            }
        }

        let named = namedWorkspace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !named.isEmpty {
            let catalogsToSearch: [Catalog]
            if let selectedServerId {
                catalogsToSearch = catalogs.filter { $0.serverId == selectedServerId }
            } else {
                catalogsToSearch = catalogs
            }
            let hits = namedHits(named, in: catalogsToSearch)
            if hits.isEmpty {
                return .namedWorkspaceMissing
            }
            if hits.count == 1 {
                return .resolved(hits[0])
            }
            return .askWorkspace(hits, includeServerSubtitle: showServerSubtitle)
        }

        let resolvedServerId: String
        if let selectedServerId, pairedServers.contains(where: { $0.serverId == selectedServerId }) {
            resolvedServerId = selectedServerId
        } else if pairedServers.count == 1 {
            resolvedServerId = pairedServers[0].serverId
        } else {
            return .askServer(pairedServers)
        }

        guard let catalog = catalogs.first(where: { $0.serverId == resolvedServerId }) else {
            return .serverUnreachable
        }
        if catalog.workspaces.isEmpty {
            return .noWorkspaces
        }
        if catalog.workspaces.count == 1 {
            let workspace = catalog.workspaces[0]
            return .resolved(
                WorkspaceHit(
                    serverId: catalog.serverId,
                    serverName: catalog.serverName,
                    workspaceId: workspace.id,
                    workspaceName: workspace.name
                )
            )
        }

        let hits = catalog.workspaces.map {
            WorkspaceHit(
                serverId: catalog.serverId,
                serverName: catalog.serverName,
                workspaceId: $0.id,
                workspaceName: $0.name
            )
        }
        return .askWorkspace(hits, includeServerSubtitle: showServerSubtitle)
    }

    private static func workspaceHit(
        serverId: String,
        workspaceId: String,
        in catalogs: [Catalog]
    ) -> WorkspaceHit? {
        guard let catalog = catalogs.first(where: { $0.serverId == serverId }),
              let workspace = catalog.workspaces.first(where: { $0.id == workspaceId }) else {
            return nil
        }
        return WorkspaceHit(
            serverId: catalog.serverId,
            serverName: catalog.serverName,
            workspaceId: workspace.id,
            workspaceName: workspace.name
        )
    }

    private static func namedHits(_ name: String, in catalogs: [Catalog]) -> [WorkspaceHit] {
        catalogs.flatMap { catalog in
            catalog.workspaces.compactMap { workspace -> WorkspaceHit? in
                guard workspace.name.compare(
                    name,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame else {
                    return nil
                }
                return WorkspaceHit(
                    serverId: catalog.serverId,
                    serverName: catalog.serverName,
                    workspaceId: workspace.id,
                    workspaceName: workspace.name
                )
            }
        }
    }
}
