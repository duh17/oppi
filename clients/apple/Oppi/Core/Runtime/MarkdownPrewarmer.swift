import Foundation

/// Asynchronous markdown cache prewarmer for history loads.
///
/// Parses the most recent assistant messages on a background thread
/// so the collection view hits warm caches on first render, avoiding
/// layout cascades from async parse → height change → re-layout.
@MainActor
final class MarkdownPrewarmer {

    private var prewarmTask: Task<Void, Never>?

    static let maxMessages = 48
    static let maxCharsPerMessage = 12_000
    static let maxTotalChars = 192_000

    /// Purge global markdown cache when resetting after a very large timeline.
    static let cachePurgeItemThreshold = 250

    func prewarm(assistantTexts: [String]) {
        cancel()
        guard !assistantTexts.isEmpty else { return }

        var seenLengths: Set<Int> = []
        var totalBytes = 0
        var textsToCache: [String] = []
        textsToCache.reserveCapacity(min(Self.maxMessages, assistantTexts.count))

        let themeID = ThemeRuntimeState.currentThemeID()

        // Prefer newest assistant messages first, with conservative size limits.
        // Use utf8.count (O(1)) instead of String.count (O(n)) for size checks.
        // Note: shouldCache is redundant when we already check textBytes ≤ maxCharsPerMessage
        // (maxCharsPerMessage=12_000 < shouldCache's 16KB limit).
        for text in assistantTexts.reversed() {
            let textBytes = text.utf8.count
            guard textBytes <= Self.maxCharsPerMessage else { continue }
            // Lightweight dedup by byte length — avoids hashing full string content.
            // Collision-safe enough for prewarm (worst case: skip a duplicate-length text).
            guard seenLengths.insert(textBytes).inserted else { continue }

            if totalBytes + textBytes > Self.maxTotalChars {
                continue
            }

            // Skip cache.get() check during fresh loads — the cache is typically
            // cold or stale. The detached prewarm task will recheck anyway.
            textsToCache.append(text)
            totalBytes += textBytes

            if textsToCache.count >= Self.maxMessages {
                break
            }
        }

        guard !textsToCache.isEmpty else { return }
        textsToCache.reverse()

        prewarmTask = Task.detached(priority: .utility) {
            for text in textsToCache {
                if Task.isCancelled { return }
                if MarkdownSegmentCache.shared.get(text, themeID: themeID) != nil { continue }

                let blocks = parseCommonMark(text)
                if Task.isCancelled { return }

                let segments = FlatSegment.build(from: blocks, themeID: themeID)
                MarkdownSegmentCache.shared.set(text, themeID: themeID, segments: segments)
            }
        }
    }

    func cancel() {
        prewarmTask?.cancel()
        prewarmTask = nil
    }
}
