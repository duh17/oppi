import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "AppletStore")

/// Observable store for workspace applets.
///
/// Fetches applets via REST on demand (no WebSocket push for now).
/// Separate @Observable to prevent cross-store re-renders.
@MainActor @Observable
final class AppletStore {
    /// Applets for the current workspace, sorted by updatedAt desc.
    private(set) var applets: [Applet] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Currently loaded workspace ID.
    private(set) var loadedWorkspaceId: String?

    /// Load applets for a workspace. Replaces current list.
    func load(workspaceId: String, api: APIClient) async {
        isLoading = true
        lastError = nil

        do {
            let fetched = try await api.listApplets(workspaceId: workspaceId)
            applets = fetched
            loadedWorkspaceId = workspaceId
            logger.info("Loaded \(fetched.count) applets for workspace \(workspaceId.prefix(8), privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            logger.error("Failed to load applets: \(error.localizedDescription, privacy: .public)")
        }

        isLoading = false
    }

    /// Refresh if already loaded for this workspace.
    func refreshIfNeeded(workspaceId: String, api: APIClient) async {
        if loadedWorkspaceId != workspaceId || applets.isEmpty {
            await load(workspaceId: workspaceId, api: api)
        }
    }

    /// Remove an applet locally (after server delete).
    func remove(id: String) {
        applets.removeAll { $0.id == id }
    }

    /// Clear all state (on workspace switch, server disconnect, etc.).
    func reset() {
        applets = []
        loadedWorkspaceId = nil
        isLoading = false
        lastError = nil
    }
}
