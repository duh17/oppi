import CryptoKit
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "FileBrowserCache")

/// Disk cache for workspace file browser content.
///
/// Caches directory listings, file content, and the file index so
/// previously viewed content loads instantly and survives connectivity
/// gaps. Stored in the app's Caches directory (system may evict under
/// storage pressure).
///
/// Cache keys are derived from workspace ID + path. File content uses
/// `modifiedAt` from the directory listing for freshness — if the
/// server timestamp hasn't changed, the cached bytes are still valid.
///
/// Invalidation:
/// - `git_status` push events call `invalidateDirectoryListings(for:)`
///   to clear stale listings (file content keyed by modifiedAt is
///   self-invalidating).
/// - Manual pull-to-refresh bypasses the cache.
actor FileBrowserCache {

    static let shared = FileBrowserCache()

    private let root: URL

    private init() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { fatalError("No caches directory") }
        root = caches.appendingPathComponent("FileBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Directory Listings

    /// Cached directory listing, or nil if not cached.
    func directoryListing(workspaceId: String, path: String) -> DirectoryListingResponse? {
        let file = listingURL(workspaceId: workspaceId, path: path)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(DirectoryListingResponse.self, from: data)
    }

    /// Cache a directory listing response.
    func cacheDirectoryListing(_ response: DirectoryListingResponse, workspaceId: String, path: String) {
        let file = listingURL(workspaceId: workspaceId, path: path)
        ensureParent(of: file)
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Clear all cached directory listings for a workspace (called on git_status).
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

    // MARK: - File Content

    /// Cached file content, or nil if not cached or stale.
    ///
    /// When `knownModifiedAt` is provided (from a directory listing),
    /// the cache only returns data if the stored timestamp matches.
    /// When nil (e.g. opened from search), returns whatever is cached.
    func fileContent(workspaceId: String, path: String, knownModifiedAt: Int? = nil) -> Data? {
        let dataFile = contentURL(workspaceId: workspaceId, path: path)
        let metaFile = contentMetaURL(workspaceId: workspaceId, path: path)

        guard let data = try? Data(contentsOf: dataFile) else { return nil }

        if let expected = knownModifiedAt,
           let meta = readMeta(at: metaFile),
           meta.modifiedAt != expected {
            return nil // stale
        }

        return data
    }

    /// Cache file content with its server-reported modification timestamp.
    func cacheFileContent(_ data: Data, workspaceId: String, path: String, modifiedAt: Int) {
        let dataFile = contentURL(workspaceId: workspaceId, path: path)
        let metaFile = contentMetaURL(workspaceId: workspaceId, path: path)
        ensureParent(of: dataFile)

        try? data.write(to: dataFile, options: .atomic)

        let meta = CacheMeta(modifiedAt: modifiedAt, cachedAt: Int(Date().timeIntervalSince1970 * 1000))
        if let metaData = try? JSONEncoder().encode(meta) {
            try? metaData.write(to: metaFile, options: .atomic)
        }
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

    private func listingURL(workspaceId: String, path: String) -> URL {
        workspaceDir(workspaceId)
            .appendingPathComponent("dirs", isDirectory: true)
            .appendingPathComponent(stableKey(path.isEmpty ? "__root__" : path) + ".json")
    }

    private func contentURL(workspaceId: String, path: String) -> URL {
        workspaceDir(workspaceId)
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(stableKey(path) + ".data")
    }

    private func contentMetaURL(workspaceId: String, path: String) -> URL {
        workspaceDir(workspaceId)
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(stableKey(path) + ".meta")
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

    private struct CacheMeta: Codable {
        let modifiedAt: Int
        let cachedAt: Int
    }

    private func readMeta(at url: URL) -> CacheMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheMeta.self, from: data)
    }
}
