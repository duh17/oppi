import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "LocalHTTPCache")

/// Keeps HTTP traffic off disk.
///
/// Oppi's own sessions use no `URLCache` (see `TailnetTransportRoute`). Builds
/// before that change shared the process-wide disk cache, which stored response
/// bodies and `Authorization: Bearer` request headers in
/// `Library/Caches/<bundle>/Cache.db`. This type removes that leftover data and
/// keeps the shared cache memory-only so nothing else in the process can recreate it.
enum LocalHTTPCache {
    /// Files and directories CFNetwork's default disk cache creates beside `Cache.db`.
    private static let diskCacheNames = [
        "Cache.db", "Cache.db-shm", "Cache.db-wal", "Cache.db-journal", "fsCachedData",
    ]

    /// Launch-time step: replace the shared cache with a memory-only one before
    /// anything opens `Cache.db`, then delete what older builds left behind.
    static func disableDiskCacheAndPurgeLeftovers() {
        URLCache.shared = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, directory: nil)
        purgeLeftovers()
    }

    /// Clear Local Cache: drop every cached response and delete leftover disk files.
    static func clear(directory: URL? = nil) {
        URLCache.shared.removeAllCachedResponses()
        purgeLeftovers(in: directory)
    }

    /// Deletes CFNetwork disk-cache files under `directory` (default: this app's
    /// `Library/Caches/<bundle id>`). Missing files are fine.
    static func purgeLeftovers(
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        guard let directory = directory ?? defaultCacheDirectory(fileManager: fileManager) else { return }
        var removed = 0
        for name in diskCacheNames {
            let url = directory.appending(path: name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                logger.warning("Could not remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if removed > 0 {
            logger.notice("Removed \(removed, privacy: .public) leftover HTTP cache items")
        }
    }

    private static func defaultCacheDirectory(fileManager: FileManager) -> URL? {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundleId = Bundle.main.bundleIdentifier else { return nil }
        return caches.appending(path: bundleId, directoryHint: .isDirectory)
    }
}
