import CryptoKit
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "FileBrowserCache")

/// Disk cache for workspace file index data.
///
/// Stores the file index in the app's Caches directory so path suggestions
/// remain fast across view reloads. The system may evict this data under
/// storage pressure.
///
/// Cache keys are derived from workspace ID. Workspace mutation events clear
/// stale cached paths.
actor FileBrowserCache {

    static let shared = FileBrowserCache()

    private let root: URL

    private init() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { fatalError("No caches directory") }
        root = caches.appendingPathComponent("FileBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Invalidation

    /// Clear cached directory listings for a workspace when present.
    func invalidateDirectoryListings(for workspaceId: String) {
        let dir = workspaceDir(workspaceId).appendingPathComponent("dirs", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        logger.debug("Invalidated directory listings for \(workspaceId)")
    }

    /// Clear workspace-scoped listings and the cached file index after a global
    /// workspace mutation invalidation.
    func invalidateWorkspaceCaches(for workspaceId: String) {
        let workspace = workspaceDir(workspaceId)
        try? FileManager.default.removeItem(at: workspace.appendingPathComponent("dirs", isDirectory: true))
        try? FileManager.default.removeItem(at: workspace.appendingPathComponent("index.json"))
        logger.debug("Invalidated workspace file caches for \(workspaceId)")
    }

    // MARK: - File Index

    /// Cached file index paths, or nil if not cached.
    func fileIndex(workspaceId: String) -> [String]? {
        let file = indexURL(workspaceId: workspaceId)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// Cache the file index.
    func cacheFileIndex(_ paths: [String], workspaceId: String) {
        let file = indexURL(workspaceId: workspaceId)
        ensureParent(of: file)
        guard let data = try? JSONEncoder().encode(paths) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Paths

    private func workspaceDir(_ workspaceId: String) -> URL {
        root.appendingPathComponent(stableKey(workspaceId), isDirectory: true)
    }

    private func indexURL(workspaceId: String) -> URL {
        workspaceDir(workspaceId)
            .appendingPathComponent("index.json")
    }

    // MARK: - Helpers

    /// Deterministic, filesystem-safe key from an arbitrary string.
    private func stableKey(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func ensureParent(of url: URL) {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

}
