import Foundation

/// Unified timeline item for the chat view.
///
/// Designed for cheap `Equatable` diffs in the collection timeline:
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
    case systemEvent(id: String, message: String)
    case cacheMiss(id: String, message: String)
    case customEvent(id: String, message: String, presentation: TraceEventPresentation)
    case error(id: String, message: String)

    var id: String {
        switch self {
        case .userMessage(let id, _, _, _): return id
        case .assistantMessage(let id, _, _): return id
        case .audioClip(let id, _, _, _): return id
        case .thinking(let id, _, _, _): return id
        case .toolCall(let id, _, _, _, _, _, _): return id
        case .systemEvent(let id, _): return id
        case .cacheMiss(let id, _): return id
        case .customEvent(let id, _, _): return id
        case .error(let id, _): return id
        }
    }

    func replacingID(_ newID: String) -> ChatItem {
        switch self {
        case .userMessage(_, let text, let images, let timestamp):
            return .userMessage(id: newID, text: text, images: images, timestamp: timestamp)
        case .assistantMessage(_, let text, let timestamp):
            return .assistantMessage(id: newID, text: text, timestamp: timestamp)
        case .audioClip(_, let title, let fileURL, let timestamp):
            return .audioClip(id: newID, title: title, fileURL: fileURL, timestamp: timestamp)
        case .thinking(_, let preview, let hasMore, let isDone):
            return .thinking(id: newID, preview: preview, hasMore: hasMore, isDone: isDone)
        case .toolCall(_, let tool, let argsSummary, let outputPreview, let outputByteCount, let isError, let isDone):
            return .toolCall(
                id: newID,
                tool: tool,
                argsSummary: argsSummary,
                outputPreview: outputPreview,
                outputByteCount: outputByteCount,
                isError: isError,
                isDone: isDone
            )
        case .systemEvent(_, let message):
            return .systemEvent(id: newID, message: message)
        case .cacheMiss(_, let message):
            return .cacheMiss(id: newID, message: message)
        case .customEvent(_, let message, let presentation):
            return .customEvent(id: newID, message: message, presentation: presentation)
        case .error(_, let message):
            return .error(id: newID, message: message)
        }
    }
}

// MARK: - Preview helpers

extension ChatItem {
    /// Max characters stored in tool call preview fields.
    static let maxPreviewLength = 500

    /// Truncate a string to preview length.
    static func preview(_ text: String) -> String {
        // Fast path: UTF-8 byte count ≥ character count. For ASCII text (common
        // for tool output), utf8.count == character count, avoiding O(n) grapheme
        // cluster iteration.
        if text.utf8.count <= maxPreviewLength { return text }
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
