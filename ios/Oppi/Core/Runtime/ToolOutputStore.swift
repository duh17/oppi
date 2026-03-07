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
    private struct StoredOutput {
        var text: String
        var previewOnly: Bool
        var totalBytes: Int?
    }

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

    private var entries: [String: StoredOutput] = [:]
    /// Insertion order for FIFO eviction.
    private var insertionOrder: [String] = []
    /// Running total of stored bytes.
    private(set) var totalBytes: Int = 0

    @discardableResult
    func append(_ chunk: String, to itemID: String) -> Bool {
        guard !chunk.isEmpty else {
            return false
        }

        let existing = entries[itemID]
        let existingText = existing?.text ?? ""
        let existingBytes = existingText.utf8.count

        // Per-item cap: stop accumulating once hit
        if existingBytes >= Self.perItemCap {
            return false
        }

        // Track insertion order
        if existing == nil {
            insertionOrder.append(itemID)
        }

        let updatedText: String
        // Append chunk, truncating if it would exceed per-item cap
        let remainingCap = Self.perItemCap - existingBytes
        let chunkBytes = chunk.utf8.count
        if chunkBytes <= remainingCap {
            updatedText = existingText + chunk
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
            updatedText = existingText + truncated + Self.truncationMarker
        }

        let updatedBytes = updatedText.utf8.count
        totalBytes -= existingBytes
        entries[itemID] = StoredOutput(text: updatedText, previewOnly: false, totalBytes: nil)
        totalBytes += updatedBytes

        // Evict oldest items if total cap exceeded
        evictIfNeeded()
        return true
    }

    /// Replace stored output entirely.
    ///
    /// Used for bounded shell preview snapshots (`previewOnly = true`) and for
    /// swapping a previously preview-only entry with fetched full output.
    @discardableResult
    func replace(
        _ output: String,
        for itemID: String,
        previewOnly: Bool = false,
        totalBytes: Int? = nil
    ) -> Bool {
        let existing = entries[itemID]
        let existingBytes = existing?.text.utf8.count ?? 0

        // Track insertion order for FIFO eviction
        if existing == nil {
            insertionOrder.append(itemID)
        }

        let storedText: String
        let outputBytes = output.utf8.count
        if outputBytes > Self.perItemCap {
            // Truncate replacement to fit
            var truncated = ""
            var bytesSoFar = 0
            for char in output {
                let charBytes = String(char).utf8.count
                if bytesSoFar + charBytes > Self.perItemCap { break }
                truncated.append(char)
                bytesSoFar += charBytes
            }
            storedText = truncated + Self.truncationMarker
        } else {
            storedText = output
        }

        let storedBytes = storedText.utf8.count
        let normalizedTotalBytes = previewOnly ? max(totalBytes ?? storedBytes, storedBytes) : nil
        if let existing,
           existing.text == storedText,
           existing.previewOnly == previewOnly,
           existing.totalBytes == normalizedTotalBytes {
            return false
        }

        self.totalBytes -= existingBytes
        entries[itemID] = StoredOutput(
            text: storedText,
            previewOnly: previewOnly,
            totalBytes: normalizedTotalBytes
        )
        self.totalBytes += storedBytes

        evictIfNeeded()
        return true
    }

    func fullOutput(for itemID: String) -> String {
        entries[itemID]?.text ?? ""
    }

    func outputByteCount(for itemID: String) -> Int {
        if let entry = entries[itemID] {
            return entry.totalBytes ?? entry.text.utf8.count
        }
        return 0
    }

    func hasCompleteOutput(for itemID: String) -> Bool {
        guard let entry = entries[itemID], !entry.text.isEmpty else {
            return false
        }
        return !entry.previewOnly
    }

    func hasPreviewOnlyOutput(for itemID: String) -> Bool {
        entries[itemID]?.previewOnly ?? false
    }

    // periphery:ignore - used by ToolOutputStoreTests via @testable import
    func byteCount(for itemID: String) -> Int {
        entries[itemID]?.text.utf8.count ?? 0
    }

    /// Clear output for specific items (memory management).
    func clear(itemIDs: Set<String>) {
        for id in itemIDs {
            if let removed = entries.removeValue(forKey: id) {
                totalBytes -= removed.text.utf8.count
            }
        }
        insertionOrder.removeAll { itemIDs.contains($0) }
    }

    func clearAll() {
        entries.removeAll()
        insertionOrder.removeAll()
        totalBytes = 0
    }

    // MARK: - Private

    private func evictIfNeeded() {
        while totalBytes > Self.totalCap, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalBytes -= removed.text.utf8.count
            }
        }
    }
}
