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
        // If we're actively streaming a message (currentAssistantID != nil),
        // let messageEnd finalize it normally — this is the standard path.
        guard currentAssistantID == nil else { return false }

        // Otherwise, the assistant message was already finalized (e.g., by
        // toolStart calling finalizeAssistantMessage). If the latest assistant
        // item matches the messageEnd content, suppress the duplicate.
        // This covers both:
        //   1. Mid-turn: text streamed → tool start finalizes → messageEnd
        //      arrives with same text (turnInProgress == true)
        //   2. Reconnect: trace already loaded → stale messageEnd arrives
        //      (turnInProgress == false)
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
