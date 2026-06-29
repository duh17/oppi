import Foundation

protocol WorkspaceFileIndexFetching: Sendable {
    func fetchFileIndex(workspaceId: String) async throws -> FileIndexResponse
}

struct FileIndexStoreEnvironment: Sendable {
    let loadCachedFileIndex: @Sendable (_ workspaceId: String) async -> [String]?
    let cacheFileIndex: @Sendable (_ paths: [String], _ workspaceId: String) async -> Void
    let logDebug: @Sendable (_ message: String) -> Void
    let logWarning: @Sendable (_ message: String) -> Void

    init(
        loadCachedFileIndex: @escaping @Sendable (_ workspaceId: String) async -> [String]? = { _ in nil },
        cacheFileIndex: @escaping @Sendable (_ paths: [String], _ workspaceId: String) async -> Void = { _, _ in },
        logDebug: @escaping @Sendable (_ message: String) -> Void = { _ in },
        logWarning: @escaping @Sendable (_ message: String) -> Void = { _ in }
    ) {
        self.loadCachedFileIndex = loadCachedFileIndex
        self.cacheFileIndex = cacheFileIndex
        self.logDebug = logDebug
        self.logWarning = logWarning
    }

    static let none = FileIndexStoreEnvironment()
}

/// Shared workspace file index for local fuzzy search.
///
/// Used by both `@file` autocomplete in the composer and the file browser.
/// Loads the index once per workspace from the `/paths` API, caches it
/// indefinitely. Invalidation is event-driven: when `git_status` arrives
/// (after file-mutating tool calls), the index is marked dirty and refreshed
/// on next access.
@MainActor @Observable
final class FileIndexStore {
    private let environment: FileIndexStoreEnvironment

    /// Cached file paths for the current workspace. Nil until first load.
    private(set) var paths: [String]?

    /// True while the initial fetch is in-flight.
    private(set) var isLoading = false

    /// The workspace ID this store is tracking.
    private(set) var workspaceId: String?

    private var loadTask: Task<Void, Never>?
    private var dirty = false

    init(environment: FileIndexStoreEnvironment = .none) {
        self.environment = environment
    }

    // MARK: - Public API

    /// Ensure the file index is loaded for a workspace.
    /// No-op if already cached and clean. Re-fetches if dirty or different workspace.
    func ensureLoaded(workspaceId: String, apiClient: any WorkspaceFileIndexFetching) {
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

    /// Mark the current workspace index dirty when the global app event stream
    /// reports a workspace mutation.
    func invalidate(workspaceId: String) {
        guard workspaceId == self.workspaceId else { return }
        invalidate()
    }

    // MARK: - Testing

    // periphery:ignore - used by tests via @testable import
    /// Set paths directly for unit tests. Not for production use.
    func setPathsForTesting(_ paths: [String]) {
        self.paths = paths
        self.dirty = false
    }

    // MARK: - Internals

    private func load(workspaceId: String, apiClient: any WorkspaceFileIndexFetching) {
        loadTask?.cancel()
        dirty = false

        // Show disk-cached index immediately while fetching fresh
        if paths == nil {
            Task { [weak self] in
                guard let self else { return }
                if let cached = await self.environment.loadCachedFileIndex(workspaceId) {
                    if self.workspaceId == workspaceId, self.paths == nil {
                        self.paths = cached
                        self.isLoading = false
                        self.environment.logDebug("File index loaded from cache: \(cached.count) paths")
                    }
                }
            }
        }

        isLoading = paths == nil

        loadTask = Task { [weak self] in
            do {
                let response = try await apiClient.fetchFileIndex(workspaceId: workspaceId)
                guard let self, !Task.isCancelled, self.workspaceId == workspaceId else { return }
                self.paths = response.paths
                self.isLoading = false
                // Persist to disk for next app launch.
                await self.environment.cacheFileIndex(response.paths, workspaceId)
                self.environment.logDebug("File index loaded: \(response.paths.count) paths for workspace \(workspaceId)")
            } catch {
                guard let self, !Task.isCancelled, self.workspaceId == workspaceId else { return }
                if self.paths == nil {
                    self.paths = []
                }
                self.isLoading = false
                self.environment.logWarning("Failed to load file index: \(error.localizedDescription)")
            }
        }
    }
}
