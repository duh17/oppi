import Foundation
import ImageIO
import os
import UIKit

/// Shared decoded-image cache for base64 blobs shown in chat/tool output.
///
/// Avoids repeated base64 decode + image decode work when cells are reused
/// during fast scrolling.
enum ImageDecodeCache {
    /// A thumbnail is a screen's worth of pixels at most; 128 MB and 96 entries
    /// hold the attachment and tool images a chat shows while it scrolls.
    static let countLimit = 96
    static let totalCostLimit = 128 * 1024 * 1024

    private final class CacheBox: @unchecked Sendable {
        // SAFETY (`@unchecked Sendable`):
        // - `NSCache` is documented thread-safe for concurrent reads/writes.
        // - `footprint` is an `OSAllocatedUnfairLock`, so the tally it guards is thread-safe too.
        // - `CacheBox` is immutable after init (`cache` and `footprint` are `let`) and has no additional mutable state.
        // - Callers only interact through static helpers that perform deterministic keying + decode.
        let cache: NSCache<NSString, UIImage>
        /// What the cache was given since it was last emptied. `NSCache` reports
        /// neither its entries nor its costs, so `removeAll()` reports these.
        let footprint = OSAllocatedUnfairLock(initialState: CacheFootprint())

        init() {
            let cache = NSCache<NSString, UIImage>()
            cache.countLimit = ImageDecodeCache.countLimit
            cache.totalCostLimit = ImageDecodeCache.totalCostLimit
            self.cache = cache
        }
    }

    private static let cacheBox = CacheBox()

    #if DEBUG
    /// Drops every decoded image (`HarnessLaunchReset`).
    static func resetForTesting() { _ = removeAll() }
    #endif

    static func decode(base64: String, maxPixelSize: CGFloat = 1600) -> UIImage? {
        let key = decodeKey(for: base64, maxPixelSize: maxPixelSize) as NSString
        if let cached = cacheBox.cache.object(forKey: key) {
            return cached
        }

        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }

        let image = downsample(data: data, maxPixelSize: maxPixelSize) ?? UIImage(data: data)
        guard let image else { return nil }

        insert(image, forKey: key)
        return image
    }

    /// Inserts one decoded image, charging the tally only for a cold insert: a
    /// row that configures again stores the same image and holds no new memory.
    private static func insert(_ image: UIImage, forKey key: NSString) {
        let cost = pixelCost(of: image)
        if cacheBox.cache.object(forKey: key) == nil {
            cacheBox.footprint.withLock { $0.record(cost, limit: totalCostLimit) }
        }
        cacheBox.cache.setObject(image, forKey: key, cost: cost)
    }

    /// A decoded thumbnail of a stored session attachment. Attachment ids are
    /// content-addressed and never change, so a row that configures again reuses the
    /// thumbnail instead of downloading the image again; closing the chat drops it.
    static func storedAttachmentThumbnail(
        for attachmentID: String,
        sessionId: String?
    ) -> UIImage? {
        cacheBox.cache.object(forKey: storedAttachmentKey(attachmentID, sessionId) as NSString)
    }

    static func storeStoredAttachmentThumbnail(
        _ image: UIImage,
        for attachmentID: String,
        sessionId: String?
    ) {
        insert(image, forKey: storedAttachmentKey(attachmentID, sessionId) as NSString)
    }

    /// Drops every cached image and reports what it was holding.
    @discardableResult
    static func removeAll() -> CacheFootprint {
        let freed = cacheBox.footprint.withLock { footprint in
            let held = footprint.capped(entries: countLimit, bytes: totalCostLimit)
            footprint = CacheFootprint()
            return held
        }
        cacheBox.cache.removeAllObjects()
        return freed
    }

    private static func storedAttachmentKey(_ attachmentID: String, _ sessionId: String?) -> String {
        "stored-attachment-thumbnail:\(sessionId ?? ""):\(attachmentID)"
    }

    static func decodeKey(for base64: String, maxPixelSize: CGFloat) -> String {
        let prefix = String(base64.prefix(32))
        let suffix = String(base64.suffix(32))
        return "\(base64.utf8.count):\(Int(maxPixelSize.rounded())):\(prefix):\(suffix)"
    }

    private static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded())),
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private static func pixelCost(of image: UIImage) -> Int {
        let width = Int((image.size.width * image.scale).rounded())
        let height = Int((image.size.height * image.scale).rounded())
        return max(1, width * height * 4)
    }
}
