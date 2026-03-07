import UIKit

/// LRU cache for pre-built NSAttributedString results from tool row render strategies.
///
/// Keyed by the deterministic render signature (from `ToolTimelineRowRenderMetrics`).
/// When a cell is recycled for the same content, the cached attributed string is
/// returned instantly — skipping the expensive syntax highlight / ANSI parse / diff build.
///
/// Uses `NSCache` which automatically evicts under memory pressure.
@MainActor
enum ToolRowRenderCache {
    private final class Entry {
        let attributed: NSAttributedString
        init(_ attributed: NSAttributedString) {
            self.attributed = attributed
        }
    }

    private static let cache: NSCache<NSNumber, Entry> = {
        let c = NSCache<NSNumber, Entry>()
        c.countLimit = 128
        // ~8MB total limit. Individual entries range from ~1KB (single line)
        // to ~500KB (1000-line highlighted file).
        c.totalCostLimit = 8 * 1024 * 1024
        return c
    }()

    /// Look up a cached attributed string by render signature.
    static func get(signature: Int) -> NSAttributedString? {
        cache.object(forKey: NSNumber(value: signature))?.attributed
    }

    /// Store a rendered attributed string keyed by render signature.
    /// Cost is estimated from the string length (bytes ≈ 2 × character count for UTF-16).
    static func set(signature: Int, attributed: NSAttributedString) {
        let cost = attributed.length * 2
        cache.setObject(Entry(attributed), forKey: NSNumber(value: signature), cost: cost)
    }

    /// Evict all cached entries. Called on memory warning or session disconnect.
    static func evictAll() {
        cache.removeAllObjects()
    }
}
