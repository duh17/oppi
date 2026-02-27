import Foundation

/// Stores full tool output separately from ChatItem for performance.
///
/// ChatItem.toolCall only carries a ≤500 char preview and byte count.
/// The full output is fetched on-demand when the user expands a tool call row.
///
/// Memory bounded: per-item cap of 2MB, total cap of 16MB.
/// When total cap is exceeded, oldest items are evicted (FIFO).
@MainActor @Observable
final class ToolOutputStore {
    /// Max bytes stored per tool call output.
    /// Needs headroom for image/audio data URIs (base64 inflates ~33%).
    /// 1024x1024 PNGs can exceed 512KB once encoded; 2MB avoids truncating
    /// common tool-read images while still bounding memory.
    static let perItemCap = 2 * 1024 * 1024  // 2MB
    /// Max total bytes across all stored outputs.
    /// Keeps several large media outputs resident without immediate eviction.
    static let totalCap = 16 * 1024 * 1024  // 16MB
    /// Suffix appended when output is truncated.
    static let truncationMarker = "\n\n… [output truncated]"

    private var chunks: [String: String] = [:]
    /// Insertion order for FIFO eviction.
    private var insertionOrder: [String] = []
    /// Running total of stored bytes.
    private(set) var totalBytes: Int = 0

    @discardableResult
    func append(_ chunk: String, to itemID: String) -> Bool {
        guard !chunk.isEmpty else {
            return false
        }

        let existing = chunks[itemID]
        let existingBytes = existing?.utf8.count ?? 0

        // Per-item cap: stop accumulating once hit
        if existingBytes >= Self.perItemCap {
            return false
        }

        // Track insertion order
        if existing == nil {
            insertionOrder.append(itemID)
        }

        // Append chunk, truncating if it would exceed per-item cap
        let remainingCap = Self.perItemCap - existingBytes
        let chunkBytes = chunk.utf8.count
        if chunkBytes <= remainingCap {
            chunks[itemID, default: ""] += chunk
            totalBytes += chunkBytes
        } else {
            // Truncate chunk to fit within per-item cap.
            // Use prefix by character and check byte count to avoid splitting UTF-8.
            var truncated = ""
            var bytesSoFar = 0
            for char in chunk {
                let charBytes = String(char).utf8.count
                if bytesSoFar + charBytes > remainingCap { break }
                truncated.append(char)
                bytesSoFar += charBytes
            }
            let truncatedOutput = truncated + Self.truncationMarker
            chunks[itemID, default: ""] += truncatedOutput
            totalBytes += truncatedOutput.utf8.count
        }

        // Evict oldest items if total cap exceeded
        evictIfNeeded()
        return true
    }

    func fullOutput(for itemID: String) -> String {
        chunks[itemID, default: ""]
    }

    func byteCount(for itemID: String) -> Int {
        chunks[itemID]?.utf8.count ?? 0
    }

    /// Clear output for specific items (memory management).
    func clear(itemIDs: Set<String>) {
        for id in itemIDs {
            if let removed = chunks.removeValue(forKey: id) {
                totalBytes -= removed.utf8.count
            }
        }
        insertionOrder.removeAll { itemIDs.contains($0) }
    }

    func clearAll() {
        chunks.removeAll()
        insertionOrder.removeAll()
        totalBytes = 0
    }

    // MARK: - Private

    private func evictIfNeeded() {
        while totalBytes > Self.totalCap, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            if let removed = chunks.removeValue(forKey: oldest) {
                totalBytes -= removed.utf8.count
            }
        }
    }
}
