import Foundation

/// Everything Oppi caches from servers on this device: session history and
/// lists (`TimelineCache`), file indexes (`FileBrowserCache`), and any HTTP
/// cache an older build left on disk (`LocalHTTPCache`). Storage & About shows
/// the size and clears it.
enum LocalCache {
    /// The cached bytes on disk, formatted for display.
    static func formattedSize(
        timelineCache: TimelineCache = .shared,
        fileBrowserCache: FileBrowserCache = .shared
    ) async -> String {
        let timelineBytes = await timelineCache.diskSize()
        let fileBrowserBytes = await fileBrowserCache.diskSize()
        return ByteCountFormatter.string(fromByteCount: timelineBytes + fileBrowserBytes, countStyle: .file)
    }

    /// Wipes every cache above. Oppi downloads from the server again when needed.
    static func clear(
        timelineCache: TimelineCache = .shared,
        fileBrowserCache: FileBrowserCache = .shared,
        httpCacheDirectory: URL? = nil
    ) async {
        await timelineCache.clear()
        await fileBrowserCache.clear()
        LocalHTTPCache.clear(directory: httpCacheDirectory)
    }
}
