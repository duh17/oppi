import Foundation

/// Unified timeline item for the chat view.
///
/// Designed for cheap `Equatable` diffs in `LazyVStack`:
/// - Tool output stores preview-only (`outputPreview` ≤ 500 chars)
/// - Full output lives in `ToolOutputStore`, keyed by item ID
/// - Expansion state is external (`Set<String>` in reducer)
enum ChatItem: Identifiable, Equatable {
    case userMessage(id: String, text: String, timestamp: Date)
    case assistantMessage(id: String, text: String, timestamp: Date)
    case thinking(id: String, preview: String, hasMore: Bool)
    case toolCall(
        id: String,
        tool: String,
        argsSummary: String,
        outputPreview: String,
        outputByteCount: Int,
        isError: Bool,
        isDone: Bool
    )
    case permission(PermissionRequest)
    case permissionResolved(id: String, action: PermissionAction)
    case systemEvent(id: String, message: String)
    case error(id: String, message: String)

    var id: String {
        switch self {
        case .userMessage(let id, _, _): return id
        case .assistantMessage(let id, _, _): return id
        case .thinking(let id, _, _): return id
        case .toolCall(let id, _, _, _, _, _, _): return id
        case .permission(let request): return request.id
        case .permissionResolved(let id, _): return id
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
@MainActor @Observable
final class ToolOutputStore {
    private var chunks: [String: String] = [:]

    func append(_ chunk: String, to itemID: String) {
        chunks[itemID, default: ""] += chunk
    }

    func fullOutput(for itemID: String) -> String {
        chunks[itemID, default: ""]
    }

    func byteCount(for itemID: String) -> Int {
        chunks[itemID]?.utf8.count ?? 0
    }

    /// Clear output for a session's items (memory management).
    func clear(itemIDs: Set<String>) {
        for id in itemIDs {
            chunks.removeValue(forKey: id)
        }
    }

    func clearAll() {
        chunks.removeAll()
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
}
