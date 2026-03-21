import AppIntents

// MARK: - Thinking Level

/// AppEnum for thinking level selection in Shortcuts.
enum ThinkingLevelEnum: String, AppEnum {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Thinking Level"

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .off: "Off",
        .minimal: "Minimal",
        .low: "Low",
        .medium: "Medium",
        .high: "High",
        .xhigh: "Extra High",
    ]

}

// MARK: - Workspace Entity

/// Lightweight entity representing an Oppi workspace for Shortcuts parameter pickers.
struct WorkspaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workspace"
    static let defaultQuery = WorkspaceEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Fetches workspaces from the paired server for the Shortcuts picker.
struct WorkspaceEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WorkspaceEntity] {
        let all = try await fetchWorkspaces()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WorkspaceEntity] {
        try await fetchWorkspaces()
    }

    private func fetchWorkspaces() async throws -> [WorkspaceEntity] {
        guard let server = KeychainService.loadServers().first,
              let baseURL = server.baseURL else {
            return []
        }

        let api = APIClient(
            baseURL: baseURL,
            token: server.token,
            tlsCertFingerprint: server.tlsCertFingerprint
        )

        let workspaces = try await api.listWorkspaces()
        return workspaces.map { WorkspaceEntity(id: $0.id, name: $0.name) }
    }
}
