import Foundation
import ImageIO
import UIKit

/// Shared decoded-image cache for base64 blobs shown in chat/tool output.
///
/// Avoids repeated base64 decode + image decode work when cells are reused
/// during fast scrolling.
enum ImageDecodeCache {
    private final class CacheBox: @unchecked Sendable {
        // SAFETY (`@unchecked Sendable`):
        // - `NSCache` is documented thread-safe for concurrent reads/writes.
        // - `CacheBox` is immutable after init (`cache` is `let`) and has no additional mutable state.
        // - Callers only interact through static helpers that perform deterministic keying + decode.
        let cache: NSCache<NSString, UIImage>

        init() {
            let cache = NSCache<NSString, UIImage>()
            cache.countLimit = 96
            cache.totalCostLimit = 128 * 1024 * 1024
            self.cache = cache
        }
    }

    private static let cacheBox = CacheBox()

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

        cacheBox.cache.setObject(image, forKey: key, cost: pixelCost(of: image))
        return image
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
