import Foundation

protocol WorkspaceGitStatusFetching: Sendable {
    func getGitStatus(workspaceId: String, worktreeId: String?) async throws -> GitStatus
}

struct GitStatusStoreEnvironment: Sendable {
    let logWarning: @Sendable (_ message: String) -> Void

    init(logWarning: @escaping @Sendable (_ message: String) -> Void = { _ in }) {
        self.logWarning = logWarning
    }

    static let none = GitStatusStoreEnvironment()
}

/// Receives git status updates pushed over WebSocket after file-mutating tool calls.
///
/// The server fires `git_status` events after edit/write/bash tool calls.
/// This store simply holds the latest status per workspace. Also supports
/// on-demand refresh via the REST endpoint (e.g. on initial load).
@MainActor @Observable
final class GitStatusStore {
    private let environment: GitStatusStoreEnvironment

    // MARK: - Public state

    /// Latest git status for the active workspace. Nil until first push/fetch.
    private(set) var gitStatus: GitStatus?

    /// True while the initial fetch is in-flight.
    private(set) var isLoading = false

    /// The workspace/worktree this store is tracking.
    private(set) var workspaceId: String?
    private(set) var worktreeId: String?

    private var invalidationRefreshTask: Task<Void, Never>?

    init(environment: GitStatusStoreEnvironment = .none) {
        self.environment = environment
    }

    // MARK: - Handle push from WebSocket

    /// Called when a `git_status` ServerMessage arrives.
    func handleGitStatusPush(workspaceId: String, worktreeId: String? = nil, status: GitStatus) {
        guard workspaceId == self.workspaceId,
              (worktreeId ?? WorkspaceWorktree.mainId) == (self.worktreeId ?? WorkspaceWorktree.mainId) else { return }
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
        worktreeId: String? = nil,
        apiClient: (any WorkspaceGitStatusFetching)? = nil,
        gitStatusEnabled: Bool = true,
        debounce: Duration = .seconds(2)
    ) {
        guard workspaceId == self.workspaceId,
              (worktreeId ?? WorkspaceWorktree.mainId) == (self.worktreeId ?? WorkspaceWorktree.mainId) else { return }

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
                let status = try await apiClient.getGitStatus(workspaceId: workspaceId, worktreeId: worktreeId)
                guard let self,
                      self.workspaceId == workspaceId,
                      (self.worktreeId ?? WorkspaceWorktree.mainId) == (worktreeId ?? WorkspaceWorktree.mainId) else { return }
                if self.gitStatus != status {
                    self.gitStatus = status
                }
                self.isLoading = false
                self.invalidationRefreshTask = nil
            } catch is CancellationError {
                // A newer invalidation or explicit load will replace this refresh.
            } catch {
                guard let self,
                      self.workspaceId == workspaceId,
                      (self.worktreeId ?? WorkspaceWorktree.mainId) == (worktreeId ?? WorkspaceWorktree.mainId) else { return }
                self.environment.logWarning("Debounced git status refresh failed: \(error.localizedDescription)")
                self.isLoading = false
                self.invalidationRefreshTask = nil
            }
        }
    }

    // MARK: - Initial load

    /// Fetch initial git status when entering a chat view.
    /// Subsequent updates arrive via WebSocket push.
    func loadInitial(
        workspaceId: String,
        worktreeId: String? = nil,
        apiClient: any WorkspaceGitStatusFetching,
        gitStatusEnabled: Bool = true
    ) {
        invalidationRefreshTask?.cancel()
        invalidationRefreshTask = nil

        let normalizedWorktreeId = worktreeId ?? WorkspaceWorktree.mainId
        let workspaceChanged = self.workspaceId != workspaceId || (self.worktreeId ?? WorkspaceWorktree.mainId) != normalizedWorktreeId
        self.workspaceId = workspaceId
        self.worktreeId = normalizedWorktreeId

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
                let status = try await apiClient.getGitStatus(workspaceId: workspaceId, worktreeId: normalizedWorktreeId)
                guard let self,
                      self.workspaceId == workspaceId,
                      (self.worktreeId ?? WorkspaceWorktree.mainId) == normalizedWorktreeId else { return }
                if self.gitStatus != status {
                    self.gitStatus = status
                }
            } catch is CancellationError {
                // Expected
            } catch {
                self?.environment.logWarning("Initial git status fetch failed: \(error.localizedDescription)")
            }
            self?.isLoading = false
        }
    }
}
