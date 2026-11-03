import UIKit

/// The decoded images markdown shows, and the source bytes behind the ones a
/// WebView draws or the image view animates. Keyed by media URL and shared by
/// every screen, so the timeline's rows, a reader, and a fullscreen view all
/// hit the same entry.
///
/// Both caches are bounded by what their entries cost, not by how many there
/// are: one fullscreen photo decodes to tens of MB.
@MainActor
enum MarkdownMediaCaches {
    /// Decoded bitmaps are what a media-heavy chat keeps resident: one large
    /// fullscreen photo alone decodes to 24 MB. 64 MB holds the images a screen
    /// of the timeline shows and lets the off-screen rows behind them go, which
    /// refetch from the server's cache when they scroll back.
    static let imageTotalCostLimit = 64 * 1024 * 1024
    /// Second bound on the same cache, so a screen of small thumbnails cannot
    /// stay resident on entry count alone.
    static let imageCountLimit = 96
    /// Source bytes behind an SVG or an animated raster are cheap to restore:
    /// the fetch refills them and WebKit or ImageIO decodes them again. 16 MB
    /// keeps a handful of large GIFs or APNGs without a whole chat's animations.
    static let dataTotalCostLimit = 16 * 1024 * 1024
    static let dataCountLimit = 128

    /// Which source cache an entry belongs to: SVG runs in a WebView, an
    /// animated raster plays on the image view.
    enum ImageDataKind {
        case svg
        case animatedRaster
    }

    private static let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = imageTotalCostLimit
        cache.countLimit = imageCountLimit
        return cache
    }()
    private static let svgData = makeImageDataCache()
    private static let animatedRasterData = makeImageDataCache()

    /// What each cache was given since its last trim. `NSCache` reports neither
    /// its entry count nor its cost, so `trim()` reports these.
    private static var imageFootprint = CacheFootprint()
    private static var dataFootprint = CacheFootprint()

    private static func makeImageDataCache() -> NSCache<NSURL, NSData> {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = dataTotalCostLimit
        cache.countLimit = dataCountLimit
        return cache
    }

    /// The memory a decoded image occupies, the unit `NSCache` evicts by: a
    /// 3000×2000 photo costs 24 MB whatever its encoded file weighed.
    static func decodedByteCost(of image: UIImage) -> Int {
        if let raster = image.cgImage {
            return max(1, IconAssetCache.decodedByteCost(bytesPerRow: raster.bytesPerRow, height: raster.height))
        }
        // A backing store Core Graphics cannot describe still occupies pixels.
        let width = Int((image.size.width * image.scale).rounded())
        let height = Int((image.size.height * image.scale).rounded())
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow, pixels > 0 else { return .max }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return byteOverflow ? .max : bytes
    }

    static func cachedRaster(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    static func cacheRaster(_ image: UIImage, for url: URL) {
        let key = url as NSURL
        let cost = decodedByteCost(of: image)
        // A row that shows a cached image inserts it again, and that hit is not
        // new memory: only a cold insert grows the tally.
        if images.object(forKey: key) == nil {
            imageFootprint.record(cost, limit: imageTotalCostLimit)
        }
        images.setObject(image, forKey: key, cost: cost)
    }

    static func cachedImageData(_ kind: ImageDataKind, for url: URL) -> Data? {
        imageDataCache(kind).object(forKey: url as NSURL) as Data?
    }

    static func cacheImageData(_ data: Data, kind: ImageDataKind, for url: URL) {
        let key = url as NSURL
        if imageDataCache(kind).object(forKey: key) == nil {
            dataFootprint.record(data.count, limit: dataTotalCostLimit)
        }
        imageDataCache(kind).setObject(data as NSData, forKey: key, cost: data.count)
    }

    private static func imageDataCache(_ kind: ImageDataKind) -> NSCache<NSURL, NSData> {
        kind == .svg ? svgData : animatedRasterData
    }

    /// Drops every decoded image and image source entry and reports what they
    /// were holding.
    static func trim() -> (images: CacheFootprint, data: CacheFootprint) {
        let imagesHeld = imageFootprint.capped(entries: imageCountLimit, bytes: imageTotalCostLimit)
        let dataHeld = dataFootprint.capped(entries: dataCountLimit, bytes: dataTotalCostLimit)
        images.removeAllObjects()
        svgData.removeAllObjects()
        animatedRasterData.removeAllObjects()
        imageFootprint = CacheFootprint()
        dataFootprint = CacheFootprint()
        return (imagesHeld, dataHeld)
    }

    /// A chat that leaves for good gives the shared media caches back what it
    /// filled.
    ///
    /// Every screen shares these caches, and `NSCache` returns their memory only
    /// under a warning, so a media-heavy chat kept the footprint it raised until
    /// relaunch. Markdown rasters and sources, inline video still frames, and the
    /// decoded attachment thumbnails all go; a miss fetches and decodes again.
    /// A reader pushed over the chat keeps the chat alive, and so keeps its media.
    static func releaseAfterChatClose() {
        let markdown = trim()
        let stillFrames = InlineVideoStillFrameStore.shared.removeAll()
        let decoded = ImageDecodeCache.removeAll()
        guard !markdown.images.isEmpty
            || !markdown.data.isEmpty
            || !stillFrames.isEmpty
            || !decoded.isEmpty
        else { return }
        // The shipped `Cache` category: a report shows whether leaving a chat
        // actually dropped the media memory it was holding.
        ClientLog.info(
            "Cache",
            "Chat closed, media released",
            metadata: [
                "imageEntries": String(markdown.images.entries),
                "imageBytes": String(markdown.images.bytes),
                "imageDataEntries": String(markdown.data.entries),
                "imageDataBytes": String(markdown.data.bytes),
                "stillFrameEntries": String(stillFrames.entries),
                "stillFrameBytes": String(stillFrames.bytes),
                "decodedThumbnailEntries": String(decoded.entries),
                "decodedThumbnailBytes": String(decoded.bytes),
            ]
        )
    }
}
