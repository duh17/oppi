import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "GitStatusStore")

/// Receives git status updates pushed over WebSocket after file-mutating tool calls.
///
/// The server fires `git_status` events after edit/write/bash tool calls.
/// This store simply holds the latest status per workspace. Also supports
/// on-demand refresh via the REST endpoint (e.g. on initial load).
@MainActor @Observable
final class GitStatusStore {

    // MARK: - Public state

    /// Latest git status for the active workspace. Nil until first push/fetch.
    private(set) var gitStatus: GitStatus?

    /// True while the initial fetch is in-flight.
    private(set) var isLoading = false

    /// The workspace ID this store is tracking.
    private(set) var workspaceId: String?

    // MARK: - Handle push from WebSocket

    /// Called when a `git_status` ServerMessage arrives.
    func handleGitStatusPush(workspaceId: String, status: GitStatus) {
        guard workspaceId == self.workspaceId else { return }
        gitStatus = status
    }

    // MARK: - Initial load

    /// Fetch initial git status when entering a chat view.
    /// Subsequent updates arrive via WebSocket push.
    func loadInitial(workspaceId: String, apiClient: APIClient, gitStatusEnabled: Bool = true) {
        self.workspaceId = workspaceId

        guard gitStatusEnabled else {
            gitStatus = nil
            return
        }

        isLoading = gitStatus == nil

        Task { [weak self] in
            do {
                let status = try await apiClient.getGitStatus(workspaceId: workspaceId)
                guard let self, self.workspaceId == workspaceId else { return }
                self.gitStatus = status
            } catch is CancellationError {
                // Expected
            } catch {
                logger.warning("Initial git status fetch failed: \(error.localizedDescription)")
            }
            self?.isLoading = false
        }
    }

    /// Clear state when leaving the chat view.
    func reset() {
        gitStatus = nil
        workspaceId = nil
        isLoading = false
    }
}
