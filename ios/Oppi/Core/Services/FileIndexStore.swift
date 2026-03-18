import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "FileIndexStore")

/// Shared workspace file index for local fuzzy search.
///
/// Used by both `@file` autocomplete in the composer and the file browser.
/// Loads the index once per workspace from the `/file-index` API, caches it
/// indefinitely. Invalidation is event-driven: when `git_status` arrives
/// (after file-mutating tool calls), the index is marked dirty and refreshed
/// on next access.
@MainActor @Observable
final class FileIndexStore {

    /// Cached file paths for the current workspace. Nil until first load.
    private(set) var paths: [String]?

    /// True while the initial fetch is in-flight.
    private(set) var isLoading = false

    /// The workspace ID this store is tracking.
    private(set) var workspaceId: String?

    private var loadTask: Task<Void, Never>?
    private var dirty = false

    // MARK: - Public API

    /// Ensure the file index is loaded for a workspace.
    /// No-op if already cached and clean. Re-fetches if dirty or different workspace.
    func ensureLoaded(workspaceId: String, apiClient: APIClient) {
        if self.workspaceId == workspaceId, paths != nil, !dirty {
            return
        }

        if self.workspaceId != workspaceId {
            paths = nil
        }
        self.workspaceId = workspaceId
        load(workspaceId: workspaceId, apiClient: apiClient)
    }

    /// Mark the index as dirty. Next `ensureLoaded` call will re-fetch.
    /// Called when `git_status` push arrives (files changed on disk).
    func invalidate() {
        dirty = true
    }

    /// Force an immediate refresh (e.g., entering file browser after edits).
    func refresh(apiClient: APIClient) {
        guard let workspaceId else { return }
        dirty = false
        load(workspaceId: workspaceId, apiClient: apiClient)
    }

    /// Cancel in-flight load and reset state.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        paths = nil
        workspaceId = nil
        dirty = false
        isLoading = false
    }

    // MARK: - Testing

    /// Set paths directly for unit tests. Not for production use.
    // periphery:ignore - used by tests via @testable import
    func setPathsForTesting(_ paths: [String]) {
        self.paths = paths
        self.dirty = false
    }

    // MARK: - Internals

    private func load(workspaceId: String, apiClient: APIClient) {
        loadTask?.cancel()
        dirty = false
        isLoading = paths == nil

        loadTask = Task { [weak self] in
            do {
                let response = try await apiClient.fetchFileIndex(workspaceId: workspaceId)
                guard let self, !Task.isCancelled, self.workspaceId == workspaceId else { return }
                self.paths = response.paths
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
