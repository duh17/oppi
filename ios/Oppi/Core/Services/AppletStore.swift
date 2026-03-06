import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "AppletStore")

/// Observable store for workspace applets.
///
/// Fetches applets via REST on demand (no WebSocket push for now).
/// Separate @Observable to prevent cross-store re-renders.
@MainActor @Observable
final class AppletStore {
    /// Applets for the current workspace.
    private(set) var applets: [Applet] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Currently loaded workspace ID.
    private(set) var loadedWorkspaceId: String?

    /// Applets for a specific workspace (returns empty if different workspace is loaded).
    func applets(for workspaceId: String) -> [Applet] {
        loadedWorkspaceId == workspaceId ? applets : []
    }

    /// Load applets for a workspace. Replaces current list.
    func load(workspaceId: String, api: APIClient) async {
        // Clear stale data from a different workspace immediately
        if loadedWorkspaceId != workspaceId {
            applets = []
            loadedWorkspaceId = workspaceId
        }

        isLoading = true
        lastError = nil

        do {
            let fetched = try await api.listApplets(workspaceId: workspaceId)
            // Guard against a race: only apply if we're still on this workspace
            guard loadedWorkspaceId == workspaceId else { return }
            applets = fetched
            logger.info("Loaded \(fetched.count) applets for workspace \(workspaceId.prefix(8), privacy: .public)")
        } catch {
            guard loadedWorkspaceId == workspaceId else { return }
            lastError = error.localizedDescription
            logger.error("Failed to load applets: \(error.localizedDescription, privacy: .public)")
        }

        isLoading = false
    }

    /// Refresh if not loaded for this workspace yet.
    func refreshIfNeeded(workspaceId: String, api: APIClient) async {
        if loadedWorkspaceId != workspaceId {
            await load(workspaceId: workspaceId, api: api)
        }
    }

    /// Remove an applet locally (after server delete).
    func remove(id: String) {
        applets.removeAll { $0.id == id }
    }

    /// Clear all state (on server disconnect, etc.).
    func reset() {
        applets = []
        loadedWorkspaceId = nil
        isLoading = false
        lastError = nil
    }
}
