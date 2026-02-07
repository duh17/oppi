import Foundation

/// Observable store for workspaces and the available skill pool.
@MainActor @Observable
final class WorkspaceStore {
    var workspaces: [Workspace] = []
    var skills: [SkillInfo] = []
    var isLoaded = false

    /// Insert or update a workspace.
    func upsert(_ workspace: Workspace) {
        if let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[idx] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    /// Remove a workspace by ID.
    func remove(id: String) {
        workspaces.removeAll { $0.id == id }
    }

    /// Load workspaces and skills from the server.
    func load(api: APIClient) async {
        async let fetchWorkspaces = api.listWorkspaces()
        async let fetchSkills = api.listSkills()

        do {
            let (ws, sk) = try await (fetchWorkspaces, fetchSkills)
            workspaces = ws
            skills = sk
            isLoaded = true
        } catch {
            // Keep stale data on error; retry on next load
        }
    }
}
