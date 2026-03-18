import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "FileIndexStore")

/// Shared workspace file index for local fuzzy search.
///
/// Used by both `@file` autocomplete in the composer and the file browser.
/// Loads the index once per workspace from the `/file-index` API, caches it,
/// and invalidates after a TTL so file changes are picked up.
@MainActor @Observable
final class FileIndexStore {

    /// Cached file paths for the current workspace. Nil until first load.
    private(set) var paths: [String]?

    /// True while the initial fetch is in-flight.
    private(set) var isLoading = false

    /// The workspace ID this store is tracking.
    private(set) var workspaceId: String?

    private var loadTask: Task<Void, Never>?
    private var loadedAt: ContinuousClock.Instant?

    private static let ttl: Duration = .seconds(30)

    // MARK: - Public API

    /// Ensure the file index is loaded for a workspace.
    /// No-op if already cached and fresh. Re-fetches if stale or different workspace.
    func ensureLoaded(workspaceId: String, apiClient: APIClient) {
        if self.workspaceId == workspaceId, paths != nil, !isStale {
            return
        }

        // Different workspace or stale — reload
        if self.workspaceId != workspaceId {
            paths = nil
        }
        self.workspaceId = workspaceId
        load(workspaceId: workspaceId, apiClient: apiClient)
    }

    /// Force a refresh (e.g., after the user knows files changed).
    func refresh(apiClient: APIClient) {
        guard let workspaceId else { return }
        load(workspaceId: workspaceId, apiClient: apiClient)
    }

    /// Cancel in-flight load and reset state.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        paths = nil
        workspaceId = nil
        loadedAt = nil
        isLoading = false
    }

    // MARK: - Testing

    /// Set paths directly for unit tests. Not for production use.
    // periphery:ignore - used by tests via @testable import
    func setPathsForTesting(_ paths: [String]) {
        self.paths = paths
        self.loadedAt = .now
    }

    // MARK: - Internals

    private var isStale: Bool {
        guard let loadedAt else { return true }
        return ContinuousClock.now - loadedAt > Self.ttl
    }

    private func load(workspaceId: String, apiClient: APIClient) {
        loadTask?.cancel()
        isLoading = paths == nil

        loadTask = Task { [weak self] in
            do {
                let response = try await apiClient.fetchFileIndex(workspaceId: workspaceId)
                guard let self, !Task.isCancelled, self.workspaceId == workspaceId else { return }
                self.paths = response.paths
                self.loadedAt = .now
                self.isLoading = false
                logger.debug("File index loaded: \(response.paths.count) paths for workspace \(workspaceId)")
            } catch {
                guard let self, !Task.isCancelled, self.workspaceId == workspaceId else { return }
                if self.paths == nil {
                    self.paths = []
                }
                self.isLoading = false
                logger.warning("Failed to load file index: \(error.localizedDescription)")
            }
        }
    }
}
