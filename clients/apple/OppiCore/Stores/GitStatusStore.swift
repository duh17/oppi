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

/// Each checkout's Git status, for every screen that shows one: a chat's Git
/// button and panel, Workspace Detail, a Git pane. A checkout is tracked from
/// its first `loadInitial` and keeps its own status, so two screens showing
/// different checkouts (a chat beside a pinned Git pane) never take the status
/// from each other.
///
/// The server pushes `git_status` after file-mutating tool calls and
/// invalidates after workspace mutations; `loadInitial` fetches over REST, and
/// `refreshTracked` fetches every tracked checkout again when the connection's
/// event stream (re)connects.
@MainActor @Observable
final class GitStatusStore {
    private struct Checkout: Hashable {
        let workspaceId: String
        /// The main checkout is always `WorkspaceWorktree.mainId`, never nil.
        let worktreeId: String

        init(_ workspaceId: String, _ worktreeId: String?) {
            self.workspaceId = workspaceId
            self.worktreeId = worktreeId ?? WorkspaceWorktree.mainId
        }
    }

    private struct Entry {
        var gitStatus: GitStatus?
        var isLoading = false
        /// Why the last fetch failed, until a status arrives.
        var error: String?
        var gitStatusEnabled = true
    }

    private let environment: GitStatusStoreEnvironment
    private var entries: [Checkout: Entry] = [:]
    @ObservationIgnored private var fetchTasks: [Checkout: Task<Void, Never>] = [:]

    init(environment: GitStatusStoreEnvironment = .none) {
        self.environment = environment
    }

    // MARK: - Reading

    /// That checkout's status (nil and the main worktree's id are the main
    /// checkout), or nil before one arrived.
    func status(workspaceId: String, worktreeId: String?) -> GitStatus? {
        entries[Checkout(workspaceId, worktreeId)]?.gitStatus
    }

    /// Whether the store is tracking that checkout, loaded yet or not.
    func tracks(workspaceId: String, worktreeId: String?) -> Bool {
        entries[Checkout(workspaceId, worktreeId)] != nil
    }

    /// Whether that checkout's status is still on its way: not yet asked for
    /// (its host loads it when it appears), or its first fetch in flight.
    /// False once loaded, or once a fetch ended without one.
    func isAwaitingStatus(workspaceId: String, worktreeId: String?) -> Bool {
        guard let entry = entries[Checkout(workspaceId, worktreeId)] else { return true }
        return entry.gitStatus == nil && entry.isLoading
    }

    /// Why that checkout has no status: its last fetch failed. Nil while it
    /// has a status or one is on its way.
    func loadError(workspaceId: String, worktreeId: String?) -> String? {
        guard let entry = entries[Checkout(workspaceId, worktreeId)], entry.gitStatus == nil, !entry.isLoading else { return nil }
        return entry.error
    }

    // MARK: - Push from WebSocket

    /// Called when a `git_status` ServerMessage arrives; a checkout no screen
    /// tracks is ignored.
    func handleGitStatusPush(workspaceId: String, worktreeId: String? = nil, status: GitStatus) {
        let key = Checkout(workspaceId, worktreeId)
        guard var entry = entries[key] else { return }
        fetchTasks.removeValue(forKey: key)?.cancel()
        if entry.gitStatus != status { entry.gitStatus = status }
        entry.isLoading = false
        entry.error = nil
        entries[key] = entry
    }

    // MARK: - Invalidation

    /// Refreshes a tracked checkout after a workspace-level file mutation.
    ///
    /// Stale-while-refreshing: the shown status stays while a debounced REST
    /// refresh checks whether file state actually changed, so an active
    /// session's stream of invalidations never blanks the bar.
    func invalidate(
        workspaceId: String,
        worktreeId: String? = nil,
        apiClient: (any WorkspaceGitStatusFetching)? = nil,
        gitStatusEnabled: Bool = true,
        debounce: Duration = .seconds(2)
    ) {
        let key = Checkout(workspaceId, worktreeId)
        guard entries[key] != nil else { return }
        guard gitStatusEnabled else {
            fetchTasks.removeValue(forKey: key)?.cancel()
            entries[key] = Entry(gitStatusEnabled: false)
            return
        }
        guard let apiClient else { return }
        fetch(key, apiClient: apiClient, debounce: debounce)
    }

    // MARK: - Loading

    /// Tracks the checkout and fetches its status. A checkout already showing
    /// a status keeps it while the fetch runs (no flash).
    func loadInitial(
        workspaceId: String,
        worktreeId: String? = nil,
        apiClient: (any WorkspaceGitStatusFetching)?,
        gitStatusEnabled: Bool = true
    ) {
        let key = Checkout(workspaceId, worktreeId)
        guard gitStatusEnabled else {
            fetchTasks.removeValue(forKey: key)?.cancel()
            entries[key] = Entry(gitStatusEnabled: false)
            return
        }
        var entry = entries[key] ?? Entry()
        entry.gitStatusEnabled = true
        guard let apiClient else {
            // No connection yet (a cold launch restoring a Git pane): tracked
            // and on its way; the event stream's connect fetches it.
            entry.isLoading = true
            entries[key] = entry
            return
        }
        entries[key] = entry
        fetch(key, apiClient: apiClient, debounce: nil)
    }

    /// Fetches every tracked checkout again: the event stream (re)connected,
    /// so pushes may have been missed, or a checkout was waiting for a client.
    func refreshTracked(apiClient: any WorkspaceGitStatusFetching) {
        for (key, entry) in entries where entry.gitStatusEnabled {
            fetch(key, apiClient: apiClient, debounce: nil)
        }
    }

    private func fetch(_ key: Checkout, apiClient: any WorkspaceGitStatusFetching, debounce: Duration?) {
        fetchTasks.removeValue(forKey: key)?.cancel()
        entries[key]?.isLoading = true
        entries[key]?.error = nil
        fetchTasks[key] = Task { [weak self] in
            do {
                if let debounce { try await Task.sleep(for: debounce) }
                let status = try await apiClient.getGitStatus(workspaceId: key.workspaceId, worktreeId: key.worktreeId)
                try Task.checkCancellation()
                self?.finish(key, status: status, error: nil)
            } catch is CancellationError {
                // A newer fetch or push for this checkout replaced this one.
            } catch {
                // A cancelled URL load throws its own error, not CancellationError.
                guard !Task.isCancelled else { return }
                self?.environment.logWarning("Git status fetch failed: \(error.localizedDescription)")
                self?.finish(key, status: nil, error: error.localizedDescription)
            }
        }
    }

    private func finish(_ key: Checkout, status: GitStatus?, error: String?) {
        fetchTasks[key] = nil
        guard var entry = entries[key], entry.gitStatusEnabled else { return }
        if let status, entry.gitStatus != status { entry.gitStatus = status }
        entry.isLoading = false
        entry.error = status == nil ? error : nil
        entries[key] = entry
    }
}
