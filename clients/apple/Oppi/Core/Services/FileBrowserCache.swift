import CryptoKit
import Foundation
import os
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "FileBrowserCache")

/// Disk cache for workspace file index data.
///
/// Stores the file index in the app's Caches directory so path suggestions
/// remain fast across view reloads. The system may evict this data under
/// storage pressure.
///
/// Entries live under one directory per server (`servers/<server>/<key>`), so
/// removing a server deletes every index it owns, including worktree keys and
/// workspaces the app no longer lists, and two servers can never collide.
/// Workspace mutation events clear stale cached paths.
actor FileBrowserCache {

    static let shared = FileBrowserCache()

    private let root: URL
    private let serversRoot: URL

    /// Servers whose data was removed. Writes for these ids are dropped so a
    /// late in-flight index fetch cannot recreate what Remove Server deleted.
    private let removedServerIds = OSAllocatedUnfairLock(initialState: Set<String>())

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { fatalError("No caches directory") }
            self.root = caches.appendingPathComponent("FileBrowser", isDirectory: true)
        }
        serversRoot = self.root.appendingPathComponent("servers", isDirectory: true)
        try? FileManager.default.createDirectory(at: serversRoot, withIntermediateDirectories: true)
        Self.removeUnscopedEntries(in: self.root, keeping: serversRoot)
    }

    // MARK: - Server lifecycle

    /// Refuse writes for a server until `resumeServer(_:)`. Marked synchronously
    /// before `removeServer(_:)` is awaited; see `TimelineCache.markRemoved(_:)`.
    nonisolated func markRemoved(_ serverId: String) {
        removedServerIds.withLock { _ = $0.insert(serverId) }
    }

    /// Delete one server's cached files. Call `markRemoved(_:)` first.
    func removeServer(_ serverId: String) {
        try? FileManager.default.removeItem(at: serverDir(serverId))
        logger.info("File browser cache removed for server \(serverId, privacy: .public)")
    }

    /// Allow writes for a server again once a later pairing of the same id commits.
    nonisolated func resumeServer(_ serverId: String) {
        removedServerIds.withLock { _ = $0.remove(serverId) }
    }

    // MARK: - Invalidation

    /// Clear cached directory listings for a workspace when present.
    func invalidateDirectoryListings(for workspaceId: String, serverId: String) {
        let dir = workspaceDir(workspaceId, serverId: serverId).appendingPathComponent("dirs", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        logger.debug("Invalidated directory listings for \(workspaceId)")
    }

    /// Clear workspace-scoped listings and the cached file index after a global
    /// workspace mutation invalidation.
    func invalidateWorkspaceCaches(for workspaceId: String, serverId: String) {
        let workspace = workspaceDir(workspaceId, serverId: serverId)
        try? FileManager.default.removeItem(at: workspace.appendingPathComponent("dirs", isDirectory: true))
        try? FileManager.default.removeItem(at: workspace.appendingPathComponent("index.json"))
        logger.debug("Invalidated workspace file caches for \(workspaceId)")
    }

    /// Delete everything this cache holds.
    func clear() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: serversRoot, withIntermediateDirectories: true)
        logger.info("File browser cache cleared")
    }

    /// Total bytes of cached files.
    func diskSize() -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: - File Index

    /// Cached file index paths, or nil if not cached.
    func fileIndex(workspaceId: String, serverId: String) -> [String]? {
        let file = indexURL(workspaceId: workspaceId, serverId: serverId)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// Cache the file index. Dropped for a removed server.
    func cacheFileIndex(_ paths: [String], workspaceId: String, serverId: String) {
        guard !isRemoved(serverId) else { return }
        let file = indexURL(workspaceId: workspaceId, serverId: serverId)
        ensureParent(of: file)
        guard let data = try? JSONEncoder().encode(paths) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Paths

    private func serverDir(_ serverId: String) -> URL {
        serversRoot.appendingPathComponent(stableKey(serverId), isDirectory: true)
    }

    private func workspaceDir(_ workspaceId: String, serverId: String) -> URL {
        serverDir(serverId).appendingPathComponent(stableKey(workspaceId), isDirectory: true)
    }

    private func indexURL(workspaceId: String, serverId: String) -> URL {
        workspaceDir(workspaceId, serverId: serverId)
            .appendingPathComponent("index.json")
    }

    // MARK: - Helpers

    private func isRemoved(_ serverId: String) -> Bool {
        removedServerIds.withLock { $0.contains(serverId) }
    }

    /// Older builds stored `<root>/<workspace hash>` without a server. It is
    /// only cache, so delete it once instead of guessing which server owned it.
    private static func removeUnscopedEntries(in root: URL, keeping serversRoot: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent != serversRoot.lastPathComponent {
            try? FileManager.default.removeItem(at: entry)
        }
    }

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
