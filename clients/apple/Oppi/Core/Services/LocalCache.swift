import Foundation

/// Everything Oppi caches from servers on this device: session history and
/// lists (`TimelineCache`), file indexes (`FileBrowserCache`), the icon artwork
/// it keeps so icons draw at once (`IconAssetCache.DiskStore`), and any HTTP
/// cache an older build left on disk (`LocalHTTPCache`). Storage & About shows
/// the size and clears it.
enum LocalCache {
    /// The cached bytes on disk, formatted for display.
    static func formattedSize(
        timelineCache: TimelineCache = .shared,
        fileBrowserCache: FileBrowserCache = .shared,
        iconCaches: URL = AppLibrary.caches()
    ) async -> String {
        ByteCountFormatter.string(
            fromByteCount: await byteCount(
                timelineCache: timelineCache,
                fileBrowserCache: fileBrowserCache,
                iconCaches: iconCaches
            ),
            countStyle: .file
        )
    }

    /// Everything this device caches from servers, in bytes: what Storage & About
    /// reports and what Clear deletes.
    static func byteCount(
        timelineCache: TimelineCache = .shared,
        fileBrowserCache: FileBrowserCache = .shared,
        iconCaches: URL = AppLibrary.caches()
    ) async -> Int64 {
        let timelineBytes = await timelineCache.diskSize()
        let fileBrowserBytes = await fileBrowserCache.diskSize()
        return timelineBytes
            + fileBrowserBytes
            + IconAssetCache.DiskStore.storedBytes(caches: iconCaches)
    }

    /// Wipes every cache above. Oppi downloads from the server again when needed.
    static func clear(
        timelineCache: TimelineCache = .shared,
        fileBrowserCache: FileBrowserCache = .shared,
        httpCacheDirectory: URL? = nil,
        iconCaches: URL = AppLibrary.caches()
    ) async {
        await timelineCache.clear()
        await fileBrowserCache.clear()
        IconAssetCache.DiskStore.removeAllBytes(caches: iconCaches)
        LocalHTTPCache.clear(directory: httpCacheDirectory)
    }
}
