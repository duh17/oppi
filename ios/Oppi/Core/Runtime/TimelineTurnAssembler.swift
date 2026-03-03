import Foundation

@MainActor
enum TimelineTurnAssembler {
    static func isWhitespaceOnly(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func makeAssistantItem(id: String, text: String, timestamp: Date) -> ChatItem {
        .assistantMessage(id: id, text: text, timestamp: timestamp)
    }

    static func makeThinkingItem(id: String, preview: String, hasMore: Bool, isDone: Bool = false) -> ChatItem {
        .thinking(id: id, preview: preview, hasMore: hasMore, isDone: isDone)
    }

    static func shouldSuppressDuplicateMessageEnd(
        content: String,
        turnInProgress: Bool,
        currentAssistantID: String?,
        latestAssistantItem: ChatItem?
    ) -> Bool {
        guard !turnInProgress, currentAssistantID == nil else { return false }
        guard let latestAssistantItem,
              case .assistantMessage(_, let existingText, _) = latestAssistantItem else {
            return false
        }

        return existingText.trimmingCharacters(in: .whitespacesAndNewlines)
            == content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeToolCallItem(
        id: String,
        tool: String,
        argsSummary: String,
        outputPreview: String,
        outputByteCount: Int,
        isError: Bool,
        isDone: Bool
    ) -> ChatItem {
        .toolCall(
            id: id,
            tool: tool,
            argsSummary: ChatItem.preview(argsSummary),
            outputPreview: outputPreview,
            outputByteCount: outputByteCount,
            isError: isError,
            isDone: isDone
        )
    }

    static func makeUpdatedToolCallPreview(
        existing: ChatItem,
        output: String,
        isError: Bool
    ) -> ChatItem? {
        guard case .toolCall(let id, let tool, let args, _, _, let existingError, let isDone) = existing else {
            return nil
        }

        return .toolCall(
            id: id,
            tool: tool,
            argsSummary: args,
            outputPreview: ChatItem.preview(output),
            outputByteCount: output.utf8.count,
            isError: existingError || isError,
            isDone: isDone
        )
    }

    static func makeDoneToolCall(existing: ChatItem, isError: Bool) -> ChatItem? {
        guard case .toolCall(let id, let tool, let args, let preview, let bytes, let streamIsErr, _) = existing else {
            return nil
        }

        let finalIsError = isError || streamIsErr
        return .toolCall(
            id: id,
            tool: tool,
            argsSummary: args,
            outputPreview: preview,
            outputByteCount: bytes,
            isError: finalIsError,
            isDone: true
        )
    }
}
