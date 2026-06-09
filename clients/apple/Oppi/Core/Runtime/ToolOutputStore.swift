import Foundation

/// Stores full tool output separately from ChatItem for performance.
///
/// ChatItem.toolCall only carries a ≤500 char preview and byte count.
/// The full output is fetched on-demand when the user expands a tool call row.
///
/// Memory bounded by FIFO eviction. Individual outputs are stored intact; when
/// total memory grows past the budget, older entries are evicted instead of
/// truncating the active output.
@MainActor @Observable
final class ToolOutputStore {
    private struct StoredOutput {
        var text: String
        var previewOnly: Bool
        var totalBytes: Int?
    }

    /// Max total bytes across stored outputs before FIFO eviction.
    /// Large active outputs are kept intact even when they exceed this budget;
    /// older entries are the memory-pressure relief valve.
    static let totalCap = 16 * 1024 * 1024  // 16MB

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

        // Track insertion order
        if existing == nil {
            insertionOrder.append(itemID)
        }

        let updatedText = existingText + chunk
        let updatedBytes = updatedText.utf8.count
        totalBytes -= existingBytes
        entries[itemID] = StoredOutput(text: updatedText, previewOnly: false, totalBytes: nil)
        totalBytes += updatedBytes

        // Evict older items if total cap exceeded. Keep the active output intact.
        evictIfNeeded(protecting: itemID)
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

        let storedText = output
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

        evictIfNeeded(protecting: itemID)
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

    // periphery:ignore - used by ToolOutputStoreTests + TimelineReducerToolTests via @testable import
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

    private func evictIfNeeded(protecting protectedItemID: String) {
        while totalBytes > Self.totalCap, let oldest = insertionOrder.first {
            if oldest == protectedItemID {
                guard insertionOrder.count > 1 else { return }
                insertionOrder.removeFirst()
                insertionOrder.append(oldest)
                continue
            }
            insertionOrder.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalBytes -= removed.text.utf8.count
            }
        }
    }
}
