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
    // swiftlint:disable:next enum_case_associated_values_count
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
