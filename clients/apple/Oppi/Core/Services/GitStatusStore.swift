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

    private var invalidationRefreshTask: Task<Void, Never>?

    // MARK: - Handle push from WebSocket

    /// Called when a `git_status` ServerMessage arrives.
    func handleGitStatusPush(workspaceId: String, status: GitStatus) {
        guard workspaceId == self.workspaceId else { return }
        invalidationRefreshTask?.cancel()
        invalidationRefreshTask = nil
        if gitStatus != status {
            gitStatus = status
        }
        isLoading = false
    }

    // MARK: - Invalidation

    /// Refresh visible git status after a workspace-level file mutation invalidates it.
    ///
    /// The context bar uses stale-while-refreshing behavior: keep the current
    /// bar visible while a debounced REST refresh checks whether file state
    /// actually changed. This avoids clearing the bar for every low-level
    /// invalidation event from an active session.
    func invalidate(
        workspaceId: String,
        apiClient: APIClient? = nil,
        gitStatusEnabled: Bool = true,
        debounce: Duration = .seconds(2)
    ) {
        guard workspaceId == self.workspaceId else { return }

        invalidationRefreshTask?.cancel()
        invalidationRefreshTask = nil

        guard gitStatusEnabled else {
            gitStatus = nil
            isLoading = false
            return
        }

        guard let apiClient else {
            return
        }

        isLoading = gitStatus == nil
        invalidationRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                let status = try await apiClient.getGitStatus(workspaceId: workspaceId)
                guard let self, self.workspaceId == workspaceId else { return }
                if self.gitStatus != status {
                    self.gitStatus = status
                }
                self.isLoading = false
                self.invalidationRefreshTask = nil
            } catch is CancellationError {
                // A newer invalidation or explicit load will replace this refresh.
            } catch {
                guard let self, self.workspaceId == workspaceId else { return }
                logger.warning("Debounced git status refresh failed: \(error.localizedDescription)")
                self.isLoading = false
                self.invalidationRefreshTask = nil
            }
        }
    }

    // MARK: - Initial load

    /// Fetch initial git status when entering a chat view.
    /// Subsequent updates arrive via WebSocket push.
    func loadInitial(workspaceId: String, apiClient: APIClient, gitStatusEnabled: Bool = true) {
        invalidationRefreshTask?.cancel()
        invalidationRefreshTask = nil

        let workspaceChanged = self.workspaceId != workspaceId
        self.workspaceId = workspaceId

        guard gitStatusEnabled else {
            gitStatus = nil
            isLoading = false
            return
        }

        // Clear stale status from a different workspace before fetching
        if workspaceChanged {
            gitStatus = nil
        }

        isLoading = gitStatus == nil

        Task { [weak self] in
            do {
                let status = try await apiClient.getGitStatus(workspaceId: workspaceId)
                guard let self, self.workspaceId == workspaceId else { return }
                if self.gitStatus != status {
                    self.gitStatus = status
                }
            } catch is CancellationError {
                // Expected
            } catch {
                logger.warning("Initial git status fetch failed: \(error.localizedDescription)")
            }
            self?.isLoading = false
        }
    }

    // periphery:ignore - API surface for git status lifecycle management
    /// Clear state when leaving the chat view.
    func reset() {
        invalidationRefreshTask?.cancel()
        invalidationRefreshTask = nil
        gitStatus = nil
        workspaceId = nil
        isLoading = false
    }
}
