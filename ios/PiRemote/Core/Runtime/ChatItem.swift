import Foundation

/// Unified timeline item for the chat view.
///
/// Designed for cheap `Equatable` diffs in `LazyVStack`:
/// - Tool output stores preview-only (`outputPreview` ≤ 500 chars)
/// - Full output lives in `ToolOutputStore`, keyed by item ID
/// - Expansion state is external (`Set<String>` in reducer)
enum ChatItem: Identifiable, Equatable {
    case userMessage(id: String, text: String, images: [ImageAttachment] = [], timestamp: Date)
    case assistantMessage(id: String, text: String, timestamp: Date)
    /// Locally generated audio clip for playback in the timeline.
    case audioClip(id: String, title: String, fileURL: URL, timestamp: Date)
    case thinking(id: String, preview: String, hasMore: Bool, isDone: Bool = false)
    case toolCall(
        id: String,
        tool: String,
        argsSummary: String,
        outputPreview: String,
        outputByteCount: Int,
        isError: Bool,
        isDone: Bool
    )
    /// Historical permission from trace replay. Not interactive — rendered
    /// as a resolved marker (the permission is long past).
    case permission(PermissionRequest)
    case permissionResolved(id: String, outcome: PermissionOutcome, tool: String, summary: String)
    case systemEvent(id: String, message: String)
    case error(id: String, message: String)

    var id: String {
        switch self {
        case .userMessage(let id, _, _, _): return id
        case .assistantMessage(let id, _, _): return id
        case .audioClip(let id, _, _, _): return id
        case .thinking(let id, _, _, _): return id
        case .toolCall(let id, _, _, _, _, _, _): return id
        case .permission(let request): return request.id
        case .permissionResolved(let id, _, _, _): return id
        case .systemEvent(let id, _): return id
        case .error(let id, _): return id
        }
    }
}

// MARK: - ToolOutputStore

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

    func append(_ chunk: String, to itemID: String) {
        let existing = chunks[itemID]
        let existingBytes = existing?.utf8.count ?? 0

        // Per-item cap: stop accumulating once hit
        if existingBytes >= Self.perItemCap {
            return
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
            chunks[itemID, default: ""] += truncated + Self.truncationMarker
            totalBytes += truncated.utf8.count + Self.truncationMarker.utf8.count
        }

        // Evict oldest items if total cap exceeded
        evictIfNeeded()
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

// MARK: - Preview helpers

extension ChatItem {
    /// Max characters stored in tool call preview fields.
    static let maxPreviewLength = 500

    /// Truncate a string to preview length.
    static func preview(_ text: String) -> String {
        if text.count <= maxPreviewLength { return text }
        return String(text.prefix(maxPreviewLength - 1)) + "…"
    }

    /// Timestamp for outline display.
    var timestamp: Date? {
        switch self {
        case .userMessage(_, _, _, let ts): return ts
        case .assistantMessage(_, _, let ts): return ts
        case .audioClip(_, _, _, let ts): return ts
        default: return nil
        }
    }
}

// MARK: - ToolArgsStore

/// Stores structured tool call arguments keyed by tool call ID.
///
/// Separate from ChatItem to avoid Equatable cost on the `[String: JSONValue]` dict.
/// ToolCallRow reads from this to render tool-specific headers (bash command, file path, etc).
@MainActor @Observable
final class ToolArgsStore {
    private var store: [String: [String: JSONValue]] = [:]

    func set(_ args: [String: JSONValue], for id: String) {
        store[id] = args
    }

    func args(for id: String) -> [String: JSONValue]? {
        store[id]
    }

    func clear(itemIDs: Set<String>) {
        guard !itemIDs.isEmpty else { return }
        for id in itemIDs {
            store.removeValue(forKey: id)
        }
    }

    func clearAll() {
        store.removeAll()
    }
}
